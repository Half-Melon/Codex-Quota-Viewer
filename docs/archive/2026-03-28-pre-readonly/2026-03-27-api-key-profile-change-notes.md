# CodexAccountSwitcher API Key 账号改动说明

## 这次到底修了什么

这轮不是简单“兼容一下 API Key”，而是把 API Key 账号从半手工状态补成了正式能力：

1. 可以通过 UI 正式导入本地 API Key 账号
2. 切换时不再只恢复 `auth.json`，也会一起恢复该账号保存下来的 `config.toml`
3. API Key 账号在菜单里有专门展示，不再被当成异常红号
4. 多个 API Key 账号的识别，不再只靠 `type = apiKey`

## 真实根因

这次排查下来，之前“看起来有 API Key profile，但切换不成功”的根因主要有 3 个：

### 1. 切换链路只关注 `auth.json`

API Key 场景里，真正决定运行行为的不只是登录态，还有 provider/base URL/model 这些配置。

也就是说：

- 只恢复 `~/.codex/auth.json`
- 不恢复 `~/.codex/config.toml`

会导致切换后 `Codex.app` 读到的运行材料不完整，表现成“像切了，但实际上不可用”。

### 2. API Key 切换校验依赖旧 metadata

旧 profile 文件里很多并没有 `apiKeyDetails`。

之前切换完成后，代码会拿：

- target profile 里保存的 `apiKeyDetails`
- 和当前目标 auth 推出来的指纹

做比对。

这会导致一种误判：

- 实际已经切到正确 API Key
- 但 profile metadata 太旧
- 最终还是被判成“校验失败”，然后回滚

### 3. 运行目录隔离不够显式

这台机器上 `codex` CLI 默认走的是独立的 API Key `CODEX_HOME`。

如果切换器只改 `HOME`，不明确指定 `CODEX_HOME`，那在下面这些场景里就有风险：

- 读取临时 profile
- 浏览器登录临时会话
- 切换后的账号校验

都可能读错运行目录。

## 本次代码改动

### 1. 正式引入 API Key 运行材料

新增：

- `ProfileRuntimeMaterial`
- `APIKeyProfileDetails`
- `ProfileRuntimeSupport.swift`

现在每个账号保存的不再只是 auth，而是：

- `auth.json`
- 可选 `config.toml`
- API Key 的展示和识别信息

包括：

- `providerID`
- `providerName`
- `baseURL`
- `model`
- `keyHint`
- `keyFingerprint`
- `runtimeFingerprint`

其中 `runtimeFingerprint` 会把 key 和运行配置一起纳入识别，避免不同 provider 的 API Key 被误认为同一个账号。

### 2. Keychain bundle 升级

`ProfileStore` 现在统一把账号运行材料存成：

- `authData`
- `configData`

并且继续兼容旧版只有 `authData` 的 bundle 数据。

这意味着：

- 旧用户升级不会丢数据
- 新用户的 API Key 账号可以完整恢复运行配置

### 3. 切换逻辑升级

`ProfileSwitchService` 现在会：

1. 先保存当前账号的 `auth.json + config.toml`
2. 再恢复目标账号的 `auth.json + config.toml`
3. 重启 `Codex.app`
4. 做切换后校验
5. 若失败，同时回滚 auth 和 config

另外，API Key 切换后的校验不再依赖旧 metadata 指纹，而是按 API Key 能拿到的真实信息做兼容校验，避免“实际成功但被误回滚”。

### 4. 运行环境显式隔离

`CodexRPCClient` 和 `BrowserLoginService` 现在都会显式设置：

- `HOME`
- `CODEX_HOME`

确保：

- 临时导入目录
- 浏览器登录临时目录
- 当前 `~/.codex`

不会被外部 shell wrapper 或环境变量污染。

### 5. 正式菜单入口

现在菜单里已经有正式入口：

- `账号管理 -> 导入 API Key 账号…`

这个入口会：

1. 选择一个本地 `CODEX_HOME` 目录
2. 读取 `auth.json`
3. 若存在 `config.toml`，一并读取
4. 校验它是不是 API Key 账号
5. 拉一次快照验证
6. 保存或更新为本地账号

默认会优先指向：

- `~/.codex-cli-apikey`

### 6. 菜单展示升级

API Key 账号现在在菜单里：

- 不再显示假的 `5h / 1w` 空占位
- 主行显示 provider 名称，或回退为 `API Key`
- 次行显示 `model / host / key hint`
- 状态点会显示为蓝色可用态，不再被误判成红色异常态

状态栏如果当前账号是 API Key，也会优先显示 provider 名称，而不是空额度文本。

### 7. 启动时自动回填旧数据

启动后会自动修补两类旧账号：

1. 旧 API Key 账号缺失 `apiKeyDetails`
2. 旧普通账号缺失 `config.toml`

这样旧数据不需要你手工删掉重建，就能进入新模型。

## 当前本机验证结果

### 构建

已验证通过：

- `swift build -c release --product CodexAccountSwitcher`
- `./scripts/build-app.sh`

产物：

- `dist/CodexAccountSwitcher.app`

### 测试

这轮我补了 API Key 相关的回归测试，重点覆盖：

- API Key 展示信息提取
- API Key 账号解析和激活识别
- 只更新 auth 时保留已有 config
- 旧 API Key metadata 缺失时仍可切换成功
- 切换失败时 auth/config 一起回滚

但当前机器的 Swift Command Line Tools 测试运行时有环境问题：

- `swift test` 下既拿不到 `Testing`
- 也拿不到 `XCTest`

所以这轮没法在这台机器上把测试执行结果跑绿。  
这不是业务逻辑问题，而是本机 SwiftPM 测试运行时本身不完整。

## 现在的能力边界

### 已完成

- 可以正式导入 API Key 账号
- 可以完整保存 API Key 运行材料
- 可以稳定切换到 API Key 账号
- 可以从 API Key 切回普通 ChatGPT 账号
- 不同 provider 的 API Key 可以共存

### 仍然不做

- 不托管整套 CLI wrapper 生态
- 不自动帮你管理多个 `CODEX_HOME` 之间的同步
- 不尝试读取 API Key 的 `5h / 1w` ChatGPT 配额
- 不对复杂 `config.toml` 做深层 merge

## 对你本机使用的影响

如果你本机现在是：

- `Codex.app` 默认仍用 `~/.codex`
- CLI 默认走 `~/.codex-cli-apikey`

那么当前项目已经能合理支持这套混合模式：

- 普通 ChatGPT 账号继续在菜单里看 `5h / 1w`
- API Key 账号通过导入入口纳入切换器
- 切换到 API Key 时，`Codex.app` 会带着对应 provider 配置一起切过去
- 切回普通账号时，也会把默认 `config.toml` 恢复回来

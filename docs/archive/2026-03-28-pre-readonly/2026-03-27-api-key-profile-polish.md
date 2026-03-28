# API Key Profile 正式化需求

## 目标

把 `CodexAccountSwitcher` 当前对 API key 账号的“兼容”升级为正式产品能力：

- 用户可以通过 UI 导入 API key 账号
- API key 账号可以被稳定识别、展示、刷新和切换
- API key 账号切换时会带上运行所需配置，而不只是单独替换 `auth.json`
- 菜单和状态展示对 API key 账号有合理的视觉与信息表达

## 当前问题

1. 现在的 API key profile 没有正式 UI 入口，只能手工写入本地数据。
2. 现有 profile 存储只保存 `auth.json`，不会保存 API key 依赖的 `config.toml` 运行配置。
3. 菜单展示仍按 ChatGPT 账号假设处理 API key：
   - 没有 `5h / 1w` 配额时会显示空额度占位
   - 健康状态点会被误判成异常红色
4. API key 身份判定过弱，多个 API key profile 可能会被错误合并。
5. 当前账号回识别逻辑主要依赖邮箱，对 API key 账号不稳。

## 需求范围

### 功能

- 新增正式菜单入口：`导入 API Key 账号…`
- 支持从用户选择的 `CODEX_HOME` 目录导入 API key 运行材料
  - 至少读取 `auth.json`
  - 若存在 `config.toml`，也一并保存
- API key profile 切换时同时恢复：
  - `~/.codex/auth.json`
  - `~/.codex/config.toml`（若该 profile 存在对应配置）
- 保存/更新当前账号时，如果当前是 API key，也要同步捕获当前 `config.toml`

### 数据与身份

- profile 需要新增 API key 元数据：
  - `keyHint`
  - `keyFingerprint`
  - `providerName`
  - `baseURL`
  - `model`
- 身份匹配对 API key 账号不能再只靠 `type + nil email + nil planType`
- 需要兼容已有老 profile 与旧 Keychain bundle 数据

### UI / UX

- API key profile 在菜单中应显示与 ChatGPT 账号不同但合理的信息
- API key profile 不再显示误导性的 `5h / 1w` 空占位
- API key profile 状态点不能被误判为错误态
- 当前账号如果是 API key，状态栏文案也要有合理降级

## 验收标准

- 可以从 `~/.codex-cli-apikey` 这类目录导入 API key 账号
- 导入后能在菜单中看到清晰的 API key 信息
- 切换到 API key profile 后，`Codex.app` 对应运行配置可用
- 切回 ChatGPT profile 后，原配置能恢复
- 多个 API key profile 可以并存且不会被错误覆盖
- 构建通过，文档与测试同步更新

## 已知边界

- 不负责托管用户整个 CLI wrapper 生态
- 不承诺对任意复杂 TOML 配置做深层语义合并
- 若某个 profile 没有保存 `config.toml`，切换时只能恢复其 `auth.json`

# API Key Profile 正式化执行计划

## 内部等级

- `L`

原因：

- 范围跨越存储、切换链路、菜单 UI、状态展示、文档与验证
- 但写集主要集中在少量核心文件，适合单主代理分阶段推进

## Wave 划分

### Wave 1：验证与建模

- 读取当前改动说明、本机配置形状和现有代码路径
- 明确 API key 当前失效的真实原因
- 引入 API key profile 元数据与运行材料模型

### Wave 2：存储与切换链路

- 扩展 Keychain bundle 存储结构，支持 `auth.json + config.toml`
- 补齐旧 bundle 到新结构的兼容解码
- 扩展切换链路，同步恢复 `auth.json` 与可选 `config.toml`

### Wave 3：UI 与交互

- 新增 `导入 API Key 账号…` 菜单入口
- 实现导入目录选择与校验流程
- 菜单列表与状态栏对 API key 账号做专门展示

### Wave 4：验证、文档、清理

- 跑构建与测试
- 更新 README / docs
- 写 phase receipt 和 cleanup receipt

## 关键实现点

- 新增 profile 级 API key 元数据，避免多个 API key profile 错误合并
- 为 `CodexRPCClient.fetchSnapshot` 增加可选 `config.toml` 注入能力
- `ProfileStore` 统一管理 profile 运行材料，不再只有 auth
- `ProfileSwitchService` 在切换前保存当前 profile 的运行材料，在切换目标 profile 时恢复目标运行材料
- `AppController` 为 API key 提供正式导入入口与 UI 展示逻辑

## 验证命令

- `swift build`
- `swift test`
- `./scripts/build-app.sh`

## 回滚策略

- 任何 profile 存储结构升级都必须兼容旧 bundle
- 切换失败时继续沿用现有回滚机制，恢复原 `auth.json`
- 若目标 profile 保存了 `config.toml`，失败时也要恢复原 `config.toml`

## Phase Cleanup 期望

- 保留验证命令结果
- 记录新增/修改文件
- 记录任何测试环境问题
- 不留下临时脚本、临时目录或多余调试输出

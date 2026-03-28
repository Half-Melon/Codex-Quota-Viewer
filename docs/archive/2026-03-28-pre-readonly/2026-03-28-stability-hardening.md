# CodexAccountSwitcher 全面稳定性修复需求

## 目标

把 `CodexAccountSwitcher` 从“功能能跑但存在脆弱点”的状态，提升为：

- 启动时可自动修复历史坏数据
- 当前账号保存、账号切换、API key 导入与额度刷新都稳定
- 关键错误与告警对用户可见
- 核心路径有可重复验证的测试与构建证据

## 核心问题

1. 历史 profile 可能存在重复、孤立凭据、缺失运行材料或受污染配置。
2. `保存当前账号…` 会重复创建同一身份的 profile，导致账号识别变得模糊。
3. API key 导入对 `auth.json` 形态过于苛刻，可能误判有效目录。
4. 菜单里维护了 `statusNotice / loadWarningNotice / profileErrors`，但没有真正展示。
5. 设置页的开机启动切换不是事务化操作，失败后 UI / 持久化 / 实际状态可能不一致。
6. 关键体验路径的自动化测试覆盖明显不足。

## 范围

### 必做

- 新增启动自动修复服务，支持备份、诊断、清理、回滚
- 自动清理可唯一判定的重复/受污染账号与孤立凭据
- 当前账号保存改为 upsert 语义
- API key 导入兼容仅包含 `OPENAI_API_KEY` 的 `auth.json`
- `CodexRPCClient` 对“可登录但无 ChatGPT quota”做结构化降级
- 菜单显式展示最近状态、启动告警与刷新失败原因
- 开机启动设置改为事务化应用
- 补齐高风险路径测试

### 非目标

- 不引入第三方 UI 框架
- 不实现任意复杂 TOML 的语义合并
- 不托管用户所有 `CODEX_HOME` 生命周期

## 验收标准

- 启动时遇到重复 profile、孤立凭据、缺失凭据账号会自动修复并写备份
- 同一账号重复点击 `保存当前账号…` 不再新增重复 profile
- API key 目录即使没有 `auth_mode=apikey` 也能在 `OPENAI_API_KEY` 可识别时导入
- API key 账号在无 ChatGPT 配额时仍能正常显示、切换和刷新
- 菜单顶部能看到最近状态、启动告警、刷新错误
- `swift build` 和 `./scripts/build-app.sh` 可通过；`swift test` 的失败若存在，必须记录为环境阻塞而不是静默忽略

# Stability Hardening 执行计划

## 内部等级

- `XL`

原因：

- 涉及存储、自动修复、UI、设置事务、测试与文档多个层面
- 需要一次性把“当前已知脆弱点”一起收口，避免只修表面症状

## Waves

### Wave 1：治理骨架与文档

- 冻结 requirement doc 与本执行计划
- 写 runtime skeleton / intent / phase receipts
- 审阅并整合当前 worktree 中已有未提交改动

### Wave 2：数据与身份修复

- 实现 `ProfileRepairService`
- 启动时自动备份并修复重复 profile、孤立凭据、缺凭据 metadata
- 统一当前账号识别优先级，保证真实运行态优先于陈旧 `lastActiveProfileID`

### Wave 3：核心链路硬化

- `保存当前账号…` 改为 upsert
- API key 导入兼容 `OPENAI_API_KEY` 直出格式
- `CodexRPCClient` 用结构化信号降级 quota 不可用场景
- 设置页开机启动开关改为事务化

### Wave 4：体验、测试与收尾

- 菜单顶部展示 notices / warnings / current error
- 异常账号次行展示简短错误原因
- 补自动修复、导入兼容、设置事务、notice 构建等测试
- 跑 `swift build`、`swift test`、`./scripts/build-app.sh`

## Ownership

- `ProfileStore + ProfileRepairService`：备份、恢复、清洗、活跃账号重写
- `AppController`：启动编排、menu notice 展示、保存/导入/设置事务接线
- `CodexRPCClient`：API key quota 不可用降级
- `Tests`：高风险路径回归用例

## 验证命令

```bash
swift build
swift test
./scripts/build-app.sh
```

## 回滚规则

- 自动修复前必须先写本地备份
- 自动修复中途失败时从备份恢复 profile metadata、runtime bundle 与 settings
- 设置事务在持久化失败时必须把 launch-at-login 状态回滚到旧值

## Cleanup 期望

- 保留 requirement / plan 文档
- 保留新 runtime receipts
- 保留 repair backup
- 不留下临时调试文件或额外脚本

# 只读额度查看器严格验收执行计划

- 日期：2026-03-28
- 运行编号：`20260328-122417-readonly-acceptance-hardening`
- 内部等级：`XL`

## 波次设计

### Wave 1：并行验收

- 功能正确性审查
  - 当前账号额度读取
  - `cc-switch` 普通登录账号读取
  - API Key 隐藏额度
  - 刷新与错误态
- UX 与菜单文案审查
  - 顶部 notice
  - 当前账号区与 `CC Switch` 区
  - 设置项文案
  - 菜单层级与冗余感
- 代码卫生审查
  - 冗余代码
  - 死逻辑
  - 残留文档
  - 命名与结构负担

### Wave 2：主线程汇总与修复

- 汇总并行审查结果
- 只修高价值问题：
  - 真实 bug
  - 明显冗余
  - 影响使用体验的文案或菜单结构
  - 残留误导文档

### Wave 3：验证与收尾

- 运行：
  - `swift build`
  - `./scripts/build-app.sh`
  - `swift test`
- 若 `swift test` 环境阻塞：
  - 记录精确报错
  - 不伪称通过
- 写出 phase receipts 与 cleanup receipt

## Ownership

- 主代理：需求冻结、计划、修复、最终整合
- 子代理 A：功能验收
- 子代理 B：UX 与菜单文案验收
- 子代理 C：代码卫生与残留验收

## 回滚规则

- 不回滚无关 worktree 改动
- 若某次修复引入回归，仅回滚该修复自身
- 不恢复切换器能力

## Cleanup Expectations

- 保留 requirement / plan / receipt 证明件
- 清理本轮临时探针与无用中间文件
- 记录未完成项和环境阻塞

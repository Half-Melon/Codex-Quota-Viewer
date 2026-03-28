# 2026-03-28 收官验收执行计划

## 内部等级

- XL

## Wave 1：基线确认

- 读取当前 worktree、文档和 runtime 产物
- 重新跑 `swift test` 确认测试链修复后的基线

## Wave 2：并行审查

- 功能正确性
  - 当前账号读取
  - `cc-switch` 刷新与错误态
  - 只读安全边界
- UX 与文案
  - 菜单标题
  - 错误文案
  - 设置文案
- 代码与残留
  - 死代码
  - 结构命名
  - 文档与治理产物残留

## Wave 3：验证与分级

- 运行：
  - `swift test`
  - `swift build`
  - 必要时 `./scripts/build-app.sh`
- 把发现分成三类：
  - 必修问题
  - 中低优先级瑕疵
  - 可接受但待优化项

## 回滚规则

- 本轮默认先审查后判断是否需要修复
- 若发现必须修的高优先级问题，再单独进入修复波次

## Cleanup

- 生成 phase receipt 和 cleanup receipt
- 不新增无意义临时文件

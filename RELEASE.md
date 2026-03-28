# Codex Quota Viewer 0.1.0

一个极简的 macOS 菜单栏工具，只读查看 Codex 官方登录账号额度。

## 这版做了什么

- 查看当前 `~/.codex` 账号的 `5h` / `1w` 剩余额度
- 只读扫描 `cc-switch` 已保存的 Codex 普通登录账号并展示额度
- API Key 登录态不显示官方 `5h` / `1w` 配额
- 菜单状态统一为正常额度、需要重新登录、会话过期、读取失败
- 设置只保留刷新频率、开机启动、菜单栏样式
- 默认产物、Bundle ID、LaunchAgent label 统一为 `CodexQuotaViewer`
- 自动迁移旧版设置目录和旧 LaunchAgent

## 安全边界

- 不提供账号切换
- 不覆盖 `~/.codex/auth.json`
- 不覆盖 `~/.codex/config.toml`
- 不写入 `cc-switch` 数据库

## 使用前提

- macOS 13+
- 已安装官方 `Codex.app`
- 本机可用 `codex app-server`

## 已知范围

- 只做只读额度查看
- 不做 workspace 绑定
- 不包含开发者签名、公证和安装器分发

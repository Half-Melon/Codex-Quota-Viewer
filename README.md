# Codex Quota Viewer

一个极简的 macOS 菜单栏工具，只做一件事：

1. 看当前 Codex 账号和 `cc-switch` 已保存账号的 `5h` / `1w` 剩余额度

它现在是**纯只读额度面板**，不再负责账号切换、导入或保存。

## 核心思路

- 额度读取：直接调用本机 `codex app-server`
- 当前账号：读取官方默认 `~/.codex/auth.json` 和可选 `~/.codex/config.toml`
- 其他账号：只读扫描 `~/.cc-switch/cc-switch.db` 里已经保存的 Codex 普通登录 provider
- 安全边界：应用内部已禁止覆盖当前 `auth.json` 和 `config.toml`

## 适用场景

- 你想在菜单栏快速看当前 Codex 账号额度
- 你已经用 `cc-switch` 管理多个普通登录账号，想一起看剩余额度
- 你明确不希望第三方工具覆盖当前 `~/.codex` 会话文件

## 当前功能

- 查看当前 `~/.codex` 账号额度
- 只读扫描 `cc-switch` 已保存的 Codex 普通登录账号额度
- API Key 登录态不显示 `5h / 1w` 官方额度
- 菜单只展示必要状态：
  - 正常额度
  - `需要重新登录`
  - `过期`
  - `读取失败`
- 设置项只保留：
  - 刷新频率
  - 开机启动
  - 菜单栏样式

## 快速开始

```bash
./scripts/build-app.sh
open ./dist/CodexQuotaViewer.app
```

## 构建

```bash
./scripts/build-app.sh
open ./dist/CodexQuotaViewer.app
```

如需生成可拖拽安装的磁盘镜像：

```bash
./scripts/build-dmg.sh
open ./dist/CodexQuotaViewer.dmg
```

## 使用流程

1. 先在官方 `Codex.app` 里登录你当前正在用的账号
2. 如果你还用了 `cc-switch`，确保它已经保存过其他 Codex 普通登录账号
3. 打开菜单栏里的 `Codex Quota Viewer`
4. 查看顶部“当前账号”的额度
5. 查看下方 `CC Switch 账号` 的只读额度列表
6. 如需调整刷新频率、菜单栏样式或开机启动，打开菜单里的 `设置…`

## 运行要求

- macOS 13+
- 已安装官方 `Codex.app`
- 本机可用 `codex app-server`

## 当前范围

- 只做**只读额度查看**
- 不做账号切换
- 不做 workspace 绑定
- 不做签名、公证、安装器分发

## 说明

- 当前账号额度直接读取官方默认 `~/.codex`
- `cc-switch` 账号额度来自 `~/.cc-switch/cc-switch.db`
- 应用会显式跳过 API Key 登录态的额度展示
- 应用内部已禁止覆盖当前 `~/.codex/auth.json` 和 `~/.codex/config.toml`
- 选择“手动”刷新后，菜单打开不会自动刷新，需要手动点“刷新全部”
- `额度条` 图标在数据过旧时会变灰；手动模式下超过 30 分钟未刷新也会判定为过旧
- 文本图标直接加载官方 Blossom SVG，并按系统外观切换黑/白版本
- 开机启动通过当前用户的 `LaunchAgent` 实现，只在从 `.app` 包启动时可配置
- `build-dmg.sh` 会生成一个可拖到“应用程序”目录安装的 `.dmg`
- `build-app.sh` 默认会尝试做本机 ad-hoc 签名；如果签名失败会直接报错，不再静默继续

## 安全

这版不会写入当前正在生效的 Codex 会话文件。

仍然需要注意两点：

- 当前正在生效的 `~/.codex/auth.json` 依旧由官方 Codex 使用
- 当前正在生效的 `~/.codex/config.toml` 也依旧由官方 Codex 自己管理
- Git 默认忽略 `dist/`、`auth.json`、`*.auth.json`、证书和密钥文件，发布前也应继续避免提交任何本地账号数据
- 这个项目默认只面向本机长期自用，不处理签名、公证和分发信任链
- 打包产物会做本机 ad-hoc 签名，方便本地分发和完整性校验，但不等同于开发者签名或公证

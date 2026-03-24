# Codex Quick Switch

一个极简的 macOS 菜单栏工具，只做两件事：

1. 看多个 Codex 账号的 `5h` / `1w` 剩余额度
2. 一键切换当前 `Codex.app` 使用的账号

适合本机长期自用，不做额外平台层、不做复杂同步、不引入大依赖。

## 核心思路

- 额度读取：直接调用本机 `codex app-server`
- 账号切换：档案 metadata 存本地，账号凭据存 Keychain
- 切换流程：覆盖当前 `~/.codex/auth.json`，重启 `Codex.app`，再做账号校验

## 适用场景

- 你有多个 Codex 账号，需要频繁切换
- 你想在菜单栏快速看额度，而不是每次都进官方客户端
- 你只需要稳定、直接、可本地打包的原生 macOS 小工具

## 当前功能

- 菜单栏支持两种图标样式：
  - 双条 meter：上条表示 `5h`，下条表示 `1w`
  - 文本：显示官方 OpenAI Blossom SVG 图标，同时显示当前 `5h` 和 `1w` 剩余额度
- 每个档案都会显示凭据健康状态：
  - `正常`
  - `读取失败`
  - `需要重新登录`
  - `过期`
- 提供极简设置窗口，只包含 4 个开关：
  - 刷新频率
  - 是否开机启动
  - 图标样式
  - 切换后是否自动打开 Codex 主窗口
- 打包时会自动生成原生 macOS App 图标，并写入标准 `.app` 包

## 快速开始

```bash
./scripts/build-app.sh
open ./dist/CodexQuickSwitch.app
```

## 构建

```bash
./scripts/build-app.sh
open ./dist/CodexQuickSwitch.app
```

如需生成可拖拽安装的磁盘镜像：

```bash
./scripts/build-dmg.sh
open ./dist/CodexQuickSwitch.dmg
```

## 使用流程

1. 先在官方 `Codex.app` 里登录一个账号
2. 打开菜单栏里的 `CodexQuickSwitch`
3. 点 `从当前会话创建档案…`
4. 对其他账号重复一次
5. 之后直接点档案条目即可切换
6. 如需调整刷新频率、图标样式或开机启动，打开菜单里的 `设置…`

## 运行要求

- macOS 13+
- 已安装官方 `Codex.app`
- 本机可用 `codex app-server`

## 当前范围

- 这版只做**账号切换**
- 不做 workspace 绑定
- 不做签名、公证、安装器分发

## 说明

- 档案保存在 `~/Library/Application Support/CodexQuickSwitch/profiles/`
- 档案 JSON 只保存名称、缓存的账号信息和额度快照
- 真正的账号凭据存放在 macOS Keychain，service 为 `CodexQuickSwitch`
- 启动时会自动把旧版 `profiles/*.auth.json` 迁移到 Keychain
- 迁移成功后，旧明文凭据文件会被立即删除
- 新建或更新档案时，metadata 和 Keychain 凭据会一起成功或一起失败，不会留下半成品档案
- 如果档案 JSON 或 `settings.json` 损坏，菜单栏会明确提示对应文件，不再静默忽略
- `更新当前档案` 会把当前会话的最新凭据和额度快照回写到当前档案
- 切换动作会重启 `/Applications/Codex.app`
- 切换前会确认旧 `Codex.app` 已完全退出；如果未能退出，会立即回滚，不会误报切换成功
- 若切换后账号校验失败，会自动回滚到原账号并重新拉起 `Codex.app`
- 双条 meter 图标在数据过旧时会变灰，异常时会进一步减弱显示
- 文本图标直接加载官方 Blossom SVG，并按系统外观切换黑/白版本
- 开机启动通过当前用户的 `LaunchAgent` 实现，只在从 `.app` 包启动时可配置
- 如果关闭“切换后自动打开 Codex 主窗口”，切换只会完成账号写入和校验，不会主动拉起 Codex 窗口
- `build-dmg.sh` 会生成一个可拖到“应用程序”目录安装的 `.dmg`

## 安全

这版不再把账号凭据明文存到档案目录，而是交给 macOS Keychain。

仍然需要注意两点：

- 当前正在生效的 `~/.codex/auth.json` 依旧由官方 Codex 使用
- 这个项目默认只面向本机长期自用，不处理签名、公证和分发信任链
- 打包产物会做本机 ad-hoc 签名，方便本地分发和完整性校验，但不等同于开发者签名或公证

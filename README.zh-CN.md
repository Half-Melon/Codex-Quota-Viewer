[English](README.md) | 中文

# Codex Quota Viewer

一个原生的 macOS 菜单栏应用，用来查看本地 Codex 账号状态和额度使用情况。

Codex Quota Viewer 提供了一种快速、原生、桌面化的方式，让你无需打开终端、
解析 JSON，或在多个本地配置之间反复切换，就能查看当前 Codex 使用的账号、
检查短周期和每周额度，并查看由 CC Switch 保存的其他本地 Codex 配置。

![Codex Quota Viewer screenshot](docs/images/menu-screenshot.png)

## 亮点

- **菜单栏优先**：作为轻量级菜单栏工具运行，没有主窗口，也不会占用 Dock
- **当前账号感知**：读取当前生效的本地 Codex 配置，并立即展示账号状态
- **额度可见性**：为标准 Codex 登录显示短周期和每周额度使用情况
- **API Key 感知**：当官方 Codex 配额不可用时，识别 API key 配置并展示提供方信息
- **CC Switch 集成**：自动发现 CC Switch 中保存的其他本地 Codex 配置
- **实用控制项**：支持手动刷新、定时刷新、文本或仪表样式，以及开机启动

## 系统要求

- macOS 13 或更高版本
- 可用的本地 Codex 安装：
  - `/Applications` 下的 `Codex.app`，或
  - 已经加入 shell `PATH` 的 `codex` CLI
- 已登录的 Codex 配置文件：`~/.codex/auth.json`

可选：

- 如果你希望在菜单中看到额外的 Codex 配置，需要安装 CC Switch，并存在本地
  数据库 `~/.cc-switch/cc-switch.db`

## 快速开始

### 构建应用包

运行：

```bash
./scripts/build-app.sh
```

会生成：

```text
dist/CodexQuotaViewer.app
```

### 启动应用

打开 `dist/CodexQuotaViewer.app`。

Codex Quota Viewer 作为菜单栏应用运行。启动后，它会在 macOS 菜单栏中放置一
个状态项，而不是打开传统主窗口。

### 查看账号信息

点击菜单栏图标后，你会看到：

- **Current Account**
- **CC Switch Accounts**（如果可用）
- **Refresh All**
- **Settings**

## 应用会显示什么

### Current Account

这一部分反映的是当前由下列文件表示的 Codex 配置：

```text
~/.codex/auth.json
```

对于标准 Codex 登录，应用会显示两个额度窗口：

- `5h`：短周期额度摘要
- `1w`：每周额度摘要

对于 API key 配置，Codex Quota Viewer 不会伪造额度数据。相反，它会尽可能从
本地配置中推断并展示这些信息，例如：

- provider name
- model
- provider host
- masked key suffix

### CC Switch Accounts

如果安装了 CC Switch，且其中保存了本地 Codex 配置，应用会在同一菜单中把它
们列出来，方便快速对比。

CC Switch 列表只包含普通 Codex 登录。仅使用 API key 的 CC Switch 配置会被
有意排除在附加账号列表之外。

### 菜单栏显示样式

你可以在两种样式之间切换：

- **Meter**：用紧凑的可视化方式表示剩余额度
- **Text**：例如 `5h82% 1w64%` 这样的文本摘要

## 设置项

Codex Quota Viewer 当前提供 3 个用户可见设置：

- **Refresh interval**：Manual、1 minute、5 minutes、15 minutes
- **Menu bar style**：Meter 或 Text
- **Launch at login**：仅当应用从打包后的 `.app` 启动时可用

设置会保存在本地：

```text
~/Library/Application Support/CodexQuotaViewer/settings.json
```

## 隐私与本地数据

Codex Quota Viewer 面向本地桌面使用场景设计。它只读取你机器上已经存在的数据，
不会要求你在 UI 里手动粘贴凭据。

应用会在可用时读取这些本地来源：

- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.cc-switch/cc-switch.db`

为了获取账号状态，应用会用你本地安装的 Codex 以 `app-server` 模式启动读取。
它不依赖这个项目运营的单独托管后端。

## 故障排查

### “Could not find the codex executable.”

请确认以下任一条件成立：

- `/Applications` 中已安装 `Codex.app`
- `codex` 已安装，并且在 shell `PATH` 中可用

### “Sign in required.”

当前 Codex 会话缺失、无效或已过期。请重新登录 Codex，并确认
`~/.codex/auth.json` 存在且内容是最新的。

### “Timed out while reading quota.”

本地 Codex 进程没有在预期时间内返回账号数据。请再次尝试 **Refresh All**。
如果问题持续，请先确认 Codex 本身在这台机器上可以正常运行。

### “Launch at login can only be configured when running from the app bundle.”

只有从打包后的 `.app` 启动时，开机启动才可用。直接运行 Swift 构建输出的可执
行文件时，这个功能不会生效。

### “Failed to read CC Switch data.”

请检查：

- 是否已安装 CC Switch
- `~/.cc-switch/cc-switch.db` 是否存在
- 系统是否提供 `/usr/bin/sqlite3`

如果其中任一条件不满足，Codex Quota Viewer 仍然可以显示当前 Codex 账号，但
不会展示 CC Switch 账号列表。

## 从源码构建

如果你只想构建可执行文件，而不是完整的应用包，可以运行：

```bash
swift build -c release --product CodexQuotaViewer
```

## 分发说明

当前 DMG 是一个用于测试的预览版本。它还没有完成面向广泛用户分发所需的
notarization，因此在首次启动时，macOS 可能仍然要求手动放行。

## 致谢

本项目通过读取
[CC Switch](https://github.com/farion1231/cc-switch)
管理的本地配置数据，让多账号 Codex 使用场景变得更实用。

特别感谢 CC Switch 项目在本地账号切换和配置管理体验上的工作。Codex Quota
Viewer 直接受益于它提供的工作流和生态支持。

## 社区致谢

感谢 [LinuxDo](https://linux.do) 社区的支持。

LinuxDo 是一个讨论技术、AI 前沿和 AI 实战经验的友好社区。像这样的社区能让
Codex Quota Viewer 这类工具更容易被理解、被验证，也更容易持续改进。

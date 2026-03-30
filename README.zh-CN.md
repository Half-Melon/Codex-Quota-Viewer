[English](README.md) | 中文

# Codex Quota Viewer

一个原生的 macOS 菜单栏应用，让你无需碰终端，就能查看 Codex 额度并管理本地
Codex 会话。

Codex Quota Viewer 把两类日常工作放到了同一个入口里：

- 快速查看当前机器上正在使用的 Codex 账号和额度状态
- 直接管理本机 Codex 会话，包括浏览、恢复、归档、回收站和线程修复

它以菜单栏工具的形态运行，同时把会话管理服务直接打包进应用，所以最终用户不需
要单独 checkout CodexMM、不需要手动装 Node，也不需要自己启动本地服务。

![Codex Quota Viewer 产品截图](docs/images/readme-screenshot.png)

## 为什么使用 Codex Quota Viewer

- **菜单栏优先**：不用开着一个完整主窗口，也能随时看 Codex 状态
- **额度可见**：标准 Codex 登录可直接看到短周期和每周额度窗口
- **多账号感知**：可以把当前账号和 CC Switch 里的本地账号一起对比
- **内置会话管理**：从菜单栏直接打开本地会话管理 Web 控制台
- **不需要额外安装会话管理器**：`CodexQuotaViewer.app` 已经自带运行所需内容

## 0.2.1 更新

- 修复会话管理页面左侧项目目录列表有时无法滚动的问题
- 保持左侧项目列表和右侧会话详情区的独立滚动行为

## 你可以用它做什么

### Quota Viewer

在菜单栏中，你可以：

- 查看当前由 `~/.codex/auth.json` 表示的 Codex 账号
- 为标准 Codex 登录查看 `5h` 和 `1w` 两个额度窗口
- 在没有官方额度数据时，为 API key 配置显示 provider 元信息
- 查看由 CC Switch 保存的其他本地 Codex 账号
- 手动刷新账号状态
- 在菜单栏中切换 Meter 与 Text 两种显示样式

![Codex Quota Viewer 菜单截图](docs/images/menu-screenshot.png)

### 会话管理

通过 **Manage Sessions**，你可以打开一个随应用打包的本地 Web 管理台，在里面：

- 按项目目录分组浏览本地会话
- 按 `Active`、`Archived`、`Trash` 筛选
- 按 session 标题、路径和摘要搜索
- 查看会话摘要、时间、行数、事件数和工具调用数
- 阅读完整线程时间线
- 把会话恢复到 Codex 可识别的位置
- 在 **Resume only** 和 **Rebind cwd** 两种恢复模式之间切换
- 归档当前选中的会话
- 把会话移到回收站、恢复会话、清空回收站
- 批量选择会话并执行归档 / 回收站 / 恢复 / 清空操作
- 在本地线程状态漂移时修复官方 Codex thread 元数据

## 会话管理

内置会话管理是 Codex Quota Viewer 从“额度查看工具”升级成“本地 Codex 桌面伴
侣”的关键能力。

你只需要在菜单栏里点击 **Manage Sessions**。应用会自动完成后续动作：

- 先检查 `http://127.0.0.1:4318` 上的本地会话管理服务是否已经健康
- 如果服务已经在运行，就直接复用它
- 如果服务尚未运行，就从 `CodexQuotaViewer.app` 内部启动 bundled service
- 等到健康检查通过后，再在默认浏览器里打开管理页面

这个管理台只在本机工作。它绑定在 `127.0.0.1`，管理本机 `~/.codex` 会话文件，
也不要求你单独安装 CodexMM 或 Node。

![会话管理截图（已做隐私安全处理）](docs/images/session-manager-screenshot.png)

### 一条典型使用路径

1. 打开 `CodexQuotaViewer.app`，点击菜单栏图标。
2. 选择 **Manage Sessions**。
3. 从左侧栏选中一个项目目录。
4. 再选中你想查看或恢复的会话。
5. 查看摘要卡片、完整线程和官方同步状态。
6. 如果你只是想让 Codex 重新识别这条会话，选择 **Resume only**。
7. 如果你想把这条会话永久指向新的工作目录，选择 **Rebind cwd**。
8. 根据需要点击 **Restore to directory**、**Archive current**、
   **Repair this thread**，或者使用顶部批量操作。

### 两种恢复模式分别是什么意思

- **Resume only**：恢复会话，让 Codex 重新识别它，但不修改原本的工作目录绑定
- **Rebind cwd**：恢复会话，并把它永久改绑到新的项目目录

### “Repair official threads” 是干什么的

当一条本地会话文件明明还存在，但官方 Codex 本地线程状态或 recent conversations
索引出现漂移时，修复动作可以根据本地 session 数据重建这层关联。对于“会话在磁
盘上还在，但在官方本地线程列表里表现不对”的情况，这个能力尤其有用。

## 快速开始

### 安装打包后的应用

1. 从
   [Releases](https://github.com/Half-Melon/Codex-Quota-Viewer/releases)
   页面下载最新 DMG。
2. 将 `CodexQuotaViewer.app` 拖入 `/Applications`。
3. 打开应用；如果 Gatekeeper 弹出提示，按 macOS 指引手动放行。
4. 点击菜单栏中的新图标，查看当前 Codex 账号和额度状态。

### 开始使用会话管理

1. 打开菜单栏图标。
2. 点击 **Manage Sessions**。
3. 如果 bundled service 需要先启动，等待浏览器自动打开。
4. 在本地 Web 管理台里管理你的会话。

## 会话管理如何工作

会话管理运行所需的内容都被打包进了应用：

```text
CodexQuotaViewer.app/Contents/Resources/SessionManager/
```

这个目录包含：

- vendored 的 CodexMM 生产构建产物
- 生产运行所需的 `node_modules`
- 打包时一并复制进 `.app` 的私有 Node runtime

对最终用户来说，最重要的结论其实很简单：

- 可分发单元就是打包后的 `.app`
- 你不需要额外 clone CodexMM
- 你不需要为了 **Manage Sessions** 另外安装 Node
- 浏览器里打开的依然是本地 Web 管理台，而不是原生长列表界面

## 系统要求

- macOS 13 或更高版本
- 可用的本地 Codex 安装：
  - `/Applications` 下的 `Codex.app`，或
  - 已经加入 shell `PATH` 的 `codex` CLI
- 已登录的 Codex 配置文件：`~/.codex/auth.json`

可选：

- CC Switch 的本地数据库：`~/.cc-switch/cc-switch.db`

## 隐私与本地数据

Codex Quota Viewer 是面向本地桌面使用场景设计的。它只读取已经存在于你机器上的
数据，不要求你在 UI 中手动粘贴任何凭据。

应用可能会在可用时读取这些本地来源：

- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.cc-switch/cc-switch.db`
- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`

在额度查看场景下，应用会通过你本地安装的 Codex 以 `app-server` 模式读取账号
状态。

在会话管理场景下：

- bundled 的服务会读取本机 `~/.codex` 会话文件
- 本地索引、snapshot 和审计数据仍保存在 `~/.codex-session-manager`
- Web 管理台只在 `127.0.0.1` 上提供服务

README 中使用的会话管理截图，是从真实界面导出的隐私安全版本：本机路径碎片和
截图元数据都在入库前做了清理。

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

只有从打包后的 `.app` 启动时，开机启动才可用。直接运行 Swift 构建输出的可执行
文件时，这个功能不会生效。

### “Bundled session manager is missing. Rebuild CodexQuotaViewer.app.”

这表示当前启动的应用缺少打包后的 `SessionManager` 资源，或者 bundle 内容不完
整。请重新运行：

```bash
./scripts/build-app.sh
```

然后打开 `dist/CodexQuotaViewer.app`，而不是仅运行裸可执行文件。

### “Session manager could not start because port 4318 is already in use.”

这表示本机已经有其他进程占用了 `4318` 端口。如果那正是一个已经在运行的会话管
理服务，Codex Quota Viewer 可以直接复用它；如果是无关进程，请先停止它，再从
应用里使用 **Manage Sessions**。

### “Failed to read CC Switch data.”

请检查：

- 是否已安装 CC Switch
- `~/.cc-switch/cc-switch.db` 是否存在
- 系统是否提供 `/usr/bin/sqlite3`

如果其中任一条件不满足，Codex Quota Viewer 仍然可以显示当前 Codex 账号，但
不会展示 CC Switch 账号列表。

## 从源码构建

如果你要构建完整的打包应用，请运行：

```bash
./scripts/build-app.sh
```

这个脚本会一次性构建原生 Swift 菜单栏应用和 bundled 的会话管理服务，生成：

```text
dist/CodexQuotaViewer.app
```

如果你只想构建裸可执行文件，可以运行：

```bash
swift build -c release --product CodexQuotaViewer
```

这适合做原生应用开发，但它**不会**包含 bundled 的会话管理资源。要得到可分发
的完整应用，请使用 `./scripts/build-app.sh`。

## 更新 vendored CodexMM

会话管理源码保存在：

```text
Vendor/CodexMM
```

当前 vendored 快照信息和推荐同步流程见：

```text
Vendor/CodexMM/VENDORED.md
```

推荐的同步方式是在保留上游目录结构的前提下，原地覆盖 vendored 目录：

```bash
rsync -a --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude '.DS_Store' \
  /path/to/CodexMM/ Vendor/CodexMM/
```

同步完成后，请重新打包应用，并重新执行相关验证再发布。

## 分发说明

当前 DMG 是一个用于测试的预览版本。它还没有完成面向广泛用户分发所需的
notarization，因此在首次启动时，macOS 可能仍然要求手动放行。

当前 bundled 的私有 Node runtime 是从构建机本地的 Node 安装复制进来的，因此
其 CPU 架构会跟随构建机；在面向更广泛机器分发之前，仍需要进一步完善发布流程。

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

[English](README.md) | 中文

# Codex Quota Viewer

> 当前正式版：`1.0.1`
>
> 1.0.1 更新：
> - Session Manager 只会在你点击 `Refresh` 后扫描本地会话。
> - 自动刷新现在只针对当前账号；已保存账号改为在打开菜单时以有限并发刷新。
> - `.jsonl` provider 检查改为只读首行，减少菜单打开时的卡顿。

一个原生的 macOS 菜单栏应用，让你无需碰终端，就能查看 Codex 额度并管理本地
Codex 会话。

Codex Quota Viewer 把两类日常工作放到了同一个入口里：

- 快速查看当前机器上正在使用的 Codex 账号和额度状态
- 直接管理本机 Codex 会话与运行时切换，包括浏览、恢复、归档、回收站、
  线程修复和安全切换

它以菜单栏工具的形态运行，同时把会话管理服务直接打包进应用，所以最终用户不需
要单独 checkout CodexMM、不需要手动装 Node，也不需要自己启动本地服务。

## 为什么使用 Codex Quota Viewer

- **菜单栏优先**：不用开着一个完整主窗口，也能随时看 Codex 状态
- **额度可见**：标准 Codex 登录可直接看到短周期和每周额度窗口
- **内建账号仓**：把 ChatGPT 和 API 账号直接保存在应用自己的本地账号仓里；
  需要时可一次性导入旧账号数据
- **安全切换**：在 ChatGPT 登录和 API key / 中转配置之间切换时，尽量保
  住本地线程连续性，不需要手动改 `~/.codex`
- **内置会话管理**：从菜单栏直接打开本地会话管理 Web 控制台
- **不需要额外安装会话管理器**：`CodexQuotaViewer.app` 已经自带运行所需内容

## 0.3.0 更新

- 在 **Settings -> General** 中新增全局语言设置，支持
  **Follow System**、**English** 和 **中文**
- 内置的 Session Manager 现在跟随这个全局语言设置，不再在网页里单独切换语言
- 修复会话管理英文界面切换不彻底的问题：官方同步说明、问题列表、
  时间线角色标签、审计动作和已知校验错误都会随界面语言正确切换

## 你可以用它做什么

### Quota Viewer

在菜单栏中，你可以：

- 查看当前由 `~/.codex/auth.json` 表示的 Codex 账号
- 为标准 Codex 登录查看 `5h` 和 `1w` 两个额度窗口
- 一眼看到所有已保存 ChatGPT 账号的额度总览
- 账号很多时仍保持菜单高度可控，完整列表收进 **All Accounts**
- 在没有官方额度数据时，为 API key 配置显示 provider 元信息
- 在应用自己的本地账号仓里保存和管理其他 Codex 账号
- 手动刷新账号状态
- 在菜单栏中切换 Meter 与 Text 两种显示样式

![Codex Quota Viewer 菜单截图](docs/images/menu-screenshot.png)

### 会话管理

通过 **Maintenance -> Open Session Manager**，你可以打开一个随应用打包的本
地 Web 管理台，在里面：

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

Session Manager 现在会跟随 **Settings -> General -> Language** 的全局语言设
置，网页里不再提供单独的语言切换按钮。

### Quota Overview 与安全切换

通过菜单栏里的新布局，你可以：

- 让状态栏继续专注显示当前账号的 `5h / 1w` 剩余额度
- 顶部最多看到 5 行单行账号信息，优先展示绿色可用的 ChatGPT 账号
- 通过 **All Accounts** 查看完整账号列表，按 **Available Quota**、
  **Quota Exhausted**、**API Accounts** 分组；若存在登录或刷新问题，再额外
  显示 **Needs Attention**
- 通过 **Settings… -> Accounts** 在独立账号页里新增账号、查看已保存账号、
  重命名、激活、忘记账号，并一键打开本地账号仓文件夹
- 通过 **Settings… -> General -> Language** 一次切换原生界面和内置
  Session Manager 的语言，支持 **Follow System**、**English**、**中文**
- 点击 **Switch Safely**，让应用自动关闭 Codex、创建 restore point、
  应用 `auth.json` 和合并后的 `config.toml`、重写 rollout 的
  `model_provider`、修复本地官方线程状态，并重新打开 Codex
- 通过 **Maintenance** 进入 **Refresh All**、**Open Session Manager**、
  **Repair Now**、**Rollback Last Change**

安全切换的备份会保存在：

```text
~/Library/Application Support/CodexQuotaViewer/SwitchBackups/
```

每个 restore point 都包含一个 `manifest.json`，以及本次操作涉及文件的保护副
本。

## 会话管理

内置会话管理是 Codex Quota Viewer 从“额度查看工具”升级成“本地 Codex 桌面伴
侣”的关键能力。

你只需要在菜单栏里打开 **Maintenance -> Open Session Manager**。应用会自动
完成后续动作：

- 先检查 `http://127.0.0.1:4318` 上的本地会话管理服务是否已经健康
- 如果服务已经在运行，就直接复用它
- 如果服务尚未运行，就从 `CodexQuotaViewer.app` 内部启动 bundled service
- 等到健康检查通过后，再在默认浏览器里打开管理页面

这个管理台只在本机工作。它绑定在 `127.0.0.1`，管理本机 `~/.codex` 会话文件，
也不要求你单独安装 CodexMM 或 Node。

![会话管理截图（已做隐私安全处理）](docs/images/session-manager-screenshot.png)

### 一条典型使用路径

1. 打开 `CodexQuotaViewer.app`，点击菜单栏图标。
2. 选择 **Maintenance -> Open Session Manager**。
3. 从左侧栏选中一个项目目录。
4. 再选中你想查看或恢复的会话。
5. 查看摘要卡片、完整线程和官方同步状态。
6. 如果你只是想让 Codex 重新识别这条会话，选择 **Resume only**。
7. 如果你想把这条会话永久指向新的工作目录，选择 **Rebind cwd**。
8. 根据需要点击 **Restore to directory**、**Archive current**、
   **Repair this thread**，或者使用顶部批量操作。

### 一条典型安全切换路径

1. 打开菜单栏图标，先看顶部 5 行账号状态。
2. 在顶部账号行或 **All Accounts** 里点选目标账号。
3. 点击 **All Accounts** 下方的 **Switch Safely**，确认弹窗里的切换方向和备
   份范围。
4. 等待应用自动关闭 Codex、创建 restore point、切换运行时配置、
   修复线程元数据并重新打开 Codex。
5. 如果结果不对，打开 **Maintenance**，直接点击
   **Rollback Last Change**。

### 一条典型新增账号路径

1. 打开菜单栏图标。
2. 打开 **Settings…**。
3. 如果你想切换整体语言，先在 **General** 里调整 **Language**；如果你想管理
   账号，再切到 **Accounts** 标签页。
4. 选择 **Sign in with ChatGPT**，或选择 **Add API Account** 保存一个
   OpenAI-compatible API 账号；默认只需要填 API Key 和 Base URL，名称和
   model 可以自动探测。
5. 账号保存完成后，再通过顶部账号行或 **All Accounts** 选中它，然后点击
   **Switch Safely** 激活。

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
2. 点击 **Maintenance -> Open Session Manager**。
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
- 你不需要为了 **Open Session Manager** 另外安装 Node
- 浏览器里打开的依然是本地 Web 管理台，而不是原生长列表界面

## 系统要求

- macOS 13 或更高版本
- 可用的本地 Codex 安装：
  - `/Applications` 下的 `Codex.app`，或
  - 已经加入 shell `PATH` 的 `codex` CLI
- 已登录的 Codex 配置文件：`~/.codex/auth.json`

可选：

- 如果你想把旧账号一次性迁进来，可保留兼容的旧账号工具数据供首次导入读取

## 隐私与本地数据

Codex Quota Viewer 是面向本地桌面使用场景设计的。它会读取已经存在于你机器上的
数据；如果你主动使用 **Add API Account**，也会把你明确输入的 API 凭据保存到应
用自己的本地账号仓中。

应用可能会在可用时读取这些本地来源：

- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/Library/Application Support/CodexQuotaViewer/Accounts/**/*`
- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`
- `~/Library/Application Support/CodexQuotaViewer/SwitchBackups/**/*`

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
应用里使用 **Maintenance -> Open Session Manager**。

### “Imported 0 legacy accounts.”

这是一个信息提示，表示首次兼容导入已经完成，但没有发现可用的旧账号数据。你
仍然可以继续使用当前账号，并直接通过应用里的 **Settings…** 新增账号。

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

本项目现在已经内建本地账号仓和安全切换流程。为了帮助已有用户平滑迁移，它仍然
支持一次性读取旧的
[CC Switch](https://github.com/farion1231/cc-switch)
等兼容数据，但运行时已经不再依赖外部账号切换工具。

## 社区致谢

感谢 [LinuxDo](https://linux.do) 社区的支持。

LinuxDo 是一个讨论技术、AI 前沿和 AI 实战经验的友好社区。像这样的社区能让
Codex Quota Viewer 这类工具更容易被理解、被验证，也更容易持续改进。

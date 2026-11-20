# Pane

[中文](#chinese) · [English](#english)

<a id="chinese"></a>

## 中文

macOS 原生双栏文件管理器。设计目标：外观与苹果原生相融，易用性高于访达。

Pane 把访达式侧边栏、两个完全独立的窗格、标签页、四种视图、空格快速查看、压缩包处理和 SMB 服务器访问整合在一个 Swift 6 / SwiftUI + AppKit 应用里，零第三方依赖。

<img width="2360" height="1600" alt="image" src="https://github.com/user-attachments/assets/226c87c7-5c8b-4830-ae20-fb7f3cec5ade" />

## 💬 联系作者<br>
由 舟午YueMoon 开发。<br>
如果你有任何建议、遇到了 BUG，或者单纯想催更，欢迎在B站/Youtube相关视频的评论区告诉我！<br>
博客：http://yuemoon.vip/<br>
GitHub：@YueMoon99<br>
B站：UID223633562<br>
YouTube：@YueMoon99<br>

### 主要功能

- **四种视图**：图标 / 列表 / 分栏 / 画廊。每个窗格分别记住自己的视图、排序、列宽以及按文件夹保存的视图选项。
- **真正的双栏**：支持横向与纵向切分；两侧各自维护目录、导航历史、选择与分隔条比例。文件拖到另一栏即拷贝，按住 `⌥` 拖动为移动。
- **常驻标签页**：新建、复制、关闭、拖动排序、拖出成窗。关掉最后一个标签页会重置工作区，而不是关掉窗口。
- **快速加载目录**：异步枚举文件系统（自带 1k / 10k / 50k 项目性能基准）。本地卷用 kqueue 实时刷新，网络卷用轻量轮询兜底。
- **缩略图**：QuickLook 缩略图 + 内存 / 磁盘 / 生成三级缓存；白底文件配浅灰底板、描边与轻投影，贴近访达观感；没有真实预览的文件改用系统原生图标。
- **文件操作有反馈**：复制、移动显示按字节计算的进度条与中止按钮；重名自动处理；废纸篓在受保护目录上有兜底方案。
- **快速查看与压缩包**：空格预览文件，方向键切换项目；双击 zip / tar / gz / bz2 / xz 就地解压，也可解压到同名文件夹。
- **SMB 免折腾**：服务器保存在侧边栏，共享列表像文件夹一样浏览，双击才挂载；连接失败会翻译成人话，密码存进钥匙串。
- **外观与语言**：浅色 / 深色 / 跟随系统主题，以及中文 / 英文 / 跟随系统界面语言，均可在设置（⌘,）里即时切换。
- **可编辑地址栏**：点击面包屑栏直接输入路径（支持 `~` 与相对路径）；`⌘C` / `⌘V` 复制粘贴路径。

### 运行要求

- macOS 26.0 或更高版本
- Swift 6（Xcode 工具链）
- 无第三方依赖

Bundle ID：`com.moon.pane`。应用采用 ad-hoc 本地签名，未启用 App Sandbox（需要访达级文件访问与 NetFS 挂载能力）。

### 构建与运行

```bash
git clone <this-repo> Pane
cd Pane

bash Scripts/build.sh          # 构建、打包、签名并启动 build/Pane.app
xed .                          # 用 Xcode 打开，获得预览与调试能力
```

性能基准（自动准备 1k / 10k / 50k 项目的目录）：

```bash
bash Scripts/benchmark.sh                    # release 构建
bash Scripts/benchmark.sh debug ~/Pictures   # debug 构建 + 额外跑一个真实目录
```

### 快捷键

| 快捷键 | 作用 |
|---|---|
| `⌘1` / `⌘2` / `⌘3` | 单栏 / 横向切分 / 纵向切分 |
| `⌘4` | 轮换视图模式（图标 → 列表 → 分栏 → 画廊） |
| `⌘T` / `⇧⌘T` | 新建标签页 / 复制当前标签页 |
| `⌘W` | 关闭标签页（剩最后一个时重置工作区） |
| `⌃⇥` / `⌃⇧⇥` | 下一个 / 上一个标签页 |
| `⌘J` | 视图选项（按文件夹记忆） |
| `⌘+` / `⌘-` | 图标放大 / 缩小 |
| `⌘[` / `⌘]` / `⌘↑` | 后退 / 前进 / 上一层 |
| `⌘R` | 刷新当前目录（在共享列表里会重新枚举 SMB 共享） |
| `↩` / `Esc` | 行内重命名 / 取消 |
| `空格` | 快速查看（方向键翻页，`空格` 或 `Esc` 关闭） |
| `↑ ↓ ← →` | 移动选择；分栏视图里 `←` / `→` 切换层级 |
| 首字母 | 跳转到以该字母开头的项目 |
| `⌘C` / `⌘X` / `⌘V` | 拷贝 / 剪切 / 粘贴（可与访达互传） |
| `⌘A` / `⇧⌘A` / `⇧⌘I` | 全选 / 取消选择 / 反选 |
| `⌘⌫` / `⌥⌘⌫` | 移到废纸篓 / 直接删除（二次确认） |
| `⇧⌘N` / `⌥⌘C` | 新建文件夹 / 复制所选路径 |
| `⌘⌥←` / `⌘⌥→` | 切换焦点到左/上或右/下栏 |
| `⌃⌘→` / `⌃⌘⇧→` | 拷贝 / 移动到另一栏 |
| `⌃⌘↑` | 让另一栏同步到本栏当前目录 |

### 项目结构

```
Pane/
├─ Package.swift
├─ Sources/PaneApp/
│  ├─ PaneApp.swift              # @main、窗口、Settings 场景
│  ├─ Core/                      # 状态、文件系统、缩略图、SMB、命令表、
│  │                             # 导航、本地化、目录监听、诊断工具
│  └─ UI/                        # 侧边栏、标签栏、窗格、地址栏、四种视图、
│                                # 设置、快速查看、传输进度面板
├─ Resources/AppIcon.icns
├─ Scripts/                       # build.sh、benchmark.sh、make_icon.swift
├─ docs/                          # 设计文档
└─ IMG.png                        # 本 README 使用的界面截图
```

### 补充说明

- 首次访问桌面、文稿、下载等受保护目录时，需在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中授权 Pane。
- 界面语言默认为「跟随系统」，需要固定中文或英文时在设置里改；主题同理。
- 网络卷缩略图默认关闭：SMB 上生成一张缩略图就要完整读一遍文件，容易把带宽吃满；确有需要再到设置里打开。
- 网络卷的目录变化由约 2 秒一次的 stat 比对和约 12 秒一次的文件名比对兜底；隐藏的标签页和退到后台时会暂停轮询，避免无谓流量。
- 诊断日志：`/tmp/pane-debug.log`（通用）、`/tmp/pane-smb.log`（SMB）。命令行还支持 `Pane --self-check`、`--dump-menus`、`--dump-commands` 与 `--bench <dir>`。

### 设计文档

`docs/00-总览.md` · `docs/01-可行性分析与技术选型.md` · `docs/02-架构设计.md` · `docs/03-UI设计与交互规范.md` · `docs/04-路线图与里程碑.md`

---

<a id="english"></a>

## English

A native dual-pane file manager for macOS, built to feel at home next to Finder while getting out of your way faster.

Pane combines a Finder-like sidebar, two fully independent panes, tabs, four view modes, Quick Look preview, archive handling and SMB server access in one Swift 6 / SwiftUI + AppKit app — with no third-party dependencies.

<img width="2360" height="1600" alt="image" src="https://github.com/user-attachments/assets/559f5244-e58f-4576-9911-ef426a54352d" />

## 💬 Contact<br>
Blog：http://yuemoon.vip/<br>
GitHub：@YueMoon99<br>
Blibili：UID223633562<br>
YouTube：@YueMoon99<br>

### Highlights

- **Four view modes** — Icons, List, Columns and Gallery. Each pane remembers its own mode, sort order, column widths and folder-specific view options.
- **Real dual panes** — Horizontal or vertical split; each side keeps its own directory, navigation history, selection and layout ratio. Drag files between panes to copy, hold `⌥` to move.
- **Tabs that stay** — New, duplicate, close, reorder by drag, or tear off into a separate window. Closing the last tab resets the workspace instead of quitting the window.
- **Fast directory loading** — Asynchronous filesystem enumeration (1k / 10k / 50k items benchmark included). Local folders refresh through kqueue; network volumes use lightweight polling as a fallback.
- **Thumbnails done right** — QuickLook thumbnails with a three-level cache (memory / disk / generation), Finder-style light plate, outline and shadow for white-background files. Files without a real preview fall back to a native system icon.
- **File operations with feedback** — Copy and move show byte-level progress with a cancel button; duplicate names are handled automatically; trash has a fallback for protected folders.
- **Quick Look and archives** — `Space` previews files (arrow keys page through the selection). Double-click zip / tar / gz / bz2 / xz to extract in place, or extract into a same-named folder.
- **SMB without the boilerplate** — Save servers in the sidebar, browse shares like a folder, double-click to mount, and let Pane translate connection failures into plain language. Credentials go to the Keychain.
- **Appearance and language** — Light, Dark or Follow System theme, plus Chinese, English or Follow System UI language. Both can be switched live in Settings (⌘,).
- **Editable path bar** — Click the breadcrumb bar to type a path (`~` and relative paths work); `⌘C` / `⌘V` copy and paste paths.

### Requirements

- macOS 26.0 or later
- Swift 6 (Xcode toolchain)
- No third-party packages

Bundle ID: `com.moon.pane`. The app is ad-hoc signed and is not sandboxed (it needs Finder-level file access and NetFS mounting).

### Build & Run

```bash
git clone <this-repo> Pane
cd Pane

bash Scripts/build.sh          # build, package, sign and launch build/Pane.app
xed .                          # open in Xcode for previews and debugging
```

Performance benchmark (prepares 1k / 10k / 50k-item directories automatically):

```bash
bash Scripts/benchmark.sh                    # release build
bash Scripts/benchmark.sh debug ~/Pictures   # debug build + an extra real directory
```

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘1` / `⌘2` / `⌘3` | Single pane / horizontal split / vertical split |
| `⌘4` | Cycle view modes (Icons → List → Columns → Gallery) |
| `⌘T` / `⇧⌘T` | New tab / duplicate tab |
| `⌘W` | Close tab (resets the workspace when it is the last one) |
| `⌃⇥` / `⌃⇧⇥` | Next / previous tab |
| `⌘J` | View options (remembered per folder) |
| `⌘+` / `⌘-` | Zoom icons in / out |
| `⌘[` / `⌘]` / `⌘↑` | Back / forward / up |
| `⌘R` | Refresh the current folder (also re-enumerates SMB shares) |
| `↩` / `Esc` | Rename selected item / cancel |
| `Space` | Quick Look (arrows navigate, `Space` or `Esc` closes) |
| `↑ ↓ ← →` | Move selection; `←` / `→` also change level in Columns |
| Letter key | Jump to the first item starting with that letter |
| `⌘C` / `⌘X` / `⌘V` | Copy / cut / paste (interoperates with Finder) |
| `⌘A` / `⇧⌘A` / `⇧⌘I` | Select all / deselect / invert selection |
| `⌘⌫` / `⌥⌘⌫` | Move to Trash / delete permanently (with confirmation) |
| `⇧⌘N` / `⌥⌘C` | New folder / copy selected paths |
| `⌘⌥←` / `⌘⌥→` | Focus left/top or right/bottom pane |
| `⌃⌘→` / `⌃⌘⇧→` | Copy / move to the other pane |
| `⌃⌘↑` | Point the other pane at this pane's directory |

### Project layout

```
Pane/
├─ Package.swift
├─ Sources/PaneApp/
│  ├─ PaneApp.swift              # @main, scenes, Settings
│  ├─ Core/                      # state, filesystem, thumbnails, SMB, commands,
│  │                             # navigation, localization, watchers, diagnostics
│  └─ UI/                        # sidebar, tabs, panes, path bar, four view modes,
│                                # settings, Quick Look, transfer HUD
├─ Resources/AppIcon.icns
├─ Scripts/                       # build.sh, benchmark.sh, make_icon.swift
├─ docs/                          # design documents (Chinese)
└─ IMG.png                        # screenshot used by this README
```

### Good to know

- On first access to Desktop, Documents or Downloads, grant Pane **Full Disk Access** in *System Settings → Privacy & Security*.
- UI language defaults to **Follow System**; set Chinese / English explicitly in Settings if needed. The same applies to the theme.
- Thumbnails on network volumes are off by default: SMB thumbnails require reading whole files, which can saturate a connection. Enable the switch in Settings when you need them.
- Directory changes on network volumes are detected by a ~2 s stat poll plus a ~12 s filename comparison; hidden tabs and background apps pause polling to avoid needless traffic.
- Diagnostics: `/tmp/pane-debug.log` (general), `/tmp/pane-smb.log` (SMB). `Pane --self-check`, `--dump-menus`, `--dump-commands` and `--bench <dir>` are available from the terminal.

### Design documents

`docs/00-总览.md` · `docs/01-可行性分析与技术选型.md` · `docs/02-架构设计.md` · `docs/03-UI设计与交互规范.md` · `docs/04-路线图与里程碑.md` (Chinese).

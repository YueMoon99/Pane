import SwiftUI
import AppKit

// MARK: - 菜单栏（全部由命令表生成）

struct PaneCommands: Commands {
    @FocusedValue(\.workspace) private var workspace: AppState?

    var body: some Commands {
        // 文件菜单：新建 / 打开 / 删除
        CommandGroup(replacing: .newItem) {
            CommandList(app: workspace, ids: ["newFolder", "newDocument", "open", "-", "trash", "deleteNow"])
        }
        // 编辑菜单：剪贴板与选择（替掉系统默认的那几项，语义统一到命令表）
        CommandGroup(replacing: .pasteboard) {
            CommandList(app: workspace, ids: ["copy", "cut", "paste", "-", "selectAll", "deselect", "invert"])
        }
        // 显示菜单：视图模式 / 排序 / 视图选项 / 状态开关 / 缩放 / 刷新
        CommandGroup(replacing: .sidebar) {
            CommandList(app: workspace, ids: [
                "cycleViewMode", "-",
                "viewIcon", "viewList", "viewColumn", "viewGallery",
                "-", "viewOptions", "-",
                "toggleHidden", "togglePathBar", "toggleStatusBar",
                "-", "zoomIn", "zoomOut", "-", "refresh"
            ])
            if workspace != nil {
                Divider()
                Menu(L10n.tr("排序方式")) { SortMenuContents(app: workspace) }
            }
        }
        CommandMenu(L10n.tr("前往")) {
            CommandList(app: workspace, ids: ["back", "forward", "up", "-", "home", "desktop", "documents", "downloads"])
        }
        CommandMenu(L10n.tr("切分")) {
            CommandList(app: workspace, ids: [
                "layoutSingle", "layoutHorizontal", "layoutVertical",
                "-", "focusPrimary", "focusSecondary",
                "-", "copyToOther", "moveToOther", "syncOther"
            ])
        }
        CommandMenu(L10n.tr("标签页")) {
            CommandList(app: workspace, ids: [
                "newTab", "duplicateTab", "closeTab", "closeOtherTabs",
                "-", "nextTab", "prevTab", "-", "detachTab"
            ])
        }
        CommandMenu(L10n.tr("操作")) {
            CommandList(app: workspace, ids: [
                "rename", "quickLook", "-",
                "terminal", "reveal", "copyPath", "-",
                "bookmarkCurrentFolder", "-",
                "compress", "extract", "extractToFolder", "hash"
            ])
        }
    }
}

/// 按 id 批量生成菜单项；"-" 表示分隔线
struct CommandList: View {
    let app: AppState?
    let ids: [String]

    var body: some View {
        ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
            if id == "-" {
                Divider()
            } else if let command = CommandBus.command(id: id) {
                CommandMenuItem(command: command, app: app)
            }
        }
    }
}

/// 单个菜单项：标题 / 图标 / 快捷键 / 置灰都来自命令定义
struct CommandMenuItem: View {
    let command: AppCommand
    let app: AppState?

    var body: some View {
        if let app {
            let context = CommandContext.build(app)
            if let isOn = command.isOn {
                Toggle(L10n.tr(command.title(in: context)), isOn: Binding(
                    get: { isOn(context) },
                    set: { _ in CommandBus.perform(command, on: app) }
                ))
            } else {
                Button {
                    CommandBus.perform(command, on: app)
                } label: {
                    Label(L10n.tr(command.title(in: context)), systemImage: command.symbol)
                }
                .optionalShortcut(command.shortcut)
                .disabled(!command.isEnabled(context))
            }
        } else {
            // 没有窗口（焦点值缺失）时保持可见但不可用
            Button(L10n.tr(command.title)) {}
                .optionalShortcut(command.shortcut)
                .disabled(true)
        }
    }
}

extension View {
    /// 没有快捷键的命令不加修饰符
    @ViewBuilder
    func optionalShortcut(_ combo: KeyCombo?) -> some View {
        if let combo {
            keyboardShortcut(combo.keyEquivalent, modifiers: combo.eventModifiers)
        } else {
            self
        }
    }
}

// MARK: - 排序子菜单
//
// 菜单栏「显示」、工具栏「操作」、右键空白处共用这一份：
// 排序是每个窗格独立的设置，这里改的是**焦点窗格**的排序；
// 选字段 = 升序排（再点同字段反向），「升序」开关直接定方向。

struct SortMenuContents: View {
    let app: AppState?

    var body: some View {
        if let app {
            Picker(L10n.tr("排序字段"), selection: Binding(
                get: { app.focused.sort.field },
                set: { app.setSortField($0) }
            )) {
                ForEach(SortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle(L10n.tr("升序"), isOn: Binding(
                get: { app.focused.sort.ascending },
                set: { app.setSortAscending($0) }
            ))
        }
    }
}

// MARK: - 右键菜单

/// 右键菜单的两种形态：点在项目上 / 点在空白处。
/// 内容仍然来自命令表，只是挑不同的子集与顺序。
struct PaneContextMenu: View {
    @Environment(AppState.self) private var app
    /// nil 表示空白处
    let item: FileItem?
    /// 列视图里点击的是某一列的行，选中态由列自己维护
    var onOpenItem: ((FileItem) -> Void)?

    var body: some View {
        let context = CommandContext.build(app)
        if let item {
            itemMenu(item, context: context)
        } else {
            blankMenu(context: context)
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: FileItem, context: CommandContext) -> some View {
        if let onOpenItem {
            Button(L10n.tr("打开")) { onOpenItem(item) }
            Divider()
        } else {
            CommandMenuItem(command: requireCommand("open"), app: app)
        }
        CommandMenuItem(command: requireCommand("reveal"), app: app)
        CommandMenuItem(command: requireCommand("copyPath"), app: app)
        Divider()
        // 重命名 / 快速查看：与访达一致，紧跟在「打开」之后
        if !item.isShare && !context.isServerRoot {
            CommandMenuItem(command: requireCommand("rename"), app: app)
            CommandMenuItem(command: requireCommand("quickLook"), app: app)
            Divider()
        }
        CommandMenuItem(command: requireCommand("compress"), app: app)
        if context.selectionHasExtractable {
            CommandMenuItem(command: requireCommand("extract"), app: app)
            CommandMenuItem(command: requireCommand("extractToFolder"), app: app)
        }
        CommandMenuItem(command: requireCommand("hash"), app: app)
        Divider()
        // 只有选中的是文件夹时才有意义（文件不能当书签）
        if !context.selectionDirectories.isEmpty {
            CommandMenuItem(command: requireCommand("addBookmark"), app: app)
            Divider()
        }
        CommandMenuItem(command: requireCommand("copy"), app: app)
        CommandMenuItem(command: requireCommand("cut"), app: app)
        Divider()
        if context.isSplit {
            CommandMenuItem(command: requireCommand("copyToOther"), app: app)
            CommandMenuItem(command: requireCommand("moveToOther"), app: app)
            Divider()
        }
        CommandMenuItem(command: requireCommand("trash"), app: app)
        CommandMenuItem(command: requireCommand("deleteNow"), app: app)
    }

    @ViewBuilder
    private func blankMenu(context: CommandContext) -> some View {
        CommandMenuItem(command: requireCommand("newFolder"), app: app)
        CommandMenuItem(command: requireCommand("newDocument"), app: app)
        Divider()
        CommandMenuItem(command: requireCommand("paste"), app: app)
        Divider()
        CommandMenuItem(command: requireCommand("selectAll"), app: app)
        CommandMenuItem(command: requireCommand("deselect"), app: app)
        Divider()
        CommandMenuItem(command: requireCommand("cycleViewMode"), app: app)
        Menu(L10n.tr("排序方式")) { SortMenuContents(app: app) }
        CommandMenuItem(command: requireCommand("viewOptions"), app: app)
        CommandMenuItem(command: requireCommand("toggleHidden"), app: app)
        Divider()
        CommandMenuItem(command: requireCommand("bookmarkCurrentFolder"), app: app)
        Divider()
        CommandMenuItem(command: requireCommand("terminal"), app: app)
        CommandMenuItem(command: requireCommand("refresh"), app: app)
    }

    /// 命令表里一定有这些 id；万一被删掉，用占位命令避免菜单结构错乱
    private func requireCommand(_ id: String) -> AppCommand {
        CommandBus.command(id: id)
            ?? AppCommand(id, id, "questionmark", group: .file, run: { _ in })
    }
}

extension View {
    /// 给文件单元 / 空白区域挂上统一的右键菜单
    func paneContextMenu(item: FileItem?, onOpen: ((FileItem) -> Void)? = nil) -> some View {
        contextMenu {
            PaneContextMenu(item: item, onOpenItem: onOpen)
        }
    }
}

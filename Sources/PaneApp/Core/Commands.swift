import SwiftUI
import AppKit

// MARK: - 快捷键描述
//
// 一条命令的快捷键只在这里定义一次：菜单栏用它生成 NSMenuItem 的等价键，
// 按键路由用它匹配 NSEvent，右键菜单也用它显示提示。
// 匹配按键码而不是字符：中文/非美式布局下字符会变，键码不变；
// 万一没匹配上，事件会继续走菜单的等价键，结果一致。
@MainActor
struct KeyCombo {
    /// 菜单里显示用的字符（"t"、"["、"1"…）
    let character: String
    /// 匹配用键码
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(_ character: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) {
        self.character = character
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == modifiers && event.keyCode == keyCode
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(character))
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    /// 菜单标题里的快捷键提示（右键菜单用）
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch character {
        case "\r": text += "↩"
        case "\t": text += "⇥"
        default: text += character.uppercased()
        }
        return text
    }
}

// MARK: - 命令分组（决定它出现在哪个菜单）

enum CommandSection: String, CaseIterable {
    case file, edit, view, go, pane, tab
}

// MARK: - 命令可用性上下文
//
// 菜单的置灰、右键菜单的裁剪都只看这一个结构，
// 不再让每个入口各自判断「现在能不能拷 / 能不能切」。

@MainActor
struct CommandContext {
    var selectionCount = 0
    var selectionHasDirectory = false
    var selectionHasExtractable = false
    var layout: PaneLayout = .single
    var tabCount = 1
    var canPaste = false
    var canGoBack = false
    var canGoForward = false
    var canGoUp = false
    var viewMode: ViewMode = .icon
    var showHidden = false
    var showPathBar = true
    var showStatusBar = true
    /// 焦点在地址栏等文本框里：拷贝/剪切/粘贴要让位给文本编辑
    var editingText = false
    /// 只选中一个压缩包时，它对应的文件夹名（「解压到“名字”」的标题要用）
    var archiveFolderName: String?
    /// 当前停在服务器共享列表：这一屏没有可写的本地路径，文件类命令一律置灰
    var isServerRoot = false
    /// 选中的文件夹（「添加到书签」的目标）
    var selectionDirectories: [URL] = []
    /// 当前窗格所在位置
    var currentURL: URL?
    /// 只选中一个项目时它的名字（「重命名“xxx”」的标题要用）
    var selectionName: String?

    var hasSelection: Bool { selectionCount > 0 }
    var isSplit: Bool { layout != .single }
    /// 能对选择做文件操作：有选择，且不在虚拟的共享列表里
    var canOperateOnSelection: Bool { selectionCount > 0 && !isServerRoot }
    /// 当前目录能不能加进书签（共享列表这类虚拟位置不行）
    var canBookmarkCurrentFolder: Bool { !isServerRoot && currentURL?.isFileURL == true }

    static func build(_ app: AppState) -> CommandContext {
        let pane = app.focused
        let urls = pane.selectedURLs()
        let files = urls.filter(\.isFileURL)
        let archives = files.filter { ArchiveService.canExtract($0) }
        return CommandContext(
            selectionCount: urls.count,
            selectionHasDirectory: files.contains(where: isDirectory),
            selectionHasExtractable: archives.count > 0,
            layout: app.paneLayout,
            tabCount: app.tabs.count,
            canPaste: pane.url.isFileURL && NSPasteboard.general.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ),
            canGoBack: !pane.backStack.isEmpty,
            canGoForward: !pane.forwardStack.isEmpty,
            canGoUp: pane.url.parent != nil,
            viewMode: app.viewMode,
            showHidden: app.showHidden,
            showPathBar: app.showPathBar,
            showStatusBar: app.showStatusBar,
            editingText: app.isEditingText,
            archiveFolderName: archives.count == 1 ? ArchiveService.folderName(for: archives[0]) : nil,
            isServerRoot: pane.isServerRoot,
            selectionDirectories: files.filter(isDirectory),
            currentURL: pane.url,
            selectionName: urls.count == 1 ? pane.selectedItems().first?.name ?? urls[0].lastPathComponent : nil
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - 一条命令

@MainActor
struct AppCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let group: CommandSection
    let shortcut: KeyCombo?
    /// 开关类命令：菜单里画成带勾选的 Toggle
    let isOn: ((CommandContext) -> Bool)?
    /// 标题随选择变化（例如「解压到“Photos”」），为 nil 时用固定标题
    let dynamicTitle: ((CommandContext) -> String)?
    let isEnabled: (CommandContext) -> Bool
    let run: (AppState) -> Void

    init(
        _ id: String,
        _ title: String,
        _ symbol: String,
        group: CommandSection,
        shortcut: KeyCombo? = nil,
        isOn: ((CommandContext) -> Bool)? = nil,
        dynamicTitle: ((CommandContext) -> String)? = nil,
        enabled: @escaping (CommandContext) -> Bool = { _ in true },
        run: @escaping (AppState) -> Void
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.group = group
        self.shortcut = shortcut
        self.isOn = isOn
        self.dynamicTitle = dynamicTitle
        self.isEnabled = enabled
        self.run = run
    }

    /// 菜单里显示的标题
    func title(in context: CommandContext) -> String {
        dynamicTitle?(context) ?? title
    }
}

// MARK: - 命令表
//
// 全应用唯一的命令清单：菜单栏、快捷键、右键菜单都从这里取。
// 顺序即菜单里的顺序。

@MainActor
enum CommandCatalog {
    static let all: [AppCommand] = file + edit + view + go + pane + tab

    private static var file: [AppCommand] {
        [
            AppCommand("newFolder", "新建文件夹", "folder.badge.plus", group: .file,
                       shortcut: KeyCombo("n", keyCode: 45, [.command, .shift]),
                       enabled: { !$0.isServerRoot },
                       run: { $0.createFolder() }),
            AppCommand("newDocument", "新建文件", "doc.badge.plus", group: .file,
                       enabled: { !$0.isServerRoot },
                       run: { $0.createDocument() }),
            AppCommand("open", "打开", "arrow.up.forward.app", group: .file,
                       shortcut: KeyCombo("o", keyCode: 31, [.command]),
                       enabled: { $0.hasSelection },
                       run: { $0.openSelection() }),
            // 回车是它的快捷键，但只登记在按键路由里（handleKey）：
            // 菜单项带无修饰键的 ↩ 会抢走输入框里的回车。
            AppCommand("rename", "重命名", "pencil", group: .file,
                       dynamicTitle: { context in
                           guard context.selectionCount == 1, let name = context.selectionName else {
                               return "重命名"
                           }
                           return "重命名“\(name)”"
                       },
                       enabled: { $0.selectionCount == 1 && !$0.isServerRoot && !$0.editingText },
                       run: { $0.beginRename() }),
            // 空格同理：只在按键路由里登记
            AppCommand("quickLook", "快速查看", "doc.text.magnifyingglass", group: .file,
                       enabled: { $0.canOperateOnSelection && !$0.editingText },
                       run: { $0.togglePreview() }),
            AppCommand("trash", "移到废纸篓", "trash", group: .file,
                       shortcut: KeyCombo("⌫", keyCode: 51, [.command]),
                       enabled: { $0.canOperateOnSelection },
                       run: { $0.trashSelection() }),
            AppCommand("deleteNow", "直接删除…", "trash.slash", group: .file,
                       shortcut: KeyCombo("⌫", keyCode: 51, [.command, .option]),
                       enabled: { $0.canOperateOnSelection },
                       run: { $0.requestPermanentDelete() }),

            // 操作类（独立菜单）：作用于选择，无选择时作用于当前目录
            AppCommand("terminal", "在终端中打开", "terminal", group: .file,
                       enabled: { !$0.isServerRoot },
                       run: { $0.openInTerminal() }),
            AppCommand("reveal", "在访达中显示", "finder", group: .file,
                       enabled: { $0.canOperateOnSelection },
                       run: { $0.revealInFinder() }),
            AppCommand("copyPath", "复制路径", "doc.on.doc", group: .file,
                       shortcut: KeyCombo("c", keyCode: 8, [.command, .option]),
                       enabled: { !$0.isServerRoot },
                       run: { $0.copySelectedPath() }),
            AppCommand("compress", "压缩", "archivebox", group: .file,
                       enabled: { $0.canOperateOnSelection },
                       run: { $0.compressSelection() }),
            AppCommand("extract", "解压到当前文件夹", "tray.and.arrow.down", group: .file,
                       enabled: { $0.selectionHasExtractable },
                       run: { $0.extractSelectedArchives() }),
            AppCommand("extractToFolder", "解压到同名文件夹", "folder", group: .file,
                       dynamicTitle: { context in
                           guard let name = context.archiveFolderName else {
                               return "解压到同名文件夹"
                           }
                           return "解压到“\(name)”"
                       },
                       enabled: { $0.selectionHasExtractable },
                       run: { $0.extractSelectedArchives(intoNamedFolders: true) }),
            AppCommand("hash", "计算哈希值", "number", group: .file,
                       enabled: { $0.canOperateOnSelection },
                       run: { $0.calculateHashes() }),

            // 书签：右键文件夹即可固定到侧边栏
            AppCommand("addBookmark", "添加到书签", "bookmark", group: .file,
                       dynamicTitle: { context in
                           guard context.selectionDirectories.count == 1,
                                 let name = context.selectionDirectories.first?.lastPathComponent,
                                 !name.isEmpty else { return "添加到书签" }
                           return "将“\(name)”添加到书签"
                       },
                       enabled: { !$0.isServerRoot && !$0.selectionDirectories.isEmpty },
                       run: { $0.addSelectedFoldersToBookmarks() }),
            AppCommand("bookmarkCurrentFolder", "添加当前文件夹到书签", "bookmark", group: .file,
                       enabled: { $0.canBookmarkCurrentFolder },
                       run: { $0.addCurrentFolderToBookmark() }),
        ]
    }

    private static var edit: [AppCommand] {
        [
            AppCommand("copy", "拷贝", "doc.on.doc", group: .edit,
                       shortcut: KeyCombo("c", keyCode: 8, [.command]),
                       enabled: { $0.canOperateOnSelection || $0.editingText },
                       run: { app in
                           if app.forwardToTextEditor(#selector(NSText.copy(_:))) { return }
                           app.copySelection()
                       }),
            AppCommand("cut", "剪切", "scissors", group: .edit,
                       shortcut: KeyCombo("x", keyCode: 7, [.command]),
                       enabled: { $0.canOperateOnSelection || $0.editingText },
                       run: { app in
                           if app.forwardToTextEditor(#selector(NSText.cut(_:))) { return }
                           app.cutSelection()
                       }),
            AppCommand("paste", "粘贴", "doc.on.clipboard", group: .edit,
                       shortcut: KeyCombo("v", keyCode: 9, [.command]),
                       enabled: { $0.canPaste || $0.editingText },
                       run: { app in
                           if app.forwardToTextEditor(#selector(NSText.paste(_:))) { return }
                           app.paste()
                       }),
            AppCommand("selectAll", "全选", "checkmark.circle", group: .edit,
                       shortcut: KeyCombo("a", keyCode: 0, [.command]),
                       run: { app in
                           if app.forwardToTextEditor(#selector(NSText.selectAll(_:))) { return }
                           app.focused.selectAll()
                       }),
            AppCommand("deselect", "取消选择", "circle.dashed", group: .edit,
                       shortcut: KeyCombo("a", keyCode: 0, [.command, .shift]),
                       enabled: { $0.hasSelection },
                       run: { $0.focused.clearSelection() }),
            AppCommand("invert", "反选", "arrow.triangle.2.circlepath", group: .edit,
                       shortcut: KeyCombo("i", keyCode: 34, [.command, .shift]),
                       run: { $0.focused.invertSelection() }),
        ]
    }

    private static var view: [AppCommand] {
        [
            // ⌘4：一格一格往下轮换，不用记「图标是哪个数字」
            AppCommand("cycleViewMode", "切换显示模式", "arrow.triangle.2.circlepath", group: .view,
                       shortcut: KeyCombo("4", keyCode: 21, [.command]),
                       run: { $0.cycleViewMode() }),
            AppCommand("viewIcon", "图标", "square.grid.2x2", group: .view,
                       run: { $0.viewMode = .icon }),
            AppCommand("viewList", "列表", "list.bullet", group: .view,
                       run: { $0.viewMode = .list }),
            AppCommand("viewColumn", "分栏", "rectangle.split.3x1", group: .view,
                       run: { $0.viewMode = .column }),
            AppCommand("viewGallery", "画廊", "rectangle.on.rectangle", group: .view,
                       run: { $0.viewMode = .gallery }),
            AppCommand("viewOptions", "视图选项…", "slider.horizontal.3", group: .view,
                       shortcut: KeyCombo("j", keyCode: 38, [.command]),
                       run: { $0.showViewOptions = true }),
            AppCommand("toggleHidden", "显示隐藏文件", "eye", group: .view,
                       shortcut: KeyCombo(".", keyCode: 47, [.command, .shift]),
                       isOn: { $0.showHidden },
                       run: { $0.showHidden.toggle() }),
            AppCommand("togglePathBar", "显示路径栏", "point.topleft.down.curvedto.point.bottomright.up", group: .view,
                       shortcut: KeyCombo("p", keyCode: 35, [.command, .option]),
                       isOn: { $0.showPathBar },
                       run: { $0.showPathBar.toggle() }),
            AppCommand("toggleStatusBar", "显示状态栏", "rectangle.bottomthird.inset.filled", group: .view,
                       shortcut: KeyCombo("/", keyCode: 44, [.command, .option]),
                       isOn: { $0.showStatusBar },
                       run: { $0.showStatusBar.toggle() }),
            AppCommand("zoomIn", "放大图标", "plus.magnifyingglass", group: .view,
                       shortcut: KeyCombo("+", keyCode: 24, [.command]),
                       run: { $0.zoomIcons(up: true) }),
            AppCommand("zoomOut", "缩小图标", "minus.magnifyingglass", group: .view,
                       shortcut: KeyCombo("-", keyCode: 27, [.command]),
                       run: { $0.zoomIcons(up: false) }),
            AppCommand("refresh", "刷新", "arrow.clockwise", group: .view,
                       shortcut: KeyCombo("r", keyCode: 15, [.command]),
                       run: { $0.refresh() }),
        ]
    }

    private static var go: [AppCommand] {
        [
            AppCommand("back", "后退", "chevron.left", group: .go,
                       shortcut: KeyCombo("[", keyCode: 33, [.command]),
                       enabled: { $0.canGoBack },
                       run: { $0.focused.back() }),
            AppCommand("forward", "前进", "chevron.right", group: .go,
                       shortcut: KeyCombo("]", keyCode: 30, [.command]),
                       enabled: { $0.canGoForward },
                       run: { $0.focused.forward() }),
            AppCommand("up", "上一层", "arrow.up", group: .go,
                       shortcut: KeyCombo("↑", keyCode: 126, [.command]),
                       enabled: { $0.canGoUp },
                       run: { $0.goUp() }),
            AppCommand("home", "主目录", "house", group: .go,
                       shortcut: KeyCombo("h", keyCode: 4, [.command, .shift]),
                       run: { $0.focused.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }),
            AppCommand("desktop", "桌面", "desktopcomputer", group: .go,
                       shortcut: KeyCombo("d", keyCode: 2, [.command, .shift]),
                       run: { $0.go(to: .desktopDirectory) }),
            AppCommand("documents", "文稿", "doc", group: .go,
                       shortcut: KeyCombo("o", keyCode: 31, [.command, .shift]),
                       run: { $0.go(to: .documentDirectory) }),
            AppCommand("downloads", "下载", "arrow.down.circle", group: .go,
                       shortcut: KeyCombo("l", keyCode: 37, [.command, .option]),
                       run: { $0.go(to: .downloadsDirectory) }),
        ]
    }

    private static var pane: [AppCommand] {
        [
            AppCommand("layoutSingle", "单栏", "square", group: .pane,
                       shortcut: KeyCombo("1", keyCode: 18, [.command]),
                       run: { $0.paneLayout = .single }),
            AppCommand("layoutHorizontal", "横向切分", "rectangle.split.2x1", group: .pane,
                       shortcut: KeyCombo("2", keyCode: 19, [.command]),
                       run: { $0.paneLayout = .horizontal }),
            AppCommand("layoutVertical", "纵向切分", "rectangle.split.1x2", group: .pane,
                       shortcut: KeyCombo("3", keyCode: 20, [.command]),
                       run: { $0.paneLayout = .vertical }),
            AppCommand("focusPrimary", "切到左/上栏", "arrow.left.to.line", group: .pane,
                       shortcut: KeyCombo("←", keyCode: 123, [.command, .option]),
                       enabled: { $0.isSplit },
                       run: { $0.focusPane(.primary) }),
            AppCommand("focusSecondary", "切到右/下栏", "arrow.right.to.line", group: .pane,
                       shortcut: KeyCombo("→", keyCode: 124, [.command, .option]),
                       enabled: { $0.isSplit },
                       run: { $0.focusPane(.secondary) }),
            AppCommand("copyToOther", "拷贝到另一栏", "doc.on.doc", group: .pane,
                       shortcut: KeyCombo("→", keyCode: 124, [.command, .control]),
                       enabled: { $0.isSplit && $0.canOperateOnSelection },
                       run: { $0.transferSelectionToOtherPane(move: false) }),
            AppCommand("moveToOther", "移动到另一栏", "arrow.right.doc.on.clipboard", group: .pane,
                       shortcut: KeyCombo("→", keyCode: 124, [.command, .control, .shift]),
                       enabled: { $0.isSplit && $0.canOperateOnSelection },
                       run: { $0.transferSelectionToOtherPane(move: true) }),
            AppCommand("syncOther", "用另一栏同目录", "arrow.left.arrow.right", group: .pane,
                       shortcut: KeyCombo("↑", keyCode: 126, [.command, .control]),
                       enabled: { $0.isSplit },
                       run: { $0.syncOtherPaneToFocused() }),
        ]
    }

    private static var tab: [AppCommand] {
        [
            AppCommand("newTab", "新建标签页", "plus.square", group: .tab,
                       shortcut: KeyCombo("t", keyCode: 17, [.command]),
                       run: { $0.newTab() }),
            AppCommand("duplicateTab", "复制标签页", "plus.square.on.square", group: .tab,
                       shortcut: KeyCombo("t", keyCode: 17, [.command, .shift]),
                       run: { $0.duplicateActiveTab() }),
            AppCommand("closeTab", "关闭标签页", "xmark.square", group: .tab,
                       shortcut: KeyCombo("w", keyCode: 13, [.command]),
                       run: { $0.closeActiveTab() }),
            AppCommand("closeOtherTabs", "关闭其他标签页", "square.stack.3d.down.right", group: .tab,
                       enabled: { $0.tabCount > 1 },
                       run: { $0.closeOtherTabs(keeping: $0.activeTabID) }),
            AppCommand("nextTab", "下一个标签页", "chevron.forward.square", group: .tab,
                       shortcut: KeyCombo("\t", keyCode: 48, [.control]),
                       run: { $0.selectTab(offset: 1) }),
            AppCommand("prevTab", "上一个标签页", "chevron.backward.square", group: .tab,
                       shortcut: KeyCombo("\t", keyCode: 48, [.control, .shift]),
                       run: { $0.selectTab(offset: -1) }),
            AppCommand("detachTab", "移到新窗口", "macwindow.on.rectangle", group: .tab,
                       enabled: { $0.tabCount > 1 },
                       run: { $0.moveActiveTabToNewWindow() }),
        ]
    }

    static func inGroup(_ section: CommandSection) -> [AppCommand] {
        all.filter { $0.group == section }
    }

    static func command(_ id: String) -> AppCommand? {
        all.first { $0.id == id }
    }
}

// MARK: - 命令总线（菜单 / 快捷键 / 右键菜单的唯一执行口）

@MainActor
enum CommandBus {
    static func command(id: String) -> AppCommand? { CommandCatalog.command(id) }

    /// 按键匹配：命中则执行并吞掉事件
    static func handleKey(_ event: NSEvent, in app: AppState) -> Bool {
        guard let command = CommandCatalog.all.first(where: { $0.shortcut?.matches(event) == true }) else {
            return false
        }
        perform(command, on: app, beepOnDisabled: false)
        return true
    }

    static func perform(id: String, on app: AppState) {
        guard let command = CommandCatalog.command(id) else { return }
        perform(command, on: app)
    }

    static func perform(_ command: AppCommand, on app: AppState, beepOnDisabled: Bool = true) {
        let context = CommandContext.build(app)
        guard command.isEnabled(context) else {
            if beepOnDisabled { NSSound.beep() }
            return
        }
        command.run(app)
    }
}

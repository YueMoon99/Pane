import SwiftUI
import AppKit

// MARK: - 枚举（rawValue 用稳定英文，显示标题独立，便于本地化与持久化）

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .light: L10n.tr("浅色")
        case .dark: L10n.tr("深色")
        }
    }
}

enum PaneLayout: String, CaseIterable, Identifiable {
    case single, horizontal, vertical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: L10n.tr("单栏")
        case .horizontal: L10n.tr("横向切分")
        case .vertical: L10n.tr("纵向切分")
        }
    }
    var symbol: String {
        switch self {
        case .single: "square"
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case icon, list, column, gallery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: L10n.tr("图标")
        case .list: L10n.tr("列表")
        case .column: L10n.tr("分栏")
        case .gallery: L10n.tr("画廊")
        }
    }
    var symbol: String {
        switch self {
        case .icon: "square.grid.2x2"
        case .list: "list.bullet"
        case .column: "rectangle.split.3x1"
        case .gallery: "rectangle.on.rectangle"
        }
    }

    /// ⌘4 的轮换顺序：图标 → 列表 → 分栏 → 画廊 → 回到图标。
    /// 顺序就是 `allCases` 的声明顺序，改这里即改轮换次序。
    var next: ViewMode {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

enum PaneSlot: Hashable {
    case primary, secondary

    /// 用于给每个窗格的列表列宽做独立的持久化键，
    /// 避免切分模式下拖动左栏列宽把右栏也一起改掉。
    var storageKey: String {
        switch self {
        case .primary: return "primary"
        case .secondary: return "secondary"
        }
    }
}

// MARK: - 全局应用状态（Observable，主线程）

@MainActor
@Observable
final class AppState {
    var appearance: AppearanceChoice {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            apply()
        }
    }

    // MARK: 标签页

    /// 打开的标签页，顺序即标签栏顺序，始终至少一个
    private(set) var tabs: [TabSession]
    var activeTabID: UUID

    var showPathBar = true
    var showStatusBar = true
    var showHidden = false {
        didSet {
            for tab in tabs {
                tab.primary.setShowHidden(showHidden)
                tab.secondary.setShowHidden(showHidden)
            }
        }
    }

    /// 服务器列表：整机共享一份（挂载是系统级状态，多窗口要看到同一批服务器）
    let server = ServerModel.shared

    /// ⌘J 视图选项面板
    var showViewOptions = false

    /// 所在窗口：用于多窗口时把快捷键路由到正确的实例
    weak var window: NSWindow?

    private var typeBuffer = ""
    private var typeBufferDate = Date.distantPast

    /// 只有主窗口负责把标签页写回磁盘，避免分割出去的窗口互相覆盖
    let persistsTabs: Bool

    /// - Parameter detached: 从主窗口「拖出成窗」时带过来的标签页；nil 表示恢复上次的标签页
    init(detached: TabSession? = nil) {
        // 主窗口的判定不能只看「是不是进程里第一个」：
        // 点左上角 X 关窗后 App 仍驻留在后台，重新打开会新建一个 AppState。
        // 只要当前没有「窗口还开着」的主工作区，新实例就接管标签页存储。
        let ownsTabs = detached == nil && !WorkspaceRegistry.hasOpenPrimary()
        self.persistsTabs = ownsTabs

        let defaults = UserDefaults.standard
        let rawAppearance = defaults.string(forKey: "appearance") ?? AppearanceChoice.system.rawValue
        self.appearance = AppearanceChoice(rawValue: rawAppearance) ?? .system

        if let detached {
            self.tabs = [detached]
            self.activeTabID = detached.id
        } else if !ownsTabs {
            // 已有主窗口在工作：再开一个窗口时给干净的起始页，不与主窗口抢同一套标签页
            let start = Self.lastVisitedPath ?? FileManager.default.homeDirectoryForCurrentUser.path
            let tab = TabSession(primary: URL(fileURLWithPath: start))
            self.tabs = [tab]
            self.activeTabID = tab.id
        } else {
            // 恢复上次的标签页；首次启动（或数据损坏）时给一个干净的起始页
            let stored = TabStore.load()
            if stored.tabs.isEmpty {
                // 兼容旧版：没有 lastPath 时用上次的启动目录，再退回主目录
                let start = Self.lastVisitedPath
                    ?? defaults.string(forKey: "startPath")
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
                let tab = TabSession(primary: URL(fileURLWithPath: start))
                self.tabs = [tab]
                self.activeTabID = tab.id
            } else {
                let restored = stored.tabs.map(TabSession.restore(from:))
                self.tabs = restored
                self.activeTabID = restored.first { $0.id.uuidString == stored.active }?.id
                    ?? restored[0].id
            }
        }

        apply()
        observeLifecycle()
        KeyRouter.installIfNeeded()
        WorkspaceRegistry.register(self)
        // primary 不在 init 里指定：启动时 SwiftUI 会连续构造几个临时实例，
        // 后构造的会把弱引用覆盖掉。等真正绑上窗口时再认领（见 attach）。
        debugLog("[Pane] workspace ready: \(tabs.count) tab(s), ownsTabs=\(ownsTabs), active=\(activeTabID.uuidString.prefix(8))")
    }

    // MARK: 活动标签页

    /// 当前标签页（`tabs` 恒非空，这里只是防御性兜底）
    var activeTab: TabSession {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    var activeTabIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    /// 主窗口：负责持久化标签页、记住窗口位置
    var isPrimaryWindow: Bool { persistsTabs }

    // MARK: 窗格转发（所有旧调用点仍然走这里，作用在活动标签页上）

    var primary: PaneModel { activeTab.primary }
    var secondary: PaneModel { activeTab.secondary }

    var paneLayout: PaneLayout {
        get { activeTab.layout }
        set {
            activeTab.layout = newValue
            if newValue == .single { activeTab.focusedSlot = .primary }
            UserDefaults.standard.set(newValue.rawValue, forKey: "paneLayout")
            persistTabs()
        }
    }

    /// 当前布局下分隔条的比例（左右 / 上下各记一套，属于标签页）
    var splitRatio: Double {
        get { activeTab.ratio(for: activeTab.layout) }
        set {
            activeTab.setRatio(newValue, for: activeTab.layout)
            persistTabs()
        }
    }

    var focusedSlot: PaneSlot {
        get { activeTab.focusedSlot }
        set { activeTab.focusedSlot = newValue }
    }

    var primaryViewMode: ViewMode {
        get { activeTab.primaryViewMode }
        set { activeTab.primaryViewMode = newValue }
    }

    var secondaryViewMode: ViewMode {
        get { activeTab.secondaryViewMode }
        set { activeTab.secondaryViewMode = newValue }
    }

    // MARK: 标签页操作

    @discardableResult
    func newTab(at url: URL? = nil) -> TabSession {
        let source = focused
        let tab = TabSession(
            primary: url ?? source.url,
            secondary: url ?? source.url,
            layout: activeTab.layout,
            focusedSlot: activeTab.focusedSlot,
            primaryViewMode: primaryViewMode,
            secondaryViewMode: secondaryViewMode,
            horizontalRatio: activeTab.horizontalRatio,
            verticalRatio: activeTab.verticalRatio
        )
        tabs.insert(tab, at: activeTabIndex + 1)
        activeTabID = tab.id
        applyGlobalOptions(to: tab)
        persistTabs()
        return tab
    }

    /// 新标签页沿用当前路径与布局（⌘T 的语义）
    func duplicateActiveTab() {
        let copy = TabSession(
            primary: activeTab.primary.url,
            secondary: activeTab.secondary.url,
            layout: activeTab.layout,
            focusedSlot: activeTab.focusedSlot,
            primaryViewMode: primaryViewMode,
            secondaryViewMode: secondaryViewMode,
            horizontalRatio: activeTab.horizontalRatio,
            verticalRatio: activeTab.verticalRatio,
            customTitle: activeTab.customTitle
        )
        tabs.insert(copy, at: activeTabIndex + 1)
        activeTabID = copy.id
        applyGlobalOptions(to: copy)
        persistTabs()
    }

    /// 新建的标签页要继承「显示隐藏文件」这类全局开关，以及当前的剪切标记
    private func applyGlobalOptions(to tab: TabSession) {
        tab.primary.setShowHidden(showHidden)
        tab.secondary.setShowHidden(showHidden)
        let marks = Set(cutURLs.map(\.standardizedFileURL))
        tab.primary.cutURLs = marks
        tab.secondary.cutURLs = marks
    }

    /// 关闭标签页。关掉最后一个时重置为一个新的空标签页，
    /// 而不是把窗口一起关掉——标签栏要常驻，随时能再开新的。
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        guard tabs.count > 1 else {
            // 沿用刚关掉那一页的布局与视图模式，只把位置重置成一个干净的工作区
            let old = tabs[index]
            let location = freshStartURL(from: old)
            let keep = TabSession(
                primary: location,
                secondary: location,
                layout: old.layout,
                focusedSlot: .primary,
                primaryViewMode: old.primaryViewMode,
                secondaryViewMode: old.secondaryViewMode,
                horizontalRatio: old.horizontalRatio,
                verticalRatio: old.verticalRatio
            )
            applyGlobalOptions(to: keep)
            tabs = [keep]
            activeTabID = keep.id
            persistTabs()
            return
        }

        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        persistTabs()
    }

    /// 关到最后一个标签页时回到哪个目录：优先沿用刚关掉那一页的位置
    private func freshStartURL(from tab: TabSession) -> URL {
        let candidate = tab.primary.url
        var isDir: ObjCBool = false
        guard candidate.isFileURL,
              FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
              isDir.boolValue else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return candidate
    }

    func closeActiveTab() {
        closeTab(activeTabID)
    }

    func closeOtherTabs(keeping id: UUID) {
        guard let keep = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keep]
        activeTabID = keep.id
        persistTabs()
    }

    func activate(_ id: UUID) {
        guard id != activeTabID, tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        persistTabs()
    }

    func selectTab(offset: Int) {
        guard tabs.count > 1 else { return }
        let count = tabs.count
        let next = ((activeTabIndex + offset) % count + count) % count
        activeTabID = tabs[next].id
        persistTabs()
    }

    /// 拖拽排序：把 from 位置的标签页插到 to 位置
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        var target = to
        if target > from { target -= 1 }
        target = min(max(target, 0), tabs.count - 1)
        guard target != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: target)
        persistTabs()
    }

    /// 把标签页从当前窗口取出（供「拖出成窗」使用）
    @discardableResult
    func detachTab(_ id: UUID) -> TabSession? {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        persistTabs()
        return tab
    }

    /// 接收从别的窗口拖过来的标签页
    func adopt(_ tab: TabSession) {
        tabs.append(tab)
        activeTabID = tab.id
        persistTabs()
    }

    /// 由 ContentView 注入（SwiftUI 的 openWindow 只能从视图环境里取）
    var openDetachedWindow: ((UUID) -> Void)?

    /// 菜单命令：把当前标签页移到新窗口
    func moveActiveTabToNewWindow() {
        guard tabs.count > 1, let tab = detachTab(activeTabID) else {
            NSSound.beep()
            return
        }
        let token = DetachedWorkspaces.stash(tab)
        openDetachedWindow?(token)
    }

    // MARK: 持久化

    func persistTabs() {
        guard persistsTabs else { return }
        TabStore.save(tabs.map(\.snapshot), active: activeTabID.uuidString)
        // 服务器共享列表不是文件路径，别把 lastPath 覆盖成空
        if focused.url.isFileURL {
            UserDefaults.standard.set(focused.url.path, forKey: "lastPath")
        }
    }

    private static var lastVisitedPath: String? {
        UserDefaults.standard.string(forKey: "lastPath")
    }

    private var lifecycleObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    /// 窗口已经关掉（App 可能仍驻留在后台）：这个实例不再响应任何输入
    private(set) var isWindowClosed = false

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistTabs() }
            }
            lifecycleObservers.append(token)
        }
    }

    /// 由 WindowConfigurator 调用：记住自己的窗口，并在它关闭时收尾
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        isWindowClosed = false
        removeWindowObservers()

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
        windowObservers.append(token)
        // 真正拿到窗口的实例才是「主工作区」：启动时 SwiftUI 可能先构造几个
        // 临时实例，靠 init 里赋值会被后构造的那些覆盖成 nil。
        if persistsTabs { WorkspaceRegistry.primary = self }
        debugLog("[Pane] window bound \(Int(window.frame.width))x\(Int(window.frame.height)) primary=\(persistsTabs)")
    }

    /// 点左上角 X 关闭窗口时也要落盘：
    /// 只有一个窗口时 App 不会退出，靠 willResignActive / willTerminate 都等不到。
    private func windowWillClose() {
        persistTabs()
        debugLog("[Pane] window closing, persisted \(tabs.count) tab(s)")
        window = nil
        isWindowClosed = true
        removeWindowObservers()
        // 让出「主窗口」身份，下次开窗的实例才能接管并恢复标签页
        if WorkspaceRegistry.primary === self { WorkspaceRegistry.primary = nil }
    }

    private func removeWindowObservers() {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers.removeAll()
    }

    // MARK: 键盘命令（由 KeyRouter 统一按窗口派发）

    func handleKey(_ event: NSEvent) -> NSEvent? {
        // 窗口已关闭的旧实例不再参与，避免同一个按键被两个实例各执行一次
        guard !isWindowClosed else { return event }

        // 正在编辑文本时：标准编辑快捷键由这里直接投给字段编辑器。
        // 不能指望菜单的等价键 —— SwiftUI 的 CommandGroup 在字段编辑器当第一
        // 响应者时不派发（菜单项看着是可用的，按 ⌘C / ⌘V 却毫无反应），
        // 所以地址栏 / 重命名框里复制粘贴必须是显式转发。
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            if let action = Self.textEditingAction(for: event) {
                // 撤销 / 重做要沿响应链找撤销管理器，其余动作字段编辑器自己就实现了
                let isUndo = event.keyCode == 6
                NSApp.sendAction(action, to: isUndo ? nil : responder, from: nil)
                return nil
            }
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let effectiveFlags = flags.subtracting([.function, .numericPad])

        // 1. 命令表里登记过的快捷键：菜单栏、快捷键、右键菜单共用同一份定义，
        //    命中就执行并吞掉事件（否则菜单的等价键还会再触发一次）。
        if CommandBus.handleKey(event, in: self) { return nil }

        // 1.5 空格：快速查看。没有修饰键时才认，⌘␣ 是系统输入法
        if event.keyCode == 49, effectiveFlags.isEmpty {
            QuickLookCoordinator.shared.toggle(for: self)
            return nil
        }

        // 1.6 回车：重命名（访达语义）。
        //     没有登记进命令表：菜单项带「无修饰键的 ↩」等价键会抢走
        //     输入框里的回车，导致改名时按回车提交不了。
        if event.keyCode == 36, effectiveFlags.isEmpty {
            beginRename()
            return nil
        }

        // 1.7 F2：重命名（Windows 资源管理器语义）。keyCode 120 是 F2。
        //     Fn+F2 也会产生 keyCode 120（Fn 只是把媒体键还原成功能键）。
        //     不带 ⌘/⌥/⌃/⇧ 时才认，避免误吞其他 F2 组合。
        if event.keyCode == 120, effectiveFlags.isEmpty {
            beginRename()
            return nil
        }

        // 2. ⇧⌫：移到废纸篓（没有 ⌘ 的组合键，菜单里不登记）
        if event.keyCode == 51, flags == [.shift] {
            trashSelection()
            return nil
        }

        // 3. 无修饰键：方向键导航 / 首字母跳转
        // 注意：方向键自带 .function 标志，不能直接用 flags.isEmpty 判断
        guard effectiveFlags.isEmpty else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if let direction = PaneModel.MoveDirection(rawValue: event.keyCode) {
            if let interceptor = focused.arrowInterceptor, interceptor(event.keyCode) { return nil }
            // 只有图标视图需要按网格列数跨行移动，其余视图按单列（行）移动
            let columns = viewMode == .icon ? focused.gridColumns : 1
            focused.moveSelection(direction, columns: columns)
            return nil
        }

        if chars.count == 1, chars.rangeOfCharacter(from: .letters) != nil {
            typeBuffer = Date().timeIntervalSince(typeBufferDate) > 0.9 ? chars : typeBuffer + chars
            typeBufferDate = Date()
            focused.jump(toPrefix: typeBuffer)
            return nil
        }

        return event
    }

    /// ⌘+ / ⌘- 调整图标视图档位（作用于当前聚焦目录）
    func zoomIcons(up: Bool) {
        let store = ViewOptionsStore.shared
        let url = focused.url
        var options = store.options(for: url)
        let next = options.steppedIconSize(up: up)
        guard next != options.iconSize else { return }
        options.iconSize = next
        store.update(options, for: url)
    }

    // MARK: 剪贴板（⌘C / ⌘X / ⌘V）

    /// 被剪切（待移动）的文件；复制时清空。
    /// 变化会同步到各窗格，视图据此把待移动的项目画成半透明。
    private(set) var cutURLs: Set<URL> = [] {
        didSet { syncCutMarks() }
    }

    private func syncCutMarks() {
        let marks = Set(cutURLs.map(\.standardizedFileURL))
        for tab in tabs {
            tab.primary.cutURLs = marks
            tab.secondary.cutURLs = marks
        }
    }

    /// 放弃当前的剪切状态（粘贴完成 / 删除后）
    func clearCutMarks() {
        if !cutURLs.isEmpty { cutURLs = [] }
    }

    func copySelection() {
        writeSelectionToPasteboard(cut: false)
    }

    func cutSelection() {
        writeSelectionToPasteboard(cut: true)
    }

    private func writeSelectionToPasteboard(cut: Bool) {
        let urls = focused.selectedURLs()
        // 共享列表里的条目还不是真实路径，不能当文件拷走
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // 写成标准文件 URL，访达与其他 App 也能直接粘贴
        pasteboard.writeObjects(urls as [NSURL])
        cutURLs = cut ? Set(urls) : []
    }

    func paste() {
        guard focused.url.isFileURL else {
            NSSound.beep()
            return
        }
        guard let urls = Self.fileURLs(on: NSPasteboard.general), !urls.isEmpty else { return }
        let move = !cutURLs.isEmpty && Set(urls).isSubset(of: cutURLs)
        // 目标永远是「当前活动窗格」，而不是固定某一侧
        let destination = focused.url
        debugLog("[Pane] paste \(urls.count) item(s) -> [\(focusedSlot == .primary ? "primary" : "secondary")] \(destination.path)")
        Task {
            await FileOperationService.shared.transfer(urls, to: destination, move: move, duplicateInPlace: true)
            cutURLs = []
            await reloadPanes()
        }
    }

    /// 从剪贴板读出文件 URL（兼容访达等外部 App 复制的文件）
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !objects.isEmpty else { return nil }
        return objects
    }

    /// 把当前选择移到废纸篓（⌘⌫ / ⇧⌫）
    func trashSelection() {
        guard !isEditingText else { return }
        guard focused.url.isFileURL else { return }
        let urls = focused.selectedURLs().filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        clearCutMarks()
        Task {
            await FileOperationService.shared.trash(urls)
            focused.clearSelection()
            await reloadPanes()
        }
    }

    // MARK: 重命名 / 快速查看

    /// 回车或菜单「重命名」：给唯一选中的项目起一个行内输入框
    func beginRename() {
        guard !isEditingText else { return }
        let pane = focused
        guard !pane.isServerRoot else { return }
        guard pane.selection.count == 1, let item = pane.selectedItems().first else {
            // 空目录里按回车什么都不做；多选时响一声表示「只能一个个改」
            if !pane.selection.isEmpty { NSSound.beep() }
            return
        }
        pane.beginRename(item)
    }

    /// 空格：QuickLook 预览开 / 关
    func togglePreview() {
        guard !isEditingText else { return }
        QuickLookCoordinator.shared.toggle(for: self)
    }

    // MARK: 直接删除（⌥⌘⌫）

    /// 非空表示有待确认的删除（ContentView 据此弹二次确认）
    var pendingDelete: [URL] = []

    /// 上一层（⌘↑）。菜单与按键监听共用，文本框输入时让给系统
    func goUp() {
        guard !isEditingText else { return }
        focused.up()
    }

    func requestPermanentDelete() {
        guard !isEditingText else { return }
        guard focused.url.isFileURL else { return }
        let urls = focused.selectedURLs().filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        pendingDelete = urls
    }

    /// 二次确认后执行，不可撤销。
    /// 目标列表由调用方传进来：SwiftUI 关弹窗时会先把 `pendingDelete` 清空
    /// （binding 的 set(false)），等按钮的 action 执行时数组已经空了 —— 之前
    /// 「点删除没反应」就是这个顺序问题。
    func performPermanentDelete(_ urls: [URL]) async {
        pendingDelete = []
        guard !urls.isEmpty else { return }
        clearCutMarks()

        let errors = await Task.detached(priority: .userInitiated) { () -> [String] in
            let fm = FileManager.default
            var errors: [String] = []
            for url in urls {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            return errors
        }.value

        focused.clearSelection()
        await reloadPanes()
        if !errors.isEmpty {
            FileActionService.shared.lastError = errors.prefix(3).joined(separator: "\n")
        }
    }

    /// 正在地址栏 / 重命名框里输入时，删除 / 选择类快捷键应让给系统
    var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    /// 文本框里的标准编辑快捷键 → 对应的 NSText 动作。
    /// 只认「只有 ⌘」或「⌘⇧」两种组合，其他组合（含方向键）继续走系统。
    static func textEditingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        let plain = flags == [.command]
        let withShift = flags == [.command, .shift]
        guard plain || withShift else { return nil }
        switch event.keyCode {
        case 0:  return plain ? #selector(NSText.selectAll(_:)) : nil     // ⌘A
        case 6:  return plain ? Selector(("undo:")) : Selector(("redo:")) // ⌘Z / ⇧⌘Z
        case 7:  return plain ? #selector(NSText.cut(_:)) : nil           // ⌘X
        case 8:  return plain ? #selector(NSText.copy(_:)) : nil          // ⌘C
        case 9:  return plain ? #selector(NSText.paste(_:)) : nil         // ⌘V
        default: return nil
        }
    }

    /// 菜单里的「拷贝 / 剪切 / 粘贴 / 全选」：正在编辑文本时转交系统处理，
    /// 否则（没有这段）焦点在地址栏时 ⌘C 会把文件写成剪贴板内容。
    @discardableResult
    func forwardToTextEditor(_ selector: Selector) -> Bool {
        guard isEditingText, let responder = NSApp.keyWindow?.firstResponder else { return false }
        NSApp.sendAction(selector, to: responder, from: nil)
        return true
    }

    func reloadPanes() async {
        // 所有标签页都已加载过的窗格一起刷新（未显示的标签页不做多余 I/O）
        for tab in tabs {
            for pane in [tab.primary, tab.secondary] where pane.loadState != .idle {
                await pane.load()
            }
        }
        persistTabs()
    }

    func apply() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: 排序（每窗格独立，菜单 / 右键入口改的是焦点窗格；表头直接改本窗格）

    /// 选中排序字段：同字段再点一次 = 反向（访达 / 资源管理器的表头语义）
    func setSortField(_ field: SortField) {
        focused.setSortField(field)
    }

    /// 直接指定方向（「升序 / 降序」开关用）
    func setSortAscending(_ ascending: Bool) {
        focused.setSortAscending(ascending)
    }

    // MARK: 聚焦窗格

    func model(for slot: PaneSlot) -> PaneModel {
        slot == .primary ? primary : secondary
    }

    // MARK: 视图模式（每栏独立）

    func viewMode(for slot: PaneSlot) -> ViewMode {
        slot == .primary ? primaryViewMode : secondaryViewMode
    }

    func setViewMode(_ mode: ViewMode, for slot: PaneSlot) {
        switch slot {
        case .primary: primaryViewMode = mode
        case .secondary: secondaryViewMode = mode
        }
        persistTabs()
    }

    /// 工具栏 / ⌘4 / ⌘J 作用的那一栏：始终跟随焦点窗格
    var viewMode: ViewMode {
        get { viewMode(for: focusedSlot) }
        set { setViewMode(newValue, for: focusedSlot) }
    }

    /// ⌘4：只轮换当前活动窗格的显示模式，另一栏保持原样
    func cycleViewMode() {
        debugLog("[view] cycle \(viewMode.rawValue) -> \(viewMode.next.rawValue)")
        viewMode = viewMode.next
    }

    var focused: PaneModel { model(for: focusedSlot) }

    /// 非焦点窗格（单栏时等于自己）
    var otherPane: PaneModel {
        model(for: focusedSlot == .primary ? .secondary : .primary)
    }

    // MARK: 书签

    /// 右键「添加到书签」：把选中的文件夹固定到侧边栏
    func addSelectedFoldersToBookmarks() {
        let folders = focused.selectedURLs().filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        addBookmarks(folders)
    }

    /// 空白处右键：把当前目录固定到侧边栏
    func addCurrentFolderToBookmark() {
        addBookmarks([focused.url])
    }

    private func addBookmarks(_ urls: [URL]) {
        let added = BookmarkStore.shared.add(contentsOf: urls)
        // 全都已在书签里：响一声，避免「点了没反应」
        if added == 0 { NSSound.beep() }
    }

    // MARK: 跨栏操作

    /// ⌘⌥←/→ 切换焦点：单栏时无意义，忽略
    func focusPane(_ slot: PaneSlot) {
        guard paneLayout != .single else { return }
        focusedSlot = slot
    }

    /// ⌃⌘→ 拷贝 / ⌃⌘⇧→ 移动到另一栏
    func transferSelectionToOtherPane(move: Bool) {
        guard paneLayout != .single else {
            NSSound.beep()
            return
        }
        let urls = focused.selectedURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let destination = otherPane.url
        Task {
            await FileOperationService.shared.transfer(urls, to: destination, move: move)
            await reloadPanes()
        }
    }

    /// ⌃⌘↑ 让另一栏跳到本栏当前目录
    func syncOtherPaneToFocused() {
        guard paneLayout != .single else {
            NSSound.beep()
            return
        }
        otherPane.navigate(to: focused.url)
    }
}

import Foundation
import SwiftUI
import AppKit

/// 单个窗格的可观察状态：当前目录、历史、选择、加载态、实时刷新
@MainActor
@Observable
final class PaneModel {
    var url: URL
    private(set) var items: [FileItem] = []
    private(set) var loadState: LoadState = .idle
    var selection = Set<URL>()
    var showHidden = false

    /// 本窗格的排序方式：切分时左右独立（访达语义），按槽位持久化。
    var sort: FileSort {
        didSet { Self.persist(sort, slotKey: slotKey) }
    }
    /// 持久化键后缀（primary / secondary），与列表列宽同一套约定
    private let slotKey: String

    /// 图标视图每行列数（由视图写入，供方向键上下移动使用）
    var gridColumns = 1
    /// 列视图接管方向键：返回 true 表示已处理（nil 表示不接管）
    var arrowInterceptor: ((UInt16) -> Bool)?
    /// 列视图里「正在浏览」的子目录：只影响地址栏显示，不改变窗格根目录
    var browsingURL: URL?

    /// 处于「剪切待移动」状态的文件（已标准化）。
    /// 视图据此把图标与文件名画成半透明，表示「这些项目等着被粘贴走」。
    var cutURLs: Set<URL> = []

    /// 正在挂载的共享名：列表 / 图标视图在那一行转圈
    private(set) var mountingShare: String?

    /// 正在行内重命名的项目（nil 表示没有）
    private(set) var renaming: URL?
    /// 目录内容被外部改写（重命名）后 +1：列视图据此重读各列
    private(set) var refreshToken = 0
    /// 最近一次改名的「旧 → 新」：列视图用它把列内选中项换成新名字
    private(set) var lastRename: (from: URL, to: URL)?

    /// 从哪个服务器的哪个挂载点进来的：在挂载点根部按「上一层」回到共享列表
    private struct ShareOrigin {
        let server: ServerLocation
        let mountRoot: String
    }
    private var shareOrigin: ShareOrigin?

    func isCut(_ url: URL) -> Bool {
        guard !cutURLs.isEmpty else { return false }
        return cutURLs.contains(url.standardizedFileURL)
    }

    /// 键盘导航后请求滚动到的项。
    /// 只有方向键 / 首字母跳转会写它——鼠标点击本来就在视野内，
    /// 无条件 scrollTo 会让整张表在每次单击时跳一下。
    private(set) var scrollTarget: URL?

    /// 地址栏应显示的路径：列视图下钻时跟随最深选中的目录
    var displayURL: URL { browsingURL ?? url }

    /// 当前是否停在某台服务器的共享列表上（位置是 `smb://host`，不是本地目录）
    var isServerRoot: Bool { serverLocation != nil }

    /// 服务器根位置：由当前 URL 的 scheme 推导，历史栈与标签页恢复都跟着 URL 走
    var serverLocation: ServerLocation? {
        guard url.scheme == "smb", let host = url.host, !host.isEmpty else { return nil }
        return ServerModel.shared.location(forHost: host)
    }

    /// 标签页 / 地址栏用的一行标题：服务器根显示备注名，其余显示目录名
    var displayTitle: String {
        if let server = serverLocation { return server.label }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    private var watcher: DirectoryWatcher?
    /// 网络卷上的轮询兜底（本地卷为 nil，仍走 kqueue）
    private var poller: PollingDirectoryWatcher?
    /// 窗格是否在屏幕上：网络卷的轮询只对看得见的窗格跑
    private var visible = false
    /// 上一次真正加载过的位置：换位置时先清空旧条目，
    /// 否则挂着新目录的路径栏、内容区还留着上一个文件夹的项目（挂载慢时尤其明显）
    private var lastLoadedURL: URL?
    private var anchor: URL?
    private var pendingSelection: URL?

    enum LoadState: Equatable {
        case idle, loading, loaded, empty, error(String)
    }

    init(initial: URL, slot: PaneSlot) {
        self.url = initial
        self.slotKey = slot.storageKey
        let defaults = UserDefaults.standard
        let field = SortField(rawValue: defaults.string(forKey: "sort.field.\(slotKey)") ?? "") ?? .name
        let ascending = defaults.object(forKey: "sort.ascending.\(slotKey)") as? Bool ?? true
        self.sort = FileSort(field: field, ascending: ascending)
    }

    /// 选中排序字段：同字段再点一次 = 反向（访达 / 资源管理器的表头语义）
    func setSortField(_ field: SortField) {
        if sort.field == field {
            sort.ascending.toggle()
        } else {
            sort = FileSort(field: field, ascending: true)
        }
        Task { await resort() }
    }

    /// 直接指定方向（「升序 / 降序」开关用）
    func setSortAscending(_ ascending: Bool) {
        guard sort.ascending != ascending else { return }
        sort.ascending = ascending
        Task { await resort() }
    }

    private static func persist(_ sort: FileSort, slotKey: String) {
        UserDefaults.standard.set(sort.field.rawValue, forKey: "sort.field.\(slotKey)")
        UserDefaults.standard.set(sort.ascending, forKey: "sort.ascending.\(slotKey)")
    }

    // MARK: 加载

    /// 首次展示时加载，避免未显示的窗格做多余 I/O
    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await load()
    }

    /// 排序方式变了：重读当前目录并让列视图重排各列
    func resort() async {
        guard loadState != .idle, !isServerRoot else { return }
        refreshToken &+= 1
        await load()
    }

    func load() async {
        if lastLoadedURL != url {
            lastLoadedURL = url
            items = []
            selection.removeAll()
            anchor = nil
        }
        // 服务器根：列出共享，不挂载任何东西
        if let location = serverLocation {
            await loadShares(location)
            return
        }

        loadState = .loading
        let start = CFAbsoluteTimeGetCurrent()
        do {
            var result = try await LocalFileSystem.shared.contents(
                of: url, showHidden: showHidden, sort: sort)
            // 时长排序：后台线程拿不到 DurationService 的缓存，回主线程取快照重排
            if sort.field == .duration {
                var snapshot = sort
                snapshot.durations = DurationService.shared.durations(for: result)
                result = snapshot.applied(to: result)
            }
            items = result
            loadState = result.isEmpty ? .empty : .loaded
            if let pending = pendingSelection {
                pendingSelection = nil
                if let f = result.first(where: { $0.url.standardizedFileURL == pending.standardizedFileURL }) {
                    selection = [f.url]
                    anchor = f.url
                }
            }
            startWatching()
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            debugLog("[Pane] load \(url.path): \(result.count) items in \(ms)ms")
        } catch {
            items = []
            loadState = .error(error.localizedDescription)
            debugLog("[Pane] load \(url.path) failed: \(error.localizedDescription)")
        }
    }

    /// 服务器根：把共享当成文件夹列出来。双击才挂载，所以进来这一步很快。
    /// - Parameter force: 为 true 时重新向服务器要一次清单（刷新用）
    private func loadShares(_ location: ServerLocation, force: Bool = false) async {
        stopWatching()
        loadState = .loading
        let server = ServerModel.shared
        guard let profile = server.profile(id: location.profileID) ?? server.profile(host: location.host) else {
            items = []
            loadState = .error(ServerError.profileMissing(location.host).localizedDescription)
            return
        }
        do {
            let shares = try await server.ensureSession(for: profile, force: force)
            // 加载期间用户可能已经切到别处，旧结果不能覆盖新目录
            guard serverLocation == location else { return }
            items = shares.map { name in
                FileItem.share(name, host: location.host, mounted: server.mountedURL(share: name, on: profile))
            }
            loadState = items.isEmpty ? .empty : .loaded
            debugLog("[Pane] shares of \(location.host): \(items.count) item(s)")
        } catch {
            guard serverLocation == location else { return }
            items = []
            loadState = .error(error.localizedDescription)
            debugLog("[Pane] shares of \(location.host) failed: \(error.localizedDescription)")
        }
    }

    func setShowHidden(_ value: Bool) {
        guard showHidden != value else { return }
        showHidden = value
        Task { await load() }
    }

    // MARK: 导航

    func navigate(to newURL: URL) {
        guard newURL != url else { return }
        // 文件路径，或 `smb://host`（服务器根）
        guard newURL.isFileURL || newURL.scheme == "smb" else { return }
        backStack.append(url)
        if backStack.count > 50 { backStack.removeFirst() }
        forwardStack.removeAll()
        // 离开这个共享之后再按「上一层」就不该跳回服务器列表了
        if let origin = shareOrigin, !Self.isInside(newURL, root: origin.mountRoot) {
            shareOrigin = nil
        }
        url = newURL
        selection.removeAll()
        anchor = nil
        Task { await load() }
    }

    /// 重新读一次当前目录（工具栏刷新按钮 / ⌘R / 右键「刷新」共用）。
    /// 服务器根则是重新向服务器要一份共享清单。
    func reload() {
        if isServerRoot {
            Task { await reloadShares() }
        } else {
            Task { await load() }
        }
    }

    /// 刷新共享列表：绕过缓存，重新枚举一次
    func reloadShares() async {
        guard let location = serverLocation else {
            await load()
            return
        }
        await loadShares(location, force: true)
    }

    /// 打开一台服务器：在工作区里像文件夹一样列出它的共享
    func openServer(_ location: ServerLocation) {
        if url.scheme == "smb", url.host?.caseInsensitiveCompare(location.host) == .orderedSame {
            // 已经在这一屏：刷新一次即可
            Task { await load() }
            return
        }
        navigate(to: location.url)
    }

    /// 双击共享：挂载它，然后进入挂载点
    func openShare(_ item: FileItem) async {
        guard item.isShare, let location = serverLocation else { return }
        let server = ServerModel.shared
        guard let profile = server.profile(id: location.profileID) ?? server.profile(host: location.host) else {
            FileActionService.shared.lastError = ServerError.profileMissing(location.host).localizedDescription
            return
        }
        guard mountingShare == nil else { return }

        mountingShare = item.name
        defer { mountingShare = nil }
        do {
            let mounted = try await server.mount(share: item.name, on: profile)
            guard serverLocation == location else { return }
            shareOrigin = ShareOrigin(server: location, mountRoot: mounted.path)
            navigate(to: mounted)
        } catch {
            FileActionService.shared.lastError = error.localizedDescription
            debugLog("[Pane] mount \(location.host)/\(item.name) failed: \(error.localizedDescription)")
        }
    }

    /// URL 是否位于某个挂载点之内（挂载点本身也算）
    private static func isInside(_ url: URL, root: String) -> Bool {
        let path = url.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// 地址栏输入：目录则进入；文件则进入父目录并选中该文件
    @discardableResult
    func navigate(toPath raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let expanded = (text as NSString).expandingTildeInPath
        let target: URL = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : url.appendingPathComponent(expanded)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            return false
        }
        // .app / .bundle 等包按“文件”处理：进入父目录并选中
        let isPackage = (try? target.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false

        if isDir.boolValue && !isPackage {
            navigate(to: target)
        } else {
            let parent = target.deletingLastPathComponent()
            if parent.standardizedFileURL == url.standardizedFileURL {
                if let f = items.first(where: { $0.url.standardizedFileURL == target.standardizedFileURL }) {
                    selection = [f.url]
                    anchor = f.url
                }
            } else {
                pendingSelection = target
                navigate(to: parent)
            }
        }
        return true
    }

    /// 双击行为：共享先挂载再进入；文件夹进入；压缩包就地解压并选中结果；其他文件/包用默认程序打开
    func enter(_ item: FileItem) {
        if item.isShare {
            Task { await openShare(item) }
            return
        }
        if item.isDirectory && !item.isPackage {
            navigate(to: item.url)
            return
        }
        if item.kind == .archive, ArchiveService.canExtract(item.url) {
            Task { await extract([item.url]) }
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    /// 解压到各自所在目录，完成后选中新出现的项目（不弹窗）
    /// - Parameter intoNamedFolders: 为 true 时放进与压缩包同名的文件夹
    func extract(_ urls: [URL], intoNamedFolders: Bool = false) async {
        guard !urls.isEmpty else { return }
        let outcome = await ArchiveService.extract(
            urls,
            destination: intoNamedFolders ? .namedFolder : .besideArchive
        )
        await load()
        select(itemsAt: outcome.created, scroll: true)
        if !outcome.failed.isEmpty {
            FileActionService.shared.lastError =
                L10n.tr("解压失败：%@", outcome.failed.prefix(3).joined(separator: "、"))
        }
    }

    /// 按 URL 选中一批项目（解压 / 新建后定位用）
    func select(itemsAt urls: [URL], scroll: Bool = false) {
        let targets = Set(urls.map(\.standardizedFileURL))
        let matched = items.filter { targets.contains($0.url.standardizedFileURL) }
        guard !matched.isEmpty else { return }
        selection = Set(matched.map(\.url))
        anchor = matched.first?.url
        if scroll { scrollTarget = anchor }
    }

    // MARK: 重命名
    //
    // 一行只在「有输入框」的时候进入编辑态：renaming 存的是项目 URL，
    // 四个视图（图标 / 列表 / 分栏 / 画廊）看到它就地把名字换成输入框。
    // 提交逻辑放在模型里，菜单命令、回车、右键菜单都走同一条路。

    /// 这个项目是否正在改名
    func isRenaming(_ item: FileItem) -> Bool {
        renaming == item.url
    }

    func beginRename(_ item: FileItem) {
        // 服务器共享列表是虚拟位置，没有可改的本地名字
        guard !isServerRoot, !item.isShare else {
            NSSound.beep()
            return
        }
        renaming = item.url
    }

    func cancelRename() {
        renaming = nil
    }

    /// 提交改名：空名字 / 同名视为取消；成功后重新加载并选中新名字
    func finishRename(_ newName: String) async {
        guard let target = renaming else { return }
        renaming = nil

        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.lastPathComponent else { return }
        guard !name.contains("/"), !name.contains(":") else {
            FileActionService.shared.lastError = L10n.tr("名称里不能包含“/”或“:”")
            return
        }
        guard let renamed = FileActionService.shared.rename(target, to: name) else { return }

        lastRename = (target, renamed)
        await load()
        select(itemsAt: [renamed], scroll: true)
        refreshToken &+= 1
    }

    // MARK: 选择（访达语义）

    /// 单击替换；⌘ 切换；⇧ 从锚点连选
    func click(_ item: FileItem, toggle: Bool = false, range: Bool = false) {
        if range, let a = anchor,
           let i = items.firstIndex(where: { $0.url == a }),
           let j = items.firstIndex(of: item) {
            let lo = min(i, j), hi = max(i, j)
            selection = Set(items[lo...hi].map(\.url))
        } else if toggle {
            if selection.contains(item.url) { selection.remove(item.url) }
            else { selection.insert(item.url) }
            anchor = item.url
        } else {
            selection = [item.url]
            anchor = item.url
        }
    }

    /// 单击统一入口（四个视图共用）：双击打开；无修饰键单击「已唯一选中」的项时，
    /// 只有点在**文件名文字**上才进入重命名（点图标或行内空白什么都不做，避免误触发）；
    /// 其余走普通单击选择。
    /// - Parameters:
    ///   - point: 点击位置（窗口坐标，与 SwiftUI `.global` 一致）
    ///   - nameRect: 该文件名文字在窗口内的矩形
    func clickOrRename(_ item: FileItem, count: Int, flags: NSEvent.ModifierFlags,
                       at point: CGPoint? = nil, nameRect: CGRect? = nil) {
        if count >= 2 {
            click(item)
            enter(item)
            return
        }
        let toggle = flags.contains(.command)
        let range = flags.contains(.shift)
        // 无修饰键，且该项已经是唯一选中项
        if !toggle && !range, selection.count == 1, selection.contains(item.url) {
            // 只有点在文件名上才进入重命名；点图标/空白保持原状，什么都不做
            if let point, let nameRect, !nameRect.isEmpty, nameRect.contains(point) {
                beginRename(item)
            }
            return
        }
        click(item, toggle: toggle, range: range)
    }

    func selectAll() {
        selection = Set(items.map(\.url))
        anchor = items.first?.url
    }

    func clearSelection() {
        selection.removeAll()
        anchor = nil
    }

    /// 框选 / 批量替换选择：锚点取显示顺序里的最后一个，随后的 ⇧ 连选从这里开始
    func setSelection(_ urls: Set<URL>) {
        let ordered = items.filter { urls.contains($0.url) }
        selection = Set(ordered.map(\.url))
        anchor = ordered.last?.url
    }

    /// 当前选中的文件（按列表顺序，供复制 / 拖拽使用）
    func selectedURLs() -> [URL] {
        items.filter { selection.contains($0.url) }.map(\.url)
    }

    func selectedItems() -> [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    func invertSelection() {
        selection = Set(items.map(\.url)).subtracting(selection)
        anchor = items.first?.url
    }

    // MARK: 键盘导航

    enum MoveDirection: UInt16 {
        case left = 123, right = 124, down = 125, up = 126
    }

    /// 方向键移动选择：`columns` 为图标视图每行列数，列表 / 画廊传 1
    func moveSelection(_ direction: MoveDirection, columns: Int = 1) {
        guard !items.isEmpty else { return }
        let cols = max(1, columns)
        guard let current = anchor ?? selection.first,
              let index = items.firstIndex(where: { $0.url == current }) else {
            select(index: 0, scroll: true)
            return
        }
        let target: Int
        switch direction {
        case .up:    target = index - cols
        case .down:  target = index + cols
        case .left:  target = index - 1
        case .right: target = index + 1
        }
        select(index: min(max(target, 0), items.count - 1), scroll: true)
    }

    /// 首字母跳转：从当前项之后循环查找，同名首字母可连续跳转
    func jump(toPrefix prefix: String) {
        let text = prefix.lowercased()
        guard !text.isEmpty, !items.isEmpty else { return }
        let start = (anchor ?? selection.first)
            .flatMap { current in items.firstIndex { $0.url == current } } ?? -1
        for offset in 1...items.count {
            let i = (start + offset) % items.count
            if items[i].name.lowercased().hasPrefix(text) {
                select(index: i, scroll: true)
                return
            }
        }
    }

    private func select(index: Int, scroll: Bool = false) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        selection = [item.url]
        anchor = item.url
        if scroll { scrollTarget = item.url }
    }

    /// 选中并滚动到某一项（画廊 / 列表聚焦同步）
    func reveal(_ item: FileItem) {
        guard let index = items.firstIndex(where: { $0.url == item.url }) else { return }
        select(index: index)
    }

    func back() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(url)
        url = prev
        selection.removeAll()
        anchor = nil
        Task { await load() }
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        url = next
        selection.removeAll()
        anchor = nil
        Task { await load() }
    }

    func up() {
        // 挂载点的上一层应该是「服务器的共享列表」，而不是本机的 /Volumes
        if let origin = shareOrigin, url.path == origin.mountRoot {
            openServer(origin.server)
            return
        }
        guard let parent = url.parent else { return }
        navigate(to: parent)
    }

    // MARK: 实时刷新

    private func startWatching() {
        stopWatching()
        guard WatcherConfig.enabled else { return }

        let onChange: () -> Void = { [weak self] in
            Task { await self?.load() }
        }

        // 本地卷：kqueue 的事件又快又准，原样保留
        if VolumeInspector.isLocal(url) {
            watcher = DirectoryWatcher(url: url, onChange: onChange)
            return
        }

        // 网络卷（SMB / AFP / NFS）：那边 kqueue 基本收不到 .write，改成
        // 「每 2 秒 stat 一次目录 + 每 12 秒比一次文件名」的轻量轮询。
        // 可见性跟着视图走：隐藏的标签页 / 未显示的副窗格不轮询。
        let poller = PollingDirectoryWatcher(url: url, appActive: NSApp.isActive, onChange: onChange)
        poller.setVisible(visible)
        self.poller = poller
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        poller?.stop()
        poller = nil
    }

    /// 由 `PaneView` 的任务生命周期维护：窗格离开屏幕就停掉网络卷轮询
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        poller?.setVisible(value)
    }
}

extension URL {
    /// 父目录（到达卷根时返回 nil，避免越界）
    var parent: URL? {
        let p = self.path
        guard p != "/", pathComponents.count > 1 else { return nil }
        let parent = deletingLastPathComponent()
        return parent == self ? nil : parent
    }
}

/// 无缓冲调试日志（重定向到文件时不会因进程退出丢失）
func debugLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    // 同时落一份到 /tmp/pane-debug.log：从访达/LaunchServices 启动时看不到 stderr，
    // 排查「点了没反应」这类问题时这份流水账是唯一的线索。
    let url = URL(fileURLWithPath: "/tmp/pane-debug.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

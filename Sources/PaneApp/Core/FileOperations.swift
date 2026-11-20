import Foundation
import AppKit

/// 一次复制 / 移动的实时进度。
///
/// 写入发生在后台线程、读取发生在主线程（进度卡片），所有字段用锁保护；
/// 卡片用 `TimelineView` 定时取一次快照，所以这里不需要 `@Observable`。
final class TransferTask: @unchecked Sendable, Identifiable {
    enum Kind {
        case copy, move

        var verb: String { self == .copy ? L10n.tr("复制") : L10n.tr("移动") }
    }

    struct Snapshot {
        var verb: String
        var currentName: String
        var completedBytes: Int64
        var totalBytes: Int64
        var completedItems: Int
        var totalItems: Int
        var preparing: Bool
        var cancelled: Bool

        /// 进度条比例：有字节数就按字节算，估不出总量时退化成按项目数
        var fraction: Double {
            if totalBytes > 0 {
                return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
            }
            if totalItems > 0 {
                return min(Double(completedItems) / Double(totalItems), 1)
            }
            return 0
        }
    }

    let id = UUID()
    let kind: Kind
    let startedAt = Date()

    private let lock = NSLock()
    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0
    private var completedItems = 0
    private var totalItems = 0
    private var currentName = ""
    private var preparing = true
    private var cancelled = false
    /// 用户点了「中止」，用来区分「取消」和「全部完成」两种收尾
    private var cancelledByUser = false

    init(kind: Kind, totalItems: Int) {
        self.kind = kind
        self.totalItems = totalItems
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(verb: kind.verb,
                        currentName: currentName,
                        completedBytes: completedBytes,
                        totalBytes: totalBytes,
                        completedItems: completedItems,
                        totalItems: totalItems,
                        preparing: preparing,
                        cancelled: cancelled)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledByUser
    }

    var bytesDone: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return completedBytes
    }

    /// 中止：后台循环会在下一个文件 / 下一段数据前退出
    func cancel() {
        lock.lock()
        cancelled = true
        cancelledByUser = true
        lock.unlock()
    }

    func begin(totalBytes: Int64, totalItems: Int) {
        lock.lock()
        self.totalBytes = totalBytes
        if totalItems > 0 { self.totalItems = totalItems }
        preparing = false
        lock.unlock()
    }

    func setCurrentName(_ name: String) {
        lock.lock()
        currentName = name
        lock.unlock()
    }

    /// 当前文件内已复制的字节（相对整个任务）
    func setCopied(base: Int64, inFile: Int64) {
        lock.lock()
        completedBytes = max(completedBytes, base + inFile)
        lock.unlock()
    }

    func addBytes(_ bytes: Int64) {
        lock.lock()
        completedBytes += max(bytes, 0)
        lock.unlock()
    }

    func advanceItem() {
        lock.lock()
        completedItems += 1
        lock.unlock()
    }
}

/// 用户中止时抛出的哨兵错误：用来把「半成品」清掉
private struct CancelledTransfer: Error {}

/// 文件级操作（复制 / 移动）。
///
/// 复制走 `copyfile(3)`：保留扩展属性、ACL、创建时间，APFS 上优先克隆；
/// 同时借它的状态回调拿到字节级进度，并可随时中止。移动先试 rename，
/// 跨卷时退化成「复制 + 删源」，这样才有进度可看。
@MainActor
@Observable
final class FileOperationService {
    static let shared = FileOperationService()

    private(set) var isWorking = false
    /// 当前正在进行的复制 / 移动：界面右下角的进度卡片读它
    private(set) var activeTask: TransferTask?
    /// 最近一次失败提示（ContentView 用它弹窗）
    var lastError: String?
    /// 失败原因是「系统权限」：提示里可以给一个去开完全磁盘访问权限的按钮
    var lastErrorNeedsFullDiskAccess = false

    /// 正在跑的任务：再发起一次时先等它结束，避免两条进度互相覆盖
    private var running: Task<Result, Never>?

    private init() {}

    struct Result: Sendable {
        var copied = 0
        var moved = 0
        var errors: [String] = []
        var isEmpty: Bool { copied == 0 && moved == 0 && errors.isEmpty }
    }

    /// 把 `sources` 复制或移动到 `destination` 目录
    ///
    /// - Parameter duplicateInPlace: ⌘V 粘回原目录时为 true（生成「副本」），
    ///   拖拽回原目录时保持 false（视为无操作）
    @discardableResult
    func transfer(_ sources: [URL], to destination: URL, move: Bool, duplicateInPlace: Bool = false) async -> Result {
        guard !sources.isEmpty else { return Result() }
        // 上一个任务还没收尾就排队等它，HUD 一次只显示一个任务
        if let running { _ = await running.value }

        let task = TransferTask(kind: move ? .move : .copy, totalItems: sources.count)
        activeTask = task
        isWorking = true

        let job = Task.detached(priority: .userInitiated) {
            Self.perform(sources,
                         destination: destination,
                         move: move,
                         duplicateInPlace: duplicateInPlace,
                         task: task)
        }
        running = job
        let result = await job.value
        running = nil
        isWorking = false

        // 中止时不必再弹错：用户自己按的
        if !result.errors.isEmpty, !task.wasCancelled {
            let shown = result.errors.prefix(3).joined(separator: "\n")
            lastError = result.errors.count > 3 ? shown + "\n…" : shown
        }

        // 让「完成 / 已中止」在卡片上停留一小会儿再消失
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(task.wasCancelled ? 350 : 550))
            guard let self, self.activeTask === task else { return }
            self.activeTask = nil
        }
        return result
    }

    /// 移到废纸篓（⌘⌫、拖到废纸篓）
    ///
    /// 两个层次：先交给系统的废纸篓助手（保留「放回原处」），
    /// 被系统权限拒绝时退一步自己把文件搬进 `~/.Trash`。
    @discardableResult
    func trash(_ sources: [URL]) async -> Result {
        guard !sources.isEmpty else { return Result() }
        let outcome = await Task.detached(priority: .userInitiated) { () -> (Result, Bool) in
            var result = Result()
            var permissionDenied = false
            for source in sources {
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
                    result.moved += 1
                    continue
                } catch {
                    let ns = error as NSError
                    debugLog("[trash] \(source.path) trashItem failed code=\(ns.code)")
                    // 513 = NSFileWriteNoPermissionError。桌面 / 文稿 / 下载这些受
                    // 系统保护的文件夹，系统的废纸篓助手要求「完全磁盘访问权限」，
                    // 而普通授权只够读写文件本身。这里直接搬进 ~/.Trash 绕过它。
                    guard ns.code == NSFileWriteNoPermissionError,
                          Self.moveToUserTrash(source) else {
                        if ns.code == NSFileWriteNoPermissionError { permissionDenied = true }
                        result.errors.append("\(source.lastPathComponent)：\(error.localizedDescription)")
                        continue
                    }
                    result.moved += 1
                }
            }
            return (result, permissionDenied)
        }.value

        let result = outcome.0
        if !result.errors.isEmpty {
            var shown = result.errors.prefix(3).joined(separator: "\n")
            if outcome.1 {
                shown += L10n.tr("\n\n受系统保护的文件夹（桌面、文稿、下载等）需要在\n")
                    + L10n.tr("「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许 Pane。")
            }
            lastError = result.errors.count > 3 ? shown + "\n…" : shown
            lastErrorNeedsFullDiskAccess = outcome.1
        }
        return result
    }

    /// 文件自己的废纸篓目录。
    ///
    /// 开着「桌面与文稿」iCloud 同步的机器上，桌面里的文件其实躺在
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Desktop`，
    /// 访达删除时会放进 `~/Library/Mobile Documents/.Trash` 而不是 `~/.Trash`。
    /// 放错地方会让 iCloud 以为文件被移出云盘，所以这里跟着来源走。
    private nonisolated static func trashDirectory(for source: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localTrash = home.appendingPathComponent(".Trash", isDirectory: true)
        let cloudTrash = home.appendingPathComponent("Library/Mobile Documents/.Trash", isDirectory: true)

        // 只有真的在 iCloud 云盘里（`isUbiquitousItem`）才用云盘废纸篓：
        // 「桌面与文稿」同步打开时 `~/Desktop` 本身还是普通路径，看不出差别。
        let isCloud = (try? source.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            || source.path.contains("/Library/Mobile Documents/")
        guard isCloud else { return localTrash }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudTrash.path, isDirectory: &isDir), isDir.boolValue else {
            return localTrash
        }
        return cloudTrash
    }

    /// 绕过系统废纸篓助手，直接把文件搬进废纸篓目录。
    ///
    /// 目标重名时退化成「名称 2.ext」这样的名字；云盘废纸篓写不进去时退回本机的 `~/.Trash`。
    private nonisolated static func moveToUserTrash(_ source: URL) -> Bool {
        if moveToTrash(source, in: trashDirectory(for: source)) { return true }
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        if trashDirectory(for: source) == homeTrash { return false }
        return moveToTrash(source, in: homeTrash)
    }

    private nonisolated static func moveToTrash(_ source: URL, in trash: URL) -> Bool {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension

        for index in 1...20 {
            let candidate: String
            switch index {
            case 1: candidate = name
            default:
                let suffix = " \(index)"
                candidate = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            }
            let target = trash.appendingPathComponent(candidate)
            // 注意：废纸篓的目录列表可能被系统拦着，别用 fileExists 判断（会永远为 false），
            // 直接尝试移动，失败（目标已存在 / 跨卷）就换个名字。
            do {
                try fm.moveItem(at: source, to: target)
                debugLog("[trash] moved to \(target.path) (fallback)")
                return true
            } catch {
                let code = (error as NSError).code
                if code != NSFileWriteFileExistsError { return false }
            }
        }
        return false
    }

    // MARK: 实际 I/O（后台）

    private nonisolated static func perform(_ sources: [URL],
                                            destination: URL,
                                            move: Bool,
                                            duplicateInPlace: Bool,
                                            task: TransferTask) -> Result {
        let fm = FileManager.default
        var result = Result()
        let dest = destination.standardizedFileURL

        // 先把真正要搬的条目挑出来：同目录内移动 / 粘回原目录之类的不算
        var work: [(source: URL, target: URL)] = []
        for source in sources {
            let src = source.standardizedFileURL
            // 同一目录内：拖拽视为无操作；⌘V 生成副本；⌘X 后 ⌘V 也视为无操作
            if src.deletingLastPathComponent() == dest, move || !duplicateInPlace { continue }
            if src == dest { continue }
            // 不允许把目录拖进它自己的子目录
            if dest.path.hasPrefix(src.path + "/") {
                result.errors.append(L10n.tr("%@：不能移动到自身的子目录", src.lastPathComponent))
                continue
            }
            work.append((src, uniqueTarget(for: src.lastPathComponent, in: dest, fm: fm)))
        }
        guard !work.isEmpty else { return result }

        // 先量一遍总字节数，进度条才有分母；量得太久（超大目录）就放弃，退化成按项目数
        let total = measureBytes(of: work.map(\.source))
        task.begin(totalBytes: total, totalItems: work.count)

        for item in work {
            if task.isCancelled { break }
            task.setCurrentName(item.source.lastPathComponent)
            do {
                try transferOne(item.source, to: item.target, move: move, task: task, fm: fm)
                if move { result.moved += 1 } else { result.copied += 1 }
            } catch is CancelledTransfer {
                // 中止：把拷了一半的东西删掉，别留垃圾
                try? fm.removeItem(at: item.target)
                break
            } catch {
                try? fm.removeItem(at: item.target)
                result.errors.append("\(item.source.lastPathComponent)：\(error.localizedDescription)")
            }
            task.advanceItem()
        }
        return result
    }

    private nonisolated static func transferOne(_ src: URL,
                                                to dst: URL,
                                                move: Bool,
                                                task: TransferTask,
                                                fm: FileManager) throws {
        if move {
            // 同卷 rename 是瞬间的；跨卷 FileManager 不会自己降级，手动复制再删源
            do {
                try fm.moveItem(at: src, to: dst)
                task.addBytes(sizeOf(src))
                return
            } catch {
                debugLog("[move] rename failed, fallback to copy+delete: \(error.localizedDescription)")
            }
        }
        try copyRecursively(src, to: dst, task: task)
        if move { try fm.removeItem(at: src) }
    }

    /// 递归复制：文件用 copyfile 拿到进度，目录自己建、符号链接按链接复制
    private nonisolated static func copyRecursively(_ src: URL, to dst: URL, task: TransferTask) throws {
        if task.isCancelled { throw CancelledTransfer() }
        let fm = FileManager.default
        let values = try? src.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])

        if values?.isSymbolicLink == true {
            let destination = try fm.destinationOfSymbolicLink(atPath: src.path)
            try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: destination)
            return
        }

        guard values?.isDirectory == true else {
            try copyFile(src, dst, task: task)
            return
        }

        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        let children = try fm.contentsOfDirectory(at: src,
                                                  includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                                  options: [])
        for child in children {
            try copyRecursively(child,
                                to: dst.appendingPathComponent(child.lastPathComponent),
                                task: task)
        }
        // 子项拷完再套用目录自身的权限 / 时间戳，避免只读目录导致子项写不进去
        if let attributes = try? fm.attributesOfItem(atPath: src.path) {
            try? fm.setAttributes(attributes, ofItemAtPath: dst.path)
        }
    }

    private nonisolated static func copyFile(_ src: URL, _ dst: URL, task: TransferTask) throws {
        guard let state = copyfile_state_alloc() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer { copyfile_state_free(state) }

        let context = CopyContext(task: task, base: task.bytesDone)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                           unsafeBitCast(copyFileStatusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), pointer)

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC)
        let fileSize = sizeOf(src)
        let status = src.withUnsafeFileSystemRepresentation { from in
            dst.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return Int32(-1) }
                return copyfile(from, to, state, flags)
            }
        }
        if context.cancelled || task.isCancelled { throw CancelledTransfer() }
        guard status == 0 else {
            let code = errno == 0 ? EIO : errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
        // 回调是节流的，最后一个包不一定报到；这里把整份文件的大小补齐
        task.setCopied(base: context.base, inFile: fileSize)
    }

    /// copyfile 的状态回调：边拷边报进度，用户中止就返回 QUIT
    private nonisolated static let copyFileStatusCallback:
        @convention(c) (Int32, Int32, copyfile_state_t,
                        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { what, stage, state, _, _, raw in
        guard let raw else { return COPYFILE_CONTINUE }
        let context = Unmanaged<CopyContext>.fromOpaque(raw).takeUnretainedValue()
        if context.task.isCancelled {
            context.cancelled = true
            return COPYFILE_QUIT
        }
        if stage == COPYFILE_PROGRESS, what == COPYFILE_COPY_DATA {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                context.report(copied: Int64(copied))
            }
        }
        return COPYFILE_CONTINUE
    }

    /// 重名时生成「名称 副本.ext」「名称 副本 2.ext」…
    private nonisolated static func uniqueTarget(for name: String, in directory: URL, fm: FileManager) -> URL {
        let base = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: base.path) else { return base }

        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var index = 1
        while true {
            let suffix = index == 1 ? L10n.tr(" 副本") : L10n.tr(" 副本 %@", index)
            let candidate = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: url.path) { return url }
            index += 1
            if index > 999 { return url }
        }
    }

    // MARK: 体积估算

    /// 估算总字节数（只读元数据）。超过 3 秒还数不完就放弃，返回 0，
    /// 进度卡片会退化成「x / y 项」。
    private nonisolated static func measureBytes(of urls: [URL]) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let deadline = Date().addingTimeInterval(3)
        var total: Int64 = 0
        var visited = 0

        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory != true {
                total += Int64(values?.fileSize ?? 0)
                continue
            }
            guard let enumerator = fm.enumerator(at: url,
                                                 includingPropertiesForKeys: keys,
                                                 options: [],
                                                 errorHandler: { _, _ in true }) else { continue }
            while let child = enumerator.nextObject() as? URL {
                visited += 1
                if visited % 512 == 0, Date() > deadline { return 0 }
                guard let childValues = try? child.resourceValues(forKeys: Set(keys)),
                      childValues.isDirectory != true else { continue }
                total += Int64(childValues.fileSize ?? 0)
            }
        }
        return total
    }

    private nonisolated static func sizeOf(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory != true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }
}

/// copyfile 回调的上下文（回调与复制在同一线程上顺序执行，不需要加锁）
private final class CopyContext {
    let task: TransferTask
    let base: Int64
    var cancelled = false
    private var lastReport: CFAbsoluteTime = 0

    init(task: TransferTask, base: Int64) {
        self.task = task
        self.base = base
    }

    func report(copied: Int64) {
        // 每 60ms 汇报一次就够顺畅了，避免回调把时间全花在加锁上
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReport > 0.06 else { return }
        lastReport = now
        task.setCopied(base: base, inFile: copied)
    }
}

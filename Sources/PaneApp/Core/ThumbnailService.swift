import AppKit
import QuickLookThumbnailing

/// 缩略图服务：三级缓存（内存 → 磁盘 → QuickLook 生成）
///
/// - 内存：`NSCache`，约 300 张，键为「路径 + 尺寸档 + 修改时间」
/// - 磁盘：`~/Library/Caches/Pane/thumbs/`，上限 500MB，超出按最旧访问时间淘汰
/// - 生成：`QLThumbnailGenerator`，后台 `.utility` 优先级，**最多 4 个并发**，
///   调用方取消时会 `cancel` 掉 QuickLook 请求（网络卷上尤其重要，否则会持续读盘）
///
/// 只保留**真正的页面预览**（`rep.type != .icon`）。系统在拿不到预览器时
/// 会退回来一张图标级表示（`.icon`：透明方框里画个文档图标），那种图交给上层
/// 会被当成内容套上底板和投影，结果阴影落在透明外框上。这种情况直接返回 `nil`，
/// 由 `ThumbnailView` 落回 `FileIcon`（NSWorkspace 原生图标，更锐利）。
///
/// 网络卷直接跳过生成：SMB 上一次缩略图就是一次完整文件读取，几十个 cell 同时请求
/// 会把带宽打满。需要时可以在设置里打开「在网络宗卷上显示缩略图」，
/// 那时只对图片 / 视频 / PDF 生成，且并发压到 2、体积上限 64MB。
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<Data?, Never>] = [:]
    private let diskDir: URL
    private let gate = ThumbnailGate(limit: 4)
    /// 网络卷单独一道闸：带宽比 CPU 金贵得多
    private let remoteGate = ThumbnailGate(limit: 2)

    private nonisolated static let diskLimit: Int64 = 500 * 1024 * 1024

    /// 缓存代次：生成规则变了就加一，旧缓存自然淘汰（避免复用旧版存下的「图标图」）
    private nonisolated static let cacheGeneration = "g2"

    /// 墓碑有效期：期间不再向 QuickLook 询问；过期后重试，
    /// 给「后来装了预览插件」留条恢复的路
    private nonisolated static let tombstoneTTL: TimeInterval = 7 * 24 * 3600

    private init() {
        memory.countLimit = 300
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pane/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        diskDir = base

        Task.detached(priority: .background) {
            Self.pruneDiskCache(dir: base, limit: Self.diskLimit)
        }
    }

    // MARK: 对外接口

    /// 只查内存缓存（同步，用于避免首帧闪烁）
    func cached(_ item: FileItem, size: CGFloat) -> NSImage? {
        memory.object(forKey: Self.key(for: item, size: size) as NSString)
    }

    /// 取缩略图：命中缓存直接返回，否则排队生成（同键请求共享同一任务）
    func thumbnail(for item: FileItem, size: CGFloat) async -> NSImage? {
        guard Self.supportsPreview(item) else { return nil }
        let key = Self.key(for: item, size: size)

        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let running = inflight[key] {
            let data = await withTaskCancellationHandler {
                await running.value
            } onCancel: {
                running.cancel()
            }
            return data.flatMap(NSImage.init(data:))
        }

        let file = diskDir.appendingPathComponent(key + ".png")
        // 网络卷走单独的闸门：同一个 cell 的请求仍然共享同一个任务
        let gate = VolumeInspector.isLocal(item.url) ? self.gate : self.remoteGate
        let task = Task.detached(priority: .utility) { () -> Data? in
            switch Self.readCache(file) {
            case .image(let cached):
                return cached
            case .tombstone:
                // 上次已经问过 QuickLook，确实没有页面预览，别再问一遍
                return nil
            case .miss:
                break
            }
            guard !Task.isCancelled else { return nil }

            await gate.acquire()
            let data = await Self.generatePNG(item: item, points: size)
            await gate.release()

            guard !Task.isCancelled else { return nil }
            // 没有真预览时写一个空文件当墓碑，省掉后续每次滚动的一次 QuickLook 往返
            try? (data ?? Data()).write(to: file, options: .atomic)
            return data
        }
        inflight[key] = task

        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inflight[key] == task { inflight[key] = nil }
        guard let data, let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    // MARK: 键与适用范围

    /// 只有本地卷上的非文件夹项目才生成缩略图；
    /// 网络卷要显式打开设置，且只对图片 / 视频 / PDF 这类「必须看一眼」的文件生成。
    static func supportsPreview(_ item: FileItem) -> Bool {
        guard !item.isDirectory, !item.isShare else { return false }
        if VolumeInspector.isLocal(item.url) { return true }
        guard ThumbnailSettings.shared.allowRemote else { return false }
        switch item.kind {
        case .image, .pdf:
            // 图片 / PDF 要把整段数据拉下来解码，限制体积
            guard let size = item.size, size > 0 else { return false }
            return size <= ThumbnailSettings.remoteSizeLimit
        case .video:
            // 视频由 AVFoundation 只取首帧附近的字节，体积再大也不必拦
            return true
        default:
            return false
        }
    }

    /// 设置切换后清空内存缓存（磁盘缓存仍然有效，下次直接命中）
    func invalidateMemory() {
        memory.removeAllObjects()
    }

    private static func key(for item: FileItem, size: CGFloat) -> String {
        let mtime = Int(item.modificationDate?.timeIntervalSince1970 ?? 0)
        return fnv1a("\(cacheGeneration)|\(item.url.path)|\(Int(size.rounded()))|\(mtime)")
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: 生成与磁盘

    private final class RequestBox: @unchecked Sendable {
        let request: QLThumbnailGenerator.Request
        init(_ request: QLThumbnailGenerator.Request) { self.request = request }
    }

    /// 磁盘缓存命中情况
    private enum CacheHit {
        case image(Data)
        /// 上次已经确认没有页面预览（空文件墓碑），且还在有效期内
        case tombstone
        case miss
    }

    /// 读磁盘缓存。空文件是「墓碑」：这只表示上一次判定没有真预览，
    /// 命中就返回 `.tombstone` 省掉一次 QuickLook 往返；超过宽限期删掉重问，
    /// 这样后来装了 QuickLook 插件也能自动恢复。
    private nonisolated static func readCache(_ file: URL) -> CacheHit {
        guard let data = try? Data(contentsOf: file) else { return .miss }
        guard data.isEmpty else {
            // 刷新访问时间，供 LRU 淘汰参考
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return .image(data)
        }
        let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if let written, Date().timeIntervalSince(written) < tombstoneTTL { return .tombstone }
        try? FileManager.default.removeItem(at: file)
        return .miss
    }

    /// 返回 PNG 数据（Sendable，可安全跨越 actor 边界）；没有真预览时返回 nil
    private nonisolated static func generatePNG(item: FileItem, points: CGFloat) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: points, height: points),
            scale: 2,
            representationTypes: .thumbnail
        )
        // 明确不要「图标模式」：那是把系统图标画在一张透明方框里，不是内容预览
        request.iconMode = false

        let box = RequestBox(request)
        let rep = await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        } onCancel: {
            // 否则关掉窗口/离开目录后 QuickLook 仍会继续读文件
            QLThumbnailGenerator.shared.cancel(box.request)
        }

        // 只认真正的预览：`.icon` 是透明方框里塞个文档图标（.aep / .prproj / .c4d 等
        // 没有 QuickLook 插件的类型就是这种），套上底板和投影会「阴影落在框上」。
        // 低质量预览（`.lowQualityThumbnail`）仍然是真内容，照收。
        guard let rep, rep.type != .icon else { return nil }
        let image = rep.nsImage
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 磁盘缓存超限时按修改时间从旧到新淘汰
    private nonisolated static func pruneDiskCache(dir: URL, limit: Int64) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int64, date: Date)] = []
        entries.reserveCapacity(files.count)
        var total: Int64 = 0
        for f in files {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            total += size
            entries.append((f, size, v?.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return }

        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > limit else { break }
            if (try? fm.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}

/// 生成并发闸门（QuickLook 同时跑几十个请求会拖垮 I/O）
private actor ThumbnailGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // 槽位直接转交给下一个等待者
            waiters.removeFirst().resume()
        }
    }
}

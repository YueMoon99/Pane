import Foundation

/// 判断路径是否位于本地卷。
///
/// 网络卷（SMB / AFP / NFS）上任何一次 `stat`、图标读取、QuickLook 缩略图生成
/// 都是一次网络往返；批量操作会把带宽打满，所以对这些卷要主动降级：
/// - 不生成缩略图 / 元数据（只显示系统图标）
/// - 不安装目录监听（SMB 上 `.write` 事件会持续触发重载）
enum VolumeInspector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    /// 同一卷只探测一次（键取路径前 3 段，如 `/Volumes/NAS`）
    static func isLocal(_ url: URL) -> Bool {
        let key = cacheKey(for: url)
        lock.lock()
        if let known = cache[key] {
            lock.unlock()
            return known
        }
        lock.unlock()

        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        // volumeIsLocal 为 nil 时按本地处理，避免误伤
        let local = values?.volumeIsLocal ?? true

        lock.lock()
        cache[key] = local
        lock.unlock()
        return local
    }

    private static func cacheKey(for url: URL) -> String {
        let parts = url.pathComponents
        return parts.prefix(3).joined(separator: "/")
    }

    /// 测试或卷状态变化时清空缓存
    static func resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

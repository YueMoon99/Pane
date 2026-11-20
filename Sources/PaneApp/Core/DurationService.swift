import Foundation
import AVFoundation
import SwiftUI

// MARK: - 媒体时长
//
// 视频 / 音频的持续时长，供列表视图「时长」列使用。
// 取时长要打开文件解析容器头，网络卷上还是一次 I/O，所以：
// - 结果按路径缓存（目录重绘、滚动来回都秒出）；
// - 异步加载，行先渲染、时长好了再补上；
// - 只对音频 / 视频文件发起请求，失败的记进 failed 不再重试。

@MainActor
@Observable
final class DurationService {
    static let shared = DurationService()

    /// 路径 → 秒数
    private var cache: [String: Double] = [:]
    /// 探测过但拿不到时长的（损坏文件 / 非媒体容器），避免反复重试
    private var failed: Set<String> = []
    private var inflight: Set<String> = []

    /// 行内直接用：拿得到返回格式化文本，拿不到先返回空串（加载中）
    func text(for item: FileItem) -> String {
        guard item.isMedia, !item.isDirectory else { return "" }
        let key = item.url.standardizedFileURL.path
        if let seconds = cache[key] { return Self.format(seconds) }
        if failed.contains(key) { return "" }
        request(item.url)
        return ""
    }

    private func request(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        Task {
            defer { inflight.remove(key) }
            guard FileManager.default.fileExists(atPath: key) else { return }
            if let seconds = await Self.load(url) {
                cache[key] = seconds
            } else {
                failed.insert(key)
            }
        }
    }

    /// 已缓存时长的快照（路径 → 秒）：后台排序线程拿不到 MainActor 状态，
    /// 由主线程在目录读取完成后取走，塞进 FileSort 里重排
    func durations(for items: [FileItem]) -> [String: Double] {
        var out: [String: Double] = [:]
        for item in items where item.isMedia {
            let key = item.url.standardizedFileURL.path
            if let seconds = cache[key] { out[key] = seconds }
        }
        return out
    }

    /// 后台解析容器头；损坏 / 不是媒体的返回 nil
    private static func load(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let cm = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(cm)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// 1:23:45 / 12:34
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

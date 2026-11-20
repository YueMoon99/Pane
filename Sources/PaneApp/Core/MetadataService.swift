import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import PDFKit

// MARK: - 元数据结果

struct FileMetadata: Sendable, Equatable {
    /// 图片 / 视频的像素尺寸（视频已应用旋转）
    var imageSize: CGSize?
    /// 音视频时长（秒）
    var duration: TimeInterval?
    /// PDF 页数
    var pageCount: Int?
    /// 附加信息（相机型号、光圈、ISO 等）
    var extra: [String] = []

    var isEmpty: Bool {
        imageSize == nil && duration == nil && pageCount == nil && extra.isEmpty
    }

    var dimensionText: String? {
        guard let size = imageSize, size.width > 0, size.height > 0 else { return nil }
        return L10n.tr("%@ × %@ 像素", Int(size.width.rounded()), Int(size.height.rounded()))
    }

    var durationText: String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    var pageText: String? {
        pageCount.map { L10n.tr("%@ 页", $0) }
    }

    /// 供界面直接展示的若干行
    var detailLines: [String] {
        [dimensionText, pageText, durationText].compactMap { $0 } + extra
    }
}

// MARK: - 元数据服务

/// 按需、异步、可取消地读取文件元数据（图片尺寸/EXIF、音视频时长、PDF 页数）
@MainActor
final class MetadataService {
    static let shared = MetadataService()

    private var cache: [String: FileMetadata] = [:]
    private var order: [String] = []
    private var inflight: [String: Task<FileMetadata, Never>] = [:]

    private static let cacheLimit = 600

    private init() {}

    func cached(_ item: FileItem) -> FileMetadata? {
        cache[Self.key(item)]
    }

    func metadata(for item: FileItem) async -> FileMetadata {
        let key = Self.key(item)
        if let hit = cache[key] { return hit }
        if let running = inflight[key] { return await running.value }

        let task = Task.detached(priority: .utility) { () -> FileMetadata in
            await Self.load(item)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        store(result, key: key)
        return result
    }

    private func store(_ value: FileMetadata, key: String) {
        if cache[key] == nil {
            order.append(key)
            if order.count > Self.cacheLimit {
                let overflow = order.count - Self.cacheLimit
                for old in order.prefix(overflow) { cache[old] = nil }
                order.removeFirst(overflow)
            }
        }
        cache[key] = value
    }

    private static func key(_ item: FileItem) -> String {
        let mtime = Int(item.modificationDate?.timeIntervalSince1970 ?? 0)
        return "\(item.url.path)|\(mtime)"
    }

    // MARK: 具体读取（后台）

    private nonisolated static func load(_ item: FileItem) async -> FileMetadata {
        // 网络卷上 ImageIO / AVFoundation / PDFKit 都会把整个文件读一遍，直接跳过
        guard VolumeInspector.isLocal(item.url) else { return FileMetadata() }
        switch item.kind {
        case .image:            return imageMetadata(item.url)
        case .pdf:              return pdfMetadata(item.url)
        case .video, .audio:    return await mediaMetadata(item.url, isVideo: item.kind == .video)
        default:                return FileMetadata()
        }
    }

    private nonisolated static func imageMetadata(_ url: URL) -> FileMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return FileMetadata()
        }
        var meta = FileMetadata()

        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            meta.imageSize = CGSize(width: w, height: h)
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String, !model.isEmpty {
            meta.extra.append(model)
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                meta.extra.append(String(format: "ƒ/%.1f", fNumber))
            }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
                meta.extra.append(exposure < 1
                    ? "1/\(Int((1 / exposure).rounded()))s"
                    : String(format: "%.1fs", exposure))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first {
                meta.extra.append("ISO \(iso)")
            }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                meta.extra.append(String(format: "%.0fmm", focal))
            }
        }
        return meta
    }

    private nonisolated static func pdfMetadata(_ url: URL) -> FileMetadata {
        guard let doc = PDFDocument(url: url) else { return FileMetadata() }
        var meta = FileMetadata()
        meta.pageCount = doc.pageCount
        if let page = doc.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            meta.imageSize = CGSize(width: bounds.width, height: bounds.height)
        }
        return meta
    }

    private nonisolated static func mediaMetadata(_ url: URL, isVideo: Bool) async -> FileMetadata {
        let asset = AVURLAsset(url: url)
        var meta = FileMetadata()

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { meta.duration = seconds }
        }

        if isVideo,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let oriented = natural.applying(transform)
            meta.imageSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }

        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            meta.extra.append("\(Int((rate / 1000).rounded())) kbps")
        }
        return meta
    }
}

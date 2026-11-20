import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 文件图标服务：复用访达原生图标（NSWorkspace），带内存缓存。
///
/// 网络卷上逐个读取真实图标会触发大量网络往返，因此降级为按类型的通用图标。
@MainActor
final class IconService {
    static let shared = IconService()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 4000 }

    func icon(for item: FileItem) -> NSImage {
        // 共享条目不是真实路径：用系统通用文件夹图标，
        // 既不会误读同名的本地目录（例如本地就有 /Users），也不触发网络往返
        if item.isShare {
            let key = "share" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            let image = NSWorkspace.shared.icon(for: .folder)
            cache.setObject(image, forKey: key)
            return image
        }

        let key = (VolumeInspector.isLocal(item.url) ? "local:" : "remote:") + item.url.path
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let image: NSImage
        if VolumeInspector.isLocal(item.url) {
            image = NSWorkspace.shared.icon(forFile: item.url.path)
        } else {
            image = Self.genericIcon(for: item)
        }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// 不触碰文件系统的通用类型图标
    private static func genericIcon(for item: FileItem) -> NSImage {
        NSWorkspace.shared.icon(for: item.kind.contentType)
    }
}

extension FileKind {
    /// 对应的 UTI，用于取通用系统图标
    var contentType: UTType {
        switch self {
        case .folder: .folder
        case .document: .data
        case .image: .image
        case .video: .movie
        case .audio: .audio
        case .archive: .archive
        case .code: .sourceCode
        case .pdf: .pdf
        case .app: .application
        case .share: .folder
        }
    }
}

/// 统一的文件图标视图：直接读取缓存图标，避免在表格/网格布局期间修改状态
struct FileIcon: View {
    let item: FileItem
    let size: CGFloat

    var body: some View {
        Image(nsImage: IconService.shared.icon(for: item))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

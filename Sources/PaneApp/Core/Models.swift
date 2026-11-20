import Foundation
import SwiftUI

// MARK: - 文件类型

enum FileKind: String, Sendable {
    case folder, document, image, video, audio, archive, code, pdf, app
    /// 服务器上的共享（尚未挂载的「虚拟文件夹」）
    case share

    var label: String {
        switch self {
        case .folder: L10n.tr("文件夹")
        case .document: L10n.tr("文稿")
        case .image: L10n.tr("图像")
        case .video: L10n.tr("视频")
        case .audio: L10n.tr("音频")
        case .archive: L10n.tr("归档")
        case .code: L10n.tr("源代码")
        case .pdf: L10n.tr("PDF 文稿")
        case .app: L10n.tr("应用程序")
        case .share: L10n.tr("共享")
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .document: "doc"
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .archive: "doc.zipper"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .pdf: "doc.richtext"
        case .app: "app"
        case .share: "externaldrive.connected.to.line.below"
        }
    }

    /// 类型语义色（仅在真实图标不可用时作为 SF Symbol 兜底色）
    var tint: Color {
        switch self {
        case .folder: .blue
        case .document: .secondary
        case .image: .purple
        case .video: .teal
        case .audio: .pink
        case .archive: .orange
        case .code: .indigo
        case .pdf: .red
        case .app: .blue
        case .share: .blue
        }
    }

    /// 由目录/包/UTI/扩展名推导类型
    static func `for`(isDirectory: Bool, isPackage: Bool, typeIdentifier uti: String?, name: String) -> FileKind {
        if isDirectory { return isPackage ? .app : .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "bmp", "webp", "avif":
            return .image
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "wmv", "flv":
            return .video
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "caf", "opus":
            return .audio
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "dmg", "iso", "xz", "zst":
            return .archive
        case "pdf":
            return .pdf
        case "swift", "m", "mm", "c", "cpp", "cc", "h", "hpp", "py", "js", "ts", "sh", "rb",
             "go", "java", "kt", "rs", "php", "json", "xml", "yaml", "yml", "html", "css",
             "txt", "md", "plist", "strings", "swiftpm":
            return .code
        case "app", "framework", "bundle", "prefpane", "qlgenerator", "mdimporter":
            return .app
        default:
            if let uti, uti.contains("image") { return .image }
            if let uti, uti.contains("video") { return .video }
            if let uti, uti.contains("audio") { return .audio }
            if let uti, uti.contains("pdf") { return .pdf }
            return .document
        }
    }
}

// MARK: - 复用的格式化器（逐行 new 一个 DateFormatter 在万项列表里非常慢）

enum DateFormats {
    /// 列表 / 画廊里的修改日期：年月日 + 到分钟（如「2026年12月31日 09:05」）。
    /// 时间用 `.short` 样式，跟随系统的地区与 12/24 小时制偏好。
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - 文件项（真实文件系统快照，以 URL 作为稳定标识）

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let kind: FileKind
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64?
    let modificationDate: Date?
    /// 服务器共享条目：还不是本地路径，双击才挂载
    var isShare: Bool = false
    /// 共享已经挂载时的挂载点（用于「已挂载」提示与避免重复挂载）
    var mountedURL: URL?

    /// 音频 / 视频等有时长的媒体文件（列表「时长」列的目标）
    var isMedia: Bool { kind == .audio || kind == .video }

    var id: URL { url }

    var sizeText: String {
        guard let s = size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
    }

    var dateText: String {
        guard let d = modificationDate else { return "—" }
        return DateFormats.dateTime.string(from: d)
    }

    /// 列表「种类」列：共享额外说明连接状态
    var kindText: String {
        guard isShare else { return kind.label }
        return mountedURL == nil ? L10n.tr("共享") : L10n.tr("共享（已挂载）")
    }

    /// 构造一条「共享」条目：URL 只是标识（smb://host/share），不对应本地路径
    static func share(_ name: String, host: String, mounted: URL?) -> FileItem {
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        comps.path = "/" + name
        let url = comps.url ?? URL(fileURLWithPath: "/Volumes/\(name)")
        return FileItem(
            url: url,
            name: name,
            kind: .share,
            isDirectory: true,
            isPackage: false,
            isHidden: name.hasPrefix("."),
            size: nil,
            modificationDate: nil,
            isShare: true,
            mountedURL: mounted
        )
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url == rhs.url }
}

// MARK: - 侧边栏数据（真实目录）

struct SidebarItem: Identifiable {
    let id: String
    let name: String
    let symbol: String?      // 提供了 url 时优先用真实文件夹图标
    let url: URL?
}

private func userDir(_ dir: FileManager.SearchPathDirectory) -> URL? {
    FileManager.default.urls(for: dir, in: .userDomainMask).first
}

let locations: [SidebarItem] = [
    .init(id: "loc-home",    name: L10n.tr("主目录"),   symbol: "house",          url: FileManager.default.homeDirectoryForCurrentUser),
    .init(id: "loc-desktop", name: L10n.tr("桌面"),     symbol: "desktopcomputer", url: userDir(.desktopDirectory)),
    .init(id: "loc-docs",    name: L10n.tr("文稿"),     symbol: "doc",            url: userDir(.documentDirectory)),
    .init(id: "loc-dl",      name: L10n.tr("下载"),     symbol: "arrow.down.doc", url: userDir(.downloadsDirectory)),
    .init(id: "loc-movies",  name: L10n.tr("影片"),     symbol: "film",           url: userDir(.moviesDirectory)),
    .init(id: "loc-music",   name: L10n.tr("音乐"),     symbol: "music.note",     url: userDir(.musicDirectory)),
    .init(id: "loc-pics",    name: L10n.tr("图片"),     symbol: "photo",          url: userDir(.picturesDirectory)),
    .init(id: "loc-apps",    name: L10n.tr("应用程序"), symbol: "app",            url: URL(fileURLWithPath: "/Applications")),
]

// 书签改由 BookmarkStore 管理（可增删、持久化），这里不再硬编码

struct TagColor: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
}

// label 存中文原文，显示时再翻译：这个全局数组只初始化一次，
// 若在这里翻译，运行中切换语言后标签颜色名会被冻结在旧语言。
let tagColors = [
    TagColor(label: "红色", color: .red),
    TagColor(label: "橙色", color: .orange),
    TagColor(label: "黄色", color: .yellow),
    TagColor(label: "绿色", color: .green),
    TagColor(label: "蓝色", color: .blue),
    TagColor(label: "紫色", color: .purple),
    TagColor(label: "灰色", color: .gray),
]

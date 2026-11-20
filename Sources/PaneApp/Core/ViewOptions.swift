import Foundation
import SwiftUI

// MARK: - 图标视图标签位置

enum IconLabelPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case below, right
    var id: String { rawValue }
    var title: String { self == .below ? L10n.tr("底部") : L10n.tr("右侧") }
}

// MARK: - 单个目录的视图选项（对应 ⌘J）

/// 数值默认值对齐 `03-UI设计与交互规范 §2.1`
struct ViewOptions: Codable, Equatable, Sendable {
    /// 图标视图图标边长：档位 64 / 80 / 96 / 128 / 160
    var iconSize: Double = 96
    /// 图标视图水平间距（垂直间距固定 16）
    var gridSpacing: Double = 12
    var labelPosition: IconLabelPosition = .below
    /// 是否用 QuickLook 缩略图替代系统图标
    var showThumbnails: Bool = true
    /// 图标视图标签字号
    var textSize: Double = 11
    /// 列视图列宽（可拖 140–400）
    var columnWidth: Double = 200
    /// 画廊视图预览区高度（可调 160–320）
    var galleryPreviewSize: Double = 200
    var showGalleryInfo: Bool = true

    static let iconSizeSteps: [Double] = [64, 80, 96, 128, 160]
    static let columnWidthRange: ClosedRange<Double> = 140...400
    static let galleryPreviewRange: ClosedRange<Double> = 160...320

    /// 放大 / 缩小一档（⌘+ / ⌘-）
    func steppedIconSize(up: Bool) -> Double {
        let steps = Self.iconSizeSteps
        if up {
            return steps.first { $0 > iconSize + 0.5 } ?? steps.last ?? iconSize
        }
        return steps.last { $0 < iconSize - 0.5 } ?? steps.first ?? iconSize
    }
}

// MARK: - 选项存储（按文件夹记忆，可继承）

/// 目录 → 选项的持久化存储。
///
/// 继承语义：某目录没有独立记录时，向上查找最近的、有独立记录的祖先目录；
/// 一路到根都没有，则使用全局默认值。
@MainActor
@Observable
final class ViewOptionsStore {
    static let shared = ViewOptionsStore()

    private let defaults = UserDefaults.standard
    private static let foldersKey = "viewOptions.folders.v1"
    private static let globalKey = "viewOptions.global.v1"

    private var folderMap: [String: ViewOptions]
    private(set) var global: ViewOptions

    /// 变更计数：让 SwiftUI 在 `options(for:)` 结果变化时刷新
    private(set) var revision = 0

    private init() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.foldersKey),
           let map = try? decoder.decode([String: ViewOptions].self, from: data) {
            folderMap = map
        } else {
            folderMap = [:]
        }
        if let data = UserDefaults.standard.data(forKey: Self.globalKey),
           let value = try? decoder.decode(ViewOptions.self, from: data) {
            global = value
        } else {
            global = ViewOptions()
        }
    }

    // MARK: 读取

    /// 当前目录实际生效的选项
    func options(for url: URL) -> ViewOptions {
        _ = revision
        return resolved(for: url)
    }

    /// 该目录是否有独立设置（否则跟随父级 / 全局默认）
    func isCustomized(_ url: URL) -> Bool {
        _ = revision
        return folderMap[url.standardizedFileURL.path] != nil
    }

    private func resolved(for url: URL) -> ViewOptions {
        var current = url.standardizedFileURL
        while true {
            if let value = folderMap[current.path] { return value }
            let parent = current.deletingLastPathComponent()
            if parent == current || current.path == "/" { break }
            current = parent
        }
        return global
    }

    // MARK: 写入

    /// 写入当前目录的独立设置
    func update(_ options: ViewOptions, for url: URL) {
        let key = url.standardizedFileURL.path
        guard folderMap[key] != options else { return }
        folderMap[key] = options
        revision &+= 1
        persist()
    }

    /// 清除当前目录的独立设置，回到「继承父级 / 全局」
    func clearOverride(for url: URL) {
        let key = url.standardizedFileURL.path
        guard folderMap.removeValue(forKey: key) != nil else { return }
        revision &+= 1
        persist()
    }

    /// 把当前选项保存为全局默认（之后没有独立记录的目录都用它）
    func saveAsGlobal(_ options: ViewOptions) {
        guard global != options else { return }
        global = options
        revision &+= 1
        persist()
    }

    /// 恢复出厂默认（全局默认 + 清空所有目录记忆）
    func resetAll() {
        global = ViewOptions()
        folderMap.removeAll()
        revision &+= 1
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(folderMap) {
            defaults.set(data, forKey: Self.foldersKey)
        }
        if let data = try? encoder.encode(global) {
            defaults.set(data, forKey: Self.globalKey)
        }
    }
}

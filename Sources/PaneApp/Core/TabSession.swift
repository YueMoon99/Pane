import Foundation
import SwiftUI

/// 一个标签页 = 一套完全独立的窗格状态：
/// 左右两栏各自的路径 / 历史 / 选择、布局、焦点与视图模式。
///
/// AppState 只持有 `[TabSession]` 与当前活动页；单栏、分栏相关的一切
/// 都通过 AppState 上的转发属性落到活动标签页上，因此旧的调用点无需改动。
@MainActor
@Observable
final class TabSession: Identifiable {
    let id: UUID

    var primary: PaneModel
    var secondary: PaneModel
    var layout: PaneLayout
    var focusedSlot: PaneSlot
    var primaryViewMode: ViewMode
    var secondaryViewMode: ViewMode
    /// 分隔条比例：左右切分与上下切分各记一套，属于这个标签页的工作区状态
    var horizontalRatio: Double
    var verticalRatio: Double

    /// 用户手动改过标题时固定下来，nil 表示跟随当前目录
    var customTitle: String?

    init(
        id: UUID = UUID(),
        primary: URL,
        secondary: URL? = nil,
        layout: PaneLayout = .single,
        focusedSlot: PaneSlot = .primary,
        primaryViewMode: ViewMode = .icon,
        secondaryViewMode: ViewMode = .icon,
        horizontalRatio: Double = 0.5,
        verticalRatio: Double = 0.5,
        customTitle: String? = nil
    ) {
        self.id = id
        self.primary = PaneModel(initial: primary, slot: .primary)
        self.secondary = PaneModel(initial: secondary ?? primary, slot: .secondary)
        self.layout = layout
        self.focusedSlot = layout == .single ? .primary : focusedSlot
        self.primaryViewMode = primaryViewMode
        self.secondaryViewMode = secondaryViewMode
        self.horizontalRatio = horizontalRatio
        self.verticalRatio = verticalRatio
        self.customTitle = customTitle
    }

    var focusedPane: PaneModel {
        focusedSlot == .primary ? primary : secondary
    }

    func pane(for slot: PaneSlot) -> PaneModel {
        slot == .primary ? primary : secondary
    }

    func viewMode(for slot: PaneSlot) -> ViewMode {
        slot == .primary ? primaryViewMode : secondaryViewMode
    }

    func setViewMode(_ mode: ViewMode, for slot: PaneSlot) {
        switch slot {
        case .primary: primaryViewMode = mode
        case .secondary: secondaryViewMode = mode
        }
    }

    /// 单栏标题：当前栏的目录名（服务器根显示备注名）
    var primaryTitle: String { primary.displayTitle }

    /// 另一栏标题：单栏时也有值（标签页没切分时用不到）
    var secondaryTitle: String { secondary.displayTitle }

    var isSplit: Bool { layout != .single }

    /// 标签标题：优先用户自定义，否则按切分状态拼「A / B」。
    /// 单栏只显示一栏的目录名；左右（或上下）切分时两栏目录名用「空格 斜线 空格」连接。
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        guard isSplit else { return primaryTitle }
        return "\(primaryTitle) / \(secondaryTitle)"
    }

    /// 悬停提示：单栏给一条路径，切分时两栏路径分行列出
    var helpText: String {
        let primaryPath = primary.displayURL.isFileURL ? primary.displayURL.path : primary.displayTitle
        guard isSplit else { return primaryPath }
        let secondaryPath = secondary.displayURL.isFileURL ? secondary.displayURL.path : secondary.displayTitle
        return primaryPath + "\n" + secondaryPath
    }

    /// 目录名；根目录等没有 lastPathComponent 的取整条路径
    static func folderName(of url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    /// 落盘用：文件路径原样保存（兼容旧数据），服务器位置保存成 `smb://host`
    static func stored(_ url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    /// 让另一栏跟本栏同目录（跨栏同步 / 新标签页复用位置）
    var otherSlot: PaneSlot {
        focusedSlot == .primary ? .secondary : .primary
    }

    /// 分隔条比例（按切分方向取值）
    func ratio(for layout: PaneLayout) -> Double {
        layout == .vertical ? verticalRatio : horizontalRatio
    }

    func setRatio(_ value: Double, for layout: PaneLayout) {
        if layout == .vertical { verticalRatio = value } else { horizontalRatio = value }
    }

    var snapshot: TabSnapshot {
        TabSnapshot(
            id: id.uuidString,
            primary: Self.stored(primary.url),
            secondary: Self.stored(secondary.url),
            layout: layout.rawValue,
            focused: focusedSlot == .primary ? "primary" : "secondary",
            primaryMode: primaryViewMode.rawValue,
            secondaryMode: secondaryViewMode.rawValue,
            hRatio: horizontalRatio,
            vRatio: verticalRatio,
            title: customTitle
        )
    }

    static func restore(from snapshot: TabSnapshot) -> TabSession {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        /// 旧数据里只有文件路径；新数据还可能是 `smb://host`（服务器共享列表）
        func resolve(_ stored: String) -> URL {
            if !stored.hasPrefix("/"), let url = URL(string: stored),
               url.scheme == "smb", let host = url.host, !host.isEmpty {
                return ServerModel.shared.location(forHost: host).url
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: stored, isDirectory: &isDir), isDir.boolValue else { return home }
            return URL(fileURLWithPath: stored)
        }
        // 旧数据没有比例字段：回落到旧版全局比例，再回落到均分
        let legacy = UserDefaults.standard
        let fallbackH = legacy.object(forKey: "paneSplitRatio.horizontal") as? Double ?? 0.5
        let fallbackV = legacy.object(forKey: "paneSplitRatio.vertical") as? Double ?? 0.5
        return TabSession(
            id: snapshot.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
            primary: resolve(snapshot.primary),
            secondary: resolve(snapshot.secondary),
            layout: PaneLayout(rawValue: snapshot.layout) ?? .single,
            focusedSlot: snapshot.focused == "secondary" ? .secondary : .primary,
            primaryViewMode: ViewMode(rawValue: snapshot.primaryMode) ?? .icon,
            secondaryViewMode: ViewMode(rawValue: snapshot.secondaryMode) ?? .icon,
            horizontalRatio: clampRatio(snapshot.hRatio ?? fallbackH),
            verticalRatio: clampRatio(snapshot.vRatio ?? fallbackV),
            customTitle: snapshot.title
        )
    }

    private static func clampRatio(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0.15), 0.85)
    }
}

/// 标签页的可持久化描述（窗口恢复用）
///
/// 记录的是「工作区状态」而不只是路径：布局方向、两侧宽度/高度比例、
/// 每栏的视图模式都在这里，所以重启后能回到离开时的那一屏。
struct TabSnapshot: Codable, Sendable {
    var id: String?
    var primary: String
    var secondary: String
    var layout: String
    var focused: String
    var primaryMode: String
    var secondaryMode: String
    /// 旧版本没有这两个字段（可选值保证旧数据仍能解码）
    var hRatio: Double?
    var vRatio: Double?
    var title: String?
}

/// 标签页读写：UserDefaults + JSON，键名带版本便于以后迁移
enum TabStore {
    private static let tabsKey = "tabs.v1"
    private static let activeKey = "tabs.active.v1"

    static func load() -> (tabs: [TabSnapshot], active: String?) {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: tabsKey),
              let tabs = try? JSONDecoder().decode([TabSnapshot].self, from: data) else {
            return ([], nil)
        }
        return (tabs, defaults.string(forKey: activeKey))
    }

    static func save(_ tabs: [TabSnapshot], active: String) {
        let defaults = UserDefaults.standard
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: tabsKey)
        defaults.set(active, forKey: activeKey)
    }
}

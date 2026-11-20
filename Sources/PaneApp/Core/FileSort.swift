import Foundation
import SwiftUI

// MARK: - 排序
//
// 排序是**每个窗格自己**的设置（切分时左右互不影响），
// 状态挂在 PaneModel 上并按槽位持久化；
// 菜单 / 右键 / 列表表头三处入口改的都是「焦点窗格 / 本窗格」的排序，
// 在后台线程的目录读取里直接排好，主线程只改设置不排数据。

/// 按哪个字段排
enum SortField: String, CaseIterable, Identifiable, Sendable {
    case name, kind, size, date, duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: L10n.tr("名称")
        case .kind: L10n.tr("种类")
        case .size: L10n.tr("大小")
        case .date: L10n.tr("修改日期")
        case .duration: L10n.tr("时长")
        }
    }
}

/// 一次排序的完整描述（可跨 actor 传给目录读取）
struct FileSort: Sendable, Equatable {
    var field: SortField = .name
    var ascending = true
    /// 时长排序用的快照（路径 → 秒）：时长在 DurationService 里异步积累，
    /// 后台排序线程拿不到，由主线程在读取完成后塞进来重排一次
    var durations: [String: Double] = [:]

    /// 文件夹永远在前（访达习惯），其余按所选字段排
    func applied(to items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result = compare(a, b)
            if result == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch field {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .kind:
            return a.kindText.localizedStandardCompare(b.kindText)
        case .size:
            let lhs = a.size ?? -1
            let rhs = b.size ?? -1
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case .date:
            let lhs = a.modificationDate ?? .distantPast
            let rhs = b.modificationDate ?? .distantPast
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case .duration:
            let lhs = durations[a.url.standardizedFileURL.path] ?? -1
            let rhs = durations[b.url.standardizedFileURL.path] ?? -1
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }
}

import Foundation
import AppKit
import Observation

// MARK: - 书签
//
// 侧边栏「书签」分组的唯一数据源：右键任意文件夹即可加进来，
// 右键书签行即可移除。持久化在 UserDefaults 的 bookmarks.v1（JSON），
// 顺序就是侧边栏里的顺序。

struct Bookmark: Identifiable, Codable, Hashable {
    var id: UUID
    /// 标准化后的绝对路径
    var path: String
    /// 显示名；为空时退回文件夹名
    var name: String

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { name.isEmpty ? url.lastPathComponent : name }
}

@MainActor
@Observable
final class BookmarkStore {
    /// 侧边栏与命令共用一份
    static let shared = BookmarkStore()

    private(set) var items: [Bookmark] = []

    private let defaults = UserDefaults.standard
    private static let storageKey = "bookmarks.v1"
    private static let seededKey = "bookmarks.seeded.v1"

    private init() {
        load()
    }

    // MARK: 查询

    func contains(_ url: URL) -> Bool {
        let target = Self.normalizedPath(url)
        return items.contains { Self.normalizedPath(URL(fileURLWithPath: $0.path)) == target }
    }

    @discardableResult
    func add(_ url: URL, name: String? = nil) -> Bookmark? {
        guard url.isFileURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        guard !contains(url) else { return nil }

        let item = Bookmark(
            id: UUID(),
            path: Self.normalizedPath(url),
            name: (name ?? url.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        )
        items.append(item)
        save()
        return item
    }

    /// 批量添加，返回真正新增的条数（已存在的会跳过）
    @discardableResult
    func add(contentsOf urls: [URL]) -> Int {
        var added = 0
        for url in urls where add(url) != nil { added += 1 }
        return added
    }

    // MARK: 修改

    func remove(_ bookmark: Bookmark) {
        remove(id: bookmark.id)
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        save()
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].name = trimmed
        save()
    }

    /// 拖动排序
    func move(from: Int, to: Int) {
        guard items.indices.contains(from) else { return }
        var target = to
        if target > from { target -= 1 }
        target = min(max(target, 0), items.count - 1)
        guard target != from else { return }
        let item = items.remove(at: from)
        items.insert(item, at: target)
        save()
    }

    // MARK: 持久化

    private func load() {
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = saved
            return
        }
        // 首次运行，或从旧版（硬编码常量）升级过来：种入那两个默认位置。
        // 种过就不再种——用户清空书签后应该保持空。
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 沿用旧版的两个默认书签：名字与顺序都和硬编码时期一致
        let seeds: [(URL, String)] = [
            (home.appendingPathComponent("WorkBuddy WorkSpace/Pane"), L10n.tr("Pane 项目")),
            (home.appendingPathComponent("WorkBuddy WorkSpace"), L10n.tr("工作区")),
        ]
        var isDir: ObjCBool = false
        for (url, name) in seeds
        where FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
            items.append(Bookmark(id: UUID(), path: url.path, name: name))
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

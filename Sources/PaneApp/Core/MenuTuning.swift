import AppKit

/// 系统菜单微调
///
/// SwiftUI 给 WindowGroup 自动加了「关闭窗口 / 关闭全部」两项，并把它们占着 ⌘W。
/// 这里的 ⌘W 语义是「关闭标签页」（单标签时重置工作区，见 README 的取舍说明），
/// 所以启动后把这两项摘掉，再把 ⌘W 交给「关闭标签页」。
/// 菜单重建时可能被覆盖，调用方会多跑一次。
@MainActor
enum MenuTuning {
    static func apply() {
        guard let main = NSApp.mainMenu else { return }
        // 「关闭」用的是 performClose:，「全部关闭」用的是私有名字 closeAll:，
        // 所以按选择器名字匹配，避免依赖本地化后的标题
        let closeActions: Set<String> = ["performClose:", "closeAll:"]

        for menu in main.items.compactMap(\.submenu) {
            let targets = menu.items.filter { item in
                guard let action = item.action else { return false }
                return closeActions.contains(NSStringFromSelector(action))
            }
            for item in targets {
                menu.removeItem(item)
            }
        }

        // 冲突解除后 SwiftUI 已经跳过了 ⌘W，这里补回去
        for menu in main.items.compactMap(\.submenu) {
            for item in menu.items where item.title == L10n.tr("关闭标签页") && item.keyEquivalent.isEmpty {
                item.keyEquivalent = "w"
                item.keyEquivalentModifierMask = [.command]
            }
        }
    }
}

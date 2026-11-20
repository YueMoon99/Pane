import AppKit

// MARK: - 工作区登记表

/// 窗口 ↔ AppState 的对应关系。
///
/// 之前每个 AppState 各自装一个 NSEvent 本地监听器，窗口关掉后实例仍被
/// SwiftUI 持有（或尚未释放），旧监听器会和新窗口的监听器一起响应同一个
/// 按键——表现出来就是「⌘V 有时粘贴到了上一个窗口的右栏」。
/// 现在改成全进程只有一个监听器，按 `NSApp.keyWindow` 找到对应工作区再派发。
@MainActor
enum WorkspaceRegistry {
    /// 主窗口（设置窗口、菜单需要拿到「当前工作区」）
    static weak var primary: AppState?

    /// 所有还活着的工作区（弱引用，窗口关掉后自动失效）
    private static let live = NSHashTable<AppState>.weakObjects()

    static func register(_ app: AppState) {
        live.add(app)
    }

    /// 窗口 → 工作区（sheet 按键算在它的父窗口上）
    static func workspace(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        let all = live.allObjects
        if let direct = all.first(where: { $0.window === window }) { return direct }
        if let parent = window.sheetParent {
            return all.first { $0.window === parent }
        }
        return nil
    }

    /// 是否已经有一个「窗口还开着」的主工作区。
    /// 点 X 关窗后窗口变 nil，新的实例就能接管标签页存储并恢复上次的页面。
    static func hasOpenPrimary() -> Bool {
        live.allObjects.contains { $0.persistsTabs && $0.window != nil }
    }
}

// MARK: - 键盘派发

@MainActor
enum KeyRouter {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // assumeIsolated 要求返回值是 Sendable，而 NSEvent 不是，
            // 所以在这里用外部变量接结果，闭包里只做派发。
            var handled: NSEvent? = event
            MainActor.assumeIsolated {
                // 弹出确认框 / 输入框（sheet）时，按键归那个窗口自己。
                // 否则回车会顺手把底下的文件送进重命名。
                if let parent = NSApp.keyWindow, parent.attachedSheet != nil { return }

                if let target = WorkspaceRegistry.workspace(for: NSApp.keyWindow) {
                    handled = target.handleKey(event)
                } else if QuickLookCoordinator.shared.isVisible,
                          QuickLookCoordinator.shared.handleKey(event) {
                    // QuickLook 面板是独立窗口，拿不到工作区：空格 / Esc / 方向键在这里收
                    handled = nil
                }
            }
            return handled
        }
    }
}

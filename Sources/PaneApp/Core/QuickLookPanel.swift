import AppKit
import Quartz

// MARK: - 空格键快速查看（QuickLook）
//
// 直接驱动系统的 `QLPreviewPanel`：它自带缩放、翻页、音视频播放，
// 也能预览我们不想自己渲染的格式（Keynote、Sketch、压缩包目录…）。
//
// 位置 / 选择同步全由这里管，而不是靠「响应链接管面板」：
// 面板是独立窗口，它成为 key window 之后应用内的按键派发（KeyRouter）
// 就拿不到工作区了，所以面板窗口里的空格、Esc、方向键也在这里处理。

@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    /// 面板可以翻页的整批项目（当前目录的全部内容）
    private var items: [FileItem] = []
    private weak var app: AppState?

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    // MARK: 开关

    /// 空格：没开就预览当前选择，已经开着就关掉
    func toggle(for app: AppState) {
        if isVisible {
            close()
            return
        }
        let pane = app.focused
        // 共享列表里的条目还不是真实路径，QuickLook 打不开
        guard !pane.isServerRoot, !pane.items.isEmpty else {
            NSSound.beep()
            return
        }
        guard let current = pane.selectedItems().first else {
            NSSound.beep()
            return
        }
        self.app = app
        items = pane.items
        guard let panel = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index(of: current.url)
        panel.makeKeyAndOrderFront(nil)
        debugLog("[quicklook] open \(items.count) item(s), index=\(panel.currentPreviewItemIndex)")
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
        panel.dataSource = nil
        panel.delegate = nil
        items = []
        debugLog("[quicklook] close")
    }

    /// 窗格里的选择变了：面板跟着翻到同一项（选择被清空就关掉面板）
    func selectionChanged() {
        guard isVisible, let app else { return }
        let pane = app.focused
        guard !pane.isServerRoot else { close(); return }
        guard let current = pane.selectedItems().first else {
            close()
            return
        }
        items = pane.items
        QLPreviewPanel.shared()?.currentPreviewItemIndex = index(of: current.url)
    }

    // MARK: 面板窗口里的按键
    //
    // 面板是 key window 时 KeyRouter 找不到工作区，这些键由这里兜住。

    func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        guard flags.isEmpty else { return false }

        switch event.keyCode {
        case 49:            // 空格：关掉面板，回到窗格
            close()
            return true
        case 53:            // Esc
            close()
            return true
        default:
            break
        }

        // 方向键：改的是窗格里的选择，面板会跟着翻页
        if let direction = PaneModel.MoveDirection(rawValue: event.keyCode), let app {
            app.focused.moveSelection(direction, columns: 1)
            return true
        }
        return false
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        return items[index].url as NSURL
    }

    /// 返回 false：让面板自己处理缩放、滚轮等事件
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }

    private func index(of url: URL) -> Int {
        items.firstIndex { $0.url == url } ?? 0
    }
}

import SwiftUI
import AppKit

/// 用 AppKit 原生鼠标事件区分单击/双击，并顺带承担「拖出 / 接收拖放」。
///
/// 解决 SwiftUI 同时挂 onTapGesture 与 onTapGesture(count:2) 时，
/// 单击必须等待双击超时（约 0.3–1s）才触发的问题。
struct ClickCatcher: NSViewRepresentable {
    var draggedURLs: () -> [URL] = { [] }
    var onDrop: (([URL], _ move: Bool) -> Bool)? = nil
    /// 拖到废纸篓时回调（系统只回报 .delete，删除动作要拖拽源自己完成）
    var onTrash: (([URL]) -> Void)? = nil
    /// 右键按下：用来先把「没被选中的那一项」选中，再弹菜单（访达语义）
    var onRightClick: (() -> Void)? = nil
    /// 放在最后，保证 `ClickCatcher { count, flags, point in ... }` 的尾随闭包写法可用。
    /// point 是与 SwiftUI `.global` 一致的窗口坐标（左上原点、y 向下），
    /// 用于判断这次点击是否落在文件名文字上。
    let onClick: (_ count: Int, _ flags: NSEvent.ModifierFlags, _ point: CGPoint) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ClickView) {
        view.onClick = onClick
        view.draggedURLs = draggedURLs
        view.onDrop = onDrop
        view.onTrash = onTrash
        view.onRightClick = onRightClick
        view.refreshDropRegistration()
    }

    final class ClickView: NSView, NSDraggingSource {
        var onClick: ((Int, NSEvent.ModifierFlags, CGPoint) -> Void)?
        var draggedURLs: (() -> [URL])?
        var onDrop: (([URL], Bool) -> Bool)?
        var onTrash: (([URL]) -> Void)?
        var onRightClick: (() -> Void)?

        private var pressEvent: NSEvent?
        private var draggingStarted = false
        /// 本次拖拽携带的文件，拖到废纸篓时用来自行删除
        private var draggingURLs: [URL] = []

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        func refreshDropRegistration() {
            if onDrop == nil {
                unregisterDraggedTypes()
            } else {
                registerForDraggedTypes([.fileURL])
            }
        }

        // MARK: 点击

        override func mouseDown(with event: NSEvent) {
            pressEvent = event
            draggingStarted = false
            // 保持默认行为（激活窗口），但不交给 SwiftUI 手势
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !draggingStarted, let start = pressEvent else { return }
            let dx = event.locationInWindow.x - start.locationInWindow.x
            let dy = event.locationInWindow.y - start.locationInWindow.y
            guard dx * dx + dy * dy > 16 else { return }
            draggingStarted = true
            debugLog("[drag] source start")
            beginFileDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            if !draggingStarted {
                onClick?(event.clickCount, event.modifierFlags, Self.globalPoint(of: event))
            }
            pressEvent = nil
            draggingStarted = false
        }

        /// 把鼠标位置换算成与 SwiftUI `.global` 一致的坐标（窗口内容区内、左上原点、y 向下）。
        /// 这样上层量到的文件名矩形可以直接用 contains 判断。
        static func globalPoint(of event: NSEvent) -> CGPoint {
            guard let window = event.window, let content = window.contentView else { return .zero }
            var p = content.convert(event.locationInWindow, from: nil)
            if !content.isFlipped {
                p.y = content.bounds.height - p.y
            }
            return p
        }

        // MARK: 拖出

        /// 右键：先让上层把该行选中，再交给系统的上下文菜单流程
        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
            super.rightMouseDown(with: event)
        }

        private func beginFileDrag(with event: NSEvent) {
            guard let urls = draggedURLs?(), !urls.isEmpty else { return }
            draggingURLs = urls
            let origin = convert(event.locationInWindow, from: nil)

            var items: [NSDraggingItem] = []
            items.reserveCapacity(urls.count)
            for (index, url) in urls.enumerated() {
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 40, height: 40)
                let offset = CGFloat(min(index, 6)) * 6
                let frame = NSRect(x: origin.x - 20 + offset,
                                   y: origin.y - 20 - offset,
                                   width: 40, height: 40)
                item.setDraggingFrame(frame, contents: icon)
                items.append(item)
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // 拖到其它 App 时也必须声明 .move/.delete，否则 Dock 上的废纸篓不受理投放，
            // 拖拽会穿透 Dock 落到桌面上（变成一次莫名其妙的复制）。
            // 仍保留 .copy：按住 ⌥ 拖到访达就是复制。
            context == .outsideApplication ? [.copy, .move, .delete] : [.copy, .move]
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

        /// 拖到 Dock 的废纸篓时，系统只在会话结束时回报 `.delete`，
        /// 真正的删除必须由拖拽源执行（Finder 也是这样做的）。
        func draggingSession(_ session: NSDraggingSession,
                             endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            let urls = draggingURLs
            draggingURLs = []
            guard operation == .delete, !urls.isEmpty else { return }
            onTrash?(urls)
        }

        // MARK: 接收拖放

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
                  !objects.isEmpty else { return nil }
            return objects
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard onDrop != nil, fileURLs(from: sender.draggingPasteboard) != nil else { return [] }
            return NSEvent.modifierFlags.contains(.option) ? .move : .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            draggingEntered(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onDrop != nil && fileURLs(from: sender.draggingPasteboard) != nil
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let urls = fileURLs(from: sender.draggingPasteboard) else {
                debugLog("[drag] perform: no file urls")
                return false
            }
            let move = NSEvent.modifierFlags.contains(.option)
            let accepted = onDrop?(urls, move) ?? false
            debugLog("[drag] perform urls=\(urls.count) move=\(move) accepted=\(accepted)")
            return accepted
        }
    }
}

// MARK: - 窗格焦点

final class PaneFocusAction: @unchecked Sendable {
    var action: () -> Void
    init(_ action: @escaping () -> Void = {}) { self.action = action }
}

private struct PaneFocusKey: EnvironmentKey {
    static let defaultValue = PaneFocusAction()
}

extension EnvironmentValues {
    var paneFocus: PaneFocusAction {
        get { self[PaneFocusKey.self] }
        set { self[PaneFocusKey.self] = newValue }
    }
}

// MARK: - 窗格活动状态

/// 切分模式下只有一个窗格是「活动」的：非活动侧保留选择，但用灰色底表示失焦。
private struct PaneActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var paneActive: Bool {
        get { self[PaneActiveKey.self] }
        set { self[PaneActiveKey.self] = newValue }
    }
}

// MARK: - 拖拽上下文（拖出哪些文件 / 放到哪里）

struct PaneDragDrop: @unchecked Sendable {
    /// 某个单元格被拖动时应携带的文件（通常按当前选择）
    var dragURLs: (FileItem?) -> [URL] = { _ in [] }
    /// 有文件被拖入本窗格：返回是否已受理
    var dropURLs: ([URL], FileItem?, Bool) -> Bool = { _, _, _ in false }
    /// 拖拽落进废纸篓：交给服务层移到废纸篓并刷新
    var trashURLs: ([URL]) -> Void = { _ in }
}

private struct PaneDragDropKey: EnvironmentKey {
    static let defaultValue = PaneDragDrop()
}

extension EnvironmentValues {
    var paneDragDrop: PaneDragDrop {
        get { self[PaneDragDropKey.self] }
        set { self[PaneDragDropKey.self] = newValue }
    }
}

/// 在触发点击前先切换当前窗格焦点（ClickCatcher 会拦截 SwiftUI 手势）
struct PaneClickCatcher: View {
    var item: FileItem?
    var onRightClick: (() -> Void)?
    let onClick: (Int, NSEvent.ModifierFlags, CGPoint) -> Void

    @Environment(\.paneFocus) private var focus
    @Environment(\.paneDragDrop) private var dragDrop

    init(item: FileItem? = nil,
         onRightClick: (() -> Void)? = nil,
         onClick: @escaping (Int, NSEvent.ModifierFlags, CGPoint) -> Void) {
        self.item = item
        self.onRightClick = onRightClick
        self.onClick = onClick
    }

    var body: some View {
        ClickCatcher(
            draggedURLs: {
                dragDrop.dragURLs(item)
            },
            onDrop: { urls, move in
                focus.action()
                return dragDrop.dropURLs(urls, item, move)
            },
            onTrash: { urls in
                dragDrop.trashURLs(urls)
            },
            onRightClick: {
                focus.action()
                onRightClick?()
            },
            onClick: { count, flags, point in
                focus.action()
                onClick(count, flags, point)
            }
        )
    }
}

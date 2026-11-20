import SwiftUI
import AppKit

// MARK: - 框选（marquee）
//
// 在空白处按下并拖动，画出选框，松开后把与选框相交的项目全部选中。
// 按住 ⌘ / ⇧ 拖动是「追加选择」，与访达一致。
//
// 实现要点：
// - 事件由背景里的 NSView 接（空白处本来就有「点一下取消选择」的视图，两者合一）；
// - 每个单元用 GeometryReader 把自己在同一个坐标空间里的位置报上来；
// - 选框本身画在最上层 overlay 里，且不参与命中测试。

enum Marquee {
    /// 框选用的坐标空间名；每个窗格各自解析自己的容器，互不干扰
    static let space = "PaneMarqueeSpace"
    /// 拖动超过这个距离才算框选，否则当单击
    static let dragThreshold: CGFloat = 3
}

/// 单元位置收集：key 是文件 URL，value 是该单元在框选坐标空间中的矩形
struct ItemFramePreference: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 事件捕获

struct MarqueeCatcher: NSViewRepresentable {
    var onFocus: () -> Void = {}
    var onBegin: () -> Void = {}
    var onChange: (CGRect, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// rect 为 nil 表示这只是一次单击（没有拖动）
    var onEnd: (CGRect?, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// 空白处接收拖放：返回是否受理（nil 表示这块地方不接收拖放）
    var onDrop: (([URL], _ move: Bool) -> Bool)? = nil
    /// 拖拽悬停进入 / 离开，用来画高亮
    var onTargeted: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> MarqueeView {
        let view = MarqueeView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: MarqueeView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: MarqueeView) {
        view.onFocus = onFocus
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
        view.onDrop = onDrop
        view.onTargeted = onTargeted
        view.refreshDropRegistration()
    }

    final class MarqueeView: NSView {
        var onFocus: () -> Void = {}
        var onBegin: () -> Void = {}
        var onChange: (CGRect, NSEvent.ModifierFlags) -> Void = { _, _ in }
        var onEnd: (CGRect?, NSEvent.ModifierFlags) -> Void = { _, _ in }
        var onDrop: (([URL], Bool) -> Bool)?
        var onTargeted: (Bool) -> Void = { _ in }

        private var start: CGPoint?
        private var isDragging = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // MARK: 空白处接收拖放

        /// 空白区域同样要能接文件：只给每一行挂投递目标时，
        /// 空文件夹（一屏全是空白）会变成「拖进去毫无反应」。
        func refreshDropRegistration() {
            if onDrop == nil {
                unregisterDraggedTypes()
            } else {
                registerForDraggedTypes([.fileURL])
            }
        }

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
                  !objects.isEmpty else { return nil }
            return objects
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard onDrop != nil, fileURLs(from: sender.draggingPasteboard) != nil else { return [] }
            onTargeted(true)
            return NSEvent.modifierFlags.contains(.option) ? .move : .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard onDrop != nil, fileURLs(from: sender.draggingPasteboard) != nil else { return [] }
            return NSEvent.modifierFlags.contains(.option) ? .move : .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargeted(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onDrop != nil && fileURLs(from: sender.draggingPasteboard) != nil
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargeted(false)
            guard let urls = fileURLs(from: sender.draggingPasteboard) else { return false }
            return onDrop?(urls, NSEvent.modifierFlags.contains(.option)) ?? false
        }

        override func mouseDown(with event: NSEvent) {
            onFocus()
            start = convert(event.locationInWindow, from: nil)
            isDragging = false
            // 交给默认实现，保证点空白也能激活窗口
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = convert(event.locationInWindow, from: nil)
            if !isDragging {
                let dx = point.x - start.x
                let dy = point.y - start.y
                guard dx * dx + dy * dy > Marquee.dragThreshold * Marquee.dragThreshold else { return }
                isDragging = true
                onBegin()
            }
            onChange(rect(from: start, to: point), event.modifierFlags)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                start = nil
                isDragging = false
            }
            let point = convert(event.locationInWindow, from: nil)
            if isDragging, let start {
                onEnd(rect(from: start, to: point), event.modifierFlags)
            } else {
                onEnd(nil, event.modifierFlags)
            }
        }

        private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
            CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                   width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }
}

// MARK: - 挂在容器上的框选能力

private struct MarqueeSelectionModifier: ViewModifier {
    @Bindable var model: PaneModel
    /// 空白处单击（没有拖动）时的动作：取消选择
    let onTap: () -> Void

    @Environment(\.paneFocus) private var focus
    @Environment(\.paneDragDrop) private var dragDrop

    @State private var rect: CGRect?
    @State private var base: Set<URL> = []
    @State private var frames: [URL: CGRect] = [:]
    /// 有文件悬停在空白处：整块内容画一圈蓝框，表示「松手就放这儿」
    @State private var dropTargeted = false

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: Marquee.space)
            .background {
                MarqueeCatcher(
                    onFocus: { focus.action() },
                    onBegin: { base = model.selection },
                    onChange: { rect, flags in
                        self.rect = rect
                        apply(rect, additive: isAdditive(flags))
                    },
                    onEnd: { rect, flags in
                        if let rect {
                            apply(rect, additive: isAdditive(flags))
                        } else {
                            onTap()
                        }
                        self.rect = nil
                    },
                    onDrop: { urls, move in
                        guard !model.isServerRoot else { return false }
                        focus.action()
                        // item 传 nil：落点是本窗格当前目录
                        return dragDrop.dropURLs(urls, nil, move)
                    },
                    onTargeted: { dropTargeted = $0 }
                )
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.05))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let rect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay {
                            Rectangle().strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(ItemFramePreference.self) { frames = $0 }
    }

    private func isAdditive(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) || flags.contains(.shift)
    }

    private func apply(_ rect: CGRect, additive: Bool) {
        let hits = Set(frames.filter { $0.value.intersects(rect) }.keys)
        model.setSelection(additive ? base.union(hits) : hits)
    }
}

extension View {
    /// 给内容容器（需要被 frame 撑满整块可视区）开启框选
    func marqueeSelection(model: PaneModel, onTap: @escaping () -> Void) -> some View {
        modifier(MarqueeSelectionModifier(model: model, onTap: onTap))
    }

    /// 单元把自身位置报告给框选层
    func marqueeFrame(for url: URL) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ItemFramePreference.self,
                    value: [url: proxy.frame(in: .named(Marquee.space))]
                )
            }
        }
    }
}

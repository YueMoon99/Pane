import SwiftUI
import AppKit

// MARK: - 行内重命名输入框
//
// 用 AppKit 的 NSTextField 而不是 SwiftUI 的 TextField：
// - 进入编辑时只选中「主文件名」，扩展名不动（访达的行为）；
// - 回车提交、Esc 取消、点到别处提交，这三件事在 NSTextField 里是明确的；
// - 不用把每次按键写回 @Observable 的模型，避免敲一个字母整屏重排。

struct RenameField: NSViewRepresentable {
    /// 进入编辑时的初始名字
    let initialText: String
    var fontSize: CGFloat = 12
    var alignment: NSTextAlignment = .left
    /// 提交时把输入框里的最终文本给出来（空字符串表示没改）
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initialText)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        context.coordinator.field = field
        // 等它真正进入视图层级、拿到窗口后再抢焦点
        DispatchQueue.main.async { context.coordinator.beginEditing() }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // 编辑中不要覆写用户已经敲进去的内容
        if field.currentEditor() == nil, field.stringValue != initialText {
            field.stringValue = initialText
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        weak var field: NSTextField?
        /// 已经提交/取消过：防止「回车提交 → 视图移除 → 失焦再提交一次」
        private var finished = false
        /// 窗口级鼠标按下监听：点到输入框之外就当作提交（访达语义）。
        /// 只用 delegate 的 controlTextDidEndEditing 不可靠——点击 SwiftUI 的
        /// 其他区域不会让 NSTextField 自动失焦，那个回调根本不会触发。
        private var clickMonitor: Any?

        init(_ parent: RenameField) {
            self.parent = parent
        }

        func beginEditing() {
            guard !finished, let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            // 只选中主文件名（不含扩展名）；隐藏文件（.env）全选
            let name = field.stringValue as NSString
            let base = name.deletingPathExtension
            let length = base.isEmpty ? name.length : base.count
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
            installClickMonitor()
        }

        /// 监听窗口内所有 mouseDown：若按下点落在输入框（及其编辑器）之外，
        /// 立即提交。这是「点别处接受新名称」的可靠实现。
        private func installClickMonitor() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, !self.finished, let field = self.field else { return event }
                // 输入框本身（或它的字段编辑器）里的点击不提交
                let target = event.window
                guard target === field.window else { return event }
                let p = field.convert(event.locationInWindow, from: nil)
                if field.bounds.contains(p) { return event }
                // 字段编辑器（NSTextView）会盖在 field 上，点它也应视为点输入框内
                if let editor = field.currentEditor(), let tv = editor as? NSTextView {
                    let ep = tv.convert(event.locationInWindow, from: nil)
                    if tv.bounds.contains(ep) { return event }
                }
                self.commit()
                return event
            }
        }

        private func removeClickMonitor() {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                commit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancel()
                return true
            default:
                return false
            }
        }

        /// 点到别处：与访达一致，当作提交
        func controlTextDidEndEditing(_ obj: Notification) {
            guard !finished else { return }
            commit()
        }

        private func commit() {
            guard !finished else { return }
            finished = true
            removeClickMonitor()
            parent.onCommit(field?.stringValue ?? "")
        }

        private func cancel() {
            guard !finished else { return }
            finished = true
            removeClickMonitor()
            parent.onCancel()
        }
    }
}

// MARK: - 带边框的重命名框（四个视图共用同一套外观）

struct RenameEditor: View {
    let item: FileItem
    let model: PaneModel
    var fontSize: CGFloat = 12
    var alignment: NSTextAlignment = .left

    var body: some View {
        RenameField(
            initialText: item.name,
            fontSize: fontSize,
            alignment: alignment,
            onCommit: { name in
                Task { await model.finishRename(name) }
            },
            onCancel: { model.cancelRename() }
        )
        .frame(height: fontSize + 6)
        .padding(.horizontal, 3)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1)
        }
    }
}

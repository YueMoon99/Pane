import SwiftUI
import AppKit

// MARK: - 路径栏（面包屑 + 可编辑地址）

struct PathBarView: View {
    let url: URL
    /// 停在服务器共享列表时显示的名字（此时没有可编辑的文件路径）
    var serverLabel: String? = nil
    var highlighted: Bool = false
    var onNavigate: (URL) -> Void
    var onNavigatePath: (String) -> Bool

    @State private var isEditing = false
    @State private var draft = ""
    @State private var barWindowFrame: CGRect = .zero
    @State private var clickMonitor: Any?
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// 地址栏高度，同时也是左侧三按钮的高度
    static let barHeight: CGFloat = 26
    /// 与三按钮的胶囊圆角保持一致
    private let barRadius: CGFloat = PathBarView.barHeight / 2

    private var crumbs: [(String, URL)] {
        var result: [(String, URL)] = []
        var current = url
        while true {
            let title = current.lastPathComponent.isEmpty ? current.path : current.lastPathComponent
            result.insert((title, current), at: 0)
            if current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return result
    }

    var body: some View {
        // 用 GeometryReader 拿「真实可用宽度」：面包屑按宽度自己裁剪。
        // 之前每个面包屑都 fixedSize，路径一长就撑出一个超过窗格的内禀宽度，
        // 切分模式下会把整栏顶出去、和侧边栏 / 另一栏重叠。
        GeometryReader { proxy in
            ZStack {
                if isEditing {
                    editingBar
                } else if let serverLabel {
                    serverCrumb(serverLabel)
                } else {
                    // 点击处理在 breadcrumbs 内部的 HStack 上（见 breadcrumbs），
                    // 面包屑按钮作为子级优先响应。
                    breadcrumbs(width: max(proxy.size.width - Tokens.spacingS * 2, 60))
                        .padding(.horizontal, Tokens.spacingS)
                }
            }
            .frame(width: proxy.size.width, height: Self.barHeight)
        }
        .frame(height: Self.barHeight)
        .background(
            RoundedRectangle(cornerRadius: barRadius, style: .continuous)
                // 工作区 / 未工作区，深浅色各有一套底色
                .fill(PanePalette.barSurface(active: highlighted, scheme: colorScheme))
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contextMenu {
            Button(L10n.tr("复制路径")) { copyPath() }
            if serverLabel == nil {
                Button(L10n.tr("编辑地址")) { beginEdit() }
                if !isEditing {
                    Button(L10n.tr("在终端打开")) { openInTerminal() }
                }
            }
        }
        .onExitCommand { if isEditing { cancelEdit() } }
        // 失去焦点（点了别处）即退出编辑，不需要「取消」按钮
        .onChange(of: fieldFocused) { _, isFocused in
            if !isFocused, isEditing { cancelEdit() }
        }
        .background(BarFrameReporter { frame in barWindowFrame = frame })
        .onChange(of: isEditing) { _, editing in
            if editing { startDismissMonitor() } else { stopDismissMonitor() }
        }
        .onDisappear { stopDismissMonitor() }
    }

    /// 编辑状态下点击地址栏以外的任何位置（文件区、侧边栏、工具栏…）都退出输入状态。
    /// 不能只依赖 TextField 失焦：SwiftUI 里点非聚焦区域并不会自动让它 resign。
    private func startDismissMonitor() {
        stopDismissMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard isEditing, barWindowFrame != .zero else { return event }
            if !barWindowFrame.contains(event.locationInWindow) {
                cancelEdit()
            }
            return event
        }
    }

    private func stopDismissMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    /// 面包屑：宽度不够时折叠前面的层级，只留最后两级（实在放不下就只留最后一级）。
    /// 不用横向 ScrollView：NSScrollView 会吞掉落在内容空白区域的点击，
    /// 导致「点地址栏进入编辑」只在文字上生效，因此这里用普通 HStack，宽度自己算。
    private func breadcrumbs(width: CGFloat) -> some View {
        HStack(spacing: Self.crumbSpacing) {
            ForEach(Array(crumbItems(width: width).enumerated()), id: \.offset) { position, item in
                if position > 0 {
                    chevron
                }
                switch item {
                case .crumb(let index, let text, let itemWidth):
                    Button { onNavigate(crumbs[index].1) } label: {
                        Text(text)
                            .font(Self.crumbFont)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                            .frame(width: itemWidth, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                case .collapsed(let first, let last):
                    collapsedMenu(first: first, last: last)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { beginEdit() }
        .clipped()
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.secondary.opacity(0.5))
            .frame(width: Self.chevronWidth)
    }

    /// 被省略的层级收进「/.../」，点它还能跳回中间某一级
    @ViewBuilder
    private func collapsedMenu(first: Int, last: Int) -> some View {
        if last >= first {
            Menu {
                ForEach(first...last, id: \.self) { index in
                    Button(crumbs[index].0) { onNavigate(crumbs[index].1) }
                }
            } label: {
                Text(Self.omittedMark)
                    .font(Self.crumbFont)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(Self.omittedMark)
                .font(Self.crumbFont)
                .foregroundStyle(.secondary)
        }
    }

    private enum CrumbItem {
        case crumb(index: Int, text: String, width: CGFloat)
        /// 「/.../」占位：里面是被省略的层级区间
        case collapsed(first: Int, last: Int)
    }

    /// 按可用宽度排布：能放下就全显示，放不下就「/.../ + 最后两级」，
    /// 再放不下就「/.../ + 最后一级（名称中间省略）」。
    private func crumbItems(width: CGFloat) -> [CrumbItem] {
        let names = crumbs.map(\.0)
        guard !names.isEmpty else { return [] }
        guard names.count > 1 else {
            // 只有根目录：名称本身太长就截断，不能再加省略号
            return [.crumb(index: 0,
                           text: names[0],
                           width: min(textWidth(names[0]), max(width, 40)))]
        }

        func totalWidth(_ indices: [Int]) -> CGFloat {
            indices.reduce(0) { $0 + textWidth(names[$1]) }
                + Self.separatorWidth * CGFloat(max(indices.count - 1, 0))
        }

        let all = Array(names.indices)
        if totalWidth(all) <= width {
            return all.map {
                .crumb(index: $0, text: names[$0], width: textWidth(names[$0]))
            }
        }

        let last = names.count - 1
        let omittedWidth = textWidth(Self.omittedMark) + Self.menuSlack

        // 优先保留最后两级
        if names.count >= 3 {
            let tail = [last - 1, last]
            if omittedWidth + Self.separatorWidth + totalWidth(tail) <= width {
                let items: [CrumbItem] = [.collapsed(first: 0, last: last - 2)]
                return items + tail.map {
                    .crumb(index: $0, text: names[$0], width: textWidth(names[$0]))
                }
            }
        }

        // 再退一步：只留当前目录名（太宽就中间省略）
        let room = max(width - omittedWidth - Self.separatorWidth, 40)
        return [
            .collapsed(first: 0, last: last - 1),
            .crumb(index: last, text: names[last], width: min(textWidth(names[last]), room))
        ]
    }

    /// 与 SwiftUI 渲染的字体保持一致，否则算出来的宽度和实际画出来的对不上
    private static let crumbFontSize: CGFloat = 12
    private static let crumbFont = Font.system(size: crumbFontSize)
    private static let crumbSpacing: CGFloat = 3
    /// 分隔箭头固定宽度（避免 SF Symbol 自带留白影响计算）
    private static let chevronWidth: CGFloat = 7
    /// 箭头 7 + 两侧间距 3×2
    private static let separatorWidth: CGFloat = 13
    /// 折叠标记
    private static let omittedMark = "/.../"
    /// 给 Menu 自带的内边距留一点余量
    private static let menuSlack: CGFloat = 8

    private func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Self.crumbFontSize)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width) + 1
    }

    /// 输入模式：Enter 前往，点击别处 / Esc 退出，不放任何按钮
    private var editingBar: some View {
        TextField(L10n.tr("输入路径，回车前往"), text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($fieldFocused)
            .onSubmit { commitEdit() }
            .padding(.horizontal, 8)
            .frame(height: Self.barHeight - 4)
            .background(
                RoundedRectangle(cornerRadius: (Self.barHeight - 4) / 2, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .padding(.horizontal, Tokens.spacingS)
    }

    /// 服务器共享列表：地址栏只显示「服务器名」，点它不进编辑态
    private func serverCrumb(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(label)
                .lineLimit(1)
            Text(L10n.tr("共享"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.spacingS)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginEdit() {
        guard serverLabel == nil else { return }
        draft = url.path
        isEditing = true
        // 进入编辑后全选，方便直接输入新路径（输入框要等下一轮布局才成为第一响应者）
        DispatchQueue.main.async {
            fieldFocused = true
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
            }
        }
    }

    private func commitEdit() {
        let text = draft
        isEditing = false
        fieldFocused = false
        if !onNavigatePath(text) {
            NSSound.beep()
        }
    }

    private func cancelEdit() {
        isEditing = false
        fieldFocused = false
    }

    private func copyPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.isFileURL ? url.path : url.absoluteString, forType: .string)
    }

    private func openInTerminal() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", url.path]
        try? p.run()
    }
}

/// 把视图在「窗口坐标系」里的位置回报出来，用来判断点击是否落在地址栏内。
private struct BarFrameReporter: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ReportingView else { return }
        view.onChange = onChange
        view.report()
    }

    final class ReportingView: NSView {
        var onChange: ((CGRect) -> Void)?

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            guard window != nil else { return }
            onChange?(convert(bounds, to: nil))
        }
    }
}

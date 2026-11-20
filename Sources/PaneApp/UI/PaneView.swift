import SwiftUI
import AppKit

// MARK: - 分栏容器（单 / 横切 / 纵切）

/// 分隔条拖拽热区宽度
private let paneSplitterHit: CGFloat = 9
/// 单栏最小宽度 / 高度，避免拖到看不见内容
private let paneMinSize: CGFloat = 200

struct PaneContainer: View {
    let app: AppState

    /// 拖拽中的实时比例：只在内存里，松手才写进标签页
    @State private var liveRatio: Double?
    /// 本次拖拽的起始比例（避免累加漂移）
    @State private var dragBase: Double?

    private var isSplit: Bool { app.paneLayout != .single }

    var body: some View {
        content
            // 切标签页时丢掉上一步没落盘的临时比例
            .onChange(of: app.activeTabID) { _, _ in
                liveRatio = nil
                dragBase = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        switch app.paneLayout {
        case .single:
            pane(for: .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .horizontal:
            split(vertical: false)
        case .vertical:
            split(vertical: true)
        }
    }

    // MARK: 可拖分隔条

    @ViewBuilder
    private func split(vertical: Bool) -> some View {
        GeometryReader { geo in
            let total = vertical ? geo.size.height : geo.size.width
            // 两栏紧贴（不留占位间距），分隔线用 1pt 压在交界处：
            // 留出间隙的话，间隙里透出的是窗口白底，地址栏和表头那一行就会
            // 在灰线两边各露出一条白边。热区仍然有 9pt，只是往两侧各压 4pt。
            let usable = max(total, paneMinSize * 2)
            // 比例跟着标签页走：每个标签页各自记住自己切分后的宽度 / 高度
            let stored = vertical ? app.activeTab.verticalRatio : app.activeTab.horizontalRatio
            let fraction = min(max(liveRatio ?? stored, 0), 1)
            // 首栏宽度 = 可用空间 × 比例，并夹在 [最小尺寸, 总长 - 最小尺寸] 之间
            let first = min(max(usable * fraction, paneMinSize), usable - paneMinSize)

            if vertical {
                // 分隔条画在最上层（ZStack 的最后一个子视图）：相邻窗格里的 AppKit
                // 子视图（框选层、单元格点击层）会比窗格本身宽出十来个点，横着盖住
                // 分隔条的位置。分隔条如果只是 HStack/VStack 里的普通兄弟节点，
                // 它的命中区会被这些溢出的子视图压住 —— 表现就是「分隔条拖不动」。
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        pane(for: .primary)
                            .frame(height: first)
                        pane(for: .secondary)
                    }
                    divider(vertical: true, usable: usable)
                        .frame(width: geo.size.width, height: paneSplitterHit)
                        .offset(y: first - paneSplitterHit / 2)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        pane(for: .primary)
                            .frame(width: first)
                        pane(for: .secondary)
                    }
                    divider(vertical: false, usable: usable)
                        .frame(width: paneSplitterHit, height: geo.size.height)
                        .offset(x: first - paneSplitterHit / 2)
                }
            }
        }
    }

    private func divider(vertical: Bool, usable: CGFloat) -> some View {
        PaneDivider(
            stacked: vertical,
            onDrag: { delta in
                let stored = vertical ? app.activeTab.verticalRatio : app.activeTab.horizontalRatio
                let base = dragBase ?? (liveRatio ?? stored)
                if dragBase == nil { dragBase = base }
                let raw = (base * usable + delta) / usable
                let minFraction = paneMinSize / usable
                liveRatio = min(max(raw, minFraction), 1 - minFraction)
            },
            onEnd: {
                if let liveRatio {
                    app.activeTab.setRatio(liveRatio, for: vertical ? .vertical : .horizontal)
                    app.persistTabs()
                }
                liveRatio = nil
                dragBase = nil
            },
            onReset: {
                // 双击均分
                liveRatio = nil
                dragBase = nil
                app.activeTab.setRatio(0.5, for: vertical ? .vertical : .horizontal)
                app.persistTabs()
            }
        )
    }

    private func pane(for slot: PaneSlot) -> some View {
        PaneView(
            model: app.model(for: slot),
            slot: slot,
            // 单窗格时这一栏就是工作区；切分时只有当前槽位是工作区
            focused: !isSplit || app.focusedSlot == slot,
            onFocus: { app.focusedSlot = slot },
            // 每栏用自己的视图模式：切分时两侧互不影响
            viewMode: app.viewMode(for: slot)
        )
        // 每栏给一个合理的下限，避免内容把侧边栏挤掉
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 1pt 视觉分隔线 + 9pt 拖拽热区，双击回到均分。
///
/// 鼠标事件交给一个真正的 NSView（`DividerHandle`）来接，而不是 SwiftUI 手势：
/// 纯 SwiftUI 的命中区只能活在宿主视图自己的绘制层里，一旦相邻窗格里有
/// AppKit 子视图（框选层 / 单元格点击层）横向溢出盖过来，这些 NSView 会优先
/// 拿到 mouseDown，SwiftUI 的 gesture 就永远不会触发 —— 分隔条表现为拖不动。
private struct PaneDivider: View {
    /// true = 上下排列（分隔条横向），false = 左右排列
    let stacked: Bool
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: stacked ? nil : 1,
                   height: stacked ? 1 : nil)
            .frame(width: stacked ? nil : paneSplitterHit,
                   height: stacked ? paneSplitterHit : nil)
            .overlay {
                DividerHandle(stacked: stacked,
                              onDrag: onDrag,
                              onEnd: onEnd,
                              onReset: onReset)
            }
    }
}

/// 分隔条的事件承接层：光标用 cursor rect（系统管理，点击不会错乱），
/// 拖拽用 mouseDown/mouseDragged/mouseUp（不受 SwiftUI 手势竞争影响）。
private struct DividerHandle: NSViewRepresentable {
    let stacked: Bool
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.toolTip = L10n.tr("拖动调整比例，双击均分")
        apply(to: view)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: HandleView) {
        view.stacked = stacked
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onReset = onReset
        // 轴向可能变（横切 ↔ 纵切），让系统重算光标区域
        view.window?.invalidateCursorRects(for: view)
    }

    final class HandleView: NSView {
        var stacked = false
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onReset: () -> Void = {}

        private var start: NSPoint?
        private var dragging = false
        private var hoverArea: NSTrackingArea?

        private var resizeCursor: NSCursor { stacked ? .resizeUpDown : .resizeLeftRight }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: resizeCursor)
        }

        /// cursor rect 在 SwiftUI 的宿主视图里偶尔被上层容器覆盖，再补一条
        /// tracking area，鼠标进入时直接 set，双保险。
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .cursorUpdate,
                                                .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            resizeCursor.set()
        }

        override func cursorUpdate(with event: NSEvent) {
            resizeCursor.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        /// 窗口没激活时第一下也要能拖
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // 双击均分
                start = nil
                dragging = false
                onReset()
                return
            }
            start = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let dx = event.locationInWindow.x - start.x
            // AppKit 的 y 轴向上；上下切分时往下拖 = 上栏变高
            let dy = start.y - event.locationInWindow.y
            if !dragging {
                guard abs(dx) + abs(dy) > 1 else { return }
                dragging = true
            }
            onDrag(stacked ? dy : dx)
        }

        override func mouseUp(with event: NSEvent) {
            if dragging { onEnd() }
            start = nil
            dragging = false
        }
    }
}

// MARK: - 单个窗格

struct PaneView: View {
    @Bindable var model: PaneModel
    let slot: PaneSlot
    /// 是否为正在工作的区域（分栏模式下用蓝色地址栏标出）
    var focused: Bool = true
    let onFocus: () -> Void
    let viewMode: ViewMode

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                navigationButtons
                PathBarView(
                    url: model.displayURL,
                    serverLabel: model.serverLocation?.label,
                    highlighted: focused,
                    onNavigate: model.navigate,
                    onNavigatePath: { model.navigate(toPath: $0) }
                )
            }
            // 活动区域：整条（三按钮 + 地址栏）底色变蓝
            // 非活动切分区域也铺满浅灰，而不是留白 —— 否则灰胶囊四周的留白会
            // 在地址栏和分隔线 / 中线之间露出一条白缝
            .background(focused ? PanePalette.focusBar : PanePalette.barSurface(active: false, scheme: colorScheme))
            Divider()
            // 模型换了（切换标签页）就重建视图：列视图的列状态是 @State，
            // 不换标识会残留上一个标签页的列。
            Group {
                switch viewMode {
                case .icon:   IconGridView(model: model)
                case .list:   ListView(model: model, slot: slot)
                case .column: ColumnView(model: model)
                case .gallery: GalleryView(model: model)
                }
            }
            .id(ObjectIdentifier(model))
            // 加载中 / 读取共享列表 / 出错时的说明：空白一片会让人以为卡死
            .overlay { PaneStateOverlay(model: model) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 活动区底色不能溢出到别的栏（否则会在侧边栏玻璃后面糊出一片蓝）
        .clipped()
        .onTapGesture { onFocus() }
        .environment(\.paneFocus, PaneFocusAction(onFocus))
        .environment(\.paneDragDrop, dragDrop)
        .environment(\.paneActive, focused)
        // 新建标签页的窗格是 idle 状态：模型一变就要触发加载，
        // 否则新标签页会一直停在空白内容上。
        //
        // 这个任务同时充当「窗格在屏幕上」的生命周期信号：SwiftUI 在视图消失
        // 或 id 变化（切标签页）时会取消它，网络卷的轮询据此停掉 —— 隐藏的
        // 标签页不该每两秒去 stat 一次 NAS。
        .task(id: ObjectIdentifier(model)) {
            model.setVisible(true)
            defer { model.setVisible(false) }
            await model.loadIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        // 快速查看面板开着时，选择变化让它跟着翻页
        .onChange(of: model.selection) { _, _ in
            QuickLookCoordinator.shared.selectionChanged()
        }
    }

    /// 拖出：优先带上整个选择；拖入：放进目标文件夹或本窗格当前目录
    private var dragDrop: PaneDragDrop {
        PaneDragDrop(
            dragURLs: { item in
                // 共享列表里的条目还不是本地路径，拖出去没有意义
                guard !model.isServerRoot, let item else { return [] }
                if model.selection.contains(item.url), model.selection.count > 1 {
                    return model.items.filter { model.selection.contains($0.url) }.map(\.url)
                }
                return [item.url]
            },
            dropURLs: { urls, target, move in
                guard !model.isServerRoot else { return false }
                let destination: URL
                if let target, target.isDirectory, !target.isPackage {
                    destination = target.url
                } else {
                    destination = model.url
                }
                Task { await receiveDrop(urls, into: destination, move: move) }
                return true
            },
            trashURLs: { urls in
                guard !model.isServerRoot else { return }
                Task {
                    await FileOperationService.shared.trash(urls)
                    await model.load()
                    model.clearSelection()
                }
            }
        )
    }

    private func receiveDrop(_ urls: [URL], into destination: URL, move: Bool) async {
        await FileOperationService.shared.transfer(urls, to: destination, move: move)
        await model.load()
    }

    /// 每栏独立的「后退 / 前进 / 上一层 / 刷新」，贴在地址栏左侧
    private var navigationButtons: some View {
        HStack(spacing: 1) {
            navigationButton("chevron.left", help: L10n.tr("后退"), enabled: !model.backStack.isEmpty) { model.back() }
            navigationButton("chevron.right", help: L10n.tr("前进"), enabled: !model.forwardStack.isEmpty) { model.forward() }
            navigationButton("arrow.up", help: L10n.tr("上一层"), enabled: model.url.parent != nil) { model.up() }
            // 本地卷靠监听、网络卷靠轮询，但总有「现在就要看最新」的时候：
            // 放在导航组末尾，所有卷都有，和 ⌘R 同一个动作
            navigationButton("arrow.clockwise", help: L10n.tr("刷新（⌘R）"), enabled: true) { model.reload() }
        }
        .padding(.horizontal, 2)
        .frame(height: PathBarView.barHeight)
        // 不透明胶囊浮在蓝色底条之上：工作区亮一档，未工作区暗一档
        .background(Capsule(style: .continuous)
            .fill(PanePalette.barSurface(active: focused, scheme: colorScheme)))
        // 地址栏是 maxWidth: .infinity，会抢占宽度把按钮压扁，这里锁住固有尺寸
        .fixedSize()
        .padding(.leading, 6)
    }

    private func navigationButton(
        _ symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            onFocus()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 27, height: PathBarView.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.3))
        .disabled(!enabled)
        .help(help)
    }
}


// MARK: - 状态栏

struct StatusBarView: View {
    let model: PaneModel

    var body: some View {
        HStack(spacing: Tokens.spacingM) {
            Text(L10n.tr("%@ 个项目", model.items.count)).foregroundStyle(.secondary)

            // 已选数量 + 所选大小，作为一组紧挨着排在项目数后面
            HStack(spacing: 5) {
                Text(L10n.tr("已选 %@ 个", model.selection.count)).foregroundStyle(.secondary)
                if let size = selectedSizeText {
                    Text(size).foregroundStyle(.secondary)
                }
            }

            Divider().frame(height: 12)

            // 选中里含文件夹时 selectedSizeText 为 nil，后面两项自然左移
            Text(freeSpaceText(model.url)).foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, Tokens.spacingL)
        .frame(height: Tokens.statusBarHeight)
        .background(.thinMaterial)
    }

    /// 选中的项目（按列表顺序）
    private var selectedItems: [FileItem] {
        guard !model.selection.isEmpty else { return [] }
        return model.items.filter { model.selection.contains($0.url) }
    }

    /// 所选文件的总大小。只要有一个是文件夹 / 共享 / 大小未知，就不显示：
    /// 目录大小要递归统计，值太小还会误导，访达在选中文件夹时同样不报体积。
    private var selectedSizeText: String? {
        let items = selectedItems
        guard !items.isEmpty else { return nil }
        guard items.allSatisfy({ !$0.isDirectory && !$0.isShare && $0.size != nil }) else { return nil }
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func freeSpaceText(_ url: URL) -> String {
        guard url.isFileURL,
              let cap = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            return ""
        }
        return L10n.tr("可用 ") + ByteCountFormatter.string(fromByteCount: Int64(cap), countStyle: .file)
    }
}

// MARK: - 加载 / 空 / 出错状态

/// 覆盖在内容区上的轻量状态层：正在读取、空文件夹、读取失败（带重试）
private struct PaneStateOverlay: View {
    let model: PaneModel

    var body: some View {
        switch model.loadState {
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.isServerRoot ? L10n.tr("正在读取共享列表…") : L10n.tr("正在读取…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.opacity(0.65))
        case .error(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("重试")) {
                    Task { await model.load() }
                }
                .controlSize(.small)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.opacity(0.9))
        case .empty:
            Text(model.isServerRoot ? L10n.tr("这台服务器没有列出可访问的共享") : L10n.tr("文件夹是空的"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        case .idle, .loaded:
            EmptyView()
        }
    }
}

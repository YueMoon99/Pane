import SwiftUI
import AppKit

// MARK: - 标签栏

/// 窗口顶部的标签栏：新建 / 关闭 / 拖拽排序 / 拖出成窗
struct TabBarView: View {
    let app: AppState

    @Environment(\.openWindow) private var openWindow

    @State private var frames: [UUID: CGRect] = [:]
    @State private var barWidth: CGFloat = 0
    /// 正在拖拽的标签页；nil 表示没有拖拽
    @State private var dragging: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(app.tabs) { tab in
                    chip(for: tab)
                }
                // 「+」紧跟在最后一个标签页后面，随标签一起滚动
                Button {
                    app.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("新建标签页（⌘T）"))
            }
            .padding(.horizontal, 8)
            .coordinateSpace(name: TabBar.coordinateSpace)
        }
        // 标签栏被卷动时也要能判断「拖到了栏外」
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { barWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in barWidth = width }
        })
        .frame(height: TabBar.height)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onPreferenceChange(TabFramePreference.self) { frames = $0 }
    }

    // MARK: 单个标签

    private func chip(for tab: TabSession) -> some View {
        TabChip(
            tab: tab,
            active: tab.id == app.activeTabID,
            onSelect: { app.activate(tab.id) },
            onClose: { app.closeTab(tab.id) }
        )
        .opacity(dragging == tab.id ? 0.55 : 1)
        .background(GeometryReader { proxy in
            Color.clear.preference(
                key: TabFramePreference.self,
                value: [tab.id: proxy.frame(in: .named(TabBar.coordinateSpace))]
            )
        })
        .contextMenu {
            Button(L10n.tr("新建标签页")) { app.newTab() }
            Button(L10n.tr("复制标签页")) { app.duplicateActiveTab() }
            Divider()
            Button(L10n.tr("关闭标签页")) { app.closeTab(tab.id) }
                .disabled(app.tabs.count <= 1)
            Button(L10n.tr("关闭其他标签页")) { app.closeOtherTabs(keeping: tab.id) }
                .disabled(app.tabs.count <= 1)
            Divider()
            Button(L10n.tr("移到新窗口")) { detach(tab.id) }
                .disabled(app.tabs.count <= 1)
        }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(TabBar.coordinateSpace))
                .onChanged { value in
                    if dragging != tab.id { dragging = tab.id }
                    app.activate(tab.id)
                    _ = value
                }
                .onEnded { value in
                    defer { dragging = nil }
                    drop(tab.id, at: value.location)
                }
        )
        .help(tab.helpText)
    }

    // MARK: 拖拽结果

    private func drop(_ id: UUID, at point: CGPoint) {
        guard let from = app.tabs.firstIndex(where: { $0.id == id }) else { return }

        // 拖到标签栏之外（留 24pt 容差）→ 拆成独立窗口
        let inside = CGRect(x: -24, y: -20, width: barWidth + 120, height: TabBar.height + 40)
        if !inside.contains(point), app.tabs.count > 1 {
            detach(id)
            return
        }

        // 否则按落点插入：取第一个「中点位于落点右侧」的标签页位置
        var target = app.tabs.count
        for (index, tab) in app.tabs.enumerated() {
            if let frame = frames[tab.id], point.x < frame.midX {
                target = index
                break
            }
        }
        app.moveTab(from: from, to: target)
    }

    private func detach(_ id: UUID) {
        guard let tab = app.detachTab(id) else { return }
        let token = DetachedWorkspaces.stash(tab)
        openWindow(id: WorkspaceWindow.sceneID, value: token)
    }
}

// MARK: - 单个标签页外观

private struct TabChip: View {
    let tab: TabSession
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // 单栏只显示一个目录名；切分时显示「左 / 右」两个目录名。
            // 两个名字分开排，中间的分隔符不受截断影响。
            HStack(spacing: 4) {
                Text(tab.primaryTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if tab.isSplit {
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text(tab.secondaryTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(active ? Color.primary : Color.secondary)
            Spacer(minLength: 2)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovered || active ? 1 : 0.25)
            .help(L10n.tr("关闭标签页"))
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 108, maxWidth: tab.isSplit ? 270 : 190, alignment: .leading)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // 单击选择、拖动排序：两者同时识别，位移不足 5pt 时退化为单击
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .onHover { hovered = $0 }
    }

    private var background: Color {
        if active { return Color(nsColor: .textBackgroundColor) }
        return hovered ? Color.primary.opacity(0.06) : Color.clear
    }
}

// MARK: - 布局常量与偏好键

private enum TabBar {
    static let height: CGFloat = 30
    static let coordinateSpace = "PaneTabBar"
}

private struct TabFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 窗口 / 场景标识

enum WorkspaceWindow {
    static let sceneID = "workspace"
}

/// 「拖出成窗」时把标签页暂存起来，等新窗口创建时取走
@MainActor
enum DetachedWorkspaces {
    private static var pending: [UUID: TabSession] = [:]

    static func stash(_ tab: TabSession) -> UUID {
        let token = UUID()
        pending[token] = tab
        // 防御：连续拖出多个标签页时避免无限堆积
        if pending.count > 16 { pending.removeAll() }
        return token
    }

    static func take(_ token: UUID?) -> TabSession? {
        guard let token else { return nil }
        return pending.removeValue(forKey: token)
    }
}

// MARK: - 焦点值（菜单命令据此作用于当前窗口）

struct WorkspaceFocusedKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var workspace: AppState? {
        get { self[WorkspaceFocusedKey.self] }
        set { self[WorkspaceFocusedKey.self] = newValue }
    }
}

// MARK: - 窗口挂载

/// 把 NSWindow 交给 AppState，并为主窗口记住窗口位置
struct WindowConfigurator: NSViewRepresentable {
    let app: AppState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { resolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolve(nsView)
    }

    private func resolve(_ view: NSView) {
        guard let window = view.window else { return }
        app.attach(to: window)
        // 主窗口记住大小与位置；拖出去的窗口不覆盖主窗口的记录
        guard app.isPrimaryWindow else { return }
        let autosave = "Pane.MainWindow"
        let key = "NSWindow Frame \(autosave)"
        let hasSaved = UserDefaults.standard.string(forKey: key) != nil
        window.setFrameAutosaveName(autosave)
        guard !hasSaved else { return }
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.center()
    }
}

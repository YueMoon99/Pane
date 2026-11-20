import SwiftUI
import AppKit

// MARK: - 分栏（列）视图（动态多级 + 可拖列宽 + 最多 4 列）

/// 单列状态：每列自带 url / 内容 / 选中项，避免用数组下标互相推断
private struct ColumnState: Identifiable {
    let id: Int
    let url: URL
    var items: [FileItem]
    var selection: URL?
}

struct ColumnView: View {
    @Bindable var model: PaneModel
    @State private var columns: [ColumnState] = []
    @State private var nextID = 1

    /// 拖拽中的临时列宽（松手才落盘，避免每帧写 UserDefaults）
    @State private var liveWidth: Double?
    @State private var resizeStart: Double?

    /// 规范：列视图最多 4 列
    private static let maxColumns = 4

    private var options: ViewOptions { ViewOptionsStore.shared.options(for: model.url) }
    private var columnWidth: CGFloat { CGFloat(liveWidth ?? options.columnWidth) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(columns) { column in
                    ColumnPane(
                        model: model,
                        items: column.items,
                        selected: column.selection,
                        cutURLs: model.cutURLs,
                        onSelect: { item in handleSelect(item, in: column.id) },
                        onOpen: { item in model.enter(item) },
                        onClear: { clear(columnID: column.id) }
                    )
                    .frame(width: columnWidth)

                    if column.id != columns.last?.id {
                        ColumnSplitter(
                            onDrag: { delta in
                                let base = resizeStart ?? (liveWidth ?? options.columnWidth)
                                resizeStart = base
                                let range = ViewOptions.columnWidthRange
                                liveWidth = min(max(base + delta, range.lowerBound), range.upperBound)
                            },
                            onEnd: commitWidth
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .task { syncRoot() }
        .onAppear { model.arrowInterceptor = { handleArrow($0) } }
        .onDisappear {
            model.arrowInterceptor = nil
            model.browsingURL = nil
        }
        .onChange(of: model.url) { _, _ in reset() }
        .onChange(of: model.items) { _, new in
            guard let i = columns.firstIndex(where: { $0.url == model.url }) else { return }
            columns[i].items = new
        }
        // 改名会改变磁盘上的名字：各列的快照都要重读，否则深一层的列还显示旧名字
        .onChange(of: model.refreshToken) { _, _ in Task { await reloadColumns() } }
    }

    // MARK: 列生命周期

    private func syncRoot() {
        guard columns.isEmpty else { return }
        columns = [ColumnState(id: 0, url: model.url, items: model.items, selection: nil)]
        model.browsingURL = nil
    }

    private func reset() {
        columns = [ColumnState(id: 0, url: model.url, items: model.items, selection: nil)]
        nextID = 1
        liveWidth = nil
        model.browsingURL = nil
    }

    private func handleSelect(_ item: FileItem, in columnID: Int) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        if columns.count > index + 1 {
            columns.removeSubrange((index + 1)...)
        }
        columns[index].selection = item.url
        // 地址栏跟随选中项：选目录显示该目录，选文件显示它所在的列
        let drillable = item.isDirectory && !item.isPackage && !item.isShare
        model.browsingURL = drillable ? item.url : columns[index].url
        // 同步给窗格模型：状态栏计数、其他视图的选择保持一致
        model.reveal(item)

        // 共享要先挂载才能读内容，双击（onOpen）会走挂载流程，这里不下钻
        guard drillable else { return }

        let paneURL = model.url
        let showHidden = model.showHidden
        let columnURL = columns[index].url
        Task {
            let children = (try? await LocalFileSystem.shared.contents(of: item.url, showHidden: showHidden)) ?? []
            guard model.url == paneURL,
                  let current = columns.firstIndex(where: { $0.id == columnID }),
                  current == columns.count - 1,
                  columns[current].url == columnURL,
                  columns[current].selection == item.url else { return }

            columns.append(ColumnState(id: nextID, url: item.url, items: children, selection: nil))
            nextID += 1
            // 最多 4 列：超出后丢弃最左侧一列（继续下钻时始终看得到当前层级）
            while columns.count > Self.maxColumns {
                columns.removeFirst()
            }
        }
    }

    private func clear(columnID: Int) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        if columns.count > index + 1 {
            columns.removeSubrange((index + 1)...)
        }
        columns[index].selection = nil
        model.browsingURL = columns[index].url
        model.clearSelection()
    }

    /// 重新读取各列内容（改名后调用），保留每列当前选中的项目
    private func reloadColumns() async {
        let snapshot = columns
        let showHidden = model.showHidden
        let rootURL = model.url
        let rootItems = model.items
        // 刚改过名的那一项：列里存的还是旧 URL，换成新的才不会丢掉高亮
        let rename = model.lastRename
        var updated: [ColumnState] = []
        for column in snapshot {
            var copy = column
            if column.url == rootURL {
                copy.items = rootItems
            } else {
                copy.items = (try? await LocalFileSystem.shared.contents(of: column.url, showHidden: showHidden)) ?? column.items
            }
            if let rename, copy.selection == rename.from { copy.selection = rename.to }
            updated.append(copy)
        }
        guard !Task.isCancelled, columns.count == snapshot.count else { return }
        columns = updated
    }

    private func commitWidth() {
        if let width = liveWidth {
            var updated = options
            updated.columnWidth = width
            ViewOptionsStore.shared.update(updated, for: model.url)
        }
        liveWidth = nil
        resizeStart = nil
    }

    // MARK: 键盘导航（← 返回上级列，→ 下钻，↑↓ 移动）

    private func handleArrow(_ keyCode: UInt16) -> Bool {
        guard let direction = PaneModel.MoveDirection(rawValue: keyCode) else { return false }
        guard !columns.isEmpty else { return false }
        let active = columns.lastIndex(where: { $0.selection != nil }) ?? (columns.count - 1)
        guard columns.indices.contains(active) else { return false }

        switch direction {
        case .up, .down:
            let items = columns[active].items
            guard !items.isEmpty else { return true }
            let current = columns[active].selection.flatMap { sel in items.firstIndex { $0.url == sel } }
            let step = direction == .down ? 1 : -1
            let target = current.map { min(max($0 + step, 0), items.count - 1) } ?? 0
            handleSelect(items[target], in: columns[active].id)
            return true

        case .left:
            guard active > 0 else { return true }
            columns.removeSubrange(active...)
            model.browsingURL = columns[active - 1].url == model.url ? nil : columns[active - 1].url
            return true

        case .right:
            let items = columns[active].items
            guard let sel = columns[active].selection,
                  let item = items.first(where: { $0.url == sel }),
                  item.isDirectory, !item.isPackage else { return true }
            handleSelect(item, in: columns[active].id)
            return true
        }
    }
}

/// 列分隔条：1pt 视觉线 + 8pt 拖拽热区，拖动调整列宽（140–400）
struct ColumnSplitter: View {
    let onDrag: (Double) -> Void
    let onEnd: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 1)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag(Double($0.translation.width)) }
                    .onEnded { _ in onEnd() }
            )
    }
}

struct ColumnPane: View {
    let model: PaneModel
    let items: [FileItem]
    let selected: URL?
    /// 处于剪切待移动状态的项目（画成半透明）
    var cutURLs: Set<URL> = []
    let onSelect: (FileItem) -> Void
    let onOpen: (FileItem) -> Void
    let onClear: () -> Void

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            ColumnRow(item: item,
                                      model: model,
                                      selected: item.url == selected,
                                      dimmed: cutURLs.contains(item.url.standardizedFileURL),
                                      onSelect: onSelect,
                                      onOpen: onOpen)
                            .paneContextMenu(item: item)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                // 空白处取消本列选择（挂在撑满后的容器上，否则收不到点击）
                .background {
                    PaneClickCatcher { _, _, _ in onClear() }
                }
            }
        }
    }
}

struct ColumnRow: View {
    let item: FileItem
    let model: PaneModel
    let selected: Bool
    /// 已剪切、等待粘贴走：内容画成半透明
    var dimmed: Bool = false
    let onSelect: (FileItem) -> Void
    let onOpen: (FileItem) -> Void

    @Environment(\.paneActive) private var paneActive
    /// 文件名文字的实际矩形（窗口坐标）
    @State private var nameFrame: CGRect = .zero

    private var canDescend: Bool { item.isDirectory && !item.isPackage }

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(item: item, size: 18)
                .frame(width: 20)
            if model.isRenaming(item) {
                RenameEditor(item: item, model: model, fontSize: 12)
                    .layoutPriority(1)
            } else {
                Text(item.name).lineLimit(1)
                    .readGlobalFrame { nameFrame = $0 }
            }
            Spacer(minLength: 0)
            if canDescend {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
        .font(.system(size: 12))
        .foregroundStyle(selected ? PanePalette.selectionText(active: paneActive) : Color.primary)
        .padding(.horizontal, Tokens.spacingS)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected
                    ? (paneActive ? PanePalette.selectionActive : PanePalette.selectionInactive)
                    : Color.clear)
        .contentShape(Rectangle())
        .overlay {
            if !model.isRenaming(item) {
                PaneClickCatcher(item: item, onRightClick: { onSelect(item) }) { count, flags, point in
                    if count >= 2 {
                        onOpen(item)
                    } else if !flags.contains(.command) && !flags.contains(.shift) && selected {
                        // 已选中：只有点在文件名上才进入重命名，点图标/空白什么都不做
                        if !nameFrame.isEmpty, nameFrame.contains(point) {
                            model.beginRename(item)
                        }
                    } else {
                        onSelect(item)
                    }
                }
            }
        }
    }
}

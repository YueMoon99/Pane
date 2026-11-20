import SwiftUI
import AppKit

// MARK: - 列表视图（自绘虚拟化行 + 可配置列 + 可拖拽列宽）

/// 列布局常量：表头与行必须共用，保证分隔线与单元格对齐
private enum ListMetrics {
    /// 单元格内容与列边界之间的留白（避免相邻两列文字贴在一起）
    static let columnInset: CGFloat = 10
    /// 分隔线拖拽热区宽度（从列的左边缘向内延伸）
    static let handleHitWidth: CGFloat = 9
    /// 列头点击 vs 拖拽重排的位移分界（pt）：小于它算点击排序，大于它算拖拽重排
    static let reorderThreshold: CGFloat = 6
    /// 可拖拽列宽区间
    static let minWidth: Double = 48
    static let maxWidth: Double = 360
    /// 名称列（文件名）最小宽度，避免文件名整列被压没
    static let minName: Double = 120
}

/// 列表的一列（用于表头与数据行统一描述，支持拖拽重排顺序）
enum ColKey: String, CaseIterable, Codable {
    case name, size, duration, kind, date

    var title: String {
        switch self {
        case .name: L10n.tr("名称")
        case .size: L10n.tr("大小")
        case .duration: L10n.tr("时长")
        case .kind: L10n.tr("种类")
        case .date: L10n.tr("修改日期")
        }
    }

    /// 文本对齐：名称/种类/日期靠左，大小/时长靠右
    var alignment: Alignment {
        switch self {
        case .size, .duration: .trailing
        default: .leading
        }
    }

    /// 对应的排序字段
    var sortField: SortField {
        switch self {
        case .name: .name
        case .size: .size
        case .duration: .duration
        case .kind: .kind
        case .date: .date
        }
    }
}

struct ListView: View {
    @Bindable var model: PaneModel
    let slot: PaneSlot
    @Environment(AppState.self) private var app

    @AppStorage("list.showSize") private var showSize = true
    @AppStorage("list.showKind") private var showKind = true
    @AppStorage("list.showDate") private var showDate = true
    /// 时长列开关：只有当前目录里真的有音频 / 视频时才会实际显示
    @AppStorage("list.showDuration") private var showDuration = true

    // 每个窗格独立保存列宽（键里带槽位），切分时互不影响
    @AppStorage private var nameWidth: Double
    @AppStorage private var sizeWidth: Double
    @AppStorage private var kindWidth: Double
    @AppStorage private var dateWidth: Double
    @AppStorage private var durationWidth: Double

    /// 拖拽中的实时列宽：只存在于内存，松手才写 UserDefaults。
    /// 之前每帧写 @AppStorage 会导致整张表重建 + 同步磁盘写入，表现就是「卡」。
    @State private var liveName: Double?
    @State private var liveSize: Double?
    @State private var liveKind: Double?
    @State private var liveDate: Double?
    @State private var liveDuration: Double?
    /// 当前拖拽的固定参照（拖动过程中不变，避免位移基准漂移）
    @State private var dragAnchor: ListView.ResizeAnchor?
    /// 列左右顺序（可拖拽重排），按槽位持久化
    @AppStorage private var columnOrder: String
    /// 正在拖动重排的源列（非 nil 表示拖拽进行中）
    @State private var draggingColumn: ColKey?
    /// 拖拽重排的悬停目标列（用于画插入指示）
    @State private var reorderTarget: ColKey?
    /// 拖拽开始的全局 x（用于按位移计算目标列）
    @State private var reorderStartX: CGFloat?

    init(model: PaneModel, slot: PaneSlot) {
        self._model = Bindable(model)
        self.slot = slot
        let key = slot.storageKey
        _nameWidth = AppStorage(wrappedValue: 200, "list.widthName.\(key)")
        _sizeWidth = AppStorage(wrappedValue: 80, "list.widthSize.\(key)")
        _kindWidth = AppStorage(wrappedValue: 100, "list.widthKind.\(key)")
        // 日期精确到分钟后文字更长（最坏「2026年12月31日 09:05」约 133pt），
        // 列内容还要留 10pt 左内边距，140 会被截掉最后几位
        _dateWidth = AppStorage(wrappedValue: 160, "list.widthDate.\(key)")
        _durationWidth = AppStorage(wrappedValue: 70, "list.widthDuration.\(key)")
        _columnOrder = AppStorage(wrappedValue: "name,size,duration,kind,date", "list.order.\(key)")
    }

    private var effName: Double { liveName ?? nameWidth }
    private var effSize: Double { liveSize ?? sizeWidth }
    private var effKind: Double { liveKind ?? kindWidth }
    private var effDate: Double { liveDate ?? dateWidth }
    private var effDuration: Double { liveDuration ?? durationWidth }

    /// 目录里有没有音频 / 视频文件（时长列非媒体格子留空时的参考，仅用于行内渲染）
    private var durationVisible: Bool {
        showDuration
    }

    var body: some View {
        GeometryReader { geo in
            let columns = orderedColumns
            let widths = columnWidths(for: columns)
            let menu: CGFloat = 26
            let contentWidth = columns.reduce(0) { $0 + (widths[$1] ?? 0) } + menu
            // 内容至少占满窗格：这样 2 轴/横轴 ScrollView 不会把内容居中，
            // 表头与行都从同一条左基线排布，列与列标题自然对齐。
            let fullWidth = max(contentWidth, geo.size.width)

            ZStack(alignment: .topLeading) {
                // 外层只做横向滚动：表头与数据行一起左右滚（表头跟随左右滚轮）。
                // 表头不再带背景（透明），只显示文字与分割线；横向滚动时不会
                // 露出多余的背景条。
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        header(columns: columns, widths: widths)
                            .frame(width: fullWidth, alignment: .leading)
                        Divider()
                        // 内层只做纵向滚动：表头在滚动视图之外，上下滚轮时固定不动。
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 0) {
                                    ForEach(model.items) { item in
                                        ListRow(
                                            item: item,
                                            model: model,
                                            selected: model.selection.contains(item.url),
                                            mounting: model.mountingShare == item.name,
                                            dimmed: model.isCut(item.url),
                                            columns: columns,
                                            widths: widths,
                                            onRightClick: { selectIfNeeded(item) }
                                        )
                                        .frame(width: fullWidth, alignment: .leading)
                                        .marqueeFrame(for: item.url)
                                        .paneContextMenu(item: item)
                                    }
                                }
                                .frame(minWidth: fullWidth,
                                       minHeight: max(geo.size.height - 25, 1),
                                       alignment: .topLeading)
                                .marqueeSelection(model: model) { model.clearSelection() }
                                .paneContextMenu(item: nil)
                            }
                            .onChange(of: model.scrollTarget) { _, target in
                                guard let target else { return }
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                            }
                        }
                    }
                    .frame(width: fullWidth, height: geo.size.height, alignment: .topLeading)
                }

                // 列设置按钮：钉在表头可视区最右缘，不随横向滚动/列宽移动。
                // 表头透明，这里也只保留按钮本身，不带背景。
                columnMenu
                    .padding(.trailing, 6)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// 各列使用固定存储宽度；窗格放不下时由外层 ScrollView 横向滚动，
    /// 不做等比压缩（压缩会让「拖拽跟手」与「所见即所存」都失真）。
    private func columnWidths(for columns: [ColKey]) -> [ColKey: CGFloat] {
        var out: [ColKey: CGFloat] = [:]
        for key in columns {
            switch key {
            case .name:
                out[key] = max(ListMetrics.minName, CGFloat(effName))
            case .size:
                out[key] = showSize ? CGFloat(effSize) : 0
            case .duration:
                out[key] = durationVisible ? CGFloat(effDuration) : 0
            case .kind:
                out[key] = showKind ? CGFloat(effKind) : 0
            case .date:
                out[key] = showDate ? CGFloat(effDate) : 0
            }
        }
        return out
    }

    private func header(columns: [ColKey], widths: [ColKey: CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { key in
                if isVisible(key) {
                    let w = widths[key] ?? 0
                    if key == .name {
                        HeaderLabel(title: key.title, leadingPadding: Tokens.spacingM,
                                    isActive: model.sort.field == key.sortField,
                                    ascending: model.sort.ascending)
                            .frame(width: w, alignment: key.alignment)
                            .background(reorderTarget == key && draggingColumn != key
                                        ? Color.accentColor.opacity(0.18) : Color.clear)
                            .gesture(headerGesture(for: key))
                    } else {
                        ColumnHeader(title: key.title, width: Double(w),
                                     alignment: key.alignment,
                                     isActive: model.sort.field == key.sortField,
                                     ascending: model.sort.ascending,
                                     onDrag: { resize(divider: key.rawValue, delta: $0) },
                                     onEnd: commitDrag)
                            .background(reorderTarget == key && draggingColumn != key
                                        ? Color.accentColor.opacity(0.18) : Color.clear)
                            .gesture(headerGesture(for: key))
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 24)
    }

    /// 列头统一手势：位移小于阈值 → 点击排序；超过阈值 → 拖拽重排。
    ///
    /// 之前把「点击」和「拖拽」拆成 onTapGesture + DragGesture 两个手势，
    /// 二者在 SwiftUI 里的优先级互相竞争，点击偶尔生效、拖拽常常不触发。
    /// 现在合成一个 DragGesture，用 minimumDistance 区分：点一下位移约等于 0
    /// 走排序，拖动超过阈值走重排，行为确定、互不干扰。
    private func headerGesture(for source: ColKey) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // 位移超过阈值才进入重排（避免轻微抖动误判成拖拽）
                let dx = value.translation.width
                guard abs(dx) >= ListMetrics.reorderThreshold else {
                    if draggingColumn == nil { draggingColumn = source }
                    return
                }
                if draggingColumn == nil {
                    draggingColumn = source
                    reorderStartX = value.startLocation.x
                }
                let offset = value.location.x - (reorderStartX ?? value.startLocation.x)
                reorderTarget = columnKey(offsetBy: offset, from: source)
            }
            .onEnded { value in
                defer {
                    draggingColumn = nil
                    reorderTarget = nil
                    reorderStartX = nil
                }
                // 位移小 → 当作点击：切换排序
                if abs(value.translation.width) < ListMetrics.reorderThreshold
                    && abs(value.translation.height) < ListMetrics.reorderThreshold {
                    model.setSortField(source.sortField)
                    return
                }
                // 位移大 → 拖拽重排
                guard let src = draggingColumn, let target = reorderTarget,
                      src != target else { return }
                moveColumn(src, to: target)
            }
    }

    /// 按横向位移推算源列「落点」列：位移累计超过若干列宽，目标就向右/左移动。
    /// 可见列按当前顺序排布，宽度固定，所以位移可以精确映射到列索引。
    private func columnKey(offsetBy dx: CGFloat, from source: ColKey) -> ColKey {
        let visible = orderedColumns.filter { isVisible($0) }
        guard let srcIndex = visible.firstIndex(of: source) else { return source }

        // 鼠标中心相对源列左边缘的位移：+ 向右、- 向左
        let halfSource = columnWidth(of: source) / 2
        let cursor = dx + halfSource  // 相对源列左边缘的「鼠标绝对位置」

        // 从源列起，往右/左走，跨过一列宽就移动一格目标
        var targetIndex = srcIndex
        if cursor >= 0 {
            // 向右：累计越过后续列
            var acc: CGFloat = 0
            for i in srcIndex..<visible.count {
                let w = columnWidth(of: visible[i])
                if cursor < acc + w { targetIndex = i; break }
                acc += w
                targetIndex = i
            }
        } else {
            // 向左
            var acc: CGFloat = 0
            for i in stride(from: srcIndex, through: 0, by: -1) {
                let w = columnWidth(of: visible[i])
                if cursor > acc - w { targetIndex = i; break }
                acc -= w
                targetIndex = i
            }
        }
        return visible[targetIndex]
    }

    /// 表头最右的列设置菜单：显示/隐藏列、恢复列宽、排序方式
    private var columnMenu: some View {
        Menu {
            Toggle(L10n.tr("大小"), isOn: $showSize)
            Toggle(L10n.tr("种类"), isOn: $showKind)
            Toggle(L10n.tr("修改日期"), isOn: $showDate)
            Toggle(L10n.tr("时长"), isOn: $showDuration)
            Divider()
            Button(L10n.tr("恢复默认列宽")) {
                nameWidth = 200
                sizeWidth = 80
                kindWidth = 100
                dateWidth = 160
                durationWidth = 70
            }
            Divider()
            Menu(L10n.tr("排序方式")) { SortMenuContents(app: app) }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help(L10n.tr("显示/隐藏列"))
    }

    /// 右键点在未选中的行上：先选中它
    private func selectIfNeeded(_ item: FileItem) {
        guard !model.selection.contains(item.url) else { return }
        model.click(item)
    }

    // MARK: 列宽拖拽

    /// 一次拖拽的固定参照：被改变的是左侧列、起始宽度多少
    private struct ResizeAnchor {
        let right: ColKey
        let left: ColKey
        let leftBase: Double
    }

    private func width(of key: ColKey) -> Double {
        switch key {
        case .name: effName
        case .size: effSize
        case .duration: effDuration
        case .kind: effKind
        case .date: effDate
        }
    }

    /// 解析存储的列顺序，补上缺失项、剔除未知项，保证总是完整的一轮
    private var orderedColumns: [ColKey] {
        let parsed = columnOrder.split(separator: ",").compactMap { ColKey(rawValue: String($0)) }
        var seen = Set<ColKey>()
        var out: [ColKey] = []
        for k in parsed where !seen.contains(k) {
            seen.insert(k)
            out.append(k)
        }
        for k in ColKey.allCases where !seen.contains(k) {
            out.append(k)
        }
        return out
    }

    /// 某列当前是否显示（名称恒显示；其余看开关）
    private func isVisible(_ key: ColKey) -> Bool {
        switch key {
        case .name: true
        case .size: showSize
        case .duration: durationVisible
        case .kind: showKind
        case .date: showDate
        }
    }

    /// 某列当前宽度（隐藏列为 0）
    private func columnWidth(of key: ColKey) -> CGFloat {
        isVisible(key) ? CGFloat(width(of: key)) : 0
    }

    /// 把 source 列拖到 target 列的位置：source 占据 target 原来的位置，
    /// target 及其右侧列整体右移（访达拖列头重排的标准语义）。
    private func moveColumn(_ source: ColKey, to target: ColKey) {
        var order = orderedColumns
        guard let s = order.firstIndex(of: source),
              let t = order.firstIndex(of: target), s != t else { return }
        order.remove(at: s)
        // source 移除后 target 的位置就是插入点（source 顶替 target 原位）
        let insertIndex = order.firstIndex(of: target) ?? t
        order.insert(source, at: insertIndex)
        columnOrder = order.map(\.rawValue).joined(separator: ",")
    }

    private func setLive(_ key: ColKey, _ value: Double) {
        switch key {
        case .name: liveName = value
        case .size: liveSize = value
        case .duration: liveDuration = value
        case .kind: liveKind = value
        case .date: liveDate = value
        }
    }

    /// 某条分隔线改变的是它**左侧**那一列的宽度。
    /// 列顺序可变，所以按「当前可见顺序」里目标列的前一列来定位左邻列；
    /// 没有左邻（即最左可见列）则返回它自己。
    private func leftNeighbor(of key: ColKey) -> ColKey {
        let visible = orderedColumns.filter { isVisible($0) }
        guard let idx = visible.firstIndex(of: key) else { return key }
        return idx > 0 ? visible[idx - 1] : key
    }

    /// 拖动某条分隔线：只改变它**左侧**那一列的宽度，
    /// 右侧各列宽度不变、随分隔线整体左右平移（这是标准表格列宽交互，
    /// 也是用户期望的行为：拽一列/二列之间的线，只有一列宽变化，其余列跟着走）。
    private func resize(divider: String, delta: Double) {
        let key: ColKey
        if let existing = dragAnchor, existing.right.rawValue == divider {
            key = existing.left
        } else {
            guard let right = ColKey(rawValue: divider) else { return }
            key = leftNeighbor(of: right)
            dragAnchor = ResizeAnchor(right: right, left: key, leftBase: width(of: key))
        }

        // 列宽是固定存储值、不再压缩，所以光标位移就是存储位移，分隔线严格 1:1 跟手。
        // 必须用拖拽开始时缓存的 leftBase 作为基准，叠加累计位移，
        // 不能用当前 live 宽度（它已包含上一帧的 delta，会重复累加）。
        let next = allowedValue(dragAnchor!.leftBase + delta, base: dragAnchor!.leftBase)
        setLive(key, next)
    }

    /// 把宽度裁到 [minWidth, maxWidth]，名称列允许更宽（文件名需要空间）
    private func allowedValue(_ value: Double, base: Double) -> Double {
        let lo: Double = base >= ListMetrics.minName ? ListMetrics.minName : ListMetrics.minWidth
        return min(max(value, lo), ListMetrics.maxWidth)
    }

    private func commitDrag() {
        if let value = liveName { nameWidth = value }
        if let value = liveSize { sizeWidth = value }
        if let value = liveDuration { durationWidth = value }
        if let value = liveKind { kindWidth = value }
        if let value = liveDate { dateWidth = value }
        liveName = nil
        liveSize = nil
        liveDuration = nil
        liveKind = nil
        liveDate = nil
        dragAnchor = nil
    }
}

/// 表头里可点的一段文字：点一下按该列升序，再点反向 —— 和访达 / 资源管理器一致。
/// 当前排序列在文字右侧画 ▲/▼，箭头紧贴文字、随列一起左右移动。
struct HeaderLabel: View {
    let title: String
    var alignment: Alignment = .leading
    var leadingPadding: CGFloat = ListMetrics.columnInset
    /// 本列是否当前排序列
    var isActive: Bool = false
    var ascending: Bool = true

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
            if isActive {
                Image(systemName: ascending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 6, weight: .bold))
            }
        }
        .padding(.leading, alignment == .leading ? leadingPadding : 0)
        .padding(.trailing, alignment == .trailing ? ListMetrics.columnInset : 0)
        .frame(maxWidth: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        // 光标：进入显示手型，离开恢复箭头。
        // 点击/拖拽已合并为外层单一 DragGesture（不再是 onTapGesture），
        // 不会触发 hover 相位的抖动，因此 onHover 的 push/pop 配对稳定，
        // 点击后不会再「手型变箭头」。
        .onHover { inside in
            if inside {
                if !hovering { hovering = true; NSCursor.pointingHand.push() }
            } else {
                if hovering { hovering = false; NSCursor.pop() }
            }
        }
    }
}

/// 可拖拽调整宽度的表头单元
///
/// 分隔线画在本列的左边缘，拖动它影响的是分隔线左侧那一列（本列右移/左移同步），
/// 与列表行中该列的边界完全对齐。
/// 点击排序由外层 `headerGesture` 统一处理，这里只负责「列宽拖拽」。
struct ColumnHeader: View {
    let title: String
    let width: Double
    let alignment: Alignment
    var isActive: Bool = false
    var ascending: Bool = true
    let onDrag: (Double) -> Void
    let onEnd: () -> Void

    var body: some View {
        HeaderLabel(title: title, alignment: alignment,
                    isActive: isActive, ascending: ascending)
            .frame(width: CGFloat(width), alignment: alignment)
            // 分隔线画在列左边界，热区跨线对称：handle 中心（视觉线）对齐到列边界上，
            // 向左回退半个热区宽度，让热区左右各占一半。
            .overlay(alignment: .leading) {
                ColumnResizeHandle(onDrag: onDrag, onEnd: onEnd)
                    .offset(x: -ListMetrics.handleHitWidth / 2)
            }
    }
}

/// 列分隔线：1pt 视觉线，拖拽热区以线为中心向两侧严格对称扩展。
///
/// 之前的问题：视觉线画在「本列左边缘」，但 handle 的 frame 叠加顺序导致
/// 热区整体偏向线的一侧，鼠标要偏离视觉线一段才抓得到。现在把 1pt 的视觉线
/// 居中放在 handleHitWidth 的透明热区中央，热区左右各占一半，严格对称。
struct ColumnResizeHandle: View {
    let onDrag: (Double) -> Void
    let onEnd: () -> Void

    @State private var hovering = false

    var body: some View {
        // 透明热区：宽 handleHitWidth（默认 9pt），视觉线居中画在正中间。
        Rectangle()
            .fill(Color.clear)
            .frame(width: ListMetrics.handleHitWidth)
            .contentShape(Rectangle())
            .overlay {
                // 1pt 视觉线，居中于热区
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
            }
            // 光标：进入显示左右拖拽箭头，离开恢复。
            .onHover { inside in
                if inside {
                    if !hovering { hovering = true; NSCursor.resizeLeftRight.push() }
                } else {
                    if hovering { hovering = false; NSCursor.pop() }
                }
            }
            // 关键：用窗口坐标系。默认的 .local 会跟着被拖动的分隔线一起移动，
            // 产生"位移→布局变化→位移基准变化"的反馈，表现为拖很远只走一半。
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag(Double($0.translation.width)) }
                    .onEnded { _ in onEnd() }
            )
    }
}

struct ListRow: View {
    let item: FileItem
    /// 行内重命名要读写窗格状态，所以整行持有模型
    let model: PaneModel
    let selected: Bool
    /// 这一行的共享正在挂载：名字后面转个小圈
    var mounting: Bool = false
    /// 已剪切、等待粘贴走：内容画成半透明
    var dimmed: Bool = false
    /// 列左右顺序（与表头一致）
    let columns: [ColKey]
    /// 每列宽度
    let widths: [ColKey: CGFloat]
    var onRightClick: (() -> Void)?

    /// 非活动窗格保留选中，但底色退成系统灰
    @Environment(\.paneActive) private var paneActive
    /// 文件名文字的实际矩形（窗口坐标），用来判断点击是否落在名字上
    @State private var nameFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { key in
                cell(for: key, width: widths[key] ?? 0)
            }
            Color.clear.frame(width: 26)
        }
        .font(.system(size: 12))
        // 只淡化内容，选中底色保持原样
        .opacity(dimmed ? 0.4 : 1)
        .foregroundStyle(selected ? PanePalette.selectionText(active: paneActive) : Color.primary)
        .frame(height: 24)
        // 必须是 .leading：默认 .infinity 的 center 会把整行内容居中，
        // 而表头是左对齐，导致「表头与列不对应」
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected
                    ? (paneActive ? PanePalette.selectionActive : PanePalette.selectionInactive)
                    : Color.clear)
        .contentShape(Rectangle())
        // 改名时让出鼠标：输入框在下面，遮住它的点按层会让光标点不进去
        .overlay {
            if !model.isRenaming(item) {
                PaneClickCatcher(item: item, onRightClick: onRightClick) { count, flags, point in
                    model.clickOrRename(item, count: count, flags: flags,
                                        at: point, nameRect: nameFrame)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for key: ColKey, width: CGFloat) -> some View {
        switch key {
        case .name:
            HStack(spacing: 6) {
                FileIcon(item: item, size: 18)
                    .frame(width: 20)
                if model.isRenaming(item) {
                    RenameEditor(item: item, model: model, fontSize: 12)
                        .frame(maxWidth: 260)
                        .layoutPriority(1)
                } else {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // 只有点在名字文字上才可能触发重命名（点图标不算）
                        .readGlobalFrame { nameFrame = $0 }
                }
                if mounting {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.leading, Tokens.spacingM)
            .frame(width: width, alignment: .leading)

        case .size:
            Text(item.sizeText)
                .lineLimit(1)
                .padding(.trailing, ListMetrics.columnInset)
                .frame(width: width, alignment: .trailing)

        case .duration:
            Text(DurationService.shared.text(for: item))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundStyle(item.isMedia ? Color.primary : Color.secondary.opacity(0.4))
                .padding(.trailing, ListMetrics.columnInset)
                .frame(width: width, alignment: .trailing)

        case .kind:
            Text(item.kindText)
                .lineLimit(1)
                .padding(.leading, ListMetrics.columnInset)
                .frame(width: width, alignment: .leading)

        case .date:
            Text(item.dateText)
                .lineLimit(1)
                // 已持久化过窄列宽的窗格不会跟着默认值变宽，留一点缩放余地
                .minimumScaleFactor(0.9)
                .padding(.leading, ListMetrics.columnInset)
                .frame(width: width, alignment: .leading)
        }
    }
}

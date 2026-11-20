import SwiftUI
import AppKit

// MARK: - 图标视图（选项驱动：档位 / 间距 / 标签位置 / 缩略图）

/// 图标视图的网格度量（选项 → 单元格尺寸 / 列数）
private struct IconLayout {
    let options: ViewOptions

    var iconSide: CGFloat {
        options.labelPosition == .below ? options.iconSize : min(options.iconSize, 64)
    }

    var cellWidth: CGFloat {
        options.labelPosition == .below ? options.iconSize + 24 : iconSide + 8 + 150
    }

    var cellHeight: CGFloat {
        switch options.labelPosition {
        case .below: return iconSide + 8 + options.textSize * 2 + 16
        case .right: return max(iconSide + 8, 36)
        }
    }

    /// 当前宽度下每行能放几个（供方向键上下移动使用）
    func columns(for width: CGFloat) -> Int {
        let usable = width - Tokens.spacingM * 2
        let step = cellWidth + options.gridSpacing
        guard step > 1, usable > 1 else { return 1 }
        return max(1, Int((usable + options.gridSpacing) / step))
    }
}

struct IconGridView: View {
    @Bindable var model: PaneModel
    @Environment(\.paneActive) private var paneActive

    /// 每个文件名文字的实际矩形（窗口坐标），用来判断点击是否落在名字上
    @State private var nameFrames: [URL: CGRect] = [:]

    private var options: ViewOptions { ViewOptionsStore.shared.options(for: model.url) }

    /// 活动窗格用蓝色淡底，非活动窗格用系统灰底——选择保留，只是不再抢焦点
    private func selectionFill(for item: FileItem) -> Color {
        guard model.selection.contains(item.url) else { return .clear }
        return paneActive ? Color.accentColor.opacity(0.18) : PanePalette.selectionInactive
    }

    var body: some View {
        GeometryReader { geo in
            let opt = options
            let layout = IconLayout(options: opt)

            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        LazyVGrid(
                            columns: [
                                // 不给 maximum：列宽会均分剩余空间，图标网格横向铺满窗格，
                                // 不会在右侧留出一条空白
                                GridItem(.adaptive(minimum: layout.cellWidth),
                                         spacing: opt.gridSpacing,
                                         alignment: .top)
                            ],
                            alignment: .leading,
                            spacing: Tokens.spacingL
                        ) {
                            ForEach(model.items) { item in
                                IconCell(item: item,
                                         model: model,
                                         options: opt,
                                         mounting: model.mountingShare == item.name,
                                         onNameFrame: { nameFrames[item.url] = $0 })
                                    // 已剪切的项目变半透明（底色仍保留选中态）
                                    .opacity(model.isCut(item.url) ? 0.4 : 1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: layout.cellHeight)
                                    .background(
                                        selectionFill(for: item),
                                        in: RoundedRectangle(cornerRadius: Tokens.cornerCard, style: .continuous)
                                    )
                                    // 把自身矩形报给框选层
                                    .marqueeFrame(for: item.url)
                                    .contentShape(Rectangle())
                                    .overlay {
                                        // 改名时让出鼠标，否则点不进输入框
                                        if !model.isRenaming(item) {
                                            PaneClickCatcher(item: item, onRightClick: {
                                                selectIfNeeded(item)
                                            }) { count, flags, point in
                                                model.clickOrRename(item, count: count, flags: flags,
                                                                    at: point, nameRect: nameFrames[item.url])
                                            }
                                        }
                                    }
                                    .paneContextMenu(item: item)
                            }
                        }
                        .padding(Tokens.spacingM)
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    // 空白处：单击取消选择，拖出选框批量选中。
                    // 必须挂在「已被 frame 撑满」的容器上：作为 ZStack 的普通子视图时，
                    // 滚动视图给出的高度提案是 nil，它会退化成 0 尺寸从而收不到点击。
                    .marqueeSelection(model: model) { model.clearSelection() }
                    .paneContextMenu(item: nil)
                }
                .onAppear { model.gridColumns = layout.columns(for: geo.size.width) }
                .onChange(of: geo.size.width) { _, width in model.gridColumns = layout.columns(for: width) }
                .onChange(of: opt) { _, _ in model.gridColumns = layout.columns(for: geo.size.width) }
                // 键盘导航 / 首字母跳转后把选中项滚进视野
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    /// 右键点在未选中的项目上：先把它选中（已选中的多选保持不变）
    private func selectIfNeeded(_ item: FileItem) {
        guard !model.selection.contains(item.url) else { return }
        model.click(item)
    }
}

struct IconCell: View {
    let item: FileItem
    let model: PaneModel
    let options: ViewOptions
    /// 共享正在挂载：图标上盖一个小转圈
    var mounting: Bool = false
    /// 汇报文件名文字在窗口内的矩形（用于「点名字才触发重命名」）
    var onNameFrame: ((CGRect) -> Void)? = nil

    private var layout: IconLayout { IconLayout(options: options) }

    var body: some View {
        switch options.labelPosition {
        case .below:
            VStack(spacing: 6) {
                icon
                label
                    .multilineTextAlignment(.center)
                    .frame(width: options.iconSize + 16)
            }
            .padding(.horizontal, 4)
        case .right:
            HStack(spacing: 8) {
                icon
                label
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
        }
    }

    private var icon: some View {
        Group {
            if options.showThumbnails {
                ThumbnailView(item: item, size: layout.iconSide)
            } else {
                FileIcon(item: item, size: layout.iconSide)
            }
        }
        .frame(width: layout.iconSide, height: layout.iconSide)
        .overlay {
            if mounting {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if model.isRenaming(item) {
            RenameEditor(item: item,
                         model: model,
                         fontSize: options.textSize,
                         alignment: options.labelPosition == .below ? .center : .left)
                .frame(width: options.labelPosition == .below ? options.iconSize + 24 : nil)
        } else {
            Text(item.name)
                .font(.system(size: options.textSize))
                .lineLimit(2)
                .truncationMode(.middle)
                .readGlobalFrame { onNameFrame?($0) }
        }
    }
}

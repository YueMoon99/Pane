import SwiftUI
import AppKit

// MARK: - 画廊视图（大预览 + 真实缩略图 + 信息区 + 右侧列表）

struct GalleryView: View {
    @Bindable var model: PaneModel
    @Environment(\.paneActive) private var paneActive

    @State private var metadata: FileMetadata?
    /// 缩略图条里每个文件名文字的实际矩形（窗口坐标）
    @State private var nameFrames: [URL: CGRect] = [:]

    private var options: ViewOptions { ViewOptionsStore.shared.options(for: model.url) }

    private var current: FileItem? {
        if let id = model.selection.first, let item = model.items.first(where: { $0.url == id }) {
            return item
        }
        return model.items.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                preview
                Divider()
                filmstrip
            }

            Divider()

            GeometryReader { geo in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items) { item in
                                CompactRow(item: item,
                                           model: model,
                                           selected: model.selection.contains(item.url),
                                           dimmed: model.isCut(item.url),
                                           onRightClick: { selectIfNeeded(item) })
                                .marqueeFrame(for: item.url)
                                .paneContextMenu(item: item)
                            }
                        }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    // 空白处：单击取消选择 / 拖动框选
                    .marqueeSelection(model: model) { model.clearSelection() }
                    .paneContextMenu(item: nil)
                }
            }
            .frame(width: 260)
        }
    }

    // MARK: 主预览

    private var preview: some View {
        VStack(spacing: Tokens.spacingM) {
            Spacer(minLength: 0)

            if let cur = current {
                // 投影由 ThumbnailView 自己按尺寸给（跟着预览尺寸缩放），这里不再叠一层
                ThumbnailView(item: cur, size: options.galleryPreviewSize, fallbackScale: 0.9)

                VStack(spacing: 3) {
                    Text(cur.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 10) {
                        Text(cur.sizeText)
                        ForEach(metadata?.detailLines ?? [], id: \.self) { line in
                            Text(line)
                        }
                        if options.showGalleryInfo {
                            Text(cur.dateText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.horizontal, Tokens.spacingL)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .overlay {
            if let cur = current {
                PaneClickCatcher(item: cur) { count, _, _ in
                    if count >= 2 { model.enter(cur) }
                    else { model.clearSelection() }
                }
            }
        }
        .task(id: current?.url) { await loadMetadata() }
    }

    /// 右键点在未选中的行上：先选中它
    private func selectIfNeeded(_ item: FileItem) {
        guard !model.selection.contains(item.url) else { return }
        model.click(item)
    }

    private func loadMetadata() async {        guard let cur = current, !cur.isDirectory else {
            metadata = nil
            return
        }
        if let cached = MetadataService.shared.cached(cur) {
            metadata = cached
        } else {
            metadata = nil
        }
        let loaded = await MetadataService.shared.metadata(for: cur)
        guard !Task.isCancelled, current?.url == cur.url else { return }
        metadata = loaded
    }

    // MARK: 底部缩略图条

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.spacingS) {
                ForEach(model.items) { item in
                    thumbnail(item)
                }
            }
            .padding(Tokens.spacingS)
        }
        .frame(height: 96)
    }

    private func thumbnail(_ item: FileItem) -> some View {
        let selected = model.selection.contains(item.url)
        return VStack(spacing: Tokens.spacingXS) {
            ThumbnailView(item: item, size: 64, cornerRadius: Tokens.cornerS)
                .frame(width: 64, height: 64)
                // 已剪切的项目变半透明
                .opacity(model.isCut(item.url) ? 0.4 : 1)
                // 底板和描边由 ThumbnailView 自己画（白底内容靠它定边界），这里只留选中环
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.cornerS, style: .continuous)
                        .stroke(selected
                                ? (paneActive ? PanePalette.selectionActive : PanePalette.selectionInactive)
                                : Color.clear,
                                lineWidth: 2)
                }
            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 64)
                .opacity(model.isCut(item.url) ? 0.4 : 1)
                .readGlobalFrame { nameFrames[item.url] = $0 }
        }
        .contentShape(Rectangle())
        .overlay {
            PaneClickCatcher(item: item, onRightClick: {}) { count, flags, point in
                model.clickOrRename(item, count: count, flags: flags,
                                    at: point, nameRect: nameFrames[item.url])
            }
        }
        .paneContextMenu(item: item, onOpen: { item in
            model.click(item)
            model.enter(item)
        })
    }
}

/// 画廊右侧 / 窄栏使用的紧凑行，避免多列在 260pt 内被挤压
struct CompactRow: View {
    let item: FileItem
    let model: PaneModel
    let selected: Bool
    /// 已剪切、等待粘贴走：内容画成半透明
    var dimmed: Bool = false
    var onRightClick: (() -> Void)?

    @Environment(\.paneActive) private var paneActive
    /// 文件名文字的实际矩形（窗口坐标）
    @State private var nameFrame: CGRect = .zero

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
            Spacer(minLength: 4)
            Text(item.sizeText)
                .lineLimit(1)
                .foregroundStyle(selected
                                 ? PanePalette.selectionText(active: paneActive).opacity(0.85)
                                 : Color.secondary)
        }
        .font(.system(size: 12))
        .opacity(dimmed ? 0.4 : 1)
        .foregroundStyle(selected ? PanePalette.selectionText(active: paneActive) : Color.primary)
        .padding(.horizontal, Tokens.spacingM)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(selected
                    ? (paneActive ? PanePalette.selectionActive : PanePalette.selectionInactive)
                    : Color.clear)
        .contentShape(Rectangle())
        .overlay {
            if !model.isRenaming(item) {
                PaneClickCatcher(item: item, onRightClick: onRightClick) { count, flags, point in
                    model.clickOrRename(item, count: count, flags: flags,
                                        at: point, nameRect: nameFrame)
                }
            }
        }
    }
}

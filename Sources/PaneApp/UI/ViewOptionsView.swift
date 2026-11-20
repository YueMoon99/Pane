import SwiftUI

/// ⌘J 视图选项面板：按文件夹记忆，可继承上级 / 全局默认
struct ViewOptionsView: View {
    let url: URL
    let mode: ViewMode

    @Environment(\.dismiss) private var dismiss

    @State private var options: ViewOptions
    @State private var customized: Bool

    init(url: URL, mode: ViewMode) {
        self.url = url
        self.mode = mode
        let store = ViewOptionsStore.shared
        _options = State(initialValue: store.options(for: url))
        _customized = State(initialValue: store.isCustomized(url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Form {
                switch mode {
                case .icon:     iconSection
                case .list:     listSection
                case .column:   columnSection
                case .gallery:  gallerySection
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()

            footer
        }
        .frame(width: 400)
        .onChange(of: options) { _, new in
            ViewOptionsStore.shared.update(new, for: url)
            customized = ViewOptionsStore.shared.isCustomized(url)
        }
    }

    // MARK: 头部 / 底部

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.tr("%@视图选项", mode.title))
                .font(.headline)
            Text(url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: Tokens.spacingS) {
            Button(L10n.tr("用作默认")) { ViewOptionsStore.shared.saveAsGlobal(options) }
                .help(L10n.tr("把当前设置作为所有未单独设置文件夹的默认值"))

            Button(L10n.tr("全部恢复默认")) {
                ViewOptionsStore.shared.resetAll()
                options = ViewOptionsStore.shared.options(for: url)
                customized = false
            }

            if customized {
                Button(L10n.tr("跟随上级")) {
                    ViewOptionsStore.shared.clearOverride(for: url)
                    options = ViewOptionsStore.shared.options(for: url)
                    customized = false
                }
                .help(L10n.tr("删除此文件夹的单独设置，改为继承上级文件夹"))
            }

            Spacer()

            Button(L10n.tr("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 各视图的分区

    @ViewBuilder
    private var iconSection: some View {
        Section(L10n.tr("图标")) {
            LabeledContent(L10n.tr("图标大小")) {
                Picker("", selection: $options.iconSize) {
                    ForEach(ViewOptions.iconSizeSteps, id: \.self) { step in
                        Text("\(Int(step))").tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LabeledContent(L10n.tr("网格间距")) {
                HStack(spacing: Tokens.spacingS) {
                    Slider(value: $options.gridSpacing, in: 4...24, step: 4)
                    Text("\(Int(options.gridSpacing)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            LabeledContent(L10n.tr("标签位置")) {
                Picker("", selection: $options.labelPosition) {
                    ForEach(IconLabelPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LabeledContent(L10n.tr("标签字号")) {
                HStack(spacing: Tokens.spacingS) {
                    Slider(value: $options.textSize, in: 9...15, step: 1)
                    Text("\(Int(options.textSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Toggle(L10n.tr("显示缩略图预览"), isOn: $options.showThumbnails)
        }
    }

    @ViewBuilder
    private var listSection: some View {
        Section(L10n.tr("列表")) {
            Text(L10n.tr("列宽在表头分隔线上拖动调整；列的显示与隐藏在表头右侧菜单里。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var columnSection: some View {
        Section(L10n.tr("分栏")) {
            LabeledContent(L10n.tr("列宽")) {
                HStack(spacing: Tokens.spacingS) {
                    Slider(value: $options.columnWidth,
                           in: ViewOptions.columnWidthRange,
                           step: 10)
                    Text("\(Int(options.columnWidth)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Text(L10n.tr("也可以在列之间的分隔线上拖动；最多同时显示 4 列，←/→ 切换层级。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var gallerySection: some View {
        Section(L10n.tr("画廊")) {
            LabeledContent(L10n.tr("预览大小")) {
                HStack(spacing: Tokens.spacingS) {
                    Slider(value: $options.galleryPreviewSize,
                           in: ViewOptions.galleryPreviewRange,
                           step: 20)
                    Text("\(Int(options.galleryPreviewSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Toggle(L10n.tr("信息区显示修改日期"), isOn: $options.showGalleryInfo)
        }
    }
}

import SwiftUI

/// 复制 / 移动时的进度卡片：右下角浮起，右侧灰色小 × 可以中止。
///
/// 进度数据由后台线程写入、这里用 `TimelineView` 定时取快照刷新，
/// 不走 `@Observable`（后台改 @Observable 属性会踩主线程隔离的坑）。
struct TransferHUD: View {
    let task: TransferTask

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { _ in
            let snap = task.snapshot
            VStack(alignment: .leading, spacing: 7) {
                Text(title(snap))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    progressBar(snap.fraction)
                    abortButton(snap)
                }
                Text(detail(snap))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
            .frame(width: 236)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
    }

    /// 自己画进度条：系统的线性 ProgressView 在 macOS 上只有 2pt 高，细得看不清
    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(PanePalette.selection)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 3))
            }
        }
        .frame(height: 4)
    }

    private func title(_ snap: TransferTask.Snapshot) -> String {
        if snap.cancelled { return L10n.tr("正在中止…") }
        return L10n.tr("正在%@ %@ 个项目", snap.verb, snap.totalItems)
    }

    private func detail(_ snap: TransferTask.Snapshot) -> String {
        if snap.preparing { return L10n.tr("正在统计…") }
        let name = snap.currentName.isEmpty ? "" : " · \(snap.currentName)"
        if snap.totalBytes > 0 {
            return "\(bytes(snap.completedBytes)) / \(bytes(snap.totalBytes))\(name)"
        }
        return L10n.tr("%@ / %@ 项%@", snap.completedItems, snap.totalItems, name)
    }

    @ViewBuilder
    private func abortButton(_ snap: TransferTask.Snapshot) -> some View {
        Button {
            task.cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(snap.cancelled ? 0.35 : 0.9))
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(snap.cancelled)
        .help(L10n.tr("中止%@", snap.verb))
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

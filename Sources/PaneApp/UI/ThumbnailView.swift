import SwiftUI
import AppKit

/// 文件缩略图：先显示系统图标占位，QuickLook 缩略图到达后平滑替换。
///
/// 之所以能「滚动挂起」：`task(id:)` 在 cell 被 LazyVGrid / LazyVStack 回收时
/// 自动取消，取消后不会继续发起 QuickLook 生成。
///
/// 只有**真正的页面预览**才垫浅灰底板并带极轻的投影：白底图片、白底视频首帧、
/// 文本 / PDF 页面这类内容本身是白的，直接摊在白底工作区上会连边界都看不见
/// （Finder / QSpace 也是同样做法 —— 预览永远浮在背景之上一点点）。
///
/// 没有预览的文件（.aep / .prproj / .c4d 这类没有 QuickLook 插件的格式，
/// `ThumbnailService` 会返回 nil）直接走 `FileIcon`：系统图标自带立体感，
/// 再套一层底板只会像「阴影落在框上」。
struct ThumbnailView: View {
    let item: FileItem
    /// 目标显示边长（pt）
    let size: CGFloat
    var fallbackScale: CGFloat = 0.82
    var cornerRadius: CGFloat = 4

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    private var cacheKey: String { "\(item.url.path)|\(Int(size.rounded()))" }

    /// 底板四周留的空，正好够投影晕开，免得被父视图的 frame 截断
    private var plateInset: CGFloat { max(1, min(3, size * 0.022)) }

    var body: some View {
        // 读一下这个开关：切换「网络宗卷显示缩略图」后，格子要重新请求
        let remoteEnabled = ThumbnailSettings.shared.allowRemote
        ZStack {
            if let image {
                plate(for: image)
            } else {
                FileIcon(item: item, size: size * fallbackScale)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(cacheKey)|\(remoteEnabled)") { await load() }
    }

    // MARK: 缩略图底板

    /// 按图片自身比例摆放（不撑成正方形，避免照片两侧出现灰条），
    /// 底板 + 1pt 描边 + 投影一起贴在图片轮廓上。
    private func plate(for image: NSImage) -> some View {
        let fitted = fittedSize(of: image)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: fitted.width, height: fitted.height)
            // 底板：透明 PNG、白色图片都能透出一点灰，边界立刻可见
            .background(shape.fill(plateFill))
            // 描边画在图片之上，纯白内容也能抠出轮廓
            .overlay(shape.strokeBorder(plateStroke, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: plateShadow, radius: shadowRadius, y: shadowRadius * 0.45)
    }

    private func fittedSize(of image: NSImage) -> CGSize {
        let available = max(1, size - plateInset * 2)
        let original = image.size
        guard original.width > 0, original.height > 0 else {
            return CGSize(width: available, height: available)
        }
        let scale = min(available / original.width, available / original.height)
        return CGSize(width: max(1, (original.width * scale).rounded()),
                      height: max(1, (original.height * scale).rounded()))
    }

    /// 底板填充：浅色下是很淡的灰白（#F7F7F7），深色下是深灰
    private var plateFill: Color {
        colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.969)
    }

    /// 描边：1pt 的极淡灰线，白底内容靠它定边界（约 #DDDDDD，和访达的文档描边同一档）
    private var plateStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.135)
    }

    /// 投影半径跟着尺寸走：96pt 的格子约 2pt，画廊大图约 8pt
    private var shadowRadius: CGFloat { max(1.5, min(9, size * 0.022)) }

    private var plateShadow: Color {
        colorScheme == .dark ? Color.black.opacity(0.55) : Color.black.opacity(0.17)
    }

    // MARK: 加载

    private func load() async {
        // 网络卷在设置关闭时不生成缩略图：别留着上一次的图，退回系统图标
        guard ThumbnailService.supportsPreview(item) else {
            image = nil
            return
        }
        if let hit = ThumbnailService.shared.cached(item, size: size) {
            image = hit
            return
        }
        image = nil
        // 滚动中先等一下：40ms 内被回收的 cell 不会触发缩略图生成
        try? await Task.sleep(for: .milliseconds(40))
        guard !Task.isCancelled else { return }
        guard let loaded = await ThumbnailService.shared.thumbnail(for: item, size: size) else { return }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.12)) { image = loaded }
    }
}

import SwiftUI

// MARK: - 文件名热区测量
//
// 「再次点击已选中项进入重命名」只应该在点到**文件名文字**时触发：
// 点图标、点行内空白都不该响应（否则误触发率太高）。
//
// 做法：把 Text 实际排布出来的矩形汇报给所在行，点击时用窗口坐标比对。
// 坐标统一用 SwiftUI 的 `.global`（窗口内、左上原点、y 向下），
// ClickCatcher 会按同一套坐标给出点击位置。

/// 读取自身在窗口内的矩形，尺寸/位置变化时回调
struct GlobalFrameReader: View {
    let onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onAppear { onChange(frame) }
                .onChange(of: frame) { _, new in onChange(new) }
        }
    }
}

extension View {
    /// 把自身在窗口内的矩形报出去（用作「文件名热区」）
    func readGlobalFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        background(GlobalFrameReader(onChange: onChange))
    }
}

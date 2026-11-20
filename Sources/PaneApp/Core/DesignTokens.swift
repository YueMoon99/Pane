import SwiftUI
import AppKit

// MARK: - 设计令牌（对应 03-UI设计与交互规范 §2）

enum Tokens {
    // 尺寸
    static let sidebarWidth: CGFloat = 220
    static let rowHeight: CGFloat = 24
    static let statusBarHeight: CGFloat = 24
    static let pathBarHeight: CGFloat = 28
    static let paneHeaderHeight: CGFloat = 32
    static let iconGridSize: CGFloat = 96
    static let listIconSize: CGFloat = 18

    // 间距（4pt 栅格）
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16

    // 圆角
    static let cornerS: CGFloat = 8
    static let cornerSelected: CGFloat = 6
    static let cornerCard: CGFloat = 10
}

// MARK: - Pane 专属色板

enum PanePalette {
    /// 选中项底色，与选中文件夹一致（#3478f6）
    static let selection = Color(.sRGB,
                                 red: 0x34 / 255,
                                 green: 0x78 / 255,
                                 blue: 0xF6 / 255,
                                 opacity: 1)
    /// 活动区（三按钮 + 地址栏整条）的蓝色底，与选中色一致
    static let focusBar = selection
    /// 该底色上的文字（浅色，保证对比度）
    static let focusBarText = Color.white

    /// 地址栏 / 导航胶囊的表面色。
    ///
    /// 必须随外观切换：地址栏上的文字用的是 `.primary` / `.secondary`，
    /// 深色模式下它们会变成白字，压在写死的纯白底上就完全看不见了
    /// （浅色 #ffffff / #e6e6e6，深色 #3a3a3c / #2a2a2c）。
    ///
    /// 这里按 `colorScheme` 显式取值，而不是用动态 NSColor：运行中切换
    /// 「外观」时 SwiftUI 会因为环境里的 colorScheme 变化而必定重绘。
    static func barSurface(active: Bool, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return active ? darkBarActive : darkBarInactive
        }
        return active ? .white : lightBarInactive
    }

    private static let lightBarInactive = Color(.sRGB,
                                                red: 0xE6 / 255,
                                                green: 0xE6 / 255,
                                                blue: 0xE6 / 255,
                                                opacity: 1)
    private static let darkBarInactive = Color(.sRGB,
                                               red: 0x2A / 255,
                                               green: 0x2A / 255,
                                               blue: 0x2C / 255,
                                               opacity: 1)
    private static let darkBarActive = Color(.sRGB,
                                             red: 0x3A / 255,
                                             green: 0x3A / 255,
                                             blue: 0x3C / 255,
                                             opacity: 1)

    // MARK: 选中态

    /// 活动窗格的选中底色
    static let selectionActive = selection
    /// 非活动窗格的选中底色：系统「非强调选择」色，浅色下是浅灰、深色下是深灰，随外观自适应
    static let selectionInactive = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    /// 选中项文字色：活动窗格用白字压在蓝底上，非活动保持主色压在灰底上
    static func selectionText(active: Bool) -> Color {
        active ? .white : .primary
    }
}

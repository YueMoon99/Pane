import Foundation
import SwiftUI

/// 缩略图的全局开关。
///
/// 为什么默认在网络卷上关掉：SMB / AFP 上生成一张缩略图 = 把源文件读一遍，
/// 一屏几十个 cell 同时请求会把带宽吃满、界面跟着卡住（见 `VolumeInspector`）。
/// 打开这个开关后只对「看一眼就知道是什么」的图片 / 视频 / PDF 生成，
/// 并且限制并发与体积——第一次进目录会明显慢，之后就吃磁盘缓存了。
@MainActor
@Observable
final class ThumbnailSettings {
    static let shared = ThumbnailSettings()

    private static let key = "thumbs.remote"
    /// 网络卷上生成缩略图的最大文件体积：超过这个尺寸拉一遍太亏
    static let remoteSizeLimit: Int64 = 64 * 1024 * 1024

    var allowRemote: Bool {
        didSet {
            guard allowRemote != oldValue else { return }
            UserDefaults.standard.set(allowRemote, forKey: Self.key)
            // 清掉内存缓存，让已显示的格子按新设置重新请求
            ThumbnailService.shared.invalidateMemory()
        }
    }

    private init() {
        allowRemote = UserDefaults.standard.bool(forKey: Self.key)
    }
}

import SwiftUI

/// 设置窗口。
///
/// 只有一页，就不再用 TabView——单项 TabView 会在窗口里画出一个巨大的图标
/// 和标题，把表单挤到下面。直接摆 Form 更干净。
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Bindable private var thumbnails = ThumbnailSettings.shared
    @Bindable private var localization = LocalizationStore.shared

    var body: some View {
        @Bindable var app = app
        Form {
            Section(L10n.tr("外观")) {
                Picker(L10n.tr("语言"), selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
                .pickerStyle(.segmented)

                Picker(L10n.tr("主题"), selection: $app.appearance) {
                    ForEach(AppearanceChoice.allCases) { a in
                        Text(a.title).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.tr("窗口")) {
                Toggle(L10n.tr("显示路径栏"), isOn: $app.showPathBar)
                Toggle(L10n.tr("显示状态栏"), isOn: $app.showStatusBar)
            }

            Section(L10n.tr("缩略图")) {
                Toggle(L10n.tr("在网络宗卷上显示缩略图"), isOn: $thumbnails.allowRemote)
                Text(L10n.tr("SMB 等网络卷上生成缩略图要把文件读一遍，第一次进目录会明显变慢。")
                     + L10n.tr("只对图片、视频和 PDF 生成；图片与 PDF 限 64MB 以内，视频只取首帧，不受体积限制。")
                     + L10n.tr("生成过一次之后会进本地缓存，再进同一目录就是秒开。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.tr("Pane 设置"))
        .frame(width: 480, height: 460)
    }
}

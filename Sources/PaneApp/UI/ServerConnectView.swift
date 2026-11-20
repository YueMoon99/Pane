import SwiftUI

/// 「连接服务器」弹窗要连的是哪一台：新服务器，还是列表里已有的那一台
enum ServerSheetTarget: Identifiable, Hashable {
    case new
    case existing(ServerProfile)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let profile): profile.id.uuidString
        }
    }

    var profile: ServerProfile? {
        if case .existing(let profile) = self { return profile }
        return nil
    }
}

/// 添加 / 重新连接服务器。
///
/// 这里只负责「认证」这件事：认证通过后回到工作区，
/// 由工作区像文件夹一样列出这台机器上的所有共享，双击某个共享才挂载。
struct ServerConnectView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let target: ServerSheetTarget

    @State private var address = ""
    /// 可选：直接进某一个共享（服务器禁止浏览共享时用得上）
    @State private var share = ""
    @State private var label = ""
    @State private var user = ""
    @State private var password = ""
    @State private var remember = true
    @State private var errorText: String?
    @State private var busy = false

    private var savedProfile: ServerProfile? {
        guard let profile = target.profile else { return nil }
        return app.server.profile(id: profile.id) ?? profile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                Text(L10n.tr("连接 SMB 服务器"))
                    .font(.headline)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(L10n.tr("地址")).foregroundStyle(.secondary)
                    TextField(L10n.tr("192.168.1.10 或 smb://nas.local"), text: $address)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.tr("备注")).foregroundStyle(.secondary)
                    TextField(L10n.tr("侧边栏显示的名字，例如 家里 NAS"), text: $label)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.tr("账号")).foregroundStyle(.secondary)
                    TextField(L10n.tr("留空则用访客身份；需要域时写 DOMAIN\\user"), text: $user)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.tr("密码")).foregroundStyle(.secondary)
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L10n.tr("直接进入共享")).foregroundStyle(.secondary)
                    TextField(L10n.tr("可留空；留空则先列出全部共享，双击哪个进哪个"), text: $share)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text(L10n.tr("连接成功后，工作区会像文件夹一样列出这台服务器上的所有共享，双击才挂载。")
                 + L10n.tr("「直接进入共享」只在服务器禁止浏览共享列表时才需要填。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.tr("记住密码（保存到钥匙串，下次点一下就直接进）"), isOn: $remember)
                .toggleStyle(.checkbox)

            if let profile = savedProfile, !app.server.mountURLs(profile).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(app.server.mountURLs(profile), id: \.self) { url in
                        Text(L10n.tr("已挂载：%@", url.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(app.server.statusText ?? L10n.tr("正在连接…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let profile = savedProfile, app.server.isConnected(profile) {
                    Button(L10n.tr("断开连接")) {
                        app.server.disconnect(profile)
                        dismiss()
                    }
                }
                Button(L10n.tr("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("连接")) {
                    Task { await connect() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear(perform: prefill)
    }

    // MARK: - 表单

    private func prefill() {
        if let profile = target.profile {
            address = profile.host
            share = profile.share
            label = profile.label
            user = profile.user
            password = app.server.savedPassword(for: profile) ?? ""
            errorText = nil
            return
        }
        // 新建：沿用上一次的账号更省事，地址留空避免误填到别的机器
        if let last = app.server.profiles.last {
            user = last.user
        }
        remember = true
    }

    private func connect() async {
        errorText = nil
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorText = L10n.tr("请输入服务器地址")
            return
        }
        guard let parsed = SMBMounter.parse(text) else {
            errorText = L10n.tr("地址格式无效，请检查服务器 IP 或主机名")
            return
        }

        busy = true
        defer { busy = false }

        // 共享名可能来自输入框，也可能是地址里带的 smb://host/共享名
        let typedShare = SMBMounter.normalizeShare(share)
        let finalShare = typedShare.isEmpty ? parsed.share : typedShare

        var candidate = target.profile ?? ServerProfile()
        candidate.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.host = parsed.host
        candidate.share = finalShare
        candidate.user = user.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let profile = await app.server.connect(
            candidate,
            password: password,
            remember: remember
        ) else {
            errorText = app.server.lastError ?? L10n.tr("连接失败")
            return
        }

        // 填了共享名：直接进那个共享；否则进「服务器共享列表」
        if let mounted = app.server.mountedShares(profile).values.first {
            app.focused.navigate(to: mounted)
        } else {
            app.focused.openServer(app.server.location(for: profile))
        }
        dismiss()
    }
}

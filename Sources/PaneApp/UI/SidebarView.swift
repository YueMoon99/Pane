import SwiftUI
import AppKit

struct SidebarView: View {
    var onNavigate: (URL) -> Void
    /// 当前窗格所在位置：用来高亮正在浏览的那一行
    var currentURL: URL? = nil
    /// 书签列表（可增删、持久化）
    var bookmarks: BookmarkStore
    /// 服务器列表与连接状态
    var server: ServerModel
    var onAddServer: () -> Void = {}
    /// 点一行服务器：在工作区里列出它的共享（缺密码时才由外层弹连接窗口）
    var onServerTap: (ServerProfile) -> Void = { _ in }
    var onServerEject: (ServerProfile) -> Void = { _ in }
    /// 右键「重新连接…」：打开连接窗口重新输入密码
    var onServerReconnect: (ServerProfile) -> Void = { _ in }
    /// 只有服务器行靠点击状态高亮；书签与位置行跟随当前目录
    @State private var selection: String? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                section(L10n.tr("书签")) {
                    ForEach(bookmarks.items) { item in
                        bookmarkRow(item)
                    }
                    if bookmarks.items.isEmpty {
                        emptyHint(L10n.tr("右键任意文件夹 → 添加到书签"))
                    }
                }
                section(L10n.tr("位置")) {
                    ForEach(locations) { item in
                        row(for: item)
                    }
                }
                section(L10n.tr("标签")) {
                    ForEach(tagColors) { c in
                        simpleRow(id: "tag-\(c.id.uuidString)",
                                  title: L10n.tr(c.label),
                                  help: L10n.tr("标签筛选将在 M7 接入")) {
                            Image(systemName: "tag.fill")
                                .foregroundStyle(c.color)
                                .frame(width: 16)
                        }
                    }
                }
                section(L10n.tr("服务器")) {
                    ForEach(server.profiles) { profile in
                        serverRow(profile)
                    }
                    addServerRow
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .navigationTitle("Pane")
    }

    // MARK: 分组

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 2)
        content()
    }

    // MARK: 行

    private func row(for item: SidebarItem) -> some View {
        let selected = isBrowsing(item.url)
        return HStack(spacing: 7) {
            itemIcon(item, selected: selected)
                .frame(width: 16, height: 16)
            Text(item.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .overlay {
            ClickCatcher { _, _, _ in
                if let url = item.url {
                    onNavigate(url)
                }
            }
        }
    }

    /// 一行书签：图标取真实文件夹图标，右键可移除
    private func bookmarkRow(_ item: Bookmark) -> some View {
        let selected = isBrowsing(item.url)
        return HStack(spacing: 7) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(item.displayName)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
        .help(item.path)
        .contentShape(Rectangle())
        .overlay {
            ClickCatcher { _, _, _ in
                onNavigate(item.url)
            }
        }
        .contextMenu {
            Button(L10n.tr("打开")) { onNavigate(item.url) }
            Button(L10n.tr("在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button(L10n.tr("拷贝路径")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(item.path, forType: .string)
            }
            Divider()
            Button(L10n.tr("从书签移除")) { bookmarks.remove(item) }
        }
    }

    /// 分组为空时的一行说明文字
    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
    }

    /// 光标是不是正停在这个位置（书签 / 位置行的高亮依据）
    private func isBrowsing(_ url: URL?) -> Bool {
        guard let url, let currentURL else { return false }
        return Self.normalized(currentURL) == Self.normalized(url)
    }

    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func simpleRow<Icon: View>(id: String,
                                       title: String,
                                       help: String,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 7) {
            icon()
                .frame(width: 16, height: 16)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selection == id ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .foregroundStyle(selection == id ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .help(help)
        .overlay {
            ClickCatcher { _, _, _ in
                selection = id
            }
        }
    }

    /// 一行服务器：显示备注名，已连接的右侧有弹出按钮
    private func serverRow(_ profile: ServerProfile) -> some View {
        let connected = server.isConnected(profile)
        let rowID = "srv-\(profile.id.uuidString)"
        let selected = selection == rowID

        return HStack(spacing: 4) {
            HStack(spacing: 7) {
                if server.isConnecting(profile) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "server.rack")
                        .foregroundStyle(selected ? Color.white : (connected ? Color.accentColor : Color.secondary))
                        .frame(width: 16, height: 16)
                }
                Text(profile.displayName)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay {
                ClickCatcher { _, _, _ in
                    selection = rowID
                    onServerTap(profile)
                }
            }

            // 只有已连接的服务器才有弹出按钮
            if connected {
                Button {
                    onServerEject(profile)
                } label: {
                    Image(systemName: "eject")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .help(L10n.tr("断开并弹出「%@」", profile.displayName))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
        .help(connected ? "\(profile.displayName)（\(profile.subtitle)）" : L10n.tr("点击连接 %@", profile.displayName))
        .contextMenu {
            Button(L10n.tr("打开共享列表")) { onServerTap(profile) }
            Button(L10n.tr("重新连接…")) { onServerReconnect(profile) }
            if connected {
                Button(L10n.tr("弹出（断开）")) { onServerEject(profile) }
            }
            Divider()
            Button(L10n.tr("从列表移除")) { server.remove(profile) }
        }
    }

    /// 「服务器」分组末尾的 + 号：打开连接服务器窗口
    private var addServerRow: some View {
        Button {
            selection = "srv-add"
            onAddServer()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle")
                    .frame(width: 16, height: 16)
                Text(L10n.tr("连接服务器…"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L10n.tr("添加 SMB 服务器"))
    }

    @ViewBuilder
    private func itemIcon(_ item: SidebarItem, selected: Bool) -> some View {
        if let url = item.url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else if let symbol = item.symbol {
            Image(systemName: symbol)
                .foregroundStyle(selected ? Color.white : Color.secondary)
        }
    }
}

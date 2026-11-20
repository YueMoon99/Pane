import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Bindable private var operations = FileOperationService.shared
    @Bindable private var actions = FileActionService.shared
    @State private var serverSheet: ServerSheetTarget?

    var body: some View {
        @Bindable var app = app
        // 标签栏只横跨内容区（右侧），左侧栏保持通高 —— 与访达一致。
        NavigationSplitView {
            SidebarView(
                onNavigate: { url in app.focused.navigate(to: url) },
                currentURL: app.focused.url,
                bookmarks: BookmarkStore.shared,
                server: app.server,
                onAddServer: { serverSheet = .new },
                onServerTap: { profile in
                    // 和 QSpace 一样：点一下就在工作区里像文件夹一样列出共享，
                    // 只有「没保存过密码」时才需要弹窗问一次
                    if app.server.needsCredentials(profile) {
                        serverSheet = .existing(profile)
                    } else {
                        app.focused.openServer(ServerLocation(profile: profile))
                    }
                },
                onServerEject: { profile in app.server.disconnect(profile) },
                onServerReconnect: { profile in serverSheet = .existing(profile) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: Tokens.sidebarWidth, max: 340)
        } detail: {
            VStack(spacing: 0) {
                // 标签栏：始终显示（关到最后一个标签页时也不会消失），
                // 只占内容区，不压到左侧栏上方。
                TabBarView(app: app)
                PaneContainer(app: app)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 复制 / 移动进度：浮在工作区右下角，不挡内容也不进布局
                    .overlay(alignment: .bottomTrailing) {
                        if let task = operations.activeTask {
                            TransferHUD(task: task)
                                .padding(.trailing, 14)
                                .padding(.bottom, 14)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.16), value: operations.activeTask?.id)
                if app.showStatusBar {
                    Divider()
                    StatusBarView(model: app.focused)
                }
            }
        }
        // balanced：窗口变窄时优先压缩内容区，而不是把侧边栏整个收起来
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    app.newTab()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help(L10n.tr("新建标签页（⌘T）"))
            }
            ToolbarItem(placement: .principal) {
                Picker(L10n.tr("视图模式"), selection: $app.viewMode) {
                    ForEach(ViewMode.allCases) { m in
                        Label(m.title, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .help(L10n.tr("视图模式"))
            }
            ToolbarItem(placement: .secondaryAction) {
                Menu(L10n.tr("操作")) {
                    // 和菜单栏、右键菜单同一份命令表，图标与置灰自动一致
                    CommandList(app: app, ids: [
                        "newFolder", "newDocument", "-",
                        "rename", "quickLook", "-",
                        "copyPath", "terminal", "reveal", "-",
                        "compress", "extract", "extractToFolder", "hash", "-",
                        "bookmarkCurrentFolder"
                    ])
                    Divider()
                    Menu(L10n.tr("排序方式")) { SortMenuContents(app: app) }
                }
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker(L10n.tr("切分模式"), selection: $app.paneLayout) {
                        ForEach(PaneLayout.allCases) { l in
                            Label(l.title, systemImage: l.symbol).tag(l)
                        }
                    }
                    Divider()
                    Toggle(L10n.tr("路径栏"), isOn: $app.showPathBar)
                    Toggle(L10n.tr("状态栏"), isOn: $app.showStatusBar)
                    Toggle(L10n.tr("显示隐藏文件"), isOn: $app.showHidden)
                    Divider()
                    Button(L10n.tr("视图选项…")) { app.showViewOptions = true }
                        .keyboardShortcut("j", modifiers: .command)
                    Divider()
                    Button(L10n.tr("连接服务器…")) { serverSheet = .new }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help(L10n.tr("显示与切分"))
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    ForEach(AppearanceChoice.allCases) { a in
                        Button {
                            app.appearance = a
                        } label: {
                            if app.appearance == a {
                                Image(systemName: "checkmark")
                            }
                            Text(a.title)
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .help(L10n.tr("外观"))
            }
        }
        .background(WindowConfigurator(app: app))
        // 拖出成窗需要 openWindow：只能从视图环境里取，转交给 AppState
        .task {
            app.openDetachedWindow = { token in
                openWindow(id: WorkspaceWindow.sceneID, value: token)
            }
        }
        .sheet(item: $serverSheet) { target in
            ServerConnectView(target: target)
                .environment(app)
        }
        .sheet(isPresented: $app.showViewOptions) {
            ViewOptionsView(url: app.focused.url, mode: app.viewMode)
        }
        .sheet(item: $actions.hashReport) { report in
            HashReportView(report: report)
        }
        .alert(L10n.tr("部分文件未能处理"), isPresented: Binding(
            get: { operations.lastError != nil },
            set: { if !$0 { operations.lastError = nil } }
        )) {
            if operations.lastErrorNeedsFullDiskAccess {
                Button(L10n.tr("打开隐私设置…")) {
                    operations.lastError = nil
                    operations.lastErrorNeedsFullDiskAccess = false
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button(L10n.tr("好")) {
                operations.lastError = nil
                operations.lastErrorNeedsFullDiskAccess = false
            }
        } message: {
            Text(operations.lastError ?? "")
        }
        .alert(L10n.tr("操作未完成"), isPresented: Binding(
            get: { actions.lastError != nil },
            set: { if !$0 { actions.lastError = nil } }
        )) {
            Button(L10n.tr("好")) { actions.lastError = nil }
        } message: {
            Text(actions.lastError ?? "")
        }
        .alert(L10n.tr("要永久删除吗？"), isPresented: Binding(
            get: { !app.pendingDelete.isEmpty },
            set: { if !$0 { app.pendingDelete = [] } }
        )) {
            Button(L10n.tr("删除"), role: .destructive) {
                // 先把目标取出来再交给异步任务：关弹窗会触发 binding 的
                // set(false)，那时 pendingDelete 已被清空。
                let urls = app.pendingDelete
                app.pendingDelete = []
                Task { await app.performPermanentDelete(urls) }
            }
            Button(L10n.tr("取消"), role: .cancel) { app.pendingDelete = [] }
        } message: {
            Text(deleteMessage)
        }
    }

    /// 二次确认的说明文字：最多列出 3 个名称
    private var deleteMessage: String {
        let names = app.pendingDelete.prefix(3).map(\.lastPathComponent)
        let suffix = app.pendingDelete.count > 3 ? L10n.tr(" 等") : ""
        return L10n.tr("「%@%@」共 %@ 项将被直接删除，此操作无法撤销。", names.joined(separator: "、"), suffix, app.pendingDelete.count)
    }
}

import SwiftUI

@main
struct PaneApp: App {
    init() {
        // 命令行基准测试模式：`Pane --bench <dir>`，跑完即退出
        Benchmark.runIfRequested()
        // 命令行自检：`Pane --self-check` / `--dump-menus`
        SelfCheck.runIfRequested()

        // 系统菜单由 SwiftUI 在启动后异步装上，多补几次确保 ⌘W 归位
        for delay in [0.4, 1.2, 2.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MenuTuning.apply()
            }
        }
    }

    var body: some Scene {
        // 每个窗口一个独立的 AppState：标签页、分栏都在窗口内自洽
        WindowGroup(id: WorkspaceWindow.sceneID, for: UUID.self) { token in
            WorkspaceRoot(token: token.wrappedValue)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        // 标签页与窗口位置由我们自己持久化，关掉系统的窗口恢复避免重复开窗
        .restorationBehavior(.disabled)
        .commands { PaneCommands() }

        Settings {
            SettingsScene()
        }
    }
}

/// 一个窗口的根视图：持有本窗口的 AppState
struct WorkspaceRoot: View {
    @State private var app: AppState

    init(token: UUID?) {
        _app = State(initialValue: AppState(detached: DetachedWorkspaces.take(token)))
    }

    var body: some View {
        ContentView()
            .environment(app)
            .accentColor(PanePalette.selection)
            .frame(minWidth: 760, minHeight: 480)
            // 菜单命令通过焦点值拿到「当前窗口」的状态
            .focusedSceneValue(\.workspace, app)
    }
}

/// 设置窗口：始终操作主窗口的状态
struct SettingsScene: View {
    var body: some View {
        if let app = WorkspaceRegistry.primary {
            SettingsView().environment(app)
        } else {
            ProgressView()
                .frame(width: 420, height: 280)
        }
    }
}

import Foundation
import AppKit

// MARK: - 命令实现（菜单表里那些 run 闭包落到这里）
//
// AppState 本体只保留状态与底层动作；命令语义（「打开」「刷新」「去某个位置」）
// 集中在这个扩展里，方便命令表引用，也方便以后加新的入口。

extension AppState {
    /// ⌘O / 右键「打开」：单个项按双击语义处理；多选时打开所有文件，文件夹进入第一个
    func openSelection() {
        let items = focused.selectedItems()
        guard !items.isEmpty else { return }
        if items.count == 1 {
            focused.enter(items[0])
            return
        }
        let directories = items.filter { $0.isDirectory && !$0.isPackage }
        let others = items.filter { !($0.isDirectory && !$0.isPackage) }
        for file in others {
            NSWorkspace.shared.open(file.url)
        }
        if let first = directories.first {
            focused.enter(first)
        }
    }

    /// ⌘R / 右键「刷新」：重新读当前目录；在服务器共享列表上则重新枚举共享
    func refresh() {
        focused.reload()
    }

    /// 前往系统目录（主目录 / 桌面 / 文稿 / 下载）
    func go(to directory: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            return
        }
        focused.navigate(to: url)
    }
}

import AppKit

/// 命令行自检：`Pane --self-check`
///
/// 没有辅助功能权限时没法脚本化点菜单，这里退一步，检查「能静态验证的部分」：
/// 快捷键是否重复、每条命令的元数据是否完整、以及菜单栏最终长什么样。
/// 跑完即退出，不影响正常启动。
@MainActor
enum SelfCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--smb-probe") {
            runSMBProbe(Array(args[(index + 1)...]))
            return
        }
        let wantsCheck = args.contains("--self-check")
        let wantsMenus = args.contains("--dump-menus")
        let wantsCommands = args.contains("--dump-commands")
        guard wantsCheck || wantsMenus || wantsCommands else { return }

        if wantsCheck {
            checkCommands()
            checkSort()
        }
        if wantsCommands {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { dumpEnablement() }
        }
        if wantsMenus {
            // 菜单在启动之后才由 SwiftUI 装到 NSApp 上，等一拍再打印
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                emit("mainMenu=\(NSApp.mainMenu?.items.count ?? -1)")
                dumpMenu(NSApp.mainMenu, depth: 0)
                exit(0)
            }
        } else if !wantsCommands {
            exit(0)
        }
    }

    // MARK: SMB 诊断

    /// `Pane --smb-probe <地址> [账号] [密码]`
    /// 把「端口 / 认证 / 枚举 / 挂载」四步逐个跑一遍，说清到底卡在哪。
    private static func runSMBProbe(_ rest: [String]) {
        guard let address = rest.first else {
            emit("用法：Pane --smb-probe <地址或 smb://host/share> [账号] [密码]")
            exit(2)
        }
        let user = rest.count > 1 ? rest[1] : ""
        let password = rest.count > 2 ? rest[2] : ""

        guard let parsed = SMBMounter.parse(address) else {
            emit("地址无法解析：\(address)")
            exit(2)
        }
        emit("地址：\(address) → host=\(parsed.host) share=\(parsed.share.isEmpty ? "<未指定>" : parsed.share)")
        emit("445 端口：\(SMBMounter.probe(host: parsed.host, port: 445, timeout: 2) ? "通" : "不通")")
        emit("139 端口：\(SMBMounter.probe(host: parsed.host, port: 139, timeout: 2) ? "通" : "不通")")

        if parsed.share.isEmpty {
            let start = Date()
            let discovery = SMBMounter.discoverShares(host: parsed.host, user: user, password: password)
            let cost = String(format: "%.1f", Date().timeIntervalSince(start))
            emit("枚举共享：\(cost)s 结果=\(discovery.shares.isEmpty ? "空" : discovery.shares.joined(separator: ", "))")
            if let failure = discovery.failure { emit("失败原因：\(failure)（code \(discovery.code)）") }
        }

        let start = Date()
        do {
            let mounts = try SMBMounter.mountAll(address: address, user: user, password: password)
            emit("挂载成功（\(String(format: "%.1f", Date().timeIntervalSince(start)))s）：")
            mounts.forEach { emit("  \($0.path)") }
        } catch {
            emit("挂载失败（\(String(format: "%.1f", Date().timeIntervalSince(start)))s）：\(error.localizedDescription)")
        }
        emit("详细日志：/tmp/pane-smb.log")
        exit(0)
    }

    /// 打印当前窗口下每条命令是否可用（菜单的置灰逻辑就是这个）
    private static func dumpEnablement() {
        guard let app = WorkspaceRegistry.primary else {
            emit("没有工作区")
            exit(1)
        }
        let context = CommandContext.build(app)
        emit("选中 \(context.selectionCount) 项｜可粘贴 \(context.canPaste)｜布局 \(context.layout.rawValue)｜标签 \(context.tabCount)｜视图 \(context.viewMode.rawValue)")
        for command in CommandCatalog.all where !command.isEnabled(context) {
            emit("不可用: \(command.id)")
        }
        let enabled = CommandCatalog.all.filter { $0.isEnabled(context) }.count
        emit("可用 \(enabled)/\(CommandCatalog.all.count)")
        exit(0)
    }

    // MARK: 命令表自检

    private static func checkCommands() {
        var failures: [String] = []
        var seen: [String: String] = [:]

        for command in CommandCatalog.all {
            if command.id.isEmpty || command.title.isEmpty {
                failures.append("命令缺少 id / 标题：\(command)")
            }
            guard let shortcut = command.shortcut else { continue }
            let key = "\(shortcut.display)"
            if let other = seen[key] {
                failures.append("快捷键冲突：\(key) 同时分给 \(other) 与 \(command.id)")
            }
            seen[key] = command.id
        }

        print("命令总数：\(CommandCatalog.all.count)，带快捷键：\(seen.count)")
        for section in CommandSection.allCases {
            let list = CommandCatalog.inGroup(section)
            print("  [\(section.rawValue)] \(list.count) 条：" + list.map(\.id).joined(separator: ", "))
        }
        if failures.isEmpty {
            print("自检通过：没有重复快捷键，元数据完整")
        } else {
            print("自检发现问题：")
            failures.forEach { print("  ✗ \($0)") }
        }
    }

    // MARK: 排序自检

    /// 排序规则跑一遍合成数据：文件夹永远在前，四个字段的两方向都要对得上
    private static func checkSort() {
        let base = Date(timeIntervalSince1970: 0)
        let later = Date(timeIntervalSince1970: 86_400)
        func item(_ name: String, _ kind: FileKind, size: Int64?, date: Date?, dir: Bool = false) -> FileItem {
            FileItem(url: URL(fileURLWithPath: "/" + name), name: name, kind: kind,
                     isDirectory: dir, isPackage: false, isHidden: false,
                     size: size, modificationDate: date)
        }
        let items = [
            item("zebra.txt", .document, size: 30, date: later),
            item("Bravo", .folder, size: nil, date: nil, dir: true),
            item("apple.png", .image, size: nil, date: base),
            item("Alpha", .folder, size: nil, date: nil, dir: true),
            item("mango.pdf", .pdf, size: 10, date: nil)
        ]
        func order(_ sort: FileSort) -> [String] { sort.applied(to: items).map(\.name) }

        let expectations: [(FileSort, [String], String)] = [
            (FileSort(field: .name, ascending: true),
             ["Alpha", "Bravo", "apple.png", "mango.pdf", "zebra.txt"], "名称升序"),
            (FileSort(field: .name, ascending: false),
             // 降序连文件夹组内部也一起反（访达同样如此），文件夹仍整体在最前
             ["Bravo", "Alpha", "zebra.txt", "mango.pdf", "apple.png"], "名称降序"),
            (FileSort(field: .size, ascending: true),
             ["Alpha", "Bravo", "apple.png", "mango.pdf", "zebra.txt"], "大小升序（缺值当最小）"),
            (FileSort(field: .size, ascending: false),
             ["Alpha", "Bravo", "zebra.txt", "mango.pdf", "apple.png"], "大小降序"),
            (FileSort(field: .date, ascending: true),
             ["Alpha", "Bravo", "mango.pdf", "apple.png", "zebra.txt"], "日期升序（缺值当最早）"),
            (FileSort(field: .date, ascending: false),
             ["Alpha", "Bravo", "zebra.txt", "apple.png", "mango.pdf"], "日期降序")
        ]

        var failures: [String] = []
        for (sort, expected, label) in expectations {
            let got = order(sort)
            if got != expected {
                failures.append("\(label)：期望 \(expected.joined(separator: ", "))，实际 \(got.joined(separator: ", "))")
            }
        }

        // 种类相同（或大小/日期并列）时退回按名称排，降序也一样不会乱序
        let sameKind = [
            item("b.txt", .document, size: 1, date: nil),
            item("a.txt", .document, size: 1, date: nil),
            item("c.txt", .document, size: 1, date: nil)
        ]
        let kindAsc = FileSort(field: .kind, ascending: true).applied(to: sameKind).map(\.name)
        let kindDesc = FileSort(field: .kind, ascending: false).applied(to: sameKind).map(\.name)
        if kindAsc != ["a.txt", "b.txt", "c.txt"] {
            failures.append("种类相同时退回名称排序失败：\(kindAsc.joined(separator: ", "))")
        }
        if kindDesc != ["a.txt", "b.txt", "c.txt"] {
            failures.append("种类并列降序应保持名称升序：\(kindDesc.joined(separator: ", "))")
        }

        if failures.isEmpty {
            print("排序自检通过：名称/大小/日期两个方向，种类并列退回名称，文件夹始终在前")
        } else {
            print("排序自检发现问题：")
            failures.forEach { print("  ✗ \($0)") }
        }
    }

    /// 直接用 stderr 输出：从终端启动时 stdout 会被缓冲，exit 前可能丢掉
    private static func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: 菜单结构

    private static func dumpMenu(_ menu: NSMenu?, depth: Int) {
        guard let menu else { return }
        menu.update()
        let indent = String(repeating: "  ", count: depth)
        if depth == 0 {
            emit("菜单栏：")
        } else {
            emit("\(indent)[\(menu.title)]")
        }
        for item in menu.items {
            if item.isSeparatorItem {
                emit("\(indent)  ---")
                continue
            }
            var line = "\(indent)  \(item.title)"
            if !item.keyEquivalent.isEmpty {
                line += "    ⌨ " + modifierText(item.keyEquivalentModifierMask) + item.keyEquivalent.uppercased()
            }
            if !item.isEnabled { line += "   (置灰)" }
            if let action = item.action { line += "   ^\(NSStringFromSelector(action))" }
            emit(line)
            if let submenu = item.submenu {
                dumpMenu(submenu, depth: depth + 1)
            }
        }
    }

    private static func modifierText(_ mask: NSEvent.ModifierFlags) -> String {
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text
    }
}

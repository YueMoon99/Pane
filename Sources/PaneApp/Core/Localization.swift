import Foundation
import SwiftUI

// MARK: - 语言选择
//
// rawValue 用稳定英文键持久化，显示标题走 L10n.tr，
// 这样切换语言时选项本身也会跟着变。

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese, english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .chinese: L10n.tr("中文")
        case .english: L10n.tr("英文")
        }
    }
}

/// 语言状态。swiftui 视图在 body 里调用 `L10n.tr` 时会读取 `isEnglish`，
/// 从而自动建立观察关系：设置里一改语言，所有界面立即重绘。
@Observable
final class LocalizationStore {
    // 读写都在主线程（SwiftUI body / 设置面板）；标记为 unsafe 只为满足 Swift 6
    // 对全局可变状态的静态检查，实际不存在跨线程竞争。
    nonisolated(unsafe) static let shared = LocalizationStore()

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "language") ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
    }

    /// 「跟随系统」按用户首选语言列表判定；中文（简/繁）都走中文文案。
    var isEnglish: Bool {
        switch language {
        case .english: return true
        case .chinese: return false
        case .system:
            return Locale.preferredLanguages.first.map { lang in
                let lower = lang.lowercased()
                return lower.hasPrefix("en") && !lower.hasPrefix("en.zh")
            } ?? false
        }
    }
}

// MARK: - 文案查找

enum L10n {
    /// 取一条文案。`key` 是源码里的中文原文，插值统一写成 `%@`。
    /// 中文（含跟随系统为中文）直接返回原文；英文查表，查不到时退回原文。
    static func tr(_ key: String, _ args: Any...) -> String {
        let resolved = LocalizationStore.shared.isEnglish ? (english[key] ?? key) : key
        guard !args.isEmpty else { return resolved }
        // 自己替换 %@，不用 String(format:)：调用处的插值有 Int / Double / String
        // 多种类型，%@ 遇到非对象类型会在运行时崩溃。
        var result = ""
        var cursor = resolved.startIndex
        var index = 0
        while let range = resolved.range(of: "%@", range: cursor..<resolved.endIndex) {
            result += resolved[cursor..<range.lowerBound]
            if index < args.count {
                result += String(describing: args[index])
                index += 1
            }
            cursor = range.upperBound
        }
        result += resolved[cursor...]
        return result
    }

    /// 中文原文 → 英文。插值占位符与调用处一一对应。
    static let english: [String: String] = [
        "\n\n受系统保护的文件夹（桌面、文稿、下载等）需要在\n": "\n\nProtected folders (Desktop, Documents, Downloads, etc.) require Pane to be allowed in\n",
        " 副本": " copy",
        " 副本 %@": " copy %@",
        " 等": ", etc.",
        "%@ / %@ 项%@": "%@ / %@ items%@",
        "%@ × %@ 像素": "%@ × %@ px",
        "%@ 个项目": "%@ items",
        "%@ 拒绝了匿名（访客）访问，请填写「账号」和「密码」": "%@ rejected guest access. Enter a username and password.",
        "%@ 拒绝了本次登录，请确认账号有访问共享「%@」的权限": "%@ rejected this login. Check that the account can access share \"%@\".",
        "%@ 拒绝了登录：账号或密码不正确。请确认大小写；若 NAS 要求域，账号写成 DOMAIN\\user；也可能该账号没有 SMB 权限": "%@ rejected the login: wrong username or password. Check capitalization; if the NAS requires a domain, use DOMAIN\\user; the account may also lack SMB access.",
        "%@ 拒绝了连接：账号、密码或访问权限不对": "%@ rejected the connection: wrong account, password, or permissions.",
        "%@ 校验值": "%@ checksum",
        "%@ 没有响应共享列表请求（可能禁止浏览共享）": "%@ did not respond to the share list request (share browsing may be disabled).",
        "%@ 没有返回共享列表（这类服务器通常禁止浏览共享）。": "%@ did not return a share list (this kind of server usually disables share browsing).",
        "%@ 没有返回可挂载的共享": "%@ returned no mountable shares.",
        "%@ 页": "%@ pages",
        "%@ 项": "%@ items",
        "%@视图选项": "%@ View Options",
        "%@（文件夹不支持）": "%@ (folders not supported)",
        "%@：不能移动到自身的子目录": "%@: cannot move a folder into its own subdirectory",
        "192.168.1.10 或 smb://nas.local": "192.168.1.10 or smb://nas.local",
        "NetFS 挂载 smb://%@/%@ 失败 code=%@": "NetFS mount smb://%@/%@ failed (code=%@)",
        "NetFS 挂载 smb://%@/%@ 成功": "NetFS mounted smb://%@/%@",
        "PDF 文稿": "PDF Document",
        "Pane 项目": "Pane Project",
        "SMB 等网络卷上生成缩略图要把文件读一遍，第一次进目录会明显变慢。": "Generating thumbnails on network volumes such as SMB requires reading each file, so the first visit to a folder will be noticeably slower.",
        "mountAll address=%@ host=%@ share=%@ user=%@ pwd=%@": "mountAll address=%@ host=%@ share=%@ user=%@ pwd=%@",
        "smbutil view %@ 输出 %@ 字节：%@": "smbutil view %@ returned %@ bytes: %@",
        "「%@%@」共 %@ 项将被直接删除，此操作无法撤销。": "\"%@%@\" — %@ items will be deleted permanently. This cannot be undone.",
        "「直接进入共享」只在服务器禁止浏览共享列表时才需要填。": "Only fill in \"Connect directly to share\" when the server disables browsing the share list.",
        "「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许 Pane。": "System Settings → Privacy & Security → Full Disk Access.",
        "上一层": "Up",
        "下载": "Downloads",
        "中文": "Chinese",
        "中止%@": "Cancel %@",
        "主目录": "Home",
        "主题": "Theme",
        "也可以在列之间的分隔线上拖动；最多同时显示 4 列，←/→ 切换层级。": "You can also drag the dividers between columns. Up to 4 columns are shown at once; use ←/→ to change level.",
        "书签": "Bookmarks",
        "从书签移除": "Remove from Bookmarks",
        "从列表移除": "Remove from List",
        "位置": "Locations",
        "侧边栏显示的名字，例如 家里 NAS": "Name shown in the sidebar, e.g. Home NAS",
        "信息区显示修改日期": "Show modification date in info area",
        "修改日期": "Date Modified",
        "全部恢复默认": "Reset All to Defaults",
        "共享": "Share",
        "共享「%@」无法挂载，请确认它存在": "Cannot mount share \"%@\". Check that it exists.",
        "共享（已挂载）": "Shares (Mounted)",
        "关闭其他标签页": "Close Other Tabs",
        "关闭标签页": "Close Tab",
        "分栏": "Columns",
        "切分": "Split",
        "切分模式": "Layout",
        "列宽": "Column Width",
        "列宽在表头分隔线上拖动调整；列的显示与隐藏在表头右侧菜单里。": "Drag the header dividers to resize columns; use the menu at the right of the header to show or hide columns.",
        "列表": "List",
        "删除": "Delete",
        "删除此文件夹的单独设置，改为继承上级文件夹": "Remove this folder's custom settings and inherit from its parent.",
        "刷新（⌘R）": "Refresh (⌘R)",
        "前往": "Go",
        "前进": "Forward",
        "升序": "Ascending",
        "单栏": "Single Pane",
        "压缩失败：%@": "Compression failed: %@",
        "取消": "Cancel",
        "只对图片、视频和 PDF 生成；图片与 PDF 限 64MB 以内，视频只取首帧，不受体积限制。": "Only images, videos, and PDFs are generated. Images and PDFs are limited to 64 MB; for videos only the first frame is used, regardless of size.",
        "可用 ": "Available ",
        "可留空；留空则先列出全部共享，双击哪个进哪个": "Optional. Leave blank to list all shares first, then double-click the one you want.",
        "右侧": "Right",
        "右键任意文件夹 → 添加到书签": "Right-click any folder → Add to Bookmarks",
        "名称": "Name",
        "名称里不能包含“/”或“:”": "Names cannot contain \"/\" or \":\"",
        "后退": "Back",
        "和访达里「连接服务器」时选的那个一致": "Same as the one you pick in Finder's Connect to Server.",
        "图像": "Image",
        "图标": "Icons",
        "图标大小": "Icon Size",
        "图片": "Pictures",
        "在终端打开": "Open in Terminal",
        "在网络宗卷上显示缩略图": "Show thumbnails on network volumes",
        "在访达中显示": "Reveal in Finder",
        "地址": "Address",
        "地址格式无效，请检查服务器 IP": "Invalid address. Check the server IP.",
        "地址格式无效，请检查服务器 IP 或主机名": "Invalid address. Check the server IP or host name.",
        "备注": "Label",
        "复制": "Copy",
        "复制标签页": "Duplicate Tab",
        "复制路径": "Copy Path",
        "外观": "Appearance",
        "大小": "Size",
        "好": "OK",
        "完成": "Done",
        "密码": "Password",
        "工作区": "Workspace",
        "已填写账号但密码为空，%@ 不允许空密码登录，请补全密码": "A username was entered without a password. %@ does not allow empty passwords; please enter one.",
        "已拷贝": "Copied",
        "已挂载：%@": "Mounted: %@",
        "已选 %@ 个": "%@ selected",
        "应用程序": "Applications",
        "底部": "Bottom",
        "弹出（断开）": "Eject (Disconnect)",
        "归档": "Archive",
        "影片": "Movies",
        "恢复默认列宽": "Restore Default Column Widths",
        "打开": "Open",
        "打开共享列表": "Open Share List",
        "打开隐私设置…": "Open Privacy Settings…",
        "找不到主机 %@，请检查地址是否写对": "Host %@ not found. Check the address.",
        "把当前设置作为所有未单独设置文件夹的默认值": "Use current settings as the default for all folders without custom settings",
        "拖动调整比例，双击均分": "Drag to resize; double-click to split evenly",
        "拷贝全部": "Copy All",
        "拷贝路径": "Copy Path",
        "挂载失败（错误码 %@）": "Mount failed (error code %@)",
        "挂载成功但未获取到挂载路径": "Mounted but no mount path was returned",
        "排序字段": "Sort By",
        "排序方式": "Sort",
        "操作": "Action",
        "操作未完成": "Operation Incomplete",
        "文件夹": "Folder",
        "文件夹是空的": "This folder is empty",
        "文稿": "Documents",
        "断开并弹出「%@」": "Disconnect and eject \"%@\"",
        "断开连接": "Disconnect",
        "新建文件失败：%@": "Failed to create file: %@",
        "新建文件夹失败：%@": "Failed to create folder: %@",
        "新建标签页": "New Tab",
        "新建标签页（⌘T）": "New Tab (⌘T)",
        "无法打开终端：%@": "Cannot open Terminal: %@",
        "无法运行 smbutil，系统可能阻止了子进程": "Cannot run smbutil; the system may have blocked the subprocess",
        "时长": "Duration",
        "显示/隐藏列": "Show/Hide Columns",
        "显示与切分": "Display & Split",
        "显示状态栏": "Show Status Bar",
        "显示缩略图预览": "Show thumbnail previews",
        "显示路径栏": "Show Path Bar",
        "显示隐藏文件": "Show Hidden Files",
        "服务器": "Servers",
        "服务器 %@ 已不在侧边栏列表里": "Server %@ is no longer in the sidebar",
        "服务器上找不到共享「%@」": "Share \"%@\" was not found on the server",
        "服务器地址无效": "Invalid server address",
        "未命名": "Untitled",
        "未命名文件夹": "Untitled Folder",
        "未能从 %@ 获取共享列表": "Could not get the share list from %@",
        "未能从 %@ 获取共享列表：%@": "Could not get the share list from %@: %@",
        "未能计算": "Unavailable",
        "标签": "Tags",
        "标签位置": "Label Position",
        "标签字号": "Label Font Size",
        "标签筛选将在 M7 接入": "Tag filtering will arrive in M7",
        "标签页": "Tabs",
        "桌面": "Desktop",
        "横向切分": "Split Horizontally",
        "橙色": "Orange",
        "正在%@ %@ 个项目": "%@ %@ items",
        "正在中止…": "Cancelling…",
        "正在统计…": "Counting…",
        "正在读取…": "Loading…",
        "正在读取共享列表…": "Loading share list…",
        "正在连接…": "Connecting…",
        "没有任何共享挂载成功": "No shares were mounted",
        "浅色": "Light",
        "深色": "Dark",
        "添加 SMB 服务器": "Add SMB Server",
        "源代码": "Source Code",
        "灰色": "Gray",
        "点击连接 %@": "Click to connect to %@",
        "状态栏": "Status Bar",
        "生成过一次之后会进本地缓存，再进同一目录就是秒开。": "Once generated, thumbnails are cached locally, so revisiting the folder is instant.",
        "用作默认": "Use as Default",
        "画廊": "Gallery",
        "留空则用访客身份；需要域时写 DOMAIN\\user": "Leave blank to connect as guest; use DOMAIN\\user if a domain is required",
        "直接进入共享": "Connect directly to share",
        "磁盘": "Disk",
        "种类": "Kind",
        "移到新窗口": "Move to New Window",
        "移动": "Move",
        "窗口": "Window",
        "系统 NetFS 不可用": "System NetFS unavailable",
        "紫色": "Purple",
        "红色": "Red",
        "纵向切分": "Split Vertically",
        "绿色": "Green",
        "编辑地址": "Edit Path",
        "缩略图": "Thumbnails",
        "网格间距": "Grid Spacing",
        "英文": "English",
        "语言": "Language",
        "Pane 设置": "Pane Settings",
        "蓝色": "Blue",
        "要永久删除吗？": "Delete permanently?",
        "视图模式": "View",
        "视图选项…": "View Options…",
        "视频": "Video",
        "解压失败：%@": "Extraction failed: %@",
        "记住密码（保存到钥匙串，下次点一下就直接进）": "Remember password (saved to Keychain for one-click access next time)",
        "请先进入一个文件夹再压缩": "Open a folder before compressing",
        "请先选择 zip、tar 等可以就地解压的压缩文件": "Select a zip, tar, or other supported archive to extract in place",
        "请先选择要压缩的项目": "Select items to compress first",
        "请先选择要计算哈希的项目": "Select items to compute hashes for first",
        "请在「共享名」里直接填写要进入的目录名，例如 Home、homes、Public，": "Enter the folder name directly in Share Name, e.g. Home, homes, Public,",
        "请输入服务器地址": "Enter a server address",
        "账号": "Username",
        "账号或密码不正确，请重新输入": "Incorrect username or password. Try again.",
        "账号没有访问「%@」的权限": "The account does not have access to \"%@\"",
        "跟随上级": "Inherit from Parent",
        "跟随系统": "Follow System",
        "路径栏": "Path Bar",
        "输入路径，回车前往": "Enter a path and press Return",
        "还没有保存「%@」的密码。右键这台服务器选「重新连接…」，输入一次密码就好": "No saved password for \"%@\". Right-click the server, choose Reconnect…, and enter it once.",
        "这台服务器没有列出可访问的共享": "This server did not list any accessible shares",
        "连不上 %@，请检查网络或服务器是否在线": "Cannot reach %@. Check the network or whether the server is online.",
        "连不上 %@：SMB 端口没有响应，请检查网络或服务器是否开机": "Cannot reach %@: the SMB port is not responding. Check the network or whether the server is powered on.",
        "连接": "Connect",
        "连接 %@ 失败，请检查网络或服务器是否在线": "Failed to connect to %@. Check the network or whether the server is online.",
        "连接 SMB 服务器": "Connect to SMB Server",
        "连接失败": "Connection Failed",
        "连接成功后，工作区会像文件夹一样列出这台服务器上的所有共享，双击才挂载。": "After connecting, the pane lists all shares on this server like a folder. Double-click one to mount it.",
        "连接服务器…": "Connect to Server…",
        "部分文件未能处理": "Some Files Could Not Be Processed",
        "重命名失败：%@": "Rename failed: %@",
        "重新连接…": "Reconnect…",
        "重试": "Try Again",
        "音乐": "Music",
        "音频": "Audio",
        "预览大小": "Preview Size",
        "黄色": "Yellow",
    ]
}

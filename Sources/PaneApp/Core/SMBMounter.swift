import Foundation
import Darwin

/// NetFS / SMB 挂载失败原因。
///
/// `NetFSMountURLSync` 的返回值就是 POSIX errno（部分情况返回 NetFS 自己的负数错误码）：
///   -6003  没给共享名 / 系统选择窗口被关闭
///   2      共享不存在 / 路径错误
///   5      EIO：会话建立被服务器拒绝（典型是没带有效凭据走了访客，而服务器禁用了匿名）
///   13     没有权限
///   22     地址参数无效
///   60     连接超时
///   65     服务器不可达
///   80     EAUTH：用户名或密码不正确
enum SMBMountError: LocalizedError {
    case invalidAddress
    case frameworkUnavailable
    case failed(code: Int32, detail: String)
    case noMountPoint

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return L10n.tr("服务器地址无效")
        case .frameworkUnavailable:
            return L10n.tr("系统 NetFS 不可用")
        case .noMountPoint:
            return L10n.tr("挂载成功但未获取到挂载路径")
        case .failed(let code, let detail):
            // detail 已经是给人看的一句话，不再拼上原始错误码，免得干扰阅读
            return detail.isEmpty ? L10n.tr("挂载失败（错误码 %@）", code) : detail
        }
    }
}

/// 通过系统 NetFS 挂载 SMB 共享（不使用明文命令行密码）
enum SMBMounter {
    private typealias MountFn = @convention(c) (
        CFURL?, CFURL?, CFString?, CFString?,
        CFMutableDictionary?, CFMutableDictionary?,
        UnsafeMutablePointer<CFArray?>?
    ) -> Int32

    @_silgen_name("forkpty")
    private static func forkpty(
        _ amaster: UnsafeMutablePointer<Int32>?,
        _ name: UnsafeMutablePointer<CChar>?,
        _ termp: UnsafeMutablePointer<termios>?,
        _ winp: UnsafeMutablePointer<winsize>?
    ) -> pid_t

    /// 解析 "host" / "smb://host" / "smb://host/share" / "//host/share"
    static func parse(_ address: String) -> (host: String, share: String)? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "smb://" + text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let comps = URLComponents(string: text),
              let host = comps.host, !host.isEmpty else { return nil }
        return (host, normalizeShare(comps.path))
    }

    /// 共享名规整：去掉首尾斜杠，只取第一段。
    /// `smb://host/Share/Sub` 这种写法 NetFS 也只认最外层共享，多出来的段会被拒。
    static func normalizeShare(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let first = trimmed.split(separator: "/").first else { return "" }
        return String(first)
    }

    // MARK: - 对外入口

    /// 连接服务器：知道共享名就直接挂载；不知道才去枚举。
    ///
    /// 这一点很关键——很多服务器（群晖的部分共享、Windows 域内的机器）
    /// 允许按名字直接访问共享，却**不允许浏览共享列表**，
    /// 此时 `smbutil view` 会一直卡到超时才返回空。
    /// 访达能连是因为它压根不枚举，直接挂 `smb://host/共享名`。
    /// 所以只要用户给了共享名，就一步到位，不再走枚举。
    static func mountAll(address: String, user: String, password: String) throws -> [URL] {
        guard let (host, share) = parse(address) else { throw SMBMountError.invalidAddress }
        log(L10n.tr("mountAll address=%@ host=%@ share=%@ user=%@ pwd=%@", address, host, share.isEmpty ? "<空>" : share, user.isEmpty ? "<访客>" : user, password.isEmpty ? "空" : "\(password.count) 位"))

        if !share.isEmpty {
            return [try mountShare(host: host, share: share, user: user, password: password)]
        }

        let discovery = discoverShares(host: host, user: user, password: password)
        guard !discovery.shares.isEmpty else {
            // 枚举失败时给出能立刻照做的下一步，而不是一个「超时」
            if discovery.code == 60 || discovery.code == -6003 {
                throw SMBMountError.failed(
                    code: discovery.code,
                    detail: L10n.tr("%@ 没有返回共享列表（这类服务器通常禁止浏览共享）。", host)
                        + L10n.tr("请在「共享名」里直接填写要进入的目录名，例如 Home、homes、Public，")
                        + L10n.tr("和访达里「连接服务器」时选的那个一致")
                )
            }
            // 其他原因（密码错 / 网络不通）原样透传
            throw SMBMountError.failed(
                code: discovery.code,
                detail: discovery.failure ?? L10n.tr("未能从 %@ 获取共享列表", host)
            )
        }

        var mounted: [URL] = []
        var lastError: SMBMountError?
        for share in discovery.shares {
            do {
                mounted.append(try mountShare(host: host, share: share, user: user, password: password))
            } catch let error as SMBMountError {
                lastError = error
            } catch {
                lastError = .failed(code: -1, detail: error.localizedDescription)
            }
        }
        guard !mounted.isEmpty else {
            throw lastError ?? SMBMountError.failed(code: -1, detail: L10n.tr("没有任何共享挂载成功"))
        }
        return mounted
    }

    /// 已挂载则直接复用，避免重复挂载被服务器回 EIO
    static func existingMount(host: String, share: String) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: []
        ) ?? []

        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == false,
                  let remount = values.volumeURLForRemounting,
                  remount.host?.lowercased() == host.lowercased() else { continue }
            if share.isEmpty { return volume }
            let mountedShare = remount.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if mountedShare.caseInsensitiveCompare(share) == .orderedSame { return volume }
        }
        return nil
    }

    // MARK: - 挂载单个共享

    static func mountShare(host: String, share: String, user: String, password: String) throws -> URL {
        if let existing = existingMount(host: host, share: share) { return existing }

        guard let handle = dlopen("/System/Library/Frameworks/NetFS.framework/NetFS", RTLD_NOW),
              let sym = dlsym(handle, "NetFSMountURLSync") else {
            throw SMBMountError.frameworkUnavailable
        }
        defer { dlclose(handle) }
        let fn = unsafeBitCast(sym, to: MountFn.self)

        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        if !share.isEmpty { comps.path = "/" + share }
        guard let url = comps.url else { throw SMBMountError.invalidAddress }

        var result = attempt(fn, url: url, user: user, password: password, forceNewSession: false)

        // 服务器重启 / 旧会话凭据失效后，复用已有 SMB 会话会返回 EIO 或 EAUTH，
        // 强制新建会话再试一次通常就好了。
        if result.code == 5 || result.code == 80 {
            let retry = attempt(fn, url: url, user: user, password: password, forceNewSession: true)
            if retry.code == 0 || retry.code != result.code { result = retry }
        }

        guard result.code == 0 else {
            log(L10n.tr("NetFS 挂载 smb://%@/%@ 失败 code=%@", host, share, result.code))
            throw SMBMountError.failed(
                code: result.code,
                detail: describe(code: result.code, host: host, share: share, user: user, password: password)
            )
        }
        log(L10n.tr("NetFS 挂载 smb://%@/%@ 成功", host, share))

        if let arr = result.mountPoints as? [AnyObject] {
            for obj in arr {
                if let u = obj as? URL { return u }
                if let s = obj as? String { return URL(fileURLWithPath: s) }
            }
        }
        let candidates = ["/Volumes/\(share)", "/Volumes/\(host)-\(share)"]
        for path in candidates where !share.isEmpty {
            let guess = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: guess.path) { return guess }
        }
        throw SMBMountError.noMountPoint
    }

    private struct Attempt {
        let code: Int32
        let mountPoints: CFArray?
    }

    private static func attempt(
        _ fn: MountFn,
        url: URL,
        user: String,
        password: String,
        forceNewSession: Bool
    ) -> Attempt {
        // 静默挂载：失败只回传错误码，不弹系统认证窗口
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "NoUI"
        if forceNewSession { openOptions["ForceNewSession"] = "yes" }

        var mountPoints: CFArray?
        let rc = fn(
            (url as NSURL) as CFURL,
            nil,
            user.isEmpty ? nil : (user as CFString),
            password.isEmpty ? nil : (password as CFString),
            openOptions as CFMutableDictionary,
            nil,
            &mountPoints
        )
        return Attempt(code: rc, mountPoints: mountPoints)
    }

    private static func describe(
        code: Int32,
        host: String,
        share: String,
        user: String,
        password: String
    ) -> String {
        switch code {
        case 1:
            return L10n.tr("%@ 拒绝了连接：账号、密码或访问权限不对", host)
        case -6003, -6004:
            return share.isEmpty
                ? L10n.tr("%@ 没有返回可挂载的共享", host)
                : L10n.tr("共享「%@」无法挂载，请确认它存在", share)
        case 5:
            if user.isEmpty {
                return L10n.tr("%@ 拒绝了匿名（访客）访问，请填写「账号」和「密码」", host)
            }
            if password.isEmpty {
                return L10n.tr("已填写账号但密码为空，%@ 不允许空密码登录，请补全密码", host)
            }
            return L10n.tr("%@ 拒绝了本次登录，请确认账号有访问共享「%@」的权限", host, share)
        case 80, 86:
            return L10n.tr("账号或密码不正确，请重新输入")
        case 2:
            return L10n.tr("服务器上找不到共享「%@」", share)
        case 13:
            return L10n.tr("账号没有访问「%@」的权限", share)
        case 22:
            return L10n.tr("地址格式无效，请检查服务器 IP")
        case 60, 65, 51, 61:
            return L10n.tr("连接 %@ 失败，请检查网络或服务器是否在线", host)
        default:
            return ""
        }
    }

    // MARK: - 共享列表（smbutil + 伪终端，密码不进命令行）

    /// 枚举共享的结果：拿到列表就只填 shares；
    /// 没拿到时把 smbutil 的真实原因（认证失败 / 网络不通 …）翻译成一句人话
    struct ShareDiscovery {
        var shares: [String] = []
        var failure: String?
        var code: Int32 = -6003
    }

    static func discoverShares(host: String, user: String, password: String) -> ShareDiscovery {
        // 先花两三秒确认 445/139 通不通：服务器关机时 smbutil 会干等十几秒才吐空结果
        let reach445 = probe(host: host, port: 445, timeout: 2.0)
        let reach139 = reach445 ? false : probe(host: host, port: 139, timeout: 2.0)
        log("probe 445=\(reach445) 139=\(reach139)")
        guard reach445 || reach139 else {
            return ShareDiscovery(failure: L10n.tr("连不上 %@：SMB 端口没有响应，请检查网络或服务器是否开机", host), code: 60)
        }

        // 有些 NAS 需要「域;账号」的形式，允许用户直接写 DOMAIN\user
        let account = user.replacingOccurrences(of: "\\", with: ";")
        let target = account.isEmpty ? "//\(host)" : "//\(account)@\(host)"

        guard let output = runWithPassword(
            executable: "/usr/bin/smbutil",
            arguments: ["view", target],
            password: password
        ) else {
            return ShareDiscovery(failure: L10n.tr("无法运行 smbutil，系统可能阻止了子进程"), code: -1)
        }
        log(L10n.tr("smbutil view %@ 输出 %@ 字节：%@", target, output.utf8.count, output.replacingOccurrences(of: "\n", with: " ⏎ ")))

        let shares = parseShares(output)
        if !shares.isEmpty { return ShareDiscovery(shares: shares) }

        let text = output.lowercased()
        if text.contains("authentication error") || text.contains("logon_failure")
            || text.contains("rejected the authentication")
            || text.contains("password incorrect") || text.contains("access denied") {
            return ShareDiscovery(
                failure: L10n.tr("%@ 拒绝了登录：账号或密码不正确。请确认大小写；若 NAS 要求域，账号写成 DOMAIN\\user；也可能该账号没有 SMB 权限", host),
                code: 80
            )
        }
        if text.contains("timed out") || text.contains("timeout") || text.contains("connection refused")
            || text.contains("no route to host") || text.contains("host is down") {
            return ShareDiscovery(failure: L10n.tr("连不上 %@，请检查网络或服务器是否在线", host), code: 60)
        }
        if text.contains("unknown host") || text.contains("nodename nor servname") {
            return ShareDiscovery(failure: L10n.tr("找不到主机 %@，请检查地址是否写对", host), code: 65)
        }
        let tail = lines(of: output)
            .filter { !$0.lowercased().hasPrefix("password") }
            .last?
            .replacingOccurrences(of: "smbutil: ", with: "")
        guard let tail else {
            // 连提示符都没拿到：服务器接了 TCP 却不应答 SMB 会话，
            // 常见于「允许按名字访问、但禁止浏览共享」的配置
            return ShareDiscovery(
                failure: L10n.tr("%@ 没有响应共享列表请求（可能禁止浏览共享）", host),
                code: 60
            )
        }
        return ShareDiscovery(
            failure: L10n.tr("未能从 %@ 获取共享列表：%@", host, tail),
            code: -6003
        )
    }

    /// 兼容旧调用：只要名字列表
    static func listShares(host: String, user: String, password: String) -> [String] {
        discoverShares(host: host, user: user, password: password).shares
    }

    /// 解析 `smbutil view` 的输出：只取 Disk 类型，跳过 $ 结尾的管理共享
    ///
    /// 注意换行：经伪终端出来的输出是 `\r` 分隔（不是 `\n`），
    /// 直接 `split("\n")` 会把整段当一个「以 Password 开头」的行丢掉，
    /// 表现为「明明密码对、共享也列出来了，却报连不上」。
    private static func parseShares(_ output: String) -> [String] {
        var disks: [String] = []
        for line in lines(of: output) {
            let lower = line.lowercased()
            if lower.hasPrefix("password") || lower.hasPrefix("smbutil")
                || lower.hasPrefix("domain") || lower.hasPrefix("connected") { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 2 else { continue }
            let name = String(columns[0])
            let type = String(columns[1])
            if name.contains(":") || name.hasSuffix("$") { continue }
            if name.lowercased() == "share" || type.lowercased() == "type" { continue }
            if name.allSatisfy({ $0 == "-" }) { continue }
            // 只要磁盘共享：Pipe（IPC$ 之类）和 Printer 都不能挂载
            guard type.caseInsensitiveCompare("Disk") == .orderedSame || type == L10n.tr("磁盘") else { continue }
            if !disks.contains(name) { disks.append(name) }
        }
        return disks
    }

    /// 把 pty 输出切成行：`\r`、`\n`、`\r\n` 都算换行
    private static func lines(of output: String) -> [String] {
        output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 诊断日志

    /// 连接过程的流水账，固定写到 /tmp/pane-smb.log。
    /// 服务器连不上时，这份日志能直接看出卡在哪一步（端口 / 认证 / 枚举 / 挂载）。
    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/pane-smb.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// 快速探测 SMB 端口（445 / 139）是否可连，避免在网络不通时干等
    static func probe(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(result) }

        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            defer { node = current.pointee.ai_next }
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd < 0 { continue }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let rc = connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
            if rc == 0 {
                close(fd)
                return true
            }
            guard errno == EINPROGRESS else {
                close(fd)
                continue
            }

            var fds = fd_set()
            fdZero(&fds)
            fdSet(fd, &fds)
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            let ready = select(fd + 1, nil, &fds, nil, &tv)
            if ready > 0 {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                close(fd)
                if error == 0 { return true }
            } else {
                close(fd)
            }
        }
        return false
    }

    /// 用伪终端跑子进程：密码通过终端输入，不出现在 `ps` 的命令行里。
    /// 认证失败时服务器可能只在第一次提示，也可能连问两次，所以按提示次数补发。
    private static func runWithPassword(
        executable: String,
        arguments: [String],
        password: String,
        timeout: TimeInterval = 8
    ) -> String? {
        // argv 必须在 fork 之前准备好。fork 出来的子进程里再分配内存
        // （strdup / Swift 数组）会碰到父进程其他线程持有的 malloc 锁而死锁，
        // 表现就是「点了连接一直转圈，最后报超时」。
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, nil)
        if pid == 0 {
            execv(executable, argv)
            _exit(127)
        }
        argv.forEach { free($0) }
        guard pid > 0 else { return nil }

        // 关闭回显，避免口令被打回输出
        var term = termios()
        if tcgetattr(master, &term) == 0 {
            term.c_lflag &= ~UInt(ECHO)
            tcsetattr(master, TCSANOW, &term)
        }

        var output = Data()
        var promptsSeen = 0
        var promptsSent = 0
        var lastSend = Date.distantPast
        let deadline = Date().addingTimeInterval(timeout)

        func flushPasswordIfNeeded() {
            guard promptsSeen > promptsSent, promptsSent < 2 else { return }
            // 提示刚打出来时终端可能还没准备好接收，稍等一下再写，
            // 否则口令会被丢掉、子进程继续干等（这是之前「连不上」的一种可能）
            guard Date().timeIntervalSince(lastSend) > 0.15 else { return }
            _ = (password + "\n").withCString { write(master, $0, strlen($0)) }
            promptsSent += 1
            lastSend = Date()
        }

        while Date() < deadline {
            var fds = fd_set()
            fdZero(&fds)
            fdSet(master, &fds)
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)
            let ready = select(master + 1, &fds, nil, nil, &tv)
            if ready > 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = buffer.withUnsafeMutableBytes { pointer in
                    read(master, pointer.baseAddress, pointer.count)
                }
                if count <= 0 { break }
                output.append(contentsOf: buffer[0..<count])

                let text = String(decoding: output, as: UTF8.self)
                promptsSeen = text.components(separatedBy: "assword").count - 1
                flushPasswordIfNeeded()
            } else {
                // 没有新输出时也补发一次（提示可能已经打出来但我们刚好错过）
                flushPasswordIfNeeded()
            }
        }

        // 超时还在等输入的子进程要先收掉，否则下面的 waitpid 会一直挂着
        kill(pid, SIGTERM)
        var status: Int32 = 0
        var waited: pid_t = 0
        for _ in 0..<10 {
            waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            usleep(50_000)
        }
        if waited != pid {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
        close(master)
        return String(decoding: output, as: UTF8.self)
    }

    private static func fdZero(_ set: inout fd_set) {
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { ints in
                for index in 0..<32 { ints[index] = 0 }
            }
        }
    }

    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let offset = Int32(fd / 32)
        let mask = Int32(1) << (fd % 32)
        withUnsafeMutablePointer(to: &set) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { ints in
                ints[Int(offset)] |= mask
            }
        }
    }
}

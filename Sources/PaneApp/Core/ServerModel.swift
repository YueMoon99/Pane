import Foundation
import SwiftUI
import AppKit

/// 一台保存下来的服务器。只有「备注 / 地址 / 共享 / 账号」落盘，密码在钥匙串里。
struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String = ""
    var host: String = ""
    /// 可留空：留空表示连接时枚举该服务器上的全部共享
    var share: String = ""
    var user: String = ""

    /// 侧边栏显示名：备注优先；没写备注时退回地址，免得留一行空白
    var displayName: String {
        label.isEmpty ? host : label
    }

    var subtitle: String {
        share.isEmpty ? host : "\(host) / \(share)"
    }
}

/// 一台服务器在工作区里的「根位置」。
///
/// 它不代表某个本地目录，而是一屏共享列表：点侧边栏的服务器，
/// 工作区就像打开文件夹一样列出这台机器上的所有共享，双击才真正挂载。
/// `url` 是一个只用于导航 / 标签页标题 / 历史栈的合成标识（`smb://host`），不是文件 URL。
struct ServerLocation: Hashable, Sendable {
    var profileID: UUID
    var host: String
    var label: String
    var user: String

    init(profileID: UUID, host: String, label: String, user: String) {
        self.profileID = profileID
        self.host = host
        self.label = label
        self.user = user
    }

    init(profile: ServerProfile) {
        self.init(
            profileID: profile.id,
            host: profile.host,
            label: profile.displayName,
            user: profile.user
        )
    }

    var url: URL {
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        return comps.url ?? URL(fileURLWithPath: "/Volumes")
    }
}

/// 服务器操作失败的原因：都能直接照做，不出现「超时」这种没头没尾的提示。
enum ServerError: LocalizedError {
    case noCredentials(String)
    case listing(String)
    case profileMissing(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let name):
            return L10n.tr("还没有保存「%@」的密码。右键这台服务器选「重新连接…」，输入一次密码就好", name)
        case .listing(let message):
            return message
        case .profileMissing(let host):
            return L10n.tr("服务器 %@ 已不在侧边栏列表里", host)
        }
    }
}

/// SMB 服务器列表、会话与挂载状态（凭据只进钥匙串）
///
/// 这里是全进程共享的：挂载是整机状态，多个窗口应该看到同一批服务器。
@MainActor
@Observable
final class ServerModel {
    static let shared = ServerModel()

    /// 一次连接会话：认证通过后的共享清单 + 已经挂上的共享
    struct Session {
        var shares: [String] = []
        var mounted: [String: URL] = [:]
        /// 是否真的向服务器要过一次共享列表（只靠残留挂载推出来的不算）
        var listed = false
    }

    /// 已保存的服务器，顺序即侧边栏顺序
    private(set) var profiles: [ServerProfile] = []
    /// 每台服务器的会话（认证过、或是启动时发现有残留挂载）
    private(set) var sessions: [UUID: Session] = [:]
    /// 正在连接 / 正在列共享的服务器
    private(set) var connecting: Set<UUID> = []
    var lastError: String?
    /// 连接过程中的提示
    private(set) var statusText: String?

    private let storageKey = "servers.v1"

    init() {
        profiles = Self.loadProfiles()
        detectExistingMounts()
    }

    // MARK: 查询

    var anyConnected: Bool {
        profiles.contains { isConnected($0) }
    }

    func isConnected(_ profile: ServerProfile) -> Bool {
        sessions[profile.id] != nil
    }

    func isConnecting(_ profile: ServerProfile) -> Bool {
        connecting.contains(profile.id)
    }

    /// 已挂载的共享 → 挂载点
    func mountedShares(_ profile: ServerProfile) -> [String: URL] {
        sessions[profile.id]?.mounted ?? [:]
    }

    func mountURLs(_ profile: ServerProfile) -> [URL] {
        Array(mountedShares(profile).values)
    }

    func mountedURL(share: String, on profile: ServerProfile) -> URL? {
        sessions[profile.id]?.mounted[share]
    }

    /// 已知的共享清单（没连过时为 nil）
    func shares(of profile: ServerProfile) -> [String]? {
        sessions[profile.id]?.shares
    }

    func profile(id: UUID?) -> ServerProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func profile(host: String) -> ServerProfile? {
        profiles.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// 从 `smb://host` 这样的位置标识反查服务器（找不到就用地址兜底，供标签页恢复用）
    func location(forHost host: String) -> ServerLocation {
        if let profile = profile(host: host) { return ServerLocation(profile: profile) }
        return ServerLocation(profileID: UUID(), host: host, label: host, user: "")
    }

    func location(for profile: ServerProfile) -> ServerLocation {
        ServerLocation(profile: profile)
    }

    /// 点一行服务器时是否需要先问密码：没连过、钥匙串里也没有密码
    func needsCredentials(_ profile: ServerProfile) -> Bool {
        if sessions[profile.id] != nil { return false }
        return savedPassword(for: profile) == nil
    }

    // MARK: 保存服务器

    /// 新建（或覆盖同地址）一台服务器
    @discardableResult
    func addProfile(label: String, host: String, share: String, user: String) -> ServerProfile {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = profiles.firstIndex(where: {
            $0.host.caseInsensitiveCompare(trimmedHost) == .orderedSame
        }) {
            // 同一个地址再连一次：更新备注/账号，不新增重复行
            profiles[index].label = trimmedLabel
            profiles[index].user = trimmedUser
            if !trimmedShare.isEmpty { profiles[index].share = trimmedShare }
            persist()
            return profiles[index]
        }

        let profile = ServerProfile(
            label: trimmedLabel,
            host: trimmedHost,
            share: trimmedShare,
            user: trimmedUser
        )
        profiles.append(profile)
        persist()
        return profile
    }

    /// 从列表里移除（会先断开）
    func remove(_ profile: ServerProfile) {
        disconnect(profile)
        profiles.removeAll { $0.id == profile.id }
        sessions[profile.id] = nil
        persist()
    }

    // MARK: 连接（只认证 / 列共享，不挂载）

    /// 认证一台服务器，并拿到它的共享清单。
    /// - Returns: 连接成功时返回列表里对应的那一条，失败返回 nil（原因在 `lastError`）
    @discardableResult
    func connect(
        _ candidate: ServerProfile,
        password: String,
        remember: Bool
    ) async -> ServerProfile? {
        guard !connecting.contains(candidate.id) else { return nil }
        connecting.insert(candidate.id)
        lastError = nil
        statusText = L10n.tr("正在读取共享列表…")
        defer {
            connecting.remove(candidate.id)
            statusText = nil
        }

        let host = candidate.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = candidate.user.trimmingCharacters(in: .whitespacesAndNewlines)

        // 用户直接填了共享名：一步挂上，不再枚举（有些服务器禁止浏览共享）
        if !candidate.share.isEmpty {
            do {
                let url = try await Self.mountDetached(
                    host: host, share: candidate.share, user: user, password: password
                )
                let saved = addProfile(
                    label: candidate.label, host: host, share: candidate.share, user: user
                )
                var session = sessions[saved.id] ?? Session()
                session.mounted[candidate.share] = url
                if !session.shares.contains(candidate.share) {
                    session.shares.append(candidate.share)
                }
                // 用户指定了共享：不枚举，之后进共享列表时再补一次
                session.listed = false
                sessions[saved.id] = session
                rememberPassword(remember, host: host, user: user, password: password)
                return saved
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }

        let discovery = await Task.detached(priority: .userInitiated) {
            SMBMounter.discoverShares(host: host, user: user, password: password)
        }.value

        guard !discovery.shares.isEmpty else {
            lastError = discovery.failure ?? L10n.tr("未能从 %@ 获取共享列表", host)
            // 密码被拒绝时清掉钥匙串里的旧口令，否则下次又会自动填上同一个错误密码
            if discovery.code == 80 || discovery.code == 86, !user.isEmpty {
                KeychainStore.delete(service: Self.service(for: host), account: user)
            }
            return nil
        }

        let saved = addProfile(label: candidate.label, host: host, share: "", user: user)
        var session = sessions[saved.id] ?? Session()
        session.shares = Self.merged(discovery.shares, with: Array(session.mounted.keys))
        session.listed = true
        sessions[saved.id] = session
        rememberPassword(remember, host: host, user: user, password: password)
        return saved
    }

    /// 进入服务器根时调用：确保有共享清单（有会话就复用，否则用钥匙串里的密码枚举）
    @discardableResult
    func ensureSession(for profile: ServerProfile, force: Bool = false) async throws -> [String] {
        if !force, let session = sessions[profile.id], !session.shares.isEmpty, session.listed {
            return session.shares
        }
        guard let password = savedPassword(for: profile) else {
            throw ServerError.noCredentials(profile.displayName)
        }

        let known = Array((sessions[profile.id]?.mounted ?? [:]).keys)
        guard !connecting.contains(profile.id) else { return known }
        connecting.insert(profile.id)
        defer { connecting.remove(profile.id) }

        let discovery = await Task.detached(priority: .userInitiated) {
            SMBMounter.discoverShares(host: profile.host, user: profile.user, password: password)
        }.value

        var session = sessions[profile.id] ?? Session()
        if discovery.shares.isEmpty {
            // 枚举失败但已经有挂着的共享：至少把已挂载的列出来，别让用户看到一片空白
            let cached = session.shares
            let fallback = cached.isEmpty ? known : cached
            if !fallback.isEmpty {
                session.shares = Self.merged(fallback, with: known)
                sessions[profile.id] = session
                return session.shares
            }
            throw ServerError.listing(discovery.failure ?? L10n.tr("未能从 %@ 获取共享列表", profile.host))
        }
        session.shares = Self.merged(discovery.shares, with: known)
        session.listed = true
        sessions[profile.id] = session
        return session.shares
    }

    // MARK: 挂载单个共享

    /// 挂载一个共享（工作区里双击共享时调用）
    func mount(share: String, on profile: ServerProfile) async throws -> URL {
        if let existing = sessions[profile.id]?.mounted[share],
           FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        guard let password = savedPassword(for: profile) else {
            throw ServerError.noCredentials(profile.displayName)
        }

        connecting.insert(profile.id)
        defer { connecting.remove(profile.id) }

        let host = profile.host
        let user = profile.user
        let url = try await Self.mountDetached(host: host, share: share, user: user, password: password)

        var session = sessions[profile.id] ?? Session()
        session.mounted[share] = url
        session.shares = Self.merged(session.shares + [share], with: [share])
        sessions[profile.id] = session
        return url
    }

    private static func mountDetached(
        host: String,
        share: String,
        user: String,
        password: String
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try SMBMounter.mountShare(host: host, share: share, user: user, password: password)
        }.value
    }

    /// 共享清单：枚举结果 + 已挂载的，去重后按名称排序
    private static func merged(_ shares: [String], with extra: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in shares + extra where !name.isEmpty {
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func rememberPassword(_ remember: Bool, host: String, user: String, password: String) {
        guard remember, !user.isEmpty, !password.isEmpty else { return }
        KeychainStore.save(service: Self.service(for: host), account: user, password: password)
    }

    // MARK: 断开

    func disconnect(_ profile: ServerProfile) {
        for url in (sessions[profile.id]?.mounted ?? [:]).values {
            Self.unmount(url)
        }
        sessions[profile.id] = nil
    }

    private static func unmount(_ url: URL) {
        for force in [false, true] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = force ? ["unmount", "force", url.path] : ["unmount", url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return
            }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
        }
    }

    // MARK: 凭据

    func savedPassword(for profile: ServerProfile) -> String? {
        Self.savedPassword(host: profile.host, user: profile.user)
    }

    static func savedPassword(host: String, user: String) -> String? {
        guard !user.isEmpty else { return nil }
        return KeychainStore.load(service: service(for: host), account: user)
    }

    /// 列出服务器上的共享（连不上或服务器禁止浏览时返回空）
    func discoverShares(host: String, user: String, password: String) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            SMBMounter.discoverShares(host: host, user: user, password: password).shares
        }.value
    }

    // MARK: 启动时识别已挂载的卷

    private func detectExistingMounts() {
        let keys: [URLResourceKey] = [
            .volumeIsLocalKey, .volumeURLForRemountingKey, .volumeNameKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: []
        ) ?? []

        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == false,
                  let remount = values.volumeURLForRemounting,
                  let host = remount.host else { continue }
            guard let profile = profile(host: host) else { continue }
            let share = Self.shareName(of: volume, host: host)
            guard !share.isEmpty else { continue }
            var session = sessions[profile.id] ?? Session()
            session.mounted[share] = volume
            session.shares = Self.merged(session.shares + [share], with: [share])
            sessions[profile.id] = session
        }
    }

    /// 从挂载点反推共享名：优先用 volumeURLForRemounting 的路径，其次用卷名
    static func shareName(of url: URL, host: String) -> String {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)),
           let remount = values.volumeURLForRemounting {
            let name = SMBMounter.normalizeShare(remount.path)
            if !name.isEmpty { return name }
        }
        return url.lastPathComponent
    }

    // MARK: 持久化

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func loadProfiles() -> [ServerProfile] {
        if let data = UserDefaults.standard.data(forKey: "servers.v1"),
           let saved = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            return deduplicated(saved)
        }

        // 迁移旧版单服务器设置（smb.host / smb.label / smb.user）
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "smb.host") ?? ""
        let label = defaults.string(forKey: "smb.label") ?? ""
        let share = defaults.string(forKey: "smb.share") ?? ""
        let user = defaults.string(forKey: "smb.user") ?? ""
        guard !host.isEmpty || !label.isEmpty else { return [] }
        return [ServerProfile(label: label, host: host, share: share, user: user)]
    }

    /// 早期版本按「地址 + 共享名」去重，同一台机器可能留下好几行；
    /// 现在一台服务器就是一行共享列表，启动时按地址合并（保留备注、账号）
    private static func deduplicated(_ profiles: [ServerProfile]) -> [ServerProfile] {
        var result: [ServerProfile] = []
        for profile in profiles {
            guard let index = result.firstIndex(where: {
                $0.host.caseInsensitiveCompare(profile.host) == .orderedSame
            }) else {
                result.append(profile)
                continue
            }
            if result[index].label.isEmpty { result[index].label = profile.label }
            if result[index].user.isEmpty { result[index].user = profile.user }
        }
        return result
    }

    // MARK: 工具

    private static func service(for host: String) -> String {
        let name = SMBMounter.parse(host)?.host ?? host
        return "com.moon.pane.smb.\(name)"
    }
}

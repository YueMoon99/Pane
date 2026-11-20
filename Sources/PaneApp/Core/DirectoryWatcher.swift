import Foundation
import AppKit
import Darwin

enum WatcherConfig {
    /// 调试开关：定位 NSTableView 重入警告时临时关闭
    static let enabled = true
}

/// 基于目录文件描述符的轻量变更监听（内容增删改会触发 .write）
///
/// 只用在**本地卷**：kqueue 的事件来自内核，零网络开销、延迟只有防抖的 0.25 秒。
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.moon.pane.dirwatch")
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let path = url.path
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )
        source?.setEventHandler { [weak self] in self?.scheduleReload() }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 {
                close(fd)
                self?.fd = -1
            }
        }
        source?.resume()
    }

    private func scheduleReload() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

/// 网络卷（SMB / AFP / NFS）上的轮询兜底。
///
/// 这类卷上 kqueue 的目录 `.write` 事件基本指望不上：多数服务器根本不发，
/// 少数实现一次批量操作会发一整串，重载把带宽打满还卡界面。访达在远程卷上
/// 同样退化成轮询，所以这里照同样的取舍做一个尽量便宜的实现：
///
/// - **每 2 秒 `stat` 一次目录**：只读目录自身的 mtime / 大小 / 链接数，
///   一次极小的往返。外部「新建 / 删除 / 改名」都会改父目录的 mtime，够用了。
/// - **每 12 秒再取一次纯文件名**：有些 NAS 的 mtime 精度只到分钟、或者干脆不
///   更新目录 mtime，这时靠名字集合的差异兜底。`contentsOfDirectory` 不带属性，
///   是这轮询里唯一真正读目录的请求。
/// - 只在**窗格可见 + App 在前台**时跑：隐藏的标签页不该每 2 秒戳一下 NAS。
final class PollingDirectoryWatcher: @unchecked Sendable {
    /// 目录自身状态的指纹，一次 `stat` 就能拿到
    private struct Stamp: Equatable {
        var exists: Bool
        var modified: Int64   // mtime（纳秒）
        var size: Int64
        var links: Int64      // 子目录增减会改链接数（APFS / HFS），其它文件系统上不变也无害
    }

    /// 轮询周期：2 秒足够贴近访达的体感，局域网里一次 stat 是毫秒级
    private static let interval: TimeInterval = 2
    /// 每 N 个周期做一次「只取文件名」的深检查（2s × 6 = 12s）
    private static let deepEvery = 6
    /// 触发后至少隔这么久才考虑下一次：解压 / 批量拷贝会连续改目录，
    /// 不设冷却的话每个周期都会重载一遍
    private static let cooldown: TimeInterval = 1.5

    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.moon.pane.netpoll", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// 以下状态只在 `queue` 上访问
    private var baseline = Stamp(exists: false, modified: 0, size: 0, links: 0)
    private var baselineNames: Set<String>?
    private var ticks = 0
    private var lastFire = Date.distantPast

    /// 以下状态在锁后面：主线程（可见性 / 激活状态）写，轮询线程读
    private let lock = NSLock()
    private var visible = true
    private var appActive = true
    private var stopped = false

    /// 启动时立刻取一次基线，之后交给定时器
    init(url: URL, appActive: Bool, onChange: @escaping () -> Void) {
        self.url = url
        self.appActive = appActive
        self.onChange = onChange
        baseline = Self.stamp(at: url.path)
        debugLog("[poll] start \(url.path) appActive=\(appActive) baseline=\(baseline)")
        observeActivation()
        startTimer()
    }

    // MARK: 开关

    /// 窗格是否在屏幕上（由 `PaneView` 的任务生命周期维护）
    func setVisible(_ value: Bool) {
        lock.lock()
        let changed = visible != value
        visible = value
        lock.unlock()
        if changed {
            debugLog("[poll] visible=\(value) \(url.path)")
            if value { poke() }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && visible && appActive
    }

    // MARK: 定时器

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval,
                       repeating: Self.interval,
                       leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// 刚变可见 / App 刚回到前台：立刻补一次检查，不用等下一个周期。
    /// 基线可能已经过期，这一下通常正好能把「切走期间的变化」刷出来。
    private func poke() {
        lastFire = .distantPast
        queue.async { [weak self] in self?.tick() }
    }

    private func observeActivation() {
        let center = NotificationCenter.default
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true),
                               (NSApplication.willResignActiveNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.appActive = active
                self.lock.unlock()
                if active { self.poke() }
            }
        }
    }

    // MARK: 检查

    private func tick() {
        guard isRunning else { return }
        ticks += 1

        var changed = false
        var viaStat = false
        let now = Self.stamp(at: url.path)
        if now != baseline {
            viaStat = true
            baseline = now
            // 名字基线跟着作废，下一轮深检查只记录、不比较，避免重复触发
            baselineNames = nil
            changed = true
        } else if ticks % Self.deepEvery == 0 {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                let current = Set(names)
                if let known = baselineNames, known != current { changed = true }
                baselineNames = current
            }
        }

        guard changed else { return }
        guard Date().timeIntervalSince(lastFire) >= Self.cooldown else { return }
        lastFire = Date()
        debugLog("[poll] change detected \(url.path) via \(viaStat ? "stat" : "names")")
        onChange()
    }

    /// 一次 stat 拿到目录指纹；失败（被卸载 / 无权限）也算一种「变化」
    private static func stamp(at path: String) -> Stamp {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return Stamp(exists: false, modified: 0, size: 0, links: 0)
        }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return Stamp(exists: true,
                     modified: modified,
                     size: Int64(info.st_size),
                     links: Int64(info.st_nlink))
    }
}

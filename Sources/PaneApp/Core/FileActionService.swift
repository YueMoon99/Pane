import Foundation
import AppKit

/// 单次性的文件动作：新建、压缩、计算哈希、在终端 / 访达中打开。
///
/// 与 `FileOperationService`（复制 / 移动 / 废纸篓）分开：那边是「传输」，
/// 这边是「一次性命令」。所有重 I/O 都在后台线程，结果回到主线程展示。
@MainActor
@Observable
final class FileActionService {
    static let shared = FileActionService()

    var isWorking = false
    /// 失败或前置条件不满足时的提示（ContentView 用它弹窗）
    var lastError: String?
    /// 哈希结果面板
    var hashReport: HashReport?

    struct HashReport: Identifiable, Sendable {
        let id = UUID()
        var algorithm: String
        var rows: [HashRow]
        var failed: [String]
    }

    struct HashRow: Identifiable, Sendable {
        let id = UUID()
        var name: String
        var digest: String
    }

    private init() {}

    // MARK: - 新建

    /// 在当前目录新建文件夹，返回新目录 URL（供调用方选中）
    func newFolder(in directory: URL) -> URL? {
        let target = Self.uniqueURL(stem: L10n.tr("未命名文件夹"), ext: "", in: directory)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return target
        } catch {
            lastError = L10n.tr("新建文件夹失败：%@", error.localizedDescription)
            return nil
        }
    }

    /// 在当前目录新建一个空文本文件
    func newDocument(in directory: URL) -> URL? {
        let target = Self.uniqueURL(stem: L10n.tr("未命名"), ext: "txt", in: directory)
        do {
            try Data().write(to: target, options: .withoutOverwriting)
            return target
        } catch {
            lastError = L10n.tr("新建文件失败：%@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - 重命名

    /// 改名为 `newName`（同目录内），返回改名后的 URL
    ///
    /// 一律用 `moveItem`：`URLResourceValues.name` 在部分系统上会改成功却不回写
    /// URL 自身的路径，容易误判成失败。大小写不敏感卷上「abc.png → ABC.png」
    /// 会被判定为「目标已存在」，这时用临时名中转一次。
    func rename(_ url: URL, to newName: String) -> URL? {
        let directory = url.deletingLastPathComponent()
        let target = directory.appendingPathComponent(newName)
        if target.standardizedFileURL == url.standardizedFileURL { return url }
        let fm = FileManager.default

        do {
            guard fm.fileExists(atPath: target.path) else {
                try fm.moveItem(at: url, to: target)
                return target
            }
            // 只改大小写：目标名「已存在」的其实还是自己，借临时名绕过
            let temp = directory.appendingPathComponent(".pane-rename-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: temp)
            do {
                try fm.moveItem(at: temp, to: target)
                return target
            } catch {
                try? fm.moveItem(at: temp, to: url)
                throw error
            }
        } catch {
            lastError = L10n.tr("重命名失败：%@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - 压缩

    /// 逐个压缩为 zip（与访达一致：多选时每项一个压缩包）
    func compress(_ urls: [URL], into directory: URL) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
            var failures: [String] = []
            for source in urls {
                let stem = source.deletingPathExtension().lastPathComponent
                let target = Self.uniqueURL(stem: stem, ext: "zip", in: directory)
                // ditto 保留资源分支与扩展属性，与「归档实用工具」产物一致
                let status = Self.run("/usr/bin/ditto", [
                    "-c", "-k", "--sequesterRsrc", "--keepParent",
                    source.path, target.path
                ])
                if status != 0 {
                    try? FileManager.default.removeItem(at: target)
                    failures.append(source.lastPathComponent)
                }
            }
            return failures
        }.value

        if !failures.isEmpty {
            lastError = L10n.tr("压缩失败：%@", failures.prefix(3).joined(separator: "、"))
        }
    }

    // MARK: - 哈希

    /// 计算 SHA-256（只处理文件，目录跳过并在结果里标注）
    func computeHashes(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }

        let snapshot = urls
        let report = await Task.detached(priority: .userInitiated) { () -> HashReport in
            var rows: [HashRow] = []
            var failed: [String] = []

            let files = snapshot.filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return !isDir.boolValue
            }
            let directories = snapshot.filter { !files.contains($0) }

            if !files.isEmpty {
                // 一次调用处理全部文件，省去逐个启动进程
                let output = Self.capture("/usr/bin/shasum", ["-a", "256"] + files.map(\.path))
                var digestByName: [String: String] = [:]
                for line in output.split(separator: "\n") {
                    // 格式：<hash>  <path>
                    guard let split = line.range(of: "  ") else { continue }
                    let digest = String(line[line.startIndex..<split.lowerBound])
                    let path = String(line[split.upperBound...])
                    digestByName[path] = digest
                }
                for file in files {
                    if let digest = digestByName[file.path] {
                        rows.append(HashRow(name: file.lastPathComponent, digest: digest))
                    } else {
                        failed.append(file.lastPathComponent)
                    }
                }
            }

            for dir in directories {
                failed.append(L10n.tr("%@（文件夹不支持）", dir.lastPathComponent))
            }
            return HashReport(algorithm: "SHA-256", rows: rows, failed: failed)
        }.value

        hashReport = report
    }

    // MARK: - 外部 App

    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let text = urls.map(\.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func openInTerminal(_ directory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", directory.path]
        do {
            try process.run()
        } catch {
            lastError = L10n.tr("无法打开终端：%@", error.localizedDescription)
        }
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - 后台工具

    /// 名称冲突时生成「名称 2」「名称 3」…
    nonisolated static func uniqueURL(stem: String, ext: String, in directory: URL) -> URL {
        let fm = FileManager.default
        func compose(_ index: Int) -> URL {
            let name = index == 1 ? stem : "\(stem) \(index)"
            let full = ext.isEmpty ? name : "\(name).\(ext)"
            return directory.appendingPathComponent(full)
        }
        var index = 1
        var candidate = compose(index)
        while fm.fileExists(atPath: candidate.path), index < 999 {
            index += 1
            candidate = compose(index)
        }
        return candidate
    }

    /// 运行命令并丢弃输出，返回退出码
    nonisolated static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 运行命令并返回标准输出
    nonisolated static func capture(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 工具栏动作（作用于焦点窗格）

extension AppState {
    private var actions: FileActionService { .shared }

    /// 工具栏动作的操作对象：有选择用选择，否则用当前目录（服务器共享列表没有本地路径，直接空）
    private var actionURLs: [URL] {
        let selected = focused.selectedURLs().filter(\.isFileURL)
        if !selected.isEmpty { return selected }
        return focused.url.isFileURL ? [focused.url] : []
    }

    func createFolder() {
        guard focused.url.isFileURL else { NSSound.beep(); return }
        guard let url = actions.newFolder(in: focused.url) else { return }
        Task {
            await focused.load()
            focused.selection = [url]
        }
    }

    func createDocument() {
        guard focused.url.isFileURL else { NSSound.beep(); return }
        guard let url = actions.newDocument(in: focused.url) else { return }
        Task {
            await focused.load()
            focused.selection = [url]
        }
    }

    func copySelectedPath() {
        guard !actionURLs.isEmpty else { NSSound.beep(); return }
        actions.copyPaths(actionURLs)
    }

    func openInTerminal() {
        // 选中文件夹时在它里面开终端，否则开当前目录
        let target = focused.selectedURLs().first { url in
            guard url.isFileURL else { return false }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }
        guard let directory = target ?? (focused.url.isFileURL ? focused.url : nil) else {
            NSSound.beep()
            return
        }
        actions.openInTerminal(directory)
    }

    func revealInFinder() {
        guard !actionURLs.isEmpty else { NSSound.beep(); return }
        actions.revealInFinder(actionURLs)
    }

    func compressSelection() {
        let urls = focused.selectedURLs().filter(\.isFileURL)
        guard !urls.isEmpty else {
            actions.lastError = L10n.tr("请先选择要压缩的项目")
            return
        }
        let destination = focused.url
        guard destination.isFileURL else {
            actions.lastError = L10n.tr("请先进入一个文件夹再压缩")
            return
        }
        Task {
            await actions.compress(urls, into: destination)
            await focused.load()
        }
    }

    func calculateHashes() {
        let urls = focused.selectedURLs()
        guard !urls.isEmpty else {
            actions.lastError = L10n.tr("请先选择要计算哈希的项目")
            return
        }
        Task { await actions.computeHashes(urls) }
    }

    /// 解压所选压缩包，完成后选中解压结果
    /// - Parameter intoNamedFolders: 为 true 时解到与压缩包同名的文件夹里
    func extractSelectedArchives(intoNamedFolders: Bool = false) {
        let urls = focused.selectedURLs().filter { ArchiveService.canExtract($0) }
        guard !urls.isEmpty else {
            actions.lastError = L10n.tr("请先选择 zip、tar 等可以就地解压的压缩文件")
            return
        }
        let pane = focused
        Task { await pane.extract(urls, intoNamedFolders: intoNamedFolders) }
    }
}

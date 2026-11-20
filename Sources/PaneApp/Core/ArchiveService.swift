import Foundation

/// 就地解压：直接调用系统自带的 ditto / tar / gzip 等工具，
/// 不经过「归档实用工具」，因此不会弹出额外窗口。
///
/// 返回「解压后在目录里新出现的项目」，调用方据此选中它们。
enum ArchiveService {
    struct Outcome: Sendable {
        var created: [URL] = []
        var failed: [String] = []
    }

    /// 解压落点
    enum Destination: Sendable {
        /// 直接铺在压缩包旁边（「解压到当前文件夹」）
        case besideArchive
        /// 放进一个与压缩包同名的文件夹（「解压到“名字”」）
        case namedFolder
    }

    /// 能就地解压的格式；其余（磁盘映像、7z、rar 等）交给系统默认程序
    static func canExtract(_ url: URL) -> Bool {
        command(for: url) != nil || singleFileTool(for: url) != nil
    }

    /// 压缩包对应的文件夹名：去掉归档扩展名后的文件名
    /// （`Photos.tar.gz` → `Photos`，`a.zip` → `a`）
    static func folderName(for url: URL) -> String {
        var name = url.lastPathComponent
        // 顺序有意义：多段扩展名要先于单段判断
        let suffixes = [
            ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.z",
            ".tgz", ".tbz2", ".tbz", ".txz", ".tzst",
            ".tar", ".zip", ".gz", ".bz2", ".xz", ".zst", ".7z", ".rar",
        ]
        for suffix in suffixes where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.isEmpty ? url.lastPathComponent : name
    }

    static func extract(_ urls: [URL], destination: Destination = .besideArchive) async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            var outcome = Outcome()
            for url in urls {
                guard canExtract(url) else {
                    outcome.failed.append(url.lastPathComponent)
                    continue
                }
                let parent = url.deletingLastPathComponent()
                // 先记下目录现状，再建文件夹：这样「新建的文件夹」也会被算成新出现的项目
                let before = names(in: parent)
                var target = parent

                if destination == .namedFolder {
                    let folder = parent.appendingPathComponent(folderName(for: url), isDirectory: true)
                    do {
                        // 已存在同名文件夹时沿用（Finder 也是直接往里解），不覆盖也不报错
                        try FileManager.default.createDirectory(
                            at: folder,
                            withIntermediateDirectories: true
                        )
                    } catch {
                        outcome.failed.append(url.lastPathComponent)
                        continue
                    }
                    target = folder
                }

                // 先看能接受目标目录的格式（tar / zip），再退回单文件压缩器：
                // 否则 .tar.gz 会被当成 gzip 单文件，解出一个 .tar 而不是解开归档
                let succeeded: Bool
                if let makeCommand = command(for: url) {
                    let (tool, arguments) = makeCommand(url, target)
                    succeeded = run(tool, arguments) == 0
                } else if let tool = singleFileTool(for: url) {
                    succeeded = decompress(url, with: tool, into: target)
                } else {
                    succeeded = false
                }

                if !succeeded {
                    // 失败时把刚建出来的空文件夹收掉，别在用户目录里留垃圾
                    if destination == .namedFolder, target != parent, isEmpty(target) {
                        try? FileManager.default.removeItem(at: target)
                    }
                    outcome.failed.append(url.lastPathComponent)
                    continue
                }

                // 新建的文件夹本身也算「新出现的项目」，解压完直接选中它
                let after = names(in: parent)
                var created = after.subtracting(before).sorted().map {
                    parent.appendingPathComponent($0)
                }
                // 同名文件夹本来就存在时，diff 里不会有它，这里补上，保证解压完仍有落点
                if destination == .namedFolder, !created.contains(target) {
                    created.append(target)
                }
                outcome.created += created
            }
            return outcome
        }.value
    }

    // MARK: - 命令选择

    /// 返回一个「压缩包 + 目标目录 → 可执行文件与参数」的构造函数（能接受目标目录的格式）
    private static func command(for url: URL) -> ((URL, URL) -> (String, [String]))? {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        // 双扩展名的 tar 家族必须先于单扩展名判断
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz")
            || ["tar", "tgz", "tbz", "tbz2", "txz"].contains(ext) {
            return { archive, dir in ("/usr/bin/tar", ["-xf", archive.path, "-C", dir.path]) }
        }

        switch ext {
        case "zip":
            // ditto 能正确还原中文文件名与扩展属性，与访达解压结果一致
            return { archive, dir in ("/usr/bin/ditto", ["-x", "-k", archive.path, dir.path]) }
        default:
            return nil
        }
    }

    /// 单文件压缩器（解出来只有一个文件，没有目标目录参数）
    private static func singleFileTool(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "gz": "/usr/bin/gzip"
        case "bz2": "/usr/bin/bzip2"
        case "xz": "/usr/bin/xz"
        default: nil
        }
    }

    // MARK: - 工具

    /// 解到指定目录（文件名为去掉压缩扩展名后的名字）
    private static func decompress(_ archive: URL, with tool: String, into directory: URL) -> Bool {
        let output = directory.appendingPathComponent(
            archive.deletingPathExtension().lastPathComponent
        )
        let manager = FileManager.default
        if manager.fileExists(atPath: output.path) {
            try? manager.removeItem(at: output)
        }
        guard manager.createFile(atPath: output.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: output.path)
        else {
            return false
        }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        // -dc：解压到标准输出，再重定向到目标文件，这样能落到任意目录
        process.arguments = ["-dc", archive.path]
        process.standardOutput = handle
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func names(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private static func isEmpty(_ directory: URL) -> Bool {
        names(in: directory).isEmpty
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
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
}

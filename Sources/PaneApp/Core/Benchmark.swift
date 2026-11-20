import Foundation

/// 命令行性能基准：`Pane --bench <目录> [--repeat 3]`
///
/// 直接调用 `LocalFileSystem` 枚举目录并输出耗时，不创建窗口，跑完即退出，
/// 供 `Scripts/benchmark.sh` 在 1k / 10k / 50k 目录上做回归对比。
enum Benchmark {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--bench"),
              args.count > flagIndex + 1 else { return }

        let path = args[flagIndex + 1]
        let repeatCount = args.firstIndex(of: "--repeat")
            .flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 3

        run(path: path, repeatCount: max(1, repeatCount))
        exit(0)
    }

    private static func run(path: String, repeatCount: Int) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached(priority: .high) {
            var timings: [Double] = []
            var count = 0
            var failure: String?

            // 预热一次，排除首次磁盘缓存抖动
            _ = try? await LocalFileSystem.shared.contents(of: url, showHidden: false)

            for _ in 0..<repeatCount {
                let start = CFAbsoluteTimeGetCurrent()
                do {
                    let items = try await LocalFileSystem.shared.contents(of: url, showHidden: false)
                    count = items.count
                    timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }

            if let failure {
                print("  ✗ \(path)：\(failure)")
            } else {
                let minValue = timings.min() ?? 0
                let maxValue = timings.max() ?? 0
                let avg = timings.reduce(0, +) / Double(max(1, timings.count))
                let rate = avg > 0 ? Double(count) / (avg / 1000) : 0
                let label = path.count > 46
                    ? "…" + String(path.suffix(45))
                    : path.padding(toLength: 46, withPad: " ", startingAt: 0)
                let stats = String(
                    format: "%6d 项   min %7.1fms   avg %7.1fms   max %7.1fms   %8.0f 项/秒",
                    count, minValue, avg, maxValue, rate
                )
                print("  \(label) \(stats)")
            }
            semaphore.signal()
        }

        semaphore.wait()
    }
}

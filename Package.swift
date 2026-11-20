// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pane",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "PaneApp", path: "Sources/PaneApp")
    ]
)

import Foundation

/// 本地文件系统读取（actor 隔离，避免阻塞主线程）
actor LocalFileSystem {
    static let shared = LocalFileSystem()
    private let fm = FileManager.default

    func contents(of url: URL, showHidden: Bool, sort: FileSort = FileSort()) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey, .typeIdentifierKey
        ]
        let urls = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for u in urls {
            let res = try u.resourceValues(forKeys: Set(keys))
            let isDir = res.isDirectory ?? false
            let isPackage = res.isPackage ?? false
            let isHidden = res.isHidden ?? u.lastPathComponent.hasPrefix(".")
            let size = res.fileSize.map(Int64.init)
            let kind = FileKind.for(
                isDirectory: isDir,
                isPackage: isPackage,
                typeIdentifier: res.typeIdentifier,
                name: u.lastPathComponent
            )
            items.append(FileItem(
                url: u,
                name: u.lastPathComponent,
                kind: kind,
                isDirectory: isDir,
                isPackage: isPackage,
                isHidden: isHidden,
                size: isDir ? nil : size,
                modificationDate: res.contentModificationDate
            ))
        }

        // 排序方式由调用方决定（菜单 / 表头），文件夹始终在前
        return sort.applied(to: items)
    }
}

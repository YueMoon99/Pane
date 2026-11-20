import AppKit

// 用 SF Symbol 渲染一枚 macOS 26 风格的占位 App 图标（1024×1024 PNG）
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/pane_icon_1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let inset: CGFloat = 64
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = size * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.42, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.36, green: 0.24, blue: 0.92, alpha: 1)
])
gradient?.draw(in: path, angle: -60)

let highlight = NSBezierPath(
    roundedRect: rect.insetBy(dx: 3, dy: 3),
    xRadius: radius - 3,
    yRadius: radius - 3
)
NSColor.white.withAlphaComponent(0.14).setStroke()
highlight.lineWidth = 6
highlight.stroke()

let config = NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

if let symbol = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let target = NSRect(
        x: (size - s.width) / 2,
        y: (size - s.height) / 2,
        width: s.width,
        height: s.height
    )
    symbol.draw(in: target)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outPath))
print(outPath)

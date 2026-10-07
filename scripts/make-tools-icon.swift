// Рисует значок «Инструментов» (Resources/ToolsIcon.icns): swift scripts/make-tools-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ToolsIcon.iconset")
try? FileManager.default.removeItem(at: folder)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func render(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(side)
    // Сетка значков macOS: тело ~82 % с отступом, скругление ~22 %.
    let body = NSRect(x: s * 0.09, y: s * 0.09, width: s * 0.82, height: s * 0.82)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowBlurRadius = s * 0.02
    shadow.set()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.20, green: 0.24, blue: 0.70, alpha: 1)])!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for side in sizes where side <= 512 {
    try render(side).write(to: folder.appendingPathComponent("icon_\(side)x\(side).png"))
    try render(side * 2).write(to: folder.appendingPathComponent("icon_\(side)x\(side)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", folder.path, "-o", "Resources/ToolsIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/ToolsIcon.icns" : "iconutil failed")

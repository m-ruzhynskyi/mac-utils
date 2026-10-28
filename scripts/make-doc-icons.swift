// Usage: swift scripts/make-doc-icons.swift <out-dir>
// Значки документов (вариант C макета .audit/doc-icons-design): лист с оттенком группы, цветной уголок, значок приложения,
// расширение цветом группы. Пишет <out-dir>/DocIcon-<ext>.icns — по одному на запись CFBundleDocumentTypes в Info.plist.
// Графика плоская (без градиентов, свечения и теней): 14 файлов вместе остаются в пределах пары мегабайт.
// Значок приложения — плоская копия scripts/make-app-icon.swift (та же геометрия). 16 и 32 pt — упрощённый рисунок
// без подписи (крупнее значок), как у системных значков.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Group {
    let tint: UInt32, fold: UInt32, edge: UInt32, ink: UInt32
}

// Токены DesignSystem: acc (документы), blue (видео), warn (звук).
let docs = Group(tint: 0xF5FBE3, fold: 0xC8F05A, edge: 0x9CC23A, ink: 0x3D6600)
let video = Group(tint: 0xEAF2FF, fold: 0x6EA8FF, edge: 0x4A86E0, ink: 0x1F6FDB)
let audio = Group(tint: 0xFFF5DF, fold: 0xF5B83D, edge: 0xD39A26, ink: 0x8A5300)

// Тот же список, что CFBundleTypeIconFile в Resources/Info.plist (сверяет scripts/check-doc-icons.sh).
let types: [(ext: String, group: Group)] = [
    ("frm", docs), ("txt", docs), ("rtf", docs), ("json", docs), ("xml", docs), ("csv", docs), ("log", docs),
    ("mp4", video), ("mov", video), ("m4v", video),
    ("mp3", audio), ("m4a", audio), ("wav", audio), ("aac", audio),
]

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-doc-icons.swift <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Геометрия листа в сетке 1024 (y вниз, как в макете).
struct Sheet {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, f: CGFloat
    static let large = Sheet(x: 196, y: 72, w: 632, h: 880, r: 44, f: 196)
    static let small = Sheet(x: 136, y: 40, w: 752, h: 944, r: 64, f: 250)
}

// Рисуем в координатах макета: контекст перевёрнут (y вниз).
func page(_ s: Sheet) -> CGPath {
    let p = CGMutablePath()
    let x2 = s.x + s.w, y2 = s.y + s.h
    p.move(to: CGPoint(x: s.x + s.r, y: s.y))
    p.addLine(to: CGPoint(x: x2 - s.f, y: s.y))
    p.addLine(to: CGPoint(x: x2, y: s.y + s.f))
    p.addLine(to: CGPoint(x: x2, y: y2 - s.r))
    p.addQuadCurve(to: CGPoint(x: x2 - s.r, y: y2), control: CGPoint(x: x2, y: y2))
    p.addLine(to: CGPoint(x: s.x + s.r, y: y2))
    p.addQuadCurve(to: CGPoint(x: s.x, y: y2 - s.r), control: CGPoint(x: s.x, y: y2))
    p.addLine(to: CGPoint(x: s.x, y: s.y + s.r))
    p.addQuadCurve(to: CGPoint(x: s.x + s.r, y: s.y), control: CGPoint(x: s.x, y: s.y))
    p.closeSubpath()
    return p
}

func fold(_ s: Sheet) -> CGPath {
    let p = CGMutablePath()
    let x2 = s.x + s.w, k = s.f * 0.2
    p.move(to: CGPoint(x: x2 - s.f, y: s.y))
    p.addLine(to: CGPoint(x: x2 - s.f, y: s.y + s.f - k))
    p.addQuadCurve(to: CGPoint(x: x2 - s.f + k, y: s.y + s.f), control: CGPoint(x: x2 - s.f, y: s.y + s.f))
    p.addLine(to: CGPoint(x: x2, y: s.y + s.f))
    p.closeSubpath()
    return p
}

/// Скруглённый прямоугольник с плавными углами — как `squircle` в make-app-icon.swift.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let c = min(radius * 1.28, min(r.width, r.height) / 2)
    let (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
    p.move(to: CGPoint(x: x0 + c, y: y0))
    p.addLine(to: CGPoint(x: x1 - c, y: y0))
    p.addCurve(to: CGPoint(x: x1, y: y0 + c), control1: CGPoint(x: x1 - c * 0.18, y: y0), control2: CGPoint(x: x1, y: y0 + c * 0.18))
    p.addLine(to: CGPoint(x: x1, y: y1 - c))
    p.addCurve(to: CGPoint(x: x1 - c, y: y1), control1: CGPoint(x: x1, y: y1 - c * 0.18), control2: CGPoint(x: x1 - c * 0.18, y: y1))
    p.addLine(to: CGPoint(x: x0 + c, y: y1))
    p.addCurve(to: CGPoint(x: x0, y: y1 - c), control1: CGPoint(x: x0 + c * 0.18, y: y1), control2: CGPoint(x: x0, y: y1 - c * 0.18))
    p.addLine(to: CGPoint(x: x0, y: y0 + c))
    p.addCurve(to: CGPoint(x: x0 + c, y: y0), control1: CGPoint(x: x0, y: y0 + c * 0.18), control2: CGPoint(x: x0 + c * 0.18, y: y0))
    p.closeSubpath()
    return p
}

/// Значок приложения плоско, в его сетке 1024 (y вверх, как в make-app-icon.swift): корпус, клавиша, лаймовый ⌘.
func drawAppMark(_ ctx: CGContext) {
    ctx.addPath(squircle(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185)); ctx.setFillColor(color(0x1B1E26)); ctx.fillPath()
    ctx.addPath(squircle(CGRect(x: 214, y: 236, width: 596, height: 588), radius: 112)); ctx.setFillColor(color(0x474D62)); ctx.fillPath()
    let face = CGRect(x: 250, y: 318, width: 524, height: 470)
    ctx.addPath(squircle(face, radius: 80)); ctx.setFillColor(color(0x2A2E3B)); ctx.fillPath()
    let lime = color(0xC8F05A)
    let half: CGFloat = 102, loop: CGFloat = 54, pin: CGFloat = 15
    let corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { CGPoint(x: face.midX + CGFloat($0.0) * half, y: face.midY + CGFloat($0.1) * half) }
    ctx.addRect(CGRect(x: face.midX - half, y: face.midY - half, width: half * 2, height: half * 2))
    ctx.setStrokeColor(lime); ctx.setLineWidth(40); ctx.setLineJoin(.round); ctx.strokePath()
    for p in corners {
        ctx.addEllipse(in: CGRect(x: p.x - loop, y: p.y - loop, width: loop * 2, height: loop * 2)); ctx.setFillColor(lime); ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: p.x - pin, y: p.y - pin, width: pin * 2, height: pin * 2)); ctx.setFillColor(color(0x5C6447)); ctx.fillPath()
    }
}

func boldFont(_ size: CGFloat) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
}

func render(ext: String, group: Group, pixels: Int, small: Bool) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let px = CGFloat(pixels), scale = px / 1024
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: px)
    ctx.scaleBy(x: scale, y: -scale)

    let s = small ? Sheet.small : Sheet.large
    let body = page(s)
    let line = max(1024 / px, 2.5)  // около 1 px на экране

    // Лист: ровная заливка оттенком группы, контур цветом группы.
    ctx.addPath(body); ctx.setFillColor(color(group.tint)); ctx.fillPath()
    ctx.addPath(body); ctx.setStrokeColor(color(group.edge, 0.75)); ctx.setLineWidth(line); ctx.strokePath()
    ctx.addPath(fold(s)); ctx.setFillColor(color(group.fold)); ctx.fillPath()
    ctx.addPath(fold(s)); ctx.setStrokeColor(color(group.edge)); ctx.setLineWidth(line); ctx.setLineJoin(.round); ctx.strokePath()

    // Значок приложения: его сетка 1024 с осью y вверх вписывается в рамку.
    let icon: CGFloat = small ? 600 : 400, centerY: CGFloat = small ? 560 : 452
    ctx.saveGState()
    ctx.translateBy(x: 512 - icon / 2, y: centerY + icon / 2)
    ctx.scaleBy(x: icon / 1024, y: -icon / 1024)
    drawAppMark(ctx)
    ctx.restoreGState()

    // Подпись: расширение заглавными, по центру, базовая линия 842.
    if !small {
        let text = ext.uppercased()
        let font = boldFont(text.count > 3 ? 116 : 132)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(group.ink),
            NSAttributedString.Key(kCTKernAttributeName as String): 2,
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        ctx.saveGState()
        ctx.translateBy(x: 512 - CGFloat(width) / 2, y: 842)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

/// Сбой генерации: текст — в stderr, код выхода 1 (build.sh с `set -e` останавливает сборку).
struct Failure: Error {
    let message: String
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure(message: "не создан \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure(message: "не записан \(url.path)") }
}

// Размеры iconset: pt × масштаб; 16 и 32 pt — упрощённый рисунок.
let reps: [(name: String, pixels: Int, small: Bool)] = [
    ("icon_16x16", 16, true), ("icon_16x16@2x", 32, true), ("icon_32x32", 32, true), ("icon_32x32@2x", 64, true),
    ("icon_128x128", 128, false), ("icon_128x128@2x", 256, false), ("icon_256x256", 256, false),
    ("icon_256x256@2x", 512, false), ("icon_512x512", 512, false), ("icon_512x512@2x", 1024, false),
]

/// Все значки; временная папка с iconset удаляется при любом выходе — и при ошибке (`defer` внутри функции).
func generate() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    let work = fm.temporaryDirectory.appendingPathComponent("mu-doc-icons-\(getpid())", isDirectory: true)
    defer { try? fm.removeItem(at: work) }

    for type in types {
        let set = work.appendingPathComponent("DocIcon-\(type.ext).iconset", isDirectory: true)
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        var cache: [String: CGImage] = [:]
        for rep in reps {
            let key = "\(rep.pixels)-\(rep.small)"
            let image = cache[key] ?? render(ext: type.ext, group: type.group, pixels: rep.pixels, small: rep.small)
            cache[key] = image
            try writePNG(image, to: set.appendingPathComponent("\(rep.name).png"))
        }
        let icns = outDir.appendingPathComponent("DocIcon-\(type.ext).icns")
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", set.path, "-o", icns.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else { throw Failure(message: "iconutil: \(type.ext)") }
    }
}

do {
    try generate()
    print("Значки документов: \(types.count) → \(outDir.path)")
} catch {
    let message = (error as? Failure)?.message ?? "\(error)"
    FileHandle.standardError.write("make-doc-icons: \(message)\n".data(using: .utf8)!)
    exit(1)
}

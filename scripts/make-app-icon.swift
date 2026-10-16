// Usage: swift scripts/make-app-icon.swift /tmp/AppIcon-1024.png, then build the .iconset with sips and iconutil (see the comment at the end).
import AppKit
import CoreGraphics

// Mac Utils app icon (Graphite): dark squircle, a raised keycap, lime ⌘ with a soft glow. 1024×1024 master.
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Rounded rect with continuous-looking corners (superellipse approximation through cubic curves).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.28 // extends the curve along the edge for a smoother, iOS-like corner
    let c = min(radius * k, min(r.width, r.height) / 2)
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

func linear(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor, rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    // CG origin is bottom-left: "top" is maxY.
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// 1. Body: macOS icon grid — 824 pt squircle centred, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(body, radius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x15171D)); ctx.fillPath()
ctx.restoreGState()
linear(ctx, bodyPath, top: color(0x2A2E39), bottom: color(0x0B0C10), rect: body)
// Hairline highlight on the upper edge of the body.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5), radius: 184))
ctx.setStrokeColor(color(0xFFFFFF, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

// 2. Keycap: side (depth) + top face. The bottom edge is thicker, so the key reads as raised.
let keySide = CGRect(x: 214, y: 236, width: 596, height: 588)
let keySidePath = squircle(keySide, radius: 112)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 40, color: color(0x000000, 0.55))
ctx.addPath(keySidePath); ctx.setFillColor(color(0x3B4052)); ctx.fillPath()
ctx.restoreGState()
linear(ctx, keySidePath, top: color(0x5A6177), bottom: color(0x343849), rect: keySide)

let face = CGRect(x: 250, y: 318, width: 524, height: 470)
let facePath = squircle(face, radius: 80)
linear(ctx, facePath, top: color(0x2F3341), bottom: color(0x252834), rect: face)
// Inner rim: light on top, dark at the bottom of the face.
ctx.saveGState()
ctx.addPath(facePath); ctx.clip()
ctx.addPath(squircle(face.insetBy(dx: 2, dy: 2), radius: 79))
ctx.setStrokeColor(color(0x000000, 0.35)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

// 3. ⌘ glyph in lime with a glow: a square between four loops, each loop a disc with a darker pin.
let lime = color(0xC8F05A)
let center = CGPoint(x: face.midX, y: face.midY)
let half: CGFloat = 102          // half side of the inner square (between loop centres)
let loopR: CGFloat = 54
let stroke: CGFloat = 40
let corners = [CGPoint(x: center.x - half, y: center.y - half), CGPoint(x: center.x + half, y: center.y - half),
               CGPoint(x: center.x + half, y: center.y + half), CGPoint(x: center.x - half, y: center.y + half)]

func glyph(_ ctx: CGContext) {
    let sq = CGMutablePath()
    sq.addRect(CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2))
    ctx.addPath(sq); ctx.setStrokeColor(lime); ctx.setLineWidth(stroke); ctx.setLineJoin(.round); ctx.strokePath()
    for p in corners {
        ctx.addEllipse(in: CGRect(x: p.x - loopR, y: p.y - loopR, width: loopR * 2, height: loopR * 2))
        ctx.setFillColor(lime); ctx.fillPath()
    }
}

// Glow: two blurred passes, then the crisp glyph on top.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: color(0xC8F05A, 0.55))
glyph(ctx)
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: color(0xD8FF6A, 0.6))
glyph(ctx)
ctx.restoreGState()
glyph(ctx)
// Pins in the loops.
for p in corners {
    let r: CGFloat = 15
    ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    ctx.setFillColor(color(0x5C6447)); ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

// Build Resources/AppIcon.icns from the master:
//   mkdir AppIcon.iconset; for s in 16 32 128 256 512; do
//     sips -z $s $s AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png; done
//   iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
//   sips -z 512 512 AppIcon-1024.png --out Resources/AppIcon.png

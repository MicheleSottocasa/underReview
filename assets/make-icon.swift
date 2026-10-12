// Renders the 1024 px app icon master: `swift assets/make-icon.swift assets/AppIcon.png`.
// `make icon` renders it and builds assets/AppIcon.icns in every size macOS needs.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS icon grid: 824 pt body centered on a 1024 canvas, continuous-corner rounded rect.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x4338CA))
ctx.fillPath()
ctx.restoreGState()

// Indigo → violet gradient with a soft top highlight.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x6366F1), color(0x4338CA), color(0x6D28D9)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Pull-request glyph (white): left branch with two commits, right branch merging back with an arrow.
let white = color(0xFFFFFF)
let stroke: CGFloat = 54, node: CGFloat = 62
ctx.setStrokeColor(white)
ctx.setFillColor(white)
ctx.setLineWidth(stroke)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let leftTop = CGPoint(x: 360, y: 730), leftBottom = CGPoint(x: 360, y: 300)
// The right branch's commit is the approval badge: the review is what lands the change.
let badge = CGRect(x: 640 - 128, y: 300 - 128, width: 256, height: 256)
let ring: CGFloat = 22
// Lines end under the node rings so their round caps never show inside the holes.
let tuck = node + stroke * 0.45

ctx.move(to: CGPoint(x: leftTop.x, y: leftTop.y - tuck))
ctx.addLine(to: CGPoint(x: leftBottom.x, y: leftBottom.y + tuck))
ctx.strokePath()

// Right branch: up from the badge, then a rounded turn left into the arrow head.
ctx.move(to: CGPoint(x: badge.midX, y: badge.maxY))
ctx.addLine(to: CGPoint(x: badge.midX, y: 600))
ctx.addArc(tangent1End: CGPoint(x: badge.midX, y: 730), tangent2End: CGPoint(x: 520, y: 730), radius: 110)
ctx.addLine(to: CGPoint(x: 500, y: 730))
ctx.strokePath()
ctx.move(to: CGPoint(x: 560, y: 800))
ctx.addLine(to: CGPoint(x: 490, y: 730))
ctx.addLine(to: CGPoint(x: 560, y: 660))
ctx.strokePath()

for point in [leftTop, leftBottom] {
    ctx.setLineWidth(stroke * 0.9)
    ctx.strokeEllipse(in: CGRect(x: point.x - node, y: point.y - node, width: node * 2, height: node * 2))
}

// Approval badge: white ring like the other commits, green disc, white check.
ctx.setFillColor(white)
ctx.fillEllipse(in: badge.insetBy(dx: -ring, dy: -ring))
let green = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x4ADE80), color(0x16A34A)] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: badge)
ctx.clip()
ctx.drawLinearGradient(green, start: CGPoint(x: badge.midX, y: badge.maxY), end: CGPoint(x: badge.midX, y: badge.minY), options: [])
ctx.restoreGState()
ctx.setStrokeColor(white)
ctx.setLineWidth(38)
ctx.move(to: CGPoint(x: badge.minX + 66, y: badge.midY + 2))
ctx.addLine(to: CGPoint(x: badge.midX - 16, y: badge.minY + 74))
ctx.addLine(to: CGPoint(x: badge.maxX - 58, y: badge.maxY - 74))
ctx.strokePath()

NSGraphicsContext.current = nil
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

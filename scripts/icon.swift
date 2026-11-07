// Draws Zefra's app icon: a dark tile, a fan of thin curved blades running from cool to warm.
// swift scripts/icon.swift <out.png> [size]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon_1024.png"
let size = args.count > 2 ? CGFloat(Double(args[2]) ?? 1024) : 1024
let px = Int(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12 * size / 1024), blur: 28 * size / 1024, color: color(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0x101114)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let wash = CGGradient(colorsSpace: space, colors: [color(0x1C1E22), color(0x0C0D10)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(wash, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// The blades: each a slim leaf that sweeps round the hub.
let center = CGPoint(x: 512, y: 512)
let blades = 7
let tints: [UInt32] = [0x7FC8E8, 0x83D0D6, 0x8FD8C6, 0xB7D3A0, 0xE6C27A, 0xEEA96C, 0xEE9A62]
for index in 0..<blades {
    let angle = CGFloat(index) / CGFloat(blades) * 2 * .pi
    var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: 62, y: 0), transform: t)
    blade.addCurve(to: CGPoint(x: 322, y: 118), control1: CGPoint(x: 150, y: -92), control2: CGPoint(x: 296, y: -44), transform: t)
    blade.addCurve(to: CGPoint(x: 62, y: 0), control1: CGPoint(x: 258, y: 58), control2: CGPoint(x: 160, y: 18), transform: t)
    blade.closeSubpath()
    _ = t; t = .identity
    ctx.addPath(blade)
    ctx.setFillColor(color(tints[index]))
    ctx.fillPath()
}
// The hub.
ctx.addEllipse(in: CGRect(x: center.x - 46, y: center.y - 46, width: 92, height: 92))
ctx.setFillColor(color(0xF1F1EF))
ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

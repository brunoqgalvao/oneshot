// Draws the Murmur app icon: a deep indigo squircle with a white waveform.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(red: 0.36, green: 0.29, blue: 0.98, alpha: 1).cgColor,
              NSColor(red: 0.09, green: 0.07, blue: 0.26, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// soft highlight
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX - 120, y: rect.maxY - 120), startRadius: 0,
                       endCenter: CGPoint(x: rect.midX - 120, y: rect.maxY - 120), endRadius: 560, options: [])

// waveform
let heights: [CGFloat] = [0.16, 0.30, 0.52, 0.34, 0.72, 0.95, 0.62, 0.80, 0.44, 0.58, 0.28, 0.14]
let barW: CGFloat = 34, gap: CGFloat = 24
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = size / 2 - total / 2
for h in heights {
    let bh = 420 * h
    let bar = CGRect(x: x, y: size / 2 - bh / 2, width: barW, height: bh)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    x += barW + gap
}
ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
ctx.fillPath()
ctx.restoreGState()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

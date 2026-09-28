// Draws the Oneshot app icon: an ink squircle with a waveform whose center bar is the "shot".
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [NSColor(red: 0.17, green: 0.16, blue: 0.19, alpha: 1).cgColor,
                                                 NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
// warm glow behind the shot
let glow = CGGradient(colorsSpace: space, colors: [NSColor(red: 1, green: 0.38, blue: 0.2, alpha: 0.38).cgColor,
                                                   NSColor(red: 1, green: 0.38, blue: 0.2, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: 330, options: [])

let heights: [CGFloat] = [0.14, 0.26, 0.40, 0.30, 0.52, 1.0, 0.52, 0.30, 0.40, 0.26, 0.14]
let barW: CGFloat = 40, gap: CGFloat = 26
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = size / 2 - total / 2
for (i, h) in heights.enumerated() {
    let bh = 470 * h
    let bar = CGRect(x: x, y: size / 2 - bh / 2, width: barW, height: bh)
    let p = CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    if i == heights.count / 2 {
        let shot = CGGradient(colorsSpace: space, colors: [NSColor(red: 1, green: 0.48, blue: 0.26, alpha: 1).cgColor,
                                                           NSColor(red: 0.89, green: 0.22, blue: 0.12, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shot, start: CGPoint(x: bar.midX, y: bar.maxY), end: CGPoint(x: bar.midX, y: bar.minY), options: [])
    } else {
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.93).cgColor); ctx.fill(bar)
    }
    ctx.restoreGState()
    x += barW + gap
}
ctx.restoreGState()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

// Draws the icon's foreground layer: swiftc -o /tmp/gen scripts/gen-icon.swift && /tmp/gen scripts/Camdeck.icon/Assets/lens.png
import AppKit
let n = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) { c.setFill(); NSBezierPath(ovalIn: NSRect(x: cx-r, y: cy-r, width: 2*r, height: 2*r)).fill() }
// disc: soft white-to-silver gradient so the glass pass has something to catch
let lens = NSBezierPath(ovalIn: NSRect(x: 512-300, y: 494-300, width: 600, height: 600))
NSGradient(starting: .white, ending: NSColor(srgbRed: 0.80, green: 0.81, blue: 0.85, alpha: 1))!.draw(in: lens, angle: -90)
disc(786, 768, 48, NSColor(srgbRed: 1, green: 0.77, blue: 0, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

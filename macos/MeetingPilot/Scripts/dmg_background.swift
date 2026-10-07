// Draws the DMG window background: a light canvas with a curved arrow from the
// app icon to the Applications link. Usage: swift dmg_background.swift OUT.png SCALE
import AppKit

let width: CGFloat = 660
let height: CGFloat = 400
let args = CommandLine.arguments
let outPath = args[1]
let scale = CGFloat(Double(args[2]) ?? 1)

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor(srgbRed: 0.941, green: 0.941, blue: 0.941, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Finder places icon centers at (165, 190) and (495, 190) from the top-left.
func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: height - y) }

let arrow = NSBezierPath()
arrow.move(to: p(258, 200))
arrow.curve(to: p(318, 182), controlPoint1: p(276, 178), controlPoint2: p(302, 166))
arrow.curve(to: p(410, 224), controlPoint1: p(338, 204), controlPoint2: p(352, 236))
arrow.move(to: p(392, 205))
arrow.line(to: p(412, 223))
arrow.line(to: p(390, 240))
arrow.lineWidth = 9
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(srgbRed: 0.80, green: 0.38, blue: 0.34, alpha: 1).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))

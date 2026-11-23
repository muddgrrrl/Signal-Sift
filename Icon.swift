import AppKit

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
let frame = NSRect(x: 72, y: 72, width: 880, height: 880)
let bezel = NSBezierPath(roundedRect: frame, xRadius: 222, yRadius: 222)
let dark = NSColor(srgbRed: 0.05, green: 0.11, blue: 0.17, alpha: 1)
let teal = NSColor(srgbRed: 0.48, green: 0.94, blue: 0.82, alpha: 1)
let blue = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.37, alpha: 1)
NSGradient(starting: dark, ending: blue)?.draw(in: bezel, angle: 32)
teal.withAlphaComponent(0.55).setStroke()
bezel.lineWidth = 10
bezel.stroke()
let trace = NSBezierPath()
trace.move(to: NSPoint(x: 222, y: 512))
for (x, y) in [(340, 512), (430, 674), (536, 347), (629, 611), (692, 512), (802, 512)] {
    trace.line(to: NSPoint(x: x, y: y))
}
trace.lineWidth = 58
trace.lineJoinStyle = .round
trace.lineCapStyle = .round
teal.setStroke()
trace.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]))

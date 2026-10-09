import AppKit
let root = CommandLine.arguments[1]
let dir = URL(fileURLWithPath: root).appendingPathComponent("Lilt.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let rect = NSRect(x: 62,y: 62,width: 900,height: 900)
        NSColor(calibratedRed: 0.10, green: 0.38, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 208, yRadius: 208).fill()
        let gradient = NSGradient(starting: NSColor.white.withAlphaComponent(0.17), ending: NSColor.clear)!
        gradient.draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: 205, yRadius: 205), angle: -60)
        let path = NSBezierPath(); path.lineWidth = 62; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 255,y: 445))
        path.curve(to: NSPoint(x: 455,y: 450), controlPoint1: NSPoint(x: 370,y: 335), controlPoint2: NSPoint(x: 365,y: 335))
        path.line(to: NSPoint(x: 574,y: 615))
        path.curve(to: NSPoint(x: 773,y: 620), controlPoint1: NSPoint(x: 665,y: 735), controlPoint2: NSPoint(x: 674,y: 735))
        NSColor(calibratedWhite: 0.97, alpha: 0.96).setStroke(); path.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x:0,y:0,width:pixels,height:pixels))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(filename))
    }
}

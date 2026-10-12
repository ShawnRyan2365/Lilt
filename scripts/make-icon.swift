import AppKit
import CoreText

// One set of vector paths generates the app icon, transparent marks and SVG masters.
// Coordinates use a top-left origin on a 1024-point canvas.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build")
let brand = CommandLine.arguments.contains("--brand-assets")
let dir = root.appendingPathComponent("Lilt.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

enum Segment {
    case move(CGFloat, CGFloat), line(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat), close
}
let stem: [Segment] = [
    .move(409, 254), .curve(377, 254, 351, 277, 344, 310),
    .line(292, 564), .curve(282, 615, 296, 659, 331, 689),
    .line(459, 566), .line(507, 332),
    .curve(516, 290, 486, 254, 445, 254), .close
]
let foot: [Segment] = [
    .move(355, 710), .curve(391, 732, 435, 738, 481, 724),
    .line(712, 653), .curve(750, 641, 771, 602, 759, 565),
    .curve(748, 528, 710, 507, 672, 519),
    .line(475, 580), .close
]
func path(_ segments: [Segment]) -> CGPath {
    let p = CGMutablePath()
    for s in segments {
        switch s {
        case let .move(x,y): p.move(to: CGPoint(x:x,y:y))
        case let .line(x,y): p.addLine(to: CGPoint(x:x,y:y))
        case let .curve(a,b,c,d,x,y): p.addCurve(to: CGPoint(x:x,y:y), control1: CGPoint(x:a,y:b), control2: CGPoint(x:c,y:d))
        case .close: p.closeSubpath()
        }
    }
    return p
}
func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
}
func fill(_ p: CGPath, _ c: CGColor, _ ctx: CGContext) { ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath() }
func gradient(_ p: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint, _ ctx: CGContext) {
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func mark(_ ctx: CGContext, primary: CGColor, secondary: CGColor) {
    fill(path(stem), primary, ctx); fill(path(foot), secondary, ctx)
}
func icon(_ ctx: CGContext) {
    // Core Graphics shadows use device space; scale them explicitly for 16–1024 px exports.
    let shadowScale = abs(ctx.ctm.a)
    let tile = CGPath(roundedRect: CGRect(x: 62, y: 62, width: 900, height: 900), cornerWidth: 204, cornerHeight: 204, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * shadowScale), blur: 20 * shadowScale, color: color(0x09281F).copy(alpha: 0.20))
    fill(tile, color(0x123E33), ctx); ctx.restoreGState()
    gradient(tile, colors: [color(0x245D4D), color(0x0B3028)], from: CGPoint(x:180,y:80), to: CGPoint(x:750,y:950), ctx)
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    ctx.addPath(CGPath(roundedRect: CGRect(x:64,y:64,width:896,height:896), cornerWidth:202, cornerHeight:202, transform:nil))
    ctx.setStrokeColor(color(0xE3FFEE).copy(alpha:0.19)!); ctx.setLineWidth(2); ctx.strokePath(); ctx.restoreGState()
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width:0,height:-9 * shadowScale), blur:14 * shadowScale, color: color(0x001B13).copy(alpha:0.24))
    mark(ctx, primary: color(0xF2F8E9), secondary: color(0xB6ECC0)); ctx.restoreGState()
    gradient(path(stem), colors: [color(0xFAFCEE),color(0xDFEEDC)], from: CGPoint(x:350,y:250), to: CGPoint(x:480,y:700), ctx)
    gradient(path(foot), colors: [color(0xCDF6C9),color(0x8DDCAC)], from: CGPoint(x:380,y:580), to: CGPoint(x:760,y:720), ctx)
}
func png(width: Int, height: Int, logicalWidth: CGFloat, logicalHeight: CGFloat, to url: URL, draw: (CGContext)->Void) throws {
    let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x:0,y:CGFloat(height)); ctx.scaleBy(x:CGFloat(width)/logicalWidth,y: -CGFloat(height)/logicalHeight)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage:ctx.makeImage()!)
    try rep.representation(using:.png,properties:[:])!.write(to:url)
}
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        try png(width:pixels,height:pixels,logicalWidth:1024,logicalHeight:1024,
                to:dir.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"),draw:icon)
    }
}

// Export a black template for the menu bar. It uses the exact same silhouette as the icon.
for scale in [1,2] {
    try png(width:18*scale,height:18*scale,logicalWidth:560,logicalHeight:560,
            to:root.appendingPathComponent("LiltMenu\(scale == 2 ? "@2x" : "").png")) { ctx in
        ctx.translateBy(x:-245,y:-220)
        mark(ctx,primary:color(0x000000),secondary:color(0x000000))
    }
}

if brand {
    let out = URL(fileURLWithPath:"assets/brand")
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    func svgPath(_ p: CGPath) -> String {
        var d = ""
        func n(_ x: CGFloat) -> String { String(format:"%.2f",Double(x)) }
        p.applyWithBlock { ptr in
            let e = ptr.pointee, v = e.points
            switch e.type {
            case .moveToPoint: d += "M\(n(v[0].x)) \(n(v[0].y))"
            case .addLineToPoint: d += "L\(n(v[0].x)) \(n(v[0].y))"
            case .addQuadCurveToPoint: d += "Q\(n(v[0].x)) \(n(v[0].y)) \(n(v[1].x)) \(n(v[1].y))"
            case .addCurveToPoint: d += "C\(n(v[0].x)) \(n(v[0].y)) \(n(v[1].x)) \(n(v[1].y)) \(n(v[2].x)) \(n(v[2].y))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }
    func svg(_ content:String, viewBox:String, name:String) throws {
        let s = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\" role=\"img\" aria-label=\"Lilt\"><title>Lilt</title>\(content)</svg>\n"
        try s.write(to:out.appendingPathComponent(name),atomically:true,encoding:.utf8)
    }
    let shapes = "<path d=\"\(svgPath(path(stem)))\"/><path d=\"\(svgPath(path(foot)))\"/>"
    try svg("<g fill=\"#194D3E\">\(shapes)</g>",viewBox:"224 200 600 600",name:"lilt-mark.svg")
    try svg("<g fill=\"#F2F8E9\">\(shapes)</g>",viewBox:"224 200 600 600",name:"lilt-mark-light.svg")
    try png(width:1024,height:1024,logicalWidth:1024,logicalHeight:1024,to:out.appendingPathComponent("lilt-icon.png"),draw:icon)
    try png(width:1024,height:1024,logicalWidth:600,logicalHeight:600,to:out.appendingPathComponent("lilt-mark.png")) { ctx in
        ctx.translateBy(x:-224,y:-200); mark(ctx,primary:color(0x194D3E),secondary:color(0x194D3E))
    }
    // Convert the wordmark into outlines so SVG consumers need no installed font.
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString,240,nil)
    let letters = Array("Lilt".utf16)
    var glyphs = [CGGlyph](repeating:0,count:letters.count)
    CTFontGetGlyphsForCharacters(font,letters,&glyphs,letters.count)
    var advances = [CGSize](repeating:.zero,count:letters.count)
    CTFontGetAdvancesForGlyphs(font,.horizontal,glyphs,&advances,letters.count)
    let word = CGMutablePath(); var x:CGFloat = 390
    for (index,glyph) in glyphs.enumerated() {
        if let p = CTFontCreatePathForGlyph(font,glyph,nil) {
            word.addPath(p,transform:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:x,ty:280))
        }
        x += advances[index].width - 7
    }
    let wordPaths = "<g transform=\"translate(-55 -25) scale(.44)\">\(shapes)</g><path d=\"\(svgPath(word))\"/>"
    try svg("<g fill=\"#194D3E\">\(wordPaths)</g>",viewBox:"0 0 770 390",name:"lilt-logo.svg")
    try svg("<g fill=\"#F2F8E9\">\(wordPaths)</g>",viewBox:"0 0 770 390",name:"lilt-logo-light.svg")
    func drawLogo(_ ctx:CGContext, ink:CGColor) {
        ctx.saveGState(); ctx.translateBy(x:-55,y:-25); ctx.scaleBy(x:0.44,y:0.44)
        mark(ctx,primary:ink,secondary:ink); ctx.restoreGState(); fill(word,ink,ctx)
    }
    try png(width:1540,height:780,logicalWidth:770,logicalHeight:390,to:out.appendingPathComponent("lilt-logo.png")) { drawLogo($0,ink:color(0x194D3E)) }
    try png(width:1600,height:900,logicalWidth:1600,logicalHeight:900,to:out.appendingPathComponent("brand-preview.png")) { ctx in
        ctx.setFillColor(color(0xF2F3EC)); ctx.fill(CGRect(x:0,y:0,width:1600,height:900))
        ctx.saveGState(); ctx.translateBy(x:90,y:95); ctx.scaleBy(x:0.62,y:0.62); icon(ctx); ctx.restoreGState()
        ctx.saveGState(); ctx.translateBy(x:810,y:165); ctx.scaleBy(x:0.85,y:0.85); drawLogo(ctx,ink:color(0x194D3E)); ctx.restoreGState()
        ctx.setFillColor(color(0x123E33)); ctx.fill(CGRect(x:0,y:710,width:1600,height:190))
        for (index,size) in [128.0,64.0,32.0,16.0].enumerated() {
            ctx.saveGState(); ctx.translateBy(x:180 + CGFloat(index)*155,y:805-size/2); ctx.scaleBy(x:size/1024,y:size/1024); icon(ctx); ctx.restoreGState()
        }
        ctx.saveGState(); ctx.translateBy(x:960,y:755); ctx.scaleBy(x:0.36,y:0.36); drawLogo(ctx,ink:color(0xF2F8E9)); ctx.restoreGState()
    }
    print("Brand assets: \(out.path)")
}
print("Icon set: \(dir.path)")

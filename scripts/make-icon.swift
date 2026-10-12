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
// A broad curved lobe repeated four times; the openings leave a quiet central aperture.
let lobe: [Segment] = [
    .move(-115, -5),
    .curve(-175, -50, -175, -145, -112, -199),
    .curve(-30, -270, 93, -236, 139, -151),
    .curve(66, -175, 12, -148, -22, -96),
    .curve(-46, -57, -79, -29, -115, -5), .close
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
func lobes() -> [CGPath] {
    (0..<4).map { index in
        var transform = CGAffineTransform(translationX:512,y:512)
            .scaledBy(x:1.16,y:1.16).rotated(by:CGFloat(index) * .pi / 2)
            .translatedBy(x:0,y:-21)
        return path(lobe).copy(using:&transform)!
    }
}
func mark(_ ctx: CGContext, primary: CGColor) {
    for p in lobes() { fill(p,primary,ctx) }
}
func icon(_ ctx: CGContext, dark: Bool = false) {
    let shadowScale = abs(ctx.ctm.a)
    let tile = CGPath(roundedRect: CGRect(x:62,y:62,width:900,height:900),cornerWidth:204,cornerHeight:204,transform:nil)
    ctx.saveGState()
    ctx.setShadow(offset:CGSize(width:0,height:-10 * shadowScale),blur:16 * shadowScale,color:color(0x000000).copy(alpha:0.16))
    fill(tile,color(dark ? 0x181818 : 0xFAFAFA),ctx); ctx.restoreGState()
    ctx.addPath(tile); ctx.setStrokeColor(color(dark ? 0x383838 : 0xDEDEDE)); ctx.setLineWidth(1.5); ctx.strokePath()
    mark(ctx,primary:color(dark ? 0xF5F5F5 : 0x141414))
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
                to:dir.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"),draw:{ icon($0) })
    }
}

// Export a black template for the menu bar. It uses the exact same silhouette as the icon.
for scale in [1,2] {
    try png(width:18*scale,height:18*scale,logicalWidth:660,logicalHeight:660,
            to:root.appendingPathComponent("LiltMenu\(scale == 2 ? "@2x" : "").png")) { ctx in
        ctx.translateBy(x:-182,y:-182)
        mark(ctx,primary:color(0x000000))
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
    let shapes = lobes().map { "<path d=\"\(svgPath($0))\"/>" }.joined()
    try svg("<g fill=\"#141414\">\(shapes)</g>",viewBox:"162 162 700 700",name:"lilt-mark.svg")
    try svg("<g fill=\"#F5F5F5\">\(shapes)</g>",viewBox:"162 162 700 700",name:"lilt-mark-light.svg")
    try png(width:1024,height:1024,logicalWidth:1024,logicalHeight:1024,to:out.appendingPathComponent("lilt-icon.png"),draw:{ icon($0) })
    try png(width:1024,height:1024,logicalWidth:1024,logicalHeight:1024,to:out.appendingPathComponent("lilt-icon-dark.png")) { icon($0,dark:true) }
    try png(width:1024,height:1024,logicalWidth:700,logicalHeight:700,to:out.appendingPathComponent("lilt-mark.png")) { ctx in
        ctx.translateBy(x:-162,y:-162); mark(ctx,primary:color(0x141414))
    }
    // Convert the wordmark into outlines so SVG consumers need no installed font.
    let font = CTFontCreateWithName("HelveticaNeue" as CFString,240,nil)
    let letters = Array("Lilt".utf16)
    var glyphs = [CGGlyph](repeating:0,count:letters.count)
    CTFontGetGlyphsForCharacters(font,letters,&glyphs,letters.count)
    var advances = [CGSize](repeating:.zero,count:letters.count)
    CTFontGetAdvancesForGlyphs(font,.horizontal,glyphs,&advances,letters.count)
    let word = CGMutablePath(); var x:CGFloat = 380
    for (index,glyph) in glyphs.enumerated() {
        if let p = CTFontCreatePathForGlyph(font,glyph,nil) {
            word.addPath(p,transform:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:x,ty:280))
        }
        x += advances[index].width - 7
    }
    let wordPaths = "<g transform=\"translate(-20 0) scale(.38)\">\(shapes)</g><path d=\"\(svgPath(word))\"/>"
    try svg("<g fill=\"#141414\">\(wordPaths)</g>",viewBox:"0 0 770 390",name:"lilt-logo.svg")
    try svg("<g fill=\"#F5F5F5\">\(wordPaths)</g>",viewBox:"0 0 770 390",name:"lilt-logo-light.svg")
    func drawLogo(_ ctx:CGContext, ink:CGColor) {
        ctx.saveGState(); ctx.translateBy(x:-20,y:0); ctx.scaleBy(x:0.38,y:0.38)
        mark(ctx,primary:ink); ctx.restoreGState(); fill(word,ink,ctx)
    }
    try png(width:1540,height:780,logicalWidth:770,logicalHeight:390,to:out.appendingPathComponent("lilt-logo.png")) { drawLogo($0,ink:color(0x141414)) }
    try png(width:1600,height:900,logicalWidth:1600,logicalHeight:900,to:out.appendingPathComponent("brand-preview.png")) { ctx in
        ctx.setFillColor(color(0xF5F5F5)); ctx.fill(CGRect(x:0,y:0,width:1600,height:900))
        ctx.saveGState(); ctx.translateBy(x:90,y:95); ctx.scaleBy(x:0.62,y:0.62); icon(ctx); ctx.restoreGState()
        ctx.saveGState(); ctx.translateBy(x:810,y:165); ctx.scaleBy(x:0.85,y:0.85); drawLogo(ctx,ink:color(0x141414)); ctx.restoreGState()
        ctx.setFillColor(color(0x141414)); ctx.fill(CGRect(x:0,y:710,width:1600,height:190))
        for (index,size) in [128.0,64.0,32.0,16.0].enumerated() {
            ctx.saveGState(); ctx.translateBy(x:180 + CGFloat(index)*155,y:805-size/2); ctx.scaleBy(x:size/1024,y:size/1024); icon(ctx); ctx.restoreGState()
        }
        ctx.saveGState(); ctx.translateBy(x:960,y:755); ctx.scaleBy(x:0.36,y:0.36); drawLogo(ctx,ink:color(0xF5F5F5)); ctx.restoreGState()
    }
    print("Brand assets: \(out.path)")
}
print("Icon set: \(dir.path)")

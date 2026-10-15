import Cocoa

let cs = CGColorSpaceCreateDeviceRGB()
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: rect, cornerWidth: 188, cornerHeight: 188, transform: nil)

func render(_ name: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    // тень плитки + заливка
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: col(0, 0, 0, 0.5))
    ctx.addPath(shape); ctx.setFillColor(col(0.05, 0.05, 0.1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    draw(ctx)
    // стеклянный блик
    let gloss = CGGradient(colorsSpace: cs, colors: [col(1, 1, 1, 0.20), col(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(col(1, 1, 1, 0.18)); ctx.setLineWidth(3); ctx.strokePath()
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
}

func blob(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: [CGFloat], _ a: CGFloat = 0.95) {
    let grad = CGGradient(colorsSpace: cs, colors: [col(c[0], c[1], c[2], a), col(c[0], c[1], c[2], 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}

func micPath(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> (body: CGPath, strokes: CGPath) {
    let body = CGPath(roundedRect: CGRect(x: cx - 75 * s, y: cy - 10 * s, width: 150 * s, height: 270 * s), cornerWidth: 75 * s, cornerHeight: 75 * s, transform: nil)
    let st = CGMutablePath()
    st.addArc(center: CGPoint(x: cx, y: cy + 70 * s), radius: 130 * s, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    st.move(to: CGPoint(x: cx, y: cy - 60 * s)); st.addLine(to: CGPoint(x: cx, y: cy - 130 * s))
    st.move(to: CGPoint(x: cx - 72 * s, y: cy - 130 * s)); st.addLine(to: CGPoint(x: cx + 72 * s, y: cy - 130 * s))
    return (body, st)
}

func drawMic(_ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat, _ fill: CGColor, glow: CGColor?) {
    let m = micPath(cx, cy, s)
    ctx.saveGState()
    if let g = glow { ctx.setShadow(offset: .zero, blur: 32, color: g) }
    ctx.addPath(m.body); ctx.setFillColor(fill); ctx.fillPath()
    ctx.addPath(m.strokes); ctx.setStrokeColor(fill); ctx.setLineWidth(30 * s); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
}

// A — шар Siri на тёмном фоне
render("icon/variant_A.png") { ctx in
    let bg = CGGradient(colorsSpace: cs, colors: [col(0.08, 0.06, 0.2), col(0.01, 0.01, 0.05)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.setBlendMode(.plusLighter)
    blob(ctx, 512, 512, 430, [0.55, 0.25, 1], 0.45)   // ореол
    ctx.setBlendMode(.normal)
    let c = CGPoint(x: 512, y: 512), r: CGFloat = 270
    let orb = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    ctx.saveGState(); ctx.addPath(orb); ctx.clip()
    let base = CGGradient(colorsSpace: cs, colors: [col(0.16, 0.12, 0.3), col(0.02, 0.02, 0.07)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(base, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    ctx.setBlendMode(.plusLighter)
    blob(ctx, 420, 600, 260, [1, 0.3, 0.55]); blob(ctx, 620, 430, 260, [1, 0.65, 0.2])
    blob(ctx, 600, 640, 240, [0.55, 0.3, 1]); blob(ctx, 400, 400, 230, [0.15, 0.8, 1])
    blob(ctx, 512, 512, 150, [1, 0.85, 1], 0.8)
    ctx.setBlendMode(.normal)
    let hl = CGGradient(colorsSpace: cs, colors: [col(1, 1, 1, 0.55), col(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 780), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()
    ctx.addPath(orb); ctx.setStrokeColor(col(1, 1, 1, 0.45)); ctx.setLineWidth(4); ctx.strokePath()
}

// B — яркий градиент и белые столбики-голос
render("icon/variant_B.png") { ctx in
    let bg = CGGradient(colorsSpace: cs, colors: [col(0.45, 0.2, 0.98), col(0.98, 0.15, 0.55), col(1, 0.55, 0.2)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    let hs: [CGFloat] = [150, 270, 400, 520, 640, 520, 400, 270, 150]
    let w: CGFloat = 52, gap: CGFloat = 32
    let total = CGFloat(hs.count) * w + CGFloat(hs.count - 1) * gap
    var x = 512 - total / 2
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: col(0.3, 0, 0.3, 0.45))
    for h in hs {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 512 - h / 2, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
        ctx.setFillColor(col(1, 1, 1)); ctx.fillPath()
        x += w + gap
    }
    ctx.restoreGState()
}

// C — светлое стекло и цветной микрофон
render("icon/variant_C.png") { ctx in
    let bg = CGGradient(colorsSpace: cs, colors: [col(0.97, 0.95, 1), col(0.80, 0.78, 0.98)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    blob(ctx, 300, 300, 420, [1, 0.5, 0.75], 0.55); blob(ctx, 740, 340, 380, [1, 0.75, 0.45], 0.5); blob(ctx, 560, 760, 420, [0.55, 0.6, 1], 0.55)
    // микрофон: градиент через маску
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: col(0.35, 0.15, 0.7, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawMic(ctx, 512, 500, 1.2, col(1, 1, 1), glow: nil)
    ctx.setBlendMode(.sourceIn)
    let mg = CGGradient(colorsSpace: cs, colors: [col(1, 0.3, 0.55), col(0.5, 0.25, 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(mg, start: CGPoint(x: 330, y: 850), end: CGPoint(x: 700, y: 330), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// D — неоновые кольца-пульс и микрофон
render("icon/variant_D.png") { ctx in
    let bg = CGGradient(colorsSpace: cs, colors: [col(0.10, 0.04, 0.2), col(0.01, 0.01, 0.04)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 620, options: [])
    let cols: [CGColor] = [col(1, 0.35, 0.6), col(1, 0.65, 0.25), col(0.6, 0.4, 1), col(0.2, 0.8, 1)]
    ctx.setBlendMode(.plusLighter)
    for i in 0..<4 {
        let r = 190 + CGFloat(i) * 62
        let a = 0.95 - CGFloat(i) * 0.18
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26, color: cols[i])
        ctx.setStrokeColor(cols[i].copy(alpha: a)!); ctx.setLineWidth(12 - CGFloat(i) * 2)
        ctx.strokeEllipse(in: CGRect(x: 512 - r, y: 512 - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
    }
    ctx.setBlendMode(.normal)
    blob(ctx, 512, 512, 180, [0.6, 0.3, 1], 0.6)
    drawMic(ctx, 512, 500, 0.78, col(1, 1, 1), glow: col(0.7, 0.4, 1))
}

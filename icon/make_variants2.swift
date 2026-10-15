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


func glowStroke(_ ctx: CGContext, _ path: CGPath, _ c: [CGFloat], width: CGFloat) {
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for (wm, a) in [(5.0, 0.10), (3.0, 0.16), (1.8, 0.30), (1.0, 0.95)] {
        ctx.addPath(path); ctx.setStrokeColor(col(c[0], c[1], c[2], CGFloat(a))); ctx.setLineWidth(width * CGFloat(wm)); ctx.strokePath()
    }
}
func wave(_ x0: CGFloat, _ x1: CGFloat, _ cy: CGFloat, amp: CGFloat, freq: CGFloat, phase: CGFloat) -> CGPath {
    let p = CGMutablePath(); var x = x0
    while x <= x1 {
        let n = (x - x0) / (x1 - x0)
        let env = pow(sin(.pi * n), 2)
        let y = cy + amp * env * sin(n * freq * 2 * .pi + phase)
        x == x0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y)); x += 3
    }
    return p
}
func darkBG(_ ctx: CGContext, top: CGColor = col(0.07, 0.07, 0.10), bottom: CGColor = col(0, 0, 0)) {
    let bg = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
}

// E — как иконка Siri на iOS: чёрный фон и светящиеся ленты-волны
render("icon/variant2_E.png") { ctx in
    darkBG(ctx)
    ctx.setBlendMode(.plusLighter)
    blob(ctx, 512, 512, 460, [0.3, 0.2, 0.9], 0.30)
    let ribbons: [([CGFloat], CGFloat, CGFloat, CGFloat)] = [
        ([0.15, 0.55, 1.0], 250, 1.0, 0.0), ([1.0, 0.25, 0.7], 220, 1.5, 1.6),
        ([0.55, 0.35, 1.0], 190, 2.0, 3.1), ([0.2, 0.9, 1.0], 150, 2.5, 4.4), ([1, 1, 1], 90, 1.2, 0.6)]
    for r in ribbons { glowStroke(ctx, wave(130, 894, 512, amp: r.1, freq: r.2, phase: r.3), r.0, width: 9) }
    ctx.setBlendMode(.normal)
}

// F — как сфера Siri на macOS: стеклянный шар с вихрями света внутри
render("icon/variant2_F.png") { ctx in
    darkBG(ctx)
    let c = CGPoint(x: 512, y: 512), r: CGFloat = 300
    let orb = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    ctx.setBlendMode(.plusLighter); blob(ctx, 512, 512, 470, [0.25, 0.3, 1], 0.28); ctx.setBlendMode(.normal)
    ctx.saveGState(); ctx.addPath(orb); ctx.clip()
    let base = CGGradient(colorsSpace: cs, colors: [col(0.05, 0.05, 0.12), col(0, 0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(base, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    ctx.setBlendMode(.plusLighter)
    let cols: [[CGFloat]] = [[0.2, 0.6, 1], [1, 0.3, 0.75], [0.6, 0.4, 1], [0.3, 0.95, 1], [1, 0.8, 0.9]]
    for i in 0..<5 {
        let k = CGFloat(i)
        let p = CGMutablePath()
        let rot = k * .pi / 5 + 0.2
        for s in 0...160 {
            let t = CGFloat(s) / 160 * 2 * .pi
            let rx: CGFloat = 235, ry: CGFloat = 70 + 8 * k
            let x = rx * cos(t), y = ry * sin(t)
            let pt = CGPoint(x: c.x + x * cos(rot) - y * sin(rot), y: c.y + x * sin(rot) + y * cos(rot))
            s == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        glowStroke(ctx, p, cols[i], width: 6)
    }
    blob(ctx, 512, 512, 120, [1, 1, 1], 0.55)
    ctx.setBlendMode(.normal)
    let hl = CGGradient(colorsSpace: cs, colors: [col(1, 1, 1, 0.35), col(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 810), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()
    ctx.addPath(orb); ctx.setStrokeColor(col(1, 1, 1, 0.5)); ctx.setLineWidth(4); ctx.strokePath()
}

// G — кольцо в цветах Siri со свечением и микрофоном
render("icon/variant2_G.png") { ctx in
    darkBG(ctx, top: col(0.05, 0.05, 0.09), bottom: col(0, 0, 0))
    let stops: [[CGFloat]] = [[1, 0.3, 0.65], [1, 0.65, 0.2], [0.6, 0.35, 1], [0.2, 0.55, 1], [0.25, 0.95, 1], [1, 0.3, 0.65]]
    func ringColor(_ f: CGFloat) -> [CGFloat] {
        let x = f * CGFloat(stops.count - 1); let i = min(stops.count - 2, Int(x)); let t = x - CGFloat(i)
        return (0..<3).map { stops[i][$0] * (1 - t) + stops[i + 1][$0] * t }
    }
    let R: CGFloat = 255
    ctx.setBlendMode(.plusLighter)
    for (w, a) in [(150.0, 0.05), (100.0, 0.08), (64.0, 0.16), (34.0, 1.0)] {
        for s in 0..<180 {
            let t0 = CGFloat(s) / 180 * 2 * .pi - .pi / 2, t1 = CGFloat(s + 1) / 180 * 2 * .pi - .pi / 2
            let c = ringColor(CGFloat(s) / 180)
            ctx.setBlendMode(w < 40 ? .normal : .plusLighter)
            ctx.setStrokeColor(col(c[0], c[1], c[2], CGFloat(a)))
            ctx.setLineWidth(CGFloat(w)); ctx.setLineCap(.round)
            ctx.addArc(center: CGPoint(x: 512, y: 512), radius: R, startAngle: t0, endAngle: t1 + 0.02, clockwise: false)
            ctx.strokePath()
        }
    }
    ctx.setBlendMode(.normal)
    blob(ctx, 512, 512, 190, [0.5, 0.3, 1], 0.35)
    drawMic(ctx, 512, 470, 0.62, col(1, 1, 1), glow: col(0.7, 0.5, 1))
}

// H — сфера Siri, через которую проходят цветные волны
render("icon/variant2_H.png") { ctx in
    darkBG(ctx, top: col(0.10, 0.06, 0.20), bottom: col(0, 0, 0.02))
    let c = CGPoint(x: 512, y: 512), r: CGFloat = 250
    let orb = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    ctx.setBlendMode(.plusLighter); blob(ctx, 512, 512, 430, [0.55, 0.3, 1], 0.5); ctx.setBlendMode(.normal)
    ctx.saveGState(); ctx.addPath(orb); ctx.clip()
    let base = CGGradient(colorsSpace: cs, colors: [col(0.2, 0.12, 0.45), col(0.02, 0.02, 0.08)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(base, startCenter: CGPoint(x: 460, y: 600), startRadius: 0, endCenter: c, endRadius: r * 1.2, options: [])
    ctx.setBlendMode(.plusLighter)
    blob(ctx, 400, 420, 230, [1, 0.3, 0.6], 0.8); blob(ctx, 640, 620, 220, [0.2, 0.7, 1], 0.8)
    ctx.setBlendMode(.normal); ctx.restoreGState()
    ctx.addPath(orb); ctx.setStrokeColor(col(1, 1, 1, 0.35)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.setBlendMode(.plusLighter)
    let rb: [([CGFloat], CGFloat, CGFloat, CGFloat)] = [([1, 0.4, 0.8], 120, 1.3, 0.3), ([0.3, 0.9, 1], 100, 1.9, 2.4), ([1, 0.8, 0.4], 80, 2.4, 4.0), ([1, 1, 1], 55, 1.6, 1.0)]
    for w in rb { glowStroke(ctx, wave(110, 914, 512, amp: w.1, freq: w.2, phase: w.3), w.0, width: 6) }
    ctx.setBlendMode(.normal)
}

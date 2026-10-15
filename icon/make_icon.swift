import Cocoa

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let g = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = g
let ctx = g.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func col(_ r: CGFloat, _ gr: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, gr, b, a])! }

let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: rect, cornerWidth: 188, cornerHeight: 188, transform: nil)

// тень плитки
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: col(0, 0, 0, 0.5))
ctx.addPath(shape); ctx.setFillColor(col(0.03, 0.03, 0.08)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// фон
let bg = CGGradient(colorsSpace: cs, colors: [col(0.13, 0.08, 0.28), col(0.02, 0.02, 0.07)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// переливающиеся пятна в духе Siri
func blob(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: CGColor) {
    let comps = c.components!
    let grad = CGGradient(colorsSpace: cs, colors: [col(comps[0], comps[1], comps[2], 0.95), col(comps[0], comps[1], comps[2], 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(grad, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}
ctx.setBlendMode(.plusLighter)
blob(370, 380, 360, col(1.0, 0.25, 0.50))
blob(660, 340, 320, col(1.0, 0.62, 0.15))
blob(640, 680, 360, col(0.55, 0.30, 1.0))
blob(340, 660, 300, col(0.15, 0.75, 1.0))
blob(512, 512, 220, col(0.9, 0.6, 1.0))
ctx.setBlendMode(.normal)

// волны-«голос» позади микрофона
ctx.setBlendMode(.plusLighter)
for (i, c) in [col(1, 0.55, 0.7), col(0.6, 0.8, 1), col(1, 0.8, 0.4)].enumerated() {
    let p = CGMutablePath()
    var x: CGFloat = 130
    while x <= 894 {
        let nx = (x - 130) / 764
        let env = pow(sin(.pi * nx), 2)
        let y = 512 + 120 * env * sin(nx * 2 * .pi * (1.2 + CGFloat(i) * 0.5) + CGFloat(i) * 1.6)
        x == 130 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        x += 4
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: c)
    ctx.addPath(p); ctx.setStrokeColor(c); ctx.setLineWidth(7); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
}
ctx.setBlendMode(.normal)

// блик-стекло сверху
let gloss = CGGradient(colorsSpace: cs, colors: [col(1, 1, 1, 0.22), col(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
ctx.restoreGState()

// ободок плитки
ctx.addPath(shape); ctx.setStrokeColor(col(1, 1, 1, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

// микрофон
let dy: CGFloat = -40
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 30, color: col(0.5, 0.2, 1, 0.9))
let body = CGPath(roundedRect: CGRect(x: 437, y: 520 + dy + 60, width: 150, height: 270), cornerWidth: 75, cornerHeight: 75, transform: nil)
ctx.addPath(body); ctx.setFillColor(col(1, 1, 1)); ctx.fillPath()
// дуга-держатель
let arc = CGMutablePath()
arc.addArc(center: CGPoint(x: 512, y: 600 + dy + 20), radius: 130, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
ctx.addPath(arc); ctx.setStrokeColor(col(1, 1, 1)); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.strokePath()
// ножка и основание
ctx.setLineWidth(30)
ctx.move(to: CGPoint(x: 512, y: 470 + dy + 20)); ctx.addLine(to: CGPoint(x: 512, y: 400 + dy + 20)); ctx.strokePath()
ctx.move(to: CGPoint(x: 440, y: 400 + dy + 20)); ctx.addLine(to: CGPoint(x: 584, y: 400 + dy + 20)); ctx.strokePath()
ctx.restoreGState()

// сетка на микрофоне
ctx.saveGState()
ctx.addPath(body); ctx.clip()
let tint = CGGradient(colorsSpace: cs, colors: [col(1, 1, 1, 0), col(0.75, 0.65, 1, 0.55)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(tint, start: CGPoint(x: 437, y: 830 + dy), end: CGPoint(x: 587, y: 580 + dy), options: [])
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

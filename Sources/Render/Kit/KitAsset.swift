import CoreGraphics
import CoreText
import Foundation

public enum KitCategory: String, CaseIterable, Codable, Sendable {
    case tape, paper, tornEdge, filmFrame, instantFrame, doodle, label, lightLeak, grain, dust, shape
}

public struct KitAsset: Sendable, Identifiable {
    public let id: String
    public let category: KitCategory
    public let defaultSize: CGSize
    public let aspect: CGFloat
    public let tintable: Bool

    public init(id: String, category: KitCategory, defaultSize: CGSize, tintable: Bool) {
        self.id = id; self.category = category; self.defaultSize = defaultSize
        self.aspect = defaultSize.width / defaultSize.height; self.tintable = tintable
    }

    public func draw(in context: CGContext, rect: CGRect, seed: UInt64, tint: CGColor? = nil) {
        var rng = KitRandom(seed: seed)
        context.saveGState()
        context.clip(to: rect) // every asset must stay strictly inside its rect
        let color = tintable ? (tint ?? CGColor(srgbRed: 0.40, green: 0.55, blue: 0.50, alpha: 1)) : palette(for: id)
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setLineCap(.round); context.setLineJoin(.round)
        switch category {
        case .tape: tape(context, rect, id: id, rng: &rng)
        case .tornEdge: tornEdgeStrip(context, rect, id: id, rng: &rng)
        case .paper: paper(context, rect, id: id, rng: &rng)
        case .filmFrame: film(context, rect, id: id)
        case .instantFrame: instant(context, rect, id: id)
        case .doodle: doodle(context, rect, id: id, rng: &rng)
        case .label: label(context, rect, id: id)
        case .lightLeak: leak(context, rect, id: id)
        case .grain: grainOverlay(context, rect, id: id, rng: &rng)
        case .dust: dustOverlay(context, rect, id: id, rng: &rng)
        case .shape: shape(context, rect, id: id)
        }
        context.restoreGState()
    }

    // MARK: - Tape

    private func tape(_ c: CGContext, _ r: CGRect, id: String, rng: inout KitRandom) {
        c.saveGState()
        let angle = rng.signed(0.07)
        c.translateBy(x: r.midX, y: r.midY); c.rotate(by: angle); c.translateBy(x: -r.midX, y: -r.midY)
        let bandH = r.height * 0.60
        let band = CGRect(x: r.minX - r.width * 0.06, y: r.midY - bandH / 2, width: r.width * 1.12, height: bandH)
        let ragged = raggedRect(band, rng: &rng, amp: bandH * 0.16, edges: [.left, .right], segments: 5)
        let base = tapeColor(for: id)
        let isClear = id.contains("clear")
        c.setFillColor(base.copy(alpha: isClear ? 0.16 : 0.58) ?? base)
        c.addPath(ragged); c.fillPath()
        c.saveGState(); c.addPath(ragged); c.clip()
        // fibre texture
        c.setStrokeColor(CGColor(gray: 1, alpha: isClear ? 0.35 : 0.16)); c.setLineWidth(0.6)
        var ty = band.minY + band.height * 0.18
        while ty < band.maxY - band.height * 0.08 {
            c.move(to: CGPoint(x: band.minX, y: ty)); c.addLine(to: CGPoint(x: band.maxX, y: ty))
            ty += band.height * 0.20
        }
        c.strokePath()
        // pattern variants
        if id.contains("dot") {
            c.setFillColor(CGColor(gray: 1, alpha: 0.55))
            var dx = band.minX + band.width * 0.05
            while dx < band.maxX {
                var dy = band.minY + band.height * 0.22
                while dy < band.maxY - band.height * 0.1 {
                    c.fillEllipse(in: CGRect(x: dx, y: dy, width: band.height * 0.12, height: band.height * 0.12))
                    dy += band.height * 0.36
                }
                dx += band.width * 0.09
            }
        } else if id.contains("grid") || id.contains("crosshatch") {
            c.setStrokeColor(CGColor(gray: 1, alpha: 0.4)); c.setLineWidth(0.8)
            var gx = band.minX + band.width * 0.08
            while gx < band.maxX {
                c.move(to: CGPoint(x: gx, y: band.minY)); c.addLine(to: CGPoint(x: gx, y: band.maxY))
                gx += band.width * 0.14
            }
            c.strokePath()
            if id.contains("crosshatch") {
                c.setStrokeColor(CGColor(gray: 0, alpha: 0.14))
                var gy = band.minY + band.height * 0.2
                while gy < band.maxY {
                    c.move(to: CGPoint(x: band.minX, y: gy)); c.addLine(to: CGPoint(x: band.maxX, y: gy))
                    gy += band.height * 0.3
                }
                c.strokePath()
            }
        } else if isClear {
            c.setFillColor(CGColor(gray: 1, alpha: 0.30))
            c.fill(CGRect(x: band.minX, y: band.minY + band.height * 0.62, width: band.width, height: band.height * 0.14))
        }
        c.restoreGState()
        // gentle top sheen
        c.setStrokeColor(CGColor(gray: 1, alpha: isClear ? 0.5 : 0.22)); c.setLineWidth(1)
        c.move(to: CGPoint(x: band.minX, y: band.minY + band.height * 0.14))
        c.addLine(to: CGPoint(x: band.maxX, y: band.minY + band.height * 0.14)); c.strokePath()
        if isClear {
            // clear tape still needs a readable silhouette
            c.setStrokeColor(CGColor(gray: 0.55, alpha: 0.35)); c.setLineWidth(1)
            c.addPath(ragged); c.strokePath()
        }
        c.restoreGState()
    }

    private func tornEdgeStrip(_ c: CGContext, _ r: CGRect, id: String, rng: inout KitRandom) {
        let bodyH = r.height * 0.68
        let body = CGRect(x: r.minX, y: r.maxY - bodyH, width: r.width, height: bodyH)
        let amp: CGFloat
        let segments: Int
        var edges: Set<RectEdge> = [.top]
        switch true {
        case id.contains("rough"): amp = bodyH * 0.30; segments = 6
        case id.contains("double"): amp = bodyH * 0.20; segments = 7; edges = [.top, .bottom]
        case id.contains("deckle"): amp = bodyH * 0.12; segments = 12
        case id.contains("paper"): amp = bodyH * 0.18; segments = 5
        default: amp = bodyH * 0.14; segments = 9 // soft
        }
        let path = id.contains("deckle")
            ? deckleRect(body, rng: &rng, amp: amp, edges: edges, segments: segments)
            : raggedRect(body, rng: &rng, amp: amp, edges: edges, segments: segments)
        c.setAlpha(0.90); c.addPath(path); c.fillPath()
        if id.contains("paper") {
            c.setAlpha(0.30); c.setLineWidth(max(1, bodyH * 0.03))
            c.move(to: CGPoint(x: body.minX, y: body.minY + bodyH * 0.22))
            c.addLine(to: CGPoint(x: body.maxX, y: body.minY + bodyH * 0.22)); c.strokePath()
        }
    }

    // MARK: - Paper

    private func paper(_ c: CGContext, _ r: CGRect, id: String, rng: inout KitRandom) {
        let amp = min(r.width, r.height) * 0.03
        let path = deckleRect(r, rng: &rng, amp: amp, edges: [.top, .bottom, .left, .right], segments: 10)
        c.setFillColor(paperColor(for: id)); c.addPath(path); c.fillPath()
        c.saveGState(); c.addPath(path); c.clip()
        if id.contains("lined") {
            c.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.62, blue: 0.72, alpha: 0.35)); c.setLineWidth(1)
            var y = r.minY + r.height * 0.16
            while y < r.maxY - r.height * 0.06 {
                c.move(to: CGPoint(x: r.minX + 6, y: y)); c.addLine(to: CGPoint(x: r.maxX - 6, y: y))
                y += r.height * 0.09
            }
            c.strokePath()
            c.setStrokeColor(CGColor(srgbRed: 0.75, green: 0.42, blue: 0.40, alpha: 0.4)); c.setLineWidth(1.2)
            c.move(to: CGPoint(x: r.minX + r.width * 0.16, y: r.minY)); c.addLine(to: CGPoint(x: r.minX + r.width * 0.16, y: r.maxY)); c.strokePath()
        } else if id.contains("ledger") {
            c.setStrokeColor(CGColor(srgbRed: 0.42, green: 0.5, blue: 0.44, alpha: 0.30)); c.setLineWidth(0.8)
            var y = r.minY + r.height * 0.1
            while y < r.maxY {
                c.move(to: CGPoint(x: r.minX, y: y)); c.addLine(to: CGPoint(x: r.maxX, y: y)); y += r.height * 0.085
            }
            var x = r.minX + r.width * 0.16
            while x < r.maxX {
                c.move(to: CGPoint(x: x, y: r.minY)); c.addLine(to: CGPoint(x: x, y: r.maxY)); x += r.width * 0.22
            }
            c.strokePath()
        } else if id.contains("newsprint") {
            c.setFillColor(CGColor(gray: 0.35, alpha: 0.22))
            var y = r.minY + r.height * 0.06
            var row = 0
            while y < r.maxY {
                var x = r.minX + (row.isMultiple(of: 2) ? r.width * 0.03 : r.width * 0.075)
                while x < r.maxX {
                    c.fillEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                    x += r.width * 0.09
                }
                y += r.height * 0.045; row += 1
            }
        } else if id.contains("cotton") {
            c.setFillColor(CGColor(gray: 1, alpha: 0.35))
            for _ in 0..<26 {
                let x = r.minX + CGFloat(rng.nextUnit()) * r.width, y = r.minY + CGFloat(rng.nextUnit()) * r.height
                let s = 3 + CGFloat(rng.nextUnit()) * 6
                c.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s * 0.6))
            }
        } else if id.contains("kraft") || id.contains("warm") {
            c.setStrokeColor(CGColor(gray: 0.25, alpha: 0.10)); c.setLineWidth(0.6)
            for _ in 0..<16 {
                let y = r.minY + CGFloat(rng.nextUnit()) * r.height
                let x0 = r.minX + CGFloat(rng.nextUnit()) * r.width * 0.4
                c.move(to: CGPoint(x: x0, y: y)); c.addLine(to: CGPoint(x: x0 + r.width * 0.35, y: y + rng.signed(3)))
            }
            c.strokePath()
        } else {
            c.setFillColor(CGColor(gray: 1, alpha: 0.12))
            for _ in 0..<10 {
                let x = r.minX + CGFloat(rng.nextUnit()) * r.width, y = r.minY + CGFloat(rng.nextUnit()) * r.height
                c.fillEllipse(in: CGRect(x: x, y: y, width: 5, height: 5))
            }
        }
        c.restoreGState()
    }

    // MARK: - Film

    private func film(_ c: CGContext, _ r: CGRect, id: String) {
        let band = r.width * 0.13
        c.setFillColor(CGColor(gray: 0.07, alpha: 0.96)); c.fill(r)
        c.setFillColor(CGColor(srgbRed: 0.93, green: 0.90, blue: 0.80, alpha: 1))
        var y = r.minY + band * 0.55
        while y + band * 0.42 < r.maxY {
            for x in [r.minX + band * 0.27, r.maxX - band * 0.73] {
                c.fillEllipse(in: CGRect(x: x, y: y, width: band * 0.46, height: band * 0.42))
            }
            y += band * 0.86
        }
        c.setStrokeColor(CGColor(gray: 0.85, alpha: 0.55)); c.setLineWidth(1); c.stroke(r.insetBy(dx: band, dy: 0))
        let middle = r.insetBy(dx: band, dy: 0)
        guard r.width > r.height else { return } // portrait frames are too narrow to caption legibly
        let cream = CGColor(srgbRed: 0.93, green: 0.90, blue: 0.80, alpha: 0.88)
        c.saveGState(); c.textMatrix = .identity
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(6, r.height * 0.085), nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: cream] as CFDictionary
        let label = id.contains("negative") ? "AK14 NEG" : id.contains("contact") ? "CONTACT" : "AK14 400"
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label as CFString, attrs)!)
        c.textPosition = CGPoint(x: middle.minX + middle.width * 0.06, y: r.midY - r.height * 0.035)
        CTLineDraw(line, c)
        let numberFont = CTFontCreateWithName("Helvetica-Bold" as CFString, max(6, r.height * 0.10), nil)
        let numAttrs = [kCTFontAttributeName: numberFont, kCTForegroundColorAttributeName: cream] as CFDictionary
        let frameNumber = String(format: "%02dA", 1 + (abs(id.hashValue) % 24))
        let numLine = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, frameNumber as CFString, numAttrs)!)
        let numWidth = CGFloat(CTLineGetTypographicBounds(numLine, nil, nil, nil))
        c.textPosition = CGPoint(x: middle.maxX - middle.width * 0.06 - numWidth, y: r.midY - r.height * 0.035)
        CTLineDraw(numLine, c)
        c.restoreGState()
    }

    // MARK: - Instant frame

    private func instant(_ c: CGContext, _ r: CGRect, id: String) {
        let tilt = CGFloat((abs(id.hashValue) % 7) - 3) * 0.012
        c.saveGState()
        c.translateBy(x: r.midX, y: r.midY); c.rotate(by: tilt); c.translateBy(x: -r.midX, y: -r.midY)
        c.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.93, alpha: 1))
        let outer = CGPath(roundedRect: r, cornerWidth: r.width * 0.02, cornerHeight: r.width * 0.02, transform: nil)
        c.addPath(outer); c.fillPath()
        c.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); c.setLineWidth(1); c.addPath(outer); c.strokePath()
        let side = r.width * 0.08
        let top = r.height * 0.08
        let bottom = r.height * 0.26 // thicker instant-photo border
        let photo = CGRect(x: r.minX + side, y: r.minY + bottom, width: r.width - side * 2, height: r.height - top - bottom)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(srgbRed: 0.42, green: 0.52, blue: 0.48, alpha: 1),
            CGColor(srgbRed: 0.72, green: 0.58, blue: 0.55, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        c.saveGState(); c.addRect(photo); c.clip()
        c.drawLinearGradient(gradient, start: CGPoint(x: photo.minX, y: photo.minY), end: CGPoint(x: photo.maxX, y: photo.maxY), options: [])
        c.restoreGState()
        c.restoreGState()
    }

    // MARK: - Doodles

    private func doodle(_ c: CGContext, _ r: CGRect, id: String, rng: inout KitRandom) {
        let b = r.insetBy(dx: r.width * 0.14, dy: r.height * 0.14)
        c.setLineWidth(max(1.4, min(r.width, r.height) * 0.05))
        let wobAmt = min(b.width, b.height) * 0.045
        func w(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + rng.signed(wobAmt), y: p.y + rng.signed(wobAmt)) }

        if id.contains("heart") {
            func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint { w(CGPoint(x: b.minX + nx * b.width, y: b.minY + ny * b.height)) }
            let p = CGMutablePath()
            p.move(to: pt(0.5, 0.906))
            p.addCurve(to: pt(0, 0.4375), control1: pt(0.1875, 0.594), control2: pt(0, 0.4375))
            p.addCurve(to: pt(0.25, 0), control1: pt(0, 0.094), control2: pt(0.125, 0))
            p.addCurve(to: pt(0.5, 0.25), control1: pt(0.375, 0), control2: pt(0.5, 0.094))
            p.addCurve(to: pt(0.75, 0), control1: pt(0.5, 0.094), control2: pt(0.625, 0))
            p.addCurve(to: pt(1, 0.4375), control1: pt(0.875, 0), control2: pt(1, 0.094))
            p.addCurve(to: pt(0.5, 0.906), control1: pt(1, 0.4375), control2: pt(0.8125, 0.594))
            c.addPath(p); c.strokePath()
        } else if id.contains("star") {
            let n = 5
            var pts: [CGPoint] = []
            for i in 0..<n {
                let a = -CGFloat.pi / 2 + CGFloat(i) * (2 * .pi / CGFloat(n))
                pts.append(w(CGPoint(x: b.midX + cos(a) * b.width / 2, y: b.midY + sin(a) * b.height / 2)))
            }
            let p = CGMutablePath(); p.move(to: pts[0])
            for k in 1...5 { p.addLine(to: pts[(k * 2) % 5]) }
            p.closeSubpath(); c.addPath(p); c.strokePath()
        } else if id.contains("sparkle") {
            // classic four-point twinkle/sparkle glyph
            let outerR = min(b.width, b.height) / 2, innerR = outerR * 0.30
            var pts: [CGPoint] = []
            for i in 0..<8 {
                let radius = i.isMultiple(of: 2) ? outerR : innerR
                let angle = -CGFloat.pi / 2 + CGFloat(i) * (.pi / 4)
                pts.append(w(CGPoint(x: b.midX + cos(angle) * radius, y: b.midY + sin(angle) * radius)))
            }
            let p = CGMutablePath(); p.move(to: pts[0])
            for i in 1..<pts.count { p.addLine(to: pts[i]) }
            p.closeSubpath(); c.addPath(p); c.fillPath()
            // a tiny companion twinkle
            let mini = outerR * 0.32
            c.saveGState(); c.translateBy(x: b.maxX - mini * 0.4, y: b.minY + mini * 0.6)
            var miniPts: [CGPoint] = []
            for i in 0..<8 {
                let radius = i.isMultiple(of: 2) ? mini : mini * 0.3
                let angle = -CGFloat.pi / 2 + CGFloat(i) * (.pi / 4)
                miniPts.append(CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
            }
            let mp = CGMutablePath(); mp.move(to: miniPts[0])
            for i in 1..<miniPts.count { mp.addLine(to: miniPts[i]) }
            mp.closeSubpath(); c.addPath(mp); c.fillPath()
            c.restoreGState()
        } else if id.contains("arrow") {
            let start = w(CGPoint(x: b.minX, y: b.maxY)), end = w(CGPoint(x: b.maxX, y: b.minY))
            c.move(to: start); c.addQuadCurve(to: end, control: w(CGPoint(x: b.midX, y: b.maxY * 0.6 + b.minY * 0.4)))
            c.move(to: end); c.addLine(to: w(CGPoint(x: end.x - b.width * 0.32, y: end.y)))
            c.move(to: end); c.addLine(to: w(CGPoint(x: end.x, y: end.y + b.height * 0.32)))
            c.strokePath()
        } else if id.contains("underline") {
            for k in 0..<2 {
                let y = b.minY + b.height * (0.5 + CGFloat(k) * 0.2)
                c.move(to: w(CGPoint(x: b.minX, y: y)))
                c.addQuadCurve(to: w(CGPoint(x: b.maxX, y: y)), control: w(CGPoint(x: b.midX, y: y + b.height * 0.14)))
            }
            c.strokePath()
        } else { // circle-scribble
            let e1 = CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height)
            let e2 = e1.insetBy(dx: -b.width * 0.06, dy: b.height * 0.04).offsetBy(dx: rng.signed(b.width * 0.05), dy: rng.signed(b.height * 0.05))
            c.addEllipse(in: e1); c.strokePath()
            c.addEllipse(in: e2); c.strokePath()
        }
    }

    // MARK: - Labels

    private func label(_ c: CGContext, _ r: CGRect, id: String) {
        if id.contains("postmark") {
            let radius = min(r.width, r.height) / 2 * 0.92
            let center = CGPoint(x: r.midX, y: r.midY)
            c.setStrokeColor(CGColor(srgbRed: 0.55, green: 0.30, blue: 0.28, alpha: 0.78))
            c.setLineWidth(max(1.2, radius * 0.06))
            c.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)); c.strokePath()
            let inner = radius * 0.74
            c.setLineWidth(max(1, radius * 0.035))
            c.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)); c.strokePath()
            for k in -1...1 {
                let y = center.y + CGFloat(k) * radius * 0.42
                c.move(to: CGPoint(x: center.x - radius * 0.6, y: y))
                c.addQuadCurve(to: CGPoint(x: center.x + radius * 0.6, y: y), control: CGPoint(x: center.x, y: y + radius * 0.22))
            }
            c.strokePath()
            return
        }
        let corner = id.contains("ticket") ? r.height * 0.10 : r.height * 0.20
        let bodyPath = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
        c.setAlpha(0.94); c.addPath(bodyPath); c.fillPath()
        c.setAlpha(1)
        if id.contains("ticket") {
            let notchR = r.height * 0.16
            c.setBlendMode(.clear)
            c.fillEllipse(in: CGRect(x: r.minX - notchR, y: r.midY - notchR, width: notchR * 2, height: notchR * 2))
            c.fillEllipse(in: CGRect(x: r.maxX - notchR, y: r.midY - notchR, width: notchR * 2, height: notchR * 2))
            c.setBlendMode(.normal)
            c.saveGState(); c.setStrokeColor(CGColor(gray: 1, alpha: 0.6)); c.setLineWidth(1.2)
            c.setLineDash(phase: 0, lengths: [3, 3])
            c.move(to: CGPoint(x: r.minX + r.width * 0.32, y: r.minY + 3)); c.addLine(to: CGPoint(x: r.minX + r.width * 0.32, y: r.maxY - 3))
            c.strokePath(); c.restoreGState()
            inkLine(c, CGRect(x: r.minX + r.width * 0.42, y: r.midY - r.height * 0.06, width: r.width * 0.46, height: r.height * 0.12))
        } else if id.contains("caption") {
            inkLine(c, CGRect(x: r.minX + r.width * 0.10, y: r.midY - r.height * 0.16, width: r.width * 0.8, height: r.height * 0.12))
            inkLine(c, CGRect(x: r.minX + r.width * 0.10, y: r.midY + r.height * 0.04, width: r.width * 0.55, height: r.height * 0.12))
        } else if id.contains("date") {
            inkLine(c, CGRect(x: r.minX + r.width * 0.14, y: r.midY - r.height * 0.09, width: r.width * 0.72, height: r.height * 0.18))
        } else {
            inkLine(c, CGRect(x: r.minX + r.width * 0.12, y: r.midY - r.height * 0.06, width: r.width * 0.76, height: r.height * 0.12))
        }
    }
    private func inkLine(_ c: CGContext, _ rect: CGRect) {
        c.setAlpha(0.28); c.setFillColor(CGColor(gray: 0.05, alpha: 1))
        c.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)); c.fillPath()
    }

    // MARK: - Overlays

    private func leak(_ c: CGContext, _ r: CGRect, id: String) {
        let hue: [CGColor]
        if id.contains("coral") { hue = [CGColor(srgbRed: 1, green: 0.55, blue: 0.42, alpha: 0.28), CGColor(srgbRed: 1, green: 0.7, blue: 0.5, alpha: 0)] }
        else if id.contains("violet") { hue = [CGColor(srgbRed: 0.55, green: 0.42, blue: 0.62, alpha: 0.26), CGColor(srgbRed: 0.7, green: 0.6, blue: 0.75, alpha: 0)] }
        else if id.contains("gold") { hue = [CGColor(srgbRed: 0.85, green: 0.68, blue: 0.32, alpha: 0.26), CGColor(srgbRed: 0.95, green: 0.85, blue: 0.55, alpha: 0)] }
        else if id.contains("edge") { hue = [CGColor(srgbRed: 1, green: 0.66, blue: 0.4, alpha: 0.30), CGColor(srgbRed: 1, green: 0.8, blue: 0.5, alpha: 0)] }
        else { hue = [CGColor(srgbRed: 0.95, green: 0.62, blue: 0.30, alpha: 0.26), CGColor(srgbRed: 1, green: 0.78, blue: 0.45, alpha: 0)] } // amber
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hue as CFArray, locations: [0, 1])!
        if id.contains("edge") {
            c.drawRadialGradient(gradient, startCenter: CGPoint(x: r.minX, y: r.maxY), startRadius: 0, endCenter: CGPoint(x: r.minX, y: r.maxY), endRadius: max(r.width, r.height) * 0.75, options: [])
        } else {
            c.drawLinearGradient(gradient, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        }
    }

    private func grainOverlay(_ c: CGContext, _ r: CGRect, id: String, rng: inout KitRandom) {
        let count: Int
        let size: CGFloat
        switch true {
        case id.contains("fine"): count = 260; size = 0.6
        case id.contains("soft"): count = 140; size = 1.1
        case id.contains("chunky"): count = 90; size = 2.6
        case id.contains("heavy"): count = 220; size = 1.9
        case id.contains("35mm"): count = 200; size = 1.5
        default: count = 180; size = 1.3 // medium
        }
        for _ in 0..<count {
            let x = r.minX + CGFloat(rng.nextUnit()) * r.width, y = r.minY + CGFloat(rng.nextUnit()) * r.height
            let s = size * (0.5 + CGFloat(rng.nextUnit()))
            c.setFillColor(CGColor(gray: rng.nextUnit() > 0.5 ? 1 : 0, alpha: 0.30))
            c.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
        }
    }
    private func dustOverlay(_ c: CGContext, _ r: CGRect, id: String, rng: inout KitRandom) {
        let flecks = id.contains("sparse") ? 12 : id.contains("flecks") ? 34 : 20
        for _ in 0..<flecks {
            let x = r.minX + CGFloat(rng.nextUnit()) * r.width, y = r.minY + CGFloat(rng.nextUnit()) * r.height
            let s = 1.0 + CGFloat(rng.nextUnit()) * 2.4
            c.setFillColor(CGColor(gray: 1, alpha: 0.42))
            c.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
        }
        if id.contains("scratches") || id.contains("hairline") || id.contains("film") {
            c.setStrokeColor(CGColor(gray: 1, alpha: 0.34)); c.setLineWidth(id.contains("hairline") ? 0.5 : 0.9)
            let strokes = id.contains("scratches") ? 5 : 2
            for _ in 0..<strokes {
                let x = r.minX + CGFloat(rng.nextUnit()) * r.width
                c.move(to: CGPoint(x: x, y: r.minY)); c.addLine(to: CGPoint(x: x + rng.signed(r.width * 0.05), y: r.maxY))
            }
            c.strokePath()
        }
    }

    // MARK: - Shapes

    private func shape(_ c: CGContext, _ r: CGRect, id: String) {
        let b = r.insetBy(dx: r.width * 0.10, dy: r.height * 0.10)
        let path = shapePath(for: id, in: b)
        c.saveGState()
        c.setStrokeColor(CGColor(srgbRed: 0.99, green: 0.98, blue: 0.94, alpha: 0.95))
        c.setLineWidth(max(3, min(b.width, b.height) * 0.10))
        c.addPath(path); c.strokePath()
        c.restoreGState()
        c.addPath(path); c.fillPath()
    }
    private func shapePath(for id: String, in b: CGRect) -> CGPath {
        if id.contains("star") { return starPath(center: CGPoint(x: b.midX, y: b.midY), outerR: min(b.width, b.height) / 2, innerRatio: 0.45, points: 5) }
        if id.contains("heart") { return heartPath(in: b) }
        if id.contains("sun") { return sunPath(in: b) }
        if id.contains("diamond") { return diamondPath(in: b) }
        if id.contains("circle") { return CGPath(ellipseIn: b, transform: nil) }
        let radius = min(b.width, b.height) / 2
        return CGPath(roundedRect: b, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    private func starPath(center: CGPoint, outerR: CGFloat, innerRatio: CGFloat, points: Int) -> CGPath {
        let path = CGMutablePath(); let innerR = outerR * innerRatio
        let step = CGFloat.pi / CGFloat(points)
        for i in 0..<(points * 2) {
            let radius = i.isMultiple(of: 2) ? outerR : innerR
            let angle = -CGFloat.pi / 2 + CGFloat(i) * step
            let pt = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath(); return path
    }
    /// Classic two-lobe heart silhouette, built from a normalised 0...1 (x, y-down) template.
    private func heartPath(in b: CGRect) -> CGPath {
        func pt(_ nx: CGFloat, _ ny: CGFloat) -> CGPoint { CGPoint(x: b.minX + nx * b.width, y: b.minY + ny * b.height) }
        let p = CGMutablePath()
        p.move(to: pt(0.5, 0.906))
        p.addCurve(to: pt(0, 0.4375), control1: pt(0.1875, 0.594), control2: pt(0, 0.4375))
        p.addCurve(to: pt(0.25, 0), control1: pt(0, 0.094), control2: pt(0.125, 0))
        p.addCurve(to: pt(0.5, 0.25), control1: pt(0.375, 0), control2: pt(0.5, 0.094))
        p.addCurve(to: pt(0.75, 0), control1: pt(0.5, 0.094), control2: pt(0.625, 0))
        p.addCurve(to: pt(1, 0.4375), control1: pt(0.875, 0), control2: pt(1, 0.094))
        p.addCurve(to: pt(0.5, 0.906), control1: pt(1, 0.4375), control2: pt(0.8125, 0.594))
        p.closeSubpath(); return p
    }
    private func sunPath(in b: CGRect) -> CGPath {
        let p = CGMutablePath(); let center = CGPoint(x: b.midX, y: b.midY)
        let outerR = min(b.width, b.height) / 2, innerR = outerR * 0.58, rays = 8
        for i in 0..<rays {
            let a0 = CGFloat(i) / CGFloat(rays) * (2 * .pi)
            let a1 = a0 + (2 * .pi / CGFloat(rays)) * 0.5
            let a2 = a0 + (2 * .pi / CGFloat(rays))
            let tip = CGPoint(x: center.x + cos(a1) * outerR, y: center.y + sin(a1) * outerR)
            let base0 = CGPoint(x: center.x + cos(a0) * innerR, y: center.y + sin(a0) * innerR)
            let base2 = CGPoint(x: center.x + cos(a2) * innerR, y: center.y + sin(a2) * innerR)
            if i == 0 { p.move(to: base0) } else { p.addLine(to: base0) }
            p.addLine(to: tip); p.addLine(to: base2)
        }
        p.closeSubpath(); return p
    }
    private func diamondPath(in b: CGRect) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: b.midX, y: b.minY)); p.addLine(to: CGPoint(x: b.maxX, y: b.midY))
        p.addLine(to: CGPoint(x: b.midX, y: b.maxY)); p.addLine(to: CGPoint(x: b.minX, y: b.midY))
        p.closeSubpath(); return p
    }

    // MARK: - Ragged / deckled edge helpers

    private enum RectEdge { case left, right, top, bottom }
    private func raggedRect(_ r: CGRect, rng: inout KitRandom, amp: CGFloat, edges: Set<RectEdge>, segments: Int) -> CGMutablePath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        if edges.contains(.top) {
            for i in 1..<segments { let x = r.minX + r.width * CGFloat(i) / CGFloat(segments); p.addLine(to: CGPoint(x: x, y: r.minY + abs(rng.signed(amp)))) }
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        if edges.contains(.right) {
            for i in 1..<segments { let y = r.minY + r.height * CGFloat(i) / CGFloat(segments); p.addLine(to: CGPoint(x: r.maxX - abs(rng.signed(amp)), y: y)) }
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        if edges.contains(.bottom) {
            for i in stride(from: segments - 1, through: 1, by: -1) { let x = r.minX + r.width * CGFloat(i) / CGFloat(segments); p.addLine(to: CGPoint(x: x, y: r.maxY - abs(rng.signed(amp)))) }
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        if edges.contains(.left) {
            for i in stride(from: segments - 1, through: 1, by: -1) { let y = r.minY + r.height * CGFloat(i) / CGFloat(segments); p.addLine(to: CGPoint(x: r.minX + abs(rng.signed(amp)), y: y)) }
        }
        p.closeSubpath(); return p
    }
    private func deckleRect(_ r: CGRect, rng: inout KitRandom, amp: CGFloat, edges: Set<RectEdge>, segments: Int) -> CGMutablePath {
        // soft rounded bumps rather than sharp zigzag
        let p = CGMutablePath()
        func bumped(_ base: CGPoint, inward: CGVector) -> CGPoint {
            let d = abs(rng.signed(amp))
            return CGPoint(x: base.x + inward.dx * d, y: base.y + inward.dy * d)
        }
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        if edges.contains(.top) {
            var prev = CGPoint(x: r.minX, y: r.minY)
            for i in 1...segments {
                let x = r.minX + r.width * CGFloat(i) / CGFloat(segments)
                let pt = bumped(CGPoint(x: x, y: r.minY), inward: CGVector(dx: 0, dy: 1))
                p.addQuadCurve(to: pt, control: CGPoint(x: (prev.x + pt.x) / 2, y: min(prev.y, pt.y)))
                prev = pt
            }
        } else { p.addLine(to: CGPoint(x: r.maxX, y: r.minY)) }
        if edges.contains(.right) {
            var prev = CGPoint(x: r.maxX, y: r.minY)
            for i in 1...segments {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(segments)
                let pt = bumped(CGPoint(x: r.maxX, y: y), inward: CGVector(dx: -1, dy: 0))
                p.addQuadCurve(to: pt, control: CGPoint(x: max(prev.x, pt.x), y: (prev.y + pt.y) / 2))
                prev = pt
            }
        } else { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }
        if edges.contains(.bottom) {
            var prev = CGPoint(x: r.maxX, y: r.maxY)
            for i in stride(from: segments - 1, through: 0, by: -1) {
                let x = r.minX + r.width * CGFloat(i) / CGFloat(segments)
                let pt = bumped(CGPoint(x: x, y: r.maxY), inward: CGVector(dx: 0, dy: -1))
                p.addQuadCurve(to: pt, control: CGPoint(x: (prev.x + pt.x) / 2, y: max(prev.y, pt.y)))
                prev = pt
            }
        } else { p.addLine(to: CGPoint(x: r.minX, y: r.maxY)) }
        if edges.contains(.left) {
            var prev = CGPoint(x: r.minX, y: r.maxY)
            for i in stride(from: segments - 1, through: 0, by: -1) {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(segments)
                let pt = bumped(CGPoint(x: r.minX, y: y), inward: CGVector(dx: 1, dy: 0))
                p.addQuadCurve(to: pt, control: CGPoint(x: min(prev.x, pt.x), y: (prev.y + pt.y) / 2))
                prev = pt
            }
        }
        p.closeSubpath(); return p
    }

    // MARK: - Palettes

    private func tapeColor(for id: String) -> CGColor {
        if id.contains("cream") { return CGColor(srgbRed: 0.92, green: 0.85, blue: 0.68, alpha: 1) }
        if id.contains("sage") { return CGColor(srgbRed: 0.55, green: 0.62, blue: 0.52, alpha: 1) }
        if id.contains("rose") { return CGColor(srgbRed: 0.78, green: 0.55, blue: 0.52, alpha: 1) }
        if id.contains("blue") { return CGColor(srgbRed: 0.52, green: 0.60, blue: 0.66, alpha: 1) }
        if id.contains("lilac") { return CGColor(srgbRed: 0.68, green: 0.60, blue: 0.68, alpha: 1) }
        if id.contains("masking") { return CGColor(srgbRed: 0.80, green: 0.70, blue: 0.55, alpha: 1) }
        if id.contains("clear") { return CGColor(gray: 0.9, alpha: 1) }
        return CGColor(srgbRed: 0.70, green: 0.66, blue: 0.58, alpha: 1) // grid / dot / crosshatch default kraft
    }
    private func paperColor(for id: String) -> CGColor {
        if id.contains("kraft") { return CGColor(srgbRed: 0.72, green: 0.58, blue: 0.42, alpha: 1) }
        if id.contains("lined") { return CGColor(srgbRed: 0.97, green: 0.96, blue: 0.91, alpha: 1) }
        if id.contains("ledger") { return CGColor(srgbRed: 0.90, green: 0.93, blue: 0.87, alpha: 1) }
        if id.contains("newsprint") { return CGColor(srgbRed: 0.90, green: 0.89, blue: 0.85, alpha: 1) }
        if id.contains("cotton") { return CGColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1) }
        if id.contains("blue") { return CGColor(srgbRed: 0.80, green: 0.85, blue: 0.87, alpha: 1) }
        if id.contains("blush") { return CGColor(srgbRed: 0.92, green: 0.83, blue: 0.81, alpha: 1) }
        if id.contains("warm") { return CGColor(srgbRed: 0.93, green: 0.86, blue: 0.74, alpha: 1) }
        return CGColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1)
    }
    private func palette(for id: String) -> CGColor {
        if id.contains("light-leak") || id.contains("label") { return CGColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1) }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.76, 0.45, 0.34), (0.79, 0.66, 0.44), (0.40, 0.55, 0.50), (0.70, 0.68, 0.59), (0.55, 0.48, 0.39)]
        let i = abs(id.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % colors.count
        let v = colors[i]; return CGColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: 0.85)
    }
}

private struct KitRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func nextUnit() -> Double {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return Double((state &* 0x2545F4914F6CDD1D) >> 11) / Double(UInt64.max >> 11)
    }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + CGFloat(nextUnit()) * (b - a) }
    mutating func signed(_ magnitude: CGFloat) -> CGFloat { range(-magnitude, magnitude) }
}

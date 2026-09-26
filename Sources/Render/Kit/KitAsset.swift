import CoreGraphics
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
        let color = tintable ? (tint ?? CGColor(srgbRed: 0.22, green: 0.38, blue: 0.36, alpha: 1)) : palette(for: id)
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setLineCap(.round); context.setLineJoin(.round)
        switch category {
        case .tape, .tornEdge: tornBand(context, rect, rng: &rng, torn: category == .tornEdge)
        case .paper: paper(context, rect, rng: &rng)
        case .filmFrame: film(context, rect)
        case .instantFrame: instant(context, rect)
        case .doodle: doodle(context, rect, id: id)
        case .label: label(context, rect, id: id)
        case .lightLeak: leak(context, rect, color: color)
        case .grain, .dust: speckles(context, rect, rng: &rng, count: category == .grain ? 240 : 38)
        case .shape: shape(context, rect, id: id)
        }
        context.restoreGState()
    }

    private func tornBand(_ c: CGContext, _ r: CGRect, rng: inout KitRandom, torn: Bool) {
        let h = torn ? r.height : r.height * 0.78
        let p = CGMutablePath(); p.move(to: CGPoint(x:r.minX,y:r.minY+h))
        p.addLine(to: CGPoint(x:r.maxX,y:r.minY+h))
        let n = 9
        for i in 0...n { let x = r.maxX - r.width * CGFloat(i)/CGFloat(n); p.addLine(to: CGPoint(x:x,y:r.minY+h-CGFloat(rng.nextUnit())*r.height*0.20)) }
        p.addLine(to: CGPoint(x:r.minX,y:r.minY))
        for i in 0...n { let x = r.minX + r.width * CGFloat(i)/CGFloat(n); p.addLine(to: CGPoint(x:x,y:r.minY+CGFloat(rng.nextUnit())*r.height*0.18)) }
        p.closeSubpath(); c.setAlpha(torn ? 0.92 : 0.52); c.addPath(p); c.fillPath()
        if !torn { c.setAlpha(0.27); c.setLineWidth(max(1,r.height*0.035)); c.move(to: CGPoint(x:r.minX,y:r.midY)); c.addLine(to: CGPoint(x:r.maxX,y:r.midY)); c.strokePath() }
    }
    private func paper(_ c: CGContext, _ r: CGRect, rng: inout KitRandom) {
        let p=CGMutablePath(); p.move(to: CGPoint(x:r.minX,y:r.minY))
        for i in 0...8 { p.addLine(to: CGPoint(x:r.minX+r.width*CGFloat(i)/8,y:r.minY+(i == 0 || i == 8 ? 0 : CGFloat(rng.nextUnit())*r.height*0.08))) }
        p.addLine(to: CGPoint(x:r.maxX,y:r.maxY)); p.addLine(to: CGPoint(x:r.minX,y:r.maxY)); p.closeSubpath()
        c.setAlpha(0.88); c.addPath(p); c.fillPath(); c.setAlpha(0.20); c.setLineWidth(1)
        for i in 1...5 { let y=r.minY+r.height*CGFloat(i)/6; c.move(to:CGPoint(x:r.minX+4,y:y)); c.addLine(to:CGPoint(x:r.maxX-4,y:y)) }; c.strokePath()
    }
    private func film(_ c: CGContext, _ r: CGRect) {
        let band=r.width*0.12; c.setFillColor(CGColor(gray:0.08,alpha:0.95)); c.fill(r)
        c.setFillColor(CGColor(srgbRed:0.94,green:0.91,blue:0.83,alpha:1)); var y=r.minY+band*0.6
        while y+band*0.48<r.maxY { for x in [r.minX+band*0.27,r.maxX-band*0.73] { c.fillEllipse(in:CGRect(x:x,y:y,width:band*0.46,height:band*0.46)) }; y += band*0.9 }
        c.setStrokeColor(CGColor(gray:0.85,alpha:0.7)); c.setLineWidth(1); c.stroke(r.insetBy(dx:band,dy:0))
    }
    private func instant(_ c: CGContext, _ r: CGRect) { c.setFillColor(CGColor(srgbRed:0.98,green:0.97,blue:0.92,alpha:1)); c.addPath(CGPath(roundedRect:r,cornerWidth:r.width*0.025,cornerHeight:r.width*0.025,transform:nil)); c.fillPath(); c.setFillColor(CGColor(gray:0.35,alpha:0.08)); c.fill(CGRect(x:r.minX+r.width*0.08,y:r.minY+r.height*0.08,width:r.width*0.84,height:r.height*0.70)) }
    private func doodle(_ c: CGContext, _ r: CGRect, id: String) {
        let b=r.insetBy(dx:r.width*0.12,dy:r.height*0.12); c.setLineWidth(max(1,min(r.width,r.height)*0.045))
        if id.contains("heart") { let p=CGMutablePath(); p.move(to:CGPoint(x:b.midX,y:b.maxY)); p.addCurve(to:CGPoint(x:b.minX,y:b.minY+b.height*0.32),control1:CGPoint(x:b.minX,y:b.maxY-b.height*0.2),control2:CGPoint(x:b.minX,y:b.minY)); p.addCurve(to:CGPoint(x:b.midX,y:b.minY+b.height*0.28),control1:CGPoint(x:b.minX,y:b.minY-b.height*0.05),control2:CGPoint(x:b.midX-b.width*0.08,y:b.minY+b.height*0.05)); p.addCurve(to:CGPoint(x:b.maxX,y:b.minY+b.height*0.32),control1:CGPoint(x:b.midX+b.width*0.08,y:b.minY+b.height*0.05),control2:CGPoint(x:b.maxX,y:b.minY-b.height*0.02)); p.addCurve(to:CGPoint(x:b.midX,y:b.maxY),control1:CGPoint(x:b.maxX,y:b.maxY-b.height*0.2),control2:CGPoint(x:b.maxX,y:b.maxY-b.height*0.2)); c.addPath(p); c.strokePath()
        } else if id.contains("arrow") { c.move(to:CGPoint(x:b.minX,y:b.maxY)); c.addLine(to:CGPoint(x:b.maxX,y:b.minY)); c.addLine(to:CGPoint(x:b.maxX-b.width*0.30,y:b.minY)); c.move(to:CGPoint(x:b.maxX,y:b.minY)); c.addLine(to:CGPoint(x:b.maxX,y:b.minY+b.height*0.3)); c.strokePath()
        } else if id.contains("underline") { for k in 0..<2 { let y=b.minY+b.height*(0.52+CGFloat(k)*0.16); c.move(to:CGPoint(x:b.minX,y:y)); c.addQuadCurve(to:CGPoint(x:b.maxX,y:y),control:CGPoint(x:b.midX,y:y+b.height*0.1)) }; c.strokePath()
        } else { c.addEllipse(in:b); c.strokePath(); if id.contains("star") || id.contains("sparkle") { c.move(to:CGPoint(x:b.midX,y:b.minY)); c.addLine(to:CGPoint(x:b.midX,y:b.maxY)); c.move(to:CGPoint(x:b.minX,y:b.midY)); c.addLine(to:CGPoint(x:b.maxX,y:b.midY)); c.strokePath() } }
    }
    private func label(_ c: CGContext, _ r: CGRect, id: String) { let path=CGPath(roundedRect:r,cornerWidth:id.contains("ticket") ? 3 : r.height*0.14,cornerHeight:r.height*0.14,transform:nil); c.setAlpha(0.92); c.addPath(path); c.fillPath(); c.setBlendMode(.clear); c.fill(CGRect(x:r.minX+r.width*0.08,y:r.midY-r.height*0.035,width:r.width*0.84,height:r.height*0.07)); c.setBlendMode(.normal) }
    private func leak(_ c: CGContext, _ r: CGRect, color: CGColor) { c.setAlpha(0.30); c.drawLinearGradient(CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color,CGColor(srgbRed:1,green:0.58,blue:0.28,alpha:0.25),CGColor(srgbRed:1,green:0.8,blue:0.4,alpha:0)] as CFArray,locations:[0,0.45,1])!,start:CGPoint(x:r.minX,y:r.minY),end:CGPoint(x:r.maxX,y:r.maxY),options:[]) }
    private func speckles(_ c: CGContext, _ r: CGRect, rng: inout KitRandom, count: Int) { c.setAlpha(0.38); for _ in 0..<count { let x=r.minX+CGFloat(rng.nextUnit())*r.width,y=r.minY+CGFloat(rng.nextUnit())*r.height,s=CGFloat(rng.nextUnit())*(category == .dust ? 2.4 : 1.4)+0.35; c.fillEllipse(in:CGRect(x:x,y:y,width:s,height:s)) } }
    private func shape(_ c: CGContext, _ r: CGRect, id: String) { if id.contains("circle") { c.addEllipse(in:r.insetBy(dx:r.width*0.06,dy:r.height*0.06)); c.strokePath() } else { c.addPath(CGPath(roundedRect:r,cornerWidth:min(r.width,r.height)*0.16,cornerHeight:min(r.width,r.height)*0.16,transform:nil)); c.fillPath() } }
    private func palette(for id:String)->CGColor { let colors:[(CGFloat,CGFloat,CGFloat)]=[(0.76,0.45,0.34),(0.79,0.66,0.44),(0.40,0.55,0.50),(0.70,0.68,0.59),(0.55,0.48,0.39)]; let i=abs(id.utf8.reduce(0){($0 &* 31) &+ Int($1)})%colors.count; let v=colors[i]; return CGColor(srgbRed:v.0,green:v.1,blue:v.2,alpha:0.72) }
}

private struct KitRandom { var state: UInt64; init(seed:UInt64){state=seed == 0 ? 0x9E3779B97F4A7C15 : seed}; mutating func nextUnit() -> Double { state ^= state >> 12; state ^= state << 25; state ^= state >> 27; return Double(state &* 0x2545F4914F6CDD1D >> 11)/Double(UInt64.max >> 11) } }

import Core
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

/// Rasterizes document layers directly, slicing the document-space canvas for each output slide.
public struct DocumentRenderer: Sendable {
    public init() {}

    public func render(_ document: CanvasDocument, photos: [AssetID: PhotoRecord], sourceFolder: URL,
                       outputDirectory: URL, recipe: Recipe? = nil, recipeText: String? = nil) throws -> CarouselRenderer.Outcome {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var result = CarouselRenderer.Outcome()
        for slide in 0..<document.slideCount {
            let name = String(format: "slide-%02d.png", slide + 1)
            do {
                let image = try renderSlide(document, slide: slide, photos: photos, sourceFolder: sourceFolder,
                                            recipe: recipe, recipeText: recipeText)
                try CarouselRenderer.writePNG(image, to: outputDirectory.appending(path: name))
                result.names.append(name)
            } catch { result.failures.append("slide \(slide + 1): \(error)") }
        }
        return result
    }

    /// Renders one document revision using exactly the same painter and treatment path as export.
    /// iOS previews can call this without maintaining a separate approximation of the document renderer.
    public func renderSlide(_ document: CanvasDocument, slide: Int, photos: [AssetID: PhotoRecord], sourceFolder: URL) throws -> CGImage {
        try renderSlide(document, slide: slide, photos: photos, sourceFolder: sourceFolder, recipe: nil, recipeText: nil)
    }

    private func renderSlide(_ document: CanvasDocument, slide: Int, photos: [AssetID: PhotoRecord], sourceFolder: URL,
                             recipe: Recipe?, recipeText: String?) throws -> CGImage {
        guard (0..<document.slideCount).contains(slide) else { throw RenderError.encodeFailed("slide index \(slide) is outside the document") }
        if isLegacyConversion(document), let carousel = legacyCarousel(document) {
            let seed = UInt64(document.seed, radix: 16) ?? 0
            return try CarouselRenderer().renderSlide(carousel.slides[slide], aspect: document.aspect, photos: photos,
                sourceFolder: sourceFolder, seed: seed &+ UInt64(slide) &* 0x9E37, recipe: recipe,
                recipeText: recipeText, slideCount: document.slideCount)
        }
        return try draw(document, slide: slide, photos: photos, sourceFolder: sourceFolder)
    }

    private func legacyCarousel(_ document: CanvasDocument) -> ResolvedCarousel? {
        let slides = (0..<document.slideCount).map { index -> ResolvedSlide in
            let elements = document.layers(onSlide: index).map { layer in
                ResolvedElement(kind: layer.kind == .photo ? .photo : layer.kind == .text ? .stamp : .tape,
                                assetID: layer.assetID, text: layer.string,
                                frame: UnitRect(x: layer.frame.x * Double(document.slideCount) - Double(index), y: layer.frame.y,
                                                width: layer.frame.width * Double(document.slideCount), height: layer.frame.height),
                                rotationDegrees: layer.rotation, crop: layer.crop, zIndex: layer.z, opacity: layer.opacity,
                                border: layer.border, shadow: layer.shadow, adjustments: layer.adjustments,
                                fontID: layer.fontID, fontSize: layer.size, textColor: layer.colour,
                                alignment: layer.alignment, lineSpacing: layer.lineHeight, letterSpacing: layer.tracking,
                                numberOfLines: layer.lineCount, textRole: layer.textRole)
            }
            return ResolvedSlide(index: index, primitive: .fullBleed, requestedPrimitive: .fullBleed,
                                 background: document.slideBackgrounds[safe: index] ?? "plain",
                                 grain: document.slideGrain[safe: index] ?? 0, filmEdge: document.slideFilmEdges[safe: index] ?? false,
                                 elements: elements, warnings: [], variant: document.slideVariants?[safe: index] ?? nil)
        }
        return ResolvedCarousel(id: document.id, aspect: document.aspect, seed: document.seed,
                                resolverVersion: ResolvedCarousel.resolverVersion, slides: slides)
    }

    private func isLegacyConversion(_ d: CanvasDocument) -> Bool {
        guard !d.layers.isEmpty, !d.seamless, d.recipeID == nil, d.templateID == nil,
              !(d.slideVariants?.contains(where: { $0?.hasPrefix("template.") == true }) ?? false),
              d.sourcePlanID == d.id, d.slideBackgrounds.count == d.slideCount else { return false }
        // `ResolvedElement` (the legacy bridge target) has no `mask` field, so a photo layer carrying a real
        // mask (rounded/torn) must never be misrouted through legacyRender, which would silently drop it.
        return d.layers.allSatisfy { l in
            (l.mask == nil || l.mask == .rect) &&
            (l.kind == .photo || (l.kind == .text && l.fontID == "DSEG7Classic-Bold") ||
             (l.kind == .sticker && l.assetID == nil && l.string == nil))
        }
    }

    private func draw(_ d: CanvasDocument, slide: Int, photos: [AssetID: PhotoRecord], sourceFolder: URL) throws -> CGImage {
        let w=d.aspect.exportWidth, h=d.aspect.exportHeight
        let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        let canvas=CGRect(x:0,y:0,width:w,height:h)
        let renderSeed = (UInt64(d.seed, radix: 16) ?? seedValue(d.seed)) &+ UInt64(slide) &* 0x9E37
        var rng = SeededRandom(seed: renderSeed)
        drawBackground(d, slide: slide, in: ctx, canvas: canvas, photos: photos, sourceFolder: sourceFolder, rng: &rng)
        let sliceX=Double(slide)*Double(w)
        ctx.saveGState(); ctx.translateBy(x: -CGFloat(sliceX), y: 0)
        let docW=Double(w)*Double(d.slideCount)
        for l in d.layers(onSlide: slide).sorted(by:{$0.z<$1.z}) {
            let rect=CGRect(x:CGFloat(l.frame.x*docW),y:CGFloat(Double(h)-(l.frame.y+l.frame.height)*Double(h)),width:CGFloat(l.frame.width*docW),height:CGFloat(l.frame.height*Double(h)))
            ctx.saveGState(); ctx.translateBy(x:rect.midX,y:rect.midY); ctx.rotate(by: -l.rotation * .pi / 180)
            let r=CGRect(x:-rect.width/2,y:-rect.height/2,width:rect.width,height:rect.height)
            ctx.setAlpha(l.opacity)
            switch l.kind {
            case .frame:
                guard let photoID = l.assetID, let record = photos[photoID],
                      let frameID = l.frameAssetID, let frame = FrameAssetRegistry.asset(imageAssetID: frameID),
                      let frameImage = FrameAssetRegistry.image(imageAssetID: frameID) else { continue }
                let window = frame.photoWindow
                let photoRect = CGRect(x: r.minX + CGFloat(window.x) * r.width,
                                       y: r.minY + CGFloat(1 - window.y - window.height) * r.height,
                                       width: CGFloat(window.width) * r.width, height: CGFloat(window.height) * r.height)
                let source = sourceFolder.appending(path: record.sourceRelativePaths[0])
                let photo = try CarouselRenderer.decodeCropped(source, record: record,
                    crop: l.crop ?? UnitRect(x: 0, y: 0, width: 1, height: 1), frame: photoRect.size)
                ctx.saveGState(); ctx.clip(to: photoRect); ctx.draw(photo, in: photoRect); ctx.restoreGState()
                ctx.draw(frameImage, in: r)
            case .photo:
                guard let id=l.assetID,let record=photos[id] else { continue }
                let src=sourceFolder.appending(path:record.sourceRelativePaths[0])
                var img=try CarouselRenderer.decodeCropped(src,record:record,crop:l.crop ?? UnitRect(x:0,y:0,width:1,height:1),frame:r.size)
                img=adjust(img,l.adjustments)
                if l.shadow { ctx.setShadow(offset:CGSize(width:0,height:-0.006*Double(min(w,h))),blur:0.022*Double(min(w,h)),color:CGColor(gray:0,alpha:0.28)) }
                if l.border>0 { let b=CGFloat(l.border*Double(min(w,h)));ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(r.insetBy(dx:-b,dy:-b));ctx.setShadow(offset:.zero,blur:0,color:nil) }
                if let radius = l.cornerRadius, radius > 0 {
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) * CGFloat(radius),
                                       cornerHeight: min(r.width, r.height) * CGFloat(radius), transform: nil))
                    ctx.clip()
                } else if let mask=l.mask { ctx.addPath(maskPath(mask,r:r,seed:seedValue(d.seed)));ctx.clip() }
                ctx.draw(img,in:r)
            case .text:
                if l.shapeKind == "legacy-stamp" {
                    try StampRenderer.draw(ctx, text: l.string ?? "", rect: r, opacity: 1)
                } else {
                    drawText(ctx,l,r:r)
                }
            case .sticker, .texture:
                if l.kind == .sticker, l.shapeKind == "legacy-tape" {
                    // The layer's CGContext is already centered, rotated and alpha-adjusted above.
                    StyleLayer.tape(ctx, rect: r, rotationDegrees: 0, opacity: 1, rng: &rng)
                } else if let id=l.assetID?.rawValue,let asset=KitAssetRegistry.asset(id:id) {
                    ctx.setBlendMode(l.kind == .texture ? blend(l.textureBlend) : .normal)
                    asset.draw(in:ctx,rect:r,seed:seedValue(d.seed),tint:l.stickerTint.flatMap(color))
                }
            case .shape:
                let p=CGMutablePath(); let k=l.shapeKind ?? "rect"
                if k == "line" { p.move(to:CGPoint(x:r.minX,y:r.midY));p.addLine(to:CGPoint(x:r.maxX,y:r.midY)) }
                else if k == "roundedRect" { p.addRoundedRect(in:r,cornerWidth:min(r.width,r.height)*0.14,cornerHeight:min(r.width,r.height)*0.14) }
                else { p.addRect(r) }
                if let c=color(l.fill) { ctx.addPath(p);ctx.setFillColor(c);ctx.fillPath() }
                if let c=color(l.stroke) { ctx.addPath(p);ctx.setStrokeColor(c);ctx.setLineWidth(max(1,CGFloat(l.border)));ctx.strokePath() }
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
        if d.slideFilmEdges[safe: slide] == true { StyleLayer.filmEdge(ctx, size: canvas.size) }
        if let strength = d.slideGrain[safe: slide], strength > 0 { StyleLayer.grain(ctx, size: canvas.size, strength: strength, rng: &rng) }
        return ctx.makeImage()!
    }

    private func drawBackground(_ d: CanvasDocument, slide: Int, in c: CGContext, canvas: CGRect,
                                photos: [AssetID:PhotoRecord], sourceFolder:URL, rng: inout SeededRandom) {
        guard slide < d.slideBackgrounds.count else {
            drawFill(d.background, in: c, canvas: canvas, photos: photos, sourceFolder: sourceFolder)
            if case .paper = d.background { StyleLayer.paper(c, size: canvas.size, rng: &rng) }
            return
        }
        let raw = d.slideBackgrounds[slide]
        if raw == "paper" {
            c.setFillColor(CarouselRenderer.paperColor); c.fill(canvas); StyleLayer.paper(c, size: canvas.size, rng: &rng)
        } else if raw == "white" {
            c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(canvas)
        } else if raw.hasPrefix("wash:"), let asset = raw.split(separator: ":").dropFirst().first.map(String.init),
                  let record = photos[AssetID(rawValue: asset)] {
            let source = sourceFolder.appending(path: record.sourceRelativePaths[0])
            if let base = try? CarouselRenderer.decodeCropped(source, record: record,
                    crop: UnitRect(x: 0, y: 0, width: 1, height: 1),
                    frame: CGSize(width: canvas.width * 0.34, height: canvas.height * 0.34)),
               let wash = CarouselRenderer.photoWash(base, size: canvas.size) {
                c.draw(wash, in: canvas); c.setFillColor(CGColor(gray: 0, alpha: 0.24)); c.fill(canvas)
            } else { drawFill(d.background, in: c, canvas: canvas, photos: photos, sourceFolder: sourceFolder) }
        } else if raw.hasPrefix("#") || (raw.count == 6 && UInt32(raw, radix: 16) != nil) {
            drawFill(.colour(raw.hasPrefix("#") ? raw : "#\(raw)"), in: c, canvas: canvas, photos: photos, sourceFolder: sourceFolder)
        } else {
            drawFill(d.background, in: c, canvas: canvas, photos: photos, sourceFolder: sourceFolder)
        }
    }

    /// A per-slide hex or paper ground wins. `plain` keeps the document fill, which is how older layouts read.
    private func drawFill(_ fill: Fill, in c: CGContext, canvas: CGRect, photos:[AssetID:PhotoRecord], sourceFolder:URL) {
        switch fill {
        case .colour(let s): c.setFillColor(color(s) ?? CGColor(gray:1,alpha:1));c.fill(canvas)
        case .gradient(let values):
            let cs=values.compactMap(color); if cs.count>1,let g=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:cs as CFArray,locations:nil) { c.drawLinearGradient(g,start:CGPoint(x:0,y:canvas.maxY),end:CGPoint(x:canvas.maxX,y:canvas.minY),options:[]) }
            else { c.setFillColor(cs.first ?? CGColor(gray:1,alpha:1));c.fill(canvas) }
        case .paper(let id):
            c.setFillColor(CGColor(srgbRed:0.95,green:0.93,blue:0.88,alpha:1));c.fill(canvas)
            if let id=id,let a=KitAssetRegistry.asset(id:id.rawValue) { a.draw(in:c,rect:canvas,seed:0) }
        case .photo(let id,let blur,let dim):
            if let record=photos[id],let img=try? CarouselRenderer.decodeCropped(sourceFolder.appending(path:record.sourceRelativePaths[0]),record:record,crop:UnitRect(x:0,y:0,width:1,height:1),frame:canvas.size) {
                var out=img
                if blur>0 { let ci=CIImage(cgImage:img).clampedToExtent().applyingFilter("CIGaussianBlur",parameters:["inputRadius":blur]).cropped(to:CIImage(cgImage:img).extent); if let x=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(ci,from:ci.extent){out=x} }
                c.draw(out,in:canvas);c.setFillColor(CGColor(gray:0,alpha:dim));c.fill(canvas)
            } else { c.setFillColor(CGColor(gray:1,alpha:1));c.fill(canvas) }
        }
    }
    private func drawText(_ c:CGContext,_ l:DocumentLayer,r:CGRect) {
        if let bg=color(l.fill) { c.setFillColor(bg);c.fill(CGRect(x:r.minX,y:r.minY,width:r.width,height:r.height)) }
        guard let s=l.string else{return}; let font=BundledFonts.font(id:l.fontID ?? "font-inter",size:l.size ?? Double(r.height*0.7))
        var attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color(l.colour) ?? CGColor(gray:0,alpha:1)]
        if let t=l.tracking { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = t }
        let fontSize = l.size ?? Double(r.height * 0.7)
        if let lh=l.lineHeight { attrs[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = paragraph(l.alignment ?? "left", fontSize + lh) }
        let attributed = NSAttributedString(string: s, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: r, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        c.textMatrix = .identity
        CTFrameDraw(frame, c)
    }
    private func paragraph(_ align: String, _ height: Double) -> CTParagraphStyle {
        var alignment: CTTextAlignment = align == "center" ? .center : align == "right" ? .right : .left
        var lineHeight = CGFloat(height)
        return withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &lineHeight) { heightPointer in
                var settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                            value: alignmentPointer),
                    CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size,
                                            value: heightPointer),
                    CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size,
                                            value: heightPointer),
                ]
                return CTParagraphStyleCreate(&settings, settings.count)
            }
        }
    }
    private func adjust(_ image: CGImage, _ a: PhotoAdjustments?) -> CGImage {
        PhotoAdjustmentFilter.apply(to: image, adjustments: a)
    }
    private func maskPath(_ m:Mask,r:CGRect,seed:UInt64)->CGPath { if m == .rounded { return CGPath(roundedRect:r,cornerWidth:min(r.width,r.height)*0.12,cornerHeight:min(r.width,r.height)*0.12,transform:nil) };if m == .torn { let p=CGMutablePath();p.move(to:CGPoint(x:r.minX,y:r.minY));for i in 0...24 {p.addLine(to:CGPoint(x:r.minX+r.width*CGFloat(i)/24,y:r.minY+((i+Int(seed%3))%2 == 0 ? 0:r.height*0.035)))};p.addLine(to:CGPoint(x:r.maxX,y:r.maxY));p.addLine(to:CGPoint(x:r.minX,y:r.maxY));p.closeSubpath();return p };return CGPath(rect:r,transform:nil) }
    private func blend(_ s:String?)->CGBlendMode { switch s {case "multiply":.multiply;case "screen":.screen;case "overlay":.overlay;case "softLight":.softLight;default:.normal} }
    private func color(_ s:String?)->CGColor? { guard let s=s else{return nil};let v=s.trimmingCharacters(in:CharacterSet(charactersIn:"#"));guard v.count==6,let n=UInt32(v,radix:16) else{return nil};return CGColor(srgbRed:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,alpha:1) }
    private func seedValue(_ s:String)->UInt64 { s.utf8.reduce(0){($0 &* 31) &+ UInt64($1)} }
}
private extension Collection { subscript(safe i:Index)->Element? { indices.contains(i) ? self[i] : nil } }

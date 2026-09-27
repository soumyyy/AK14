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
                       outputDirectory: URL) throws -> CarouselRenderer.Outcome {
        // Keep the historical renderer for documents produced by the lossless ResolvedCarousel bridge.
        if isLegacyConversion(document) {
            let slides = (0..<document.slideCount).map { index in
                let elements = document.layers(onSlide: index).map { layer in
                    ResolvedElement(kind: layer.kind == .photo ? .photo : layer.kind == .text ? .stamp : .tape,
                                    assetID: layer.assetID, text: layer.string,
                                    frame: UnitRect(x: layer.frame.x * Double(document.slideCount) - Double(index), y: layer.frame.y,
                                                    width: layer.frame.width * Double(document.slideCount), height: layer.frame.height),
                                    rotationDegrees: layer.rotation, crop: layer.crop, zIndex: layer.z, opacity: layer.opacity,
                                    border: layer.border, shadow: layer.shadow, adjustments: layer.adjustments)
                }
                return ResolvedSlide(index: index, primitive: .fullBleed, requestedPrimitive: .fullBleed,
                                     background: document.slideBackgrounds[safe: index] ?? "plain",
                                     grain: document.slideGrain[safe: index] ?? 0, filmEdge: document.slideFilmEdges[safe: index] ?? false,
                                     elements: elements, warnings: [])
            }
            let carousel = ResolvedCarousel(id: document.id, aspect: document.aspect, seed: document.seed,
                                            resolverVersion: ResolvedCarousel.resolverVersion, slides: slides)
            return try CarouselRenderer().legacyRender(carousel, photos: photos, sourceFolder: sourceFolder, outputDirectory: outputDirectory)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var result = CarouselRenderer.Outcome()
        for slide in 0..<document.slideCount {
            let name = String(format: "slide-%02d.png", slide + 1)
            do {
                let image = try draw(document, slide: slide, photos: photos, sourceFolder: sourceFolder)
                try CarouselRenderer.writePNG(image, to: outputDirectory.appending(path: name))
                result.names.append(name)
            } catch { result.failures.append("slide \(slide + 1): \(error)") }
        }
        return result
    }

    private func isLegacyConversion(_ d: CanvasDocument) -> Bool {
        guard !d.layers.isEmpty else { return false }
        return d.layers.allSatisfy { l in
            l.kind == .photo || (l.kind == .text && l.fontID == "DSEG7Classic-Bold") ||
            (l.kind == .sticker && l.assetID == nil && l.string == nil)
        }
    }

    private func draw(_ d: CanvasDocument, slide: Int, photos: [AssetID: PhotoRecord], sourceFolder: URL) throws -> CGImage {
        let w=d.aspect.exportWidth, h=d.aspect.exportHeight
        let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        let canvas=CGRect(x:0,y:0,width:w,height:h)
        drawFill(d.background, in: ctx, canvas: canvas, photos: photos, sourceFolder: sourceFolder)
        let sliceX=Double(slide)*Double(w)
        ctx.saveGState(); ctx.translateBy(x: -CGFloat(sliceX), y: 0)
        let docW=Double(w)*Double(d.slideCount)
        for l in d.layers(onSlide: slide).sorted(by:{$0.z<$1.z}) {
            let rect=CGRect(x:CGFloat(l.frame.x*docW),y:CGFloat(Double(h)-(l.frame.y+l.frame.height)*Double(h)),width:CGFloat(l.frame.width*docW),height:CGFloat(l.frame.height*Double(h)))
            ctx.saveGState(); ctx.translateBy(x:rect.midX,y:rect.midY); ctx.rotate(by: -l.rotation * .pi / 180)
            let r=CGRect(x:-rect.width/2,y:-rect.height/2,width:rect.width,height:rect.height)
            ctx.setAlpha(l.opacity)
            switch l.kind {
            case .photo:
                guard let id=l.assetID,let record=photos[id] else { continue }
                let src=sourceFolder.appending(path:record.sourceRelativePaths[0])
                var img=try CarouselRenderer.decodeCropped(src,record:record,crop:l.crop ?? UnitRect(x:0,y:0,width:1,height:1),frame:r.size)
                img=adjust(img,l.adjustments)
                if l.shadow { ctx.setShadow(offset:CGSize(width:0,height:-0.006*Double(min(w,h))),blur:0.022*Double(min(w,h)),color:CGColor(gray:0,alpha:0.28)) }
                if l.border>0 { let b=CGFloat(l.border*Double(min(w,h)));ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(r.insetBy(dx:-b,dy:-b));ctx.setShadow(offset:.zero,blur:0,color:nil) }
                if let mask=l.mask { ctx.addPath(maskPath(mask,r:r,seed:seedValue(d.seed)));ctx.clip() }
                ctx.draw(img,in:r)
            case .text:
                drawText(ctx,l,r:r)
            case .sticker, .texture:
                if let id=l.assetID?.rawValue,let asset=KitAssetRegistry.asset(id:id) {
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
        return ctx.makeImage()!
    }

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
        if let lh=l.lineHeight { attrs[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = paragraph(l.alignment ?? "left",lh) }
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:s,attributes:attrs)); c.textMatrix = .identity
        let width=CTLineGetTypographicBounds(line,nil,nil,nil); let x=(l.alignment == "center" ? r.midX-width/2 : l.alignment == "right" ? r.maxX-width : r.minX)
        c.textPosition=CGPoint(x:x,y:r.midY-(l.size ?? Double(r.height*0.7))*0.35);CTLineDraw(line,c)
    }
    private func paragraph(_ align:String,_ height:Double)->CTParagraphStyle { var a:CTTextAlignment=align == "center" ? .center : align == "right" ? .right : .left;var h=CGFloat(height);var settings=[CTParagraphStyleSetting(spec:.alignment, valueSize:MemoryLayout<CTTextAlignment>.size,value:&a),CTParagraphStyleSetting(spec:.minimumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:&h),CTParagraphStyleSetting(spec:.maximumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:&h)];return CTParagraphStyleCreate(&settings,settings.count) }
    private func adjust(_ image:CGImage,_ a:PhotoAdjustments?)->CGImage { guard let a=a else{return image};var ci=CIImage(cgImage:image);if a.exposure != 0 {ci=ci.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:a.exposure])};if a.contrast != 0 {ci=ci.applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:1+a.contrast])};if a.saturation != 0 {ci=ci.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:1+a.saturation])};if a.warmth != 0 {ci=ci.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500-a.warmth*1000,y:0)])};return CIContext(options:[.useSoftwareRenderer:true]).createCGImage(ci,from:ci.extent) ?? image }
    private func maskPath(_ m:Mask,r:CGRect,seed:UInt64)->CGPath { if m == .rounded { return CGPath(roundedRect:r,cornerWidth:min(r.width,r.height)*0.12,cornerHeight:min(r.width,r.height)*0.12,transform:nil) };if m == .torn { let p=CGMutablePath();p.move(to:CGPoint(x:r.minX,y:r.minY));for i in 0...24 {p.addLine(to:CGPoint(x:r.minX+r.width*CGFloat(i)/24,y:r.minY+((i+Int(seed%3))%2 == 0 ? 0:r.height*0.035)))};p.addLine(to:CGPoint(x:r.maxX,y:r.maxY));p.addLine(to:CGPoint(x:r.minX,y:r.maxY));p.closeSubpath();return p };return CGPath(rect:r,transform:nil) }
    private func blend(_ s:String?)->CGBlendMode { switch s {case "multiply":.multiply;case "screen":.screen;case "overlay":.overlay;case "softLight":.softLight;default:.normal} }
    private func color(_ s:String?)->CGColor? { guard let s=s else{return nil};let v=s.trimmingCharacters(in:CharacterSet(charactersIn:"#"));guard v.count==6,let n=UInt32(v,radix:16) else{return nil};return CGColor(srgbRed:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,alpha:1) }
    private func seedValue(_ s:String)->UInt64 { s.utf8.reduce(0){($0 &* 31) &+ UInt64($1)} }
}
private extension Collection { subscript(safe i:Index)->Element? { indices.contains(i) ? self[i] : nil } }

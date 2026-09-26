import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum KitPreview {
    public static func renderSheet(to url: URL) throws {
        let columns=6, cellW=220, cellH=175, rows=(KitAssetRegistry.all.count+columns-1)/columns
        let width=columns*cellW, height=rows*cellH
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.encodeFailed(url.path) }
        context.setFillColor(CGColor(srgbRed:0.96,green:0.945,blue:0.91,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        for (index,asset) in KitAssetRegistry.all.enumerated() {
            let col=index%columns,row=index/columns,x=col*cellW,y=row*cellH
            let rect=CGRect(x:x+24,y:y+22,width:cellW-48,height:cellH-62)
            asset.draw(in:context,rect:rect,seed:UInt64(index+1))
            let text=asset.id as CFString
            let font=CTFontCreateWithName("Helvetica" as CFString,11,nil)
            let attrs=[kCTFontAttributeName:font,kCTForegroundColorAttributeName:CGColor(gray:0.18,alpha:1)] as CFDictionary
            let line=CTLineCreateWithAttributedString(CFAttributedStringCreate(nil,text,attrs)!)
            context.textPosition=CGPoint(x:x+10,y:y+12); CTLineDraw(line,context)
        }
        guard let image=context.makeImage(),let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw RenderError.encodeFailed(url.path) }
        CGImageDestinationAddImage(destination,image,nil); guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed(url.path) }
    }
}

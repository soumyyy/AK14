import CoreGraphics
import CoreText
import Foundation

/// Film-camera date imprint using the bundled DSEG7 font (SIL OFL 1.1), loaded from bundle data
/// so rendering never depends on installed system fonts.
enum StampRenderer {
    static let fontData: Data? = Bundle.module.url(forResource: "DSEG7Classic-Bold", withExtension: "ttf",
                                                   subdirectory: "Assets/fonts").flatMap { try? Data(contentsOf: $0) }

    static func draw(_ ctx: CGContext, text: String, rect: CGRect, opacity: Double) throws {
        guard let data = fontData, let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else {
            throw RenderError.missingFont
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, rect.height * 0.9, nil)
        let orange = CGColor(srgbRed: 1.0, green: 0.52, blue: 0.12, alpha: opacity)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): orange,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: rect.height * 0.25, color: CGColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 0.7 * opacity))
        let x = rect.maxX - width, baseline = rect.minY + rect.height * 0.12
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        // Film-style year tick (') drawn as a path: DSEG7 has no apostrophe glyph, and falling back to a
        // system font would make output depend on installed fonts.
        let tick = CGRect(x: x - rect.height * 0.3, y: baseline + rect.height * 0.5, width: rect.height * 0.1, height: rect.height * 0.28)
        ctx.setFillColor(orange)
        ctx.fill(tick)
        ctx.restoreGState()
    }
}

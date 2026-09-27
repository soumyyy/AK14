import CoreGraphics
import CoreText
import Foundation

enum RecipeTypography {
    static func draw(_ context: CGContext, text: String, fontID: String, rect: CGRect,
                     size: CGFloat, color: CGColor) throws {
        let phrase = text.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;–—-"))
        guard !phrase.isEmpty else { return }
        let resource = String(fontID.dropFirst("font-".count))
        guard let url = Bundle.module.url(forResource: resource, withExtension: "ttf", subdirectory: "Assets/fonts"),
              let data = try? Data(contentsOf: url),
              let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return }
        var pointSize = size
        var font = CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
        var line = makeLine(phrase, font: font, color: color)
        while CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width, pointSize > 18 {
            pointSize *= 0.9
            font = CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
            line = makeLine(phrase, font: font, color: color)
        }
        guard CTLineGetTypographicBounds(line, nil, nil, nil) <= rect.width else { return }
        context.saveGState()
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + (rect.height - pointSize) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func makeLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}

import SwiftUI
import UIKit

/// Colors measured from the AK14 icon. Buttons use the field green. Text on those buttons uses cream.
enum AK14Palette {
    static let pine = Color(red: 0x1E / 255, green: 0x57 / 255, blue: 0x52 / 255)
    static let field = Color(red: 0x4D / 255, green: 0x7F / 255, blue: 0x76 / 255)
    static let cream = Color(red: 0xF9 / 255, green: 0xF6 / 255, blue: 0xF0 / 255)
    /// The green used on buttons. The screen itself stays black.
    static let accent = field
}

private struct AK14CardGlass: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension View {
    func ak14Card() -> some View { modifier(AK14CardGlass()) }
}

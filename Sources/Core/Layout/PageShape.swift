import Foundation

/// Shape of a photo or slot, width / height. Boundaries are the spec's: tall < 0.8, square 0.8–1.25, wide 1.25–2.0, band > 2.0.
public enum ShapeClass: String, Codable, Sendable, CaseIterable {
    case tall, square, wide, band
    public static func of(aspect: Double) -> ShapeClass {
        if aspect < 0.8 { return .tall }
        if aspect <= 1.25 { return .square }
        if aspect <= 2.0 { return .wide }
        return .band
    }
}

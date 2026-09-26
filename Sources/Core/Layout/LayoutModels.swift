import CryptoKit
import Foundation

public enum ElementKind: String, Codable, Sendable { case photo, tape, stamp }

/// One drawable element. `frame` is canvas-normalized with a top-left origin, before rotation
/// (rotation is about the frame centre, positive = clockwise). `crop` is source-normalized (oriented image).
public struct ResolvedElement: Codable, Sendable, Equatable {
    public var kind: ElementKind
    public var assetID: AssetID?
    public var text: String?
    public var frame: UnitRect
    public var rotationDegrees: Double
    public var crop: UnitRect?
    public var zIndex: Int
    public var opacity: Double
    /// White border width as a fraction of the canvas short side (photos only).
    public var border: Double
    public var shadow: Bool
}

public struct ResolvedSlide: Codable, Sendable, Equatable {
    public var index: Int
    public var primitive: Primitive
    public var requestedPrimitive: Primitive
    /// "none" (a full-bleed photo covers it), "plain" (off-white) or "paper" (textured).
    public var background: String
    /// Film-grain overlay strength, 0 = none.
    public var grain: Double
    public var filmEdge: Bool
    public var elements: [ResolvedElement]
    public var warnings: [String]
}

public struct ResolvedCarousel: Codable, Sendable, Equatable {
    public static let resolverVersion = "layout-1"
    public var conceptType: ConceptType
    public var aspect: CarouselAspect
    /// Hex seed (string to survive JSON number precision).
    public var seed: String
    public var resolverVersion: String
    public var slides: [ResolvedSlide]
}

/// Deterministic SplitMix64 generator.
public struct SeededRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    /// Seed derived from stable strings, e.g. runID + concept + resolver version.
    public static func seed(_ parts: String...) -> UInt64 {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    public mutating func bool() -> Bool { next() & 1 == 1 }
}

/// Axis-aligned rectangle in canvas pixels (top-left origin) used during resolution.
public struct Box: Sendable, Equatable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }
    public var area: Double { max(0, w) * max(0, h) }
    public func intersection(_ o: Box) -> Box {
        let nx = max(x, o.x), ny = max(y, o.y)
        return Box(x: nx, y: ny, w: max(0, min(maxX, o.maxX) - nx), h: max(0, min(maxY, o.maxY) - ny))
    }
    public func intersects(_ o: Box) -> Bool { intersection(o).area > 0 }
    public func inset(_ d: Double) -> Box { Box(x: x + d, y: y + d, w: w - 2 * d, h: h - 2 * d) }
    public func unit(canvasW: Double, canvasH: Double) -> UnitRect {
        UnitRect(x: x / canvasW, y: y / canvasH, width: w / canvasW, height: h / canvasH)
    }
}

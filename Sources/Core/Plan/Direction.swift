import Foundation

/// Shared style axes every direction is described on. The composer engine reads these; nothing branches on names.
public struct StyleVector: Codable, Sendable, Equatable, Hashable {
    public var density: String      // quiet | balanced | dense | varied
    public var overlap: String      // none | some | bold
    public var grouping: String     // single | mixed | collage
    public var decoration: String   // none | light | rich
    public var rotation: String     // none | some
    public var whitespace: String   // tight | airy

    public init(density: String, overlap: String, grouping: String, decoration: String, rotation: String, whitespace: String) {
        self.density = density; self.overlap = overlap; self.grouping = grouping
        self.decoration = decoration; self.rotation = rotation; self.whitespace = whitespace
    }

    public static let axes: [(name: String, values: [String])] = [
        ("density", ["quiet", "balanced", "dense", "varied"]), ("overlap", ["none", "some", "bold"]),
        ("grouping", ["single", "mixed", "collage"]), ("decoration", ["none", "light", "rich"]),
        ("rotation", ["none", "some"]), ("whitespace", ["tight", "airy"]),
    ]

    /// The photos-only control: one photo per slide, edge to edge, nothing added.
    public static let baseline = StyleVector(density: "balanced", overlap: "none", grouping: "single",
                                             decoration: "none", rotation: "none", whitespace: "tight")

    var values: [String] { [density, overlap, grouping, decoration, rotation, whitespace] }

    /// Fraction of axes that differ (0 = identical, 1 = every axis differs).
    public func distance(to o: StyleVector) -> Double {
        Double(zip(values, o.values).filter { $0 != $1 }.count) / Double(values.count)
    }

    public var summary: String {
        "density \(density) · overlap \(overlap) · grouping \(grouping) · decoration \(decoration) · rotation \(rotation) · \(whitespace)"
    }

    /// Replaces unknown axis values with the baseline's so a hand-edited plan cannot break composition.
    public var normalized: StyleVector {
        var v = self
        let fix = { (value: String, axis: Int, fallback: String) in Self.axes[axis].values.contains(value) ? value : fallback }
        v.density = fix(density, 0, "balanced"); v.overlap = fix(overlap, 1, "none"); v.grouping = fix(grouping, 2, "single")
        v.decoration = fix(decoration, 3, "none"); v.rotation = fix(rotation, 4, "none"); v.whitespace = fix(whitespace, 5, "tight")
        return v
    }
}

/// A creative direction from the model: what story to tell and how it should feel. The composer engine turns it
/// into slides; the model never writes slides, primitives or coordinates.
public struct Direction: Codable, Sendable, Equatable {
    /// One internal sentence written for these photos (operator-facing only).
    public var brief: String
    public var style: StyleVector
    public var coverAssetID: AssetID
    /// Photos in story order (usually the spine, possibly with a few additions or drops).
    public var orderedAssetIDs: [AssetID]
    /// Photos that belong on the same slide.
    public var keepTogether: [[AssetID]]
    /// Photos that deserve a slide of their own.
    public var emphasisAssetIDs: [AssetID]
    public var seamless: Bool
    public var titleIdea: String?

    public init(brief: String, style: StyleVector, coverAssetID: AssetID, orderedAssetIDs: [AssetID],
                keepTogether: [[AssetID]] = [], emphasisAssetIDs: [AssetID] = [], seamless: Bool = false, titleIdea: String? = nil) {
        self.brief = brief; self.style = style; self.coverAssetID = coverAssetID; self.orderedAssetIDs = orderedAssetIDs
        self.keepTogether = keepTogether; self.emphasisAssetIDs = emphasisAssetIDs
        self.seamless = seamless; self.titleIdea = titleIdea.map { String($0.prefix(40)) }
    }
}

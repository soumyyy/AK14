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
    public struct Moment: Codable, Sendable, Equatable {
        public var label: String
        public var photos: [AssetID]
        public var mustInclude: [AssetID]
        public var size: String

        public init(label: String, photos: [AssetID], mustInclude: [AssetID], size: String) {
            self.label = label; self.photos = photos; self.mustInclude = mustInclude; self.size = size
        }

        public var sizeRange: ClosedRange<Int> { size == "1" ? 1...1 : size == "few" ? 2...3 : 4...9 }
    }

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
    public var moments: [Moment]
    public var coverCandidates: [AssetID]
    public var titleIdeas: [String]

    private enum CodingKeys: String, CodingKey {
        case brief, style, coverAssetID, orderedAssetIDs, keepTogether, emphasisAssetIDs, seamless, titleIdea
        case moments, coverCandidates, titleIdeas
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(brief: try c.decode(String.self, forKey: .brief),
                  style: try c.decode(StyleVector.self, forKey: .style),
                  coverAssetID: try c.decode(AssetID.self, forKey: .coverAssetID),
                  orderedAssetIDs: try c.decode([AssetID].self, forKey: .orderedAssetIDs),
                  keepTogether: try c.decodeIfPresent([[AssetID]].self, forKey: .keepTogether) ?? [],
                  emphasisAssetIDs: try c.decodeIfPresent([AssetID].self, forKey: .emphasisAssetIDs) ?? [],
                  seamless: try c.decodeIfPresent(Bool.self, forKey: .seamless) ?? false,
                  titleIdea: try c.decodeIfPresent(String.self, forKey: .titleIdea),
                  moments: try c.decodeIfPresent([Moment].self, forKey: .moments) ?? [],
                  coverCandidates: try c.decodeIfPresent([AssetID].self, forKey: .coverCandidates) ?? [],
                  titleIdeas: try c.decodeIfPresent([String].self, forKey: .titleIdeas) ?? [])
    }

    public init(brief: String, style: StyleVector, coverAssetID: AssetID, orderedAssetIDs: [AssetID],
                keepTogether: [[AssetID]] = [], emphasisAssetIDs: [AssetID] = [], seamless: Bool = false, titleIdea: String? = nil,
                moments: [Moment] = [], coverCandidates: [AssetID] = [], titleIdeas: [String] = []) {
        self.brief = brief; self.style = style; self.coverAssetID = coverAssetID; self.orderedAssetIDs = orderedAssetIDs
        self.keepTogether = keepTogether; self.emphasisAssetIDs = emphasisAssetIDs
        self.seamless = seamless; self.titleIdea = Self.cleanTitle(titleIdea)
        self.moments = moments; self.coverCandidates = coverCandidates
        self.titleIdeas = titleIdeas.compactMap(Self.cleanTitle)
        if !moments.isEmpty {
            self.orderedAssetIDs = moments.flatMap(\.photos)
            self.coverAssetID = coverCandidates.first ?? coverAssetID
            self.titleIdea = self.titleIdeas.first ?? self.titleIdea
        }
    }
}

extension Direction {
    /// Models sometimes write a placeholder instead of JSON null. Such a word must never reach a slide.
    static func cleanTitle(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let placeholders: Set<String> = ["null", "nil", "none", "n/a", "na", "untitled", "no title", "title"]
        guard !placeholders.contains(text.lowercased()) else { return nil }
        return String(text.prefix(40))
    }
}

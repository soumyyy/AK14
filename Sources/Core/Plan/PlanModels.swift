import Foundation

public enum Primitive: String, Codable, Sendable, CaseIterable {
    case fullBleed = "full_bleed", hero, framedHero = "framed_hero", inset
    case asymmetricPair = "asymmetric_pair", overlapCluster = "overlap_cluster"

    public var photoRange: ClosedRange<Int> {
        switch self {
        case .fullBleed, .hero, .framedHero: 1...1
        case .inset, .asymmetricPair: 2...2
        case .overlapCluster: 2...4
        }
    }
}

public enum SequenceIntent: String, Codable, Sendable, CaseIterable { case opener, build, peak, breather, detail, closer }

public struct SpineRationale: Codable, Sendable, Equatable {
    public var id: AssetID
    public var reason: String
}

public struct TransitionRationale: Codable, Sendable, Equatable {
    public var from: AssetID
    public var to: AssetID
    public var reason: String
}

public struct SelectionSpine: Codable, Sendable, Equatable {
    public var orderedAssetIDs: [AssetID]
    public var sequenceIntent: [SequenceIntent]
    public var rationale: [SpineRationale]
    public var transitionReasons: [TransitionRationale]?
    public init(orderedAssetIDs: [AssetID], sequenceIntent: [SequenceIntent], rationale: [SpineRationale],
                transitionReasons: [TransitionRationale]? = nil) {
        self.orderedAssetIDs = orderedAssetIDs; self.sequenceIntent = sequenceIntent; self.rationale = rationale
        self.transitionReasons = transitionReasons
    }
    public var coverAssetID: AssetID? { orderedAssetIDs.first }
}

public struct PhotoElement: Codable, Sendable, Equatable {
    public var assetID: AssetID
    public var role: String            // hero | support | detail
    public var importance: Int         // 1...3
    public var cropIntent: String      // tight | balanced | loose
    public var anchorIntent: String    // center | top | bottom | left | right
    public var overlapIntent: String   // none | slight | strong
    public var rotationIntent: String  // none | slightLeft | slightRight

    public static func plain(_ id: AssetID) -> PhotoElement {
        PhotoElement(assetID: id, role: "hero", importance: 3, cropIntent: "balanced", anchorIntent: "center",
                     overlapIntent: "none", rotationIntent: "none")
    }
}

public struct DecorationElement: Codable, Sendable, Equatable {
    public var decorationID: String
    public var intensity: String       // low | medium | high
}

public struct StampElement: Codable, Sendable, Equatable {
    public var kind: String            // date | location
    public var placement: String       // topLeft | topRight | bottomLeft | bottomRight
}

public struct SlidePlan: Codable, Sendable, Equatable {
    public var primitive: Primitive
    public var mood: String
    public var density: String         // quiet | balanced | dense
    public var photos: [PhotoElement]
    public var decorations: [DecorationElement]
    public var stamps: [StampElement]
    public var placement: SlidePlacement?
    public init(primitive: Primitive, mood: String, density: String, photos: [PhotoElement],
                decorations: [DecorationElement], stamps: [StampElement], placement: SlidePlacement? = nil) {
        self.primitive = primitive; self.mood = mood; self.density = density
        self.photos = photos; self.decorations = decorations; self.stamps = stamps
        self.placement = placement
    }

    enum CodingKeys: String, CodingKey { case primitive, mood, density, photos, decorations, stamps, placement }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primitive = try c.decode(Primitive.self, forKey: .primitive)
        mood = try c.decode(String.self, forKey: .mood)
        density = try c.decode(String.self, forKey: .density)
        photos = try c.decode([PhotoElement].self, forKey: .photos)
        decorations = try c.decode([DecorationElement].self, forKey: .decorations)
        stamps = try c.decode([StampElement].self, forKey: .stamps)
        placement = try c.decodeIfPresent(SlidePlacement.self, forKey: .placement)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(primitive, forKey: .primitive); try c.encode(mood, forKey: .mood)
        try c.encode(density, forKey: .density); try c.encode(photos, forKey: .photos)
        try c.encode(decorations, forKey: .decorations); try c.encode(stamps, forKey: .stamps)
        try c.encodeIfPresent(placement, forKey: .placement)
    }
}

public struct SlidePlacement: Codable, Sendable, Equatable {
    public var catalogueVersion: Int
    public var pageID: String
    public var runOffset: Int
    public var runLength: Int
    public var placed: [SlotAssignment.Placed]
    public var slide: ResolvedSlide?
    public init(catalogueVersion: Int, pageID: String, runOffset: Int, runLength: Int,
                placed: [SlotAssignment.Placed], slide: ResolvedSlide?) {
        self.catalogueVersion = catalogueVersion; self.pageID = pageID; self.runOffset = runOffset
        self.runLength = runLength; self.placed = placed; self.slide = slide
    }
}

/// One carousel option. `id` is opaque: `baseline` (the photos-only control) or `c1`…`c5` (model directions).
/// Runs made before the composer engine keep their old ids (`plainDump`, `designed`, `wildcard`) so their
/// directories and events still resolve.
public struct CarouselPlan: Codable, Sendable, Equatable {
    public static let baselineID = "baseline"
    public var id: String
    /// Internal one-sentence brief (operator-facing, never shown to participants).
    public var brief: String
    /// The direction this plan was composed from (nil for legacy plans); lets Studio recompose without a model call.
    public var direction: Direction?
    /// Hex seed the composer used; with `direction` it reproduces the plan exactly (nil for legacy plans).
    public var compositionSeed: String?
    public var recipeID: String?
    public var slides: [SlidePlan]

    public init(id: String, brief: String, direction: Direction?, compositionSeed: String? = nil, recipeID: String? = nil, slides: [SlidePlan]) {
        self.id = id; self.brief = brief; self.direction = direction; self.compositionSeed = compositionSeed; self.slides = slides
        self.recipeID = recipeID
    }

    public var style: StyleVector? { direction?.style }
    /// The photos-only control (including the legacy Plain Dump).
    public var isBaseline: Bool { id == Self.baselineID || id == "plainDump" }
    public var photoAssetIDs: [AssetID] { slides.flatMap { $0.photos.map(\.assetID) } }
    public var coverAssetID: AssetID? {
        slides.first.flatMap { s in (s.photos.first { $0.role == "hero" } ?? s.photos.first)?.assetID }
    }

    enum CodingKeys: String, CodingKey { case id, brief, direction, compositionSeed, recipeID, slides, conceptType, conceptNote }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? c.decode(String.self, forKey: .conceptType)
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? c.decodeIfPresent(String.self, forKey: .conceptNote) ?? ""
        direction = try c.decodeIfPresent(Direction.self, forKey: .direction)
        compositionSeed = try c.decodeIfPresent(String.self, forKey: .compositionSeed)
        recipeID = try c.decodeIfPresent(String.self, forKey: .recipeID)
        slides = try c.decode([SlidePlan].self, forKey: .slides)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(brief, forKey: .brief)
        try c.encodeIfPresent(direction, forKey: .direction); try c.encodeIfPresent(compositionSeed, forKey: .compositionSeed)
        try c.encodeIfPresent(recipeID, forKey: .recipeID)
        try c.encode(slides, forKey: .slides)
    }
}

public struct PlannerResponse: Codable, Sendable, Equatable {
    public var recommendedSlideCount: Int
    public var spine: SelectionSpine
    public var directions: [Direction]
    public init(recommendedSlideCount: Int, spine: SelectionSpine, directions: [Direction]) {
        self.recommendedSlideCount = recommendedSlideCount; self.spine = spine; self.directions = directions
    }
}

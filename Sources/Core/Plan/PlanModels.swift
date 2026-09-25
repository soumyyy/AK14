import Foundation

public enum ConceptType: String, Codable, Sendable, CaseIterable { case plainDump, designed, wildcard }

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

public struct SelectionSpine: Codable, Sendable, Equatable {
    public var orderedAssetIDs: [AssetID]
    public var sequenceIntent: [SequenceIntent]
    public var rationale: [SpineRationale]
    public init(orderedAssetIDs: [AssetID], sequenceIntent: [SequenceIntent], rationale: [SpineRationale]) {
        self.orderedAssetIDs = orderedAssetIDs; self.sequenceIntent = sequenceIntent; self.rationale = rationale
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
    public init(primitive: Primitive, mood: String, density: String, photos: [PhotoElement],
                decorations: [DecorationElement], stamps: [StampElement]) {
        self.primitive = primitive; self.mood = mood; self.density = density
        self.photos = photos; self.decorations = decorations; self.stamps = stamps
    }
}

public struct CarouselPlan: Codable, Sendable, Equatable {
    public var conceptType: ConceptType
    public var conceptNote: String
    public var slides: [SlidePlan]
    public init(conceptType: ConceptType, conceptNote: String, slides: [SlidePlan]) {
        self.conceptType = conceptType; self.conceptNote = conceptNote; self.slides = slides
    }

    public var photoAssetIDs: [AssetID] { slides.flatMap { $0.photos.map(\.assetID) } }
    public var coverAssetID: AssetID? {
        slides.first.flatMap { s in (s.photos.first { $0.role == "hero" } ?? s.photos.first)?.assetID }
    }

    /// One full-bleed photo per slide, no decoration or text, in spine order.
    public static func plainDump(from spine: SelectionSpine, note: String) -> CarouselPlan {
        CarouselPlan(conceptType: .plainDump, conceptNote: note, slides: spine.orderedAssetIDs.map {
            SlidePlan(primitive: .fullBleed, mood: "calm", density: "quiet", photos: [.plain($0)], decorations: [], stamps: [])
        })
    }
}

public struct PlannerResponse: Codable, Sendable, Equatable {
    public var recommendedSlideCount: Int
    public var spine: SelectionSpine
    public var plans: [CarouselPlan]
    public init(recommendedSlideCount: Int, spine: SelectionSpine, plans: [CarouselPlan]) {
        self.recommendedSlideCount = recommendedSlideCount; self.spine = spine; self.plans = plans
    }
}

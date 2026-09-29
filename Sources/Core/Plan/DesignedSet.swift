import Foundation

/// A hand-authored photo layout in whole-carousel document coordinates.
public struct DesignedSet: Codable, Sendable, Equatable {
    public static let schemaVersion = 2

    public struct TextLayer: Codable, Sendable, Equatable {
        public var frame: UnitRect
        public var fontID: String
        public var size: Double
        public var colour: String
        public var alignment: String
        public var lineSpacing: Double
        public var letterSpacing: Double
        public var numberOfLines: Int
        public var rotation: Double
        public var role: String

        public init(frame: UnitRect, fontID: String, size: Double, colour: String, alignment: String,
                    lineSpacing: Double = 0, letterSpacing: Double = 0, numberOfLines: Int = 1,
                    rotation: Double = 0, role: String) {
            self.frame = frame; self.fontID = fontID; self.size = size; self.colour = colour
            self.alignment = alignment; self.lineSpacing = lineSpacing; self.letterSpacing = letterSpacing
            self.numberOfLines = numberOfLines; self.rotation = rotation; self.role = role
        }
    }

    public struct FrameLayer: Codable, Sendable, Equatable {
        public var frame: UnitRect
        public var frameAssetID: String
        public var slotFrame: UnitRect?
        /// Aspect ratio of the frame asset's transparent photo window.
        public var photoWindowAspect: Double?
        public var z: Int
        public var rotation: Double

        public init(frame: UnitRect, frameAssetID: String, slotFrame: UnitRect? = nil,
                    photoWindowAspect: Double? = nil, z: Int, rotation: Double = 0) {
            self.frame = frame; self.frameAssetID = frameAssetID; self.slotFrame = slotFrame
            self.photoWindowAspect = photoWindowAspect
            self.z = z; self.rotation = rotation
        }
    }

    public struct Slot: Codable, Sendable, Equatable {
        public struct Component: Codable, Sendable, Equatable {
            public var frame: UnitRect
            public var aspect: Double
            public var z: Int
            public var rotation: Double
            public var crossesSeam: Bool
            public var roleHint: String
            public init(frame: UnitRect, aspect: Double, z: Int, rotation: Double = 0, crossesSeam: Bool, roleHint: String) {
                self.frame = frame; self.aspect = aspect; self.z = z; self.rotation = rotation
                self.crossesSeam = crossesSeam; self.roleHint = roleHint
            }
        }
        public var frame: UnitRect
        /// Width / height after accounting for the carousel aspect.
        public var aspect: Double
        public var z: Int
        public var rotation: Double
        public var crossesSeam: Bool
        /// `hero` for the largest slot, then `support` in descending area order.
        public var roleHint: String
        /// Preserves individual cells when a dense source grid is packed under the 12-slot slide cap.
        public var components: [Component]?
        /// Corner radius as a fraction of the slot's shorter side.
        public var cornerRadius: Double?

        public init(frame: UnitRect, aspect: Double, z: Int, rotation: Double = 0, crossesSeam: Bool,
                    roleHint: String, components: [Component]? = nil, cornerRadius: Double? = nil) {
            self.frame = frame; self.aspect = aspect; self.z = z; self.rotation = rotation
            self.crossesSeam = crossesSeam; self.roleHint = roleHint; self.components = components; self.cornerRadius = cornerRadius
        }
    }

    public var id: String
    public var sourceRef: String
    public var aspect: CarouselAspect
    public var slideCount: Int
    public var background: String
    public var slots: [Slot]
    public var version: Int
    public var texts: [TextLayer]?
    public var frames: [FrameLayer]?
    public var family: String?
    public var decorCoverage: Double?
    public var sourceTemplate: String?
    public var pageIndex: Int?
    public var pageRole: String?
    public var coverCapable: Bool?

    public init(id: String, sourceRef: String, aspect: CarouselAspect, slideCount: Int, background: String,
                slots: [Slot], version: Int = Self.schemaVersion, texts: [TextLayer]? = nil,
                frames: [FrameLayer]? = nil, family: String? = nil, decorCoverage: Double? = nil,
                sourceTemplate: String? = nil, pageIndex: Int? = nil, pageRole: String? = nil, coverCapable: Bool? = nil) {
        self.id = id; self.sourceRef = sourceRef; self.aspect = aspect; self.slideCount = slideCount
        self.background = background; self.slots = slots; self.version = version
        self.texts = texts; self.frames = frames; self.family = family; self.decorCoverage = decorCoverage
        self.sourceTemplate = sourceTemplate; self.pageIndex = pageIndex; self.pageRole = pageRole
        self.coverCapable = coverCapable
    }

    public func validationError() -> String? {
        guard version == 1 || version == Self.schemaVersion else { return "unsupported version" }
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,127}$", options: .regularExpression) != nil else { return "invalid id" }
        guard !sourceRef.isEmpty, slideCount > 0, !slots.isEmpty else { return "invalid metadata" }
        guard background.range(of: "^#?[A-Fa-f0-9]{6}$", options: .regularExpression) != nil else { return "invalid background colour" }
        if let role = pageRole, !["cover", "statement", "grid", "strip", "quiet"].contains(role) { return "invalid page role" }
        if let index = pageIndex, index < 0 { return "invalid page index" }
        for slot in slots {
            let parts = slot.components?.map { ($0.frame, $0.aspect, $0.rotation) } ?? [(slot.frame, slot.aspect, slot.rotation)]
            for (f, aspect, rotation) in parts {
            guard f.x.isFinite, f.y.isFinite, f.width.isFinite, f.height.isFinite,
                  f.width > 0, f.height > 0, f.x >= -0.03, f.y >= -0.03,
                  f.x + f.width <= Double(slideCount) + 0.03, f.y + f.height <= 1.03 else { return "slot outside canvas" }
            guard aspect.isFinite, (0.1...10).contains(aspect), rotation.isFinite,
                  abs(rotation) <= 15 else { return "invalid slot aspect or rotation" }
            }
            if let radius = slot.cornerRadius, !radius.isFinite || radius < 0 || radius > 0.5 { return "invalid corner radius" }
        }
        for slide in 0..<slideCount where slots.filter({ $0.frame.x < Double(slide + 1) && $0.frame.x + $0.frame.width > Double(slide) }).count > 12 {
            return "more than 12 slots on a slide"
        }
        if let coverage = decorCoverage, !coverage.isFinite || coverage < 0 || coverage > 1 { return "invalid decorative coverage" }
        return nil
    }

    public var isPage: Bool { pageIndex != nil }

    public var crossesSeam: Bool {
        (isPage && slideCount > 1) ||
        slots.contains { $0.crossesSeam || ($0.components?.contains(where: \.crossesSeam) ?? false) } ||
        (texts ?? []).contains { ($0.frame.x + 0.001).rounded(.down) != ($0.frame.x + $0.frame.width - 0.001).rounded(.down) } ||
        (frames ?? []).contains { ($0.frame.x + 0.001).rounded(.down) != ($0.frame.x + $0.frame.width - 0.001).rounded(.down) }
    }

    /// Packed grid cells become individual slots. A slot with no components stays one slot.
    public var expandedSlots: [Slot] {
        slots.flatMap { slot -> [Slot] in
            guard let components = slot.components, !components.isEmpty else { return [slot] }
            return components.map {
                Slot(frame: $0.frame, aspect: $0.aspect, z: $0.z, rotation: $0.rotation,
                     crossesSeam: $0.crossesSeam, roleHint: $0.roleHint, cornerRadius: slot.cornerRadius)
            }
        }
    }

    /// Largest expanded slot, in slide-area units (1 is one full slide).
    public var heroArea: Double {
        expandedSlots.map { $0.frame.width * $0.frame.height }.max() ?? 0
    }

    public var familyID: String { family ?? sourceRef }
}

public struct DesignedSetLibrary: Codable, Sendable, Equatable {
    public var version: Int
    public var frameInference: String
    public var sets: [DesignedSet]
    public init(version: Int = DesignedSet.schemaVersion, frameInference: String, sets: [DesignedSet]) {
        self.version = version; self.frameInference = frameInference; self.sets = sets
    }

    public func validationError() -> String? {
        guard version == 1 || version == DesignedSet.schemaVersion else { return "unsupported library version" }
        guard Set(sets.map(\.id)).count == sets.count else { return "duplicate IDs" }
        for set in sets { if let error = set.validationError() { return "\(set.id): \(error)" } }
        return nil
    }

    /// Every imported set of this carousel's aspect. The photos choose which job fits them.
    public func vocabulary(for aspect: CarouselAspect) -> [DesignedSet] {
        sets.filter { $0.aspect == aspect }
    }

    public var countsByAspect: [String: Int] {
        Dictionary(grouping: sets, by: { $0.aspect.rawValue }).mapValues(\.count)
    }
}

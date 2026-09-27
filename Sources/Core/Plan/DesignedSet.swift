import Foundation

/// A hand-authored photo layout in whole-carousel document coordinates.
public struct DesignedSet: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

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

        public init(frame: UnitRect, aspect: Double, z: Int, rotation: Double = 0, crossesSeam: Bool, roleHint: String, components: [Component]? = nil) {
            self.frame = frame; self.aspect = aspect; self.z = z; self.rotation = rotation
            self.crossesSeam = crossesSeam; self.roleHint = roleHint; self.components = components
        }
    }

    public var id: String
    public var sourceRef: String
    public var aspect: CarouselAspect
    public var slideCount: Int
    public var background: String
    public var slots: [Slot]
    public var version: Int

    public init(id: String, sourceRef: String, aspect: CarouselAspect, slideCount: Int, background: String, slots: [Slot], version: Int = Self.schemaVersion) {
        self.id = id; self.sourceRef = sourceRef; self.aspect = aspect; self.slideCount = slideCount
        self.background = background; self.slots = slots; self.version = version
    }

    public func validationError() -> String? {
        guard version == Self.schemaVersion else { return "unsupported version" }
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,127}$", options: .regularExpression) != nil else { return "invalid id" }
        guard !sourceRef.isEmpty, slideCount > 0, !slots.isEmpty else { return "invalid metadata" }
        guard background.range(of: "^#?[A-Fa-f0-9]{6}$", options: .regularExpression) != nil else { return "invalid background colour" }
        for slot in slots {
            let parts = slot.components?.map { ($0.frame, $0.aspect, $0.rotation) } ?? [(slot.frame, slot.aspect, slot.rotation)]
            for (f, aspect, rotation) in parts {
            guard f.x.isFinite, f.y.isFinite, f.width.isFinite, f.height.isFinite,
                  f.width > 0, f.height > 0, f.x >= -0.03, f.y >= -0.03,
                  f.x + f.width <= Double(slideCount) + 0.03, f.y + f.height <= 1.03 else { return "slot outside canvas" }
            guard aspect.isFinite, (0.1...10).contains(aspect), rotation.isFinite,
                  abs(rotation) <= 15 else { return "invalid slot aspect or rotation" }
            }
        }
        for slide in 0..<slideCount where slots.filter({ $0.frame.x < Double(slide + 1) && $0.frame.x + $0.frame.width > Double(slide) }).count > 12 {
            return "more than 12 slots on a slide"
        }
        return nil
    }

    public var crossesSeam: Bool { slots.contains { $0.crossesSeam || ($0.components?.contains(where: \.crossesSeam) ?? false) } }
}

public struct DesignedSetLibrary: Codable, Sendable, Equatable {
    public var version: Int
    public var frameInference: String
    public var sets: [DesignedSet]
    public init(version: Int = DesignedSet.schemaVersion, frameInference: String, sets: [DesignedSet]) {
        self.version = version; self.frameInference = frameInference; self.sets = sets
    }

    public func validationError() -> String? {
        guard version == DesignedSet.schemaVersion else { return "unsupported library version" }
        guard Set(sets.map(\.id)).count == sets.count else { return "duplicate IDs" }
        for set in sets { if let error = set.validationError() { return "\(set.id): \(error)" } }
        return nil
    }

    public var countsByAspect: [String: Int] {
        Dictionary(grouping: sets, by: { $0.aspect.rawValue }).mapValues(\.count)
    }
}

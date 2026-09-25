public enum CarouselAspect: String, Codable, Sendable, CaseIterable {
    case portrait3x4 = "3:4"
    case square = "1:1"
    case portrait4x5 = "4:5"

    public var exportWidth: Int { 1080 }
    public var exportHeight: Int {
        switch self { case .portrait3x4: 1440; case .square: 1080; case .portrait4x5: 1350 }
    }

    /// "Mostly" means at least 70% of photos share an orientation. Squares count toward neither.
    public static func infer(from photos: [PhotoRecord]) -> CarouselAspect {
        guard !photos.isEmpty else { return .portrait4x5 }
        let total = Double(photos.count)
        let portrait = Double(photos.filter { $0.orientation == .portrait }.count) / total
        let landscape = Double(photos.filter { $0.orientation == .landscape }.count) / total
        if portrait >= 0.7 { return .portrait3x4 }
        if landscape >= 0.7 { return .square }
        return .portrait4x5
    }
}

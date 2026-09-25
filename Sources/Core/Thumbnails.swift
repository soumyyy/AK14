public enum ThumbnailTier: String, Codable, Sendable, CaseIterable {
    case analysis, triage, planning, display

    public var longEdge: Int {
        switch self { case .analysis: 384; case .triage: 160; case .planning: 384; case .display: 1200 }
    }
    public var jpegQuality: Double {
        switch self { case .analysis: 0.78; case .triage: 0.72; case .planning: 0.82; case .display: 0.88 }
    }
}

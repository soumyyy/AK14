import Foundation

/// A versioned, ratio independent composition recipe. Frames use normalized page coordinates.
public struct Recipe: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var family: Family
    public var axes: [String: Double]
    public var slideRoles: [SlideRole]
    public var pages: [Page]

    public enum Family: String, Codable, Sendable, CaseIterable {
        case minimal, film, scrapbook, grid, journal, recap, panorama
    }
    public enum SlideRole: String, Codable, Sendable { case cover, body, closer }
    public enum Edge: String, Codable, Sendable { case bleed, inset }
    public enum Mask: String, Codable, Sendable { case rect, rounded, torn, film }
    public enum TextRole: String, Codable, Sendable { case title, date, place, caption }
    public enum Alignment: String, Codable, Sendable { case left, center, right }
    public enum ColourRule: String, Codable, Sendable { case contrast, ink, paper, accent }
    public enum Background: String, Codable, Sendable { case colour, paper, photoBlur, gradient }
    public enum StickerCategory: String, Codable, Sendable { case tape, paper, film, doodle, label, texture }

    public struct Frame: Codable, Sendable, Equatable {
        public var x: Double; public var y: Double; public var width: Double; public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }
    public struct PhotoSlot: Codable, Sendable, Equatable {
        public var frame: Frame
        public var aspectMin: Double; public var aspectMax: Double
        public var edge: Edge
        public var rotationMin: Double; public var rotationMax: Double
        public var mask: Mask
        public var z: Int
        public var allowCrossSlide: Bool
    }
    public struct TextSlot: Codable, Sendable, Equatable {
        public var role: TextRole; public var fontID: String
        public var sizeMin: Double; public var sizeMax: Double
        public var alignment: Alignment; public var colour: ColourRule
    }
    public struct StickerBudget: Codable, Sendable, Equatable { public var category: StickerCategory; public var count: Int }
    public struct BackgroundRule: Codable, Sendable, Equatable { public var kind: Background; public var colour: ColourRule }
    public struct RangeRule: Codable, Sendable, Equatable { public var min: Double; public var max: Double }
    public struct Page: Codable, Sendable, Equatable {
        public var id: String; public var role: SlideRole
        public var photoSlots: [PhotoSlot]; public var textSlots: [TextSlot]
        public var stickerBudget: [StickerBudget]; public var background: BackgroundRule
        public var gutter: RangeRule; public var margin: RangeRule
    }
}

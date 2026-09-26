import Foundation

public enum Fill: Codable, Sendable, Equatable {
    case colour(String), gradient([String]), photo(AssetID, blur: Double, dim: Double), paper(AssetID?)
    private enum Keys: String, CodingKey { case type, colour, colours, assetID, blur, dim }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "colour": self = .colour(try c.decode(String.self, forKey: .colour))
        case "gradient": self = .gradient(try c.decode([String].self, forKey: .colours))
        case "photo": self = .photo(try c.decode(AssetID.self, forKey: .assetID), blur: try c.decode(Double.self, forKey: .blur), dim: try c.decode(Double.self, forKey: .dim))
        default: self = .paper(try c.decodeIfPresent(AssetID.self, forKey: .assetID))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .colour(let v): try c.encode("colour", forKey: .type); try c.encode(v, forKey: .colour)
        case .gradient(let v): try c.encode("gradient", forKey: .type); try c.encode(v, forKey: .colours)
        case .photo(let id, let blur, let dim): try c.encode("photo", forKey: .type); try c.encode(id, forKey: .assetID); try c.encode(blur, forKey: .blur); try c.encode(dim, forKey: .dim)
        case .paper(let id): try c.encode("paper", forKey: .type); try c.encodeIfPresent(id, forKey: .assetID)
        }
    }
}

public enum Mask: String, Codable, Sendable { case rect, rounded, torn }
public struct DocumentSlice: Codable, Sendable, Equatable { public var x, y, width, height: Double }
public struct PhotoAdjustments: Codable, Sendable, Equatable {
    public var exposure: Double = 0, contrast: Double = 0, warmth: Double = 0, saturation: Double = 0
    public var grain: Double = 0, filmLook: Double = 0
    public init(exposure: Double = 0, contrast: Double = 0, warmth: Double = 0, saturation: Double = 0, grain: Double = 0, filmLook: Double = 0) {
        self.exposure = exposure; self.contrast = contrast; self.warmth = warmth; self.saturation = saturation; self.grain = grain; self.filmLook = filmLook
    }
}
public struct DocumentLayer: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case photo, text, sticker, shape, texture }
    public var id: String, kind: Kind
    public var frame: UnitRect
    public var rotation: Double, z: Int, opacity: Double, locked: Bool, slideHint: Int?
    public var assetID: AssetID?, crop: UnitRect?, adjustments: PhotoAdjustments?, border: Double, shadow: Bool, mask: Mask?
    public var string: String?, fontID: String?, size: Double?, colour: String?, alignment: String?, tracking: Double?, lineHeight: Double?
    public var stickerTint: String?, shapeKind: String?, fill: String?, stroke: String?, textureBlend: String?, intensity: Double?
    public init(id: String, kind: Kind, frame: UnitRect, rotation: Double = 0, z: Int = 0, opacity: Double = 1, locked: Bool = false, slideHint: Int? = nil,
                assetID: AssetID? = nil, crop: UnitRect? = nil, adjustments: PhotoAdjustments? = nil, border: Double = 0, shadow: Bool = false, mask: Mask? = nil,
                string: String? = nil, fontID: String? = nil, size: Double? = nil, colour: String? = nil, alignment: String? = nil, tracking: Double? = nil, lineHeight: Double? = nil,
                stickerTint: String? = nil, shapeKind: String? = nil, fill: String? = nil, stroke: String? = nil, textureBlend: String? = nil, intensity: Double? = nil) {
        self.id=id; self.kind=kind; self.frame=frame; self.rotation=rotation; self.z=z; self.opacity=opacity; self.locked=locked; self.slideHint=slideHint
        self.assetID=assetID; self.crop=crop; self.adjustments=adjustments; self.border=border; self.shadow=shadow; self.mask=mask
        self.string=string; self.fontID=fontID; self.size=size; self.colour=colour; self.alignment=alignment; self.tracking=tracking; self.lineHeight=lineHeight
        self.stickerTint=stickerTint; self.shapeKind=shapeKind; self.fill=fill; self.stroke=stroke; self.textureBlend=textureBlend; self.intensity=intensity
    }
}
public struct CanvasDocument: Codable, Sendable, Equatable {
    public var id: String, aspect: CarouselAspect, slideCount: Int, seamless: Bool, background: Fill, layers: [DocumentLayer]
    public var recipeID: String?, stylePackPin: String?, sourcePlanID: String?, version: String
    public var slideBackgrounds: [String], slideGrain: [Double], slideFilmEdges: [Bool], seed: String
    public init(id: String, aspect: CarouselAspect, slideCount: Int, seamless: Bool = false, background: Fill = .colour("#F4F1EA"), layers: [DocumentLayer] = [], recipeID: String? = nil, stylePackPin: String? = nil, sourcePlanID: String? = nil, version: String = "document-1", slideBackgrounds: [String] = [], slideGrain: [Double] = [], slideFilmEdges: [Bool] = [], seed: String = "0") {
        self.id=id; self.aspect=aspect; self.slideCount=slideCount; self.seamless=seamless; self.background=background; self.layers=layers; self.recipeID=recipeID; self.stylePackPin=stylePackPin; self.sourcePlanID=sourcePlanID; self.version=version
        self.slideBackgrounds=slideBackgrounds; self.slideGrain=slideGrain; self.slideFilmEdges=slideFilmEdges; self.seed=seed
    }
    public func layers(onSlide index: Int) -> [DocumentLayer] {
        let selected = seamless
            ? layers.filter { $0.frame.x < Double(index + 1) / Double(slideCount) && $0.frame.x + $0.frame.width > Double(index) / Double(slideCount) }
            : layers.filter { $0.slideHint == index }
        return selected.sorted { $0.z < $1.z }
    }
    public func sliceGeometry(forSlide index: Int) -> DocumentSlice {
        let width = Double(aspect.exportWidth)
        let height = Double(aspect.exportHeight)
        let originX = Double(index) * width
        return DocumentSlice(x: originX, y: 0, width: width, height: height)
    }
}

public extension CanvasDocument {
    init(from carousel: ResolvedCarousel, photos: [AssetID: PhotoRecord]) {
        let h = Double(carousel.aspect.exportHeight), w = Double(carousel.aspect.exportWidth)
        var layers: [DocumentLayer] = []
        for slide in carousel.slides { for (n, e) in slide.elements.enumerated() {
            let frame = UnitRect(x: (Double(slide.index) + e.frame.x) / Double(max(1, carousel.slides.count)), y: e.frame.y, width: e.frame.width / Double(max(1, carousel.slides.count)), height: e.frame.height)
            let kind: DocumentLayer.Kind = e.kind == .photo ? .photo : e.kind == .stamp ? .text : .sticker
            layers.append(DocumentLayer(id: "s\(slide.index)-\(n)", kind: kind, frame: frame, rotation: e.rotationDegrees, z: e.zIndex, opacity: e.opacity, slideHint: slide.index, assetID: e.assetID, crop: e.crop, border: e.border, shadow: e.shadow, string: e.text, fontID: kind == .text ? "DSEG7Classic-Bold" : nil, size: kind == .text ? h * e.frame.height * 0.9 : nil, colour: kind == .text ? "#FF851F" : nil))
        } }
        self.init(id: carousel.id, aspect: carousel.aspect, slideCount: carousel.slides.count, background: .colour("#F4F1EA"), layers: layers, sourcePlanID: carousel.id,
                  slideBackgrounds: carousel.slides.map(\.background), slideGrain: carousel.slides.map(\.grain), slideFilmEdges: carousel.slides.map(\.filmEdge), seed: carousel.seed)
        _ = photos; _ = w
    }
}

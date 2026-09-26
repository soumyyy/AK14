import Foundation

/// The only edits Studio allows (spec §9.2): reorder slides, swap a photo, remove a photo.
public enum PlanEdit: Codable, Sendable, Equatable {
    case reorder(from: Int, to: Int)
    case swap(slide: Int, photo: AssetID, with: AssetID)
    case remove(slide: Int, photo: AssetID)
}

public enum PlanEditError: Error, Equatable, CustomStringConvertible {
    case slideOutOfRange(Int), photoNotOnSlide(AssetID), alreadyInConcept(AssetID), lastPhoto
    public var description: String {
        switch self {
        case .slideOutOfRange(let i): "slide \(i + 1) does not exist"
        case .photoNotOnSlide(let id): "\(id) is not on that slide"
        case .alreadyInConcept(let id): "\(id) is already used in this concept"
        case .lastPhoto: "a carousel needs at least one photo"
        }
    }
}

public enum PlanEditor {
    public static func apply(_ edit: PlanEdit, to plan: CarouselPlan) throws -> CarouselPlan {
        var p = plan
        switch edit {
        case .reorder(let from, let to):
            guard p.slides.indices.contains(from) else { throw PlanEditError.slideOutOfRange(from) }
            guard p.slides.indices.contains(to) else { throw PlanEditError.slideOutOfRange(to) }
            p.slides.insert(p.slides.remove(at: from), at: to)

        case .swap(let s, let old, let new):
            guard p.slides.indices.contains(s) else { throw PlanEditError.slideOutOfRange(s) }
            guard let i = p.slides[s].photos.firstIndex(where: { $0.assetID == old }) else { throw PlanEditError.photoNotOnSlide(old) }
            guard !p.photoAssetIDs.contains(new) else { throw PlanEditError.alreadyInConcept(new) }
            p.slides[s].photos[i].assetID = new

        case .remove(let s, let id):
            guard p.slides.indices.contains(s) else { throw PlanEditError.slideOutOfRange(s) }
            guard let i = p.slides[s].photos.firstIndex(where: { $0.assetID == id }) else { throw PlanEditError.photoNotOnSlide(id) }
            guard p.photoAssetIDs.count > 1 else { throw PlanEditError.lastPhoto }
            p.slides[s].photos.remove(at: i)
            if p.slides[s].photos.isEmpty {
                p.slides.remove(at: s)                     // removal never pads the carousel
            } else if !p.slides[s].primitive.photoRange.contains(p.slides[s].photos.count) {
                p.slides[s].primitive = p.slides[s].photos.count == 1 ? .hero : .asymmetricPair
            }
        }
        return p
    }
}

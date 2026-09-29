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
            invalidateRun(in: &p.slides, at: from)
            p.slides.insert(p.slides.remove(at: from), at: to)

        case .swap(let s, let old, let new):
            guard p.slides.indices.contains(s) else { throw PlanEditError.slideOutOfRange(s) }
            guard let i = p.slides[s].photos.firstIndex(where: { $0.assetID == old }) else { throw PlanEditError.photoNotOnSlide(old) }
            guard !p.photoAssetIDs.contains(new) else { throw PlanEditError.alreadyInConcept(new) }
            invalidateRun(in: &p.slides, at: s)
            p.slides[s].photos[i].assetID = new

        case .remove(let s, let id):
            guard p.slides.indices.contains(s) else { throw PlanEditError.slideOutOfRange(s) }
            guard let i = p.slides[s].photos.firstIndex(where: { $0.assetID == id }) else { throw PlanEditError.photoNotOnSlide(id) }
            guard p.photoAssetIDs.count > 1 else { throw PlanEditError.lastPhoto }
            invalidateRun(in: &p.slides, at: s)
            p.slides[s].photos.remove(at: i)
            if p.slides[s].photos.isEmpty {
                p.slides.remove(at: s)                     // removal never pads the carousel
            } else if !p.slides[s].primitive.photoRange.contains(p.slides[s].photos.count) {
                p.slides[s].primitive = p.slides[s].photos.count == 1 ? .hero : .asymmetricPair
            }
        }
        return p
    }

    private static func invalidateRun(in slides: inout [SlidePlan], at index: Int) {
        guard slides.indices.contains(index), let placement = slides[index].placement else { return }
        guard placement.runLength > 1 else {
            slides[index].placement?.slide = nil
            return
        }
        let pageID = placement.pageID
        var lower = index
        while lower > 0,
              let current = slides[lower].placement, current.pageID == pageID, current.runLength == placement.runLength,
              let previous = slides[lower - 1].placement, previous.pageID == pageID,
              previous.runLength == placement.runLength, previous.runOffset == current.runOffset - 1 {
            lower -= 1
        }
        var upper = index
        while slides.index(after: upper) < slides.endIndex,
              let current = slides[upper].placement, current.pageID == pageID,
              current.runLength == placement.runLength,
              let next = slides[upper + 1].placement, next.pageID == pageID,
              next.runLength == placement.runLength, next.runOffset == current.runOffset + 1 { upper += 1 }
        for member in lower...upper { slides[member].placement = nil }
    }
}

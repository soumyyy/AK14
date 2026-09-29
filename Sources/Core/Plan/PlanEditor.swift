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
            guard p.slides[s].photos.contains(where: { $0.assetID == old }) else { throw PlanEditError.photoNotOnSlide(old) }
            guard !p.photoAssetIDs.contains(new) else { throw PlanEditError.alreadyInConcept(new) }
            let members = invalidateRun(in: &p.slides, at: s)
            for member in members {
                for photo in p.slides[member].photos.indices where p.slides[member].photos[photo].assetID == old {
                    p.slides[member].photos[photo].assetID = new
                }
            }
            deduplicateRunMembers(in: &p.slides, members: members)

        case .remove(let s, let id):
            guard p.slides.indices.contains(s) else { throw PlanEditError.slideOutOfRange(s) }
            guard p.slides[s].photos.contains(where: { $0.assetID == id }) else { throw PlanEditError.photoNotOnSlide(id) }
            guard p.photoAssetIDs.contains(where: { $0 != id }) else { throw PlanEditError.lastPhoto }
            let members = invalidateRun(in: &p.slides, at: s)
            for member in members { p.slides[member].photos.removeAll { $0.assetID == id } }
            deduplicateRunMembers(in: &p.slides, members: members)
        }
        return p
    }

    private static func deduplicateRunMembers(in slides: inout [SlidePlan], members: Range<Int>) {
        var owners: [AssetID: (member: Int, photo: Int, isSupport: Bool)] = [:]
        for member in members {
            for (photo, element) in slides[member].photos.enumerated() {
                let isSupport = element.role == "support"
                if let owner = owners[element.assetID], !owner.isSupport || isSupport { continue }
                owners[element.assetID] = (member, photo, isSupport)
            }
        }
        // Keep each distinct photo's first non-support occurrence, or its first support occurrence.
        // Reference-only members then disappear; delete backwards so the run's indices stay valid.
        for member in members.reversed() {
            slides[member].photos = slides[member].photos.enumerated().compactMap { photo, element in
                guard let owner = owners[element.assetID], owner.member == member, owner.photo == photo else { return nil }
                return element
            }
            if slides[member].photos.isEmpty {
                slides.remove(at: member)
            } else if !slides[member].primitive.photoRange.contains(slides[member].photos.count) {
                slides[member].primitive = slides[member].photos.count == 1 ? .hero : .asymmetricPair
            }
        }
    }

    @discardableResult
    private static func invalidateRun(in slides: inout [SlidePlan], at index: Int) -> Range<Int> {
        guard slides.indices.contains(index) else { return index..<index }
        guard let placement = slides[index].placement else { return index..<(index + 1) }
        guard placement.runLength > 1 else {
            slides[index].placement?.slide = nil
            return index..<(index + 1)
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
        return lower..<(upper + 1)
    }
}

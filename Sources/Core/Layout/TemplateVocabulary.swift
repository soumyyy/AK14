import Foundation

/// Each imported layout has one job. The photos say which job they are, and that layout is used.
/// Layouts are not scored against each other. A face that would be cut refuses that layout.
enum TemplateVocabulary {
    enum Skill: Equatable {
        /// One photo is the page.
        case statement
        /// One subject, with smaller photos beside it.
        case portraitWithNotes
        /// Two photos of equal weight.
        case pair
        /// Several photos of equal weight.
        case gathering
        /// One photo continues across a slide edge.
        case continuation
    }

    static func place(plan: CarouselPlan, start: Int, context: LayoutContext,
                      usedTemplateIDs: inout Set<String>) -> [ResolvedSlide]? {
        let upcoming = Array(plan.slides[start...])
        let limit = min(3, upcoming.count)
        guard limit > 0 else { return nil }
        for length in stride(from: limit, through: 1, by: -1) {
            let window = Array(upcoming.prefix(length))
            let photos = window.flatMap(\.photos)
            guard !photos.isEmpty, Set(photos.map(\.assetID)).count == photos.count else { continue }
            // Templates cannot safely express planned adornments or their grain/film treatments.
            // Keep the ordinary resolver path for those slides so nothing silently disappears.
            guard window.allSatisfy({ $0.decorations.isEmpty && $0.stamps.isEmpty }) else { continue }
            let asked = readings(photos, plan: plan, context: context)
            let fits = context.vocabulary.filter {
                $0.aspect == context.aspect && $0.slideCount == length
                    && asked.contains(skill(of: $0)) && $0.expandedSlots.count == photos.count
            }
            let viable = fits.compactMap { set -> (set: DesignedSet, mismatch: Double, built: (id: String, score: Double, slides: [ResolvedSlide]))? in
                guard let built = build(set: set, window: window, start: start, context: context) else { return nil }
                return (set, aspectMismatch(set, photos: photos, context: context), built)
            }
            guard let best = viable.map(\.mismatch).min() else { continue }
            let nearBest = viable.filter { $0.mismatch <= best + 0.15 }
            let unused = nearBest.filter { !usedTemplateIDs.contains($0.set.id) }
            let choices = (unused.isEmpty ? nearBest : unused).sorted { $0.set.id < $1.set.id }
            guard !choices.isEmpty else { continue }
            var rng = SeededRandom(seed: SeededRandom.seed(String(context.seed), "template", String(start)))
            let selected = choices[Int(rng.unit() * Double(choices.count))]
            usedTemplateIDs.insert(selected.set.id)
            return selected.built.slides
        }
        return nil
    }

    static func skill(of set: DesignedSet) -> Skill {
        let slots = set.expandedSlots
        if slots.contains(where: \.crossesSeam) { return .continuation }
        if slots.count <= 1 { return .statement }
        let areas = slots.map { $0.frame.width * $0.frame.height }.sorted(by: >)
        let next = areas.dropFirst().first ?? areas[0]
        let dominated = next / max(areas[0], 0.001) < 0.55
        if slots.count == 2 { return dominated ? .portraitWithNotes : .pair }
        return dominated ? .portraitWithNotes : .gathering
    }

    private static func readings(_ photos: [PhotoElement], plan: CarouselPlan, context: LayoutContext) -> [Skill] {
        // Seam-crossing is a story decision from the direction. Source shape alone never implies it.
        if plan.direction?.seamless == true { return [.continuation] }
        if photos.count <= 1 { return [.statement] }
        let faced = photos.filter { hasPerson($0, context: context) }
        let hero = photos.first { $0.role == "hero" }
        let strongestSupport = photos.filter { $0.assetID != hero?.assetID }.map(\.importance).max() ?? 0
        let hasDominantHero = hero.map { $0.importance >= strongestSupport + 2 } ?? false
        let oneSubject = faced.count == 1 || hasDominantHero
        // Explicit pair/collage grouping preserves balanced compositions despite a tagged cover photo.
        if let grouping = plan.style?.grouping, grouping == "mixed" || grouping == "collage" {
            return [photos.count == 2 ? .pair : .gathering]
        }
        let intended = photos.count == 2
            ? (oneSubject ? Skill.portraitWithNotes : .pair)
            : (oneSubject ? Skill.portraitWithNotes : .gathering)
        // A hero label conveys order; it does not rule out a balanced layout. Try both readings,
        // then use crop/aspect fit and stable ID ordering to choose the better matching template.
        guard hero != nil else { return [intended] }
        let balanced: Skill = photos.count == 2 ? .pair : .gathering
        let hierarchical: Skill = .portraitWithNotes
        var options = [intended]
        for option in [balanced, hierarchical] where !options.contains(option) { options.append(option) }
        return options
    }

    private static func aspectMismatch(_ set: DesignedSet, photos: [PhotoElement], context: LayoutContext) -> Double {
        let slots = set.expandedSlots.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
        let ordered = orderedPhotos(photos)
        return zip(slots, ordered).reduce(0) { total, pair in
            let box = pair.0.aspect > 0 ? pair.0.aspect : pair.0.frame.width / max(pair.0.frame.height, 0.01)
            let image = aspect(pair.1, context: context)
            return total + abs(log((image + 0.01) / (box + 0.01)))
        }
    }

    private static func orderedPhotos(_ photos: [PhotoElement]) -> [PhotoElement] {
        var ordered = photos
        if let heroIndex = ordered.firstIndex(where: { $0.role == "hero" }), heroIndex != 0 {
            ordered.insert(ordered.remove(at: heroIndex), at: 0)
        }
        return ordered
    }

    private static func aspect(_ photo: PhotoElement, context: LayoutContext) -> Double {
        guard let record = context.photos[photo.assetID] else { return 1 }
        return Double(record.pixelWidth) / Double(max(record.pixelHeight, 1))
    }

    private static func hasPerson(_ photo: PhotoElement, context: LayoutContext) -> Bool {
        guard let features = context.features[photo.assetID] else { return false }
        return !features.faces.isEmpty || !features.humans.isEmpty
    }

    private static func build(set: DesignedSet, window: [SlidePlan], start: Int, context: LayoutContext)
        -> (id: String, score: Double, slides: [ResolvedSlide])? {
        let photos = window.flatMap(\.photos)
        let slots = set.expandedSlots
        guard photos.count == slots.count, Set(photos.map(\.assetID)).count == photos.count else { return nil }
        guard photos.allSatisfy({ context.photos[$0.assetID] != nil }) else { return nil }

        var ordered = photos
        if let heroIndex = ordered.firstIndex(where: { $0.role == "hero" }), heroIndex != 0 {
            ordered.insert(ordered.remove(at: heroIndex), at: 0)
        }
        let ranked = slots.sorted { lhs, rhs in
            let left = lhs.frame.width * lhs.frame.height
            let right = rhs.frame.width * rhs.frame.height
            if left != right { return left > right }
            return lhs.z < rhs.z
        }

        var assigned: [(slot: DesignedSet.Slot, photo: PhotoElement, crop: UnitRect)] = []
        for (slot, photo) in zip(ranked, ordered) {
            guard let record = context.photos[photo.assetID] else { return nil }
            let imageAspect = Double(record.pixelWidth) / Double(max(record.pixelHeight, 1))
            let boxAspect = slot.aspect > 0 ? slot.aspect : slot.frame.width / max(slot.frame.height, 0.01)
            let features = context.features[photo.assetID]
            let crop = CropPlanner.cover(imageAspect: imageAspect, boxAspect: boxAspect, features: features,
                                          cropIntent: photo.cropIntent, anchorIntent: photo.anchorIntent)
            guard crop.width * crop.height >= 0.65, CropPlanner.facesFit(features, crop: crop) else { return nil }
            guard !subjectCrossesSeam(features: features, crop: crop, slot: slot.frame) else { return nil }
            assigned.append((slot, photo, crop))
        }

        var buckets = Array(repeating: [ResolvedElement](), count: set.slideCount)
        for item in assigned {
            for slide in 0..<set.slideCount {
                guard let element = slice(item, onto: slide) else { continue }
                buckets[slide].append(element)
            }
        }
        guard buckets.allSatisfy({ !$0.isEmpty }) else { return nil }

        let slides = window.enumerated().map { offset, slide in
            let elements = buckets[offset].sorted { $0.zIndex < $1.zIndex }
            return ResolvedSlide(index: start + offset, primitive: slide.primitive, requestedPrimitive: slide.primitive,
                                 background: set.background, grain: 0, filmEdge: false,
                                 elements: elements, warnings: [],
                                 variant: "template.\(set.id)", metrics: metrics(elements))
        }
        return (set.id, 0, slides)
    }

    /// Coverage and crop loss score a template page like any other. Hierarchy is authored by the layout,
    /// so there is no hero share to judge.
    private static func metrics(_ elements: [ResolvedElement]) -> SlideMetrics {
        let n = 40
        var hit = 0
        for iy in 0..<n { for ix in 0..<n {
            let x = (Double(ix) + 0.5) / Double(n), y = (Double(iy) + 0.5) / Double(n)
            if elements.contains(where: { x >= $0.frame.x && x < $0.frame.x + $0.frame.width && y >= $0.frame.y && y < $0.frame.y + $0.frame.height }) { hit += 1 }
        }}
        let loss = elements.map { 1 - ($0.crop.map { $0.width * $0.height } ?? 1) }.max() ?? 0
        return SlideMetrics(coverage: Double(hit) / Double(n * n), heroShare: nil, maxCropLoss: loss)
    }

    private static func slice(_ item: (slot: DesignedSet.Slot, photo: PhotoElement, crop: UnitRect), onto slide: Int) -> ResolvedElement? {
        let slot = item.slot.frame
        let slideLeft = Double(slide)
        let left = max(slot.x, slideLeft)
        let right = min(slot.x + slot.width, slideLeft + 1)
        let localWidth = right - left
        guard localWidth > 1e-4, slot.width > 1e-4, slot.height > 1e-4 else { return nil }
        let startFraction = (left - slot.x) / slot.width
        let widthFraction = localWidth / slot.width
        let cropX = min(max(0, item.crop.x + item.crop.width * startFraction), 1)
        let cropWidth = min(item.crop.width * widthFraction, 1 - cropX)
        guard cropWidth > 1e-4 else { return nil }
        return ResolvedElement(kind: .photo, assetID: item.photo.assetID, text: nil,
                               frame: UnitRect(x: left - slideLeft, y: slot.y, width: localWidth, height: slot.height),
                               rotationDegrees: item.slot.rotation,
                               crop: UnitRect(x: cropX, y: item.crop.y, width: cropWidth, height: item.crop.height),
                               zIndex: item.slot.z, opacity: 1, border: 0, shadow: false)
    }

    /// A face or a significant person mapped through the cover crop onto the slot's carousel span.
    private static func subjectCrossesSeam(features: PhotoFeatures?, crop: UnitRect, slot: UnitRect) -> Bool {
        guard let features, crop.width > 1e-6 else { return false }
        let boxes = features.faces.map(\.box) + features.humans.filter { $0.height >= 0.2 }
        return boxes.contains { box in
            let left = slot.x + (box.x - crop.x) / crop.width * slot.width
            let right = slot.x + (box.x + box.width - crop.x) / crop.width * slot.width
            var seam = floor(left) + 1
            while seam < slot.x + slot.width - 1e-6 {
                if left < seam - 0.01 && right > seam + 0.01 { return true }
                seam += 1
            }
            return false
        }
    }
}

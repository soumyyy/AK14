import Foundation

/// Each imported layout has one job. The photos say which job they are, and that layout is used.
/// Layouts are not scored against each other. A face that would be cut refuses that layout.
public enum TemplateVocabulary {
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
                      usedTemplateIDs: inout Set<String>, selectedFamily: inout String?,
                      titlePlaced: inout Bool, captionCount: inout Int) -> [ResolvedSlide]? {
        let upcoming = Array(plan.slides[start...])
        let limit = min(3, upcoming.count)
        guard limit > 0 else { return nil }
        for length in stride(from: limit, through: 1, by: -1) {
            let window = Array(upcoming.prefix(length))
            let photos = window.flatMap(\.photos)
            guard !photos.isEmpty, Set(photos.map(\.assetID)).count == photos.count else { continue }
            // Templates cannot safely express planned adornments or their grain/film treatments.
            // Keep the ordinary resolver path for those slides so nothing silently disappears.
            // A legacy window must not consume a later slide with an authored placement.
            guard window.allSatisfy({ $0.placement == nil && $0.decorations.isEmpty && $0.stamps.isEmpty }) else { continue }
            let asked = readings(photos, plan: plan, context: context)
            let allFits = context.vocabulary.filter {
                $0.aspect == context.aspect && $0.slideCount == length
                    && asked.contains(skill(of: $0)) && $0.expandedSlots.count == photos.count
            }
            let familyFits = selectedFamily.map { family in allFits.filter { $0.familyID == family } } ?? []
            let fits = familyFits.isEmpty ? allFits : familyFits
            let viable = fits.compactMap { set -> (set: DesignedSet, mismatch: Double, built: (id: String, score: Double, slides: [ResolvedSlide]))? in
                guard let built = build(set: set, plan: plan, window: window, start: start, context: context,
                                        titlePlaced: titlePlaced, captionCount: captionCount) else { return nil }
                return (set, aspectMismatch(set, photos: photos, context: context), built)
            }
            guard !viable.isEmpty else { continue }
            if selectedFamily == nil {
                let groups = Dictionary(grouping: viable, by: { $0.set.familyID })
                selectedFamily = groups.keys.sorted {
                    let left = groups[$0]!
                    let right = groups[$1]!
                    let leftPreference = familyPreference(left.map(\.set), plan: plan)
                    let rightPreference = familyPreference(right.map(\.set), plan: plan)
                    if leftPreference != rightPreference { return leftPreference > rightPreference }
                    let leftMismatch = left.map(\.mismatch).min()!
                    let rightMismatch = right.map(\.mismatch).min()!
                    if leftMismatch != rightMismatch { return leftMismatch < rightMismatch }
                    let leftSeed = SeededRandom.seed(String(context.seed), plan.id, "family", $0)
                    let rightSeed = SeededRandom.seed(String(context.seed), plan.id, "family", $1)
                    return leftSeed == rightSeed ? $0 < $1 : leftSeed < rightSeed
                }.first
            }
            let familyViable = selectedFamily.map { family in
                let matching = viable.filter { $0.set.familyID == family }
                return matching.isEmpty ? viable : matching
            } ?? viable
            guard let best = familyViable.map(\.mismatch).min() else { continue }
            let nearBest = familyViable.filter { $0.mismatch <= best + 0.15 }
            let unused = nearBest.filter { !usedTemplateIDs.contains($0.set.id) }
            let choices = (unused.isEmpty ? nearBest : unused).sorted {
                return $0.mismatch == $1.mismatch ? $0.set.id < $1.set.id : $0.mismatch < $1.mismatch
            }
            guard !choices.isEmpty else { continue }
            var rng = SeededRandom(seed: SeededRandom.seed(String(context.seed), plan.id, "template", String(start)))
            let selected = choices[Int(rng.unit() * Double(choices.count))]
            usedTemplateIDs.insert(selected.set.id)
            if selectedFamily == nil { selectedFamily = selected.set.familyID }
            titlePlaced = titlePlaced || selected.built.slides.flatMap(\.elements).contains { $0.kind == .text && $0.textRole == "title" }
            captionCount += selected.built.slides.flatMap(\.elements).filter { $0.kind == .text && $0.textRole == "caption" }.count
            return selected.built.slides
        }
        return nil
    }

    private static func familyPreference(_ sets: [DesignedSet], plan: CarouselPlan) -> Double {
        let hasText = sets.contains { !($0.texts?.isEmpty ?? true) }
        let hasFrame = sets.contains { !($0.frames?.isEmpty ?? true) }
        if plan.style?.decoration == "none" {
            return hasText || hasFrame ? 0 : 1
        }
        return hasText || hasFrame ? 1 : 0
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

    private static func build(set: DesignedSet, plan: CarouselPlan, window: [SlidePlan], start: Int, context: LayoutContext,
                              titlePlaced: Bool, captionCount: Int)
        -> (id: String, score: Double, slides: [ResolvedSlide])? {
        let photos = window.flatMap(\.photos)
        let slots = set.expandedSlots
        guard photos.count == slots.count, Set(photos.map(\.assetID)).count == photos.count else { return nil }
        guard photos.allSatisfy({ context.photos[$0.assetID] != nil }) else { return nil }

        guard let placement = SlotAssignment.assign(photos.map(\.assetID), to: set,
            hero: photos.first { $0.role == "hero" }?.assetID, keepOrder: context.keepOrder,
            records: context.photos, features: context.features) else { return nil }
        var localTitleUsed = titlePlaced
        var localCaptions = captionCount
        let slides = render(page: set, placed: placement.placed, plan: plan, start: start,
                            context: context, titlePlaced: &localTitleUsed, captionCount: &localCaptions)
        return (set.id, 0, slides)
    }

    public static func render(page set: DesignedSet, placed: [SlotAssignment.Placed], plan: CarouselPlan, start: Int,
                              context: LayoutContext, titlePlaced: inout Bool, captionCount: inout Int) -> [ResolvedSlide] {
        var window = Array(plan.slides.dropFirst(start).prefix(set.slideCount))
        let synthesizing = window.count != set.slideCount
        if synthesizing {
            let synthesized = (0..<set.slideCount).map { slide in
                let ids = placed.compactMap { assignment -> AssetID? in
                    guard set.expandedSlots.indices.contains(assignment.slotIndex) else { return nil }
                    let frame = set.expandedSlots[assignment.slotIndex].frame
                    return Int(floor(frame.x + frame.width / 2)) == slide ? assignment.assetID : nil
                }
                return SlidePlan(primitive: .hero, mood: "", density: "balanced",
                                 photos: ids.map(PhotoElement.plain), decorations: [], stamps: [])
            }
            window = synthesized
        }
        // Authored runs assign each photo once, even when its rendered slices span two pages.
        // Keep the existing windowed path's validation and photo intents unchanged.
        let photos = synthesizing ? placed.map { PhotoElement.plain($0.assetID) } : window.flatMap(\.photos)
        let slots = set.expandedSlots
        guard photos.count == slots.count, Set(photos.map(\.assetID)).count == photos.count,
              photos.allSatisfy({ context.photos[$0.assetID] != nil }),
              placed.count == slots.count, placed.allSatisfy({ slots.indices.contains($0.slotIndex) }) else { return [] }
        let assigned: [(slot: DesignedSet.Slot, photo: PhotoElement, crop: UnitRect)] = placed.compactMap { item in
            guard slots.indices.contains(item.slotIndex), let photo = photos.first(where: { $0.assetID == item.assetID }) else { return nil }
            return (slots[item.slotIndex], photo, item.crop)
        }

        var buckets = Array(repeating: [ResolvedElement](), count: set.slideCount)
        for item in assigned {
            for slide in 0..<set.slideCount {
                guard let element = slice(item, onto: slide) else { continue }
                buckets[slide].append(element)
            }
        }
        for frame in set.frames ?? [] {
            guard let slotFrame = frame.slotFrame,
                  let item = assigned.min(by: { distance($0.slot.frame, slotFrame) < distance($1.slot.frame, slotFrame) }) else { continue }
            let record = context.photos[item.photo.assetID]!
            let imageAspect = Double(record.pixelWidth) / Double(max(record.pixelHeight, 1))
            let photoWindowAspect = frame.photoWindowAspect ?? item.slot.aspect
            let frameCrop = CropPlanner.cover(imageAspect: imageAspect, boxAspect: photoWindowAspect,
                                              features: context.features[item.photo.assetID],
                                              cropIntent: item.photo.cropIntent, anchorIntent: item.photo.anchorIntent)
            guard frameCrop.width * frameCrop.height >= SlotAssignment.cropFloor,
                  CropPlanner.facesFit(context.features[item.photo.assetID], crop: frameCrop) else { continue }
            for slide in 0..<set.slideCount {
                guard let element = sliceFrame(frame, photo: item.photo, crop: frameCrop, onto: slide) else { continue }
                buckets[slide].append(element)
            }
        }
        let title = storyTitle(plan: plan, context: context)
        var localTitleUsed = titlePlaced
        var localCaptions = captionCount
        for text in set.texts ?? [] where text.role != "accent" {
            let slide = min(set.slideCount - 1, max(0, Int(floor(text.frame.x + text.frame.width / 2))))
            guard slide < buckets.count else { continue }
            let value: String?
            switch text.role {
            case "title":
                guard !localTitleUsed else { continue }
                value = title
            case "caption":
                guard localCaptions < 2 else { continue }
                value = captureCaption(window[slide].photos.first.flatMap { context.photos[$0.assetID] })
            default:
                value = nil
            }
            guard let value, !value.isEmpty else { continue }
            let local = UnitRect(x: text.frame.x - Double(slide), y: text.frame.y,
                                 width: text.frame.width, height: text.frame.height)
            guard let safe = safeTextFrame(local, rotation: text.rotation, slide: slide, assigned: assigned, context: context) else { continue }
            buckets[slide].append(ResolvedElement(kind: .text, assetID: nil, text: value,
                                                  frame: safe, rotationDegrees: text.rotation, crop: nil,
                                                  zIndex: 200, opacity: 1, border: 0, shadow: false,
                                                  fontID: text.fontID, fontSize: text.size, textColor: text.colour,
                                                  alignment: text.alignment, lineSpacing: text.lineSpacing,
                                                  letterSpacing: text.letterSpacing, numberOfLines: text.numberOfLines,
                                                  textRole: text.role))
            if text.role == "title" { localTitleUsed = true }
            if text.role == "caption" { localCaptions += 1 }
        }
        guard synthesizing || buckets.allSatisfy({ !$0.isEmpty }) else { return [] }

        let slides = window.enumerated().map { offset, slide in
            let elements = buckets[offset].sorted { $0.zIndex < $1.zIndex }
            return ResolvedSlide(index: start + offset, primitive: slide.primitive, requestedPrimitive: slide.primitive,
                                 background: set.background, grain: 0, filmEdge: false,
                                 elements: elements, warnings: [],
                                 variant: "template.\(set.id)", metrics: metrics(elements))
        }
        titlePlaced = localTitleUsed
        captionCount = localCaptions
        return slides
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

    private static func distance(_ a: UnitRect, _ b: UnitRect) -> Double {
        abs(a.x - b.x) + abs(a.y - b.y) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func storyTitle(plan: CarouselPlan, context: LayoutContext) -> String? {
        if let idea = (plan.direction?.titleIdeas.first ?? plan.direction?.titleIdea)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !idea.isEmpty { return String(idea.prefix(40)) }
        guard let hint = context.storyHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              (3...28).contains(hint.count) else { return nil }
        return hint
    }

    /// Adds the cover title when no imported page supplied one. Keeping this in the resolver means
    /// the title remains an editable document text element on both the template and primitive paths.
    static func addCoverTitleIfNeeded(to slides: inout [ResolvedSlide], plan: CarouselPlan, context: LayoutContext) {
        guard let first = slides.indices.first else { return }
        guard let title = storyTitle(plan: plan, context: context) else { return }
        for index in slides.indices where index != first {
            slides[index].elements.removeAll { $0.kind == .text && $0.textRole == "title" }
        }
        guard !slides[first].elements.contains(where: { $0.kind == .text && $0.textRole == "title" }) else { return }
        let coverPhotos = slides[first].elements.filter { $0.kind == .photo }
        guard coverPhotos.count == 1, let photo = coverPhotos.first, let assetID = photo.assetID else { return }
        if slides[first].variant == "hero.clean" {
            placeEditorialTitle(title, on: &slides[first], photo: photo, assetID: assetID, plan: plan, context: context)
            return
        }

        let crop = photo.crop ?? UnitRect(x: 0, y: 0, width: 1, height: 1)
        let photoFrame = Box(x: photo.frame.x, y: photo.frame.y, w: photo.frame.width, h: photo.frame.height)
        let people = CropPlanner.facesOnCanvas(context.features[assetID], crop: crop, frame: photoFrame)
            + (context.features[assetID]?.humans ?? []).filter { $0.height >= 0.2 }.map {
                Box(x: photoFrame.x + ($0.x - crop.x) / crop.width * photoFrame.w,
                    y: photoFrame.y + ($0.y - crop.y) / crop.height * photoFrame.h,
                    w: $0.width / crop.width * photoFrame.w, h: $0.height / crop.height * photoFrame.h)
            }
        let saliency = context.features[assetID]?.salientRegions ?? []
        let regions = [
            UnitRect(x: 0.08, y: 0.08, width: 0.72, height: 0.22),
            UnitRect(x: 0.14, y: 0.08, width: 0.72, height: 0.22),
            UnitRect(x: 0.08, y: 0.70, width: 0.72, height: 0.22),
            UnitRect(x: 0.14, y: 0.70, width: 0.72, height: 0.22),
            UnitRect(x: 0.14, y: 0.39, width: 0.72, height: 0.22),
        ]
        var rng = SeededRandom(seed: SeededRandom.seed(String(context.seed), plan.id, "cover-title"))
        let offset = Int(rng.next() % UInt64(regions.count))
        let orderedRegions = regions.indices.map { regions[($0 + offset) % regions.count] }
        func area(_ a: UnitRect) -> Double { a.width * a.height }
        func intersection(_ a: UnitRect, _ b: UnitRect) -> Double {
            max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
                * max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        }
        func regionScore(_ region: UnitRect) -> Double {
            let box = Box(x: region.x, y: region.y, w: region.width, h: region.height)
            let peoplePenalty = people.contains(where: { $0.intersects(box) }) ? 100.0 : 0
            let saliencyPenalty = saliency.reduce(0.0) { total, salient in
                total + intersection(region, salient) / max(area(salient), 0.0001)
            }
            return peoplePenalty + saliencyPenalty
        }
        guard let region = orderedRegions.first(where: { regionScore($0) < 100 }) else { return }

        let style = Int(SeededRandom.seed(String(context.seed), plan.id, "cover-title-style") % 3)
        let meanLuminance = context.features[assetID]?.meanLuminance ?? 0.6
        let colour = meanLuminance < 0.55 ? "#FFFFFF" : "#1A1A1A"
        let contrast = meanLuminance < 0.55
            ? (1.0 + 0.05) / (meanLuminance + 0.05)
            : (meanLuminance + 0.05) / (0.0 + 0.05)
        guard contrast >= 3 else { return }

        let height = Double(context.aspect.exportHeight)
        let fontID: String
        let fontSize: Double
        let value: String
        let alignment: String
        let letterSpacing: Double
        let lineSpacing: Double
        switch style {
        case 0:
            fontID = rng.bool() ? "font-pinyonscript" : "font-cedarvillecursive"
            fontSize = height * 0.11
            value = title
            alignment = "left"
            letterSpacing = 0
            lineSpacing = -fontSize * 0.08
        case 1:
            fontID = rng.bool() ? "font-instrumentserif" : "font-instrumentserif-italic"
            fontSize = height * 0.085
            value = title
            alignment = "left"
            letterSpacing = 0
            lineSpacing = -fontSize * 0.08
        default:
            fontID = rng.bool() ? "font-inter" : "font-dotgothic16"
            fontSize = height * 0.042
            value = title.uppercased()
            alignment = "left"
            letterSpacing = fontSize * 0.12
            lineSpacing = fontSize * 0.15
        }
        let fittedSize = fitted(value, fontSize: fontSize, width: region.width, style: style, letterSpacing: letterSpacing,
                                lines: style == 0 ? 2 : 1, height: height, aspect: context.aspect)
        let titleHeight = style == 2 ? 0.12 : 0.17
        let titleFrame = UnitRect(x: region.x, y: region.y, width: region.width, height: titleHeight)
        guard !people.contains(where: { $0.intersects(Box(x: titleFrame.x, y: titleFrame.y,
                                                           w: titleFrame.width, h: titleFrame.height)) }) else { return }
        let z = (slides[first].elements.map(\.zIndex).max() ?? 0) + 1
        slides[first].elements.append(ResolvedElement(kind: .text, assetID: nil, text: value,
                                                       frame: titleFrame, rotationDegrees: 0, crop: nil,
                                                       zIndex: max(200, z), opacity: 1, border: 0, shadow: false,
                                                       fontID: fontID, fontSize: fittedSize, textColor: colour,
                                                       alignment: alignment, lineSpacing: lineSpacing,
                                                       letterSpacing: letterSpacing, numberOfLines: style == 0 ? 2 : 1,
                                                       textRole: "title"))

        guard style == 2, let date = captureCaption(context.photos[assetID]) else { return }
        let dateFrame = UnitRect(x: region.x, y: region.y + 0.135, width: region.width, height: 0.05)
        guard !people.contains(where: { $0.intersects(Box(x: dateFrame.x, y: dateFrame.y,
                                                           w: dateFrame.width, h: dateFrame.height)) }) else { return }
        slides[first].elements.append(ResolvedElement(kind: .text, assetID: nil, text: date.uppercased(),
                                                       frame: dateFrame, rotationDegrees: 0, crop: nil,
                                                       zIndex: max(200, z) + 1, opacity: 1, border: 0, shadow: false,
                                                       fontID: fontID, fontSize: fittedSize * 0.72, textColor: colour,
                                                       alignment: alignment, lineSpacing: lineSpacing,
                                                       letterSpacing: letterSpacing, numberOfLines: 1,
                                                       textRole: "caption"))
    }

    /// Largest size, at most `fontSize`, at which `text` fits `lines` lines across `width` of the slide.
    /// Average advance per character by style: script 0.42, serif 0.48, spaced caps 0.66 (plus tracking).
    static func fitted(_ text: String, fontSize: Double, width: Double, style: Int, letterSpacing: Double,
                       lines: Int, height: Double, aspect: CarouselAspect) -> Double {
        let slideWidth = Double(aspect.exportWidth) * width
        let advance = style == 0 ? 0.42 : style == 1 ? 0.48 : 0.66
        let perLine = Double(text.count) / Double(max(1, lines)) + 1
        let fit = slideWidth / (perLine * advance + perLine * letterSpacing / max(fontSize, 1))
        return max(height * 0.022, min(fontSize, fit))
    }

    /// A white-card cover keeps the whole photo, so the title sits in the white band above it,
    /// editorial style: dark ink, left-aligned to the photo's edge, never over the photo.
    private static func placeEditorialTitle(_ title: String, on slide: inout ResolvedSlide, photo: ResolvedElement,
                                            assetID: AssetID, plan: CarouselPlan, context: LayoutContext) {
        let top = photo.frame.y, bottom = 1 - (photo.frame.y + photo.frame.height)
        let band = max(top, bottom)
        guard band >= 0.1 else { return }
        let height = Double(context.aspect.exportHeight)
        let style = Int(SeededRandom.seed(String(context.seed), plan.id, "cover-title-style") % 3)
        let fontID = style == 0 ? "font-pinyonscript" : style == 1 ? "font-instrumentserif" : "font-inter"
        let value = style == 2 ? title.uppercased() : title
        let base = style == 0 ? height * 0.075 : style == 1 ? height * 0.062 : height * 0.034
        let tracking = style == 2 ? base * 0.12 : 0
        let size = fitted(value, fontSize: base, width: photo.frame.width, style: style, letterSpacing: tracking,
                          lines: 1, height: height, aspect: context.aspect)
        let lineHeight = size * 1.35 / height
        let y = top >= bottom ? max(0.02, top - lineHeight - 0.02) : photo.frame.y + photo.frame.height + 0.02
        let z = (slide.elements.map(\.zIndex).max() ?? 0) + 1
        slide.elements.append(ResolvedElement(kind: .text, assetID: nil, text: value,
            frame: UnitRect(x: photo.frame.x, y: y, width: photo.frame.width, height: lineHeight),
            rotationDegrees: 0, crop: nil, zIndex: max(200, z), opacity: 1, border: 0, shadow: false,
            fontID: fontID, fontSize: size, textColor: "#1A1A1A", alignment: "left", lineSpacing: 0,
            letterSpacing: tracking, numberOfLines: 1, textRole: "title"))
    }

    private static func captureCaption(_ photo: PhotoRecord?) -> String? {
        guard let photo else { return nil }
        if let raw = photo.metadata.localDateTime {
            let parts = raw.split(separator: " ").first?.split(separator: ":").compactMap { Int($0) } ?? []
            if parts.count >= 3 { return "\(parts[2]) \(month(parts[1]))" }
        }
        guard let date = photo.metadata.capturedAt else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.month, .day], from: date)
        guard let month = c.month, let day = c.day else { return nil }
        return "\(day) \(Self.month(month))"
    }

    private static func month(_ value: Int) -> String {
        let values = ["", "january", "february", "march", "april", "may", "june",
                      "july", "august", "september", "october", "november", "december"]
        return values.indices.contains(value) ? values[value] : "january"
    }

    private static func safeTextFrame(_ frame: UnitRect, rotation: Double, slide: Int,
                                      assigned: [(slot: DesignedSet.Slot, photo: PhotoElement, crop: UnitRect)],
                                      context: LayoutContext) -> UnitRect? {
        let width = min(1, max(0, frame.width)), height = min(1, max(0, frame.height))
        let base = UnitRect(x: min(max(0, frame.x), max(0, 1 - width)),
                            y: min(max(0, frame.y), max(0, 1 - height)), width: width, height: height)
        let faces = assigned.flatMap { item -> [Box] in
            let slot = item.slot.frame
            let left = max(slot.x, Double(slide)), right = min(slot.x + slot.width, Double(slide + 1))
            guard right > left else { return [] }
            let local = Box(x: left - Double(slide), y: slot.y, w: right - left, h: slot.height)
            return CropPlanner.facesOnCanvas(context.features[item.photo.assetID], crop: item.crop, frame: local)
        }
        for (dx, dy) in [(0.0, 0.0), (0.0, -0.12), (0.0, 0.12), (-0.12, 0.0), (0.12, 0.0)] {
            let candidate = UnitRect(x: min(max(0, base.x + dx), max(0, 1 - width)),
                                     y: min(max(0, base.y + dy), max(0, 1 - height)),
                                     width: width, height: height)
            let candidateAngle = abs(rotation) * Double.pi / 180
            let candidateSafety = Box(x: candidate.x + (candidate.width - (abs(cos(candidateAngle)) * candidate.width + abs(sin(candidateAngle)) * candidate.height)) / 2,
                                      y: candidate.y + (candidate.height - (abs(sin(candidateAngle)) * candidate.width + abs(cos(candidateAngle)) * candidate.height)) / 2,
                                      w: abs(cos(candidateAngle)) * candidate.width + abs(sin(candidateAngle)) * candidate.height,
                                      h: abs(sin(candidateAngle)) * candidate.width + abs(cos(candidateAngle)) * candidate.height)
            if !faces.contains(where: { $0.intersects(candidateSafety) }) { return candidate }
        }
        return nil
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
                               zIndex: item.slot.z, opacity: 1, border: 0, shadow: false,
                               cornerRadius: item.slot.cornerRadius)
    }

    private static func sliceFrame(_ frame: DesignedSet.FrameLayer, photo: PhotoElement, crop: UnitRect,
                                   onto slide: Int) -> ResolvedElement? {
        let authored = frame.frame
        let slideLeft = Double(slide)
        let left = max(authored.x, slideLeft), right = min(authored.x + authored.width, slideLeft + 1)
        guard right - left > 1e-4 else { return nil }
        let startFraction = (left - authored.x) / max(authored.width, 1e-4)
        let widthFraction = (right - left) / max(authored.width, 1e-4)
        let cropX = min(max(0, crop.x + crop.width * startFraction), 1)
        let cropWidth = min(crop.width * widthFraction, 1 - cropX)
        return ResolvedElement(kind: .frame, assetID: photo.assetID, text: nil,
                               frame: UnitRect(x: left - slideLeft, y: authored.y, width: right - left, height: authored.height),
                               rotationDegrees: frame.rotation,
                               crop: UnitRect(x: cropX, y: crop.y, width: cropWidth, height: crop.height),
                               zIndex: frame.z, opacity: 1, border: 0, shadow: false,
                               frameAssetID: frame.frameAssetID)
    }

    /// A face or a significant person mapped through the cover crop onto the slot's carousel span.
    static func subjectCrossesSeam(features: PhotoFeatures?, crop: UnitRect, slot: UnitRect) -> Bool {
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

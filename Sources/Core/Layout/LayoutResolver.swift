import Foundation

public struct LayoutContext: Sendable {
    public var aspect: CarouselAspect
    public var photos: [AssetID: PhotoRecord]
    public var features: [AssetID: PhotoFeatures]
    public var stylePack: StylePack
    public var seed: UInt64
    public var storyHint: String?
    /// Imported page arrangements the resolver may fill. Empty keeps the six primitives.
    public var vocabulary: [DesignedSet]
    public init(aspect: CarouselAspect, photos: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures],
                stylePack: StylePack, seed: UInt64, storyHint: String? = nil, vocabulary: [DesignedSet] = []) {
        self.aspect = aspect; self.photos = photos; self.features = features; self.stylePack = stylePack
        self.seed = seed; self.storyHint = storyHint; self.vocabulary = vocabulary
    }
}

/// Turns semantic slide intent into exact, deterministic geometry (spec §7). The model never supplies coordinates.
public enum LayoutResolver {
    public static func resolve(_ plan: CarouselPlan, context: LayoutContext) -> ResolvedCarousel {
        var rng = SeededRandom(seed: context.seed)
        var history: [String] = []
        var slides: [ResolvedSlide] = []
        var usedTemplateIDs = Set<String>()
        var selectedFamily: String?
        var titlePlaced = false
        var captionCount = 0
        var index = 0
        let useVocabulary = !plan.isBaseline && !context.vocabulary.isEmpty
        while index < plan.slides.count {
            if useVocabulary, let placed = TemplateVocabulary.place(plan: plan, start: index, context: context,
                                                                     usedTemplateIDs: &usedTemplateIDs, selectedFamily: &selectedFamily,
                                                                     titlePlaced: &titlePlaced, captionCount: &captionCount) {
                slides.append(contentsOf: placed)
                index += placed.count
            } else {
                slides.append(resolveSlide(plan.slides[index], index: index, plan: plan, context: context, history: &history, rng: &rng))
                index += 1
            }
        }
        TemplateVocabulary.addCoverTitleIfNeeded(to: &slides, plan: plan, context: context)
        if !plan.isBaseline && CarouselGrade.gradeEnabled {
            slides = applyGrade(slides, plan: plan, features: context.features)
        }
        return ResolvedCarousel(id: plan.id, aspect: context.aspect,
                                seed: String(context.seed, radix: 16), resolverVersion: ResolvedCarousel.resolverVersion,
                                slides: slides)
    }

    /// Which planned slides `resolve` would place on an imported template, without laying out the others.
    /// Template placement reads only the plan, the context and the templates already used, never the primitive
    /// path's state, so this matches `resolve` exactly at a fraction of the cost.
    static func templateHosted(_ plan: CarouselPlan, context: LayoutContext) -> [Bool] {
        var hosted = Array(repeating: false, count: plan.slides.count)
        guard !plan.isBaseline && !context.vocabulary.isEmpty else { return hosted }
        var usedTemplateIDs = Set<String>()
        var selectedFamily: String?
        var titlePlaced = false
        var captionCount = 0
        var index = 0
        while index < plan.slides.count {
            if let placed = TemplateVocabulary.place(plan: plan, start: index, context: context,
                                                     usedTemplateIDs: &usedTemplateIDs, selectedFamily: &selectedFamily,
                                                     titlePlaced: &titlePlaced, captionCount: &captionCount) {
                for offset in placed.indices { hosted[index + offset] = true }
                index += placed.count
            } else {
                index += 1
            }
        }
        return hosted
    }

    static func applyGrade(_ slides: [ResolvedSlide], plan: CarouselPlan, features: [AssetID: PhotoFeatures]) -> [ResolvedSlide] {
        var seen = Set<AssetID>()
        let photoIDs = plan.photoAssetIDs.filter { seen.insert($0).inserted }
        let grades = CarouselGrade.adjustments(for: photoIDs, features: features)
        guard !grades.isEmpty else { return slides }
        return slides.map { slide in
            var copy = slide
            copy.elements = slide.elements.map { element in
                guard element.kind == .photo, let id = element.assetID, let grade = grades[id] else { return element }
                var updated = element
                if var existing = updated.adjustments {
                    existing.exposure += grade.exposure
                    existing.warmth += grade.warmth
                    existing.saturation += grade.saturation
                    updated.adjustments = existing
                } else {
                    updated.adjustments = grade
                }
                return updated
            }
            return copy
        }
    }

    // MARK: - Slide

    /// Photo share of the canvas each slide density asks for.
    public static func densityTarget(_ density: String) -> Double {
        density == "quiet" ? 0.52 : density == "dense" ? 0.78 : 0.64
    }

    struct Canvas {
        let W: Double, H: Double
        var short: Double { min(W, H) }
    }

    static func resolveSlide(_ slide: SlidePlan, index: Int, plan: CarouselPlan, context: LayoutContext, history: inout [String],
                             rng: inout SeededRandom) -> ResolvedSlide {
        let c = Canvas(W: Double(context.aspect.exportWidth), H: Double(context.aspect.exportHeight))
        let spacing = context.stylePack.spacingRanges
        // A film edge draws bands down both sides; reserve them so nothing important sits underneath.
        let filmBand = slide.decorations.contains { $0.decorationID == "film-edge" } ? StyleMetrics.filmBand(canvasWidth: c.W) : 0
        // Airy directions breathe more; the StylePack range still bounds the base margin.
        let airy = plan.style?.whitespace == "airy" ? 1.5 : 1.0
        let margin = max(airy * rng.range(spacing["marginMin"] ?? 0.04, spacing["marginMax"] ?? 0.07) * c.short,
                         filmBand > 0 ? filmBand + 0.035 * c.short : 0)
        let content = Box(x: filmBand, y: 0, w: c.W - 2 * filmBand, h: c.H)
        let maxPhotoRot = context.stylePack.allowedRotations["photoDegrees"] ?? 2
        let minVisible = context.stylePack.overlapRanges["minimumVisibleFraction"] ?? 0.55
        var warnings: [String] = []

        // Photos ordered by importance (most important first); unknown assets are dropped with a warning.
        let photos = slide.photos.filter {
            if context.photos[$0.assetID] == nil { warnings.append("unknown photo \($0.assetID) dropped"); return false }
            return true
        }
        guard !photos.isEmpty else {
            return ResolvedSlide(index: index, primitive: slide.primitive, requestedPrimitive: slide.primitive, background: "plain",
                                 grain: 0, filmEdge: filmBand > 0, elements: [], warnings: warnings + ["slide has no usable photos"])
        }
        var primitive = slide.primitive
        if !primitive.photoRange.contains(photos.count) {
            let fallback: Primitive = photos.count <= 1 ? .fullBleed : photos.count == 2 ? .asymmetricPair : .overlapCluster
            warnings.append("\(primitive.rawValue) cannot hold \(photos.count) photos; using \(fallback.rawValue)")
            primitive = fallback
        }
        // The hero role is authoritative for the dominant frame; importance (3 = most) only orders the rest.
        let ranked = photos.enumerated().sorted {
            let a = ($0.element.role == "hero" ? 1 : 0, $0.element.importance, -$0.offset)
            let b = ($1.element.role == "hero" ? 1 : 0, $1.element.importance, -$1.offset)
            return a > b
        }.map(\.element)

        // Full-bleed faces that cannot fit the crop become a hero (whole photo) rather than being cut (spec §7.3).
        if primitive == .fullBleed {
            let e = photos[0]
            let a = Double(context.photos[e.assetID]!.pixelWidth) / Double(max(1, context.photos[e.assetID]!.pixelHeight))
            let crop = CropPlanner.cover(imageAspect: a, boxAspect: content.w / content.h, features: context.features[e.assetID],
                                         cropIntent: e.cropIntent, anchorIntent: e.anchorIntent)
            let landscapeOnPortraitCanvas = a > 1.0 && content.w / content.h < 1.0
            let cropLoss = 1 - crop.width * crop.height
            let eligible = CropPlanner.fullBleedEligible(imageAspect: a, boxAspect: content.w / content.h,
                                                         features: context.features[e.assetID])
            if !eligible {
                warnings.append(landscapeOnPortraitCanvas && cropLoss > 0.42
                    ? "landscape crop is too severe for a portrait slide; showing the whole photo as a hero"
                    : "faces do not fit a full-bleed crop; showing the whole photo as a hero")
                primitive = .hero
            }
        }

        var elements: [ResolvedElement] = []
        var background = "plain"
        let usable = Box(x: margin, y: margin, w: c.W - 2 * margin, h: c.H - 2 * margin)

        let env = SlideEnv(canvas: c, usable: usable, content: content, context: context,
                           density: slide.density, minVisible: minVisible, airy: plan.style?.whitespace == "airy")
        func rotation(_ e: PhotoElement) -> Double {
            let magnitude = rng.range(0.6, maxPhotoRot)
            switch e.rotationIntent {
            case "slightLeft": return -magnitude
            case "slightRight": return magnitude
            default: return 0
            }
        }

        var variant = "bleed"
        if primitive == .fullBleed {
            background = filmBand > 0 ? "plain" : "none"
            let e = env.photo(ranked[0], frame: content, z: 0)
            if !CropPlanner.facesFit(context.features[ranked[0].assetID], crop: e.crop!) { warnings.append("\(ranked[0].assetID): some people are cropped") }
            elements = [e]
        } else {
            let rotations = ranked.map { rotation($0) }
            let candidates: [Candidate] = switch primitive {
            case .hero, .framedHero: singleCandidates(ranked[0], framed: primitive == .framedHero, rotation: rotations[0], env: env)
            case .inset: insetCandidates(ranked[0], ranked[1], rotation: rotations[1], filmBand: filmBand > 0, env: env)
            case .asymmetricPair: pairCandidates(ranked[0], ranked[1], rotations: rotations, env: env)
            default: clusterCandidates(ranked, maxRot: maxPhotoRot, env: env, rng: &rng)
            }
            let chosen = choose(candidates, primitive: primitive, heroID: ranked[0].assetID, env: env, history: history, rng: &rng)
            variant = chosen.variant
            elements = chosen.elements
            background = chosen.background
            // No photo-derived washes: a blurred copy of the photo behind itself reads as filler, not design.
            warnings += chosen.notes
            for e in elements where e.crop.map({ $0.width * $0.height < 0.999 }) == true
                && !CropPlanner.facesFit(context.features[e.assetID!], crop: e.crop!) {
                warnings.append("\(e.assetID!.rawValue): some people are cropped")
            }
            if elements.count > 1 && overlapPenalty(elements, canvas: c, context: context, minVisible: minVisible) > 0 {
                warnings.append("\(primitive.rawValue) could not fully satisfy visibility/face constraints")
            }
        }
        history.append(Candidate(variant: variant, elements: [], background: "").family)

        var slideOut = ResolvedSlide(index: index, primitive: primitive, requestedPrimitive: slide.primitive,
                                     background: background, grain: 0, filmEdge: false, elements: elements, warnings: warnings)
        slideOut.variant = variant
        slideOut.metrics = metrics(elements, heroID: ranked[0].assetID, env: env)
        decorate(&slideOut, slide: slide, canvas: c, context: context, rng: &rng)
        return slideOut
    }

    // MARK: - Overlap safety

    /// Sum of visibility shortfalls below `minVisible` plus face-coverage fractions, over all photos.
    public static func overlapPenalty(_ elements: [ResolvedElement], canvasW: Double, canvasH: Double,
                                      features: [AssetID: PhotoFeatures], minVisible: Double) -> Double {
        let boxes = elements.map { Box(x: $0.frame.x * canvasW, y: $0.frame.y * canvasH, w: $0.frame.width * canvasW, h: $0.frame.height * canvasH) }
        var penalty = 0.0
        for (i, e) in elements.enumerated() {
            let above = elements.indices.filter { elements[$0].zIndex > e.zIndex }.map { boxes[$0] }
            guard !above.isEmpty else { continue }
            let visible = 1 - coveredFraction(boxes[i], by: above)
            if visible < minVisible { penalty += minVisible - visible }
            if let crop = e.crop, let id = e.assetID {
                for face in CropPlanner.facesOnCanvas(features[id], crop: crop, frame: boxes[i]) {
                    penalty += coveredFraction(face, by: above)
                }
            }
        }
        return penalty
    }

    /// Fraction of `box` covered by the union of `covers`, sampled on a 24×24 grid (no double counting).
    static func coveredFraction(_ box: Box, by covers: [Box]) -> Double {
        guard box.area > 0 else { return 0 }
        let n = 24
        var hit = 0
        for iy in 0..<n {
            let y = box.y + (Double(iy) + 0.5) / Double(n) * box.h
            for ix in 0..<n {
                let x = box.x + (Double(ix) + 0.5) / Double(n) * box.w
                if covers.contains(where: { x >= $0.x && x < $0.maxX && y >= $0.y && y < $0.maxY }) { hit += 1 }
            }
        }
        return Double(hit) / Double(n * n)
    }

    static func overlapPenalty(_ elements: [ResolvedElement], canvas c: Canvas, context: LayoutContext, minVisible: Double) -> Double {
        overlapPenalty(elements, canvasW: c.W, canvasH: c.H, features: context.features, minVisible: minVisible)
    }

    // MARK: - Decorations and stamps

    static func decorate(_ slide: inout ResolvedSlide, slide plan: SlidePlan, canvas c: Canvas, context: LayoutContext,
                         rng: inout SeededRandom) {
        let maxDecoRot = context.stylePack.allowedRotations["decorationDegrees"] ?? 4
        let photos = slide.elements.filter { $0.kind == .photo }
        let isFullBleedOnly = slide.background == "none" && photos.count == 1
        let faces: [Box] = photos.flatMap { p -> [Box] in
            guard let crop = p.crop, let id = p.assetID else { return [] }
            return CropPlanner.facesOnCanvas(context.features[id], crop: crop,
                                             frame: Box(x: p.frame.x * c.W, y: p.frame.y * c.H, w: p.frame.width * c.W, h: p.frame.height * c.H))
        }
        var z = (slide.elements.map(\.zIndex).max() ?? 0) + 1
        var wantsDate = plan.stamps.contains { $0.kind == "date" }
        let datePlacement = plan.stamps.first { $0.kind == "date" }?.placement ?? "bottomRight"
        if plan.stamps.contains(where: { $0.kind == "location" }) {
            slide.warnings.append("location stamp omitted: place names need a network geocoder (excluded in Phase 0)")
        }

        for d in plan.decorations {
            let strength = d.intensity == "high" ? 1.0 : d.intensity == "medium" ? 0.7 : 0.45
            switch d.decorationID {
            case "grain-fine":
                slide.grain = 0.12 * strength
            case "paper-warm":
                if slide.background == "none" { slide.warnings.append("paper-warm has no visible area on a full-bleed slide") }
                else if !slide.background.hasPrefix("wash:") { slide.background = "paper" }
            case "film-edge":
                slide.filmEdge = true
            case "date-stamp":
                wantsDate = true
            case "tape-clear":
                guard !isFullBleedOnly, let target = photos.filter({ $0.frame.width < 0.98 }).max(by: { $0.zIndex < $1.zIndex }) else {
                    slide.warnings.append("tape skipped: no framed photo to hold"); continue
                }
                let f = Box(x: target.frame.x * c.W, y: target.frame.y * c.H, w: target.frame.width * c.W, h: target.frame.height * c.H)
                let w = min(max(0.22 * f.w, 0.12 * c.W), 0.26 * c.W), h = 0.035 * c.H
                var placed: Box?
                for offset in [0.0, -0.3, 0.3] {
                    let b = Box(x: f.midX - w / 2 + offset * f.w + rng.range(-0.03, 0.03) * f.w, y: f.y - h * 0.45, w: w, h: h)
                    if !faces.contains(where: { $0.intersects(b) }) { placed = b; break }
                }
                guard let tape = placed else { slide.warnings.append("tape skipped: would cover a face"); continue }
                slide.elements.append(ResolvedElement(kind: .tape, assetID: nil, text: nil, frame: tape.unit(canvasW: c.W, canvasH: c.H),
                                                      rotationDegrees: rng.range(-maxDecoRot, maxDecoRot), crop: nil, zIndex: z,
                                                      opacity: 0.35 + 0.25 * strength, border: 0, shadow: false))
                z += 1
            default:
                slide.warnings.append("unknown decoration \(d.decorationID) ignored")
            }
        }

        guard wantsDate else { return }
        // Date comes from the most important photo on the slide (the first plan photo).
        guard let heroID = plan.photos.first?.assetID, let text = stampText(context.photos[heroID]?.metadata) else {
            slide.warnings.append("date stamp omitted: photo has no capture date"); return
        }
        let hostElement = photos.first { $0.assetID == heroID }
        let host = hostElement.map {
            Box(x: $0.frame.x * c.W, y: $0.frame.y * c.H, w: $0.frame.width * c.W, h: $0.frame.height * c.H)
        } ?? Box(x: 0, y: 0, w: c.W, h: c.H)
        // Other photos above the host are obstacles too (e.g. the small photo on an inset slide).
        let obstacles = faces + photos.filter { $0.assetID != heroID && $0.zIndex > (hostElement?.zIndex ?? -1) }.map {
            Box(x: $0.frame.x * c.W, y: $0.frame.y * c.H, w: $0.frame.width * c.W, h: $0.frame.height * c.H)
        }
        let h = 0.03 * c.H, w = h * 0.62 * Double(text.count) + h * 0.7
        let pad = 0.04 * min(host.w, host.h)
        let spots: [String: Box] = [
            "bottomRight": Box(x: host.maxX - pad - w, y: host.maxY - pad - h, w: w, h: h),
            "bottomLeft": Box(x: host.x + pad, y: host.maxY - pad - h, w: w, h: h),
            "topRight": Box(x: host.maxX - pad - w, y: host.y + pad, w: w, h: h),
            "topLeft": Box(x: host.x + pad, y: host.y + pad, w: w, h: h),
        ]
        let order = [datePlacement] + ["bottomRight", "bottomLeft", "topRight", "topLeft"].filter { $0 != datePlacement }
        guard let spot = order.first(where: { !obstacles.contains(where: spots[$0]!.intersects) }) else {
            slide.warnings.append("date stamp omitted: every corner would cover a face or photo"); return
        }
        slide.elements.append(ResolvedElement(kind: .stamp, assetID: heroID, text: text, frame: spots[spot]!.unit(canvasW: c.W, canvasH: c.H),
                                              rotationDegrees: 0, crop: nil, zIndex: z, opacity: 0.92, border: 0, shadow: false))
    }
}

/// Style geometry shared by the resolver (to reserve space) and the renderer (to draw it).
public enum StyleMetrics {
    public static func filmBand(canvasWidth: Double) -> Double { (0.05 * canvasWidth).rounded() }
}

extension LayoutResolver {
    /// Film-camera date imprint from the camera's own wall-clock date: "26 5 29" (the year tick is drawn by the renderer).
    static func stampText(_ m: CaptureMetadata?) -> String? {
        guard let raw = m?.localDateTime else {
            // Older runs lack the wall-clock string: format the absolute date in UTC so output stays machine-independent.
            guard let d = m?.capturedAt else { return nil }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%02d %d %d", c.year! % 100, c.month!, c.day!)
        }
        let parts = raw.split(separator: " ").first?.split(separator: ":").compactMap { Int($0) } ?? []
        guard parts.count == 3 else { return nil }
        return String(format: "%02d %d %d", parts[0] % 100, parts[1], parts[2])
    }
}

import Foundation

public struct LayoutContext: Sendable {
    public var aspect: CarouselAspect
    public var photos: [AssetID: PhotoRecord]
    public var features: [AssetID: PhotoFeatures]
    public var stylePack: StylePack
    public var seed: UInt64
    public init(aspect: CarouselAspect, photos: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures],
                stylePack: StylePack, seed: UInt64) {
        self.aspect = aspect; self.photos = photos; self.features = features; self.stylePack = stylePack; self.seed = seed
    }
}

/// Turns semantic slide intent into exact, deterministic geometry (spec §7). The model never supplies coordinates.
public enum LayoutResolver {
    public static func resolve(_ plan: CarouselPlan, context: LayoutContext) -> ResolvedCarousel {
        var rng = SeededRandom(seed: context.seed)
        let slides = plan.slides.enumerated().map { i, s in resolveSlide(s, index: i, context: context, rng: &rng) }
        return ResolvedCarousel(conceptType: plan.conceptType, aspect: context.aspect,
                                seed: String(context.seed, radix: 16), resolverVersion: ResolvedCarousel.resolverVersion,
                                slides: slides)
    }

    // MARK: - Slide

    struct Canvas {
        let W: Double, H: Double
        var short: Double { min(W, H) }
    }

    static func resolveSlide(_ slide: SlidePlan, index: Int, context: LayoutContext, rng: inout SeededRandom) -> ResolvedSlide {
        let c = Canvas(W: Double(context.aspect.exportWidth), H: Double(context.aspect.exportHeight))
        let spacing = context.stylePack.spacingRanges
        // A film edge draws bands down both sides; reserve them so nothing important sits underneath.
        let filmBand = slide.decorations.contains { $0.decorationID == "film-edge" } ? StyleMetrics.filmBand(canvasWidth: c.W) : 0
        let margin = max(rng.range(spacing["marginMin"] ?? 0.04, spacing["marginMax"] ?? 0.07) * c.short,
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
        let ranked = photos.enumerated().sorted {
            let a = ($0.element.importance, $0.element.role == "hero" ? 1 : 0, -$0.offset)
            let b = ($1.element.importance, $1.element.role == "hero" ? 1 : 0, -$1.offset)
            return a > b
        }.map(\.element)

        // Full-bleed faces that cannot fit the crop become a hero (whole photo) rather than being cut (spec §7.3).
        if primitive == .fullBleed {
            let e = photos[0]
            let a = Double(context.photos[e.assetID]!.pixelWidth) / Double(max(1, context.photos[e.assetID]!.pixelHeight))
            let crop = CropPlanner.cover(imageAspect: a, boxAspect: content.w / content.h, features: context.features[e.assetID],
                                         cropIntent: e.cropIntent, anchorIntent: e.anchorIntent)
            if !CropPlanner.facesFit(context.features[e.assetID], crop: crop) {
                warnings.append("faces do not fit a full-bleed crop; showing the whole photo as a hero")
                primitive = .hero
            }
        }

        var elements: [ResolvedElement] = []
        var background = "plain"
        let usable = Box(x: margin, y: margin, w: c.W - 2 * margin, h: c.H - 2 * margin)

        func aspect(_ id: AssetID) -> Double {
            let p = context.photos[id]!
            return Double(p.pixelWidth) / Double(max(1, p.pixelHeight))
        }
        func rotation(_ e: PhotoElement) -> Double {
            let magnitude = rng.range(0.6, maxPhotoRot)
            switch e.rotationIntent {
            case "slightLeft": return -magnitude
            case "slightRight": return magnitude
            default: return 0
            }
        }
        func photoElement(_ e: PhotoElement, frame: Box, z: Int, border: Double = 0, shadow: Bool = false,
                          rotation: Double = 0, fitWholePhoto: Bool = false) -> ResolvedElement {
            let crop = fitWholePhoto ? UnitRect(x: 0, y: 0, width: 1, height: 1)
                : CropPlanner.cover(imageAspect: aspect(e.assetID), boxAspect: frame.w / frame.h,
                                    features: context.features[e.assetID], cropIntent: e.cropIntent, anchorIntent: e.anchorIntent)
            return ResolvedElement(kind: .photo, assetID: e.assetID, text: nil, frame: frame.unit(canvasW: c.W, canvasH: c.H),
                                   rotationDegrees: rotation, crop: crop, zIndex: z, opacity: 1, border: border, shadow: shadow)
        }
        func contain(_ id: AssetID, in box: Box) -> Box {
            let a = aspect(id)
            let (w, h) = a > box.w / box.h ? (box.w, box.w / a) : (box.h * a, box.h)
            return Box(x: box.midX - w / 2, y: box.midY - h / 2, w: w, h: h)
        }

        switch primitive {
        case .fullBleed:
            background = filmBand > 0 ? "plain" : "none"
            elements.append(photoElement(ranked[0], frame: content, z: 0))

        case .hero:
            let e = ranked[0]
            if e.cropIntent == "tight" {
                elements.append(photoElement(e, frame: usable, z: 0))
            } else if aspect(e.assetID) > 1.15 * usable.w / usable.h,
                      CropPlanner.facesFit(context.features[e.assetID],
                                           crop: CropPlanner.cover(imageAspect: aspect(e.assetID),
                                                                   boxAspect: max(usable.w / usable.h, min(aspect(e.assetID), 1.0)),
                                                                   features: context.features[e.assetID])) {
                // A landscape photo would float small on a tall canvas: crop it toward square (face-safe) instead.
                let target = max(usable.w / usable.h, min(aspect(e.assetID), 1.0))
                let w = usable.w, h = min(usable.h, w / target)
                elements.append(photoElement(e, frame: Box(x: usable.x, y: usable.midY - h / 2, w: w, h: h), z: 0))
            } else {
                elements.append(photoElement(e, frame: contain(e.assetID, in: usable), z: 0, fitWholePhoto: true))
            }

        case .framedHero:
            let e = ranked[0]
            let box = usable.inset(0.04 * c.short)
            if aspect(e.assetID) > 1.15 * box.w / box.h {
                let h = min(box.h, box.w / max(box.w / box.h, min(aspect(e.assetID), 1.0)))
                elements.append(photoElement(e, frame: Box(x: box.x, y: box.midY - h / 2, w: box.w, h: h), z: 0,
                                             border: 0.025, shadow: true, rotation: rotation(e)))
            } else {
                elements.append(photoElement(e, frame: contain(e.assetID, in: box), z: 0, border: 0.025, shadow: true,
                                             rotation: rotation(e), fitWholePhoto: true))
            }

        case .inset:
            background = filmBand > 0 ? "plain" : "none"
            let main = ranked[0], small = ranked[1]
            let mainEl = photoElement(main, frame: content, z: 0)
            if !CropPlanner.facesFit(context.features[main.assetID], crop: mainEl.crop!) {
                warnings.append("some faces in the main inset photo are cropped")
            }
            elements.append(mainEl)
            let a = aspect(small.assetID)
            var w = 0.36 * c.W, h = w / a
            if h > 0.42 * c.H { h = 0.42 * c.H; w = h * a }
            let faces = CropPlanner.facesOnCanvas(context.features[main.assetID], crop: mainEl.crop!, frame: content)
            let corners: [String: Box] = [
                "TL": Box(x: margin, y: margin, w: w, h: h), "TR": Box(x: c.W - margin - w, y: margin, w: w, h: h),
                "BL": Box(x: margin, y: c.H - margin - h, w: w, h: h), "BR": Box(x: c.W - margin - w, y: c.H - margin - h, w: w, h: h),
            ]
            let preference: [String] = switch small.anchorIntent {
            case "top": ["TR", "TL", "BR", "BL"]
            case "bottom": ["BR", "BL", "TR", "TL"]
            case "left": ["TL", "BL", "TR", "BR"]
            case "right": ["TR", "BR", "TL", "BL"]
            default: ["BR", "TR", "BL", "TL"]
            }
            let covered = { (b: Box) in faces.reduce(0) { $0 + b.intersection($1).area } }
            let corner = preference.first { covered(corners[$0]!) == 0 } ?? preference.min { covered(corners[$0]!) < covered(corners[$1]!) }!
            if covered(corners[corner]!) > 0 { warnings.append("inset covers part of a face; no clear corner") }
            elements.append(photoElement(small, frame: corners[corner]!, z: 1, border: 0.018, shadow: true, rotation: rotation(small)))

        case .asymmetricPair:
            let dom = ranked[0], sec = ranked[1]
            let mirror = rng.bool()
            var d = Box(x: usable.x, y: usable.y, w: 0.66 * usable.w, h: 0.58 * usable.h)
            var s = Box(x: usable.maxX - 0.46 * usable.w, y: usable.maxY - 0.40 * usable.h, w: 0.46 * usable.w, h: 0.40 * usable.h)
            let pull = sec.overlapIntent == "strong" ? 0.16 : sec.overlapIntent == "slight" ? 0.08 : 0
            s.y -= pull * usable.h; s.x -= pull * usable.w * 0.5
            if mirror {
                d.x = usable.maxX - d.w
                s.x = usable.x + pull * usable.w * 0.5
            }
            var domEl = photoElement(dom, frame: d, z: 0, rotation: rotation(dom))
            var secEl = photoElement(sec, frame: s, z: 1, border: pull > 0 ? 0.012 : 0, shadow: pull > 0, rotation: rotation(sec))
            // Never let the overlapping photo cover the dominant photo's faces.
            if pull > 0 {
                let faces = CropPlanner.facesOnCanvas(context.features[dom.assetID], crop: domEl.crop!, frame: d)
                if faces.contains(where: { $0.intersects(s) }) {
                    s.y += pull * usable.h
                    s.x += mirror ? -pull * usable.w * 0.5 : pull * usable.w * 0.5
                    secEl = photoElement(sec, frame: s, z: 1, rotation: rotation(sec))
                    warnings.append("overlap removed to keep faces visible")
                }
            }
            domEl.zIndex = 0
            elements += [domEl, secEl]

        case .overlapCluster:
            elements += cluster(ranked, usable: usable, canvas: c, context: context, minVisible: minVisible,
                                maxRot: maxPhotoRot, rng: &rng, warnings: &warnings)
        }

        var slideOut = ResolvedSlide(index: index, primitive: primitive, requestedPrimitive: slide.primitive,
                                     background: background, grain: 0, filmEdge: false, elements: elements, warnings: warnings)
        decorate(&slideOut, slide: slide, canvas: c, context: context, rng: &rng)
        return slideOut
    }

    // MARK: - Overlap cluster

    static func cluster(_ photos: [PhotoElement], usable: Box, canvas c: Canvas, context: LayoutContext, minVisible: Double,
                        maxRot: Double, rng: inout SeededRandom, warnings: inout [String]) -> [ResolvedElement] {
        let n = photos.count
        let anchors: [(Double, Double)] = switch n {
        case 2: [(0.36, 0.34), (0.64, 0.68)]
        case 3: [(0.34, 0.28), (0.66, 0.47), (0.40, 0.75)]
        default: [(0.31, 0.27), (0.69, 0.31), (0.33, 0.73), (0.69, 0.74)]
        }
        let baseWidth = n == 2 ? 0.62 : n == 3 ? 0.55 : 0.50
        // Least important at the bottom, most important on top.
        let order = Array(photos.enumerated().reversed())

        func layout(spread: Double, scale: Double, rng: inout SeededRandom) -> [ResolvedElement] {
            var out: [ResolvedElement] = []
            for (z, (slot, e)) in order.enumerated() {
                let p = context.photos[e.assetID]!
                let a = Double(p.pixelWidth) / Double(max(1, p.pixelHeight))
                var w = baseWidth * scale * usable.w, h = w / a
                if h > 0.55 * scale * usable.h { h = 0.55 * scale * usable.h; w = h * a }
                let (ax, ay) = anchors[slot]
                var cx = usable.x + (ax + rng.range(-spread, spread)) * usable.w
                var cy = usable.y + (ay + rng.range(-spread, spread)) * usable.h
                cx = min(max(cx, usable.x + w / 2), usable.maxX - w / 2)
                cy = min(max(cy, usable.y + h / 2), usable.maxY - h / 2)
                let frame = Box(x: cx - w / 2, y: cy - h / 2, w: w, h: h)
                let rot: Double = switch e.rotationIntent {
                case "slightLeft": -rng.range(0.6, maxRot)
                case "slightRight": rng.range(0.6, maxRot)
                default: rng.range(-maxRot, maxRot)
                }
                out.append(ResolvedElement(kind: .photo, assetID: e.assetID, text: nil, frame: frame.unit(canvasW: c.W, canvasH: c.H),
                                           rotationDegrees: rot, crop: UnitRect(x: 0, y: 0, width: 1, height: 1), zIndex: z,
                                           opacity: 1, border: 0.02, shadow: true))
            }
            return out
        }

        var best: [ResolvedElement] = [], bestPenalty = Double.infinity
        attempts: for scale in [1.0, 0.9, 0.8] {
            for attempt in 0..<24 {
                let candidate = layout(spread: 0.04 + 0.005 * Double(attempt), scale: scale, rng: &rng)
                let penalty = overlapPenalty(candidate, canvas: c, context: context, minVisible: minVisible)
                if penalty < bestPenalty { best = candidate; bestPenalty = penalty }
                if penalty == 0 { break attempts }
            }
        }
        if bestPenalty > 0 { warnings.append("overlap cluster could not fully satisfy visibility/face constraints") }
        return best
    }

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
                else { slide.background = "paper" }
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

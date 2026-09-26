import Foundation

/// Layout quality measures for one resolved slide, stored with the layout so runs can be compared.
public struct SlideMetrics: Codable, Sendable, Equatable {
    /// Fraction of the canvas covered by photos.
    public var coverage: Double
    /// Hero's visible area over the largest other photo's visible area (nil on single-photo slides).
    public var heroShare: Double?
    /// Largest fraction of any photo cut away by its crop.
    public var maxCropLoss: Double
}

/// Aspect-aware composition (spec §7): each primitive proposes several arrangements whose frames follow the photos'
/// shapes; every candidate is scored on the same postability terms (crop loss, people safety, overlap safety,
/// hierarchy, density, balance, carousel rhythm) and the seed picks among the near-best. No concept gets a
/// lower bar: Wildcard is bolder in its primitive mix, not in how much it may crop or clutter.
extension LayoutResolver {
    struct Candidate {
        var variant: String
        var elements: [ResolvedElement]
        var background: String
        /// Soft preference cost (e.g. an overlap intent that could not be honoured).
        var bias: Double = 0
        var notes: [String] = []
        /// Carousel-rhythm family: the first two variant components ("pair.stack").
        var family: String { variant.split(separator: ".").prefix(2).joined(separator: ".") }
    }

    struct SlideEnv {
        let canvas: Canvas
        let usable: Box
        let content: Box
        let context: LayoutContext
        let density: String
        let minVisible: Double

        func aspect(_ id: AssetID) -> Double {
            let p = context.photos[id]!
            return Double(p.pixelWidth) / Double(max(1, p.pixelHeight))
        }
        func unit(_ b: Box) -> UnitRect { b.unit(canvasW: canvas.W, canvasH: canvas.H) }
        func box(_ u: UnitRect) -> Box { Box(x: u.x * canvas.W, y: u.y * canvas.H, w: u.width * canvas.W, h: u.height * canvas.H) }

        /// Photo share of the canvas each density asks for.
        var densityTarget: Double { density == "quiet" ? 0.52 : density == "dense" ? 0.78 : 0.64 }
        /// How much of the available space a single arrangement fills before scoring.
        var densityScale: Double { density == "quiet" ? 0.84 : density == "dense" ? 1.0 : 0.93 }

        /// Cover-crops `e` into `frame` (no fallback: the scorer rejects crops that cut people).
        func photo(_ e: PhotoElement, frame: Box, z: Int, border: Double = 0, shadow: Bool = false,
                   rotation: Double = 0, whole: Bool = false) -> ResolvedElement {
            let a = aspect(e.assetID), boxAspect = frame.w / frame.h
            let crop = whole || abs(a / boxAspect - 1) < 0.002 ? UnitRect(x: 0, y: 0, width: 1, height: 1)
                : CropPlanner.cover(imageAspect: a, boxAspect: boxAspect, features: context.features[e.assetID],
                                    cropIntent: e.cropIntent, anchorIntent: e.anchorIntent)
            return ResolvedElement(kind: .photo, assetID: e.assetID, text: nil, frame: unit(frame), rotationDegrees: rotation,
                                   crop: crop, zIndex: z, opacity: 1, border: border, shadow: shadow)
        }
    }

    /// Box aspect for a photo: its own aspect pulled toward square by `squareness` (0 = exact, 1 = square), in log space.
    static func shaped(_ a: Double, _ squareness: Double) -> Double { exp(log(a) * (1 - squareness)) }

    /// Largest box of aspect `a` inside `box`, placed at the optical centre (slightly above middle).
    static func fit(_ a: Double, in box: Box, scale: Double = 1) -> Box {
        var (w, h) = a > box.w / box.h ? (box.w, box.w / a) : (box.h * a, box.h)
        w *= scale; h *= scale
        return Box(x: box.midX - w / 2, y: box.y + (box.h - h) * 0.44, w: w, h: h)
    }

    // MARK: - Candidates

    static func singleCandidates(_ e: PhotoElement, framed: Bool, rotation: Double, env: SlideEnv) -> [Candidate] {
        let box = framed ? env.usable.inset(0.04 * env.canvas.short) : env.usable
        let a = env.aspect(e.assetID)
        let canvasArea = env.canvas.W * env.canvas.H
        /// Shrinks toward the density target, but never below 80%: a landscape that already leaves space stays full width.
        func frame(_ aspect: Double) -> Box {
            let full = fit(aspect, in: box)
            return fit(aspect, in: box, scale: min(1, max(0.8, (env.densityTarget * canvasArea / full.area).squareRoot())))
        }
        let style = { (frame: Box, whole: Bool) in
            env.photo(e, frame: frame, z: 0, border: framed ? 0.025 : 0, shadow: framed, rotation: framed ? rotation : 0, whole: whole)
        }
        let kind = framed ? "framed" : "hero"
        var out = [Candidate(variant: "\(kind).whole", elements: [style(frame(a), true)], background: "plain")]
        for q in [0.35, 0.7] {
            let target = shaped(a, q)
            guard abs(target / a - 1) > 0.03 else { continue }
            out.append(Candidate(variant: "\(kind).crop\(Int(q * 100))", elements: [style(frame(target), false)], background: "plain"))
        }
        if e.cropIntent == "tight" {
            out.append(Candidate(variant: "\(kind).fill", elements: [style(frame(box.w / box.h), false)], background: "plain"))
        }
        return out
    }

    /// Two photos along one axis (stacked or side by side), hero larger by `ratio`, optionally overlapping.
    static func pairCandidates(_ hero: PhotoElement, _ sup: PhotoElement, rotations: [Double], env: SlideEnv) -> [Candidate] {
        let u = env.usable, gap = 0.035 * env.canvas.short
        let wanted = sup.overlapIntent == "strong" ? 0.32 : sup.overlapIntent == "slight" ? 0.18 : 0
        var out: [Candidate] = []
        for vertical in [true, false] {
            let mainLen = vertical ? u.h : u.w, crossLen = vertical ? u.w : u.h
            for heroFirst in [true, false] { for heroAtStart in [true, false] { for ratio in [1.7, 2.4] {
                for q in [0.0, 0.35] { for overlap in Set([wanted, 0]).sorted(by: >) {
                    let aH = shaped(env.aspect(hero.assetID), q), aS = shaped(env.aspect(sup.assetID), q)
                    // Unit sizes as (main, cross); the hero's cross size is 1.
                    let mH = vertical ? 1 / aH : aH
                    let areaS = mH / ratio
                    let sW = (areaS * aS).squareRoot(), sH = (areaS / aS).squareRoot()
                    let mS = vertical ? sH : sW, cS = vertical ? sW : sH
                    let g = overlap > 0 ? 0 : gap
                    let t = min(crossLen / max(1, cS), (mainLen - g) / (mH + mS * (1 - overlap))) * env.densityScale
                    let heroM = t * mH, supM = t * mS, heroC = t, supC = t * cS
                    let extent = heroM + supM * (1 - overlap) + g
                    let m0 = (mainLen - extent) / 2
                    let firstLen = heroFirst ? heroM : supM
                    let firstPos = m0, secondPos = m0 + firstLen + g - overlap * (heroFirst ? supM : heroM)
                    let heroPos = heroFirst ? firstPos : secondPos, supPos = heroFirst ? secondPos : firstPos
                    var heroCross = heroAtStart ? 0 : crossLen - heroC
                    var supCross = heroAtStart ? crossLen - supC : 0
                    if overlap > 0 {
                        // Pull the support across so the overlap is real, never past the hero's far edge.
                        let reach = overlap * supC
                        if heroAtStart { supCross = min(supCross, heroC - reach) } else { supCross = max(supCross, heroCross + reach - supC) }
                        supCross = min(max(0, supCross), crossLen - supC)
                        heroCross = min(max(0, heroCross), crossLen - heroC)
                    }
                    func frame(_ m: Double, _ c: Double, _ ml: Double, _ cl: Double) -> Box {
                        vertical ? Box(x: u.x + c, y: u.y + m, w: cl, h: ml) : Box(x: u.x + m, y: u.y + c, w: ml, h: cl)
                    }
                    let heroEl = env.photo(hero, frame: frame(heroPos, heroCross, heroM, heroC), z: 0, rotation: rotations[0])
                    let supEl = env.photo(sup, frame: frame(supPos, supCross, supM, supC), z: 1, border: overlap > 0 ? 0.012 : 0,
                                          shadow: overlap > 0, rotation: rotations[1])
                    var c = Candidate(variant: "pair.\(vertical ? "stack" : "row").\(heroFirst ? "hero1" : "hero2")"
                                          + ".\(heroAtStart ? "s" : "e").r\(ratio).q\(q).o\(overlap)",
                                      elements: [heroEl, supEl], background: "plain")
                    if wanted > 0 && overlap == 0 { c.bias = 0.12; c.notes = ["overlap dropped to keep faces and hierarchy clear"] }
                    out.append(c)
                }}
            }}}
        }
        return out
    }

    /// A main photo with a smaller one: either full-bleed with a corner inset, or a full-width block the small photo
    /// straddles (for photos whose shape would lose too much as a full-bleed).
    static func insetCandidates(_ main: PhotoElement, _ small: PhotoElement, rotation: Double, filmBand: Bool,
                                env: SlideEnv) -> [Candidate] {
        let c = env.canvas, u = env.usable
        let frac = env.density == "quiet" ? 0.30 : env.density == "dense" ? 0.42 : 0.36
        let preference: [String] = switch small.anchorIntent {
        case "top": ["TR", "TL", "BR", "BL"]
        case "bottom": ["BR", "BL", "TR", "TL"]
        case "left": ["TL", "BL", "TR", "BR"]
        case "right": ["TR", "BR", "TL", "BL"]
        default: ["BR", "TR", "BL", "TL"]
        }
        var out: [Candidate] = []
        for q in [0.0, 0.35] {
            let aS = shaped(env.aspect(small.assetID), q)
            var w = frac * c.W, h = w / aS
            if h > 0.42 * c.H { h = 0.42 * c.H; w = h * aS }
            // Full-bleed main, small photo in a corner.
            let mainEl = env.photo(main, frame: env.content, z: 0)
            for (rank, corner) in preference.enumerated() {
                let x = corner.hasSuffix("L") ? u.x : u.maxX - w, y = corner.hasPrefix("T") ? u.y : u.maxY - h
                let smallEl = env.photo(small, frame: Box(x: x, y: y, w: w, h: h), z: 1, border: 0.018, shadow: true, rotation: rotation)
                out.append(Candidate(variant: "inset.bleed.\(corner).q\(q)", elements: [mainEl, smallEl],
                                     background: filmBand ? "plain" : "none", bias: 0.02 * Double(rank)))
            }
            // Full-width block with the small photo straddling its inner edge.
            for qm in [0.0, 0.35] {
                let aM = shaped(env.aspect(main.assetID), qm)
                let bh = min(env.content.w / aM, 0.78 * c.H)
                for below in [true, false] { for left in [true, false] {
                    // Centre the block plus the small photo's overhang at the optical centre.
                    let overhang = 0.7 * h, groupY = u.y + max(0, u.h - bh - overhang) * 0.44
                    let block = Box(x: env.content.x, y: below ? groupY : groupY + overhang, w: env.content.w, h: bh)
                    let sy = min(max(below ? block.maxY - 0.3 * h : groupY, u.y), u.maxY - h)
                    let smallEl = env.photo(small, frame: Box(x: left ? u.x : u.maxX - w, y: sy, w: w, h: h), z: 1,
                                            border: 0.018, shadow: true, rotation: rotation)
                    out.append(Candidate(variant: "inset.block.\(below ? "below" : "above").\(left ? "l" : "r").q\(q)m\(qm)",
                                         elements: [env.photo(main, frame: block, z: 0), smallEl], background: "plain"))
                }}
            }
        }
        return out
    }

    static func clusterCandidates(_ photos: [PhotoElement], maxRot: Double, env: SlideEnv, rng: inout SeededRandom) -> [Candidate] {
        let sets: [(String, [(Double, Double)])] = switch photos.count {
        case 2: [("diag", [(0.37, 0.33), (0.64, 0.69)]), ("drop", [(0.45, 0.30), (0.57, 0.72)])]
        case 3: [("zigzag", [(0.34, 0.28), (0.66, 0.47), (0.40, 0.75)]), ("crown", [(0.50, 0.32), (0.28, 0.73), (0.72, 0.71)]),
                 ("core", [(0.52, 0.50), (0.28, 0.21), (0.72, 0.80)])]
        default: [("grid", [(0.31, 0.27), (0.69, 0.31), (0.33, 0.73), (0.69, 0.74)]),
                  ("core", [(0.50, 0.47), (0.26, 0.19), (0.76, 0.24), (0.50, 0.83)])]
        }
        var out: [Candidate] = []
        for (name, anchors) in sets { for mirror in [false, true] {
            let a = mirror ? anchors.map { (1 - $0.0, $0.1) } : anchors
            let (elements, _) = cluster(photos, anchors: a, env: env, maxRot: maxRot, rng: &rng)
            out.append(Candidate(variant: "cluster.\(name).\(mirror ? "m" : "n")", elements: elements, background: "plain"))
        }}
        return out
    }

    /// Scatters photos (most important on top, hero larger) around `anchors`, searching jitter and scale for a
    /// placement that keeps every photo ≥ minVisible and every face uncovered.
    static func cluster(_ photos: [PhotoElement], anchors: [(Double, Double)], env: SlideEnv, maxRot: Double,
                        rng: inout SeededRandom) -> ([ResolvedElement], Double) {
        let n = photos.count, u = env.usable
        let baseWidth = (n == 2 ? 0.60 : n == 3 ? 0.52 : 0.46) * (env.densityScale + 0.08)
        let order = Array(photos.enumerated().reversed())   // least important at the bottom

        func layout(spread: Double, scale: Double, rng: inout SeededRandom) -> [ResolvedElement] {
            order.enumerated().map { z, item in
                let (slot, e) = item
                let a = env.aspect(e.assetID), size = scale * (slot == 0 ? 1.2 : 0.92)
                var w = baseWidth * size * u.w, h = w / a
                if h > 0.55 * size * u.h { h = 0.55 * size * u.h; w = h * a }
                w = min(w, u.w); h = min(h, u.h)
                let (ax, ay) = anchors[slot]
                let cx = min(max(u.x + (ax + rng.range(-spread, spread)) * u.w, u.x + w / 2), u.maxX - w / 2)
                let cy = min(max(u.y + (ay + rng.range(-spread, spread)) * u.h, u.y + h / 2), u.maxY - h / 2)
                let rot: Double = switch e.rotationIntent {
                case "slightLeft": -rng.range(0.6, maxRot)
                case "slightRight": rng.range(0.6, maxRot)
                default: rng.range(-maxRot, maxRot)
                }
                return env.photo(e, frame: Box(x: cx - w / 2, y: cy - h / 2, w: w, h: h), z: z, border: 0.02, shadow: true,
                                 rotation: rot, whole: true)
            }
        }
        var best: [ResolvedElement] = [], bestPenalty = Double.infinity
        attempts: for scale in [1.0, 0.9, 0.8] {
            for attempt in 0..<24 {
                let candidate = layout(spread: 0.04 + 0.005 * Double(attempt), scale: scale, rng: &rng)
                let penalty = overlapPenalty(candidate, canvas: env.canvas, context: env.context, minVisible: env.minVisible)
                if penalty < bestPenalty { best = candidate; bestPenalty = penalty }
                if penalty == 0 { break attempts }
            }
        }
        return (best, bestPenalty)
    }

    // MARK: - Scoring

    static func metrics(_ elements: [ResolvedElement], heroID: AssetID?, env: SlideEnv) -> SlideMetrics {
        let photos = elements.filter { $0.kind == .photo }
        let boxes = photos.map { env.box($0.frame) }
        let n = 40
        var hit = 0
        for iy in 0..<n { for ix in 0..<n {
            let x = (Double(ix) + 0.5) / Double(n) * env.canvas.W, y = (Double(iy) + 0.5) / Double(n) * env.canvas.H
            if boxes.contains(where: { x >= $0.x && x < $0.maxX && y >= $0.y && y < $0.maxY }) { hit += 1 }
        }}
        let visible = photos.indices.map { i in
            boxes[i].area * (1 - coveredFraction(boxes[i], by: photos.indices.filter { photos[$0].zIndex > photos[i].zIndex }.map { boxes[$0] }))
        }
        var share: Double?
        if photos.count > 1, let h = photos.firstIndex(where: { $0.assetID == heroID }) {
            let other = visible.indices.filter { $0 != h }.map { visible[$0] }.max() ?? 0
            share = other > 0 ? visible[h] / other : nil
        }
        let loss = photos.map { 1 - ($0.crop.map { $0.width * $0.height } ?? 1) }.max() ?? 0
        return SlideMetrics(coverage: Double(hit) / Double(n * n), heroShare: share, maxCropLoss: loss)
    }

    static func score(_ c: Candidate, primitive: Primitive, heroID: AssetID, env: SlideEnv, history: [String]) -> Double {
        let photos = c.elements.filter { $0.kind == .photo }
        let m = metrics(photos, heroID: heroID, env: env)
        var s = c.bias
        for p in photos {
            guard let crop = p.crop, let id = p.assetID else { continue }
            let loss = 1 - crop.width * crop.height
            s += (id == heroID ? 1.0 : 0.6) * loss + 2 * max(0, loss - 0.35)
            if loss > 0.001 && !CropPlanner.facesFit(env.context.features[id], crop: crop) { s += 3 }
        }
        s += 4 * overlapPenalty(photos, canvas: env.canvas, context: env.context, minVisible: env.minVisible)
        s += 0.6 * salientCover(photos, env: env)
        if let share = m.heroShare { s += max(0, (primitive == .overlapCluster ? 1.25 : 1.6) - share) }
        let target = primitive == .inset ? min(0.95, env.densityTarget + 0.25) : env.densityTarget
        s += 1.5 * abs(m.coverage - target)
        // Visual balance: the area-weighted centre of the photos should sit near the canvas centre.
        let boxes = photos.map { env.box($0.frame) }, total = boxes.reduce(0) { $0 + $1.area }
        if total > 0 {
            let cx = boxes.reduce(0) { $0 + $1.midX * $1.area } / total / env.canvas.W
            let cy = boxes.reduce(0) { $0 + $1.midY * $1.area } / total / env.canvas.H
            s += 1.5 * max(0, hypot(cx - 0.5, cy - 0.48) - 0.06)
        }
        // Rhythm: avoid the same arrangement on consecutive slides and repeating it across the carousel.
        if history.last == c.family { s += 0.2 }
        s += 0.06 * Double(history.filter { $0 == c.family }.count)
        return s
    }

    /// Fraction of each photo's largest salient region hidden by photos above it, summed.
    static func salientCover(_ photos: [ResolvedElement], env: SlideEnv) -> Double {
        var total = 0.0
        for p in photos {
            let above = photos.filter { $0.zIndex > p.zIndex }.map { env.box($0.frame) }
            guard !above.isEmpty, let id = p.assetID, let crop = p.crop,
                  let r = env.context.features[id]?.salientRegions.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
            let f = env.box(p.frame)
            let b = Box(x: f.x + (r.x - crop.x) / crop.width * f.w, y: f.y + (r.y - crop.y) / crop.height * f.h,
                        w: r.width / crop.width * f.w, h: r.height / crop.height * f.h).intersection(f)
            total += coveredFraction(b, by: above)
        }
        return total
    }

    /// Scores every candidate and lets the seed pick among those within a small margin of the best.
    static func choose(_ candidates: [Candidate], primitive: Primitive, heroID: AssetID, env: SlideEnv, history: [String],
                       rng: inout SeededRandom) -> Candidate {
        let scored = candidates.enumerated()
            .map { ($0.offset, $0.element, score($0.element, primitive: primitive, heroID: heroID, env: env, history: history)) }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
        let near = scored.filter { $0.2 <= scored[0].2 + 0.05 }
        return near[Int(rng.next() % UInt64(near.count))].1
    }
}

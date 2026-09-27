import Foundation

/// Local evidence the composer engine works from. Everything here is on-device; nothing is sent anywhere.
public struct CompositionContext: Sendable {
    public var aspect: CarouselAspect
    public var photos: [AssetID: PhotoRecord]
    public var features: [AssetID: PhotoFeatures]
    public var triage: [AssetID: TriageScore]
    /// Photos with a social-safety flag (never a cover when an alternative exists).
    public var flagged: Set<AssetID>
    public var sequenceIntent: [AssetID: SequenceIntent]
    public var stylePack: StylePack
    /// The user's requested slide count, if any.
    public var maxSlides: Int?
    public var exactSet: Bool
    public var keepOrder: Bool
    public var storyHint: String?
    /// Imported page arrangements shared by composition, scoring, and judging.
    public var vocabulary: [DesignedSet]

    public init(aspect: CarouselAspect, photos: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures],
                triage: [AssetID: TriageScore], flagged: Set<AssetID>, sequenceIntent: [AssetID: SequenceIntent],
                stylePack: StylePack, maxSlides: Int?, exactSet: Bool = false, keepOrder: Bool = false,
                storyHint: String? = nil, vocabulary: [DesignedSet] = []) {
        self.aspect = aspect; self.photos = photos; self.features = features; self.triage = triage; self.flagged = flagged
        self.sequenceIntent = sequenceIntent; self.stylePack = stylePack; self.maxSlides = maxSlides
        self.exactSet = exactSet
        self.keepOrder = keepOrder
        self.storyHint = storyHint
        self.vocabulary = vocabulary
    }
}

/// Turns a direction (story + style axes) into a complete carousel plan, deterministically for a seed:
/// groups photos into slides, assigns primitives and per-photo intents, budgets decoration, then resolves
/// several whole compositions through the layout engine and keeps one of the best. Every direction, and the
/// baseline, is held to the same scoring.
public enum ComposerEngine {
    public static let version = "composer-2"
    static let candidateCount = 6

    public struct Composition: Sendable {
        public var plan: CarouselPlan
        public var score: Double
        public var warnings: [String]
    }

    public struct ComposedSet: Sendable {
        /// Baseline first, then the kept directions (c1…).
        public var plans: [CarouselPlan]
        public var distances: [ConceptDistance]
        public var presentationOrder: [String]
        public var warnings: [String]
    }

    /// Seed the layout engine uses for a carousel; composition evaluates with the same seed so what was scored is
    /// exactly what renders.
    public static func layoutSeed(runID: String, id: String) -> UInt64 {
        SeededRandom.seed(runID, id, ResolvedCarousel.resolverVersion)
    }

    // MARK: - Set

    public static func composeSet(directions: [Direction], spine: SelectionSpine, context: CompositionContext,
                                  runID: String) -> ComposedSet {
        var warnings: [String] = []
        let baselineDirection = Direction(brief: "The selected photos as they are, one per slide.", style: .baseline,
                                          coverAssetID: spine.orderedAssetIDs.first ?? AssetID(rawValue: ""),
                                          orderedAssetIDs: spine.orderedAssetIDs)
        let base = compose(baselineDirection, id: CarouselPlan.baselineID, context: context,
                           seed: layoutSeed(runID: runID, id: CarouselPlan.baselineID))
        warnings += base.warnings.map { "baseline: \($0)" }

        var kept: [CarouselPlan] = []
        for (i, d) in directions.enumerated() {
            let id = "c\(i + 1)", seed = layoutSeed(runID: runID, id: id)
            var comp = compose(d, id: id, context: context, seed: seed)
            warnings += comp.warnings.map { "\(id): \($0)" }
            // Every direction must also differ from the photos-only baseline, or the study comparison is empty.
            let others = [base.plan] + kept
            var conflictAttempts = 0
            var shouldDrop = false
            while let clash = others.first(where: { !distinct($0, comp.plan, context: context) }),
                  conflictAttempts < others.count {
                conflictAttempts += 1
                // Recompose away from the earlier carousel: unused cover, rotated story beat,
                // bounded same-event substitutions, then coherent style nudges.
                let sourceDirection = comp.plan.direction ?? d
                var tries = remedyDirections(sourceDirection, against: clash, others: others, context: context)
                var groupingNudge = tries.last ?? sourceDirection
                groupingNudge.style.grouping = sourceDirection.style.grouping == "single" ? "mixed" : sourceDirection.style.grouping == "mixed" ? "collage" : "mixed"
                tries.append(groupingNudge)
                // If relation constraints send every group to separate slides, grouping alone
                // cannot distinguish the direction. Try coherent adjacent style axes before
                // dropping an otherwise valid option.
                var airyNudge = groupingNudge
                airyNudge.style.whitespace = sourceDirection.style.whitespace == "airy" ? "tight" : "airy"
                airyNudge.style.density = sourceDirection.style.density == "dense" ? "quiet" : "dense"
                tries.append(airyNudge)
                var finishNudge = airyNudge
                finishNudge.style.decoration = sourceDirection.style.decoration == "rich" ? "none" : "rich"
                finishNudge.style.rotation = sourceDirection.style.rotation == "some" ? "none" : "some"
                tries.append(finishNudge)
                var fixed = false
                attempts: for t in tries {
                    for salt in 0..<3 {
                        let alt = compose(t, id: id, context: context,
                                          seed: salt == 0 ? seed : SeededRandom.seed(runID, id, "alt\(salt)"), layoutSeed: seed)
                        if others.allSatisfy({ distinct($0, alt.plan, context: context) }) {
                            comp = alt; fixed = true
                            warnings.append("\(id): recomposed to differ from \(clash.id)")
                            break attempts
                        }
                    }
                }
                if !fixed {
                    if kept.count + (directions.count - i - 1) >= 2 {   // dropping still leaves two directions
                        warnings.append("\(id): dropped, too similar to \(clash.id)")
                        shouldDrop = true
                        break
                    }
                    warnings.append("\(id): still similar to \(clash.id); kept so at least two directions remain")
                    break
                }
            }
            if shouldDrop { continue }
            kept.append(comp.plan)
        }

        var distances: [ConceptDistance] = []
        for i in kept.indices { for j in kept.indices where j > i {
            var d = PlanMetrics.diversity(kept[i], kept[j])
            d.a = kept[i].id; d.b = kept[j].id
            if let si = kept[i].style, let sj = kept[j].style { d.styleDistance = si.distance(to: sj) }
            distances.append(d)
        }}
        let plans = [base.plan] + kept
        var order = plans.map(\.id)
        var rng = SeededRandom(seed: SeededRandom.seed(runID, "presentation-order"))
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        return ComposedSet(plans: plans, distances: distances, presentationOrder: order, warnings: warnings)
    }

    private static func distinct(_ a: CarouselPlan, _ b: CarouselPlan, context: CompositionContext) -> Bool {
        if a.isBaseline || b.isBaseline {
            // The baseline is a control, not one of the designed options. Keep its cover
            // distinct so the comparison remains meaningful, without applying option-only
            // selection and template-family thresholds to it.
            return a.coverAssetID != b.coverAssetID
        }
        guard PlanMetrics.diversity(a, b).passes else { return false }
        // The same photos in a different order still reads as one option to the owner.
        let photosA = Set(a.photoAssetIDs), photosB = Set(b.photoAssetIDs)
        let overlap = Double(photosA.intersection(photosB).count) / Double(max(1, photosA.union(photosB).count))
        if !context.exactSet && overlap > 0.7 && context.photos.count > photosA.union(photosB).count { return false }
        guard !context.vocabulary.isEmpty else { return true }
        let familiesA = templateFamilies(a, context: context).subtracting(["layouts"])
        let familiesB = templateFamilies(b, context: context).subtracting(["layouts"])
        // If only one option can use an imported family, it is already a visible layout
        // difference. When both use templates, their family sets must differ.
        return familiesA.isEmpty || familiesB.isEmpty || familiesA != familiesB
    }

    private static func templateFamilies(_ plan: CarouselPlan, context: CompositionContext) -> Set<String> {
        let layout = LayoutResolver.resolve(plan, context: LayoutContext(
            aspect: context.aspect, photos: context.photos, features: context.features,
            stylePack: context.stylePack, seed: layoutSeed(runID: plan.id, id: plan.id),
            storyHint: context.storyHint, vocabulary: plan.isBaseline ? [] : context.vocabulary))
        return Set(layout.slides.compactMap { slide in
            guard let variant = slide.variant, variant.hasPrefix("template.") else { return nil }
            let id = String(variant.dropFirst("template.".count))
            return context.vocabulary.first(where: { $0.id == id })?.familyID ?? id
        })
    }

    private static func remedyDirections(_ direction: Direction, against clash: CarouselPlan,
                                         others: [CarouselPlan], context: CompositionContext) -> [Direction] {
        let usedCovers = Set(others.compactMap(\.coverAssetID))
        let orderedPool = context.photos.keys.sorted { strengthOrder($1, $0, context) }
        let current = direction.orderedAssetIDs
        let unusedPool = orderedPool.filter { !current.contains($0) && !context.flagged.contains($0) }
        var tries: [Direction] = []

        if let alt = current.filter({ !usedCovers.contains($0) && !context.flagged.contains($0) })
            .max(by: { strengthOrder($0, $1, context) }) {
            var moved = direction
            moved.coverAssetID = alt
            if !context.keepOrder, let index = moved.orderedAssetIDs.firstIndex(of: alt) {
                moved.orderedAssetIDs.remove(at: index)
                moved.orderedAssetIDs.insert(alt, at: 0)
            }
            tries.append(moved)
        } else if !context.keepOrder, let alt = unusedPool.first {
            var moved = direction
            moved.coverAssetID = alt
            moved.orderedAssetIDs.insert(alt, at: 0)
            tries.append(moved)
        }

        guard !context.keepOrder else { return tries }
        if current.count > 1 {
            for offset in 1..<current.count {
                var rotated = direction
                rotated.orderedAssetIDs = Array(current[offset...]) + Array(current[..<offset])
                rotated.coverAssetID = rotated.orderedAssetIDs[0]
                tries.append(rotated)
            }
        }

        guard !context.exactSet else { return tries }
        let replacements = unusedPool.filter { candidate in
            current.first.map { sameEvent($0, candidate, context: context) } ?? true
        }
        let maxSwaps = Int(Double(current.count) * 0.30)
        let swapCount = min(maxSwaps, replacements.count)
        guard swapCount > 0 else { return tries }
        for count in 1...swapCount {
            var swapped = direction
            let positions = Array(swapped.orderedAssetIDs.indices.dropFirst().prefix(count))
            for (position, replacement) in zip(positions, replacements.prefix(count)) {
                swapped.orderedAssetIDs[position] = replacement
            }
            if !swapped.orderedAssetIDs.contains(swapped.coverAssetID) {
                swapped.coverAssetID = swapped.orderedAssetIDs[0]
            }
            tries.append(swapped)
        }
        return tries
    }

    private static func sameEvent(_ a: AssetID, _ b: AssetID, context: CompositionContext) -> Bool {
        if let first = context.photos[a]?.metadata.capturedAt,
           let second = context.photos[b]?.metadata.capturedAt {
            return abs(first.timeIntervalSince(second)) <= 24 * 60 * 60
        }
        let generic: Set<String> = ["outdoor", "indoor", "person", "people", "human", "adult", "child",
                                    "nature", "landscape", "sky", "land", "ground", "grass", "tree", "vegetation"]
        let left = Set((context.features[a]?.labels ?? []).filter { $0.confidence >= 0.3 }.map { $0.identifier.lowercased() })
        let right = Set((context.features[b]?.labels ?? []).filter { $0.confidence >= 0.3 }.map { $0.identifier.lowercased() })
        return !left.intersection(right).subtracting(generic).isEmpty || (left.isEmpty && right.isEmpty)
    }

    /// Rebuilds stored plans from their own direction and composition seed: same ids, no diversity remedies, so a
    /// plan composed by this engine version comes back identical. Legacy plans (no direction or seed) are returned as-is.
    public static func recompose(_ plans: [CarouselPlan], context: CompositionContext, runID: String) -> [CarouselPlan] {
        plans.map { p in
            guard let d = p.direction, let hex = p.compositionSeed, let seed = UInt64(hex, radix: 16) else { return p }
            return compose(d, id: p.id, context: context, seed: seed, layoutSeed: layoutSeed(runID: runID, id: p.id)).plan
        }
    }

    // MARK: - One direction

    /// Clean-output policy (owner feedback 2026-09-27: blurred backdrops, mats and forced pairs are not aesthetic).
    /// Until designed pages replace procedural layouts, every direction is one photo per slide, edge to edge where
    /// people fit, finished only with subtle grain or a date stamp. Directions still differ in selection, order,
    /// cover and rhythm.
    public static let cleanOutput = true

    static func cleaned(_ style: StyleVector, vocabulary: [DesignedSet] = []) -> StyleVector {
        guard cleanOutput else { return style }
        var s = style
        let supportsGroups = vocabulary.contains {
            $0.slideCount == 1 && $0.expandedSlots.count > 1 && !$0.expandedSlots.contains(where: \.crossesSeam)
        }
        if !supportsGroups { s.grouping = "single" }
        s.overlap = "none"; s.rotation = "none"; s.whitespace = "tight"
        if s.decoration == "rich" { s.decoration = "light" }
        return s
    }

    public static func compose(_ direction: Direction, id: String, context: CompositionContext, seed: UInt64,
                               layoutSeed: UInt64? = nil) -> Composition {
        var generated = generate(direction, id: id, context: context, seed: seed, layoutSeed: layoutSeed)
        guard !generated.ranked.isEmpty else { return generated.empty }
        let near = generated.ranked.filter { $0.score <= generated.ranked[0].score + 0.04 }
        let pick = near[Int(generated.rng.next() % UInt64(near.count))]
        return composition(pick, direction: generated.direction, id: id, seed: seed, layoutSeed: layoutSeed ?? seed,
                           warnings: generated.warnings, context: context)
    }

    /// Returns distinct, safe whole-carousel candidates ranked by composer score.
    public static func candidates(_ direction: Direction, id: String, context: CompositionContext, seed: UInt64,
                                  layoutSeed: UInt64? = nil, limit: Int = 6) -> [Composition] {
        guard limit > 0 else { return [] }
        let generated = generate(direction, id: id, context: context, seed: seed, layoutSeed: layoutSeed)
        return generated.ranked.reduce(into: [Composition]()) { result, candidate in
            guard result.count < limit, !result.contains(where: { $0.plan.slides == candidate.plan.slides }) else { return }
            let layout = LayoutResolver.resolve(candidate.plan, context: LayoutContext(aspect: context.aspect, photos: context.photos,
                features: context.features, stylePack: context.stylePack, seed: layoutSeed ?? seed,
                storyHint: context.storyHint,
                vocabulary: candidate.plan.isBaseline ? [] : context.vocabulary))
            guard !layout.slides.contains(where: { slide in
                slide.warnings.contains { $0.contains("people are cropped") || $0.contains("could not fully satisfy") }
            }) else { return }
            result.append(composition(candidate, direction: generated.direction, id: id, seed: seed,
                                      layoutSeed: layoutSeed ?? seed, warnings: generated.warnings, context: context))
        }
    }

    private static func composition(_ candidate: (plan: CarouselPlan, score: Double), direction: Direction, id: String,
                                    seed: UInt64, layoutSeed: UInt64, warnings: [String], context: CompositionContext) -> Composition {
        var plan = candidate.plan
        plan.compositionSeed = String(seed, radix: 16)
        // Recipe selection (spec §3/§4) happens for every composed plan, so any path that produces one —
        // composeSet, recompose, a diversity-remedy retry, or a raw `compose` call — assigns it the same way.
        let selectedTemplate = !plan.isBaseline && !context.vocabulary.isEmpty
            && LayoutResolver.resolve(plan, context: LayoutContext(aspect: context.aspect, photos: context.photos,
                features: context.features, stylePack: context.stylePack, seed: layoutSeed,
                storyHint: context.storyHint,
                vocabulary: context.vocabulary)).slides.contains { $0.variant?.hasPrefix("template.") == true }
        if !selectedTemplate, let recipes = context.stylePack.recipes,
           let recipe = RecipeFiller.select(for: direction.style, recipes: recipes, seed: seed) {
            plan.recipeID = recipe.id
        }
        return Composition(plan: plan, score: candidate.score, warnings: warnings)
    }

    private static func generate(_ direction: Direction, id: String, context: CompositionContext, seed: UInt64,
                                 layoutSeed: UInt64?) -> (ranked: [(plan: CarouselPlan, score: Double)], direction: Direction,
                                                          warnings: [String], rng: SeededRandom, empty: Composition) {
        var rng = SeededRandom(seed: seed)
        var warnings: [String] = []
        var d = direction
        d.style = cleaned(d.style.normalized, vocabulary: context.vocabulary)
        var seen = Set<AssetID>()
        var ids = d.orderedAssetIDs.filter { context.photos[$0] != nil && seen.insert($0).inserted }
        guard !ids.isEmpty else {
            let empty = Composition(plan: CarouselPlan(id: id, brief: d.brief, direction: d, slides: []), score: .infinity,
                                    warnings: ["no usable photos"])
            return ([], d, warnings, rng, empty)
        }
        if context.keepOrder { d.coverAssetID = ids[0] }
        if !ids.contains(d.coverAssetID) || (!context.keepOrder && context.flagged.contains(d.coverAssetID) && ids.contains { !context.flagged.contains($0) }) {
            let replacement = ids.filter { !context.flagged.contains($0) }.max { strengthOrder($0, $1, context) } ?? ids[0]
            warnings.append("cover \(d.coverAssetID) replaced by \(replacement) (missing or flagged)")
            d.coverAssetID = replacement
        }
        if !context.keepOrder {
            ids.removeAll { $0 == d.coverAssetID }
            ids.insert(d.coverAssetID, at: 0)
        }
        d.orderedAssetIDs = ids

        var candidates: [(plan: CarouselPlan, score: Double)] = []
        for k in 0..<candidateCount {
            let (groups, dropped) = group(ids, direction: d, context: context, noise: k == 0 ? 0 : 0.15, rng: &rng)
            if k == 0 && !dropped.isEmpty { warnings.append("\(dropped.count) photos left out to fit \(context.maxSlides ?? 20) slides") }
            if k == 0 && context.exactSet && context.maxSlides.map({ ids.count > $0 }) == true {
                warnings.append("grouped exact photos to honor the requested slide limit")
            }
            var plan = build(groups, id: id, direction: d, context: context, rng: &rng)
            if cleanOutput { plan = splitUnhostedGroups(plan, direction: d, context: context, seed: layoutSeed ?? seed, rng: &rng) }
            candidates.append((plan, evaluate(plan, context: context, seed: layoutSeed ?? seed)))
        }
        let ranked = candidates.enumerated().sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
        return (ranked.map { $0.element }, d, warnings, rng,
                Composition(plan: ranked[0].element.plan, score: ranked[0].element.score, warnings: warnings))
    }

    /// Under the clean policy photos share a slide only on an imported page. A group no page can hold is split
    /// back into single-photo slides instead of falling back to an inset or collage. Exact sets over their slide
    /// limit keep their groups: every photo must still be placed.
    static func splitUnhostedGroups(_ plan: CarouselPlan, direction d: Direction, context: CompositionContext,
                                    seed: UInt64, rng: inout SeededRandom) -> CarouselPlan {
        // Rebuilding re-decorates and shifts template windows, so repeat until every remaining group is hosted.
        // Each pass adds slides, so this ends.
        var plan = plan
        while plan.slides.contains(where: { $0.photos.count > 1 }) {
            let hosted = LayoutResolver.templateHosted(plan, context: LayoutContext(aspect: context.aspect, photos: context.photos,
                features: context.features, stylePack: context.stylePack, seed: seed, storyHint: context.storyHint,
                vocabulary: context.vocabulary))
            var groups: [[AssetID]] = [], split = false
            for (index, slide) in plan.slides.enumerated() {
                let ids = slide.photos.map(\.assetID)
                if ids.count > 1 && !hosted[index] { groups += ids.map { [$0] }; split = true } else { groups.append(ids) }
            }
            guard split, groups.count <= max(1, min(context.maxSlides ?? 20, 20)) else { return plan }
            plan = build(groups, id: plan.id, direction: d, context: context, rng: &rng)
        }
        return plan
    }

    // MARK: - Grouping

    /// Partitions the ordered photos into contiguous slides by dynamic programming. Every rule is a soft cost:
    /// the grouping axis, keep-together sets, emphasis photos alone, the cover alone, and above all how well the
    /// photos look together (colour, light, subject, shape). Returns the groups and any photos dropped to respect
    /// the requested slide count (the only limit that is never exceeded).
    static func group(_ ids: [AssetID], direction d: Direction, context: CompositionContext, noise: Double,
                      rng: inout SeededRandom) -> ([[AssetID]], [AssetID]) {
        let style = d.style
        let maxSlides = max(1, min(context.maxSlides ?? 20, 20))
        // Exact sets must retain every photo and honor the requested slide limit. Let
        // those slides grow enough to hold the full set when the normal four-photo
        // cap would make the limit impossible.
        let stackPolicy = cleanOutput && !context.vocabulary.isEmpty
        let landscapeStackCapacities = stackPolicy ? landscapeStackCapacities(context) : []
        let maxLandscapeStack = landscapeStackCapacities.max() ?? 1
        let desiredGroupSize = style.grouping == "single" ? 1 : style.grouping == "mixed" ? 3 : 4
        let designedGroupSize = context.vocabulary.filter {
            $0.aspect == context.aspect && $0.slideCount == 1 && !$0.expandedSlots.contains(where: \.crossesSeam)
        }.map { $0.expandedSlots.count }.max() ?? 1
        var cap = context.exactSet ? max(4, (ids.count + maxSlides - 1) / maxSlides)
            : min(desiredGroupSize, designedGroupSize)
        if stackPolicy && style.grouping == "single" && !landscapeStackCapacities.isEmpty {
            cap = max(cap, maxLandscapeStack)
        }
        let maxSize = cap
        var keepIndex: [AssetID: Int] = [:]
        for (g, members) in d.keepTogether.enumerated() { for m in members { keepIndex[m] = g } }
        let emphasis = Set(d.emphasisAssetIDs)

        func cost(_ seg: ArraySlice<AssetID>, first: Bool) -> Double {
            let m = seg.count
            var split = 0.0
            for g in Set(seg.compactMap { keepIndex[$0] }) {
                if !d.keepTogether[g].allSatisfy(seg.contains) { split += 0.4 }
            }
            if m == 1 {
                var base = style.grouping == "single" ? 0 : style.grouping == "mixed" ? 0.35 : 0.55
                if stackPolicy, floats(seg.first!, context: context) { base += first ? 0.3 : 0.6 }
                return (first || emphasis.contains(seg.first!) ? 0 : base) + split
            }
            if stackPolicy && !context.exactSet && style.grouping == "single" && !seg.allSatisfy({ aspect($0, context) > 1.15 }) {
                return .infinity
            }
            let oneKeepGroup = seg.allSatisfy { keepIndex[$0] != nil && keepIndex[$0] == keepIndex[seg.first!] }
            // Colour can make two unrelated photos look compatible, but it cannot explain why
            // they share a slide. Require scene evidence or a close, people-bearing moment.
            if !context.exactSet && !oneKeepGroup && !pairHasStoryLink(members: Array(seg), context: context) { return 2.5 + split }
            var c = style.grouping == "mixed" ? (m == 2 ? 0.1 : 0.55) : (m == 2 ? 0.2 : m == 3 ? 0.05 : 0.2)
            if first && !oneKeepGroup { c += 0.8 }                               // a cover usually reads best alone
            if !oneKeepGroup { c += 0.6 * Double(seg.filter(emphasis.contains).count) }
            // How well the photos sit together: mean pairwise disharmony, 0 (they rhyme) ... ~1 (they clash).
            let members = Array(seg)
            var clash = 0.0, pairs = 0.0
            for i in members.indices { for j in members.indices where j > i {
                clash += disharmony(members[i], members[j], context); pairs += 1
            }}
            c += 1.6 * clash / pairs
            if Set(seg.compactMap { keepIndex[$0] }).count > 1 { c += 0.5 }
            if oneKeepGroup { c -= 0.3 }
            if stackPolicy && m >= 2 {
                let members = Array(seg)
                if members.allSatisfy({ aspect($0, context) > 1.15 }), landscapeStackCapacities.contains(m) { c -= 0.5 }
            }
            return c + split
        }

        var photos = ids, dropped: [AssetID] = []
        while true {
            let n = photos.count
            var jitter: [[Double]] = (0..<n).map { _ in (0...maxSize).map { _ in 0 } }
            if noise > 0 { for i in 0..<n { for m in 1...maxSize { jitter[i][m] = rng.range(-noise, noise) } } }
            // best[s][j]: cheapest way to lay out the first j photos on s slides.
            var best = Array(repeating: Array(repeating: Double.infinity, count: n + 1), count: maxSlides + 1)
            var back = Array(repeating: Array(repeating: 0, count: n + 1), count: maxSlides + 1)
            best[0][0] = 0
            for s in 1...maxSlides { for j in 1...n {
                for m in 1...min(maxSize, j) where best[s - 1][j - m] < .infinity {
                    let c = best[s - 1][j - m] + cost(photos[(j - m)..<j], first: j - m == 0) + jitter[j - m][m]
                    if c < best[s][j] { best[s][j] = c; back[s][j] = m }
                }
            }}
            if let s = (1...maxSlides).filter({ best[$0][n] < .infinity }).min(by: { (best[$0][n], $0) < (best[$1][n], $1) }) {
                var groups: [[AssetID]] = [], j = n, k = s
                while k > 0 { let m = back[k][j]; groups.insert(Array(photos[(j - m)..<j]), at: 0); j -= m; k -= 1 }
                return (groups, dropped)
            }
            // Too many photos for the slide limit: drop the weakest non-cover photo and try again.
            guard !context.exactSet, photos.count > 1, let weakest = photos.dropFirst().min(by: { strengthOrder($0, $1, context) }) else {
                return (photos.map { [$0] }, dropped)
            }
            photos.removeAll { $0 == weakest }
            dropped.append(weakest)
        }
    }

    // MARK: - Slides

    static func build(_ groups: [[AssetID]], id: String, direction d: Direction, context: CompositionContext,
                      rng: inout SeededRandom) -> CarouselPlan {
        let style = d.style, n = groups.count
        let rhythmOffset = Int(rng.next() % 3)
        var slides: [SlidePlan] = []
        for (k, g) in groups.enumerated() {
            let hero = k == 0 ? d.coverAssetID : g.max { strengthOrder($0, $1, context) }!
            let unsortedOthers = g.filter { $0 != hero }
            let others = context.keepOrder ? unsortedOthers : unsortedOthers.sorted { strengthOrder($1, $0, context) }
            let position: SequenceIntent = k == 0 ? .opener : k == n - 1 ? .closer : context.sequenceIntent[hero] ?? .build
            let density: String = switch style.density {
            case "varied":
                position == .peak ? "dense" : position == .breather || position == .detail ? "quiet"
                    : position == .opener ? "balanced" : ["balanced", "dense", "quiet"][(k + rhythmOffset) % 3]
            default: style.density
            }
            let primitive = choosePrimitive(hero: hero, others: others, style: style, position: position, density: density,
                                            context: context, rng: &rng)
            let overlapIntent = style.overlap == "bold" ? "strong" : style.overlap == "some" ? "slight" : "none"
            func element(_ a: AssetID, hero isHero: Bool) -> PhotoElement {
                let rotates = style.rotation == "some" && primitive != .fullBleed && (!isHero || g.count == 1 || primitive == .overlapCluster)
                return PhotoElement(assetID: a, role: isHero ? "hero" : "support", importance: isHero ? 3 : 2,
                                    cropIntent: "balanced", anchorIntent: "center", overlapIntent: isHero ? "none" : overlapIntent,
                                    rotationIntent: rotates ? (rng.bool() ? "slightLeft" : "slightRight") : "none")
            }
            slides.append(SlidePlan(primitive: primitive, mood: mood(position), density: density,
                                    photos: context.keepOrder ? g.map { element($0, hero: $0 == hero) } : [element(hero, hero: true)] + others.map { element($0, hero: false) },
                                    decorations: [], stamps: []))
        }
        decorate(&slides, style: style, context: context, rng: &rng)
        return CarouselPlan(id: id, brief: d.brief, direction: d, slides: slides)
    }

    static func choosePrimitive(hero: AssetID, others: [AssetID], style: StyleVector, position: SequenceIntent, density: String,
                                context: CompositionContext, rng: inout SeededRandom) -> Primitive {
        let canvas = Double(context.aspect.exportWidth) / Double(context.aspect.exportHeight)
        let a = aspect(hero, context)
        let bleedLoss = 1 - min(a / canvas, canvas / a)
        var costs: [(Primitive, Double)]
        switch others.count {
        case 0:
            let f = context.features[hero]
            let fits = CropPlanner.fullBleedEligible(imageAspect: a, boxAspect: canvas, features: f)
            let airy = style.whitespace == "airy"
            if cleanOutput { return fits ? .fullBleed : .hero }
            costs = [
                // Dense slides fill the frame even in an airy carousel: that contrast is the rhythm.
                (.fullBleed, 1.2 * bleedLoss + (fits ? 0 : 5) + (airy && density != "dense" ? 0.5 : 0)
                    + (density == "quiet" ? 0.3 : 0) - (density == "dense" ? 0.3 : 0)
                    - (position == .opener || position == .peak ? 0.15 : 0)),
                (.hero, 0.45 + (airy ? -0.1 : 0.2) + (density == "dense" ? 0.15 : 0)),
            ]
            // A border and shadow are decoration: never on a carousel that asked for none.
            if style.decoration != "none" && !cleanOutput {
                costs.append((.framedHero, 0.55 + (airy ? -0.1 : 0.2) + (density == "quiet" ? -0.1 : 0)))
            }
        case 1:
            costs = [(.asymmetricPair, 0.2 + (style.overlap == "bold" ? 0.15 : 0))]
            if style.overlap != "none" {
                costs.append((.inset, 0.35 + 0.6 * bleedLoss - (style.overlap == "bold" ? 0.15 : 0) - (density == "dense" ? 0.1 : 0)))
                costs.append((.overlapCluster, style.overlap == "bold" ? 0.4 : 0.65))
            }
        default:
            return .overlapCluster
        }
        return costs.map { ($0.0, $0.1 + rng.range(0, 0.06)) }.min { $0.1 < $1.1 }!.0
    }

    /// Spends the direction's decoration budget on the slides where it fits: none = nothing, light ≤ 20% of slides,
    /// rich ≤ 50%. Date stamps only on dated photos; paper never on a full-bleed slide.
    static func decorate(_ slides: inout [SlidePlan], style: StyleVector, context: CompositionContext, rng: inout SeededRandom) {
        guard style.decoration != "none", !slides.isEmpty else { return }
        let pack = Set(context.stylePack.decorationIDs)
        let rich = style.decoration == "rich"
        // Never above the cap: a short carousel may get no decoration at all.
        let budget = Int((Double(slides.count) * (rich ? 0.5 : 0.2)).rounded(.down))
        guard budget > 0 else { return }
        let intensity = rich ? "medium" : "low"
        // Framed slides first (decoration reads best there), then the rest; seeded order within each.
        var order = slides.indices.map { ($0, slides[$0].primitive == .fullBleed ? 1 : 0, rng.unit()) }
        order.sort { ($0.1, $0.2) < ($1.1, $1.2) }
        var stamped = 0
        for (i, _, _) in order.prefix(budget) {
            let s = slides[i]
            if cleanOutput && !context.vocabulary.isEmpty && s.photos.count > 1 { continue }
            let designed: [String] = switch s.primitive {
            case .hero, .framedHero: ["film-edge", "paper-warm", "date-stamp"]
            case .overlapCluster: ["tape-clear", "paper-warm"]
            case .asymmetricPair: ["paper-warm", "grain-fine"]
            case .inset: ["grain-fine"]                        // an inset's main photo may cover the whole background
            case .fullBleed: ["grain-fine", "date-stamp"]
            }
            let options = cleanOutput ? ["grain-fine", "date-stamp"] : designed
            let dated = s.photos.first.flatMap { context.photos[$0.assetID]?.metadata.capturedAt } != nil
            let usable = options.filter { pack.contains($0) && ($0 != "date-stamp" || (dated && stamped < (rich ? 2 : 1))) }
            guard !usable.isEmpty else { continue }
            let choice = usable[Int(rng.next() % UInt64(usable.count))]
            if choice == "date-stamp" {
                slides[i].stamps.append(StampElement(kind: "date", placement: "bottomRight")); stamped += 1
            } else {
                slides[i].decorations.append(DecorationElement(decorationID: choice, intensity: intensity))
            }
        }
    }

    // MARK: - Scoring

    /// Resolves the plan through the layout engine and scores the whole carousel: crop loss, people and overlap
    /// safety, hierarchy, arrangement rhythm, density fit and cover presence. Lower is better.
    static func evaluate(_ plan: CarouselPlan, context: CompositionContext, seed: UInt64) -> Double {
        guard !plan.slides.isEmpty else { return .infinity }
        let layout = LayoutResolver.resolve(plan, context: LayoutContext(aspect: context.aspect, photos: context.photos,
                                                                          features: context.features, stylePack: context.stylePack,
                                                                          seed: seed, storyHint: context.storyHint,
                                                                          vocabulary: plan.isBaseline ? [] : context.vocabulary))
        let n = Double(layout.slides.count)
        var perSlide = 0.0, coverageGap = 0.0, framed = 0.0
        for (slide, planned) in zip(layout.slides, plan.slides) {
            guard let m = slide.metrics else { perSlide += 2; continue }
            perSlide += 0.8 * m.maxCropLoss
            if slide.warnings.contains(where: { $0.contains("people are cropped") }) { perSlide += 1 }
            if slide.warnings.contains(where: { $0.contains("could not fully") }) { perSlide += 1 }
            if let share = m.heroShare, share < 1.3 { perSlide += 1.3 - share }
            if slide.primitive != .fullBleed {
                coverageGap += abs(m.coverage - LayoutResolver.densityTarget(planned.density)); framed += 1
            }
        }
        let families = layout.slides.compactMap { $0.variant?.split(separator: ".").prefix(2).joined(separator: ".") }
        let repeats = zip(families, families.dropFirst()).filter { $0 == $1 && $0 != "bleed" }.count
        var score = perSlide / n + 0.8 * (framed > 0 ? coverageGap / framed : 0) + 0.25 * Double(repeats) / max(1, n - 1)
        if let cover = layout.slides.first?.metrics, cover.coverage < 0.45 { score += 0.3 }
        // Honour the grouping axis: the share of multi-photo slides the direction asked for.
        if let grouping = plan.style?.grouping, plan.slides.count > 1 {
            let target = grouping == "collage" ? 0.6 : grouping == "mixed" ? 0.35 : 0
            let multiSlides = plan.slides.filter { slide in
                guard slide.photos.count > 1 else { return false }
                if cleanOutput, !context.vocabulary.isEmpty, grouping == "single" {
                    return !slide.photos.map(\.assetID).allSatisfy { aspect($0, context) > 1.15 }
                }
                return true
            }
            let multi = Double(multiSlides.count) / n
            score += 1.0 * abs(multi - target)
        }
        return score
    }

    // MARK: - Helpers

    static func aspect(_ id: AssetID, _ context: CompositionContext) -> Double {
        guard let p = context.photos[id] else { return 1 }
        return Double(p.pixelWidth) / Double(max(1, p.pixelHeight))
    }

    /// True when full-bleed on this canvas would crop away more than 30% of the photo (same rule as `choosePrimitive`).
    static func floats(_ id: AssetID, context: CompositionContext) -> Bool {
        let canvas = Double(context.aspect.exportWidth) / Double(context.aspect.exportHeight)
        return !CropPlanner.fullBleedEligible(imageAspect: aspect(id, context), boxAspect: canvas,
                                               features: context.features[id])
    }

    /// Photo counts `n` for which the vocabulary has a single-slide, all-landscape, seam-safe page on this aspect.
    static func landscapeStackCapacities(_ context: CompositionContext) -> Set<Int> {
        Set(context.vocabulary.compactMap { set -> Int? in
            guard set.aspect == context.aspect, set.slideCount == 1 else { return nil }
            let slots = set.expandedSlots
            guard !slots.isEmpty, !slots.contains(where: \.crossesSeam) else { return nil }
            guard slots.allSatisfy({ $0.aspect > 1.15 }) else { return nil }
            return slots.count
        })
    }

    /// Photo strength: the model's emotional read first, then local aesthetics, then a stable id order.
    static func strengthOrder(_ a: AssetID, _ b: AssetID, _ context: CompositionContext) -> Bool {
        func key(_ id: AssetID) -> (Int, Double, String) {
            (context.triage[id]?.emotionalValue ?? 0, context.features[id]?.aestheticScore ?? 0, id.rawValue)
        }
        return key(a) < key(b)
    }

    /// How badly two photos sit side by side, 0 (they rhyme) to about 1 (they clash): colour and warmth, light and
    /// contrast, saturation, subject (people vs scenery, shared scene labels) and shape. Photos without a colour
    /// profile (older analysis) are judged on subject and shape only.
    static func disharmony(_ x: AssetID, _ y: AssetID, _ context: CompositionContext) -> Double {
        let fx = context.features[x], fy = context.features[y]
        var total = 0.0, weight = 0.0
        func add(_ value: Double, _ w: Double) { total += min(1, max(0, value)) * w; weight += w }
        if let a = fx?.color, let b = fy?.color {
            let deltaE = ((a.l - b.l) * (a.l - b.l) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
            add(deltaE / 45, 1.2)                                   // overall colour cast
            add(abs(a.warmth - b.warmth) / 0.3, 0.8)                // warm next to cool
            add(abs(a.saturation - b.saturation) / 0.4, 0.6)        // muted next to vivid
            add(abs(a.contrast - b.contrast) / 0.15, 0.4)           // flat next to punchy
        }
        if let lx = fx?.meanLuminance, let ly = fy?.meanLuminance { add(abs(lx - ly) / 0.3, 1.2) }   // night next to day
        let peopleX = !(fx?.faces.isEmpty ?? true), peopleY = !(fy?.faces.isEmpty ?? true)
        add(peopleX == peopleY ? 0 : 0.6, 0.5)
        let labelsX = Set(fx?.labels.prefix(5).map(\.identifier) ?? []), labelsY = Set(fy?.labels.prefix(5).map(\.identifier) ?? [])
        if !labelsX.isEmpty && !labelsY.isEmpty {
            add(1 - Double(labelsX.intersection(labelsY).count) / Double(labelsX.union(labelsY).count), 0.5)
        }
        // Mixed orientations interlock well on a tall slide; identical extreme shapes less so.
        let ax = aspect(x, context), ay = aspect(y, context)
        add((ax > 1) == (ay > 1) && min(ax, 1 / ax) < 0.7 ? 0.3 : 0, 0.3)
        return weight > 0 ? total / weight : 0.5
    }

    /// True when analysis can explain a pairing without relying on colour alone.
    /// Shared labels must be reasonably specific; generic labels such as "outdoor" are ignored.
    static func pairHasStoryLink(members: [AssetID], context: CompositionContext) -> Bool {
        guard members.count >= 2 else { return true }
        for i in members.indices { for j in members.indices where j > i {
            let x = members[i], y = members[j]
            let rawX = Set((context.features[x]?.labels ?? []).filter { $0.confidence >= 0.3 }.map { $0.identifier.lowercased() })
            let rawY = Set((context.features[y]?.labels ?? []).filter { $0.confidence >= 0.3 }.map { $0.identifier.lowercased() })
            let shared = rawX.intersection(rawY)
            let generic: Set<String> = ["outdoor", "indoor", "person", "people", "human", "adult", "child",
                                        "nature", "landscape", "sky", "land", "ground", "grass", "tree", "vegetation"]
            if !shared.subtracting(generic).isEmpty { continue }
            let hasCredibleFace: (AssetID) -> Bool = { id in
                (context.features[id]?.faces ?? []).contains { face in
                    face.box.width >= 0.025 && face.box.height >= 0.025
                        && (face.captureQuality == nil || face.captureQuality! >= 0.2)
                }
            }
            if let a = context.photos[x]?.metadata.capturedAt, let b = context.photos[y]?.metadata.capturedAt,
               abs(a.timeIntervalSince(b)) <= 60 * 60, hasCredibleFace(x), hasCredibleFace(y) {
                // Nearby people-bearing frames plausibly show the same group or moment.
                continue
            }
            return false
        }}
        return true
    }

    static func mood(_ p: SequenceIntent) -> String {
        switch p {
        case .opener: "warm"
        case .peak: "energetic"
        case .breather, .detail: "calm"
        case .closer: "nostalgic"
        case .build: "playful"
        }
    }
}

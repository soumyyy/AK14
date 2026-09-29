import Foundation

/// Chooses photos and authored pages together within one family.
public enum PageSearch {
    public struct Result: Sendable {
        public var plan: CarouselPlan
        public var score: Double
        public var family: String
        public var whiteCards: Int
        public var warnings: [String]
    }

    private struct Step: Sendable {
        var pageID: String?
        var photos: [AssetID]
        var placed: [SlotAssignment.Placed]
        var geometry: String
        var role: String
    }

    private struct State: Sendable {
        var moment = 0
        var used: Set<AssetID> = []
        var steps: [Step] = []
        var cover: AssetID?
        var score = 0.0
        var whiteCards = 0
        var key: String {
            "\(moment)|" + steps.map {
                ($0.pageID ?? "white") + ":" + $0.photos.map(\.rawValue).joined(separator: ",")
            }.joined(separator: "|")
        }
    }

    /// Legacy groups retain input order, even if keepTogether lists its members out of order.
    public static func legacyMoments(_ direction: Direction) -> [Direction.Moment] {
        var grouped: Set<AssetID> = []
        var moments: [Direction.Moment] = []
        for id in direction.orderedAssetIDs where !grouped.contains(id) {
            let group = direction.keepTogether.first { $0.contains(id) }
            let photos = group.map { group in
                direction.orderedAssetIDs.filter { group.contains($0) && !grouped.contains($0) }
            } ?? [id]
            grouped.formUnion(photos)
            moments.append(.init(label: "", photos: photos, mustInclude: photos,
                                 size: photos.count == 1 ? "1" : photos.count <= 3 ? "few" : "many"))
        }
        return moments
    }

    public static func candidateFamilies(_ pages: [DesignedSet], photos: [AssetID], context: CompositionContext,
                                         limit: Int = 4) -> [String] {
        let shapes = Set(photos.compactMap { context.photos[$0].map {
            ShapeClass.of(aspect: Double($0.pixelWidth) / Double(max($0.pixelHeight, 1)))
        } })
        let families = Dictionary(grouping: pages.filter { $0.aspect == context.aspect }, by: \.familyID)
        let ranked: [(family: String, count: Int)] = families.map { family, pages in
            let count = pages.filter { page in
                let slots = page.expandedSlots
                return !slots.isEmpty && slots.allSatisfy { shapes.contains(ShapeClass.of(aspect: $0.aspect)) }
            }.count
            return (family, count)
        }
        let fitting = ranked.filter { $0.family != "layouts" && $0.count > 0 }
        let sorted = fitting.sorted { $0.count != $1.count ? $0.count > $1.count : $0.family < $1.family }
        return sorted.prefix(max(0, min(limit, 4))).map(\.family)
    }

    public static func search(_ direction: Direction, id: String, family: String, pages all: [DesignedSet],
                              context: CompositionContext, seed: UInt64, excludedCovers: Set<AssetID> = []) -> Result? {
        var moments = direction.moments.isEmpty ? legacyMoments(direction) : direction.moments
        if context.keepOrder, direction.moments.isEmpty,
           moments.flatMap(\.photos) != direction.orderedAssetIDs {
            // Non-contiguous legacy groups cannot override the owner's input order.
            moments = direction.orderedAssetIDs.map {
                .init(label: "", photos: [$0], mustInclude: [$0], size: "1")
            }
        }
        let photos = moments.flatMap(\.photos)
        guard let firstPhoto = photos.first else { return nil }
        let pages = all.filter {
            $0.aspect == context.aspect && ($0.familyID == family || $0.familyID == "layouts")
                && !$0.expandedSlots.isEmpty && $0.slideCount > 0
        }.sorted { $0.id < $1.id }
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = byID.mapValues(\.expandedSlots)
        let geometry = byID.mapValues(geometrySignature)
        let mandatory = Set(context.exactSet || context.keepOrder ? photos : moments.flatMap(\.mustInclude))
        let rank = Dictionary(moments.flatMap { moment in
            moment.photos.enumerated().map { ($0.element, 1 - Double($0.offset) / Double(max(moment.photos.count, 1))) }
        }, uniquingKeysWith: max)
        let shapes = context.photos.mapValues {
            ShapeClass.of(aspect: Double($0.pixelWidth) / Double(max($0.pixelHeight, 1)))
        }
        let layout = LayoutContext(aspect: context.aspect, photos: context.photos, features: context.features,
                                   stylePack: context.stylePack, seed: seed, storyHint: context.storyHint,
                                   pages: pages, keepOrder: context.keepOrder)
        let emptyPlan = CarouselPlan(id: id, brief: direction.brief, direction: direction,
                                     compositionSeed: String(seed, radix: 16), slides: [])
        var cache: [String: SlotAssignment.Result] = [:]
        var failedAssignments: Set<String> = []
        var titleCache: [String: Bool] = [:]

        func assignmentKey(_ ids: [AssetID], _ page: DesignedSet, hero: AssetID?) -> String {
            page.id + "|" + ids.map(\.rawValue).joined(separator: ",") + "|" + (hero?.rawValue ?? "") + "|\(context.keepOrder)"
        }
        func assign(_ ids: [AssetID], _ page: DesignedSet, hero: AssetID?) -> SlotAssignment.Result? {
            let key = assignmentKey(ids, page, hero: hero)
            if let hit = cache[key] { return hit }
            if failedAssignments.contains(key) { return nil }
            guard let result = SlotAssignment.assign(ids, to: page, hero: hero, keepOrder: context.keepOrder,
                                                     records: context.photos, features: context.features) else {
                failedAssignments.insert(key)
                return nil
            }
            cache[key] = result
            return result
        }
        func titleRenders(_ ids: [AssetID], _ page: DesignedSet, fit: SlotAssignment.Result, hero: AssetID?) -> Bool {
            let key = assignmentKey(ids, page, hero: hero)
            if let hit = titleCache[key] { return hit }
            var titlePlaced = false, captions = 0
            var rendered = TemplateVocabulary.render(page: page, placed: fit.placed, plan: emptyPlan, start: 0,
                                                      context: layout, titlePlaced: &titlePlaced, captionCount: &captions)
            TemplateVocabulary.addCoverTitleIfNeeded(to: &rendered, plan: emptyPlan, context: layout)
            let result = rendered.first?.elements.contains { $0.textRole == "title" } ?? false
            titleCache[key] = result
            return result
        }
        func bounds(_ index: Int, _ state: State) -> (lower: Int, upper: Int) {
            let moment = moments[index]
            if context.exactSet || context.keepOrder { return (moment.photos.count, moment.photos.count) }
            let required = moment.photos.filter(mandatory.contains).count
            let extraCover = state.cover.map { moment.photos.contains($0) && !mandatory.contains($0) ? 1 : 0 } ?? 0
            return (min(moment.sizeRange.lowerBound, moment.photos.count),
                    min(moment.photos.count, max(moment.sizeRange.upperBound, required + extraCover)))
        }
        func usedCount(_ index: Int, _ state: State) -> Int {
            moments[index].photos.filter(state.used.contains).count
        }
        /// Mandatory alternatives replace low-ranked alternatives in the bounded pool, so a hard
        /// requirement beyond rank six cannot be starved by repeated optional choices.
        func pool(_ remaining: [AssetID]) -> [AssetID] {
            let required = remaining.filter(mandatory.contains)
            let chosen = Set((required + remaining.filter { !mandatory.contains($0) }).prefix(PageScore.alternativesPerMoment))
            return remaining.filter(chosen.contains)
        }
        func tuples(_ page: DesignedSet, state: State, hero: AssetID?) -> [[AssetID]] {
            let k = slots[page.id]!.count
            let current = moments[state.moment].photos.filter { !state.used.contains($0) && $0 != hero }
            let nextIndex = state.moment + 1
            let next = nextIndex < moments.count && usedCount(nextIndex, state) < bounds(nextIndex, state).upper
                ? moments[nextIndex].photos.filter { !state.used.contains($0) && $0 != hero } : []
            if context.keepOrder {
                let ordered = current + Array(next.prefix(1))
                let ids = hero.map { [$0] } ?? []
                return ordered.count >= k - ids.count ? [ids + ordered.prefix(k - ids.count)] : []
            }
            let available = pool(current) + Array(next.prefix(1))
            let forced = hero.map { [$0] } ?? []
            let count = k - forced.count
            guard count >= 0, available.count >= count else { return [] }
            var results: [[AssetID]] = []
            func choose(_ start: Int, _ selected: [AssetID]) {
                if selected.count == count { results.append(forced + selected); return }
                let needed = count - selected.count
                guard available.count - start >= needed else { return }
                for index in start...(available.count - needed) { choose(index + 1, selected + [available[index]]) }
            }
            choose(0, [])
            return results
        }
        func expand(_ state: State, hero: AssetID? = nil) -> [State] {
            let remaining = moments[state.moment].photos.filter { !state.used.contains($0) }
            let limit = bounds(state.moment, state).upper
            let used = usedCount(state.moment, state)
            let first = state.steps.isEmpty
            let shapePool = pool(remaining) + (hero.map { [$0] } ?? [])
            let fitting = pages.filter {
                (!first || ($0.slideCount == 1 && $0.coverCapable == true))
                    && slots[$0.id]!.count <= shapePool.count + 1
            }
            let availableShapes = Set(shapePool.compactMap { shapes[$0] })
            let ranked = fitting.map { page -> (DesignedSet, Int) in
                let matches = slots[page.id]!.filter { availableShapes.contains(ShapeClass.of(aspect: $0.aspect)) }.count
                let repeated = state.steps.contains { $0.geometry == geometry[page.id] } ? 10 : 0
                return (page, matches - repeated)
            }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
                .prefix(PageScore.pagesPerStep).map(\.0)
            var results: [State] = []
            for page in ranked {
                for ids in tuples(page, state: state, hero: hero) {
                    let currentIDs = ids.filter { moments[state.moment].photos.contains($0) }
                    let mustLeft = remaining.filter { mandatory.contains($0) && !ids.contains($0) }.count
                    guard used + currentIDs.count + mustLeft <= limit,
                          !currentIDs.isEmpty || (first && hero != nil) else { continue }
                    let nextIndex = state.moment + 1
                    if nextIndex < moments.count {
                        let consumedNext = ids.filter { moments[nextIndex].photos.contains($0) }.count
                        let requiredNext = moments[nextIndex].photos.filter {
                            mandatory.contains($0) && !state.used.contains($0) && !ids.contains($0)
                        }.count
                        guard usedCount(nextIndex, state) + consumedNext + requiredNext <= bounds(nextIndex, state).upper else { continue }
                    }
                    if context.keepOrder {
                        // Borrow only after consuming all preceding input photos.
                        guard ids.filter({ moments[state.moment].photos.contains($0) }) == Array(remaining.prefix(currentIDs.count)) else { continue }
                        if ids.contains(where: { !moments[state.moment].photos.contains($0) }), currentIDs.count != remaining.count { continue }
                    }
                    guard let fit = assign(ids, page, hero: hero) else { continue }
                    var result = state
                    result.steps.append(Step(pageID: page.id, photos: ids, placed: fit.placed,
                                             geometry: geometry[page.id]!, role: page.pageRole ?? "grid"))
                    result.used.formUnion(ids)
                    result.score += page.familyID == "layouts" ? PageScore.gridPage : PageScore.authoredPage
                    if let previous = state.steps.last?.pageID.flatMap({ byID[$0] }),
                       let source = previous.sourceTemplate, source == page.sourceTemplate,
                       let index = previous.pageIndex, index + previous.slideCount == page.pageIndex {
                        result.score += PageScore.authoredNeighbour
                    }
                    if first, titleRenders(ids, page, fit: fit, hero: hero) { result.score += PageScore.titledCover }
                    result.score += ids.reduce(0) { $0 + PageScore.storyRank * (rank[$1] ?? 0) }
                    result.score -= PageScore.cropCost * fit.cost
                    if state.steps.contains(where: { $0.geometry == geometry[page.id] }) { result.score -= PageScore.repeatedPage }
                    let previous = state.steps.suffix(2)
                    if previous.count == 2,
                       previous.allSatisfy({ $0.role == (page.pageRole ?? "grid") })
                        || previous.allSatisfy({ $0.geometry == geometry[page.id] }) {
                        result.score -= PageScore.monotony
                    }
                    let moved = ids.filter { $0 != hero && !moments[state.moment].photos.contains($0) }.count
                    result.score -= PageScore.movedPhoto * Double(moved)
                    results.append(result)
                }
            }
            return results
        }
        func whiteCard(_ state: State, photo: AssetID) -> State {
            var result = state
            result.steps.append(Step(pageID: nil, photos: [photo], placed: [], geometry: "white", role: "statement"))
            result.used.insert(photo)
            result.whiteCards += 1
            result.score -= PageScore.whiteCard
            return result
        }

        var initial = State()
        initial.moment = moments.firstIndex { !$0.photos.isEmpty } ?? 0
        var warnings: [String] = []
        var beam: [State] = []
        if context.keepOrder {
            initial.cover = firstPhoto
            beam = expand(initial, hero: firstPhoto)
            if beam.isEmpty { beam = [whiteCard(initial, photo: firstPhoto)] }
        } else {
            let candidates = direction.coverCandidates.isEmpty ? [direction.coverAssetID] : direction.coverCandidates
            for cover in candidates where photos.contains(cover) && !excludedCovers.contains(cover) {
                var opening = initial
                opening.cover = cover
                beam += expand(opening, hero: cover)
            }
            if beam.isEmpty {
                let firstMoment = moments[initial.moment].photos
                let cover: AssetID
                if let allowed = firstMoment.first(where: { !excludedCovers.contains($0) }) {
                    cover = allowed
                    warnings.append("\(id): cover candidates excluded or unusable; using \(cover.rawValue)")
                } else {
                    cover = firstPhoto
                    warnings.append("\(id): no non-excluded opening photo; ignoring cover exclusions for \(cover.rawValue)")
                }
                initial.cover = cover
                beam = expand(initial, hero: cover)
                if beam.isEmpty { beam = [whiteCard(initial, photo: cover)] }
            }
        }
        func prune(_ states: [State]) -> [State] {
            var seen: Set<String> = []
            let keyed = states.map { (state: $0, key: $0.key) }
            let sorted = keyed.sorted {
                $0.state.score != $1.state.score ? $0.state.score > $1.state.score : $0.key < $1.key
            }
            return sorted.filter { seen.insert($0.key).inserted }.prefix(PageScore.beamWidth).map(\.state)
        }
        beam = prune(beam)
        var finished: [State] = []
        let transitionLimit = (photos.count + moments.count) * 2 + 10
        for _ in 0..<transitionLimit {
            guard !beam.isEmpty else { break }
            var next: [State] = []
            for state in beam {
                if state.moment >= moments.count { finished.append(state); continue }
                let remaining = moments[state.moment].photos.filter { !state.used.contains($0) }
                let required = remaining.filter(mandatory.contains)
                let count = usedCount(state.moment, state)
                let range = bounds(state.moment, state)
                if count >= range.lower, required.isEmpty {
                    var advanced = state
                    advanced.moment += 1
                    next.append(advanced)
                }
                guard count < range.upper, !remaining.isEmpty else { continue }
                let placed = expand(state)
                next += placed
                if placed.isEmpty, let photo = required.first ?? (count < range.lower ? remaining.first : nil) {
                    next.append(whiteCard(state, photo: photo))
                }
            }
            beam = prune(next)
        }
        func finalScore(_ state: State) -> Double {
            guard let target = context.maxSlides else { return state.score }
            let count = state.steps.reduce(0) { $0 + ($1.pageID.flatMap { byID[$0]?.slideCount } ?? 1) }
            return state.score - PageScore.slideCountMiss * Double(max(0, abs(count - target) - 1))
        }
        // Every transition consumes a photo or advances a moment, so the dynamic guard is above
        // the longest path. White cards ensure even an empty catalogue has a complete result.
        let best = finished.max { finalScore($0) != finalScore($1) ? finalScore($0) < finalScore($1) : $0.key > $1.key }!
        warnings += best.steps.filter { $0.pageID == nil }.map {
            "\(id): \($0.photos[0].rawValue) fits no available page; white card"
        }
        return Result(plan: materialize(best, plan: emptyPlan, pages: byID, context: layout),
                      score: finalScore(best), family: family, whiteCards: best.whiteCards, warnings: warnings)
    }

    /// Geometry, rather than catalogue id, identifies repeated authored pages.
    private static func geometrySignature(_ page: DesignedSet) -> String {
        let frames = page.expandedSlots.map { slot in
            [slot.frame.x, slot.frame.y, slot.frame.width, slot.frame.height].map { String(Int(($0 / 0.02).rounded())) }.joined(separator: ",")
        }.sorted().joined(separator: ";")
        return "\(page.slideCount)|\(frames)|text:\(!(page.texts?.isEmpty ?? true))|frame:\(!(page.frames?.isEmpty ?? true))"
    }

    private static func materialize(_ state: State, plan initial: CarouselPlan, pages: [String: DesignedSet],
                                    context: LayoutContext) -> CarouselPlan {
        var plan = initial
        var titlePlaced = false, captions = 0
        for step in state.steps {
            guard let pageID = step.pageID, let page = pages[pageID] else {
                plan.slides.append(SlidePlan(primitive: .hero, mood: "", density: "quiet",
                                             photos: [.plain(step.photos[0])], decorations: [], stamps: []))
                titlePlaced = true
                continue
            }
            var rendered = TemplateVocabulary.render(page: page, placed: step.placed, plan: plan, start: plan.slides.count,
                                                      context: context, titlePlaced: &titlePlaced, captionCount: &captions)
            if plan.slides.isEmpty {
                TemplateVocabulary.addCoverTitleIfNeeded(to: &rendered, plan: plan, context: context)
            }
            titlePlaced = true // Title layers on later pages never become story titles.
            let slots = page.expandedSlots
            for (offset, resolved) in rendered.enumerated() {
                let onSlide = step.placed.filter {
                    let frame = slots[$0.slotIndex].frame
                    return Int(floor(frame.x + frame.width / 2)) == offset
                }.map(\.assetID)
                var photos = onSlide.map(PhotoElement.plain)
                if photos.isEmpty {
                    var reference = PhotoElement.plain(step.photos[0])
                    reference.role = "support"
                    photos = [reference]
                } else {
                    for index in photos.indices where index > 0 { photos[index].role = "support" }
                }
                let primitive: Primitive = photos.count <= 1 ? .hero : photos.count == 2 ? .asymmetricPair : .overlapCluster
                let placement = SlidePlacement(catalogueVersion: DesignedSet.schemaVersion, pageID: page.id,
                                               runOffset: offset, runLength: page.slideCount, placed: step.placed, slide: resolved)
                plan.slides.append(SlidePlan(primitive: primitive, mood: "", density: "balanced", photos: photos,
                                             decorations: [], stamps: [], placement: placement))
            }
        }
        return plan
    }
}

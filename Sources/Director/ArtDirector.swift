import Core
import Foundation

public struct CandidateCard: Sendable {
    public let assetID: AssetID
    /// One line of local facts: time, faces, labels, cluster size, flags.
    public let summary: String
    public let capturedAt: Date?
    public let triageJPEG: Data?
    public let planningJPEG: Data?
    public init(assetID: AssetID, summary: String, capturedAt: Date?, triageJPEG: Data?, planningJPEG: Data?) {
        self.assetID = assetID; self.summary = summary; self.capturedAt = capturedAt
        self.triageJPEG = triageJPEG; self.planningJPEG = planningJPEG
    }
}

public struct DirectorInput: Sendable {
    public var storyLabel: String
    public var dateSpan: String
    public var requestedSlides: Int?
    /// Shortlist in rank order.
    public var shortlist: [CandidateCard]
    /// Given triage scores, returns the planning pool ordered by adjusted rank.
    public var selectPool: @Sendable ([AssetID: TriageScore]) -> [AssetID]
    public var maxPlanningImages = 24
    public init(storyLabel: String, dateSpan: String, requestedSlides: Int?, shortlist: [CandidateCard],
                selectPool: @escaping @Sendable ([AssetID: TriageScore]) -> [AssetID]) {
        self.storyLabel = storyLabel; self.dateSpan = dateSpan; self.requestedSlides = requestedSlides
        self.shortlist = shortlist; self.selectPool = selectPool
    }
}

public struct Exchange: Sendable {
    public let name: String
    public let request: JSONValue
    public let response: JSONValue?
}

public struct DirectorOutput: Sendable {
    /// ok | partial | fallback | failed: …
    public var status = "failed: not run"
    public var triage: [AssetID: TriageScore] = [:]
    public var pool: [AssetID] = []
    public var spine: SelectionSpine?
    public var recommendedSlideCount: Int?
    public var plans: [CarouselPlan] = []
    public var unavailable: [String: String] = [:]
    public var deviations: [String: Deviation] = [:]
    public var diversity: ConceptDistance?
    public var calls: [ProviderCallRecord] = []
    public var warnings: [String] = []
    public var exchanges: [Exchange] = []
    public var promptVersions: [String: String] = [:]
}

public struct ArtDirector: Sendable {
    let client: ResponsesClient
    let stylePack: StylePack
    let log: @Sendable (String) -> Void

    public init(client: ResponsesClient, stylePack: StylePack, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client; self.stylePack = stylePack; self.log = log
    }

    public func direct(_ input: DirectorInput) async -> DirectorOutput {
        var out = DirectorOutput()
        let cards = Dictionary(uniqueKeysWithValues: input.shortlist.map { ($0.assetID, $0) })

        // 1. Triage
        log("Building the story… triaging \(input.shortlist.count) photos")
        out.triage = await triage(input, &out)
        // 2. Planning pool
        out.pool = input.selectPool(out.triage)
        let flagged = Set(out.triage.filter { !$0.value.safety.isEmpty }.keys)

        // 3. Planning with bounded repair / retry
        log("Art-directing the post… planning from \(out.pool.count) candidates")
        var response: PlannerResponse?
        var issues: [ValidationIssue] = []
        let content = plannerContent(input, pool: out.pool, cards: cards, triage: out.triage)
        let schema = Schemas.planner(ids: out.pool, decorationIDs: stylePack.decorationIDs)
        let prompt = load("planner.system", &out)

        if let prompt, let text = await call("planner", prompt, content, schema, reasoning: "medium", &out) {
            (response, issues) = decode(text, pool: out.pool, flagged: flagged)
            if !issues.isEmpty, let repair = load("repair.system", &out) {
                let repairContent: [ContentPart] = [
                    .text("Candidate ids: \(out.pool.map(\.rawValue).joined(separator: ", "))"),
                    .text("Validation errors:\n" + issues.map { "- \($0)" }.joined(separator: "\n")),
                    .text("Original JSON:\n" + text),
                ]
                if let fixed = await call("repair", repair, repairContent, schema, reasoning: "low", &out) {
                    let (r2, i2) = decode(fixed, pool: out.pool, flagged: flagged)
                    if r2 != nil && (response == nil || i2.count < issues.count) { (response, issues) = (r2, i2) }
                }
            }
            if !issues.isEmpty {
                let note = ContentPart.text("Your previous attempt was invalid: " + issues.prefix(12).map(\.description).joined(separator: "; "))
                if let retry = await call("retry", prompt, content + [note], schema, reasoning: "medium", &out) {
                    let (r3, i3) = decode(retry, pool: out.pool, flagged: flagged)
                    if r3 != nil && (response == nil || i3.count < issues.count) { (response, issues) = (r3, i3) }
                }
            }
        }
        if !issues.isEmpty { out.warnings.append("planner issues after repair/retry: " + issues.prefix(8).map(\.description).joined(separator: "; ")) }

        // 4. Assemble: keep valid parts, deterministic Plain fallback otherwise
        assemble(response, issues: issues, input: input, cards: cards, &out)

        // 5. Diversity check with one mutation
        if let d = out.plans.first(where: { $0.conceptType == .designed }),
           let w = out.plans.first(where: { $0.conceptType == .wildcard }) {
            var distance = PlanMetrics.diversity(d, w)
            if !distance.passes, let mutation = load("mutation.system", &out), let spine = out.spine {
                let current = PlannerResponse(recommendedSlideCount: spine.orderedAssetIDs.count, spine: spine, plans: out.plans)
                let json = String(decoding: (try? JSONCoding.encoder.encode(current)) ?? Data(), as: UTF8.self)
                let failed = "same cover: \(distance.sameCover), photo overlap (jaccard): \(String(format: "%.2f", distance.jaccard)), structural differences so far: \(distance.structuralDiffs)"
                if let text = await call("mutation", mutation, [.text("Too similar: \(failed)"), .text("JSON:\n" + json)],
                                         schema, reasoning: "low", &out) {
                    let (r, i) = decode(text, pool: out.pool, flagged: flagged)
                    if let r, let newW = r.plans.first(where: { $0.conceptType == .wildcard }),
                       !i.contains(where: { $0.concept == .wildcard }), PlanMetrics.diversity(d, newW).passes {
                        out.plans = out.plans.map { $0.conceptType == .wildcard ? newW : $0 }
                        distance = PlanMetrics.diversity(d, newW)
                    } else {
                        out.warnings.append("designed and wildcard remain similar after one mutation")
                    }
                }
            }
            out.diversity = distance
        }
        if let spine = out.spine {
            for p in out.plans where p.conceptType != .plainDump {
                out.deviations[p.conceptType.rawValue] = PlanMetrics.deviation(plan: p, spine: spine)
            }
        }
        return out
    }

    // MARK: - Steps

    private func triage(_ input: DirectorInput, _ out: inout DirectorOutput) async -> [AssetID: TriageScore] {
        guard let prompt = load("triage.system", &out) else { return [:] }
        var result: [AssetID: TriageScore] = [:]
        var pending = input.shortlist.filter { $0.triageJPEG != nil }
        for attempt in 0..<2 where !pending.isEmpty {
            var content: [ContentPart] = [.text("Event: \(input.storyLabel) (\(input.dateSpan)). \(pending.count) candidate photos follow.")]
            for c in pending {
                content.append(.text("id \(c.assetID.rawValue): \(c.summary)"))
                content.append(.image(jpeg: c.triageJPEG!, assetID: c.assetID, detail: "low"))
            }
            let stage = attempt == 0 ? "triage" : "triage-repair"
            guard let text = await call(stage, prompt, content, Schemas.triage(ids: pending.map(\.assetID)),
                                        reasoning: "low", &out, candidates: pending.count) else { break }
            guard let items = try? JSONDecoder().decode(TriageEnvelope.self, from: Data(text.utf8)).results else {
                out.warnings.append("triage output could not be decoded"); continue
            }
            for item in items where pending.contains(where: { $0.assetID == item.id }) {
                result[item.id] = TriageScore(emotionalValue: item.emotionalValue, imperfection: item.imperfection,
                                              safety: item.safety, tags: item.tags, confidence: item.confidence)
            }
            pending = pending.filter { result[$0.assetID] == nil }
        }
        if !pending.isEmpty { out.warnings.append("triage missing for \(pending.count) photos; local ranking used for them") }
        return result
    }

    private func plannerContent(_ input: DirectorInput, pool: [AssetID], cards: [AssetID: CandidateCard],
                                triage: [AssetID: TriageScore]) -> [ContentPart] {
        let target = input.requestedSlides.map { "Target exactly \($0) photos in the spine unless fewer strong photos exist." }
            ?? "Choose the length yourself: usually 8-12, fewer if the pool is weak."
        var content: [ContentPart] = [.text("""
        Event: \(input.storyLabel) (\(input.dateSpan)). \(pool.count) candidates, listed best-first by a local ranking (which is only a hint).
        \(target)
        Available decorationIDs: \(stylePack.decorationIDs.joined(separator: ", ")).
        Style hints: \(stylePack.promptHints.joined(separator: " "))
        """)]
        for (i, id) in pool.enumerated() {
            guard let card = cards[id] else { continue }
            var line = "id \(id.rawValue): \(card.summary)"
            if let t = triage[id] {
                line += " | emotional \(t.emotionalValue)/5, imperfection \(t.imperfection)"
                if !t.tags.isEmpty { line += ", tags \(t.tags.joined(separator: " "))" }
                if !t.safety.isEmpty { line += ", SAFETY \(t.safety.joined(separator: " "))" }
            }
            content.append(.text(line))
            if i < input.maxPlanningImages, let jpeg = card.planningJPEG {
                content.append(.image(jpeg: jpeg, assetID: id, detail: "high"))
            }
        }
        return content
    }

    private func assemble(_ response: PlannerResponse?, issues: [ValidationIssue], input: DirectorInput,
                          cards: [AssetID: CandidateCard], _ out: inout DirectorOutput) {
        let spineOK = response != nil && !issues.contains { $0.concept == nil && $0.path.hasPrefix("spine") }
        let spine: SelectionSpine
        if spineOK, let response {
            spine = response.spine
            out.recommendedSlideCount = response.recommendedSlideCount
        } else {
            let n = min(input.requestedSlides ?? 10, out.pool.count)
            let ids = Array(out.pool.prefix(n)).sorted {
                (cards[$0]?.capturedAt ?? .distantFuture, $0) < (cards[$1]?.capturedAt ?? .distantFuture, $1)
            }
            spine = SelectionSpine(orderedAssetIDs: ids, sequenceIntent: ids.map { _ in .build }, rationale: [])
            out.recommendedSlideCount = ids.count
            out.warnings.append("used deterministic fallback spine (top-ranked photos in time order)")
        }
        out.spine = spine

        var plans: [CarouselPlan] = []
        let modelPlain = spineOK ? response?.plans.first { $0.conceptType == .plainDump } : nil
        if let modelPlain, !issues.contains(where: { $0.concept == .plainDump }) {
            plans.append(modelPlain)
        } else {
            plans.append(.plainDump(from: spine, note: "Deterministic Plain Dump of the selection spine."))
        }
        for type in [ConceptType.designed, .wildcard] {
            if let p = response?.plans.first(where: { $0.conceptType == type }),
               !issues.contains(where: { $0.concept == type }) {
                plans.append(p)
            } else {
                out.unavailable[type.rawValue] = response == nil ? "planner produced no usable response" : "invalid after repair/retry"
            }
        }
        out.plans = plans
        out.status = !spineOK ? "fallback" : out.unavailable.isEmpty ? "ok" : "partial"
    }

    // MARK: - Helpers

    private func load(_ name: String, _ out: inout DirectorOutput) -> Prompt? {
        do {
            let p = try Prompts.load(name)
            out.promptVersions[name] = p.version
            return p
        } catch {
            out.warnings.append("missing prompt \(name)")
            return nil
        }
    }

    private func call(_ stage: String, _ prompt: Prompt, _ content: [ContentPart], _ schema: JSONValue,
                      reasoning: String, _ out: inout DirectorOutput, candidates: Int = 0) async -> String? {
        var record = ProviderCallRecord(stage: stage, model: client.model, promptVersion: prompt.version)
        record.candidateCount = candidates
        do {
            let r = try await client.call(system: prompt.text, content: content, schemaName: stage.replacingOccurrences(of: "-", with: "_"),
                                          schema: schema, reasoning: reasoning)
            record.inputTokens = r.usage.input; record.cachedTokens = r.usage.cached
            record.outputTokens = r.usage.output; record.reasoningTokens = r.usage.reasoning
            record.imageCount = r.imageCount; record.thumbnailBytes = r.imageBytes
            record.latencySeconds = r.latencySeconds; record.retryCount = r.retryCount
            record.estimatedCost = Pricing.estimate(r.usage); record.ok = true; record.responseID = r.responseID
            out.calls.append(record)
            out.exchanges.append(Exchange(name: "\(out.exchanges.count + 1)-\(stage)", request: r.redactedRequest, response: r.rawResponse))
            return r.outputText
        } catch {
            record.error = "\(error)"
            out.calls.append(record)
            out.warnings.append("\(stage) call failed: \(error)")
            return nil
        }
    }

    private func decode(_ text: String, pool: [AssetID], flagged: Set<AssetID>) -> (PlannerResponse?, [ValidationIssue]) {
        do {
            var r = try JSONDecoder().decode(PlannerResponse.self, from: Data(text.utf8))
            r.plans = r.plans.map { Self.normalizePlain($0, spine: r.spine) }
            return (r, PlanValidator.validate(r, pool: pool, stylePack: stylePack, flagged: flagged))
        } catch {
            return (nil, [ValidationIssue(path: "json", message: "could not decode: \(error)")])
        }
    }
}

extension ArtDirector {
    /// Plain Dump is defined as the spine, so derive it deterministically instead of spending a repair call:
    /// spine order, one photo per slide, keeping the model's hero/full_bleed choice per photo, no decoration.
    static func normalizePlain(_ plan: CarouselPlan, spine: SelectionSpine) -> CarouselPlan {
        guard plan.conceptType == .plainDump else { return plan }
        let chosen = Dictionary(plan.slides.compactMap { s in s.photos.first.map { ($0.assetID, s.primitive) } },
                                uniquingKeysWith: { a, _ in a })
        return CarouselPlan(conceptType: .plainDump, conceptNote: plan.conceptNote, slides: spine.orderedAssetIDs.map { id in
            SlidePlan(primitive: chosen[id] == .hero ? .hero : .fullBleed, mood: "calm", density: "quiet",
                      photos: [.plain(id)], decorations: [], stamps: [])
        })
    }
}

private struct TriageEnvelope: Decodable {
    struct Item: Decodable {
        let id: AssetID
        let emotionalValue: Int
        let imperfection: String
        let safety: [String]
        let tags: [String]
        let confidence: String
    }
    let results: [Item]
}

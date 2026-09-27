import Core
import Foundation
import ImageIO
import CryptoKit
import Render

public struct CandidateCard: Sendable {
    public let assetID: AssetID
    /// One line of local facts: time, faces, labels, cluster size, flags.
    public let summary: String
    public let capturedAt: Date?
    public let triageJPEG: Data?
    public let planningJPEG: Data?
    /// Local social-safety flags (e.g. very low face-capture quality); treated like triage safety flags.
    public let localFlags: [String]
    public init(assetID: AssetID, summary: String, capturedAt: Date?, triageJPEG: Data?, planningJPEG: Data?,
                localFlags: [String] = []) {
        self.assetID = assetID; self.summary = summary; self.capturedAt = capturedAt
        self.triageJPEG = triageJPEG; self.planningJPEG = planningJPEG; self.localFlags = localFlags
    }
}

public struct DirectorInput: Sendable {
    public var storyLabel: String
    public var dateSpan: String
    public var requestedSlides: Int?
    public var storyHint: String?
    public var allowMultiEventRecap: Bool
    public var exactSet: Bool
    public var keepOrder: Bool
    /// Shortlist in rank order.
    public var shortlist: [CandidateCard]
    /// Given triage scores, returns the planning pool ordered by adjusted rank.
    public var selectPool: @Sendable ([AssetID: TriageScore]) -> [AssetID]
    /// Every pool candidate is sent as an image: text-only candidates were never chosen in practice.
    public var maxPlanningImages = 60
    /// Local evidence for the composer engine (triage, flags and sequence intents are filled in by the director).
    public var composition: CompositionContext
    /// Seeds composition and layout, so a run's carousels are reproducible.
    public var runID: String
    public var analysisThumbnails: [AssetID: Data] = [:]
    public var judgeEnabled = false
    public init(storyLabel: String, dateSpan: String, requestedSlides: Int?, shortlist: [CandidateCard],
                selectPool: @escaping @Sendable ([AssetID: TriageScore]) -> [AssetID], composition: CompositionContext,
                runID: String, storyHint: String? = nil, allowMultiEventRecap: Bool = false,
                exactSet: Bool = false, keepOrder: Bool = false) {
        self.storyLabel = storyLabel; self.dateSpan = dateSpan; self.requestedSlides = requestedSlides
        self.shortlist = shortlist; self.selectPool = selectPool; self.composition = composition; self.runID = runID
        self.storyHint = storyHint
        self.allowMultiEventRecap = allowMultiEventRecap
        self.exactSet = exactSet; self.keepOrder = keepOrder
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
    /// Baseline first, then the composed directions.
    public var plans: [CarouselPlan] = []
    public var presentationOrder: [String] = []
    public var unavailable: [String: String] = [:]
    public var deviations: [String: Deviation] = [:]
    public var diversity: [ConceptDistance] = []
    public var calls: [ProviderCallRecord] = []
    public var warnings: [String] = []
    public var exchanges: [Exchange] = []
    public var promptVersions: [String: String] = [:]
    public var judgeResults: [JudgeResult] = []
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
            .union(input.shortlist.filter { !$0.localFlags.isEmpty }.map(\.assetID))

        // 3. Planning with bounded repair / retry
        log("Art-directing the post… planning from \(out.pool.count) candidates")
        var response: PlannerResponse?
        var issues: [ValidationIssue] = []
        let content = plannerContent(input, pool: out.pool, cards: cards, triage: out.triage)
        let schema = Schemas.planner(ids: out.pool)
        let prompt = load("planner.system", &out)

        let requested = input.requestedSlides
        func consider(_ text: String) {
            let (r, i) = decode(text, pool: out.pool, flagged: flagged, requested: requested, exactSet: input.exactSet, keepOrder: input.keepOrder)
            if let r, response.map({ Self.quality(r, i) > Self.quality($0, issues) }) ?? true { (response, issues) = (r, i) }
        }
        if let prompt {
            let first = await call("planner", prompt, content, schema, reasoning: PlannerExperiment.reasoning, &out)
            if let first {
                consider(first)
                if response == nil { issues = decode(first, pool: out.pool, flagged: flagged, requested: requested, exactSet: input.exactSet, keepOrder: input.keepOrder).1 }
                if !issues.isEmpty, let repair = load("repair.system", &out) {
                    let repairContent: [ContentPart] = [
                        .text("Candidate ids: \(out.pool.map(\.rawValue).joined(separator: ", "))"),
                        .text("Validation errors:\n" + issues.map { "- \($0)" }.joined(separator: "\n")),
                        .text("Original JSON:\n" + first),
                    ]
                    if let fixed = await call("repair", repair, repairContent, schema, reasoning: "low", &out) { consider(fixed) }
                }
            }
            if response == nil || !issues.isEmpty {
                var retryContent = content
                if !issues.isEmpty {
                    retryContent.append(.text("Your previous attempt was invalid: " + issues.prefix(12).map(\.description).joined(separator: "; ")))
                }
                if let retry = await call("retry", prompt, retryContent, schema, reasoning: PlannerExperiment.reasoning, &out) { consider(retry) }
            }
        }
        if !issues.isEmpty { out.warnings.append("planner issues after repair/retry: " + issues.prefix(8).map(\.description).joined(separator: "; ")) }

        // 4. Assemble: keep the valid spine and directions, deterministic fallback spine otherwise
        let directions = assemble(response, issues: issues, input: input, cards: cards, flagged: flagged, &out)

        // 5. Compose every direction (and the baseline) locally: no further model calls.
        if let spine = out.spine {
            var context = input.composition
            context.triage = out.triage
            context.flagged = flagged
            context.sequenceIntent = Dictionary(zip(spine.orderedAssetIDs, spine.sequenceIntent), uniquingKeysWith: { a, _ in a })
            let set = ComposerEngine.composeSet(directions: directions, spine: spine, context: context, runID: input.runID)
            out.plans = set.plans
            out.presentationOrder = set.presentationOrder
            out.diversity = set.distances
            out.warnings += set.warnings
            for p in out.plans where !p.isBaseline { out.deviations[p.id] = PlanMetrics.deviation(plan: p, spine: spine) }
            if input.judgeEnabled { await judge(directions: directions, input: input, context: context, out: &out) }
        }
        return out
    }

    private func judge(directions: [Direction], input: DirectorInput, context: CompositionContext, out: inout DirectorOutput) async {
        guard let prompt = load("judge.system", &out) else { return }
        let count = min(6, max(2, stylePack.judge?.candidates ?? 6))
        for (index, direction) in directions.enumerated() {
            let id = "c\(index + 1)"
            guard let composed = out.plans.first(where: { $0.id == id }), let finalDirection = composed.direction,
                  let compositionSeed = composed.compositionSeed, let seed = UInt64(compositionSeed, radix: 16) else { continue }
            let finalLayoutSeed = ComposerEngine.layoutSeed(runID: input.runID, id: id)
            let candidates = ComposerEngine.candidates(finalDirection, id: id, context: context, seed: seed,
                                                       layoutSeed: finalLayoutSeed, limit: count)
            guard candidates.count >= 2 else {
                out.judgeResults.append(JudgeResult(directionID: id, candidateFingerprints: candidates.map { Self.fingerprint($0.plan) }, model: client.model, promptVersion: prompt.version, skipped: "fewer than two safe candidates")); continue
            }
            let labels = (0..<candidates.count).map { String(UnicodeScalar(65 + $0)!) }
            do {
                let sourceFolder = FileManager.default.temporaryDirectory.appending(path: "ak14-judge-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: sourceFolder) }
                var thumbnailRecords = context.photos
                for (asset, original) in context.photos {
                    guard let data = input.analysisThumbnails[asset], let path = original.sourceRelativePaths.first else { continue }
                    let target = sourceFolder.appending(path: path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                    if let image = CGImageSourceCreateWithData(data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
                        thumbnailRecords[asset] = PhotoRecord(assetID: original.assetID, contentSHA256: original.contentSHA256, sourceRelativePaths: original.sourceRelativePaths, byteCount: data.count, fileType: "public.jpeg", pixelWidth: image.width, pixelHeight: image.height, exifOrientation: 1, metadata: original.metadata)
                    }
                }
                let stripData = try candidates.map { candidate -> Data in
                    let resolved = LayoutResolver.resolve(candidate.plan, context: LayoutContext(aspect: context.aspect, photos: context.photos, features: context.features, stylePack: context.stylePack, seed: ComposerEngine.layoutSeed(runID: input.runID, id: id), vocabulary: candidate.plan.isBaseline ? [] : context.vocabulary))
                    return try StripRenderer().strip(resolved, photos: thumbnailRecords, sourceFolder: sourceFolder)
                }
                let stripURLs = try stripData.enumerated().map { index, bytes -> URL in
                    let url = FileManager.default.temporaryDirectory.appending(path: "ak14-judge-strip-\(UUID().uuidString).jpg")
                    try bytes.write(to: url); return url
                }
                defer { stripURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
                var totalCost = 0.0, totalLatency = 0.0
                var rankings: [[String]] = [], reasons: [String] = []
                for order in [Array(candidates.indices), Array(candidates.indices.reversed())] {
                    let orderedLabels = order.map { labels[$0] }
                    var content: [ContentPart] = [.text("Constitution:\n\(stylePack.constitution ?? "")\nTrend notes: \(stylePack.trendNotes?.joined(separator: " ") ?? "")\nOwner story: \(input.storyHint ?? "")\nDirection brief: \(direction.brief)\nRank these strips, labelled in this order: \(orderedLabels.joined(separator: ", ")).")]
                    for i in order {
                        let bytes = try Data(contentsOf: stripURLs[i])
                        content.append(.text("Candidate \(labels[i])"))
                        content.append(.image(jpeg: bytes, assetID: candidates[i].plan.coverAssetID ?? direction.coverAssetID, detail: "low"))
                    }
                    let result = try await client.call(system: prompt.text, content: content, schemaName: "judge",
                                                        schema: Schemas.judge(labels: labels), reasoning: "low",
                                                        maxOutputTokens: 4_000)
                    totalCost += Pricing.estimate(result.usage); totalLatency += result.latencySeconds
                    var record = ProviderCallRecord(stage: "judge", model: client.model, promptVersion: prompt.version)
                    record.inputTokens = result.usage.input; record.cachedTokens = result.usage.cached; record.outputTokens = result.usage.output
                    record.reasoningTokens = result.usage.reasoning; record.imageCount = result.imageCount; record.thumbnailBytes = result.imageBytes
                    record.latencySeconds = result.latencySeconds; record.retryCount = result.retryCount; record.estimatedCost = Pricing.estimate(result.usage)
                    record.ok = true; record.responseID = result.responseID; out.calls.append(record)
                    out.exchanges.append(Exchange(name: "\(out.exchanges.count + 1)-judge", request: result.redactedRequest, response: result.rawResponse))
                    let decoded = try JSONDecoder().decode(JudgeEnvelope.self, from: Data(result.outputText.utf8))
                    guard decoded.ranking.count == candidates.count, Set(decoded.ranking) == Set(labels),
                          !decoded.reasons.isEmpty, decoded.reasons.allSatisfy(Schemas.judgeReasons.contains) else { throw JudgeError.invalid }
                    rankings.append(decoded.ranking); reasons += decoded.reasons
                }
                var points = Dictionary(uniqueKeysWithValues: labels.map { ($0, 0) })
                for ranking in rankings { for (rank, label) in ranking.enumerated() { points[label, default: 0] += candidates.count - rank } }
                guard let winner = labels.sorted(by: { points[$0, default: 0] == points[$1, default: 0] ? $0 < $1 : points[$0, default: 0] > points[$1, default: 0] }).first,
                      let winningIndex = labels.firstIndex(of: winner) else { throw JudgeError.invalid }
                if let planIndex = out.plans.firstIndex(where: { $0.id == id }) { out.plans[planIndex] = candidates[winningIndex].plan }
                out.judgeResults.append(JudgeResult(directionID: id, candidateFingerprints: candidates.map { Self.fingerprint($0.plan) }, stripSHA256: stripData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }, winnerIndex: winningIndex, ranking: rankings[0].compactMap { labels.firstIndex(of: $0) }, orderRankings: rankings.map { $0.compactMap { labels.firstIndex(of: $0) } }, reasons: Array(Set(reasons)).sorted(), model: client.model, promptVersion: prompt.version, costUSD: totalCost, latency: totalLatency))
            } catch {
                out.judgeResults.append(JudgeResult(directionID: id, candidateFingerprints: candidates.map { Self.fingerprint($0.plan) }, model: client.model, promptVersion: prompt.version, skipped: "\(error)"))
            }
        }
    }

    private static func fingerprint(_ plan: CarouselPlan) -> String {
        let data = (try? JSONCoding.encoder.encode(plan.slides)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Steps

    private func triage(_ input: DirectorInput, _ out: inout DirectorOutput) async -> [AssetID: TriageScore] {
        guard let prompt = load("triage.system", &out) else { return [:] }
        var result: [AssetID: TriageScore] = [:]
        var pending = input.shortlist.filter { $0.triageJPEG != nil }
        for attempt in 0..<2 where !pending.isEmpty {
            var content: [ContentPart] = []
            if let hint = input.storyHint { content.append(.text("The owner describes this post as: \"\(hint)\". Treat it as the primary brief: what the post is about, who and what matters, and anything they want left out.")) }
            content.append(.text("Event: \(input.storyLabel) (\(input.dateSpan)). \(pending.count) candidate photos follow."))
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
        let target = input.exactSet ? "The requested slide count is handled by grouping during composition; keep every candidate in the spine."
            : input.requestedSlides.map { "Target exactly \($0) photos in the spine unless fewer strong photos exist." }
                ?? "Choose the length yourself: usually 8-12, fewer if the pool is weak."
        let constitution = stylePack.constitution ?? Self.defaultConstitution
        var content: [ContentPart] = [.text("""
        Event: \(input.storyLabel) (\(input.dateSpan)). \(pool.count) candidates, listed best-first by a local ranking (which is only a hint).
        \(target)
        Taste constitution:\n\(constitution)
        \(stylePack.trendNotes.map { "Trend notes:\n" + $0.map { "- " + $0 }.joined(separator: "\n") } ?? "")
        Available decorationIDs: \(stylePack.decorationIDs.joined(separator: ", ")).
        Style hints: \(stylePack.promptHints.joined(separator: " "))
        """)]
        if input.exactSet {
            content.insert(.text("The owner selected this exact set: use every candidate exactly once in the spine and every direction. Decide their order, cover and directions." + (input.keepOrder ? " Preserve the listed input order in the spine and every direction; choose only the cover and styles." : "")), at: 0)
        }
        if input.allowMultiEventRecap {
            content.insert(.text("The owner explicitly chose one story across all detected occasions. A multi-event recap is allowed; keep transitions honest and include only photos that support that recap."), at: 0)
        }
        if let hint = input.storyHint {
            content.insert(.text("The owner describes this post as: \"\(hint)\". Treat it as the primary brief: what the post is about, who and what matters, and anything they want left out."), at: 0)
        }
        for (i, id) in pool.enumerated() {
            guard let card = cards[id] else { continue }
            var line = "id \(id.rawValue): \(card.summary)"
            if let t = triage[id] {
                line += " | emotional \(t.emotionalValue)/5, imperfection \(t.imperfection)"
                if !t.tags.isEmpty { line += ", tags \(t.tags.joined(separator: " "))" }
                if !t.safety.isEmpty { line += ", SAFETY \(t.safety.joined(separator: " "))" }
            }
            if !card.localFlags.isEmpty { line += " | SAFETY \(card.localFlags.joined(separator: " ")) (never use as a cover)" }
            content.append(.text(line))
            if i < min(input.maxPlanningImages, PlannerExperiment.maxImages), let jpeg = card.planningJPEG {
                content.append(.image(jpeg: jpeg, assetID: id, detail: PlannerExperiment.detail))
            }
        }
        return content
    }

    private static let defaultConstitution = """
- Good composition requires hierarchy.
- Not every photo needs decoration.
- Not every slide should have the same density.
- Imperfection can carry emotional value; repeated perfection feels artificial.
- A carousel should respond to its particular photos.
- Surprise is valuable when coherent.
- Avoid recognizable template fingerprints.
- Do not optimize every image for generic beauty.
- Random images (signs, food, details) can provide rhythm and personality.
- Whitespace is an active compositional element.
- A cover should create interest, not merely maximize aesthetic score.
- Different directions must differ structurally.
- A plain photo can outperform a designed slide. Design must earn its presence.
"""

    /// Spine validity dominates, then the number of valid directions, then fewer issues.
    static func quality(_ response: PlannerResponse, _ issues: [ValidationIssue]) -> (Int, Int, Int) {
        let spineOK = !issues.contains { $0.direction == nil && $0.path.hasPrefix("spine") && $0.path != "spine.cover" }
        let broken = Set(issues.compactMap(\.direction))
        return (spineOK ? 1 : 0, response.directions.indices.filter { !broken.contains($0) }.count, -issues.count)
    }

    /// Moves the first unflagged photo to the front so a flagged face is never the cover.
    static func safeCover(_ spine: SelectionSpine, flagged: Set<AssetID>) -> SelectionSpine {
        guard let cover = spine.coverAssetID, flagged.contains(cover),
              let i = spine.orderedAssetIDs.firstIndex(where: { !flagged.contains($0) }) else { return spine }
        var s = spine
        s.orderedAssetIDs.insert(s.orderedAssetIDs.remove(at: i), at: 0)
        return s
    }

    /// Sets the spine (the model's, or a deterministic fallback) and returns the directions that passed validation.
    private func assemble(_ response: PlannerResponse?, issues: [ValidationIssue], input: DirectorInput,
                          cards: [AssetID: CandidateCard], flagged: Set<AssetID>, _ out: inout DirectorOutput) -> [Direction] {
        // A flagged cover alone is fixable locally; any other spine issue means the model's story is unusable.
        let spineOK = response != nil && !issues.contains { $0.direction == nil && $0.path.hasPrefix("spine") && $0.path != "spine.cover" }
        var spine: SelectionSpine
        if spineOK, let response {
            spine = response.spine
            if input.keepOrder { spine.orderedAssetIDs = out.pool; spine.sequenceIntent = out.pool.map { _ in response.spine.sequenceIntent.first ?? .build } }
        } else {
            let n = input.exactSet ? out.pool.count : min(input.requestedSlides ?? 10, out.pool.count)
            let ids = input.exactSet && input.keepOrder ? Array(out.pool.prefix(n)) : Array(out.pool.prefix(n)).sorted {
                (cards[$0]?.capturedAt ?? .distantFuture, $0) < (cards[$1]?.capturedAt ?? .distantFuture, $1)
            }
            spine = SelectionSpine(orderedAssetIDs: ids, sequenceIntent: ids.map { _ in .build }, rationale: [])
            out.warnings.append("used deterministic fallback spine (top-ranked photos in time order)")
        }
        if !input.keepOrder { spine = Self.safeCover(spine, flagged: flagged) }
        out.spine = spine
        out.recommendedSlideCount = spine.orderedAssetIDs.count

        guard spineOK, let response else {
            out.unavailable["directions"] = response == nil ? "planner produced no usable response" : "the model's selection spine was invalid"
            out.status = "fallback"
            return []
        }
        let broken = Set(issues.compactMap(\.direction))
        let valid = response.directions.enumerated().filter { !broken.contains($0.offset) }.map(\.element)
        if !broken.isEmpty { out.unavailable["directions"] = "\(broken.count) of \(response.directions.count) invalid after repair/retry" }
        out.status = valid.isEmpty ? "fallback" : broken.isEmpty ? "ok" : "partial"
        return valid
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
                                          schema: schema, reasoning: reasoning,
                                          maxOutputTokens: Self.maxOutputTokens(for: stage))
            record.inputTokens = r.usage.input; record.cachedTokens = r.usage.cached
            record.outputTokens = r.usage.output; record.reasoningTokens = r.usage.reasoning
            record.imageCount = r.imageCount; record.thumbnailBytes = r.imageBytes
            record.latencySeconds = r.latencySeconds; record.retryCount = r.retryCount
            record.estimatedCost = Pricing.estimate(r.usage); record.ok = true; record.responseID = r.responseID
            out.calls.append(record)
            out.exchanges.append(Exchange(name: "\(out.exchanges.count + 1)-\(stage)", request: r.redactedRequest, response: r.rawResponse))
            return r.outputText
        } catch let f as CallFailure {
            record.inputTokens = f.usage.input; record.cachedTokens = f.usage.cached
            record.outputTokens = f.usage.output; record.reasoningTokens = f.usage.reasoning
            record.imageCount = f.imageCount; record.thumbnailBytes = f.imageBytes
            record.latencySeconds = f.latencySeconds; record.retryCount = f.retryCount
            record.estimatedCost = Pricing.estimate(f.usage); record.error = f.description
            out.calls.append(record)
            out.exchanges.append(Exchange(name: "\(out.exchanges.count + 1)-\(stage)", request: f.redactedRequest, response: f.rawResponse))
            out.warnings.append("\(stage) call failed: \(f)")
            return nil
        } catch {
            record.error = "\(error)"
            out.calls.append(record)
            out.warnings.append("\(stage) call failed: \(error)")
            return nil
        }
    }

    /// Leaves ample headroom above the largest observed completed response while preventing
    /// an accidental default of 16k tokens from extending a constrained JSON call.
    private static func maxOutputTokens(for stage: String) -> Int {
        switch stage {
        case "triage", "triage-repair", "repair": return 5_000
        case "planner", "retry": return 8_000
        default: return 8_000
        }
    }

    private func decode(_ text: String, pool: [AssetID], flagged: Set<AssetID>, requested: Int?, exactSet: Bool, keepOrder: Bool) -> (PlannerResponse?, [ValidationIssue]) {
        do {
            var r = try JSONDecoder().decode(PlannerResponse.self, from: Data(text.utf8))
            r.recommendedSlideCount = r.spine.orderedAssetIDs.count
            if keepOrder {
                r.spine.orderedAssetIDs = pool
                r.spine.sequenceIntent = pool.map { _ in r.spine.sequenceIntent.first ?? .build }
                for i in r.directions.indices { r.directions[i].orderedAssetIDs = pool }
            }
            return (r, PlanValidator.validate(r, pool: pool, flagged: flagged, requestedSlides: requested, exactSet: exactSet, keepOrder: keepOrder))
        } catch {
            return (nil, [ValidationIssue(path: "json", message: "could not decode: \(error)")])
        }
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

private struct JudgeEnvelope: Decodable { let ranking: [String]; let reasons: [String] }
private enum JudgeError: Error { case invalid }

/// Latency experiment overrides (docs/reviews/2026-09-27-director-latency.md). Read from the environment on the
/// Mac CLI only; unset means production behaviour (medium reasoning, high-detail images, the input's image cap).
enum PlannerExperiment {
    static var reasoning: String { value("AK14_PLANNER_REASONING", allowed: ["low", "medium", "high"]) ?? "medium" }
    static var detail: String { value("AK14_PLANNER_DETAIL", allowed: ["low", "high", "auto"]) ?? "high" }
    static var maxImages: Int { ProcessInfo.processInfo.environment["AK14_PLANNER_MAX_IMAGES"].flatMap(Int.init) ?? .max }
    private static func value(_ key: String, allowed: Set<String>) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { allowed.contains($0) ? $0 : nil }
    }
}

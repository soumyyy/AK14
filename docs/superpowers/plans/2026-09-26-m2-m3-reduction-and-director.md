# M2 + M3 — Candidate Reduction and Art Director Implementation Plan

> **For agentic workers:** Execute inline (superpowers:executing-plans). Per the user, there are **no unit tests**. Verify with builds, end-to-end tests (`Tests/CLITests`), and real runs on `IMG/`. Steps use checkbox syntax.

**Goal:** `ak14 run IMG` reduces the event to a triage shortlist (M2). It then calls GPT-6 Luna twice: a triage pass and one planning pass. The planning pass returns a shared selection spine plus Plain Dump, Designed and Wildcard plans. The plans are validated, repaired or fallen back as needed, the Plain Dump is rendered to PNG slides, and cost, latency, rejects and plans all go into the report (M3).

**Architecture:** Algorithms that need no Apple frameworks go in `Core`:
- clustering over a precomputed distance list
- junk rules
- ranking
- diversity selection
- plan schema, validation and deviation metrics

The feature-print distances and a new sharpness feature go in `Analysis`. The new `Director` module holds the OpenAI Responses client, prompts, the triage and planner calls, and repair. The new `Render` module holds the minimal Plain Dump renderer and the StylePack loader. `CLI` composes all of them.

**Tech Stack:** Swift 6.4, macOS 27, Vision, ImageIO, Core Graphics, URLSession, OpenAI Responses API (`gpt-6-luna`, strict `json_schema`, `input_image` data URLs). No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-26-ak14-phase0-design.md`:
- §4.4 clustering
- §4.5 junk
- §4.6 safety
- §5 reduction
- §6 Director
- §9.3–9.4 artifacts and report
- §10.3–10.4 provider failures and invalid plans
- §12 M2/M3

## Global Constraints

- Everything from the M1 plan still holds: module rules, no absolute paths or GPS in artifacts, atomic JSON, no AI attribution in commits.
- `Core` imports Foundation only. `Director` imports Foundation only; it gets thumbnails as JPEG bytes from the CLI. `Render` may use Core Graphics and ImageIO.
- Model ID: `gpt-6-luna`. Pricing (2026-09) is $0.10 per 1M input tokens, $0.01 per 1M cached input and $0.50 per 1M output. Prices are pinned in `Director/Pricing.swift` with a `pricingVersion`.
- API key comes from the `OPENAI_API_KEY` environment variable, or `.env` in the working directory. It is never logged, written, or passed on the command line.
- Soft cost warning at $0.50 per run. It never blocks the run.
- Near-duplicate edge: distance ≤ 0.10 and Δt ≤ 90 s. Shot-group edge: distance ≤ 0.30 and Δt ≤ 10 min. Both are calibrated on `IMG/` (random pairs have a median of ≈1.04). A cluster's temporal span is capped at 15 min.
- Triage can move a photo's score by at most ±20%. The exploration fraction is 20% of the shortlist.
- Plain Dump:
  - It follows the spine exactly, one photo per slide.
  - Each slide uses the `full_bleed` or `hero` primitive, with no decorations and no stamps.
- Designed and Wildcard can only use the six Phase 0 primitives, and decorations from the pinned StylePack.
- Text is date/location stamps only. The model never supplies literal text.
- Retry limits:
  - At most 1 repair call, then 1 full planner retry, then fallback.
  - At most 1 diversity mutation call.
  - At most 2 transport retries with jittered backoff. No retry on 401/403.
- Raw LLM I/O is persisted in `llm/` with base64 images replaced by `{"thumbnail": "<assetID>"}` references.

## Review Focus

1. **No API key, or `--no-llm`:** the run completes the M2 reduction, and the report says the concepts were skipped. The run does not crash.
2. **The model returns asset IDs that were never sent,** or duplicates, or too few slides: the validator rejects it, repair is attempted, and the fallback Plain Dump is still rendered.
3. **A folder smaller than 5 usable photos:** the recommended length shrinks and the run does not fail.
4. **All photos missing capture dates:** clustering uses visual similarity only, and time bins fall back to source order.
5. **Provider returns 429 or 5xx, then success:** retried within limits; the retry count is recorded in telemetry.

---

## File Structure

```text
Sources/Core/
  Reduction/ReductionConfig.swift     thresholds + weights (versioned "reduction-1")
  Reduction/Clustering.swift          ShotCluster, PairDistance, ShotClusterer
  Reduction/JunkFilter.swift          JunkDisposition, JunkFilter
  Reduction/Ranker.swift              RankComponents, RankedCandidate, CandidateRanker
  Reduction/DiversitySelector.swift   greedy marginal-gain selection + exploration
  Reduction/ReductionResult.swift     funnel counts, shortlist, planning pool
  Plan/PlanModels.swift               SelectionSpine, CarouselPlan, SlidePlan, elements, enums
  Plan/PlanValidator.swift            semantic validation (§6.4)
  Plan/PlanMetrics.swift              deviations vs spine, pairwise concept diversity (§6.5)
  Plan/StylePack.swift                StylePack model (loaded by Render)
  Telemetry.swift                     ProviderCallRecord
  (modify) Features.swift             + sharpness
  (modify) RunManifest.swift          + reduction/director summary, provider calls
  (modify) Report.swift               + funnel, clusters, rejects, concepts, cost table
Sources/Analysis/
  (modify) VisionAnalyzer.swift       + sharpness (Laplacian variance), version vision-2
  FeaturePrintIndex.swift             loads cached prints; distances for time-neighbours / on demand
Sources/Director/
  ResponsesClient.swift               URLSession transport protocol + OpenAI implementation, retries
  Pricing.swift                       cost estimate
  Prompts.swift                       loads versioned prompt resources
  Resources/Prompts/triage.system.md
  Resources/Prompts/planner.system.md
  Resources/Prompts/repair.system.md
  Resources/Prompts/mutation.system.md
  Schemas.swift                       strict JSON schemas (triage, planner)
  Triage.swift                        TriageInput/TriageResult + call + validation
  Planner.swift                       PlanningInput + call + decode + repair/retry/fallback + mutation
  ArtDirector.swift                   orchestrates triage → pool → planning; returns DirectorOutput
Sources/Render/
  Resources/StylePacks/starter.json
  StylePackLoader.swift
  PlainRenderer.swift                 full-bleed face/saliency-safe crop → PNG
Sources/CLI/
  (modify) Arguments.swift            --slides N, --no-llm; `rerender <runDir>`
  (modify) RunPipeline.swift          stages: reduce → triage → pool → plan → render
  Env.swift                           .env loader
Tests/CLITests/
  ReductionE2ETests.swift             bursts, black frame, no-llm run
  DirectorE2ETests.swift              scripted transport: happy path, bad IDs → repair, garbage → fallback, 429 retry
```

---

### Task 1: Sharpness feature and feature-print distances (M2)

**Files:**
- Modify: `Sources/Core/Features.swift`, `Sources/Analysis/VisionAnalyzer.swift`
- Create: `Sources/Analysis/FeaturePrintIndex.swift`

**Interfaces:**
- Produces:
  - `PhotoFeatures.sharpness: Double?`: variance of a 3×3 Laplacian on a 256 px gray downsample, normalized by dividing by 1000 and clamping to 0…1.
  - `VisionAnalyzer.version = "vision-2"`
  - `FeaturePrintIndex(cacheRoot:features:)`, where `features: [AssetID: PhotoFeatures]` supplies each photo's `featurePrintFile`
  - `FeaturePrintIndex.distance(_:_:) -> Double?`, lazily loaded and memoized
  - `FeaturePrintIndex.neighbourDistances(order: [AssetID], window: Int) -> [PairDistance]`: all pairs within `window` positions of each other in capture order

- [ ] Add `sharpness` to `PhotoFeatures`. Compute it in `ImageStats.sharpness(of:)`: draw into a 256×256 gray context, apply the Laplacian kernel `[0,1,0;1,-4,1;0,1,0]`, take the variance, divide by 1000 and clamp to 0…1.
- [ ] Bump the analyzer version to `vision-2`. The cache key changes, so the first run re-analyzes (~11 s on `IMG/`).
- [ ] Implement `FeaturePrintIndex`. It decodes `FeaturePrintObservation` from `cacheRoot/featurePrintFile` and memoizes, keyed by `AssetID`. A missing print returns nil distance.
- [ ] Build: `swift build`.

### Task 2: Clustering, junk filter, ranking, diversity (M2)

**Files:** `Sources/Core/Reduction/*`

**Interfaces:**
- `ReductionConfig` (Codable, `version = "reduction-1"`). Defaults:
  - `dupDistance 0.10`, `dupSeconds 90`
  - `shotDistance 0.30`, `shotSeconds 600`, `maxClusterSpanSeconds 900`
  - `neighbourWindow 12`
  - weights `usability 0.25, people 0.15, saliency 0.15, aesthetic 0.10, semantic 0.15, distinctiveness 0.10, userSignal 0.10`
  - `explorationFraction 0.2`, `triageMaxAdjustment 0.2`
- `PairDistance(a: AssetID, b: AssetID, distance: Double)`
- `ShotCluster(clusterID, memberAssetIDs, representativeAssetID, kind: .single | .nearDuplicate | .shotGroup, distanceRange, captureSpanSeconds)`
- `ShotClusterer.cluster(photos:features:distances:config:) -> [ShotCluster]`. The algorithm:
  1. Sort photos by `capturedAt`. Photos with no date go last, in `sourceRelativePaths` order.
  2. Walk that order. Each photo tries to join the cluster of its best matching earlier photo within the neighbour window.
  3. A match is either a dup edge (d ≤ dupDistance and Δt ≤ dupSeconds) or a shot edge (d ≤ shotDistance and Δt ≤ shotSeconds). When either time is unknown, a shot edge requires d ≤ dupDistance.
  4. The match must also be within `shotDistance` of that cluster's representative (medoid check), so chains can't drift.
  5. Joining must not push the cluster's time span past `maxClusterSpanSeconds`.
  6. The kind is `.nearDuplicate` if all edges were dup edges, otherwise `.shotGroup`.
  7. The representative is the member with the best `technicalScore`: 0.5·sharpness + 0.3·(faceQuality mean, or 0.5 if no faces) + 0.2·aesthetic01. Ties break on assetID.
- `JunkDisposition(assetID, verdict: .keep | .penalize | .reject, reasons: [String])`
- `JunkFilter.classify(photo:features:) -> JunkDisposition`:
  - **reject:** `blackFrame` (darkFraction > 0.97 and meanLuminance < 0.04); `pocketShot` (darkFraction > 0.85 and sharpness < 0.02 and no faces or salient regions); `extremeBlur` (sharpness < 0.005 and no faces and no salient region with area > 0.05)
  - **penalize:** `utility` (isUtility and not a screenshot of event content, meaning isUtility is true); `screenshot`; `lowSharpness` (< 0.03); `veryDark` (darkFraction > 0.8); `lowAesthetic` (< -0.3)
  - Everything else is `keep`. Flash, blur with a subject, food and signs are never rejected.
- `RankComponents` holds all seven components (0…1), plus `penalty` (0…0.5) and `base` (the weighted sum minus the penalty):
  - **usability:** 0.6·min(1, sharpness/0.15) + 0.4·(1 − darkFraction)
  - **people:** 0 with no faces, otherwise 0.5 + 0.5·mean(captureQuality), plus 0.1 for groups of 3 or more, capped at 1
  - **saliency:** largest salient area mapped to 0…1 (area/0.4, capped)
  - **aesthetic:** (score + 1)/2
  - **semantic:** 0.4 baseline, +0.3 if a top-3 label is in {food, sign, text, drink, animal, vehicle, building, night_sky, fireworks, concert}, +0.3 if the photo's top label is rare in the event (appears on fewer than 5% of photos)
  - **distinctiveness:** 1 − min(1, clusterSize/10)
  - **userSignal:** 0; there are no favorites in folder mode
  - Missing features redistribute their weight across the components that are present.
- `RankedCandidate(assetID, clusterID, components, score, triage: TriageScore?, adjustedScore)`
- `CandidateRanker.rank(representatives:features:clusters:junk:config:) -> [RankedCandidate]`, sorted by score descending with assetID as the tie-break
- `DiversitySelector.select(ranked:target:photos:features:distance:config:) -> [RankedCandidate]`:
  - Time bins: split the capture span into `clamp(target/8, 6, 12)` equal bins. Undated photos use position in source order.
  - People bucket: 0 / 1 / 2–3 / 4+ faces.
  - Scene key: the top label.
  - Greedy loop: `marginal = score + 0.15·newTimeBin + 0.08·newPeopleBucket + 0.10·newScene − 0.25·maxSimilarityToSelected`, where similarity = max(0, 1 − distance/0.6).
  - Fill `(1 − explorationFraction)` of the target greedily. Fill the rest from lower-ranked candidates, taking the ones with the largest coverage gain (score weight 0.3).
- `ReductionTargets.forUsable(_ n: Int, slides: Int?) -> (triage: Int, planning: ClosedRange<Int>)`, per spec §5.1:
  - n < 50: triage = all, planning = 20…40
  - n ≤ 200: triage ≤ 60, planning = 25…45
  - n ≤ 600: triage = 60…80 (use 70), planning = 30…50
  - larger: triage = 90, planning = 35…60
  - Clamp everything to n.
- `ReductionResult`: `config`, `clusters`, `junk`, `ranked`, `shortlist` (for triage), `planningPool`, and `funnel` with ingested, junkRejected, representatives, shortlisted, triaged, planningPool and selected.

- [ ] Implement the files above.
- [ ] Build.

### Task 3: M2 pipeline stage, report sections, and `--no-llm` (M2)

**Files:** `Sources/CLI/Arguments.swift`, `Sources/CLI/RunPipeline.swift`, `Sources/Core/RunManifest.swift`, `Sources/Core/Report.swift`, `Tests/CLITests/ReductionE2ETests.swift`, `Tests/TestSupport/FixtureFactory.swift`

- [ ] Add `--slides N` (5…20) and `--no-llm` to the arguments, plus a `rerender <runDir> --source <folder>` command that is wired in Task 7.
- [ ] Add a `reduction` stage to the pipeline after analysis:
  1. Build the neighbour distances.
  2. Cluster, run the junk filter, and rank the cluster representatives, excluding rejects.
  3. Select the shortlist.
  4. Write `cache/reduction.json`.
  5. Record `versions["reduction"]`.
- [ ] Add report sections:
  - the funnel table
  - the shortlist contact sheet with rank components and the reason each photo entered (top component or exploration)
  - clusters with size and representative
  - a rejected contact sheet with reasons
  - penalized badges
- [ ] Extend `FixtureFactory.writeJPEG` with a `pattern: Int` parameter (draws the block at a different position, so visually distinct scenes can be made) and a `date` argument.
- [ ] Write the e2e test `reductionClustersBurstsAndRejectsBlackFrames`:
  - Fixtures: 3 near-identical frames 1 s apart, 1 unrelated frame, 1 black frame, and 2 distinct patterns.
  - Expected: one cluster of 3, the black frame rejected with `blackFrame`, the shortlist excludes the rejected photo and holds one representative per cluster, and the report contains "blackFrame".
- [ ] Write the e2e test `noLLMRunStopsAfterReduction`: with `--no-llm`, the manifest's `directorStatus` is `"skipped: --no-llm"` and there's no `llm/` directory.
- [ ] Run `swift test` and `ak14 run IMG --no-llm`, and inspect the funnel and shortlist in the report.

### Task 4: Director transport, pricing, prompts, schemas (M3)

**Files:** `Sources/Director/{ResponsesClient,Pricing,Prompts,Schemas}.swift`, `Sources/Director/Resources/Prompts/*.md`, `Package.swift` (the Director target with `resources: [.copy("Resources")]` and the Render target)

**Interfaces:**
- `protocol ResponsesTransport: Sendable { func send(_ body: Data) async throws -> (status: Int, body: Data) }`
- `OpenAITransport(apiKey:timeout:)`, which POSTs to `https://api.openai.com/v1/responses`
- `ResponsesClient(transport:model:log:)` with `call(system:content:schemaName:schema:reasoning:maxOutputTokens:) async throws -> ResponsesResult`. The result has `outputText`, `usage` (input, cached, output and reasoning tokens), `responseID`, `latencySeconds` and `retryCount`. Retries: on 429, 5xx and URLError timeouts, wait 1 s then 3 s with ±30% jitter. It throws `DirectorError.auth` on 401/403, `.http(code, message)`, `.incomplete` (status ≠ completed) and `.refusal`.
- `ContentPart` is `.text(String)` or `.image(jpeg: Data, assetID: AssetID, detail: "low" | "high")`.
- `Pricing.estimate(usage) -> Double` and `Pricing.version = "openai-2026-09"`.
- `Prompts.load(_ name:) -> (text, version)`. Each prompt file's first line is `<!-- prompt: triage v1 -->`; the version comes from that header plus the SHA-256 prefix of the content.
- `Schemas.triage` and `Schemas.planner` are `[String: Any]`-free: they're built as `JSONValue` (a small Codable enum in Director) so they encode deterministically.
  - All objects are strict with `additionalProperties: false`, and every property is required.
  - **Triage:** `{results: [{id, emotionalValue: int 0–5, imperfection: useful|neutral|accident, safety: [blink|unflattering|awkwardCrop|sensitive], tags: [people|group|selfie|food|drink|sign|text|venue|detail|landscape|architecture|night|flash|motion|mirror|animal|vehicle|nature|celebration], confidence: low|medium|high}]}`
  - **Planner:** `{recommendedSlideCount: int, spine: {orderedAssetIDs: [string], sequenceIntent: [opener|build|peak|breather|detail|closer], rationale: [{id, reason: cover|emotional|story|variety|detail|people|place}]}, plans: [{conceptType: plainDump|designed|wildcard, conceptNote: string, slides: [{primitive: full_bleed|hero|framed_hero|inset|asymmetric_pair|overlap_cluster, mood: calm|warm|energetic|nostalgic|playful|moody, density: quiet|balanced|dense, photos: [{assetID, role: hero|support|detail, importance: int 1–3, cropIntent: tight|balanced|loose, anchorIntent: center|top|bottom|left|right, overlapIntent: none|slight|strong, rotationIntent: none|slightLeft|slightRight}], decorations: [{decorationID: <StylePack IDs enum>, intensity: low|medium|high}], stamps: [{kind: date|location, placement: topLeft|topRight|bottomLeft|bottomRight}]}]}]}`
- Prompt content:
  - **`triage.system.md`:** preserve useful imperfection; don't equate beauty with story value; flag social risks for other people's faces; use only the listed tags; never invent content; score emotional value relative to this event.
  - **`planner.system.md`:** the full Taste Constitution; the spine rules (cover first; no padding; the recommended count must be ≤ the requested count when the pool is weak); Plain = the spine exactly, one photo per slide, full_bleed or hero, no decorations or stamps; Designed = strongly designed but content-compatible; Wildcard = coherent risk, structurally different from Designed; hierarchy and varied density; decorations only from the list; no coordinates, no captions; don't make every slide decorated; don't use a socially flagged face as the hero when an alternative exists.
  - **`repair.system.md`:** fix only the listed validation errors, keep everything else, and return the full JSON.
  - **`mutation.system.md`:** make the Wildcard structurally different on the named dimensions, keep the spine, and return the full JSON.

- [ ] Implement the files above.
- [ ] Build.

### Task 5: Triage and planning calls with validation, repair, and fallback (M3)

**Files:** `Sources/Director/{Triage,Planner,ArtDirector}.swift`, `Sources/Core/Plan/*`, `Sources/Core/Telemetry.swift`

**Interfaces:**
- Plan models: the Core Codable mirrors of the planner schema are `SelectionSpine`, `CarouselPlan` (with `conceptType`, `conceptNote`, `slides`, and the computed `photoAssetIDs`), `SlidePlan`, `PhotoElement`, `DecorationElement`, `StampElement`, and the enums `Primitive`, `ConceptType`, …
- `PlannerResponse { recommendedSlideCount, spine, plans }`.
- `PlanValidator.validate(response:pool:requestedSlides:stylePack:safety:) -> [ValidationIssue]`. Rules:
  - exactly 3 plans with unique concept types
  - spine IDs are unique and within the pool, and the count is in 5…20 (or equal to the pool size when the pool has fewer than 5)
  - `sequenceIntent.count` equals the spine count
  - Plain matches the spine order exactly, with one photo per slide, primitive `full_bleed` or `hero`, and no decorations or stamps
  - every photo ID is in the pool, with no repeats within a plan
  - photos per slide by primitive: full_bleed, hero and framed_hero have 1; inset and asymmetric_pair have 2; overlap_cluster has 2–4
  - every slide count is in 5…20
  - decoration IDs are in the StylePack
  - no plan's first-slide hero is a safety-flagged photo while an unflagged photo exists in that plan
- `ValidationIssue(path, message)`, which is encoded into the repair prompt.
- `PlanMetrics.deviation(plan:spine:) -> Deviation`, with `added`, `removed`, `coverChanged`, `orderSimilarity` (Kendall tau over shared IDs), and `slideCount`.
- `PlanMetrics.diversity(a:b:) -> ConceptDistance`, with `jaccard`, `sameCover`, and `structuralDiffs` (primitive mix, single/multi ratio > 0.2 apart, density sequence, decoration profile).
  - It passes when `!sameCover && (jaccard ≤ 0.8 || orderSimilarity < 0.5) && structuralDiffs ≥ 2`.
  - It's checked only for Designed vs Wildcard.
- `ProviderCallRecord(stage: triage|planner|repair|retry|mutation, model, promptVersion, inputTokens, cachedTokens, outputTokens, reasoningTokens, imageCount, thumbnailBytes, latencySeconds, retryCount, estimatedCost, candidateCount, conceptCount, ok, error?)`.
- `ArtDirector(client:stylePack:log:)` with `direct(_ input: DirectorInput) async -> DirectorOutput`:
  - **Input:** `storyLabel`, `dateSpan`, `requestedSlides?`, `shortlist: [CandidateCard]` (id, compact feature summary, capture time, cluster size, triageThumb JPEG, planningThumb JPEG), the reduction config, and a `poolSelector` closure (adjusted ranking → planning pool).
  - **Flow:**
    1. Triage the whole shortlist (160 px, detail low).
    2. Validate that the returned IDs equal the sent IDs. On mismatch, run one repair; on failure, continue local-only with a warning.
    3. Apply the adjustment: `adj = clamp(0.2·(emotional − 2.5)/2.5 + (useful ? 0.05 : accident ? −0.2 : 0), −0.2, 0.2)`, `adjustedScore = score·(1 + adj)`.
    4. Select the planning pool.
    5. Planner call: text cards for the whole pool, plus images (384 px, detail high) for the top 24 by adjusted score.
    6. Validate.
    7. If invalid, send one repair call with the issues and the original JSON (no images), and re-validate.
    8. If still invalid, retry the planner once with the same payload plus "previous attempt was invalid: <issues>".
    9. If still invalid, fall back: use the spine if it's valid on its own; otherwise build a deterministic spine from the top-ranked pool photos, `targetSlides` of them, in time order. Build a Plain plan from it and mark Designed and Wildcard unavailable.
    10. If Designed and Wildcard fail the diversity check, send one mutation call and re-validate. If that fails, keep the originals and add a warning.
  - **Output:** `triage: [AssetID: TriageScore]`, `planningPool`, `spine`, `plans` (valid ones only), `unavailable: [ConceptType: String]`, `deviations`, `diversity`, `calls: [ProviderCallRecord]`, `warnings`, `rawExchanges` (redacted request/response JSON per call).
- Target slides: `requestedSlides` if given, otherwise the model's `recommendedSlideCount` clamped to 5…min(20, pool). The prompt asks for 8–12 unless the pool is weak.

- [ ] Implement the files above.
- [ ] Build.

### Task 6: Minimal Plain Dump renderer and StylePack (M3)

**Files:** `Sources/Render/{StylePackLoader,PlainRenderer}.swift`, `Sources/Render/Resources/StylePacks/starter.json`, `Sources/Core/Plan/StylePack.swift`

**Interfaces:**
- `StylePack` (spec §3.8 fields). The starter pack is `starter-editorial` v1.0.0 with decoration IDs `grain-fine`, `paper-warm`, `tape-clear`, `film-edge`, `date-stamp`, and the six primitive weights. Asset files come in M4, so M3 only needs the IDs.
- `StylePackLoader.load(id:) throws -> StylePack` reads it from the bundle.
- `PlainRenderer(version: "plain-1")` with `render(plan:aspect:photos:features:sourceFolder:to:) throws -> [String]`, which returns relative PNG paths `slides/plainDump/slide-NN.png`.
  - Decode the original at a maximum long edge of `2 × canvas long edge`, with the transform applied.
  - Cover-crop to the canvas aspect.
  - The focus rect is the union of face boxes when there are faces, otherwise the largest salient region, otherwise the center.
  - Position the crop window so the focus rect's center sits at the crop center, clamped inside the image.
  - If the focus rect is larger than the crop in a dimension, keep the top edge for faces and the center otherwise.
  - Draw into a 1080×H sRGB context with high interpolation quality.
  - Write an sRGB PNG, deterministic: no randomness, fixed interpolation.

- [ ] Implement the files above.
- [ ] Build.

### Task 7: Wire M3 into the pipeline, report, rerender, e2e (M3)

**Files:** `Sources/CLI/{RunPipeline,Env,AK14Command,ReportCommand}.swift`, `Sources/Core/{RunManifest,Report}.swift`, `Tests/CLITests/DirectorE2ETests.swift`

- [ ] **Env:** read `OPENAI_API_KEY` from the process environment, falling back to `.env` in the working directory (`KEY=value` lines; ignore comments; strip quotes).
- [ ] **Pipeline:** after reduction, unless `--no-llm` or there's no key (then `directorStatus = "skipped: <reason>"`):
  1. Build candidate cards: triage- and planning-tier thumbnails via the Thumbnailer, feature summaries, capture times and cluster sizes.
  2. Run the ArtDirector.
  3. Write `llm/*.json` (redacted), `plans/selection-spine.json`, `plans/<conceptType>.json` and `plans/director.json` (triage, deviations, diversity, unavailable, warnings).
  4. Render Plain.
  5. Record `manifest.providerCalls`, `totalEstimatedCost` (warn if > $0.50), `versions` (director, prompts, pricing, plan schema, style pack, renderer) and `directorStatus`.
- [ ] **Report additions:**
  - a concept section per concept
  - Plain: rendered slides inline, in order
  - Designed and Wildcard: a slide-by-slide list with thumbnails, primitive, mood, density, roles and decorations, plus a note that rendering comes in M4
  - the spine and each concept's deviation from it
  - the diversity result
  - triage flags on shortlist cards
  - a cost and latency table per call, with the total
  - `directorStatus` and warnings
- [ ] **`rerender <runDir> --source <folder>`:** reload the plans, `input-index.json` and features, then re-render Plain from the source folder. Before rendering, check that each photo's content SHA matches, and error if a file changed. Remove only the `slides/` output first. No provider calls.
- [ ] **Scripted transport for e2e tests:** `ScriptedTransport(responses: [(Int, Data)])` in TestSupport. Director tests run the pipeline with injected transport:
  - `happyPathProducesThreeConceptsAndPlainSlides`: a valid scripted triage and planner response built from the actual shortlist IDs, which the test reads from a first `--no-llm` run
  - `invalidIDsTriggerRepairThenValid`
  - `garbageTwiceFallsBackToPlain`: the Plain PNGs still exist and `unavailable` includes designed and wildcard
  - `rateLimitThenSuccessIsRetried`: the retry count is recorded
- [ ] Run `swift test`.

### Task 8: Live run on `IMG/` and exit demo

- [ ] Run `swift build -c release && .build/release/ak14 run IMG`. It exits 0, and the manifest shows `directorStatus: ok`, 2–5 provider calls and a total cost under $0.05.
- [ ] Open the report:
  - the Plain slides render upright with faces in frame
  - the Designed and Wildcard plans are present and differ
  - the cost table is present
  - no absolute paths or coordinates
- [ ] Look at the shortlist and Plain choices by eye. Note in `tasks/todo.md` anything that looks like conventional-aesthetic bias (imperfect but lively shots dropped).
- [ ] Run `.build/release/ak14 rerender <run> --source IMG`. It makes no network calls and produces identical PNG bytes.
- [ ] Update `tasks/todo.md` with a review section, then commit.

---

## Rulings in this plan

- **No full code in the plan:** the plan gives exact interfaces, algorithms, schemas and thresholds, but not full code listings. The user asked for speed and no unit tests, and the executor is the plan author. The cost is a less reviewable plan; the final code review covers it.
- **Thresholds:** 0.10 and 0.30 replace the spec's 0.18 and 0.28, calibrated on real data. The spec explicitly says "calibrate on fixtures".
- **Minimal Plain renderer in M3:** this follows spec §12 M3 ("render a minimal deterministic Plain Dump"). Designed and Wildcard rendering stays in M4.
- **`rerender` takes `--source <folder>`** instead of storing an absolute path. This keeps spec §3.9 (no absolute paths in the manifest). The cost is one extra flag.

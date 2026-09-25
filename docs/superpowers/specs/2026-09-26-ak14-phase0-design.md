# AK14 Phase 0 Design Specification

**Status:** Design draft
**Date:** 2026-09-26
**Scope:** Operator-run macOS validation pipeline
**Audience:** Phase 0 implementation and study team

## 1. Goal and boundaries

### 1.1 Goal

Phase 0 tests whether AK14 can turn one real event folder containing 200–2,000 original photos into three coherent, post-worthy Instagram carousel concepts that reduce selection and art-direction effort while preserving the owner's character.

The pipeline runs on a Mac. The participant or operator supplies one folder per story, with image originals and any embedded EXIF/GPS metadata intact. A run analyzes locally, sends only selected small thumbnails and structured features to the configured multimodal provider, then writes reviewable rendered outputs and an audit report.

Phase 0 is a validation harness, not a polished product. The primary evidence is participants' choices, edits, exports/shares, and (where observable) posts—not compliments or isolated aesthetic scores.

### 1.2 Non-goals

- iOS, TestFlight, PhotoKit library indexing, background work, event discovery, or automatic multi-story splitting.
- Video, Live Photos, generative image replacement, direct Instagram publishing, or a backend.
- Caption writing, arbitrary copy, handwritten text, or user-editable typography.
- A general photo editor, arbitrary canvas/layer editing, or unconstrained drag/resize.
- Neural taste learning, persistent preference profiles, or remote style configuration.
- Automatic upload of originals or bulk photo-library transfer to an API.
- Guaranteeing that a concept will be posted or that it outperforms a participant's own selection.

### 1.3 Success criteria

The Phase 0 study uses the product-spec go/no-go bar in §46. Recruit 12–15 target users with one genuine high-volume event each. At minimum, 50% must select and export/share a pipeline concept without substantially rebuilding it; for n=15, the expected minimum count is 8. Strong signal is at least 33% actually posting within seven days; for n=15, at least 5.

**Proposed operational definition (not resolved):** substantially rebuilding means either more than 30% of the final photos were swapped/removed/replaced from the generated concept, or more than 30% of slides were re-laid-out/regenerated. Track both dimensions separately and use the union as the binary study measure. Report sensitivity at 20% and 40%; do not silently redefine after observing outcomes.

Also report Plain/Designed/Wildcard choice, edit burden, selection quality, story quality, design lift, personal fit, novelty, concept diversity, effort reduction, cost, latency, and volunteered repeat demand. A Plain win is valid evidence, not a product failure.

### 1.4 Phase 0 operating assumptions

- One selected folder equals one story; folder semantics and optional operator notes supply context.
- Source images remain local except for compressed thumbnails explicitly included in triage/planning requests.
- Originals with embedded metadata are preserved for export; derived previews and reports are separate.
- No API key or image payload is written to logs. Raw request/response artifacts are kept in the run directory with access restricted to the operator.
- A user can override the inferred carousel ratio at run time.
- A run may take a few minutes. A soft estimated cost warning appears around $0.50; it never blocks a run.

## 2. Architecture

### 2.1 Package and repository layout

```text
Package.swift
Sources/
  Core/
    Models.swift
    PlanSchema.swift
    PlanValidator.swift
    CandidateReduction.swift
    LayoutResolver.swift
  Analysis/
    Ingest.swift
    Thumbnailer.swift
    VisionAnalyzer.swift
    Clustering.swift
    JunkFilter.swift
  Director/
    ArtDirector.swift
    OpenAIResponsesProvider.swift
    PromptLoader.swift
    PlanRepair.swift
    Resources/Prompts/        # SwiftPM resources must live inside the target
  Render/
    Renderer.swift
    StylePack.swift
    AssetLoader.swift
    Resources/StylePacks/
    Resources/Assets/         # fonts, textures, tape, decorations + manifest.json
  CLI/
    AK14Command.swift
  Studio/
    AK14StudioApp.swift
Tests/
  CoreTests/
  AnalysisTests/
  DirectorTests/
  RenderTests/
runs/                         # ignored; per-run artifacts
```

There is one Swift package, named for the repository/product as needed by SwiftPM, with no third-party dependencies unless a written decision justifies one. Public module names are `Core`, `Analysis`, `Director`, `Render`, `CLI`, and `Studio`; do not prefix module names with `AK14`.

`CLI` and `Studio` are composition roots. `Core` depends on no other package target and imports no Apple imaging framework. `Analysis`, `Director`, and `Render` each depend only on `Core` and never on each other. `CLI` and `Studio` depend on `Core`, `Analysis`, `Director`, and `Render`; nothing depends on `CLI` or `Studio`. If implementation needs a shared interface, put the value/protocol in Core instead of adding a cross-module dependency.

`Analysis` owns Apple Vision, ImageIO, and platform-specific image analysis. `Render` owns Core Graphics/Core Image. Package platforms are macOS 27 for this phase. Keep models and request/response abstractions portable enough for later iOS reuse, but do not add iOS targets or compatibility scaffolding that obscures the Mac pipeline.

### 2.2 Pipeline

```text
folder validation
  → ingest + stable content-hash IDs + incremental cache
  → junk classification + shot/duplicate clustering
  → per-photo local feature extraction
  → rank and diverse shortlist (60–100)
  → TRIAGE call over tiny thumbnails + compact features
  → planning candidate set (30–60)
  → ONE planning call: shared selection spine + Plain Dump + Designed + Wildcard
  → schema/semantic validation; bounded repair/retry
  → deterministic constraint resolution
  → deterministic render from local originals/assets
  → timestamped run directory + report.html
```

The Plain Dump renders the shared selection spine directly: one image per slide, near full-frame, without decoration. Designed and Wildcard can deviate from that spine. Record all deviations in machine-readable form so design lift can be separated from selection lift.

`rerender` must resolve and render persisted validated plans without any provider access. It may use cached analysis outputs and pinned assets. A style or renderer change creates a distinct render result/version rather than overwriting the original run artifacts.

### 2.3 Replaceable interfaces

The following are public module boundaries, shown as illustrative Swift only. Names and exact signatures may be refined while preserving the contracts.

```swift
public protocol PhotoIngesting: Sendable {
    func ingest(folder: URL, options: IngestOptions) async throws -> IngestResult
}

public protocol PhotoAnalyzing: Sendable {
    func analyze(_ photos: [PhotoRecord], cache: AnalysisCache) async throws -> [PhotoFeatures]
}

public protocol CandidateReducing: Sendable {
    func reduce(_ input: ReductionInput) -> ReductionResult
}

public protocol TriageProvider: Sendable {
    func triage(_ request: TriageRequest) async throws -> TriageResponse
}

public protocol PlannerProvider: Sendable {
    func plan(_ request: PlanningRequest) async throws -> PlanningResponse
}

public protocol ArtDirector: Sendable {
    func makeConcepts(_ input: DirectorInput) async throws -> DirectorOutput
}

public protocol LayoutResolving: Sendable {
    func resolve(_ plan: CarouselPlan, context: LayoutContext) throws -> ResolvedCarousel
}

public protocol Rendering: Sendable {
    func render(_ layout: ResolvedCarousel, assets: AssetCatalog,
                to directory: URL) async throws -> [RenderedSlide]
}
```

`ArtDirector` composes the triage provider, planner provider, schema validator, repair policy, and telemetry sink. Provider protocols expose structured outcomes and timing/token metadata, not transport implementation details. The OpenAI implementation uses the Responses API with model ID `gpt-6-luna` (verified against the /v1/models list on 2026-09-26). The model ID is configuration, not code.

### 2.4 Dependency and concurrency rules

- Core contains immutable `Sendable` value types and pure deterministic functions where possible.
- Analysis may depend on Core and Apple imaging frameworks only.
- Director may depend on Core and URLSession/Foundation networking only; no image decoding is required there.
- Render may depend on Core and Core Graphics/Core Image only.
- CLI and Studio never depend on each other; they share behavior only through the library modules. They are separate executable targets.
- Do not make Core import Vision, AppKit, SwiftUI, CoreGraphics, or CoreImage.
- Cache writes use atomic replacement. A run has one writer; read-only report generation may run after pipeline completion.
- Cancellation is cooperative between files, requests, and render slides. Never leave a partially written final PNG presented as complete.

## 3. Data model

Persist schema versions with serialized models. IDs are opaque stable strings. Timestamps use UTC ISO-8601; coordinates are omitted from provider payloads unless explicitly enabled for location stamp generation.

### 3.1 PhotoRecord

One ingested source asset plus local references to derived artifacts.

| Field | Meaning |
|---|---|
| `assetID` | Stable ID from normalized content digest; collision-safe |
| `sourceRelativePath` | Path relative to chosen folder; no absolute path in provider data |
| `contentSHA256` | Digest of original bytes |
| `byteCount`, `fileType` | Source metadata |
| `pixelWidth`, `pixelHeight`, `orientation` | Decoded dimensions/orientation |
| `capturedAt?`, `importedAt` | EXIF capture time where valid and filesystem import time |
| `latitude?`, `longitude?` | Local-only GPS values; scrub from default reports/payloads |
| `isScreenshot?`, `isFavorite?`, `isHidden?` | Available metadata/heuristics; folder import may not provide flags |
| `duplicateClusterID?`, `shotClusterID?` | Cluster references |
| `processingVersion` | Analyzer and pipeline versions used |
| `thumbnailRefs` | Relative paths and tier/dimensions/digest for cached previews |
| `featureRef?` | Reference to cached local feature record |
| `junkDisposition` | Keep, penalize, or reject with reason codes |

### 3.2 ShotCluster

| Field | Meaning |
|---|---|
| `clusterID` | Stable cluster identifier |
| `memberAssetIDs` | All cluster members in deterministic order |
| `representativeAssetID` | Current best representative |
| `duplicateKind` | Exact, near-duplicate burst, or related shot |
| `featurePrintDistanceRange` | Observed distance range |
| `captureInterval?` | First/last known capture time |
| `clusterVersion`, `reasonCodes` | Reproducibility and audit |

Exact duplicate groups and related shot groups remain distinguishable. The planner may select an alternate from a shot cluster when the representative has a blink, crop, or better emotional moment.

### 3.3 Candidate

| Field | Meaning |
|---|---|
| `assetID`, `representativeOf?` | Source identity/cluster relationship |
| `rankScore`, `rankComponents` | Local rank and auditable component scores |
| `diversityContribution` | Time/person/scene coverage contribution |
| `featureSummary` | Compact face, scene, quality, saliency, color, orientation summary |
| `triage?` | Triage score and flags once received |
| `eligibleForPlanning` | Final shortlist gate |
| `exclusionOrPenaltyReasons` | Human-readable report reasons |

### 3.4 TriageResult

| Field | Meaning |
|---|---|
| `assetID` | Candidate image identity |
| `emotionalValue` | Ordinal/normalized score with rationale code, not free-form prose |
| `imperfectionDisposition` | Useful imperfection, neutral, likely accident |
| `socialSafetyFlags` | Blink, unflattering face, severe accidental crop, sensitive context, uncertain |
| `subjectAndMomentTags` | Controlled tags: people, food, sign, venue, detail, etc. |
| `confidence` | Provider confidence bucket |
| `notes?` | Short bounded internal rationale; never rendered as caption |

### 3.5 SelectionSpine

| Field | Meaning |
|---|---|
| `storyID`, `targetSlideCount` | Folder story and target length |
| `orderedAssetIDs` | Baseline selection/order, first item is cover |
| `coverAssetID` | Must equal first spine item |
| `sequenceIntent` | Controlled pacing tags per slide |
| `selectionRationales` | Compact reason codes per asset |
| `omittedCandidateIDs?` | Optional LLM-referenced omissions, validated locally |

### 3.6 CarouselPlan and element models

`CarouselPlan` fields: `planSchemaVersion`, `conceptID`, `conceptType` (`plainDump`, `designed`, `wildcard`), `storyID`, `stylePackID`, `stylePackVersion`, `aspectRatio`, `targetSlideCount`, `slides`, `selectionSpineDigest`, `deviationLog`, `promptVersion`.

`SlidePlan` fields: `slideID`, `primitive`, `mood`, `density` (quiet/balanced/dense), `photoElements`, `decorationElements`, `textElements`, `sequenceIntent`.

`PhotoElement` fields: `assetID`, `role`, `importance`, `cropIntent`, `anchorIntent`, `overlapIntent`, `rotationIntent`, `shotClusterID?`. Intent fields are enums/bounded values, never coordinates.

`DecorationElement` fields: `decorationID`, `role`, `intensity`, `anchorIntent`, `rotationIntent?`. References must exist in the pinned StylePack asset catalog.

`TextElement` fields: `textKind` (`dateStamp` or `locationStamp`), `sourceRef`, `formatKey`, `placementIntent`, `importance`. Text is assembled locally from permitted metadata; the model cannot supply arbitrary text.

### 3.7 ResolvedLayout

`ResolvedLayout` stores `layoutSchemaVersion`, `slideID`, `canvasWidth`, `canvasHeight`, `aspectRatio`, `seed`, and ordered `ResolvedElement` values. Each resolved element stores `elementID`, `assetOrTextRef`, normalized frame, rotation degrees, crop rectangle, z-index, opacity, mask/clip key, and effective margins. Layouts include resolver version and warnings/constraint adjustments.

All coordinates are normalized to canvas dimensions. The renderer uses integer output pixels after deterministic rounding.

### 3.8 StylePack

Fields: `id`, `version`, `active`, `minAppVersion`, `primitiveWeights`, `decorationIDs`, `fontIDs`, `textureIDs`, `allowedRotations`, `overlapRanges`, `spacingRanges`, `colorRules`, `grainRules`, `densityProfile`, `promptHints`, `explorationWeight`, `assetManifestDigest`, `createdAt`, `deprecatedAt?`.

StylePacks are local, versioned resources in Phase 0. A run pins a snapshot and manifest digest; changing a resource later does not alter prior rerenders.

### 3.9 RunManifest

Fields: `runID`, `createdAt`, `completedAt?`, `sourceFolderLabel`, `inputDigest`, `photoCount`, `acceptedCount`, `rejectedCount`, `storyID`, `targetSlideCount`, `aspectRatio`, `userOverrides`, `modelProvider`, `modelID`, `promptVersions`, `stylePackID/version`, `candidatePipelineVersion`, `rankingVersion`, `tasteProfileVersion` (none/disabled in Phase 0), `noveltyVersion` (none/disabled), `analyzerVersion`, `resolverVersion`, `rendererVersion`, `planSchemaVersion`, `costTelemetry`, `stageStatuses`, `warnings`, `artifactIndex`.

Never put API credentials, full absolute source paths, or participant names in the manifest. Use an operator-supplied pseudonymous study code if needed.

## 4. Analysis

### 4.1 Ingest and identity

Walk the selected folder recursively only when the operator enables recursive import; default to direct folder contents. Accept still image formats supported by ImageIO on macOS, including HEIC/HEIF, JPEG, PNG, TIFF, and common RAW formats when macOS can decode them. Ignore hidden OS files and unsupported media with explicit report reasons.

Compute SHA-256 from original file bytes for cache identity. Derive `assetID` from the digest, with deterministic disambiguation if two records share a digest but differ in normalized metadata/path. A rename does not invalidate analysis. A changed byte digest does. Do not use timestamps or paths alone as identity.

Read EXIF orientation, dimensions, capture date, GPS, and embedded color profile. Normalize orientation for analysis previews but preserve original source bytes for export. If EXIF is absent, use no fabricated capture date; filesystem dates are labeled separately and not treated as reliable sequence evidence.

### 4.2 Thumbnail tiers

All thumbnails are generated locally from oriented sources, cached by source digest + tier + thumbnailer version, and stripped of GPS/EXIF except data explicitly needed for a date/location stamp assembled locally.

| Tier | Long edge | JPEG quality | Use |
|---|---:|---:|---|
| Analysis | 384 px | 0.78 | Vision feature extraction and contact sheet |
| Triage | 160 px | 0.72 | One triage request; emotional/imperfection/social-safety judgment |
| Planning | 384 px | 0.82 | Planning request shortlist, maximum 20–30 images by default |
| Display | 1,200 px | 0.88 | Studio review when source is not directly loaded |
| Render | Original decode | N/A | Final slide output only; never sent to provider |

Planning reuses candidate tiers and must not silently include original-size media. Store dimensions and encoded byte count for every provider-bound thumbnail. If request size exceeds configured budget, reduce included thumbnails in deterministic rank order while preserving person/time/scene coverage; record omissions.

### 4.3 Vision requests and local features

Run the following where supported by the selected SDK/OS. Record request name, revision, input dimensions, execution status, and normalized outputs per asset.

| Request/operation | Output and use |
|---|---|
| `VNGenerateImageFeaturePrintRequest` | Feature print for near-duplicate/shot similarity; retain serialized observation locally in cache |
| `VNDetectFaceRectanglesRequest` | Face boxes, count, normalized regions; do not identify people |
| `VNDetectHumanRectanglesRequest` | Person boxes for crop protection and group/single cues |
| `VNGenerateAttentionBasedSaliencyImageRequest` | Attention saliency map/regions for crop and visual-subject cues |
| `VNGenerateObjectnessBasedSaliencyImageRequest` | Objectness regions as additional crop-safe candidates |
| `VNClassifyImageRequest` | Scene/object labels with confidence; cap and normalize label list |
| `VNCalculateImageAestheticsScoresRequest` | Aesthetic score and `isUtility`; record both, only as supporting rank features |
| Face capture quality request | Use the available Vision face-capture-quality request to flag closed eyes/poor capture quality; do not treat low score alone as a rejection |
| ImageIO/Core Image analysis | Dimensions, orientation, luminance/contrast, dominant colors, flash/night heuristics, black-frame fraction |

Feature requests are independent and failures are recorded per feature; one unavailable request does not invalidate the photo. Face analysis is strictly geometric/quality based, not face recognition. Vision APIs and availability must be checked against the actual Xcode 27 SDK during implementation.

### 4.4 Clustering approach

First cluster exact byte duplicates by digest. Then create near-duplicate/shot edges only among images with compatible orientation/dimensions and either close capture times or strong visual similarity. Default thresholds are configurable and versioned:

| Parameter | Initial default | Meaning |
|---|---:|---|
| Exact digest | equality | Exact duplicate |
| Feature-print distance | ≤ 0.18 | Near duplicate candidate; calibrate on fixtures |
| Time window | ≤ 90 seconds | Same burst/short sequence candidate |
| Related-shot distance | ≤ 0.28 | Similar framing/content, kept as alternates |
| Maximum adjacent gap | ≤ 10 minutes | Allows short event sequences beyond burst |

Use Vision's feature-print distance metric supported by the SDK; do not compare serialized vectors with an ad hoc metric. Construct deterministic connected components with a stricter duplicate edge (time ≤90 seconds and distance ≤0.18) and a separate shot-group edge (distance ≤0.28 plus time ≤10 minutes or very high similarity independent of time). Avoid transitive chains swallowing a long event: cap temporal diameter, split at large gaps, and require each member to match representative or adjacent medoid within the configured distance. Keep thresholds in a pipeline configuration snapshot.

Choose representatives using a blend of technical usability, aesthetic prior, face-capture quality, saliency, emotional triage when available, and deterministic tie-break by asset ID. Do not collapse semantically related scenes that are not near-identical.

### 4.5 Junk filter: accident versus imperfection

Classifications: `reject`, `penalize`, `keep`, `review`. Hard rejects are limited to corrupted/unreadable files, exact duplicates after one representative is retained, confirmed blank/near-black frames without meaningful subject, clear pocket/obstructed lens frames, and extreme blur with no detectable subject. A screenshot is penalized or excluded only when unrelated to the event; screenshots of a venue sign, ticket, map, or meaningful message can be useful details.

Penalties, never hard filters by themselves: low aesthetic score, motion blur, high noise, poor exposure, awkward framing, closed eyes, low sharpness, dark scene, utility aesthetics classification, or low-resolution export. Preserve flash, intentional motion, grain, mirror selfies, food, signs, candid expression, clutter, random details, imperfect group moments, and unusual crops when there is a plausible story role.

Use deterministic local tests to identify obvious technical failures. When confidence is ambiguous, keep the image for triage or planning and report uncertainty. The triage model can label an imperfection useful, neutral, or likely accidental; it cannot override hard corruption or turn a low aesthetic score into exclusion. All reject/penalty reasons appear in the report.

### 4.6 Social safety

Apply a hard/semi-hard hero-selection rule: do not choose another person's face as the hero when local face-capture quality or triage flags show an obvious blink, severe accidental crop, strongly unflattering expression, or awkward close-up and a safer alternative exists. The same image may be used deeper in the carousel if context supports it. Do not infer protected traits, identity, relationships, consent, or attractiveness. Do not make face-based safety decisions for the owner unless the operator has explicitly identified the owner; Phase 0 has no identity recognition.

Sensitive scenes or ambiguous social risk are flagged for operator/user review, never silently uploaded more broadly. Safety flags are structured and minimally descriptive. Provide an option to exclude a photo or person at the folder preparation stage; this setting is not learned.

## 5. Candidate reduction

### 5.1 Targets and adaptive counts

Initial target after local reduction is 60–100 candidates for triage; final planning pool is 30–60. Use actual distinct usable content to adapt. Never pad with weak candidates merely to reach a count.

| Distinct usable photos | Triage target | Planning target |
|---:|---:|---:|
| <50 | All eligible | 20–40 or all |
| 50–200 | Up to 60 | 25–45 |
| 201–600 | 60–80 | 30–50 |
| 601–2,000 | 80–100 | 35–60 |

For a 5–8 slide target, planning can use 25–40. For 9–14 slides use 35–50. For 15–20 slides use 45–60. Clamp by token/image budget and report the effective count. One-per-shot-cluster is the default, but alternates remain available for replacing a poor representative.

### 5.2 Local rank components

Score each eligible representative using normalized components: technical usability (0–1), face/person usability, saliency, aesthetic prior (including `isUtility`), feature/scene usefulness, favorite signal if available, and contextual distinctiveness. Aesthetic prior has a low bounded contribution and is never a final judge. Penalize hard duplication, corruption, highly redundant cluster membership, and irrelevant screenshots.

Initial score (weights configurable and versioned):

```text
base = 0.25*usability + 0.15*people + 0.15*saliency
     + 0.10*aestheticPrior + 0.15*semanticUsefulness
     + 0.10*distinctiveness + 0.10*userSignal
```

Missing features redistribute weight over available components; do not impute a neutral-looking photo as poor. Rank ties resolve by stable asset ID, not filesystem order.

### 5.3 Diversity selection

Select a diverse shortlist with greedy marginal gain after base scoring. Each iteration adds the candidate maximizing:

```text
marginal = baseScore
         + λt * uncoveredTimeBinGain
         + λp * uncoveredPersonOrGroupGain
         + λs * uncoveredSceneGain
         + λd * distinctivenessGain
         - λr * redundancyToSelected
```

Use soft coverage, not quotas that force poor photos. Time bins are adaptive: divide capture span into 6–12 bins, weighted by event density; for missing EXIF, use deterministic source ordering only as a weak signal. People/group coverage uses counts and co-occurrence, not identity embeddings. Scene coverage uses normalized Vision labels and coarse tags. Maintain a modest detail/food/sign/randomness allowance so conventional portraits do not crowd out personality.

Reserve a bounded exploration fraction (about 15–25%) for useful lower-ranked candidates with novel scene, time, or content evidence. Retain a few alternates from strong clusters, but do not send the same burst repeatedly. Record score components, diversity gains, and redundancy penalties.

### 5.4 Triage and planning pool construction

Send up to 60–100 candidates as 160 px thumbnails for triage. Triage scores emotional value, useful imperfection versus accident, social-safety concerns, and moment/content tags. Combine triage with local rank using a bounded adjustment (maximum ±20% of pre-triage score), preserving coverage and avoiding wholesale replacement by model taste.

Choose 30–60 planning candidates using adjusted rank plus diversity pass. Enforce at least one viable candidate for each covered time segment when available and cap redundant near-identical images. If triage fails, use the local ranking result and continue with a warning if policy permits. If the remaining pool cannot support target slides, reduce recommended length and surface the shortfall.

## 6. Director

### 6.1 Responsibilities and prompts

`Director` has two provider calls. Triage is a cheap pass over tiny thumbnails and compact feature summaries. Planning is one multimodal call that returns the selection spine and all three concept plans together. The model is `gpt-6-luna` via OpenAI Responses API structured JSON output. Keep provider code replaceable behind `TriageProvider` and `PlannerProvider`.

Prompts live as versioned resources, each with stable prompt ID, semantic version, content digest, and change note. Suggested resources:

```text
Sources/Director/Resources/Prompts/triage.system.md
Sources/Director/Resources/Prompts/triage.user-template.json
Sources/Director/Resources/Prompts/planner.system.md
Sources/Director/Resources/Prompts/planner.user-template.json
Sources/Director/Resources/Prompts/repair.system.md
```

The triage system prompt encodes: preserve useful imperfection; identify likely accidents carefully; do not equate beauty with story value; flag specified social risks; emit only schema fields and controlled tags; do not invent relationships or image content. Its user payload supplies story context, candidate IDs, local feature summaries, and ordered thumbnails with explicit ID mapping.

The planning system prompt encodes the Taste Constitution: hierarchy, variable density, active whitespace, emotional moments, coherent surprise, no repeated perfection, no template fingerprint, plain photography can win, and design must earn its presence. It must create a compelling shared spine, then Plain Dump, Designed, and Wildcard. Designed should be content-compatible; Wildcard can take coherent risks. Do not write captions or arbitrary text. Do not provide coordinates. Use only candidate IDs, supported primitives, decorations, style IDs, and controlled intent enums. Avoid making every slide decorated or every image equally important.

### 6.2 Structured JSON contracts

Use strict JSON Schema in the provider request, with `additionalProperties: false` at every object. Illustrative compact schema shape:

```json
{
  "type": "object",
  "required": ["selectionSpine", "plans"],
  "properties": {
    "selectionSpine": {
      "type": "object",
      "required": ["orderedAssetIDs", "coverAssetID", "sequenceIntent"]
    },
    "plans": {
      "type": "array",
      "minItems": 3,
      "maxItems": 3,
      "items": {"$ref": "CarouselPlan"}
    }
  },
  "additionalProperties": false
}
```

The production schema fully defines enums, bounds, required fields, and nested items; the abbreviated example is not a runtime schema. `CarouselPlan` includes 5–20 `SlidePlan` objects, concept ID/type, story/style/version, ratio, and deviations. Plain requires one `PhotoElement` per slide, no decoration/text, and exact spine order. Designed and Wildcard may have controlled multi-photo layouts. All IDs resolve to supplied candidates and available asset IDs.

### 6.3 Payload policy and image counts

Triage receives at most 100 images, normally 60–100, with 160 px long edge. Planning receives 30–60 candidate records, structured features for all, and 20–30 384 px thumbnails by default. The remaining records have compact text feature summaries only. No originals are included. The planner receives one story context and target slide count, selected ratio, StylePack snapshot, permitted primitive/decorations, and no participant identity.

Payload building is deterministic: sort candidates by supplied candidate rank, map thumbnail IDs explicitly, and store a digest of the exact payload. Respect configured request byte/token limits. If the request cannot fit, reduce thumbnails while retaining high-ranked candidates and diversity coverage, then remove low-value structured fields in a fixed order. Persist the resulting payload manifest.

### 6.4 Validation

Validate JSON syntax and schema, then semantic constraints:

- Exactly one spine and exactly three unique concepts with required types.
- Spine assets are eligible planning candidates; no duplicates unless explicitly allowed and justified by repeat/alternate policy.
- Spine count is within user target (5–20) or a validated shorter recommendation when the pool is inadequate.
- Each plan's slide count is valid and ratio/style version matches the run.
- Plain plan exactly matches spine order, one photo per slide, full-bleed/hero-compatible primitive, no decorations or text.
- Every photo ID, primitive, decoration, text kind, intent enum, and StylePack reference is allowed.
- Per-slide photo count and total usage limits are bounded; no empty slides.
- Text elements can only refer to local date/location stamp sources. No model-supplied literal text.
- No face-safety hard rule violation for hero image where a safe alternative is available.
- Concept plans satisfy distinctness thresholds (below); all deviations from spine are computed, not trusted from model claims.

Repair only correctable shape/value issues with a constrained repair prompt that includes validator errors and the original response, not images again. One repair request maximum. If repair fails, retry the planning call once with a stricter instruction and same payload. If still invalid, retain any independently valid spine, render a deterministic fallback Plain Dump, and mark designed concepts unavailable; do not synthesize a fake designed plan silently.

Triage schema failure: one format repair attempt. If it remains unusable, continue local-only with a warning. Network, rate-limit, timeout, and provider errors have bounded exponential retry (maximum two transport retries, jitter) and never rerun successful stages. Respect cancellation. Persist raw request/response JSON with secrets redacted; store errors and provider request IDs.

### 6.5 Concept diversity and mutation

Compute pairwise concept distance from selected-photo Jaccard overlap, cover identity, slide count, single/multi-photo ratio, primitive distribution, density sequence, decoration family/use, and order similarity. Initial minimums are configurable: at least one distinct cover; selected-photo Jaccard ≤0.80 or a substantially different sequence; and at least two structural signals differ (primitive mix, single/multi ratio, density rhythm, decoration profile). Plain is naturally structurally distinct but must still be compared for selection overlap.

If Designed and Wildcard fail diversity checks, apply a deterministic mutation request once, naming the failed dimensions and preserving the spine. Prefer altering primitive/pacing/decoration structure before changing selection. Revalidate and rerender. If mutation fails, use the valid original and report diversity failure; do not loop. Mutation is included in retry/cost telemetry.

### 6.6 Cost and latency accounting

For every provider operation record `modelProvider`, `model`, `promptVersion`, `inputTokens`, `outputTokens`, `imageCount`, `thumbnailBytes`, `latency`, `retryCount`, `estimatedCost`, `candidateCount`, and `conceptCount`. Also retain provider usage metadata and pricing table/version where available. Estimate cost from provider-reported usage and a pinned local price configuration; mark estimates as estimates. Warn when projected or accumulated run cost exceeds ~$0.50; allow the operator to continue.

Measure per-stage wall time: ingest, thumbnails, Vision, clustering, reduction, triage, planning, validation/repair, layout, rendering, report. Include aggregate duration and cache hit rates. Never log API key values. A failure before provider submission has zero model cost.

## 7. Layout resolver

### 7.1 Contract and determinism

The LLM describes intent only. `LayoutResolver` chooses exact normalized geometry from a versioned primitive implementation, aspect ratio, photo dimensions, face/person boxes, saliency, style ranges, and a seed. The seed derives from run ID + plan digest + resolver version; a reroll obtains and records a new explicit seed. Given identical inputs, versions, and seed, resolution is byte-for-byte stable.

All geometry is ratio-agnostic. Canvas width/height are based on output pixel target and selected aspect ratio. Supported aspect defaults are inferred from source orientation: mostly portrait → 3:4; mostly landscape → 1:1; mixed → 4:5. User override supersedes inference. Every slide in a carousel shares its ratio.

### 7.2 Primitive geometry rules

| Primitive | Geometry behavior |
|---|---|
| `full_bleed` | One photo covers canvas; cover crop preserves face/saliency regions within feasible bounds |
| `hero` | One dominant image occupies 72–100% of usable area; optional restrained negative-space band |
| `framed_hero` | One dominant image inside a safe inset frame; border/frame from approved StylePack only |
| `inset` | Main photo remains dominant; one smaller inset occupies a disjoint or bounded-overlap corner zone |
| `asymmetric_pair` | Two images use unequal areas, with a clear dominant role and protected gutter/overlap |
| `overlap_cluster` | 2–4 photos, bounded overlap and visible minimum area per image; z-order deterministic |

The resolver may downgrade a requested primitive when the plan violates its constraints, with a warning and log. It cannot introduce unsupported primitives. Maximum count and minimum sizes are config. Full bleed and hero can use no decoration even when a StylePack allows it.

### 7.3 Crop safety

For each photo, begin with source aspect-fit/fill crop based on `cropIntent` and `anchorIntent`. Define protected regions from face/person rectangles, saliency maps, and objectness. For high-importance faces, require all detected face boxes to remain inside crop with a configurable safety margin when geometrically possible. For group photos, maximize visible face area before optimizing saliency. If constraints conflict, prioritize hero face visibility, then person visibility, then saliency, then crop intent.

Never claim a crop is safe if no feasible crop exists. Expand the photo frame, letterbox if the primitive permits, or choose an alternate layout. Minimum subject visibility and face-size thresholds are configurable and recorded. Use normalized source coordinates after orientation correction.

### 7.4 Margins, overlap, and rotation

Safe canvas margin defaults to 4–7% of the short dimension, style-configured. Full-bleed edges are exempt; stamp/text safe zones are not. Overlap is allowed only for `inset`, `asymmetric_pair`, and `overlap_cluster`; use StylePack ranges and enforce minimum visible fraction of every covered image (default 55%). Avoid covering protected face/person boxes. Overlap depth and z-order are stable from element order and seeded tie-breaks.

Rotations are limited to StylePack-configured small ranges; initial range should remain within approximately ±4 degrees for decorative elements and ±2 degrees for photo panels. Full-bleed photos do not rotate. Honor `rotationIntent` only within allowed bounds. Constrain all non-bleed elements to canvas bounds after rotation; if clipping would occur, reduce rotation or resolve again with zero rotation.

### 7.5 Text and decorations

Date/location stamps are generated from valid local metadata using locale-independent formats selected by `formatKey`. Missing date/location means omit the stamp and record a warning. Text is legible, within safe margins, and never over a face unless the plan explicitly requests an allowed non-face placement; unsupported language/characters trigger fallback font selection from the pinned StylePack.

Decorations use only approved manifest assets and bounded opacity/scale/rotation. Grain is a deterministic renderer effect with pinned parameters and seed. Paper texture may sit behind a photo only where layout provides a visible region; tape must not conceal faces or essential content.

## 8. Renderer and assets

### 8.1 Rendering contract

Render with Core Graphics/Core Image. Export at 1080 px wide: 3:4 → 1080×1440, 4:5 → 1080×1350, 1:1 → 1080×1080. Sizes live in renderer config. Preserve source color profile handling and output sRGB PNG. The original source photos are not modified. Output only flattened PNG slides; keep editable plans/layouts as separate JSON artifacts.

Rendering order is deterministic: background, paper/texture, shadows/masks, photos by z-index, frame/tape/decorations, local stamps, grain/color effects, final color conversion. Use stable fonts, asset files, color spaces, resampling modes, and seeded noise. Record the chosen crop, asset digest, and render warnings. Avoid environment-dependent filters and system fonts without pinned fallback/version handling.

### 8.2 StylePack format

Store StylePacks as versioned JSON plus assets. Example abbreviated shape:

```json
{
  "id": "starter-editorial",
  "version": "1.0.0",
  "active": true,
  "primitiveWeights": {"hero": 0.35, "inset": 0.15},
  "decorationIDs": ["paper-warm", "tape-clear", "film-edge-01"],
  "allowedRotations": {"photoDegrees": 2, "decorationDegrees": 4},
  "overlapRanges": {"minimumVisibleFraction": 0.55},
  "densityProfile": ["quiet", "balanced", "dense"],
  "assetManifestDigest": "sha256:..."
}
```

Actual format validates all ranges and references. Initial packs should include only enough variation to test Designed and Wildcard; do not create many style directions that confound the study.

### 8.3 Asset manifest and licensing

Use a manifest entry per font, texture, tape, decoration, or film-edge asset. Fields: `assetID`, `relativePath`, `assetType`, `sha256`, `licenseName`, `licenseURL`, `author`, `sourceURL`, `attributionText`, `commercialUseAllowed`, `modificationAllowed`, `redistributionAllowed`, `acquiredAt`, `notes`, `fontPostScriptName?`.

Only use assets with explicit open licenses compatible with the intended research and future product evaluation. Include license text or a stable local copy when redistribution terms require it. Review fonts and derivative texture rights individually; “free download” is not a license. No asset may load from an unpinned remote URL during rendering.

## 9. CLI, Studio, and run artifacts

### 9.1 CLI

Executable is `ak14` with these commands:

```text
ak14 run <folder> [--slides 5...20] [--aspect auto|3:4|1:1|4:5]
         [--style-pack ID] [--study-code CODE] [--recursive]
ak14 rerender <runDir> [--plan ID] [--seed SEED] [--output DIR]
ak14 report <runDir>
```

`run` prompts or accepts flags for target length, ratio override, style pack, and consented operator label; it previews estimated workload/cost before API submission. API key is read from `OPENAI_API_KEY`, loaded from a gitignored `.env` for local use. Never put the key on a command line or in run output. Missing key allows local analysis/report but blocks provider stages with clear status.

`rerender` resolves and renders saved plans using saved assets and versions, without calling an LLM. If referenced assets or renderer version are missing, report an actionable error; do not silently substitute a different StylePack. `report` rebuilds HTML from stored structured artifacts and does not call an LLM.

### 9.2 Studio UX

SwiftUI Mac Studio opens a completed run and shows three concepts side by side or via tabs, with contact-sheet navigation and full-size slide inspection. Show concept name/type, slide count, ratio, and visible Plain/Designed/Wildcard distinction. The editor supports only:

- Reorder slides.
- Swap a photo from eligible candidates/shot-cluster alternates.
- Remove a photo (including slide removal where a one-photo slide becomes empty).
- Reroll a concept or run generation again under explicit operator action.

Do not expose arbitrary positioning, resizing, type editing, or general collage editing. Reordering and swaps update the working plan and mark it as user-edited. Removal never pads the carousel. Export PNGs in slide order to a chosen destination; preserving source originals and metadata is required for any source-photo export workflow, but Phase 0 carousel exports are flattened slides. Provide an explicit local folder export and a later phone transfer step suitable for the study; no publishing integration.

Show stage progress as: “Finding the best moments” → “Building the story” → “Art-directing the post” → “Rendering your options.” Surface errors with retry at the failed stage and retain completed work.

### 9.3 Run directory

Each run writes to `runs/<UTC timestamp>-<runID>/`:

```text
manifest.json
input-index.json
cache/
  thumbnails/{analysis,triage,planning,display}/
  features/
  clusters.json
  candidates.json
llm/
  triage-request.json
  triage-response.json
  planner-request.json
  planner-response.json
  repair-or-mutation-*.json
plans/
  selection-spine.json
  plain-dump.json
  designed.json
  wildcard.json
layouts/{conceptID}/{slideID}.json
slides/{conceptID}/slide-01.png
report.html
report-assets/
  contact-sheet-*.jpg
interaction-events.jsonl
```

Raw LLM I/O may contain candidate thumbnails in encoded form or references to those local files. Keep reports local, avoid hosted content, and allow participant data to be removed by deleting the run directory. Runs are immutable after completion except appended interaction events and separate rerender/export subdirectories. `runs/` is gitignored.

### 9.4 report.html

The self-contained local report includes:

- Run ID, pseudonymous study code, timestamps, app/pipeline/model/prompt/style/analyzer/resolver/renderer versions.
- Input counts, file type counts, unreadable files, missing EXIF/GPS rates, inferred ratio and any override.
- Kept and rejected contact sheets, each with asset ID, capture time where known, cluster representative/alternate status, rank components, triage flags, and exclusion/penalty reason.
- Candidate funnel counts: ingested → valid → clustered representatives → ranked → triaged → planning pool → selected.
- Each concept's slides, selected photo IDs, cover, primitive/density/decorations, and comparison with spine.
- Selection deviations and slide layout deviations for Designed/Wildcard, with normalized metrics for design-lift analysis.
- Cost/latency table per provider call and per stage, retry counts, thumbnail counts/bytes, warnings, cache statistics.
- User interaction events and export status, where applicable.
- Privacy notice describing local artifact contents and provider-bound thumbnails.

Contact sheets of rejected images remain local. Escape all labels and paths rendered into HTML. Do not embed absolute filesystem paths or GPS coordinates by default.

### 9.5 Interaction logging

Use the product-spec event names and payloads consistently. Core event names include `concept_selected`, `concept_rejected`, `concept_rerolled`, `photo_added`, `photo_removed`, `photo_swapped`, `cover_changed`, `slide_reordered`, `layout_changed`, `layout_regenerated`, `element_resized`, `element_moved`, `carousel_exported`, `carousel_shared`, and `generation_abandoned`. Phase 0 exposes fewer edit operations; do not emit unsupported resize/move events unless a later tool actually provides them.

Also record the funnel events `moment_seen`, `story_selected`, `generation_started`, `concepts_presented`, `edit_session`, `exported`, and `shared`. For a folder-run app, `moment_seen` maps to run input opened and `story_selected` maps to folder/story confirmation. Each event has `eventID`, `runID`, UTC timestamp, concept ID if applicable, asset/slide IDs as applicable, source (operator or participant), and minimal before/after values. Do not log image contents or free-form sensitive notes in event records.

## 10. Error handling and privacy

### 10.1 Files and metadata

- Unsupported extension: skip with `unsupportedType` reason.
- Supported extension but decode failure: retry once with ImageIO options; then skip as `decodeFailure` and report.
- HEIC/HEIF: decode via ImageIO; apply EXIF orientation. If unsupported/corrupt, explain required macOS codec/update; do not silently convert the source.
- RAW: use native decode if available; otherwise skip with a format-specific explanation.
- Missing EXIF: continue with unknown capture time, lower confidence in time diversity, no fabricated date stamp.
- Conflicting/invalid timezone/date: retain raw metadata locally, normalize valid time to UTC, flag ambiguity; use deterministic filename ordering only as a last-resort sequence cue.
- Missing GPS: omit location stamp. Never infer precise location from image content.
- Duplicate digest: preserve one analysis record and reference all source paths for audit/export policy.

### 10.2 Analysis and rendering

Feature request failure is isolated to that feature; fallback to available metadata and continue. Memory pressure uses bounded image decoding and releases per-photo buffers. A render error fails only the affected slide; retain plan/layout and allow `rerender`. Missing or invalid asset manifest prevents the affected decoration and emits a warning; use a neutral background only if the StylePack defines that fallback.

### 10.3 Provider failures

Timeout, network failure, rate limit, malformed schema, refused/unavailable model, and budget estimate are distinct statuses. Retry transient errors within bounded policy. Do not retry permanent auth errors. Missing key stops provider stages, preserves local analysis, and suggests setting `OPENAI_API_KEY`. Never print the key. On partial failure, preserve all successful stage artifacts and show whether deterministic Plain fallback is available.

### 10.4 Invalid plans

Schema-invalid plans follow the bounded repair/retry policy in §6.4. Semantic violations are rejected before layout. An invalid Designed/Wildcard never reaches the renderer. Deterministic fallback Plain uses a valid spine; if no spine exists, no carousel is produced and the report explains why. Log original and repaired outputs with a clear relation and validation findings.

### 10.5 Privacy and retention

The operator chooses source folder and controls local run directories. Thumbnails sent to the provider are limited, compressed, and disclosed before the first call. No backend stores data. Provider retention is governed by the configured account/API terms and must be verified before study recruitment. Raw prompts/responses and contact sheets can contain personal imagery; keep local, restrict sharing, use pseudonymous run codes, and delete on participant request or per study retention policy.

## 11. Testing and evaluation strategy

Do not treat aggregate unit coverage as evidence of taste. Tests establish deterministic contracts and failure handling; the human study assesses value.

### 11.1 Core unit tests

Test stable IDs under rename/reordering, manifest/schema migrations, aspect inference, ratio override, adaptive target counts, rank component normalization, diversity marginal gain, cluster transitivity caps, plan validation, deviation metrics, concept distinctness, layout bounds, seeded determinism, and error classification. Include property-style cases for no out-of-bounds elements, valid IDs, and no empty slides.

### 11.2 Analysis fixtures

Keep a small, consented or synthetic fixture set with expected decodes, orientation, missing EXIF behavior, exact/near duplicates, burst boundaries, face/saliency regions, blank frames, pocket shots, intentional blur, flash/night scenes, signs, food, screenshots, and mixed orientation. Pin analyzer version and tolerate expected platform-level numeric variance with documented ranges.

### 11.3 Render golden images

Create golden PNG fixtures for every primitive and each supported ratio, including faces near crop edges, groups, portrait/landscape mixtures, overlap, tape, stamps, grain, and absent metadata. Compare pixel output or perceptual diff with tight documented tolerances. Golden updates require review and renderer version increment. Run identical render twice and compare file digests to establish determinism.

### 11.4 Director fixtures

Record sanitized request/response fixtures with model and prompt versions. Test valid outputs, malformed JSON, extra keys, unknown IDs, unsupported primitives, safety violations, invalid Plain plans, too-similar concepts, repair success/failure, mutation behavior, and provider errors. Fixture replay must not call the live API. Live-provider smoke runs are manual and cost-recorded, not part of ordinary tests.

### 11.5 End-to-end and study harness

Run a small folder fixture through ingest → analysis → reduction → recorded Director response → resolver → renderer → report. Verify cache reuse, `rerender` without network, report completeness, and run version snapshots.

Provide an eval harness that accepts an evaluator's own selected photos/order for the same event and compares overlap, cover agreement, time/person/scene coverage, cluster redundancy, selection quality, and effort. The participant's own picks are a reference, not universal ground truth. Collect pairwise preference and post-worthiness ratings alongside behavioral measures. Keep selection quality separate from design lift by comparing the spine/Plain against each designed concept and logging all selection deviations.

### 11.6 Test data governance

Use synthetic or explicitly consented photos. Store fixtures outside the public repository when consent does not include redistribution. Minimize retained imagery; retain derived features and anonymized run metrics only where allowed. Document who can access study runs.

## 12. Milestones

Milestones are sequential implementation slices. Each must be demoable from a clean checkout with a documented local command and fixture, without requiring a live API unless the milestone says so.

### M1 — Harness, analyzer, and report

Build folder ingest, stable IDs, thumbnail tiers, Vision feature extraction, file/error reporting, cache, run manifest, contact sheet, and `report.html` with accepted/rejected reasons. Include API-free local mode.

**Exit demo:** run a mixed-format fixture folder twice; second run reuses cache; stable IDs remain stable after rename; report shows counts, thumbnails, missing metadata, and decode errors.

### M2 — Candidate reducer

Implement exact/near-duplicate and shot clustering, junk rules, rank components, adaptive counts, and time/person/scene diversity selection with auditable reasons.

**Exit demo:** fixture folder reduces to a reproducible 60–100 triage shortlist and 30–60 planning-ready set where available; operators can explain why each candidate entered or left.

### M3 — Triage and planner, Plain first

Implement provider protocols, OpenAI Responses API structured output, prompt versioning, thumbnails in payload, telemetry, validation/repair, and shared selection spine. Render a minimal deterministic Plain Dump before any decorative design work; then produce Designed/Wildcard plans.

**Exit demo:** recorded-response flow produces a valid 5–20 slide Plain concept matching the spine plus two valid plans; live run logs cost and latency; malformed plan reaches bounded repair/fallback.

### M4 — Resolver and renderer

Implement six supported primitives, crop protection, deterministic geometry, pinned StylePack/manifest loader, assets, text stamps, grain, export PNGs, and golden images.

**Exit demo:** same saved plan renders byte-identically twice across a clean rerender; all supported ratios pass reviewed golden cases; no provider call occurs.

### M5 — Studio

Build a Mac SwiftUI run browser and three-concept review workflow with reorder, swap, remove, reroll, export, and interaction event log.

**Exit demo:** an operator can open a run, compare all concepts, make allowed edits, export ordered slides, and see edits reflected in event log and report without altering original plan artifacts.

### M6 — Study readiness

Complete privacy disclosure, participant/run pseudonym workflow, cost warning, crash recovery, report QA, device/phone transfer procedure, evaluator guide, and study instrumentation. Freeze versions and study protocol before recruiting.

**Exit demo:** a dry run with a consenting test participant completes folder intake, three concepts, edits, export/phone transfer, and seven-day follow-up instrumentation; all artifacts reconstruct the run and report the proposed rebuilding metric.

## 13. Risks and open items

| Risk/open item | Phase 0 treatment |
|---|---|
| Vision API names/availability may differ in the Xcode 27 SDK | Verify compile-time symbols and request behavior before M1 exit; record exact revisions |
| GPT-6 Luna structured-output behavior or pricing may change | Model ID `gpt-6-luna` is verified; confirm strict JSON-schema support in the first live smoke test; keep provider isolated |
| Participant photo transfer may remove metadata or create friction | Document supported AirDrop/export path; inspect a sample before processing; log missing metadata |
| License terms may not support app distribution or derivative assets | Maintain per-asset manifest and review rights before inclusion |
| Triage/model bias may suppress imperfect or culturally specific content | Bound triage impact, include novelty coverage, inspect rejected contact sheet, measure user edits |
| Safety flags may be incomplete or context-sensitive | Prefer review/alternate choices and avoid face identity inference |
| Cost estimates may be inaccurate | Record usage, model price snapshot, and estimate source; soft warning only |
| Render output may vary by OS/framework | Pin versions/assets/config; include environment in manifest and golden tests |
| 30% substantial-rebuild threshold is proposed | Pre-register with study protocol or replace before recruiting; report continuous edit measures |
| Posting verification is unresolved | Prefer self-report plus optional user-provided post link/screenshot; obtain consent and predefine verification |
| Contact sheet/report retention may expose personal imagery | Local-only, pseudonymous, deletable run folders; establish retention and access policy |
| One story per folder may not reflect all useful event sub-stories | Keep scope fixed for Phase 0; collect operator notes and treat story splitting as later work |

## 14. Self-check and remaining ambiguity

- The architecture uses the resolved Mac folder workflow, Swift package, provider-agnostic protocols, shared spine, Plain Dump, local StylePack assets, date/location stamps, and three concepts.
- Plain Dump is a deterministic render of the shared spine; Designed/Wildcard selection deviations are measurable.
- The six Phase 0 primitives and five named decoration families are within the allowed set. No unsupported primitive is described as implementable.
- No LLM-authored caption or arbitrary slide text is permitted.
- Cost remains a soft warning near $0.50/run; a few minutes per run is accepted.
- The requested proposed rebuild criterion is marked proposed and explicitly not settled.
- Product-spec names for interaction logging are included; events outside Phase 0 edit support are not emitted without corresponding behavior.
- Remaining implementation ambiguities: exact SDK symbol/signature/revision for face capture quality and aesthetics request; final per-asset licenses; study retention and posting-verification policy; whether the proposed 30% rule is ratified before recruitment.

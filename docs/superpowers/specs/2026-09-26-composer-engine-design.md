# Composer Engine Design

## Goal

Replace the fixed `plainDump`/`designed`/`wildcard` concept taxonomy with model-directed style directions and a deterministic Core composer. Every direction must meet the same postable, aesthetic quality bar. The model supplies the story (selection spine and 2–5 directions); Core converts each direction and local evidence into the existing `CarouselPlan`, and `LayoutResolver` continues producing geometry. Preserve rerendering and study interpretation for old runs.

## Decisions

Remove `ConceptType` from new planning and runtime identity. Use opaque `CarouselID` (`c1`…`cN`, and `baseline`) for storage, events and UI. `StyleVector` has six shared axes: `density: quiet|balanced|dense|varied`, `overlap: none|some|bold`, `grouping: single|mixed|collage`, `decoration: none|light|rich`, `rotation: none|some`, `whitespace: tight|airy`. The model returns internal one-sentence briefs, cover asset, ordered photos, optional keep-together groups and emphasis IDs. It never returns slides, primitives or per-photo intents. Composer is pure and deterministic for a seed. Baseline is composed from the spine with `single/no decoration/no overlap/no rotation`, whole-photo hero fallback, and ID `baseline`; shuffle it among directions with a stored run seed. If direction planning fails, show baseline alone.

## Pipeline split

Keep triage, pool selection and spine planning in `ArtDirector`. Change its output to `SelectionSpine` plus `[CompositionDirection]`; remove plan repair/mutation logic that assumes three named concepts. Add Core `ComposerEngine.compose(direction:photos:features:triage:reduction:aspect:stylePack:seed:) -> CompositionResult`, with result containing `CarouselPlan`, resolved `ResolvedCarousel`, score and warnings. Build baseline through the same engine. `ConceptRendering` renders these results; CLI run, rerender, `RunSession`, report and Studio address carousels by ID. Rerender resolves saved plans without recomposing legacy plans.

## Director (prompt and schema)

Update `Sources/Director/Resources/Prompts/planner.system.md` to planner prompt v3: choose spine, then 2–5 genuinely supported directions; directions must be distinct in intent but all publishable. Describe each brief as internal/operator-only. Change `PlannerResponse` to `recommendedSlideCount`, `spine`, `directions`; define Core `CompositionDirection` with `id` assigned locally, `brief`, `styleVector`, `coverAssetID`, `orderedAssetIDs`, `keepTogether: [[AssetID]]`, `emphasisAssetIDs`. Require every listed photo/group/emphasis/cover ID to be in pool; no repeated ordered IDs; spine has current safety/length constraints; direction sequence length 5…20 and cover belongs to it. Reject malformed directions individually and retain valid ones. On no usable direction, use baseline alone.

`Schemas.planner(ids:)` must emit OpenAI strict JSON Schema: root and every object use `additionalProperties:false`; every declared property is in `required`; no nullable/optional properties (use empty arrays). Root required keys exactly `recommendedSlideCount`, `spine`, `directions`. Directions array `minItems:2,maxItems:5`; direction required keys exactly `brief`, `styleVector`, `coverAssetID`, `orderedAssetIDs`, `keepTogether`, `emphasisAssetIDs`. Style vector requires all six axes, each a string enum exactly as listed above. Spine retains ordered IDs, sequence intents and rationales with candidate-ID enums. Remove slide/primitive/photo-element/decor schema. Keep bounded repair/retry for schema and semantic validation.

## Composer engine (grouping, primitive assignment, element intents, decoration, geometry, carousel scoring and selection)

Add `Sources/Core/Plan/StyleVector.swift`, `CompositionDirection.swift`, and `Sources/Core/Layout/ComposerEngine.swift` (or equivalent Core file). Group photos in direction order using dynamic programming over contiguous segments. Cost combines capture-time gap and cached Vision feature-print distance; where prints are unavailable use a deterministic fallback from time gap, scene-label overlap and aspect similarity, and record which path was used. Penalize splitting a keep-together set, combining emphasis assets, breaking sequence intent, excessive deviation from spine slide-count target, and mixing distant moments. Complementary aspects lower cost. Hard constraint: never combine distant capture moments; use the configured clustering gap, with unknown times treated as no evidence rather than distant. Deterministic tie breaks use asset IDs and seed.

Assign a legal existing `Primitive` per group size and evidence: photo aspects, face/person count, grouping, overlap, whitespace and density. Favor full-bleed/hero for one, inset/asymmetric pair for two, overlap cluster for 3–4 only when faces and hierarchy remain safe. Position (opener/build/peak/breather/detail/closer) controls rhythm; `varied` alternates density/arrangement. Hero is highest emotional triage value, then local aesthetics, then stable ID; cover is the direction’s requested asset when safe, otherwise apply existing flagged-cover safety fallback and record it. Derive crop, anchor, overlap and rotation intents deterministically from features and axes; retain `PhotoElement` and `SlidePlan` APIs so PlanEditor and renderer remain usable.

Decoration budget is per carousel: none = zero; light = no more than 20% of slides; rich = no more than 50%. Only select a decoration supported by the pinned `StylePack`, and only where geometry allows it. Never put paper on full-bleed-only slides. A date stamp requires valid capture metadata. Geometry uses `LayoutResolver` and existing `choose` candidate scorer. Remove its `conceptType == .plainDump` density exception; pass explicit resolved density/composition constraints through `LayoutContext` or a new context value. Keep crop loss, people/face, overlap visibility, hierarchy, balance and cover safety scoring at the same threshold for all plans.

Score whole carousels for rhythm (no repeated arrangement families back-to-back), axis/density fit, requested cover strength/safety, hierarchy, crop loss and people safety. Generate a bounded candidate set with existing resolver candidate scoring; stable seed selects among near-best whole compositions, never among unsafe ones. Record score components and selected candidate index for reproducibility.

## StyleVector mapping

Map vector to bounded numeric composer preferences, not new layout primitives: `density` selects quiet/balanced/dense slide targets; `varied` alternates adjacent targets. `overlap` maps none/some/bold to no/limited/preferred overlap, still subject to visibility and face constraints. `grouping` biases DP segment size and primitive weights toward single, mixed, or multi-photo collage. `decoration` applies the budget above. `rotation` disables or enables StylePack-bounded rotation. `whitespace` maps airy/tight to larger/smaller StylePack spacing and lower/higher coverage targets. Clamp every preference to current safety limits; persist both vector and effective mapping.

## Diversity

Generalize `PlanMetrics` to compare every pair of composed directions using photo Jaccard, same cover, primitive mix, density rhythm and normalized `StyleVector` distance (fraction of unequal axes). Define and version a threshold in `ComposerConfiguration`. When a pair fails, recompose the later direction away from earlier outputs by selecting another near-best seed candidate, then boundedly nudge one axis while preserving its brief and cover intent. No additional model call. If still too similar, drop the later direction while at least two directions remain; never drop below two model directions solely to satisfy pairwise checks. Always retain baseline. Persist distances, remedies and any dropped IDs.

## Baseline control

Generate baseline from spine photos and order with fixed minimal vector, one photo per slide, whole-photo hero fallback and no decorations/text. Compose via same engine/scorer and store ID `baseline`. Seeded shuffle of baseline plus valid directions is saved in run metadata and is the participant presentation order; UI labels options neutrally. On planner failure show baseline alone. Baseline is eligible for selection/export/posting metrics.

## Studio edits and reroll

Retain `PlanEditor` reorder/swap/remove on the composed plan. Change `RunSession` and `StudioModel` selection/edit APIs from `ConceptType` to `CarouselID`. Reroll recomposes that direction with a new stored seed and no model call; baseline reroll uses its fixed vector. Preserve existing handoff snapshots and event logging with ID. Display internal brief only to operator, never participant. Edits/rerolls operate on current plan and are isolated per ID.

## Storage and compatibility

New runs store `plans/director.json` with `schemaVersion`, directions, vectors, composer version/config, baseline, ID-to-directory mapping and presentation order/seed. Record mapping `id -> directory` there. Use `layouts/<id>/`, `slides/<id>/`, `edits/<id>/`; keep handoff snapshots addressable by ID. Replace `ConceptsReport` and report/edit dictionaries with ID-keyed records while decoding old JSON tolerantly. Legacy mapping: `plainDump -> baseline`, `designed -> c1`, `wildcard -> c2`, with default vectors. Preserve saved legacy slide plans and resolved layouts as-is; rerender must never recompose them. Keep old `ConceptType` decoding only in a compatibility adapter, not in new plan/runtime flow. Unknown new fields should be tolerated; missing legacy fields receive documented defaults.

## Report

Update `RunReport` and report builder to show neutral carousel IDs, internal brief in operator report, StyleVector, baseline marker, composer score/warnings, edits, diversity and rendered paths. Keep old report inputs readable. Show participant presentation order but avoid exposing condition labels in participant UI. Report failures and dropped directions explicitly.

## Study metrics and protocol

Update `docs/study/protocol.md`: 50% minimum counts a selection plus export/share without substantial rebuild for **any** selected carousel, including baseline; retain 30% rebuild rule and 20%/40% sensitivity, and 33% posted within seven days. Replace Plain/Designed/Wildcard pick counts with baseline-picked rate and picked StyleVector distribution; retain edit burden, repeat demand, cost and Director time. Add baseline to neutral shuffled presentation, note baseline-only failure case, and revise review language to “available carousels.” Update the pre-registration text before recruitment; do not change thresholds after outcomes.

## Versions

Set planner prompt version `v3`, bump director response/schema version, add `ComposerEngine.composerVersion` (initial value `composer-1`) and persist it with config. Keep `ResolvedCarousel.resolverVersion = "layout-2"`; bump only if geometry semantics change. Legacy records retain their recorded prompt/resolver values.

## E2E tests

No unit tests. Extend existing end-to-end fixtures and `FakeModel` to return a variable number of directions (2–5), including invalid direction, repair/retry, and total planner failure. Cover baseline-only fallback, seeded shuffle persistence, deterministic composition/reroll, grouping constraints, diversity recomposition/drop, safe cover and decoration budgets, edit operations, new ID directories, tolerant legacy open/report/rerender without recomposition, and study metric counting. Real verification is one live run against `IMG/` (about $0.005); inspect rendered carousels and report.

## Task list

1. Add `StyleVector`, `CompositionDirection`, `CarouselID`, composer configuration/result, and versioned Codable compatibility types. Buildable: Core compiles; no call-site migration yet.
2. Replace planner response/schema/prompt with v3 directions; update validator and `FakeModel` variable direction fixtures. Buildable: Director compiles and end-to-end planner decoding works.
3. Implement pure DP grouping and deterministic primitive/intent/decoration assignment in `ComposerEngine`; expose baseline composition. Buildable: Core compiles with generated plans.
4. Add explicit composition preferences to resolver context, remove concept-type special case, and score/select seeded whole compositions. Buildable: rendered fixtures resolve through layout-2.
5. Generalize `PlanMetrics` to pairwise directions and add deterministic diversity remedies/drop reporting. Buildable: Director output includes validated composed set.
6. Migrate `ConceptRendering`, CLI pipeline, `RunSession`, Studio and storage to ID-keyed directories; implement reroll without model calls. Buildable: new end-to-end run/edit/export flows work.
7. Add tolerant legacy decoder and ID-directory map; preserve old plans/layouts on open, report and rerender. Buildable: legacy fixture E2E succeeds.
8. Update report, study protocol and participant presentation order/labels/metrics. Buildable: report and study E2E assertions pass.
9. Run complete E2E suite and one live `IMG/` verification; review cost, deterministic artifacts, safety and postability before study recruitment.

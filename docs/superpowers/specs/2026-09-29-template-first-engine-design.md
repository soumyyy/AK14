# Template-first engine

Status: approved direction (2026-09-29). Reviewed twice with GPT-6 Astra; every claim it made was checked against the code before being adopted.

Owner: "How the photos actually appear is still quite shit. I need to fix the taste aspect. We have a set of templates: it should find the best template it can, pick the photos from all the photos we entered, create a good story, and put the photos in that template, or something inspired by that. The first priority is that it fits itself into one of those templates." Options may **mix pages from different templates**, as long as the carousel reads as one design.

## Why the output is plain today
1. **The designed templates can't be reached.** `TemplateVocabulary.place` only tries windows of at most 3 slides (`TemplateVocabulary.swift:23`) and needs `slideCount == window length`. Every bundled template with text either has 4 or more slides or is not 4:5. Titles, typography and frames from 17V28 are therefore effectively never used.
2. **Story first, templates last.** The planner fixes slides and groups (`recommendedSlideCount` = number of photos, `ComposerEngine.group`). Templates are then tried as an exact match on those groups, which almost always fails, and the slide falls back to `hero.clean`. That is why 46% of slides are photos on white cards.
3. **Naive photo-to-slot assignment.** `TemplateVocabulary.build` pairs slots ranked by area with photos, hero first (`TemplateVocabulary.swift:175`). If that single pairing fails the crop or face check, the whole template is rejected, even when another pairing would fit.
4. **The planner prompt pushes toward plain output:** "The page is mostly white" (`planner.system.md:40`) and one slide per photo.
5. **Two crop rules disagree:** 0.65 for templates versus 0.58 for full-bleed (`CropPlanner.swift:90`).
6. **Small library.** 55 sets are bundled: 27 plain grids and 28 templates. The source app has 231 templates: 71 are 4:5 with 308 pages, and 38 are 3:4 with 275 pages. The importer drops a **whole** template when any decoration covers more than 12% of it or overlaps a photo (`import.swift:365`), even if most of its pages would work without decoration.

## Principles
- **Every slide is an authored page.** A slide is a page from the catalogue, or a linked run of pages. The white card is a last resort, not a layout choice.
- **One design per option.** An option's pages come from compatible pages (same family, or an owner-curated compatibility group). Different options use different families.
- **The AI tells the story; the engine does the geometry.** No extra AI calls. Latency and cost stay within the current Worker caps.
- **What was decided is what renders.** The chosen pages, photo assignments and crops are stored and rendered exactly as chosen, with no second resolution pass using a different seed.
- **Taste is judged by the owner.** The white-card rate is a warning sign, not the goal.

## 1. Page catalogue and page rescue (importer)
`tools/import-17v28/import.swift` produces a page-level catalogue alongside the existing sets (bump the library version; old files still decode).

- **Split templates into pages.** Each page records:
  - `id`: `17v28-t<template>-p<index>`
  - `sourceTemplate` and `index`, for provenance and for keeping authored neighbours
  - `aspect`, and its slots (frame, aspect, corner radius, z-order, rotation)
  - text layers with their role, and frames
  - `background` and `family`
  - `role`: `cover`, `statement`, `grid`, `strip` or `quiet`. It is inferred from geometry: one slot covering at least 80% of the page is `statement`; a page with a `title` text layer is a cover candidate; 3 or more equal slots is `grid`; a single row or column of 2–4 slots is `strip`; mostly background with at most one small slot is `quiet`.
  - `capacity`: slot count, and each slot's shape class. Shape classes: tall (< 0.8), square (0.8–1.25), wide (1.25–2.0), band (> 2.0).
- **Linked runs.** Pages joined by a slot, frame, text layer or decoration crossing the page edge form one `run` that is always placed whole.
- **Page rescue.** The decoration filter applies per page or run, not per template. A page is kept when its decorations cover at most 12% of it and none overlaps a photo slot.
- **A cover needs to look like one.** It is `statement` or `grid`, with a title layer or a quiet region where a title can go.
- **Aspect.** Carousels are not always 4:5: `CarouselAspect.infer` (`Aspect.swift:11`) picks 3:4 when at least 70% of the photos are portrait, square when at least 70% are landscape, and 4:5 otherwise. The catalogue covers all three: 4:5 has 308 source pages, 3:4 has 275, and 1:1 has 34. The search only uses pages in the run's aspect. If an aspect has fewer than 20 usable pages after rescue (likely for 1:1), the grids for that aspect are added. If it still has fewer than 20, that run uses the current engine and records a warning. Existing runs keep their saved aspect.
- **Frames keep their geometry.** Frame layers and their photo-window geometry (`FrameLayer.slotFrame`, `photoWindowAspect`) are carried per page, so slot assignment uses the frame's photo window, not the frame's outer box.
- **Contact sheets** of the rescued pages are written to `/tmp` for owner review. They are never committed.
- **Target:** at least 150 usable 4:5 pages, up from a few dozen reachable now (mostly plain grids). The actual count is recorded in the spec's Results section.

## 2. Best-pairing placement (Core/Layout)
- A new `SlotAssignment` finds the lowest-cost assignment of photos to a page's slots using exhaustive permutations (at most 8 slots, 40,320 permutations) or the Hungarian algorithm for more.
- Cost per photo–slot pair:
  - crop loss (1 − kept area)
  - a face-size penalty. Only **relevant faces** count: the largest face, plus every face at least 40% of its height. Their smallest rendered height below 4% of the slide height is a steep penalty, not infeasibility. Background faces are ignored.
  - hero preference: the story's cover/hero photo wants the largest slot
  - hard infeasibility: kept area below 0.65, `facesFit` fails, or the subject crosses a page edge
- **One crop floor:** 0.65 everywhere, including `CropPlanner.fullBleedEligible`. The 0.58 exception is removed; the wide slots in section 4 take over the cases it covered.
- `TemplateVocabulary.build` uses `SlotAssignment` instead of zipping.

## 3. Template-aware planner (Director)
- Before the planner call, the app computes each photo's **shape class** and whether it has **people** (existing features). These go into the planner's photo list as two short tags, so no template descriptions are sent.
- **The number of AI calls does not grow.** There is still one planner request. The existing repair and retry calls (`ArtDirector.swift:116–135`) still run only when the output fails validation. The first response's validity rate is recorded in the evaluation, and the target is at least 95%. Triage is unchanged.
- **Schema, decoder, validator and fallback change together:**
  - `Schemas.swift` (the strict output schema)
  - `Direction` decoding
  - `PlanValidator`
  - the deterministic fallback plan used when the AI is unavailable, which builds moments from time clusters
- Precedence: when `moments` is present, it defines the selection and order, and `orderedAssetIDs` is derived from it (the first alternative of each slot the search fills). When it is absent (old runs, or the fallback), the legacy fields drive the search as one moment per `keepTogether` group or photo.
- Validation rules for moments:
  - a photo appears in at most one moment
  - every id is in the pool
  - moments are non-empty
  - `size` maps to the photos used in that moment: `1` → 1, `few` → 2–3, `many` → 4–9
- **`mustInclude` is a hard constraint, never a score bonus.**
- The planner output (`Direction`) gains, as optional fields so old runs still decode:
  - `moments`: an ordered list of story moments. Each moment has a short label, `photos` (ranked alternatives, best first), `mustInclude` (0–2 photos) and `size` (`1`, `few`, `many`).
  - `coverCandidates`: 1–3 photos.
  - `titleIdeas`: 1–3 strings of at most 40 characters. `titleIdea` stays for compatibility and becomes the first entry.
- Prompt changes in `planner.system.md`:
  - remove "The page is mostly white…" and `recommendedSlideCount = number of photos`
  - add: "Group photos by moment. List alternatives inside a moment; the layout engine chooses how many to show and how to lay them out."
  - keep the rule that options differ, but by story angle and cover, not by forced photo overlap quotas
- `ArtDirector.plannerContent` stops converting the requested slide count into a requested photo count. The slide count is a soft target the search respects (±1).
- **Exact-set** requires every supplied photo exactly once, so every photo is mandatory; the 0–2 `mustInclude` limit does not apply. **Keep-order** additionally fixes the input order. Within a page, the reading order is top-to-bottom, then left-to-right, by slot centre, and the assignment must respect it.
- **Worker style config.** Clients accept only `configVersion` 1 (`StyleConfigClient.swift:87`), and shipped apps cannot be updated. Rules:
  - The config schema version stays 1. New fields are optional and ignored by old clients.
  - The catalogue ships in the app bundle and has its own version. It is not served by the Worker.
  - The Worker's ETag includes a content revision, not just the schema version (`index.js:113`), so content changes reach clients.
  - The constitution line "Avoid recognizable template fingerprints." (`style-config.json:60`) contradicts the owner's direction and is removed. "Design must earn its presence" stays.

## 4. The search (Core/Compose)
A new `PageSearch` replaces group-then-fit for non-baseline options.

- **Input:** moments, the catalogue restricted to one family (or compatibility group), the target slide count, and the photo features.
- **State:** position in the moments; photos used so far; pages placed; whether a title has been placed; the last two page roles, for rhythm.
- **Step:** place one page or linked run. It consumes k photos drawn from the current moment and, with a penalty, from the neighbouring moment, using `SlotAssignment`. Slide 1 must be a cover-capable page containing a `coverCandidates` photo.
- **Bounded expansion.** The beam alone does not bound the work, so each step is capped explicitly:
  - photo subsets: from the current moment's top 6 alternatives, plus at most 1 photo from the next moment
  - pages: at most 12 candidates per step, pre-filtered by capacity and shape class
  - assignment: the Hungarian algorithm (polynomial), with no permutation enumeration above 5 slots
  - families: at most 4 per run, chosen by how many pages fit the pool's shape mix
  - beam: the best 48 states per step
- **Caching and determinism.** The assignment cache key is (page, ordered photo tuple, hero id, order constraint). Ties are broken by id.
- **Budget.** Total composition, all options, p95 at most 1.5 s, measured on the owner's iPhone 17 in a device run of the 8 IMG events. The simulator figure is only a regression guard in e2e.
- **Score** (higher is better; weights are constants in one file):
  - authored-design fidelity: the page is used with its original proportions, margins and typography, with bonuses for keeping an authored neighbour next, and for a title page as the cover
  - story value: the planner's ranking of the photos used, and every `mustInclude` photo present
  - readability: face size, and a title that fits with enough contrast
  - rhythm: busy (grid, strip) and quiet (statement, quiet) pages mixed, with a penalty for 3 or more pages of the same role in a row, rather than strict alternation
  - penalties for crop loss, repeating the same page in a carousel, photos moved between moments, and missing the target slide count
- **Wide photos get wide slots.** `band` and `wide` slots are preferred for wide photos: two landscapes stacked, a landscape band with space for type, or a landscape plus a strip of detail shots. A 16:9 photo is never forced to fill a 4:5 slot (that keeps only 45% of it).
- **Last resort.** When no page in the family can hold a photo, the search may use the white card (`hero.clean`) for that photo. Each use carries a large penalty and is recorded as a warning. Mandatory photos (`mustInclude`, exact-set) are **never dropped**: if no page can hold one, it goes on a white card.
- **Covers.** Cover capability is a separate flag, not a role. It is true when the page has a title layer, or when it has a single dominant slot covering at least 60% of the page where the existing title placement (`addCoverTitleIfNeeded`) finds a region that passes the contrast check. A story with no title still needs a cover-capable page on slide 1; its title layer is simply dropped.
- **Options.** Run the search for each candidate family. Keep the best result per family, then show the top 2–3 across families, in `ComposerEngine.composeSet`. The overlap remedy stops swapping out good photos just to meet a quota. The photos-only baseline stays as one option.
- **Placement payload.** It is not called "recipe", because `recipeID` and `RecipeFiller` already exist (`ConceptRendering.swift:26`). The winning result is stored in the plan as a versioned `placement` payload:
  - the catalogue version
  - per slide: the page id, the resolved slot geometry, the photo assignment with crops, text layers (role, font, size, line count, colour) and frames
- **Rendering precedence:** `placement` if present, then `recipeID`, then the ordinary resolver. Old plans have no `placement` and render exactly as before.
- **Every path uses it:** `LayoutResolver.resolve` (CLI and session), `StoryPipeline` on iOS (`StoryPipeline.swift:248`), and `templateFamilies`, which reads the payload and no longer re-resolves.
- **Replay versus recompose.** Re-rendering replays `placement`. `ak14 rerender --recompose` reruns the search.
- **Edits.** The editor's `CanvasDocument` is created from `placement`. `CanvasDocument` conversion must carry the text role and line count, which it drops today (`CanvasDocument.swift:95`). Editing a photo (crop, adjust, move) changes the document only. Swapping or reordering photos invalidates the affected slides' placement: those slides are re-searched with the page fixed where the new photos fit, and otherwise with the page free. `StoryEditingService.apply` follows the same rule.

## 5. Evaluation
- **`ak14 eval pairs --compare <old> <new>`:** blind pairs showing the same photos laid out by the old and new engine, to isolate the layout change. Then full-pipeline pairs.
- **"Would post" rating:** yes / almost / no for each option, shown at full slide size.
- **Report:**
  - owner preference, new versus old
  - the share of runs where no option is postable
  - the worst option's rating per run
  - white-card rate and median crop kept, as warning signs
- **Layout pairs** freeze the photo selection and order: both engines get the same `moments` and the same selected photos. Each pair records both engine versions. Ties ("same") are allowed and excluded from the denominator.
- **Options shown:** the 2–3 template-first options, plus the photos-only baseline as an additional one.
- **Acceptance:**
  - the owner prefers the new engine in at least 70% of non-tied layout pairs on the 8 IMG runs
  - no displayed template-first option is rated "no", and at least 75% are rated "yes"; every "no" is investigated and fixed or suppressed before release
  - white cards are at most 10% of slides, with no mandatory photo dropped to get there
  - the first planner response is valid in at least 95% of runs

## Tests (e2e only)
- Importer: page split, linked runs kept whole, page-level decoration rescue, cover roles, no 17V28 sample text.
- Placement: a template rejected by the old zip pairing is accepted by the best pairing on a fixture set, and the crop floor is 0.65 everywhere.
- Search:
  - determinism (same seed gives the same carousel)
  - one family per option
  - title on slide 1 at most once
  - every `mustInclude` photo is present
  - exact-set and keep-order modes are respected
  - the rendered slides match the recipe
- Fixtures: wide group shots, 16:9 panoramas, long titles, a pool of 3 photos, a pool of 60 photos.
- Latency: `PageSearch` on the 60-photo fixture stays within a simulator regression guard. The real budget is checked on the device.
- Old runs still decode and re-render, and plans without `placement` render the same bytes as before.
- The full path works: generate, edit (crop, text, swap), save, reload, export. Package e2e covers `StoryEditingService`; the iOS UI test covers the editor.
- Aspect: one fixture set per aspect (3:4, 4:5, 1:1), including the fallback to the current engine for a thin aspect.
- The Worker keeps serving `configVersion` 1, and the ETag changes when the content changes.

## Build order
1. Page catalogue and page rescue (section 1), plus owner review of the contact sheets.
2. Best-pairing placement and a single crop floor (section 2). Worth measuring on its own.
3. Planner fields, schema, validator, fallback and prompt (section 3), plus the Worker constitution and ETag change. The config schema version stays 1.
4. `PageSearch`, scoring, options and recipe rendering (section 4).
5. Evaluation (section 5) on the 8 IMG runs, then install on the phone.

## Not in scope
- Decorative image layers (Phase B, which needs the owner's files).
- Mixing aspects: for example, 3:4 pages in a 4:5 carousel.
- A preference model learned from the owner's picks. This comes after the first round of evaluation, once there are enough labels.
- Compatibility groups across families beyond "same family". The owner curates them from the contact sheets later.

## Results
Task 2 page catalogue (2026-09-29): 212 usable records (80 4:5: 67 single pages and 13 linked runs; 119 3:4: 106 single pages and 13 linked runs; 13 square: 12 single pages and 1 linked run). The 4:5 catalogue remains below its 150-record target; 3:4 exceeds its 100-record e2e threshold. Latency and evaluation results are pending later build steps.

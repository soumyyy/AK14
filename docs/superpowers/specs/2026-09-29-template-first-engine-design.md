# Template-first engine

Status: draft for owner review (2026-09-29). Reviewed with GPT-6 Astra; its claims below were checked against the code.

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
- **Aspect.** Carousels are 4:5 today, so only 4:5 pages are used. 3:4 pages are catalogued but not used (a later decision).
- **Contact sheets** of the rescued pages are written to `/tmp` for owner review. They are never committed.
- **Target:** at least 150 usable 4:5 pages, up from a few dozen reachable now (mostly plain grids). The actual count is recorded in the spec's Results section.

## 2. Best-pairing placement (Core/Layout)
- A new `SlotAssignment` finds the lowest-cost assignment of photos to a page's slots using exhaustive permutations (at most 8 slots, 40,320 permutations) or the Hungarian algorithm for more.
- Cost per photo–slot pair:
  - crop loss (1 − kept area)
  - a face-size penalty: the smallest face's height on the rendered slide must be at least 4% of the slide height, or the pair is infeasible
  - hero preference: the story's cover/hero photo wants the largest slot
  - hard infeasibility: kept area below 0.65, `facesFit` fails, or the subject crosses a page edge
- **One crop floor:** 0.65 everywhere, including `CropPlanner.fullBleedEligible`. The 0.58 exception is removed; the wide slots in section 4 take over the cases it covered.
- `TemplateVocabulary.build` uses `SlotAssignment` instead of zipping.

## 3. Template-aware planner (Director)
- Before the planner call, the app computes each photo's **shape class** and whether it has **people** (existing features). These go into the planner's photo list as two short tags, so no template descriptions are sent.
- The planner output (`Direction`) gains, as optional fields so old runs still decode:
  - `moments`: an ordered list of story moments. Each moment has a short label, `photos` (ranked alternatives, best first), `mustInclude` (0–2 photos) and `size` (`1`, `few`, `many`).
  - `coverCandidates`: 1–3 photos.
  - `titleIdeas`: 1–3 strings of at most 40 characters. `titleIdea` stays for compatibility and becomes the first entry.
- Prompt changes in `planner.system.md`:
  - remove "The page is mostly white…" and `recommendedSlideCount = number of photos`
  - add: "Group photos by moment. List alternatives inside a moment; the layout engine chooses how many to show and how to lay them out."
  - keep the rule that options differ, but by story angle and cover, not by forced photo overlap quotas
- `ArtDirector.plannerContent` stops converting the requested slide count into a requested photo count. The slide count is a soft target the search respects (±1).
- The exact-set and keep-order modes are unchanged. There, every moment's photos are all mandatory and their order is fixed.

## 4. The search (Core/Compose)
A new `PageSearch` replaces group-then-fit for non-baseline options.

- **Input:** moments, the catalogue restricted to one family (or compatibility group), the target slide count, and the photo features.
- **State:** position in the moments; photos used so far; pages placed; whether a title has been placed; the last two page roles, for rhythm.
- **Step:** place one page or linked run. It consumes k photos drawn from the current moment and, with a penalty, from the neighbouring moment, using `SlotAssignment`. Slide 1 must be a cover-capable page containing a `coverCandidates` photo.
- **Beam:** keep the best 48 states per step. Assignments are cached per (page, photo set). Budget: at most 250 ms per option on an iPhone 17 (measured in the e2e test on the simulator, and later on the device).
- **Score** (higher is better; weights are constants in one file):
  - authored-design fidelity: the page is used with its original proportions, margins and typography, with bonuses for keeping an authored neighbour next, and for a title page as the cover
  - story value: the planner's ranking of the photos used, and every `mustInclude` photo present
  - readability: face size, and a title that fits with enough contrast
  - rhythm: busy (grid, strip) and quiet (statement, quiet) pages mixed, with a penalty for 3 or more pages of the same role in a row, rather than strict alternation
  - penalties for crop loss, repeating the same page in a carousel, photos moved between moments, and missing the target slide count
- **Wide photos get wide slots.** `band` and `wide` slots are preferred for wide photos: two landscapes stacked, a landscape band with space for type, or a landscape plus a strip of detail shots. A 16:9 photo is never forced to fill a 4:5 slot (that keeps only 45% of it).
- **Last resort.** When no page in the family can hold a photo, the search may use the white card (`hero.clean`) for that photo. Each use carries a large penalty and is recorded as a warning.
- **Options.** Run the search for each candidate family. Keep the best result per family, then show the top 2–3 across families, in `ComposerEngine.composeSet`. The overlap remedy stops swapping out good photos just to meet a quota. The photos-only baseline stays as one option.
- **Recipe.** The winning pages, assignments and crops are stored in the plan. `LayoutResolver.resolve` renders that recipe directly. `templateFamilies` reads the recipe and no longer re-resolves.

## 5. Evaluation
- **`ak14 eval pairs --compare <old> <new>`:** blind pairs showing the same photos laid out by the old and new engine, to isolate the layout change. Then full-pipeline pairs.
- **"Would post" rating:** yes / almost / no for each option, shown at full slide size.
- **Report:**
  - owner preference, new versus old
  - the share of runs where no option is postable
  - the worst option's rating per run
  - white-card rate and median crop kept, as warning signs
- **Acceptance:**
  - the owner prefers the new engine in at least 70% of layout pairs on the 8 IMG runs
  - no run has zero postable options
  - white cards are at most 10% of slides, with no important group photo dropped to get there

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
- Latency: `PageSearch` on the 60-photo fixture stays within budget.
- Old runs still decode and re-render.

## Build order
1. Page catalogue and page rescue (section 1), plus owner review of the contact sheets.
2. Best-pairing placement and a single crop floor (section 2). Worth measuring on its own.
3. Planner fields and prompt (section 3), including a Worker style-config version bump if the config changes.
4. `PageSearch`, scoring, options and recipe rendering (section 4).
5. Evaluation (section 5) on the 8 IMG runs, then install on the phone.

## Not in scope
- Decorative image layers (Phase B, which needs the owner's files).
- Using 3:4 pages in 4:5 carousels.
- A preference model learned from the owner's picks. This comes after the first round of evaluation, once there are enough labels.
- Compatibility groups across families beyond "same family". The owner curates them from the contact sheets later.

## Results
To be filled in during implementation: usable page count, latency, and evaluation numbers.

# AK14 — Todo

Plan: `docs/superpowers/plans/2026-09-26-m1-harness-analyzer-report.md`
Spec: `docs/superpowers/specs/2026-09-26-ak14-phase0-design.md`

## M1 — Harness, analyzer, report
- [x] 1. Package scaffold and Core models
- [x] 2. Aspect inference and concurrent map
- [x] 3. Run store, manifest, analysis cache
- [x] 4. Folder ingest (hashing, metadata, skip reasons)
- [x] 5. Thumbnailer
- [x] 6. Vision analyzer
- [x] 7. HTML report builder
- [x] 8. CLI arguments and entry point
- [x] 9. Run pipeline, report rebuild, end-to-end test
- [x] 10. Exit demo on real `IMG/` (458 photos, 42 videos skipped)

## Later milestones
- [x] M2 — Clustering, junk filter, candidate reduction
- [x] M3 — Triage + planner (Plain first), GPT-6 Luna
- [x] M4 — Layout resolver + renderer
- [x] M5 — Studio (Mac app)
- [x] M6 — Study readiness

## Review — M1 (2026-09-26)
- Testing: per the user, no unit tests. Four e2e tests in `Tests/CLITests/PipelineTests.swift` (mixed folder, symlink + recursive + aspect override, video-only, missing folder), all passing.
- Real run on `IMG/`: 458 photos, 42 skipped (all video), 0 warnings, 0 absolute paths in the report.
  - Cold run 28 s (ingest 3.8 s, thumbnails 12.8 s, analysis 10.8 s). Warm run 3.6 s with 458/458 cache hits and the same input digest.
  - 294 portrait / 164 landscape (64% portrait), so aspect inferred as 4:5.
  - 77 photos with no camera metadata (received/forwarded), 80 with no GPS, 2 with an assumed time zone, 0 exact duplicates.
  - 249 photos with faces, 13 flagged utility. Aesthetic score median 0.53 (range -0.86 to 0.78).
- `ak14 report <run>` rebuilds a byte-identical report. Thumbnails of EXIF-rotated HEICs come out upright.

## Review — M2 + M3 (2026-09-26)
- Plan: `docs/superpowers/plans/2026-09-26-m2-m3-reduction-and-director.md`.
- E2E tests: 14 passing.
  - Reduction: bursts cluster, black frames are rejected.
  - Director (fake model): happy path, repair, fallback when every call fails, 429 retry, tiny folder.
  - Rerender produces byte-identical PNGs.
  - M1 suite still passes.
- Clustering calibrated on IMG/: feature-print distance ≤0.10 = burst duplicate, ≤0.30 = same moment reframed, ~0.35 = different pose, random pairs ≈1.0.
- Real run on IMG/:
  - 458 photos → 191 distinct moments (79 shot groups, 16 near-duplicate bursts; largest cluster has 19 frames).
  - 0 junk rejects, 32 penalized.
  - 60 shortlisted (48 by rank, 12 exploration) → 35 in the planning pool → 10–12 in the spine.
- Live GPT-6 Luna:
  - First run needed triage + planner + 1 repair ($0.0065, 77 s).
  - After deriving Plain from the spine in code, it needs 2 calls ($0.0049).
  - All three concepts valid; Designed and Wildcard are distinct (different cover, primitive mix, density, decoration).
- Plain Dump slides render face-safe. Hero slides use a paper background.
- To watch: the triage prompt's emotional scoring against conventional-aesthetic bias, which needs your own picks to evaluate.

### M2+M3 review fixes (all 11 findings)
- Old runs reopen: tolerant decoding for manifest and photo metadata.
- A flagged face is never the cover: spine cover checked, first unflagged photo moved to the front, fallback spine included.
- Local outlier face-quality flags (≤0.05 on 1–2-face photos) are shown to the planner.
- Repair/retry keeps the best result: spine validity first, then the number of valid concepts, then issue count.
- A failed first planner call is still retried.
- Failed calls record billed usage, retries and latency, and are written to `llm/`.
- `.env` with Windows line endings is read.
- `--slides` is enforced.
- An invalid spine makes Designed and Wildcard unavailable.
- One bad photo only loses its own slide; rerender stages into a temp folder and swaps.
- The report shows the post-junk representative.
- Undated photos share one time bin.
- Rulings:
  - Face-quality flag threshold is 0.05 on 1–2-face photos, not 0.15. Real data has a median of 0.14, so 0.15 flagged a third of the shortlist. Cost if wrong: a borderline blink could still become the cover, but model triage still flags blinks.
  - Diversity passes with 3+ structural differences and a different cover, regardless of photo overlap. Cost if wrong: concepts could share most photos, but structure still differs.
  - The API timeout drops from 240 s to 180 s.
- Deferred minor: task cancellation is not propagated during retry backoff.

## Review — M4 (2026-09-26)
- `LayoutResolver` (Core, seeded, deterministic): all 6 primitives, face-safe crops, face-aware inset corners and pair overlap, overlap-cluster search (24 placements × 3 scales) for ≥55% visibility and uncovered faces, tape/grain/paper/film-edge placement, DSEG7 date stamps.
- `CarouselRenderer` (Render): procedural style layer, bundled OFL font, per-slide failure isolation. It replaces `PlainRenderer`.
- Every concept renders to `slides/<concept>/` with layouts in `layouts/<concept>/`.
- `rerender --source <folder> [--seed HEX]` re-renders all concepts atomically, with no model calls.
- E2E: 22 tests passing, covering rendered counts, bounds, visibility/face constraints, byte-identical rerender, seed change, undated stamps and location-stamp omission.
- Real run on IMG/: 2 calls, $0.0046, render 2.6 s for 23 slides.
- Fixed after visual review: landscape heroes now crop toward square (face-safe) instead of floating small; the paper texture is smoothed and subtler.
- Rulings:
  - Location stamps are omitted: they would need a network geocoder, which Phase 0 privacy excludes.
  - Core uses CryptoKit for seed hashing (not an imaging framework).
  - Decorations are procedural instead of downloaded assets, so there are no licensing issues.

### M4 review fixes (all 9 findings)
- The date stamp's year tick is drawn as a path (DSEG7 has no apostrophe glyph, so no system-font fallback).
- Stamps use the camera's own wall-clock date (`localDateTime`), so they're machine-independent. Older runs fall back to UTC.
- Film-edge bands are reserved before layout: margins, full-bleed and inset frames, and stamps all stay clear.
- A full-bleed crop that would cut faces becomes a whole-photo hero, with a warning. Landscape heroes crop to square only when faces fit.
- Crops are re-clamped after anchor shift and tight zoom so faces stay in.
- A slide with no usable photos renders empty with a warning, instead of crashing.
- The date stamp avoids other photos, not just faces.
- Rerender swaps slides and layouts together, with rollback.
- Overlap coverage is measured on a grid, so there's no double counting.
- E2E: 24 tests passing.
- Deferred minor: overlap and face checks use unrotated boxes (at most ±2°, about 15 px).

## Review — M5 (2026-09-26)
- `PlanEditor` (Core): reorder, swap, remove. Removing a slide's last photo drops the slide (no padding); a photo-count mismatch downgrades the primitive; Plain stays one photo per slide.
- `Session` target:
  - `ConceptRendering` moved here from CLI.
  - `RunSession`: open, SHA-verified source folder, edits in `edits/`, reroll with a new layout seed, export of ordered PNGs, share logging.
  - `InteractionLog`: append-only `interaction-events.jsonl`, with no paths or free text.
- `Studio` (SwiftUI, `swift run Studio`):
  - run picker; three concept columns with Use this / Reroll layout / Export… / Share (NSSharingServicePicker, logs the chosen service)
  - slide inspector with move earlier/later, Swap (similar shots first) and Remove
  - the source folder is remembered in app preferences, never in the run directory
- Verification:
  - 27 e2e tests passing, including Session edits, originals untouched, event order, export, invalid edits and a changed source.
  - Snapshot mode (`AK14_STUDIO_SNAPSHOT`) rendered the real run's board off-screen: columns, slides, selection and inspector all render. Text isn't captured by off-screen caching, and a window screenshot needs Screen Recording permission, so the labels still need a check by eye with `swift run Studio`.

### M5 review fixes (all 11 findings)
- report.html now shows Studio edits (edited strips and the change against the original) and the full interaction event log. `ReportCommand` moved to `Session.RunReport`, and it's rebuilt after every Studio operation.
- Mutating operations are serialized in `RunSession`. Studio refuses a new edit while one is running and disables edit buttons. Selection follows a move only after it succeeds.
- Each edit renders into a private staging folder, and `edits/<concept>/` (plan, seed, slides, layouts) is swapped in with one rename. Memory is updated last; a failed reroll leaves everything unchanged.
- Export clears any earlier export of the same concept in the folder, and refuses to export zero slides.
- Swapped-in photos are hash-verified. Source verification runs off the main thread and explains why a remembered folder was rejected.
- Select and Share log without needing a source folder.
- Events: `slide_reordered` carries the moved photos, and `cover_changed` is logged when the cover changes.
- Slide images are cached and only reloaded after a render.
- E2E: 31 tests passing.

## Review — M6 (2026-09-26)
- `ak14 run --study-code P07`: the code is validated as pseudonymous. The provider disclosure and a consent prompt come before any model call (`--yes` for scripted runs), and consent is recorded in the manifest. Without consent, nothing is sent.
- Interrupted runs: the manifest is written early, and runs without `completedAt` are shown as incomplete and never counted. A re-run reuses the local cache.
- `ak14 followup`: structured day-7 answers, no URLs or free text.
- `ak14 study summary`: the pre-registered bar (≥50% minimum at the 30% rule, with 20%/40% sensitivity; ≥33% posted within 7 days), picks, edit burden, repeat demand, cost and latency. Writes .md and .json.
- `ak14 delete --purge-cache`: removes the run and any cache entries no other run uses.
- `ak14 versions`: the version list frozen into `docs/study/protocol.md`.
- Docs: `docs/study/protocol.md`, `consent.md`, `operator-guide.md`.
- E2E: 34 tests passing, plus an opt-in operator dry-run test.
- Dry run on IMG/ as DRY01:
  - live run: 2 calls, $0.0045
  - Studio-equivalent edits (reorder, swap, reroll), select, export (8 slides)
  - follow-up, then summary: met both bars at n=1
  - report shows the events; 0 absolute paths
  - delete kept the shared cache that older runs use
- Open item for you: verify OpenAI's current API data-retention terms before recruiting (protocol §Privacy).

### M6 review fixes (all 10 findings)
- A study run must be completed, consented and have concepts. No-consent or failed runs are reported separately and never count as the study run or repeat demand.
- The model gets "a personal event" and a day count only, never the folder name (which could contain a code or a name) or calendar dates.
- `ak14 delete` refuses anything that isn't a single run. `ak14 delete --study-code` removes all of a participant's runs, including interrupted ones. `input-index.json` is written early so their cache can be purged.
- Follow-up records `--posted-days`. Posted within 7 days requires days 0–7 and a hand-off of the selected concept.
- Metrics score the plan snapshotted at hand-off (`handoffs/`). A reroll counts only if it came before the hand-off.
- Share is logged only on `didShareItems`, not when a service is picked.
- Follow-ups are read across all of a participant's runs.
- The median is correct for even counts. Unknown metrics count as not successful.
- E2E: 39 tests passing.

## Engine fixes from the selection/framing/placement audit (2026-09-26)
Audit: Cursor/GPT-5.6 Sol, findings verified against runs/20260926-050016-e91f0c. Future audits use Claude only.
1. Hero hierarchy: the model used importance 1 for heroes, so supporting photos got the big frame. The hero role is now authoritative, and the schema and prompt define 3 = most prominent. Live check: the hero is dominant on 4/4 two-photo slides.
2. Planner sees every candidate: it got images for 24 of 35, and every pick came from those 24. Now all 35 are sent (about +$0.0002). The live spine now includes pool position 28.
3. Crops protect people, not just faces: significant people (≥20% of height) may lose at most 12% of their width per side, must keep their head, and must keep 60% of their height. Otherwise the photo is shown whole where the slide has a background; full-bleed falls back to a whole-photo hero. Live check: the outstretched arms in Plain slide 1 are kept.
6. Photos triaged ≤1/5 (and not flagged useful) stay out of the planning pool when enough others remain. Live check: 0 weak photos in the pool.
- Seen during verification: two-photo slides use fixed box shapes, so a landscape hero shown whole floats small. This feeds into #5.

## #5 Placement engine (2026-09-26)
Principle (user): every concept must be postable and aesthetic. Wildcard is bolder in character, never lower in quality.
- [x] Composer: each multi-photo and single-photo primitive generates candidate arrangements (variants), whose box shapes follow the photo aspect (exact, or 35% toward square)
- [x] Score: crop loss, people safety, overlap/face safety, hero share (pair/inset ≥1.6×, cluster ≥1.25×), density target (quiet/balanced/dense), balance, carousel rhythm (no same family twice in a row)
- [x] Choose among the near-best candidates by seed (deterministic, not templated)
- [x] Clusters: several anchor sets plus mirrors, the hero 1.2× larger, and size set by density
- [x] Slide `variant` and `metrics` (coverage, heroShare, maxCropLoss) in layouts and the report
- [x] Prompt: Wildcard is "bold, not chaotic", and every slide must be postable on its own
- [x] E2E updated. Rerender the latest IMG run (no model cost), inspect montages, compare metrics before and after
- [ ] Claude subagent review, then fix, merge and push
- Live rerender of runs/20260926-081711-fee7af (no model cost), layout-1 → layout-2:
  - largest crop on framed slides: 55% → 10% (Designed), 55% → 18% (Wildcard)
  - hero share: Designed 1.38× → 1.7×+; Wildcard cluster hero 0.6× → 1.2×
  - two-photo slides: stacked, aspect-matched boxes (the landscape hero no longer floats small)
  - average coverage on framed slides is about 50% (was 56%, but that was from 55% crops). The remaining whitespace is landscape group shots that can't be cropped without cutting people.
  - consecutive repeated arrangements: 0
- E2E: 40 tests passing (new: composer hierarchy, crop, coverage and rhythm)

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
- [ ] M5 — Studio (Mac app)
- [ ] M6 — Study readiness

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

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
- [ ] M2 — Clustering, junk filter, candidate reduction
- [ ] M3 — Triage + planner (Plain first), GPT-6 Luna
- [ ] M4 — Layout resolver + renderer
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

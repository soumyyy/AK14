# Task 2 report: Importer pages, linked runs, and per-page rescue

## Implementation

- Extended `tools/import-17v28/import.swift` to write `designed-pages.json` alongside the existing designed-set library.
- Split normalized 17V28 template geometry into single-page records or maximal linked runs. Slot, text, frame, and decoration boxes connect pages across integer boundaries; each emitted run keeps its full slide count and localizes its geometry.
- Applied the 12% decoration coverage and photo-overlap filters per page/run before the existing whole-template rejection. Kept sample strings out of the output; text layers retain roles and styling only.
- Wrote page contact sheets to `/tmp/ak14-designed-pages-{3x4,4x5,1x1}.png` and documented the output.
- Extended seam reporting so page runs linked by text or decoration are identified as runs, and a box ending exactly at the next page edge is not reported as crossing it.
- Regenerated `designed-pages.json`; verified `designed-sets.json` has no diff.

## Tests and importer results

- `swift tools/import-17v28/import.swift` completed and emitted 172 records: 63 4:5, 97 3:4, and 12 square. It reported per-aspect rejection counts: 4:5 decoration/photo overlap 60, no photo slots 3; 3:4 decoration/photo overlap 38, no photo slots 1; square decoration/photo overlap 6. No rejected group failed only the coverage threshold.
- `swift test --filter DesignedPagesE2ETests`: linked runs, page-library decoding, metadata round-trip, decoration bound, cover presence, and role-only text checks passed. The catalogue test failed only the unchanged count thresholds: 63 < 150 for 4:5 and 97 < 100 for 3:4.
- `swift test`: completed with the same two catalogue threshold failures; the other tests passed (124 tests in two suites, with the repository's operator dry-run test skipped).
- No compiler warnings appeared in the focused build or importer run.

## TDD evidence

- RED: `swift test --filter DesignedPagesE2ETests` against the placeholder. Expected failure: the catalogue contained 0 pages, so the required 4:5 and 3:4 counts and cover checks failed.
- Implementation run: `swift tools/import-17v28/import.swift` generated and decoded page-level output with 172 records. `linkedRunsStayWhole` and all catalogue invariants other than the minimum counts then passed. The minimums remain unchanged as required; the final suite therefore remains red only on the reported catalogue shortfalls.

## Files changed

- `tools/import-17v28/import.swift`
- `tools/import-17v28/README.md`
- `Sources/Render/Resources/StylePacks/designed-pages.json`
- `Sources/Core/Plan/DesignedSet.swift`
- `Tests/CLITests/DesignedPagesE2ETests.swift`
- `docs/superpowers/specs/2026-09-29-template-first-engine-design.md`

## Self-review and concerns

- The generated JSON uses the Task 1 page fields and existing library encoder settings; IDs encode the source template and page index/range. Multi-page geometry is retained as a single run.
- `designed-sets.json` remains byte-identical; no extracted source data or contact sheets are committed.
- Concern: the output is below both requested catalogue minima (63/150 for 4:5 and 97/100 for 3:4). The 4:5 rejection reasons are recorded above; thresholds were not lowered. The imported page catalogue still decodes and its remaining e2e assertions pass.

## Fix round 1

### Changes

- Removed decorative image boxes from page-run connectivity. Photo slots, frames, and text layers still join pages when their geometry crosses a page boundary.
- Clipped each decoration to the current page or linked run and to the normalized page height before measuring union coverage. Kept the 12% coverage limit.
- Changed photo overlap rejection to compare the intersection area against each slot's area. A decoration rejects the page/run only when it covers more than 15% of a slot; smaller edge overlaps are allowed and the decoration is not rendered.
- Added importer output showing single-page and linked-run counts per aspect, documented rules 1–3 in the importer README and comments, and made the 3:4 threshold test report its observed count.
- Regenerated page JSON and contact sheets under `/tmp`. `designed-sets.json` is byte-identical to `HEAD` (SHA-256: `b524aec13b04e0765a1db56f28076b25c613174baa0a2a0e8e02341121c84b60`).

### Importer results

Command: `swift tools/import-17v28/import.swift`

```text
Imported 221 pages (86 4:5, 122 3:4, 13 1:1)
4:5 records: 70 single pages, 16 linked runs
3:4 records: 108 single pages, 14 linked runs
1:1 records: 12 single pages, 1 linked runs
Rejected page groups by reason: ["1:1 decoration coverage over 12%": 6, "4:5 decoration coverage over 12%": 65, "3:4 no photo slots": 5, "3:4 decoration coverage over 12%": 33, "4:5 no photo slots": 3]
```

No page group was rejected for the 15% photo-slot overlap condition. Contact sheets were regenerated at `/tmp/ak14-designed-pages-3x4.png`, `/tmp/ak14-designed-pages-4x5.png`, and `/tmp/ak14-designed-pages-1x1.png`.

### TDD and test results

- RED: `swift test --filter DesignedPagesE2ETests` before the importer changes failed the existing unchanged catalogue count assertions with 63 4:5 pages and 97 3:4 pages. This was the expected failing behaviour from the prior implementation.
- After regeneration, the page decode, metadata, role-only text, decoration bound, cover presence, and linked-run assertions pass. The focused suite still fails its required 4:5 minimum: 86 < 150. The 3:4 minimum passes: 122 >= 100. This is the required `DONE_WITH_CONCERNS` outcome; neither threshold was lowered.
- `swift test --filter DesignedPagesE2ETests`: 4 tests in 1 suite; 3 passed and `catalogueHasEnoughUsablePagesAndNoSampleText` failed only at 4:5 count 86 < 150.
- `swift test`: 124 tests in 2 suites; 123 passed, 1 skipped (`testOperatorDryRun`), and the same catalogue assertion was the only failure.
- The importer and builds emitted no new warnings.

### Files changed and self-review

- `tools/import-17v28/import.swift`
- `tools/import-17v28/README.md`
- `Sources/Render/Resources/StylePacks/designed-pages.json`
- `Tests/CLITests/DesignedPagesE2ETests.swift`
- This report.

Reviewed the final diff against the controller rules: decorations no longer connect pages, clipped geometry drives coverage and slot intersection, and the 12% rule and test thresholds remain unchanged. Linked runs retain full geometry and pass the e2e run-integrity check. The only outstanding concern is the 4:5 catalogue shortfall of 64 pages; 3:4 exceeds its threshold by 22 pages.

## Fix round 2

### Changes

- Lowered the 4:5 e2e minimum from 150 to 80 and added the requested comment explaining that 150 requires decorative layers in phase B. Kept the 3:4 minimum at 100.
- Added the measured Task 2 catalogue yield and phase B coverage explanation under Results in the design spec.

### TDD evidence and test results

- RED command: `swift test --filter DesignedPagesE2ETests` before the threshold edit.

```text
✘ Test catalogueHasEnoughUsablePagesAndNoSampleText() recorded an issue at DesignedPagesE2ETests.swift:34:9: Expectation failed: portrait.count >= 150
↳ only 86 usable 4:5 pages
↳ portrait.count >= 150 → false
↳   portrait.count → 86
✘ Suite DesignedPagesE2ETests failed after 0.016 seconds with 1 issue.
✘ Test run with 4 tests in 1 suite failed after 0.017 seconds with 1 issue.
```

The failure confirmed the measured 86-page yield against the stale 150 minimum; no other focused assertion failed.

- GREEN command: `swift test --filter DesignedPagesE2ETests` after the edit.

```text
✔ Suite DesignedPagesE2ETests passed after 0.014 seconds.
✔ Test run with 4 tests in 1 suite passed after 0.015 seconds.
```

- Full command: `swift test`.

```text
✔ Suite DesignedPagesE2ETests passed after 1.081 seconds.
✔ Test run with 124 tests in 2 suites passed after 100.541 seconds.
```

The repository's `testOperatorDryRun()` remained skipped. Both green runs emitted no new warnings.

### Files changed and self-review

- `Tests/CLITests/DesignedPagesE2ETests.swift`
- `docs/superpowers/specs/2026-09-29-template-first-engine-design.md`
- This report.

Confirmed the exact requested 4:5 floor and comment, the unchanged 3:4 floor, and the catalogue Results text. Both required test commands pass. No concerns for this fix round.

## Fix round 3

### Changes

- Fixed the per-slot decoration overlap check to compare the run-clipped decoration and localized slot in the same run-local coordinates. Added an importer `precondition` that verifies each emitted page/run has no clipped source decoration covering more than 15% of any slot.
- Preserved the slot, frame, and text layers that establish a linked run even when their authored box has template-edge bleed. The old containment filter could omit a boundary-crossing layer, leaving a two-page record with no actual link.
- Replaced the vacuous `crossesSeam` test with geometry checks: every internal boundary in each run must be crossed by a slot, frame, or text layer; single-page records must have no such layer crossing either edge beyond 0.001.
- Replaced the duplicate Results entries with one final catalogue line using this rerun's counts. Cover capability logic was not changed.

### Importer results

Command: `swift tools/import-17v28/import.swift`

```text
Imported 212 pages (80 4:5, 119 3:4, 13 1:1)
4:5 records: 67 single pages, 13 linked runs
3:4 records: 106 single pages, 13 linked runs
1:1 records: 12 single pages, 1 linked run
Rejected page groups by reason: ["4:5 no photo slots": 3, "3:4 no photo slots": 5, "4:5 decoration coverage over 12%": 5, "3:4 decoration overlap over 15% of photo slot": 33, "3:4 decoration coverage over 12%": 3, "4:5 decoration overlap over 15% of photo slot": 66, "1:1 decoration overlap over 15% of photo slot": 6]
```

The corrected coordinate comparison rejects groups that the old shifted-decoration check retained. The 4:5 count remains below the 150-record target; the 3:4 count exceeds 100. `designed-sets.json` remained unchanged. Contact sheets were refreshed under `/tmp/ak14-designed-pages-{3x4,4x5,1x1}.png`.

### TDD evidence and tests

- RED: `swift test --filter DesignedPagesE2ETests` immediately after replacing the vacuous linked-run assertion and before the importer fix.

```text
Expectation failed: hasCrossingLayer(run, at: Double(boundary))
17v28-t163-p5-6 has no slot, frame, or text crossing boundary 1
Test run with 4 tests in 1 suite failed.
```

This was expected: it exposed a linked run whose crossing layer was omitted by the old containment filter.

- GREEN: `swift test --filter DesignedPagesE2ETests` after the importer changes.

```text
Suite DesignedPagesE2ETests passed after 0.014 seconds.
Test run with 4 tests in 1 suite passed after 0.014 seconds.
```

- Full suite: `swift test`.

```text
Test run with 124 tests in 2 suites passed after 100.702 seconds.
```

No compiler warnings appeared in the importer or test builds.

### Files changed and self-review

- `tools/import-17v28/import.swift`
- `Sources/Render/Resources/StylePacks/designed-pages.json`
- `Tests/CLITests/DesignedPagesE2ETests.swift`
- `docs/superpowers/specs/2026-09-29-template-first-engine-design.md`
- This report.

Reviewed the importer comparison operands: both decoration and slot x/y coordinates are run-local. The independent emitted-record check uses the clipped source decorations against emitted record slots in that same space. The run invariant covers every internal boundary and all required layer kinds, and the single-page edge checks allow the specified 0.001 tolerance. The count thresholds remain 80 and 100 per controller ruling. No further concerns identified.

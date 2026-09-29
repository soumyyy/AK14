# Task 5 report: Template-aware planner

## Implementation

- Added public `Direction.Moment` data with `sizeRange`, optional decoding defaults for old directions, and precedence from moments / cover candidates / title ideas when moments are present. Cleaned every title idea through the existing title sanitizer.
- Extended the strict planner schema with moments, cover candidates, and title ideas; raised direction `orderedAssetIDs` to 30.
- Added moment validation for duplicate and unknown photos, empty moments, must-include membership, valid size labels, exact-set completeness, keep-order preservation, and cover-candidate membership. The legacy requested-slide grouping check and 20-photo maximum remain unchanged for directions without moments.
- Updated the planner prompt to v10 with moment and alternative guidance, removed the white-page instruction and overlap quota, and retained the spine photo-count rule.
- Added the requested slide-target note after the existing spine target without adding any planner request.
- Added `ShapeClass` tags to CLI and iOS photo summaries, plus an iOS face-count tag.
- Extended the fake planner and `RunPipeline` e2e coverage for moment precedence and the existing repair path. Kept the baseline fake response legacy-shaped so existing composer/replay e2e cases continue to cover directions without moments.

## TDD evidence

- RED: `swift test --filter DirectorE2ETests`
  - Failed to compile because `Direction` had no `moments`, `coverCandidates`, or `titleIdeas` members, as expected before implementation.
- GREEN: `swift test --filter DirectorE2ETests`
  - Passed: 14 tests, 0 failures. Moment precedence and invalid-moment repair are exercised through `RunPipeline` with the existing fake model.
- Full verification: `swift test`
  - Passed: 133 tests across 3 suites, 0 failures.
- iOS build: `xcodebuild build -project iOS/AK14iOS.xcodeproj -scheme AK14iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -quiet`
  - Passed (exit 0). The requested destination without `OS` resolved to unavailable iOS 27 and failed to find a matching simulator; iPhone 17 Pro is installed on iOS 26.2, which built successfully.
- `git diff --check`: passed.

## Files changed

- `Sources/Core/Plan/Direction.swift`
- `Sources/Core/Plan/PlanValidator.swift`
- `Sources/Director/Schemas.swift`
- `Sources/Director/ArtDirector.swift`
- `Sources/Director/Resources/Prompts/planner.system.md`
- `Sources/CLI/RunPipeline.swift`
- `Sources/iOSApp/StoryPipeline.swift`
- `Tests/CLITests/DirectorE2ETests.swift`

## Self-review

- Confirmed field names and schema limits match the brief; no additional model call was introduced.
- Old directions decode with empty new fields; their validator rules keep the 20-photo limit and requested-slide check.
- The validator test was exercised through the authorized e2e `RunPipeline` repair flow rather than a direct validator call, per the binding e2e-only test constraint.
- The prompt contains no remaining v9 header, white-page instruction, or photo-overlap quota.
- No new warnings were introduced. Existing package/Xcode diagnostics observed during builds were in untouched files or Xcode destination metadata.

## Concerns

- The exact simulator destination from the brief is not available under the installed latest runtime. The explicit iOS 26.2 iPhone 17 Pro build passed.

## Fix round 1

### Changes

- Strengthened the planner e2e fake so its `orderedAssetIDs` differs from the moment flattening, its raw cover differs from the first cover candidate, and it returns `1`, `few`, and `many` sizes. The test asserts derived order, cover, title, and all three size ranges.
- Added separate planner responses that violate only a moment-specific rule: must-include outside its moment, cover candidate outside moments, unknown size, and empty cover candidates. Each reaches repair through `RunPipeline`.
- Removed redundant duplicate, unknown-photo, exact-set, and keep-order moment checks from `PlanValidator`; the derived `orderedAssetIDs` checks enforce them. Kept moment-unique validation and added non-empty cover-candidate validation when moments exist.
- Removed `ArtDirector.decode`'s keep-order rewrite of direction IDs, which masked the `orderedAssetIDs` check. Added an e2e keep-order case showing shuffled moments reach repair.
- Changed the iOS summary face tag to `1 face` / `N faces` without force-unwrapping.

### TDD and verification evidence

- RED: `swift test --filter DirectorE2ETests`
  ```text
  ✘ Test shuffledMomentsAreFlaggedByOrderedAssetIDsUnderKeepOrder ...
    model.stages → ["triage", "planner"]
  ✘ Test invalidMomentsTriggerTheExistingRepairPath ...
    .emptyCoverCandidates
    model.stages → ["occasion_split", "triage", "planner"]
  ✘ Test run with 15 tests in 0 suites failed ...
  ```
  The first output showed keep-order validation was being masked by direction-order rewriting; the second showed empty cover candidates were not validated. The other moment-specific cases already reached repair.
- GREEN: `swift test --filter DirectorE2ETests`
  ```text
  ✔ Test shuffledMomentsAreFlaggedByOrderedAssetIDsUnderKeepOrder() passed
  ✔ Test invalidMomentsTriggerTheExistingRepairPath() passed
  ✔ Test run with 15 tests in 0 suites passed after 35.624 seconds.
  ```
- Full suite: `swift test`
  ```text
  ✔ Test run with 134 tests in 3 suites passed after 124.172 seconds.
  ```
- iOS build: `xcodebuild build -project iOS/AK14iOS.xcodeproj -scheme AK14iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' -quiet`
  ```text
  2026-09-30 01:47:50.522 ... [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
  exit_code: 0
  ```
- `git diff --check`: passed.

### Files changed in this fix

- `Sources/Core/Plan/PlanValidator.swift`
- `Sources/Director/ArtDirector.swift`
- `Sources/iOSApp/StoryPipeline.swift`
- `Tests/CLITests/DirectorE2ETests.swift`
- `.superpowers/sdd/2026-09-29-template-first-engine/task-5-report.md`

### Self-review and concerns

- The moment-specific validation now remains limited to empty moments, must-include membership, allowed size, cover-candidate membership, and non-empty cover candidates. Duplicate/unknown/exact-set/keep-order photo validation flows through the derived direction `orderedAssetIDs` checks.
- All new behavior is covered through the `RunPipeline` e2e fake; no private-helper unit tests were added.
- The iOS build succeeded with Xcode's `IDERunDestination` metadata warning shown above. No other build warnings appeared.

## Fix round 2

### Changes

- Isolated `coverOutsideMoments`: the fake now puts a valid moment photo first in `coverCandidates` and a pool photo absent from that direction's moments second. This makes the candidate-subset rule the only failing cover rule.
- Restored the keep-order rewrite of `orderedAssetIDs` to pool order for directions with empty `moments`. Moment directions remain untouched and are validated.
- Added a `RunPipeline` e2e case for an out-of-order legacy direction under keep-order; it asserts no repair call and checks all surviving legacy directions use the pool order.
- Removed the unused outer temp directory in `invalidMomentsTriggerTheExistingRepairPath` and removed the dead `.invalidMoments` behavior and fake branch.

### TDD and verification evidence

- Cover-membership RED: temporarily disabled only the `coverCandidates` subset validation and ran `swift test --filter DirectorE2ETests`.
  ```text
  ✘ Test invalidMomentsTriggerTheExistingRepairPath ...
    ↳ .coverOutsideMoments
    ↳ model.stages → ["occasion_split", "triage", "planner"]
  ✘ Test run with 15 tests in 0 suites failed ...
  ```
  The corrected fixture did not trigger the existing `coverAssetID` check; disabling the candidate rule alone removed the repair call. The validator rule was restored immediately afterward.
- Legacy-order RED: ran `swift test --filter DirectorE2ETests` before restoring the decoder behavior.
  ```text
  ✘ Test legacyDirectionsKeepOrderWithoutRepair ...
    ↳ status fallback; stages ["occasion_split", "triage", "planner", "repair", "retry"]
    ↳ directions.isEmpty → true
  ✘ Test run with 16 tests in 0 suites failed ...
  ```
  The out-of-order legacy direction was rejected and required repair, as expected before the rewrite.
- Focused GREEN: `swift test --filter DirectorE2ETests`
  ```text
  ✔ Test legacyDirectionsKeepOrderWithoutRepair() passed
  ✔ Test shuffledMomentsAreFlaggedByOrderedAssetIDsUnderKeepOrder() passed
  ✔ Test invalidMomentsTriggerTheExistingRepairPath() passed
  ✔ Test run with 16 tests in 0 suites passed after 33.537 seconds.
  ```
- Full GREEN: `swift test`
  ```text
  ✔ Test legacyDirectionsKeepOrderWithoutRepair() passed
  ✔ Test invalidMomentsTriggerTheExistingRepairPath() passed
  ✔ Test run with 135 tests in 3 suites passed after 122.371 seconds.
  ```
- `git diff --check`: passed.

### Files changed in this fix

- `Sources/Director/ArtDirector.swift`
- `Tests/CLITests/DirectorE2ETests.swift`
- `.superpowers/sdd/2026-09-29-template-first-engine/task-5-report.md`

### Self-review and concerns

- The cover fixture's first candidate is in the direction's moments, so its derived `coverAssetID` remains valid while the second candidate independently violates subset membership.
- The keep-order rewrite is scoped to legacy directions with empty `moments`; `shuffledMomentsAreFlaggedByOrderedAssetIDsUnderKeepOrder` still reaches repair.
- No concerns. The final focused and full test runs completed without new warnings.

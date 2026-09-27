# Designed Look v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make non-baseline carousels visibly designed by adding grounded cover titles, safe full-bleed selection, and deterministic distinct-option remedies.

**Architecture:** Keep title generation in the Core layout resolver so titles remain editable `ResolvedElement` values and are preserved by the existing document/render bridge. Centralize full-bleed eligibility around crop retention, people safety, and salient-subject retention, then use the same predicate in composition, resolution, and float scoring. Strengthen `PlanMetrics` and add a context-aware `composeSet` retry that changes covers, order, and limited photo selection without changing iOS APIs.

**Tech Stack:** Swift 6 SwiftPM, Core Codable layout models, deterministic `SeededRandom`, CoreText-backed existing renderer, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-27-designed-look-v1.md`

## Global Constraints

- Do not touch `Sources/iOSApp/**` or `Tests/iOSAppUITests/**`.
- Keep existing `ResolvedElement` and `LayoutContext` call sites source-compatible with defaulted parameters.
- Baseline carousels never receive a title.
- Titles use only `Direction.titleIdea` or a 3–28-character story hint.
- Full-bleed requires `facesFit`, salient retention of at least 85%, and crop retention of at least 0.58.
- Do not commit, stash, reset, or checkout.
- Verify `swift build`, full `swift test`, the requested iOS build, and all `/tmp/ak14-ft` real-photo rerenders.

## Review Focus

- A 4:3 landscape on a 4:5 canvas retains 0.60 of its crop and should be full-bleed when people and salient regions fit.
- A large human or salient subject outside the cover crop must force the existing white-card hero fallback.
- A title must avoid mapped face/human boxes, use deterministic style/region choices, and disappear when no grounded title exists.
- The baseline and a direction with an already-authored template title must not receive a second title.
- Small photo pools must use a deterministic order-distance fallback when the 0.7 Jaccard target cannot be met.

---

### Task 1: Add failing Core/CLI tests

**Files:**
- Modify: `Tests/CLITests/TemplateVocabularyTests.swift`
- Modify: `Tests/CLITests/ComposerE2ETests.swift`

**Interfaces:**
- Tests exercise `LayoutResolver.resolve`, `ComposerEngine.choosePrimitive`, `ComposerEngine.floats`, and `PlanMetrics.diversity`.
- No production API needs to change for the tests beyond internal helpers used with `@testable import Core`.

- [ ] **Step 1: Test grounded cover-title placement**
  Build a one-photo non-baseline plan with `titleIdea`, one without it, and a baseline plan. Assert the first direction has exactly one editable `textRole == "title"` element, the other direction and baseline have none, repeated resolution is equal, and the title frame does not intersect a mapped face/human box.

- [ ] **Step 2: Test title color and the full-bleed crop thresholds**
  Use dark and light feature fixtures to assert white/near-black title colors. Use a 4:3 landscape on a 4:5 canvas to assert full-bleed at 0.60 retention, then add an out-of-crop significant human and an out-of-crop salient region to assert `.hero` and `floats == true`.

- [ ] **Step 3: Test the stricter distinct-option metric**
  Assert that options with overlap above 0.7 fail unless their order agreement is at most 0.3, and that passing options have different covers plus a density/grouping axis difference.

- [ ] **Step 4: Run focused tests and confirm the intended failures**
  Run `swift test --filter TemplateVocabularyTests` and `swift test --filter ComposerE2ETests`. Expected failures are missing title insertion, stale crop threshold behavior, and the old diversity thresholds.

### Task 2: Implement grounded cover titles and safe full-bleed eligibility

**Files:**
- Modify: `Sources/Core/Layout/TemplateVocabulary.swift`
- Modify: `Sources/Core/Layout/LayoutResolver.swift`
- Modify: `Sources/Core/Compose/ComposerEngine.swift`
- Modify: `Sources/Core/Layout/CropPlanner.swift` only if a shared subject-retention helper is needed

**Interfaces:**
- Add deterministic internal title helpers that return normal `.text` elements with `textRole == "title"`.
- Keep existing public initializers unchanged; use existing `storyHint` defaults.
- Add one shared full-bleed eligibility calculation usable by composer and resolver paths.

- [ ] **Step 1: Implement the minimal title resolver**
  Resolve `titleIdea` first, then a 3–28-character story hint. On slide zero of non-baseline plans, choose a seed-derived script/editorial/small-caps style, rank the five specified safe regions by saliency/people avoidance, choose white for dark luminance and `#1A1A1A` otherwise, reject contrast below 3:1, and emit title/date text elements only when safe. Never add a title if a template already placed one.

- [ ] **Step 2: Keep authored template titles on the cover only**
  Prevent template text layers with role `title` from being populated after slide zero; retain the existing one-title and face-safe behavior.

- [ ] **Step 3: Use the same eligibility predicate everywhere**
  Replace the 30% bleed-loss check with crop retention `>= 0.58`, `CropPlanner.facesFit`, and salient-region area retention `>= 0.85`. Apply it in clean `choosePrimitive`, full-bleed resolver fallback, and `floats`.

- [ ] **Step 4: Run focused tests and refactor only after green**
  Run the two focused filters, then `swift test --filter TemplateVocabularyTests`. Keep the implementation deterministic for the same plan/context/seed.

### Task 3: Enforce distinct options in composition

**Files:**
- Modify: `Sources/Core/Plan/PlanMetrics.swift`
- Modify: `Sources/Core/Compose/ComposerEngine.swift`
- Modify: `Sources/Director/Resources/Prompts/planner.system.md`

**Interfaces:**
- `PlanMetrics.diversity` reports the existing `ConceptDistance` shape but applies the 0.7 Jaccard / 0.3 order-agreement fallback and density/grouping layout-axis rule.
- `ComposerEngine.composeSet` retries the later direction using deterministic cover, rotation, and bounded same-event pool substitutions, preserving exact-set/keep-order constraints.

- [ ] **Step 1: Implement stricter diversity predicates**
  Compute selection pass as Jaccard `<= 0.7` or Kendall agreement `<= 0.3`; require different covers and an actual density/grouping difference. Preserve the existing structural diagnostics and Codable shape.

- [ ] **Step 2: Add the deterministic remedy**
  When a later direction clashes, choose an unused strong cover, rotate its order to another story beat, and replace at most 30% of non-exact-set photos with unused high-strength same-event candidates. Recompose with stable seeds and record a warning for a successful remedy.

- [ ] **Step 3: Require template-family separation when templates are available**
  Compare resolved template family IDs for the candidate pair and include family choice in the remedy acceptance check; use the existing style-axis nudge sequence when family choice cannot change.

- [ ] **Step 4: Tighten the planner prompt**
  Add the exact rule from the spec that each direction must use a different cover and a noticeably different selection or sequence.

- [ ] **Step 5: Run composer/director focused tests and the full suite**
  Run `swift test --filter ComposerE2ETests`, `swift test --filter DirectorE2ETests`, and `swift test`.

### Task 4: Verify every requested target and real-photo output

**Files:**
- No iOS-owned files may be modified.

- [ ] **Step 1: Build and test**
  Run `swift build` and full `swift test`, recording failures with their exact test names if any.

- [ ] **Step 2: Build the iOS target without editing it**
  Run the exact requested `xcodebuild` command and confirm the filtered output.

- [ ] **Step 3: Rerender every real-photo run**
  Run `ak14 rerender <run> --source IMG --recompose` for every `/tmp/ak14-ft/*/2026*` run, inspect layouts/documents, and report hero.clean share, title count per carousel, and pairwise option photo overlap.

- [ ] **Step 4: Confirm scope and worktree state**
  Verify no iOS paths changed, no commit was created, and report all modified files and verification results concisely.

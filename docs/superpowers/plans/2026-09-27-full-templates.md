# Full 17V28 Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import the complete locally available 17V28 template geometry and make safe, editable typography, frame layers, corner radii, backgrounds, and coherent template families render deterministically.

**Architecture:** Extend the Core designed-set and resolved-element models with optional Codable data so old plans and iOS call sites remain source-compatible. The importer converts raw template JSON into sanitized designed-set data, including role-only text styling, mapped bundled fonts, frame references, and decor coverage. `TemplateVocabulary` selects one category family per carousel, fills only owner-grounded title/date text, and emits editable resolved elements; `CanvasDocument` and `DocumentRenderer` preserve and paint those elements natively.

**Tech Stack:** Swift 6.4 SwiftPM, Core Codable models, CoreText/CGContext rendering, Python/Swift importer tooling, Google Fonts OFL assets.

**Spec:** `docs/superpowers/specs/2026-09-27-full-templates.md`

## Global Constraints

- Do not touch `Sources/iOSApp/**`; preserve compatibility with its existing initializers and Codable data.
- Never commit raw `/Applications/app17v28.app` JSON or `/tmp/17extract` previews; only converted `designed-sets.json`, imported frames, and licensed font assets may ship.
- Strip trailing commas before parsing every 17V28 JSON source.
- Never copy or render 17V28 sample strings; only title ideas/story hints and photo capture dates may populate imported text slots.
- Preserve the 65% crop floor, `facesFit`, seam safety, and `direction.seamless` requirement.
- Run the full Swift package test suite, the requested iOS build, and the free `rerender` real-photo checks before completion.
- Do not commit, stash, reset, or checkout.

## Review Focus

- Legacy designed-set JSON without new optional fields still decodes and validates — test in `DesignedSetE2ETests`.
- A template with title/caption layers never emits sample text, emits one grounded title and at most two dates — test in `TemplateVocabularyTests`.
- Decor-heavy or decor-over-slot templates are excluded while geometry-only decor coverage is retained — test importer-output validation.
- A family remains stable across a carousel but falls back when no family page fits — test in `TemplateVocabularyTests`.
- Multi-line text, rotation, spacing, rounded slots, frame overlays, and non-white backgrounds are byte-deterministic — test in `RenderE2ETests`/`FrameAssetE2ETests`.

---

### Task 1: Extend designed-set and resolved-element data models compatibly

**Files:**
- Modify: `Sources/Core/Plan/DesignedSet.swift`
- Modify: `Sources/Core/Layout/LayoutModels.swift`
- Modify: `Sources/Core/Document/CanvasDocument.swift`
- Test: `Tests/CLITests/DesignedSetE2ETests.swift`
- Test: `Tests/CLITests/TemplateVocabularyTests.swift`

**Interfaces:**
- `DesignedSet.Slot.cornerRadius: Double?`
- `DesignedSet.TextLayer` carries normalized frame, mapped font ID, size, color, alignment, line spacing, letter spacing, number of lines, rotation, and role.
- `DesignedSet.FrameLayer` carries normalized frame, frame asset ID, z-index, rotation, and source photo-window geometry.
- `DesignedSet.texts`, `DesignedSet.frames`, `DesignedSet.family`, and `DesignedSet.decorCoverage` are optional/defaulted for old files.
- `ResolvedElement.kind` gains `.text` and `.frame`; optional text styling and `frameAssetID` fields have defaulted initializer parameters.
- `CanvasDocument(from:)` maps resolved text/frame styling into editable `DocumentLayer` values without changing existing iOS construction calls.

- [ ] **Step 1: Write failing compatibility and element-shape tests**

Assert a hand-authored old-version set decodes without new fields, a new text/frame element round-trips through JSON, and a carousel-to-document conversion retains editable text and frame metadata.

- [ ] **Step 2: Run the focused tests and verify the expected missing-field/API failures**

Run: `swift test --filter DesignedSetE2ETests` and `swift test --filter TemplateVocabularyTests`

- [ ] **Step 3: Add optional Codable model fields and element kinds**

Use optional properties and defaulted initializer arguments; retain existing `ElementKind` decoding for `.photo`, `.tape`, and `.stamp`.

- [ ] **Step 4: Map new resolved metadata into `DocumentLayer`**

Keep legacy stamps on the existing DSEG path, map template text to `.text` with its actual style, and map template frame elements to `.frame` with the photo asset plus `frameAssetID`.

- [ ] **Step 5: Run the focused tests and the full package test suite**

Run: `swift test --filter DesignedSetE2ETests`, `swift test --filter TemplateVocabularyTests`, and `swift test`.

### Task 2: Upgrade the importer to convert complete template pages

**Files:**
- Modify: `tools/import-17v28/import.swift`
- Modify: `tools/import-17v28/README.md`
- Test: `Tests/CLITests/DesignedSetE2ETests.swift`

**Interfaces:**
- Raw decoders accept `categoryId`, text layers, frame layers, transforms, corners, and all existing placeholder forms.
- Sanitized records contain no sample `text` value, but retain role and visual styling.
- Font mapping is deterministic: Inter/Roboto families map to Inter; DotGothic16, Instrument Serif, Amatic SC, Anton, and the five required missing faces map to their bundled IDs; all other names map to the nearest bundled face with a source comment in the importer.
- `decorCoverage` is the union-safe area estimate of decorative image layers divided by page area; any decor over 12% or intersecting a photo slot is excluded.
- Frame layers map to an imported `FrameAsset` image ID using deterministic placeholder/window matching, and are omitted only when no bundled frame can safely represent them.

- [ ] **Step 1: Add importer-output tests for schema, exclusions, sample-text absence, roles, and mapped assets**

Load the regenerated library and assert version bump, category family, optional text/frame data, valid decor coverage, no raw sample strings, excluded decor-heavy pages, and frame IDs resolvable from `FrameAssetRegistry`.

- [ ] **Step 2: Run the importer-output test before implementation**

Run: `swift test --filter DesignedSetE2ETests`

- [ ] **Step 3: Implement lenient raw decoders and normalized geometry**

Support both point-based template canvases and nested layout placeholders, preserve corner radius normalized to the slot, and calculate text/frame geometry in whole-carousel coordinates.

- [ ] **Step 4: Implement font mapping, text-role classification, decor coverage, and frame matching**

Classify the largest non-symbol text as `title`, smaller text as `caption`, symbol-only text as `accent`; discard literal sample text; map style fields and use comments for fallback mappings.

- [ ] **Step 5: Regenerate `designed-sets.json` without writing raw sources**

Run the importer from the repository root and validate sorted IDs, bumped library version, valid geometry, excluded decor-heavy records, and no sample strings.

- [ ] **Step 6: Run importer-output tests and `swift test`**

Confirm the old 104-set assumptions are updated to the regenerated counts without weakening structural assertions.

### Task 3: Implement family-aware, text-safe template resolution

**Files:**
- Modify: `Sources/Core/Layout/LayoutResolver.swift`
- Modify: `Sources/Core/Layout/TemplateVocabulary.swift`
- Modify: `Sources/Core/Layout/LayoutModels.swift`
- Modify: `Sources/Core/Layout/Composer.swift` only if a compatible context pass-through is required
- Test: `Tests/CLITests/TemplateVocabularyTests.swift`

**Interfaces:**
- `LayoutContext` gains optional `storyHint` with a default, preserving all existing callers.
- Template placement carries a selected family through the carousel; category/family is never exposed in user-facing output.
- Statement pages are preferred for single-photo windows when crop/faces/seam constraints pass.
- Text values derive only from `Direction.titleIdea`, a 3–28-character story hint, or a lowercase capture date; captions are capped at two and titles at one per carousel.

- [ ] **Step 1: Add failing resolver tests**

Cover family consistency and fallback, statement preference, one-title/at-most-two-caption limits, title/hint/date provenance, no sample text, face avoidance/drop, rounded slots, frame element creation, and deterministic repeated resolution.

- [ ] **Step 2: Run focused resolver tests to verify red**

Run: `swift test --filter TemplateVocabularyTests`

- [ ] **Step 3: Add family selection and statement ranking**

Seed family choice from plan ID plus layout seed, prefer no-text families for `decoration == "none"` and text/frame families otherwise, use family pages whenever viable, and fall back only when no family page fits.

- [ ] **Step 4: Build photo, frame, and text elements**

Preserve existing crop/seam checks, add slot corner-radius metadata, add frame overlays, assign per-page title/caption roles, and shift text within page bounds away from detected face boxes or drop it.

- [ ] **Step 5: Pass story hints from non-iOS composition/resolution paths**

Use defaulted `LayoutContext.storyHint` for compatibility and pass known CLI/session composition hints where those call sites already own the value; do not edit iOS sources.

- [ ] **Step 6: Run focused and full tests**

Run: `swift test --filter TemplateVocabularyTests` and `swift test`.

### Task 4: Render full-template pages natively

**Files:**
- Modify: `Sources/Render/DocumentRenderer.swift`
- Modify: `Sources/Render/CarouselRenderer.swift` only if legacy conversion/version handling needs a compatible addition
- Modify: `Sources/Render/Fonts.swift`
- Test: `Tests/CLITests/RenderE2ETests.swift`
- Test: `Tests/CLITests/FrameAssetE2ETests.swift`

**Interfaces:**
- Template text renders through CoreText frames with wrapping, line spacing, letter spacing, alignment, and rotation.
- Template frame elements draw the photo through the registered frame window and then the frame PNG.
- Slot corner radius clips the photo before drawing; per-slide background hex fills the canvas.
- Every mapped bundled font resolves through `BundledFonts`.

- [ ] **Step 1: Add failing deterministic renderer tests**

Render a document containing a multiline rotated styled text layer, rounded photo, frame overlay, and background color twice; assert identical PNG bytes and inspect representative pixels/text-layer metadata.

- [ ] **Step 2: Run focused render tests to verify red**

Run: `swift test --filter RenderE2ETests` and `swift test --filter FrameAssetE2ETests`

- [ ] **Step 3: Replace single-line text drawing with CTFramesetter rendering**

Create attributed strings with mapped CTFont, color, kern, paragraph alignment, and fixed line spacing; draw in a path clipped to the layer rect with the existing rotation transform.

- [ ] **Step 4: Add frame and rounded-photo painting**

Use `FrameAssetRegistry` for the frame image/window, clip the photo to the frame window, and apply the slot mask before drawing ordinary photos.

- [ ] **Step 5: Add and register missing OFL font files**

Download Pinyon Script, Cedarville Cursive, Outfit, Ballet, and Special Elite TTF/OFL files from `google/fonts` raw `ofl/<family>/` URLs, add manifest records matching existing fields, and register IDs/postscript names in `BundledFonts`.

- [ ] **Step 6: Run render tests and full Swift verification**

Run: `swift test --filter RenderE2ETests`, `swift test --filter FrameAssetE2ETests`, and `swift test`.

### Task 5: Integrate generated data and run all acceptance checks

**Files:**
- Modify: `Sources/Render/Resources/StylePacks/designed-sets.json`
- Modify: `Sources/Render/Resources/Assets/manifest.json`
- Create: `Sources/Render/Resources/Assets/fonts/<required TTF and licence files>`
- Test: `Tests/CLITests/*.swift` as needed for acceptance coverage

- [ ] **Step 1: Validate generated resources**

Parse JSON, verify every font manifest file exists and hashes match, every frame ID resolves, no raw 17V28 filenames/sample strings are present, and library validation succeeds.

- [ ] **Step 2: Run `swift build` and full `swift test`**

Record exact exit status and test totals.

- [ ] **Step 3: Run the requested iOS build**

Run:
`cd iOS && xcodebuild -project AK14iOS.xcodeproj -scheme AK14iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ak14-dd-ft build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'`

- [ ] **Step 4: Run all real-photo rerenders**

For every `/tmp/ak14-after/*/2026*`, run `.build/debug/ak14 rerender <run> --source IMG --recompose`, then inspect resolved layouts/documents and report direction-slide `hero.clean` share, template-page share, title-slide count, and every rendered text string.

- [ ] **Step 5: Check final ownership and status**

Confirm no `Sources/iOSApp/**` changes, no raw source JSON/preview files, no commit was created, and leave unrelated user changes untouched.

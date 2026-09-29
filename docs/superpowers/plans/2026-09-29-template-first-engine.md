# Template-first Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every non-baseline carousel is built from authored 17V28 pages chosen together with the photos, instead of fitting templates onto slides decided in advance.

**Architecture:**
- **Page catalogue.** The importer splits the 17V28 templates into single pages and linked runs, stored in `designed-pages.json` as `DesignedSet`s with extra page metadata.
- **Composition.** `PageSearch`, a bounded beam search in Core/Compose, picks photos and pages together from the planner's story moments. Each option comes from one family. `SlotAssignment` places the photos using the Hungarian algorithm.
- **Placement.** The winning page, assignment and resolved slide are stored on each `SlidePlan` as a `SlidePlacement`. `LayoutResolver.resolve` replays it, so CLI, session, iOS and the editor all render exactly what was chosen.

**Tech Stack:** Swift 6.4 (SwiftPM, Swift Testing), Core Graphics rendering, a Swift script importer, and a Cloudflare Worker in JavaScript (node:test).

**Spec:** `docs/superpowers/specs/2026-09-29-template-first-engine-design.md`. Read it before starting any task.

## Global Constraints
- **Tests are e2e only:** they go through `LayoutResolver.resolve`, `ComposerEngine.composeSet`, `RunPipeline`, the CLI, or the Worker handler. No unit tests of private helpers. Use Swift Testing (`@Test`, `#expect`) in `Tests/CLITests/`.
- **Crop floor:** 0.65 everywhere (`SlotAssignment.cropFloor`). No other retention constant may remain.
- Faces are never cut (`CropPlanner.facesFit`), and no subject crosses a page edge.
- **Relevant faces:** the largest face, plus every face at least 40% of its height. A rendered height under 4% of the slide height is a steep penalty, not infeasible.
- **Mandatory photos are never dropped.** These are `mustInclude` and every exact-set photo. When no page fits one, it goes on a white card (`hero.clean`) with a warning.
- **17V28 sample text never renders.** Text comes only from `titleIdeas`, `titleIdea`, the story hint (3–28 characters) or capture dates, as in the existing rules.
- **One family per option.** Options differ by family and by cover.
- **Bounded search:** top 6 alternatives per moment, plus at most 1 photo from the next moment; at most 12 pages per step; at most 4 families per run; a beam of 48; Hungarian assignment.
- **Budget:** p95 total composition at most 1.5 s on an iPhone 17 (device run). The simulator is only a regression guard.
- **One planner request.** The existing repair and retry run only when validation fails. There are no new model call types.
- **Worker:** `configVersion` stays 1, and the ETag includes a content revision.
- **Old runs still work:** plans without `placement`, directions without `moments`, and library files without page fields all decode and render byte-identically.
- **Naming and scope:** no project-prefixed module names, no named concept types, and families are never shown to the user.
- **Commits:** commit to `main`. Commit messages carry no Claude attribution lines. Do not push without the owner's say-so.

## Review Focus
1. **A mostly-landscape pool infers the square aspect, which has a thin catalogue.** The run falls back to the current engine for that aspect with a warning, and never produces an empty or crashing option. Test in Task 7.
2. **Exact-set with 20 photos, one of them a 16:9 panorama that fits no page.** The panorama goes on a white card and all 20 photos appear. Test in Task 6.
3. **Editing after generation:** swapping a portrait into a landscape-only slot, or reordering a slide out of a linked run. The slide re-resolves through the ordinary path, never crashes, and loses no photo. Test in Task 4.
4. **Old runs (no `placement`, no `moments`) re-rendered with the new build.** They produce byte-identical slide JSON. Test in Task 4.
5. **The planner returns moments with a duplicate photo, an unknown id, or an order violating keep-order.** The validator flags it, so the repair path runs, and a still-invalid direction is dropped rather than rendered. Test in Task 5.

---

### Task 1: Page model fields and loaders

**Files:**
- Modify: `Sources/Core/Plan/DesignedSet.swift` (the struct at lines 4–140 and the library at 142–165)
- Modify: `Sources/Render/StylePackLoader.swift:14-19`
- Modify: `Sources/Core/Layout/LayoutResolver.swift:3-17` (`LayoutContext`)
- Modify: `Sources/Core/Compose/ComposerEngine.swift:4-30` (`CompositionContext`)
- Create: `Sources/Core/Layout/PageShape.swift`
- Create: `Sources/Render/Resources/StylePacks/designed-pages.json`: a placeholder library with an empty `sets` array. Task 2 regenerates it.
- Test: `Tests/CLITests/DesignedPagesE2ETests.swift`

**Interfaces:**
- Produces:
  - `DesignedSet.sourceTemplate: String?`, `pageIndex: Int?`, `pageRole: String?` (`cover|statement|grid|strip|quiet`), and `coverCapable: Bool?`
  - `DesignedSet.isPage: Bool`, true when `pageIndex != nil`
  - `StylePackLoader.loadDesignedPages() throws -> DesignedSetLibrary`
  - `LayoutContext.pages: [DesignedSet]` and `CompositionContext.pages: [DesignedSet]`, both defaulting to `[]`
  - `enum ShapeClass: String { case tall, square, wide, band }` with `static func of(aspect: Double) -> ShapeClass`

- [ ] **Step 1: Write the failing test**

```swift
import Core
import Foundation
import Render
import Testing

@Suite struct DesignedPagesE2ETests {
    @Test func pageLibraryLoadsAndOldSetsStillDecode() throws {
        let pages = try StylePackLoader.loadDesignedPages()
        #expect(pages.validationError() == nil)
        #expect(pages.sets.allSatisfy(\.isPage))
        let sets = try StylePackLoader.loadDesignedSets()
        #expect(sets.validationError() == nil)
        #expect(sets.sets.allSatisfy { !$0.isPage })
    }

    @Test func pageFieldsRoundTripAndShapeClassesMatchTheSpec() throws {
        let page = DesignedSet(id: "17v28-t1-p0", sourceRef: "17v28:template-1", aspect: .portrait4x5, slideCount: 1,
                               background: "#FFFFFF",
                               slots: [DesignedSet.Slot(frame: UnitRect(x: 0, y: 0, width: 1, height: 1), aspect: 0.8, z: 0,
                                                        crossesSeam: false, roleHint: "hero")],
                               sourceTemplate: "template-1", pageIndex: 0, pageRole: "statement", coverCapable: true)
        let decoded = try JSONDecoder().decode(DesignedSet.self, from: JSONEncoder().encode(page))
        #expect(decoded == page)
        #expect(decoded.validationError() == nil)
        #expect(ShapeClass.of(aspect: 0.75) == .tall)
        #expect(ShapeClass.of(aspect: 1.0) == .square)
        #expect(ShapeClass.of(aspect: 1.5) == .wide)
        #expect(ShapeClass.of(aspect: 2.4) == .band)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DesignedPagesE2ETests`
Expected: a compile failure: `loadDesignedPages` and `ShapeClass` don't exist.

- [ ] **Step 3: Implement**

`Sources/Core/Layout/PageShape.swift`:
```swift
import Foundation

/// Shape of a photo or slot, width / height. Boundaries are the spec's: tall < 0.8, square 0.8–1.25, wide 1.25–2.0, band > 2.0.
public enum ShapeClass: String, Codable, Sendable, CaseIterable {
    case tall, square, wide, band
    public static func of(aspect: Double) -> ShapeClass {
        if aspect < 0.8 { return .tall }
        if aspect <= 1.25 { return .square }
        if aspect <= 2.0 { return .wide }
        return .band
    }
}
```

In `DesignedSet`:
- add the four optional properties after `decorCoverage`
- add them to `init` as trailing parameters defaulting to `nil`, and assign them
- add `public var isPage: Bool { pageIndex != nil }`
- in `validationError()`, add:
  ```swift
  if let role = pageRole, !["cover", "statement", "grid", "strip", "quiet"].contains(role) { return "invalid page role" }
  if let index = pageIndex, index < 0 { return "invalid page index" }
  ```
- the synthesized `Codable` already treats optionals as absent-tolerant, so leave `version` checks as they are

`StylePackLoader`:
```swift
public static func loadDesignedPages() throws -> DesignedSetLibrary { try loadDesignedSets(file: "designed-pages") }
```

`LayoutContext` and `CompositionContext`: add `public var pages: [DesignedSet]` with an init parameter `pages: [DesignedSet] = []`, and assign it.

`designed-pages.json`:
```json
{ "frameInference": "placeholder; regenerated by tools/import-17v28/import.swift", "sets": [], "version": 2 }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DesignedPagesE2ETests`, then `swift test`.
Expected: PASS, and the full suite stays green (120 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Plan/DesignedSet.swift Sources/Render/StylePackLoader.swift Sources/Core/Layout/LayoutResolver.swift Sources/Core/Compose/ComposerEngine.swift Sources/Core/Layout/PageShape.swift Sources/Render/Resources/StylePacks/designed-pages.json Tests/CLITests/DesignedPagesE2ETests.swift
git commit -m "Page fields on designed sets and a page library loader"
```

---

### Task 2: Importer: split into pages, keep linked runs, rescue per page

**Files:**
- Modify: `tools/import-17v28/import.swift`. The template loop ends at line ~390, where `records.append(SetRecord(...))` is. Add a second output after the existing library is written.
- Modify: `tools/import-17v28/README.md`: document the page output.
- Regenerate: `Sources/Render/Resources/StylePacks/designed-pages.json`
- Test: `Tests/CLITests/DesignedPagesE2ETests.swift` (extend)

**Interfaces:**
- Consumes: the Task 1 fields.
- Produces: `designed-pages.json`, with ids `17v28-t<template>-p<index>` for single pages and `17v28-t<template>-p<start>-<end>` for linked runs. `slideCount` is the run length. `pageRole` and `coverCapable` are set.

- [ ] **Step 1: Write the failing test**

Add to `DesignedPagesE2ETests`:
```swift
    @Test func catalogueHasEnoughUsablePagesAndNoSampleText() throws {
        let pages = try StylePackLoader.loadDesignedPages().sets
        let portrait = pages.filter { $0.aspect == .portrait4x5 }
        #expect(portrait.count >= 150, "only \(portrait.count) usable 4:5 pages")
        #expect(pages.filter { $0.aspect == .portrait3x4 }.count >= 100)
        for aspect in [CarouselAspect.portrait4x5, .portrait3x4] {
            #expect(pages.contains { $0.aspect == aspect && $0.coverCapable == true }, "no cover page for \(aspect)")
        }
        #expect(pages.allSatisfy { ($0.decorCoverage ?? 0) <= 0.12 })
        // Text layers carry roles and styling only; never source strings (TextLayer has no string field).
        #expect(pages.allSatisfy { ($0.texts ?? []).allSatisfy { ["title", "caption", "accent"].contains($0.role) } })
    }

    @Test func linkedRunsStayWhole() throws {
        let pages = try StylePackLoader.loadDesignedPages().sets
        for page in pages where page.slideCount == 1 {
            #expect(!page.crossesSeam, "\(page.id) is a single page with a slot crossing its edge")
        }
        for run in pages where run.slideCount > 1 {
            #expect(run.crossesSeam || (run.frames ?? []).contains { $0.frame.x.rounded(.down) != ($0.frame.x + $0.frame.width).rounded(.down) },
                    "\(run.id) is a run but nothing links its pages")
        }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DesignedPagesE2ETests`
Expected: FAIL. The placeholder has 0 pages.

- [ ] **Step 3: Implement page splitting in the importer**

In `import.swift`, after `normalized(...)` has produced the template's slots, texts, frames and decor boxes in whole-template coordinates (x in 0..numberOfFrames), add a function and call it for every template of a supported aspect (`portrait`, `portrait2`, `square`). Call it **before** the whole-template decor rejection, so rejected templates can still donate pages.

```swift
struct PageRecord: Codable { /* same fields as SetRecord plus: */ var sourceTemplate: String; var pageIndex: Int; var pageRole: String; var coverCapable: Bool }

/// Splits one template into single pages and linked runs. A run is a maximal range of pages joined by any
/// slot, frame, text layer or decoration whose box spans an integer page boundary.
func pages(templateID: Int, aspect: String, pageCount: Int, background: String, family: String,
           slots: [Slot], texts: [TextLayer], frames: [FrameLayer], decor: [Box]) -> [PageRecord] {
    func spans(_ x: Double, _ w: Double) -> ClosedRange<Int> {
        let lo = Int(floor(x + 0.001)), hi = Int(floor(x + w - 0.001))
        return max(0, lo)...min(pageCount - 1, max(lo, hi))
    }
    // Union-find over page indices joined by spanning items.
    var parent = Array(0..<pageCount)
    func find(_ i: Int) -> Int { parent[i] == i ? i : find(parent[i]) }
    let ranges = slots.map { spans($0.frame.x, $0.frame.width) } + texts.map { spans($0.frame.x, $0.frame.width) }
        + frames.map { spans($0.frame.x, $0.frame.width) } + decor.map { spans($0.x, $0.width) }
    for r in ranges where r.count > 1 { for i in r.dropFirst() { parent[find(i)] = find(r.lowerBound) } }
    let groups = Dictionary(grouping: 0..<pageCount, by: find).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    return groups.compactMap { group -> PageRecord? in
        let start = Double(group.first!), length = Double(group.count)
        func local(_ f: Rect) -> Rect { Rect(x: f.x - start, y: f.y, width: f.width, height: f.height) }
        func inside(_ x: Double, _ w: Double) -> Bool { x + 0.001 >= start && x + w - 0.001 <= start + length }
        let s = slots.filter { inside($0.frame.x, $0.frame.width) }.map { var v = $0; v.frame = local(v.frame); return v }
        guard !s.isEmpty else { return nil }                       // pages with no photo slot are dropped
        let t = texts.filter { inside($0.frame.x, $0.frame.width) }.map { var v = $0; v.frame = local(v.frame); return v }
        let f = frames.filter { inside($0.frame.x, $0.frame.width) }.map { var v = $0; v.frame = local(v.frame); v.slotFrame = v.slotFrame.map(local); return v }
        let d = decor.filter { inside($0.x, $0.width) }
        let area = length                                            // unit page area × pages
        let coverage = min(1, unionArea(d.map { Box(x: $0.x - start, y: $0.y, width: $0.width, height: $0.height) }) / area)
        let overPhoto = d.contains { dd in s.contains { sl in
            max(dd.x - start, sl.frame.x) < min(dd.x - start + dd.width, sl.frame.x + sl.frame.width) &&
            max(dd.y, sl.frame.y) < min(dd.y + dd.height, sl.frame.y + sl.frame.height) } }
        guard coverage <= 0.12, !overPhoto else { return nil }
        let role = pageRole(slots: s, texts: t, length: length)
        let dominant = s.map { $0.frame.width * $0.frame.height }.max()! / length
        let cover = group.count == 1 && (t.contains { $0.role == "title" } || dominant >= 0.6)
        let id = group.count == 1 ? "17v28-t\(templateID)-p\(group[0])" : "17v28-t\(templateID)-p\(group.first!)-\(group.last!)"
        return PageRecord(id: id, sourceRef: "17v28:template-\(templateID)", aspect: aspect, slideCount: group.count,
                          background: background, slots: s, version: libraryVersion, texts: t.isEmpty ? nil : t,
                          frames: f.isEmpty ? nil : f, family: family, decorCoverage: coverage,
                          sourceTemplate: "template-\(templateID)", pageIndex: group[0], pageRole: role, coverCapable: cover)
    }
}

/// Role from geometry (spec §1). Evaluated in this order.
func pageRole(slots: [Slot], texts: [TextLayer], length: Double) -> String {
    let areas = slots.map { $0.frame.width * $0.frame.height / length }
    if slots.count == 1, areas[0] >= 0.8 { return texts.contains { $0.role == "title" } ? "cover" : "statement" }
    if texts.contains(where: { $0.role == "title" }) { return "cover" }
    if slots.count <= 1, (areas.first ?? 0) < 0.35 { return "quiet" }
    let xs = Set(slots.map { ($0.frame.x * 20).rounded() }), ys = Set(slots.map { ($0.frame.y * 20).rounded() })
    if (2...4).contains(slots.count), xs.count == 1 || ys.count == 1 { return "strip" }
    let maxArea = areas.max() ?? 0, minArea = areas.min() ?? 0
    if slots.count >= 3, minArea / max(maxArea, 0.0001) >= 0.7 { return "grid" }
    return areas.count == 1 ? "statement" : "grid"
}
```

Write the page records to `Sources/Render/Resources/StylePacks/designed-pages.json` with the same encoder settings as the existing library. The `Library` has `version: libraryVersion` and `frameInference` equal to the existing text. Keep `designed-sets.json` unchanged.

Extend `renderContactSheets` to also write `/tmp/ak14-designed-pages-<aspect>.png` for the pages. These are for owner review and are never committed.

- [ ] **Step 4: Run the importer, then the tests**

Run: `swift tools/import-17v28/import.swift`
Expected output: a line like `Imported … pages (… 4:5, … 3:4, … 1:1)`. Record the counts in the spec's Results section.

Run: `swift test --filter DesignedPagesE2ETests`
Expected: PASS. If the 4:5 page count is below 150, don't lower the threshold. Report the number and the top rejection reasons to the reviewer.

- [ ] **Step 5: Commit**

```bash
git add tools/import-17v28 Sources/Render/Resources/StylePacks/designed-pages.json Tests/CLITests/DesignedPagesE2ETests.swift docs/superpowers/specs/2026-09-29-template-first-engine-design.md
git commit -m "Import 17V28 templates as pages and linked runs, rescuing decoration-free pages"
```

---

### Task 3: Best-pairing slot assignment and one crop floor

**Files:**
- Create: `Sources/Core/Layout/SlotAssignment.swift`
- Modify: `Sources/Core/Layout/TemplateVocabulary.swift:157-200` (`build` uses `SlotAssignment`), and `:517` (`subjectCrossesSeam` becomes `static`, not `private`)
- Modify: `Sources/Core/Layout/CropPlanner.swift:90` (0.58 → `SlotAssignment.cropFloor`)
- Test: `Tests/CLITests/TemplateVocabularyTests.swift` (extend)

**Interfaces:**
- Produces:
```swift
public enum SlotAssignment {
    public static let cropFloor = 0.65
    public struct Placed: Codable, Sendable, Equatable { public var slotIndex: Int; public var assetID: AssetID; public var crop: UnitRect }
    public struct Result: Sendable, Equatable { public var placed: [Placed]; public var cost: Double }
    /// `photos.count` must equal the page's expanded slot count. `hero` wants the largest slot.
    /// With `keepOrder`, photos fill slots in reading order (top-to-bottom, then left-to-right by slot centre).
    public static func assign(_ photos: [AssetID], to page: DesignedSet, hero: AssetID?, keepOrder: Bool,
                              records: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures]) -> Result?
    /// Slot indices of `page.expandedSlots` in reading order.
    public static func readingOrder(_ page: DesignedSet) -> [Int]
}
```

- [ ] **Step 1: Write the failing tests**

Add to `TemplateVocabularyTests`, reusing the file's `photo`, `set`, `slot` and `context` helpers:
```swift
    @Test func bestPairingAcceptsWhatTheOldZipRejected() throws {
        // The hero is a landscape, so the zip put it in the tall big slot (crop < 0.65) and rejected the page.
        let page = set("mixed", slides: 1, slots: [
            slot(x: 0, y: 0, w: 0.55, h: 1, aspect: 0.55, z: 1, role: "hero"),
            slot(x: 0.58, y: 0.3, w: 0.42, h: 0.28, aspect: 1.5, z: 0, role: "support")
        ])
        let wide = photo("wide", aspect: 1.5), tall = photo("tall", aspect: 0.56)
        var heroElement = PhotoElement.plain(wide.assetID); heroElement.role = "hero"
        var supportElement = PhotoElement.plain(tall.assetID); supportElement.role = "support"
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [
            SlidePlan(primitive: .asymmetricPair, mood: "", density: "balanced", photos: [heroElement, supportElement], decorations: [], stamps: [])
        ])
        let resolved = LayoutResolver.resolve(plan, context: try context(photos: [wide, tall], vocabulary: [page]))
        #expect(resolved.slides[0].variant == "template.mixed")
        let crops = resolved.slides[0].elements.compactMap { $0.crop.map { $0.width * $0.height } }
        #expect(crops.allSatisfy { $0 >= SlotAssignment.cropFloor })
    }

    @Test func keepOrderFillsSlotsInReadingOrder() throws {
        let page = set("row", slides: 1, slots: [
            slot(x: 0.52, y: 0.1, w: 0.46, h: 0.8, aspect: 0.58, z: 0),
            slot(x: 0.02, y: 0.1, w: 0.46, h: 0.8, aspect: 0.58, z: 1)
        ])
        let a = photo("a", aspect: 0.58), b = photo("b", aspect: 0.58)
        let result = SlotAssignment.assign([a.assetID, b.assetID], to: page, hero: nil, keepOrder: true,
                                           records: [a.assetID: a, b.assetID: b], features: [:])
        let left = SlotAssignment.readingOrder(page)[0]
        #expect(result?.placed.first { $0.slotIndex == left }?.assetID == a.assetID)
    }

    @Test func fullBleedUsesTheSharedFloor() {
        // 4:3 on 4:5 keeps 0.60, which the old 0.58 rule accepted and the shared 0.65 floor rejects.
        #expect(!CropPlanner.fullBleedEligible(imageAspect: 4.0 / 3.0, boxAspect: 0.8, features: nil))
        #expect(CropPlanner.fullBleedEligible(imageAspect: 1.0, boxAspect: 0.8, features: nil))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TemplateVocabularyTests`
Expected: a compile failure, because `SlotAssignment` doesn't exist.

- [ ] **Step 3: Implement `SlotAssignment.swift`**

```swift
import Foundation

public enum SlotAssignment {
    public static let cropFloor = 0.65
    public struct Placed: Codable, Sendable, Equatable { public var slotIndex: Int; public var assetID: AssetID; public var crop: UnitRect }
    public struct Result: Sendable, Equatable { public var placed: [Placed]; public var cost: Double }
    static let infeasible = 1e6

    public static func readingOrder(_ page: DesignedSet) -> [Int] {
        page.expandedSlots.enumerated().sorted { l, r in
            let a = (l.element.frame.y + l.element.frame.height / 2, l.element.frame.x + l.element.frame.width / 2)
            let b = (r.element.frame.y + r.element.frame.height / 2, r.element.frame.x + r.element.frame.width / 2)
            if abs(a.0 - b.0) > 0.05 { return a.0 < b.0 }
            return a.1 < b.1
        }.map(\.offset)
    }

    /// The photo window's aspect: a frame's transparent window when the slot sits in one, else the slot's.
    static func boxAspect(_ slot: DesignedSet.Slot, page: DesignedSet) -> Double {
        if let frame = page.frames?.first(where: { $0.slotFrame.map { abs($0.x - slot.frame.x) + abs($0.y - slot.frame.y) < 0.01 } ?? false }),
           let window = frame.photoWindowAspect { return window }
        return slot.aspect > 0 ? slot.aspect : slot.frame.width / max(slot.frame.height, 0.01)
    }

    static func pair(_ id: AssetID, _ slot: DesignedSet.Slot, page: DesignedSet, isHero: Bool, largestArea: Double,
                     records: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures]) -> (cost: Double, crop: UnitRect) {
        guard let record = records[id] else { return (infeasible, UnitRect(x: 0, y: 0, width: 1, height: 1)) }
        let imageAspect = Double(record.pixelWidth) / Double(max(record.pixelHeight, 1))
        let f = features[id]
        let crop = CropPlanner.cover(imageAspect: imageAspect, boxAspect: boxAspect(slot, page: page), features: f)
        let kept = crop.width * crop.height
        guard kept >= cropFloor, CropPlanner.facesFit(f, crop: crop),
              !TemplateVocabulary.subjectCrossesSeam(features: f, crop: crop, slot: slot.frame) else { return (infeasible, crop) }
        var cost = 1 - kept
        // Relevant faces: the largest, plus every face at least 40% of its height.
        let heights = (f?.faces ?? []).map(\.box.height)
        if let biggest = heights.max(), biggest > 0 {
            let relevant = heights.filter { $0 >= 0.4 * biggest }
            let rendered = relevant.map { $0 / max(crop.height, 1e-6) * slot.frame.height }.min() ?? 1
            if rendered < 0.04 { cost += 2 * (0.04 - rendered) / 0.04 }
        }
        if isHero { cost += 0.3 * (1 - slot.frame.width * slot.frame.height / max(largestArea, 1e-6)) }
        return (cost, crop)
    }

    public static func assign(_ photos: [AssetID], to page: DesignedSet, hero: AssetID?, keepOrder: Bool,
                              records: [AssetID: PhotoRecord], features: [AssetID: PhotoFeatures]) -> Result? {
        let slots = page.expandedSlots
        guard !photos.isEmpty, photos.count == slots.count, Set(photos).count == photos.count else { return nil }
        let largest = slots.map { $0.frame.width * $0.frame.height }.max() ?? 1
        let table = photos.map { id in slots.map { pair(id, $0, page: page, isHero: id == hero, largestArea: largest, records: records, features: features) } }
        let columns: [Int]
        if keepOrder {
            let order = readingOrder(page)
            columns = photos.indices.map { order[$0] }
        } else {
            columns = hungarian(table.map { $0.map(\.cost) })
        }
        var placed: [Placed] = [], total = 0.0
        for (row, column) in columns.enumerated() {
            let (cost, crop) = table[row][column]
            guard cost < infeasible else { return nil }
            placed.append(Placed(slotIndex: column, assetID: photos[row], crop: crop)); total += cost
        }
        return Result(placed: placed.sorted { $0.slotIndex < $1.slotIndex }, cost: total)
    }

    /// Minimum-cost perfect matching on a square matrix (O(n³)). Returns the column for each row.
    static func hungarian(_ cost: [[Double]]) -> [Int] {
        let n = cost.count
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i; var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1), used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]; var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n { if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta } }
                j0 = j1
            } while p[j0] != 0
            repeat { let j1 = way[j0]; p[j0] = p[j1]; j0 = j1 } while j0 != 0
        }
        var result = [Int](repeating: 0, count: n)
        for j in 1...n where p[j] != 0 { result[p[j] - 1] = j - 1 }
        return result
    }
}
```

In `TemplateVocabulary.build`:
- replace the hero-first reordering, the `ranked` sort and the `zip` loop with a call to `SlotAssignment.assign(photos.map(\.assetID), to: set, hero: photos.first { $0.role == "hero" }?.assetID, keepOrder: context.keepOrder, records: context.photos, features: context.features)`
- return nil on nil
- map `placed` back to `(slot: slots[p.slotIndex], photo: <the PhotoElement with p.assetID>, crop: p.crop)`

`LayoutContext` has no `keepOrder`, so add `public var keepOrder: Bool = false` with a defaulted init parameter, and pass it from the callers that have it in Task 7. Make `subjectCrossesSeam` `static` (internal). In `CropPlanner.fullBleedEligible`, replace `0.58` with `SlotAssignment.cropFloor`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TemplateVocabularyTests`, then `swift test`.
Expected: PASS. Existing tests that relied on 0.58 or on zip order may now fail:
- check each one against the spec
- update its expectation only when the spec requires the new behaviour, and say so in the commit body

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Layout Tests/CLITests/TemplateVocabularyTests.swift
git commit -m "Place photos by best pairing and use one 0.65 crop floor everywhere"
```

---

### Task 4: Placement payload: replay, stale recompute, edits, document text

**Files:**
- Modify: `Sources/Core/Plan/PlanModels.swift`: `SlidePlan` (lines 67–79) gains `placement`, and a new `SlidePlacement` type
- Modify: `Sources/Core/Layout/LayoutResolver.swift:21-48` (replay before the vocabulary path)
- Modify: `Sources/Core/Layout/TemplateVocabulary.swift`: extract `render(page:placed:plan:start:context:titlePlaced:captionCount:)` out of `build`
- Modify: `Sources/Core/Plan/PlanEditor.swift:22-50`
- Modify: `Sources/Core/Document/CanvasDocument.swift`: `DocumentLayer` gains `textRole: String?` and `lineCount: Int?`, and the conversion at lines 85–110 fills them
- Test: `Tests/CLITests/PlacementE2ETests.swift`

**Interfaces:**
- Consumes: `SlotAssignment.assign` and `.Placed` (Task 3), and `LayoutContext.pages` (Task 1).
- Produces:
```swift
public struct SlidePlacement: Codable, Sendable, Equatable {
    public var catalogueVersion: Int
    public var pageID: String            // DesignedSet id of the page or linked run
    public var runOffset: Int            // this slide's position inside the run (0 for single pages)
    public var runLength: Int
    public var placed: [SlotAssignment.Placed]   // the whole page's assignment, repeated on every run member
    public var slide: ResolvedSlide?     // nil = stale; recompute from pageID + placed
}
// SlidePlan: public var placement: SlidePlacement?   (decodeIfPresent; nil for old plans)
// TemplateVocabulary:
static func render(page: DesignedSet, placed: [SlotAssignment.Placed], plan: CarouselPlan, start: Int,
                   context: LayoutContext, titlePlaced: inout Bool, captionCount: inout Int) -> [ResolvedSlide]
```

- [ ] **Step 1: Write the failing tests**

`Tests/CLITests/PlacementE2ETests.swift`. Copy the four private helpers `context`, `photo`, `set` and `slot` from `TemplateVocabularyTests.swift:321-340` into this file verbatim. They are private there.
```swift
import Core
import Foundation
import Render
import Testing

@Suite struct PlacementE2ETests {
    @Test func storedPlacementReplaysExactlyAndFixesSlideIndices() throws {
        let page = pageSet("p", slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)])
        let a = photo("a", aspect: 0.8), b = photo("b", aspect: 0.8)
        let ctx = try context(photos: [a, b], vocabulary: [], pages: [page])
        var plan = planWithPlacements(page: page, photos: [a, b], context: ctx)
        let first = LayoutResolver.resolve(plan, context: ctx)
        #expect(first.slides.map(\.variant) == ["template.p", "template.p"])
        plan = try PlanEditor.apply(.reorder(from: 1, to: 0), to: plan)
        let reordered = LayoutResolver.resolve(plan, context: ctx)
        #expect(reordered.slides.map(\.index) == [0, 1])
        #expect(reordered.slides[0].elements.first { $0.kind == .photo }?.assetID == b.assetID)
    }

    @Test func swappingInAPhotoThatDoesNotFitFallsBackWithoutLosingIt() throws {
        let page = pageSet("wide-only", slots: [slot(x: 0, y: 0.3, w: 1, h: 0.4, aspect: 2.0, z: 0)])
        let wide = photo("wide", aspect: 2.0), tall = photo("tall", aspect: 0.5)
        let ctx = try context(photos: [wide, tall], vocabulary: [], pages: [page])
        var plan = planWithPlacements(page: page, photos: [wide], context: ctx)
        plan = try PlanEditor.apply(.swap(slide: 0, photo: wide.assetID, with: tall.assetID), to: plan)
        #expect(plan.slides[0].placement?.slide == nil)          // stale
        let resolved = LayoutResolver.resolve(plan, context: ctx)
        #expect(resolved.slides[0].elements.contains { $0.assetID == tall.assetID })
        #expect(resolved.slides[0].variant != "template.wide-only")
    }

    @Test func plansWithoutPlacementRenderTheSameAsBefore() throws {
        // Golden: a plan decoded from the pre-placement JSON shape resolves identically with and without the pages library.
        let a = photo("a", aspect: 0.8)
        let plan = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [
            SlidePlan(primitive: .hero, mood: "", density: "balanced", photos: [.plain(a.assetID)], decorations: [], stamps: [])])
        let json = try JSONEncoder().encode(plan)
        #expect(!String(decoding: json, as: UTF8.self).contains("placement"))
        let decoded = try JSONDecoder().decode(CarouselPlan.self, from: json)
        let without = LayoutResolver.resolve(decoded, context: try context(photos: [a], vocabulary: [], pages: []))
        let with = LayoutResolver.resolve(decoded, context: try context(photos: [a], vocabulary: [], pages: [pageSet("x", slots: [slot(x: 0, y: 0, w: 1, h: 1, aspect: 0.8, z: 0)])]))
        #expect(try JSONEncoder().encode(without.slides) == JSONEncoder().encode(with.slides))
    }

    @Test func documentKeepsTextRoleAndLineCount() throws {
        let slide = ResolvedSlide(index: 0, primitive: .hero, requestedPrimitive: .hero, background: "plain", grain: 0, filmEdge: false,
            elements: [ResolvedElement(kind: .text, assetID: nil, text: "Days in the mist", frame: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1),
                                       rotationDegrees: 0, crop: nil, zIndex: 5, opacity: 1, border: 0, shadow: false,
                                       fontID: "InstrumentSerif-Regular", fontSize: 40, numberOfLines: 2, textRole: "title")], warnings: [])
        let doc = CanvasDocument(from: ResolvedCarousel(id: "c1", aspect: .portrait4x5, seed: "1", resolverVersion: "layout-3", slides: [slide]), photos: [:])
        let layer = try #require(doc.layers.first { $0.kind == .text })
        #expect(layer.textRole == "title")
        #expect(layer.lineCount == 2)
    }

    // Builds one single-page slide per photo, with placements, the way PageSearch will.
    private func planWithPlacements(page: DesignedSet, photos: [PhotoRecord], context: LayoutContext) -> CarouselPlan {
        var title = false, captions = 0
        let base = CarouselPlan(id: "c1", brief: "", direction: nil, slides: [])
        let slides = photos.enumerated().map { i, p -> SlidePlan in
            let placed = SlotAssignment.assign([p.assetID], to: page, hero: p.assetID, keepOrder: false,
                                               records: context.photos, features: context.features)!.placed
            let resolved = TemplateVocabulary.render(page: page, placed: placed, plan: base, start: i, context: context,
                                                     titlePlaced: &title, captionCount: &captions)[0]
            var s = SlidePlan(primitive: .hero, mood: "", density: "balanced", photos: [.plain(p.assetID)], decorations: [], stamps: [])
            s.placement = SlidePlacement(catalogueVersion: 2, pageID: page.id, runOffset: 0, runLength: 1, placed: placed, slide: resolved)
            return s
        }
        return CarouselPlan(id: "c1", brief: "", direction: nil, slides: slides)
    }

    private func pageSet(_ id: String, slots: [DesignedSet.Slot]) -> DesignedSet {
        DesignedSet(id: id, sourceRef: "test", aspect: .portrait4x5, slideCount: 1, background: "#FFFFFF", slots: slots,
                    sourceTemplate: "t", pageIndex: 0, pageRole: "statement", coverCapable: true)
    }
}
```
The copied `context` helper gains a `pages: [DesignedSet] = []` parameter, passed to `LayoutContext(pages:)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PlacementE2ETests`
Expected: a compile failure: no `placement`, `SlidePlacement`, `render`, `textRole` or `lineCount`.

- [ ] **Step 3: Implement**

1. **`PlanModels.swift`:**
   - add `SlidePlacement` exactly as in Interfaces, and `public var placement: SlidePlacement? = nil` on `SlidePlan`
   - `SlidePlan` uses synthesized `Codable`, so switch to a custom `init(from:)` using `decodeIfPresent` for `placement`
   - encoding must **omit** the key when it is nil (`encodeIfPresent`), so old plan JSON stays byte-identical
2. **`TemplateVocabulary`:** move everything in `build` after the assignment (slot slicing, text layers, frames, background, metrics) into `render(page:placed:...)`. `build` then calls `SlotAssignment.assign` followed by `render`. `render` sets `variant = "template.\(page.id)"` as today.
3. **`LayoutResolver.resolve`:** at the top of the `while` loop, before the vocabulary branch:
   ```swift
   if !plan.isBaseline, let placement = plan.slides[index].placement {
       if var stored = placement.slide {
           stored.index = slides.count
           slides.append(stored); index += 1
           if stored.elements.contains(where: { $0.textRole == "title" }) { titlePlaced = true }
           continue
       }
       if placement.runLength == 1, let page = context.pages.first(where: { $0.id == placement.pageID }) {
           let ids = plan.slides[index].photos.map(\.assetID)
           let hero = plan.slides[index].photos.first { $0.role == "hero" }?.assetID ?? ids.first
           if let fresh = SlotAssignment.assign(ids, to: page, hero: hero, keepOrder: context.keepOrder,
                                                records: context.photos, features: context.features) {
               slides += TemplateVocabulary.render(page: page, placed: fresh.placed, plan: plan, start: slides.count,
                                                   context: context, titlePlaced: &titlePlaced, captionCount: &captionCount)
               index += 1; continue
           }
       }
       // Stale run member or no fit: the ordinary single-slide path, never the vocabulary windows.
       slides.append(resolveSlide(plan.slides[index], index: slides.count, plan: plan, context: context, history: &history, rng: &rng))
       index += 1; continue
   }
   ```
4. **`PlanEditor.apply`:**
   - **`.swap`:** set `p.slides[s].placement?.slide = nil`. For every run member (`runLength > 1`, the same `pageID` in adjacent slides), set `placement = nil`.
   - **`.remove`:** set that slide's `placement = nil`, and for run members too.
   - **`.reorder`:** if the moved slide has `runLength > 1`, set `placement = nil` on all members of that run before moving.
5. **`CanvasDocument`:** add `textRole: String?` and `lineCount: Int?` to `DocumentLayer`, using `decodeIfPresent`, with defaulted init parameters. In the conversion, set `textRole: isText ? e.textRole : nil` and `lineCount: isText ? e.numberOfLines : nil`. Where the document converts back to a `ResolvedElement` for rendering (search for `numberOfLines:` in `Sources/Render/DocumentRenderer.swift`), pass `lineCount` through as `numberOfLines` and `textRole` through as `textRole`.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter PlacementE2ETests`, then `swift test`.
Expected: PASS, with the full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core Sources/Render/DocumentRenderer.swift Tests/CLITests/PlacementE2ETests.swift
git commit -m "Store chosen pages on each slide and replay them; edits invalidate only what they touch"
```

---

### Task 5: Template-aware planner: moments, schema, validator, prompt

**Files:**
- Modify: `Sources/Core/Plan/Direction.swift:50-90`
- Modify: `Sources/Director/Schemas.swift:30-39`
- Modify: `Sources/Core/Plan/PlanValidator.swift:45-68`
- Modify: `Sources/Director/Resources/Prompts/planner.system.md` (bump the header to `planner v10`)
- Modify: `Sources/Director/ArtDirector.swift:271-279` (`plannerContent`)
- Modify: `Sources/iOSApp/StoryPipeline.swift:147-150` and `Sources/CLI/RunPipeline.swift:383-400` (summary tags)
- Test: `Tests/CLITests/DirectorE2ETests.swift` (extend; it already drives `ArtDirector` with a fake model)

**Interfaces:**
- Produces:
```swift
extension Direction {
    public struct Moment: Codable, Sendable, Equatable {
        public var label: String
        public var photos: [AssetID]        // ranked alternatives, best first
        public var mustInclude: [AssetID]   // 0-2, subset of photos
        public var size: String             // "1" | "few" | "many"
        public var sizeRange: ClosedRange<Int> { size == "1" ? 1...1 : size == "few" ? 2...3 : 4...9 }
    }
}
// Direction gains: public var moments: [Moment] (default []), coverCandidates: [AssetID] (default []), titleIdeas: [String] (default [])
// When moments is non-empty, init sets orderedAssetIDs = moments.flatMap(\.photos),
// coverAssetID = coverCandidates.first ?? coverAssetID, and titleIdea = titleIdeas.first ?? titleIdea.
```

- [ ] **Step 1: Write the failing tests**

In `DirectorE2ETests.swift`, follow the file's existing fake-model pattern. Search for the helper that returns a canned planner JSON, and add a variant whose directions include `moments`, `coverCandidates` and `titleIdeas`. Then add:
```swift
@Test func momentsDecodeAndDriveTheDirection() throws {
    let json = #"{"brief":"b","style":{"density":"balanced","overlap":"none","grouping":"mixed","decoration":"none","rotation":"none","whitespace":"tight"},"coverAssetID":"a","orderedAssetIDs":["a"],"keepTogether":[],"emphasisAssetIDs":[],"seamless":false,"titleIdea":null,"moments":[{"label":"arrival","photos":["b","a"],"mustInclude":["b"],"size":"1"},{"label":"view","photos":["c","d","e"],"mustInclude":[],"size":"few"}],"coverCandidates":["c"],"titleIdeas":["Up in the clouds"]}"#
    let d = try JSONDecoder().decode(Direction.self, from: Data(json.utf8))
    #expect(d.orderedAssetIDs.map(\.rawValue) == ["b", "a", "c", "d", "e"])
    #expect(d.coverAssetID.rawValue == "c")
    #expect(d.titleIdea == "Up in the clouds")
    #expect(d.moments[1].sizeRange == 2...3)
}

@Test func invalidMomentsAreFlagged() {
    let pool = ["a", "b", "c", "d", "e"].map(AssetID.init(rawValue:))
    func direction(_ moments: [Direction.Moment]) -> Direction {
        Direction(brief: "b", style: .baseline, coverAssetID: pool[0], orderedAssetIDs: [pool[0]], moments: moments, coverCandidates: [pool[0]])
    }
    let duplicate = direction([.init(label: "x", photos: [pool[0], pool[1]], mustInclude: [], size: "few"),
                               .init(label: "y", photos: [pool[1], pool[2]], mustInclude: [], size: "few")])
    let unknown = direction([.init(label: "x", photos: [pool[0], AssetID(rawValue: "zzz")], mustInclude: [], size: "few")])
    let badMust = direction([.init(label: "x", photos: [pool[0], pool[1]], mustInclude: [pool[3]], size: "few")])
    let outOfOrder = direction([.init(label: "x", photos: [pool[1], pool[0]], mustInclude: [], size: "few"),
                                .init(label: "y", photos: [pool[2], pool[3], pool[4]], mustInclude: [], size: "few")])
    for (d, keepOrder) in [(duplicate, false), (unknown, false), (badMust, false), (outOfOrder, true)] {
        let issues = PlanValidator.validate(plannerResponse(spine: pool, directions: [d, d]), pool: pool, requestedSlides: nil,
                                            exactSet: keepOrder, keepOrder: keepOrder, flagged: [])
        #expect(issues.contains { $0.path.contains("moments") }, "no moments issue for \(d.moments)")
    }
}
```
`plannerResponse(spine:directions:)` is a small local helper building a `PlannerResponse` with `sequenceIntent` of matching length. Mirror how existing validator tests construct one. Search `PlannerResponse(` in `Tests/`. Check `PlanValidator.validate`'s exact parameter labels in `PlanValidator.swift:1-20` and match them.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DirectorE2ETests`
Expected: a compile failure, because there's no `Moment` or `moments`.

- [ ] **Step 3: Implement**

1. **`Direction.swift`:**
   - add `Moment`, the three properties, the `CodingKeys` cases, `decodeIfPresent` with `[]` defaults, and defaulted init parameters
   - apply the precedence rules from Interfaces at the end of `init` (after `cleanTitle`)
   - run every entry of `titleIdeas` through `cleanTitle`, dropping nils
2. **`Schemas.swift`:** add to the `direction` object (all required, as the strict schema expects):
   ```swift
   ("moments", .arr(.obj([("label", .str()), ("photos", .arr(id, min: 1, max: 9)), ("mustInclude", .arr(id, min: 0, max: 2)),
                          ("size", .str(["1", "few", "many"]))]), min: 1, max: 12)),
   ("coverCandidates", .arr(id, min: 1, max: 3)),
   ("titleIdeas", .arr(.object([("type", .string("string")), ("maxLength", .int(40))]), min: 0, max: 3)),
   ```
   Raise `orderedAssetIDs` to `max: 30`, since alternatives are included.
3. **`PlanValidator`**, per direction, when `!d.moments.isEmpty`:
   ```swift
   let flat = d.moments.flatMap(\.photos)
   if Set(flat).count != flat.count { add("moments", "a photo appears in more than one moment") }
   for id in flat where !poolSet.contains(id) { add("moments", "\(id) is not a candidate") }
   for (m, moment) in d.moments.enumerated() {
       if moment.photos.isEmpty { add("moments[\(m)]", "empty moment") }
       if !moment.mustInclude.allSatisfy(moment.photos.contains) { add("moments[\(m)].mustInclude", "must be photos of this moment") }
       if !["1", "few", "many"].contains(moment.size) { add("moments[\(m)].size", "unknown size") }
   }
   if exactSet && (Set(flat) != poolSet || flat.count != pool.count) { add("moments", "must contain every exact photo exactly once") }
   if keepOrder && flat != pool { add("moments", "must preserve the exact input order") }
   if !d.coverCandidates.allSatisfy(Set(flat).contains) { add("coverCandidates", "must be photos in this direction's moments") }
   ```
   Skip the `grouping == "single"` requested-count check, and allow `ids.count` up to 30 instead of 20 for directions with moments. Leave the rule for directions without moments unchanged.
4. **`planner.system.md`:**
   - delete the line `- The page is mostly white. One photo is large enough to read as the hero. Smaller photos are rhythm, not a grid of equals.`
   - delete the sentence about the "at least a third of a direction's photos must differ" quota
   - after the `orderedAssetIDs` rule, add:
     ```
     - moments: the direction's story as 1-12 ordered moments. Each moment has a short label, its photos as ranked alternatives (best first; list 1-9, more alternatives than you would show), mustInclude (0-2 photos that must appear), and size: "1" (one photo carries it), "few" (2-3), or "many" (4-9). A photo belongs to at most one moment. The layout engine chooses how many alternatives to show and lays them out on authored pages; do not count slides.
     - coverCandidates: 1-3 photos that could open this direction, best first.
     - titleIdeas: 0-3 short titles (at most 40 characters) grounded in the owner's brief; empty when no honest title fits.
     - orderedAssetIDs: repeat the moments' photos flattened in order (the engine derives it anyway).
     ```
   - keep `recommendedSlideCount = the number of photos in the spine.`, because the spine is still the one-photo-per-slide baseline
   - bump the header comment to `planner v10`
5. **`ArtDirector.plannerContent`:** in the non-exact branch, add a second sentence after the spine target:
   ```swift
   + (input.requestedSlides.map { " Directions: the owner wants about \($0) slides; the layout engine decides how many photos share a slide, so list moments with alternatives rather than a photo count." } ?? "")
   ```
6. **Summaries:** append a shape and people tag to both builders:
   - iOS (`StoryPipeline.swift:147`): add `ShapeClass.of(aspect: Double(photo.pixelWidth) / Double(max(photo.pixelHeight, 1))).rawValue` and, when `features[id]?.faces.isEmpty == false`, `"\(features[id]!.faces.count) faces"`
   - CLI (`RunPipeline.summary`): add the same `ShapeClass` tag after the orientation

- [ ] **Step 4: Run the tests**

Run: `swift test --filter DirectorE2ETests`, then `swift test`.
Expected: PASS. Existing golden prompts or fixtures that embed `planner v9` are updated to v10 in the same commit.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Plan Sources/Director Sources/iOSApp/StoryPipeline.swift Sources/CLI/RunPipeline.swift Tests/CLITests
git commit -m "Planner returns story moments with ranked alternatives, cover candidates and titles"
```

---

### Task 6: PageSearch: photos and pages chosen together

**Files:**
- Create: `Sources/Core/Compose/PageSearch.swift`
- Create: `Sources/Core/Compose/PageScore.swift` (the weights, one place)
- Test: `Tests/CLITests/PageSearchE2ETests.swift`

**Interfaces:**
- Consumes: `SlotAssignment` (Task 3), `TemplateVocabulary.render` and `SlidePlacement` (Task 4), `Direction.moments`, `coverCandidates` and `titleIdeas` (Task 5), and `ShapeClass` (Task 1).
- Produces:
```swift
public enum PageSearch {
    public struct Result: Sendable {
        public var plan: CarouselPlan          // slides carry placements; direction attached
        public var score: Double
        public var family: String
        public var whiteCards: Int
        public var warnings: [String]
    }
    /// Searches one family. Returns nil only when the direction has no photos.
    public static func search(_ direction: Direction, id: String, family: String, pages: [DesignedSet],
                              context: CompositionContext, seed: UInt64, excludedCovers: Set<AssetID> = []) -> Result?
    /// Up to `limit` families ranked by how many pages fit the pool's shape mix (ties by family id).
    public static func candidateFamilies(_ pages: [DesignedSet], photos: [AssetID], context: CompositionContext, limit: Int = 4) -> [String]
    /// Moments for a direction without them: one per keepTogether group, then one per remaining photo, in orderedAssetIDs order.
    public static func legacyMoments(_ direction: Direction) -> [Direction.Moment]
}
```

- [ ] **Step 1: Write the failing tests**

`Tests/CLITests/PageSearchE2ETests.swift`. Use these fixtures:
- a synthetic page family built in the test: one cover (a single slot with a title layer), one statement page, one 2-slot wide/wide stack, one 3-slot tall strip, and one 2×2 grid
- a second family with the same shapes but different ids

Build `CompositionContext` with `pages:` and `photos` via the same `photo(_:aspect:)` helper as the other suites.
```swift
@Test func searchFillsEverySlideWithAuthoredPagesFromOneFamily() throws {
    let ctx = try context(pool: portraits(6) + landscapes(2), pages: familyA + familyB)
    let d = direction(momentsOf: [["p0"], ["p1", "p2", "p3"], ["l0", "l1"], ["p4", "p5"]], cover: ["p0"], title: "Up in the clouds")
    let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA + familyB, context: ctx, seed: 7))
    #expect(result.plan.slides.allSatisfy { $0.placement != nil })
    #expect(result.whiteCards == 0)
    let pageIDs = result.plan.slides.compactMap { $0.placement?.pageID }
    #expect(pageIDs.allSatisfy { id in familyA.contains { $0.id == id } })
    #expect(result.plan.slides[0].placement.map { id in familyA.first { $0.id == id.pageID }?.coverCapable } == true)
    let layout = LayoutResolver.resolve(result.plan, context: layoutContext(ctx))
    #expect(layout.slides[0].elements.filter { $0.textRole == "title" }.count == 1)
    #expect(layout.slides.dropFirst().allSatisfy { !$0.elements.contains { $0.textRole == "title" } })
}

@Test func sameSeedSameCarousel() throws {
    let ctx = try context(pool: portraits(6) + landscapes(2), pages: familyA)
    let d = direction(momentsOf: [["p0"], ["p1", "p2", "p3"], ["l0", "l1"], ["p4", "p5"]], cover: ["p0"], title: nil)
    let a = PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 7)?.plan
    let b = PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 7)?.plan
    #expect(a == b)
}

@Test func exactSetKeepsEveryPhotoIncludingAPanoramaThatFitsNothing() throws {
    var pool = portraits(19); pool.append(photo("pano", aspect: 16.0 / 9.0 * 1.6))   // wider than any slot
    let ctx = try context(pool: pool, pages: familyA, exactSet: true)
    let d = direction(momentsOf: pool.map { [$0.assetID.rawValue] }, cover: ["p0"], title: nil)
    let result = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 1))
    #expect(Set(result.plan.photoAssetIDs) == Set(pool.map(\.assetID)))
    #expect(result.whiteCards == 1)
    #expect(result.warnings.contains { $0.contains("pano") })
}

@Test func mustIncludeIsHardAndKeepOrderIsRespected() throws {
    let ctx = try context(pool: portraits(8), pages: familyA, keepOrder: true, exactSet: true)
    let ids = (0..<8).map { "p\($0)" }
    let d = direction(momentsOf: [Array(ids[0..<3]), Array(ids[3..<8])], cover: ["p0"], title: nil)
    let plan = try #require(PageSearch.search(d, id: "c1", family: "A", pages: familyA, context: ctx, seed: 3)).plan
    let layout = LayoutResolver.resolve(plan, context: layoutContext(ctx))
    let reading = layout.slides.flatMap { slide in
        slide.elements.filter { $0.kind == .photo }.sorted {
            abs($0.frame.midY - $1.frame.midY) > 0.05 ? $0.frame.midY < $1.frame.midY : $0.frame.midX < $1.frame.midX
        }.compactMap(\.assetID?.rawValue)
    }
    #expect(reading == ids)
}

@Test func sixtyPhotoPoolStaysInsideTheSimulatorGuard() throws {
    let pool = portraits(40) + landscapes(20)
    let ctx = try context(pool: pool, pages: familyA + familyB)
    let d = direction(momentsOf: stride(from: 0, to: 60, by: 6).map { i in pool[i..<min(i + 6, 60)].map(\.assetID.rawValue) }, cover: ["p0"], title: "t")
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = PageSearch.search(d, id: "c1", family: "A", pages: familyA + familyB, context: ctx, seed: 1) }
    #expect(elapsed < .seconds(2), "search took \(elapsed)")
}
```
The fixtures (`familyA`, `familyB`, `portraits(n)` giving ids `p0…`, `landscapes(n)` giving `l0…`, `direction(momentsOf:cover:title:)`, `context(pool:pages:exactSet:keepOrder:)`, `layoutContext(_:)`) are private helpers in this file:
- `direction(...)` builds `Moment`s with `size` `"1"` for one photo, `"few"` for 2–3 and `"many"` otherwise
- `layoutContext` copies aspect, photos, features, stylePack, pages and keepOrder into a `LayoutContext` with `seed: 1`
- `UnitRect.midX` and `midY`: if missing, compute `x + width / 2` inline

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PageSearchE2ETests`
Expected: a compile failure, because `PageSearch` doesn't exist.

- [ ] **Step 3: Implement `PageScore.swift`**

```swift
/// Every weight PageSearch uses. Higher total is better.
enum PageScore {
    static let authoredPage = 1.0, gridPage = 0.4      // family "layouts" counts as grid
    static let authoredNeighbour = 0.3                  // same sourceTemplate, pageIndex = previous + 1
    static let titledCover = 0.5
    static let storyRank = 0.2                          // × (1 - rank / count) per photo
    static let cropCost = 1.0                           // × SlotAssignment cost
    static let repeatedPage = 1.0
    static let monotony = 0.6                           // third page in a row with the same role
    static let movedPhoto = 0.4
    static let whiteCard = 5.0
    static let slideCountMiss = 0.5                     // per slide beyond target ± 1
    static let beamWidth = 48, pagesPerStep = 12, alternativesPerMoment = 6
}
```

- [ ] **Step 4: Implement `PageSearch.swift`**

```swift
import Foundation

public enum PageSearch {
    public struct Result: Sendable { public var plan: CarouselPlan; public var score: Double; public var family: String; public var whiteCards: Int; public var warnings: [String] }

    struct Step: Sendable { var pageID: String?; var photos: [AssetID]; var placed: [SlotAssignment.Placed]; var role: String }
    struct State: Sendable {
        var moment = 0, usedInMoment = 0, moved = 0, whiteCards = 0
        var used: Set<AssetID> = []
        var steps: [Step] = []
        var score = 0.0
        var key: String { steps.map { ($0.pageID ?? "white") + ":" + $0.photos.map(\.rawValue).joined(separator: ",") }.joined(separator: "|") }
    }

    public static func legacyMoments(_ d: Direction) -> [Direction.Moment] {
        var grouped = Set<AssetID>(); var out: [Direction.Moment] = []
        for id in d.orderedAssetIDs where !grouped.contains(id) {
            if let group = d.keepTogether.first(where: { $0.contains(id) }) {
                grouped.formUnion(group)
                out.append(.init(label: "", photos: group, mustInclude: group, size: group.count <= 3 ? "few" : "many"))
            } else {
                grouped.insert(id); out.append(.init(label: "", photos: [id], mustInclude: [id], size: "1"))
            }
        }
        return out
    }

    public static func candidateFamilies(_ pages: [DesignedSet], photos: [AssetID], context: CompositionContext, limit: Int = 4) -> [String] {
        let shapes = Set(photos.compactMap { context.photos[$0].map { ShapeClass.of(aspect: Double($0.pixelWidth) / Double(max($0.pixelHeight, 1))) } })
        let byFamily = Dictionary(grouping: pages.filter { $0.aspect == context.aspect }, by: \.familyID)
        return byFamily.map { family, pages -> (String, Int) in
            (family, pages.filter { page in page.expandedSlots.allSatisfy { shapes.contains(ShapeClass.of(aspect: $0.aspect)) } }.count)
        }.filter { $0.1 > 0 && $0.0 != "layouts" }
         .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }

    public static func search(_ direction: Direction, id: String, family: String, pages all: [DesignedSet],
                              context: CompositionContext, seed: UInt64, excludedCovers: Set<AssetID> = []) -> Result? {
        let moments = direction.moments.isEmpty ? legacyMoments(direction) : direction.moments
        guard !moments.isEmpty else { return nil }
        // The family's pages plus plain grids as filler; grids score lower.
        let pages = all.filter { $0.aspect == context.aspect && ($0.familyID == family || $0.familyID == "layouts") }
            .sorted { $0.id < $1.id }
        let mandatory = Set(context.exactSet ? moments.flatMap(\.photos) : moments.flatMap(\.mustInclude))
        let covers = (direction.coverCandidates.isEmpty ? [direction.coverAssetID] : direction.coverCandidates).filter { !excludedCovers.contains($0) }
        let rank = Dictionary(moments.flatMap { m in m.photos.enumerated().map { ($0.element, 1 - Double($0.offset) / Double(max(m.photos.count, 1))) } },
                              uniquingKeysWith: max)
        let hasTitle = !(direction.titleIdeas.isEmpty && direction.titleIdea == nil && context.storyHint == nil)
        var cache: [String: SlotAssignment.Result?] = [:]

        func shape(_ id: AssetID) -> ShapeClass {
            guard let r = context.photos[id] else { return .square }
            return ShapeClass.of(aspect: Double(r.pixelWidth) / Double(max(r.pixelHeight, 1)))
        }
        func assign(_ ids: [AssetID], _ page: DesignedSet, hero: AssetID?) -> SlotAssignment.Result? {
            let key = page.id + "|" + ids.map(\.rawValue).joined(separator: ",") + "|" + (hero?.rawValue ?? "") + "|\(context.keepOrder)"
            if let hit = cache[key] { return hit }
            let r = SlotAssignment.assign(ids, to: page, hero: hero, keepOrder: context.keepOrder, records: context.photos, features: context.features)
            cache[key] = r; return r
        }
        /// Photo tuples for a page of k slots: mandatory first, then best-ranked alternatives matching the slot shapes.
        func tuple(for page: DesignedSet, remaining: [AssetID], next: [AssetID], first: Bool) -> (ids: [AssetID], moved: Int)? {
            let k = page.expandedSlots.count
            if context.keepOrder { return remaining.count >= k ? (Array(remaining.prefix(k)), 0) : nil }
            var pool = Array(remaining.prefix(PageScore.alternativesPerMoment))
            var moved = 0
            if pool.count < k, let borrow = next.first { pool.append(borrow); moved = 1 }
            guard pool.count >= k else { return nil }
            var chosen = pool.filter(mandatory.contains).prefix(k).map { $0 }
            if first, let cover = covers.first(where: pool.contains), !chosen.contains(cover) {
                if chosen.count == k { chosen.removeLast() }
                chosen.insert(cover, at: 0)
            }
            let slotShapes = page.expandedSlots.map { ShapeClass.of(aspect: $0.aspect) }
            for s in slotShapes.dropFirst(chosen.count) {
                let pick = pool.filter { !chosen.contains($0) }
                    .max { (shape($0) == s ? 1 : 0, rank[$0] ?? 0, $1.rawValue) < (shape($1) == s ? 1 : 0, rank[$1] ?? 0, $0.rawValue) }
                if let pick { chosen.append(pick) }
            }
            guard chosen.count == k else { return nil }
            return (chosen, moved == 1 && chosen.contains(pool.last!) ? 1 : 0)
        }

        var beam = [State()]
        var finished: [State] = []
        var guardSteps = 0
        while !beam.isEmpty, guardSteps < 40 {
            guardSteps += 1
            var next: [State] = []
            for state in beam {
                if state.moment >= moments.count { finished.append(state); continue }
                let m = moments[state.moment]
                let remaining = m.photos.filter { !state.used.contains($0) }
                let nextMoment = state.moment + 1 < moments.count ? moments[state.moment + 1].photos.filter { !state.used.contains($0) } : []
                let mustLeft = remaining.filter(mandatory.contains)
                let range = context.exactSet ? m.photos.count...m.photos.count : m.sizeRange
                // Advance when the moment has enough and nothing mandatory is left.
                if state.usedInMoment >= min(range.lowerBound, m.photos.count), mustLeft.isEmpty {
                    var s = state; s.moment += 1; s.usedInMoment = 0; next.append(s)
                }
                guard state.usedInMoment < range.upperBound, !remaining.isEmpty else { continue }
                let first = state.steps.isEmpty
                let fitting = pages.filter { !first || ($0.slideCount == 1 && $0.coverCapable == true) }
                  .filter { $0.expandedSlots.count <= min(remaining.count + 1, range.upperBound - state.usedInMoment + 1) }
                let shapesHere = remaining.prefix(PageScore.alternativesPerMoment).map(shape)
                let ranked = fitting.map { page -> (DesignedSet, Int) in
                    (page, page.expandedSlots.filter { shapesHere.contains(ShapeClass.of(aspect: $0.aspect)) }.count - (state.steps.contains { $0.pageID == page.id } ? 10 : 0))
                }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }.prefix(PageScore.pagesPerStep).map(\.0)
                var placedAny = false
                for page in ranked {
                    guard let (ids, moved) = tuple(for: page, remaining: remaining, next: nextMoment, first: first) else { continue }
                    let hero = first ? ids.first : nil
                    guard let fit = assign(ids, page, hero: hero) else { continue }
                    placedAny = true
                    var s = state
                    s.steps.append(Step(pageID: page.id, photos: ids, placed: fit.placed, role: page.pageRole ?? "grid"))
                    s.used.formUnion(ids); s.usedInMoment += ids.count - moved; s.moved += moved
                    s.score += (page.familyID == "layouts" ? PageScore.gridPage : PageScore.authoredPage)
                    if let prev = state.steps.last?.pageID.flatMap({ p in pages.first { $0.id == p } }),
                       prev.sourceTemplate == page.sourceTemplate, (prev.pageIndex ?? -9) + prev.slideCount == page.pageIndex { s.score += PageScore.authoredNeighbour }
                    if first, hasTitle, page.texts?.contains(where: { $0.role == "title" }) == true { s.score += PageScore.titledCover }
                    s.score += ids.reduce(0) { $0 + PageScore.storyRank * (rank[$1] ?? 0) }
                    s.score -= PageScore.cropCost * fit.cost
                    if state.steps.contains(where: { $0.pageID == page.id }) { s.score -= PageScore.repeatedPage }
                    let roles = state.steps.suffix(2).map(\.role)
                    if roles.count == 2, roles.allSatisfy({ $0 == page.pageRole }) { s.score -= PageScore.monotony }
                    s.score -= PageScore.movedPhoto * Double(moved)
                    next.append(s)
                }
                // Last resort: the next mandatory (or best) photo alone on a white card.
                if !placedAny, let lonely = mustLeft.first ?? (state.usedInMoment < range.lowerBound ? remaining.first : nil) {
                    var s = state
                    s.steps.append(Step(pageID: nil, photos: [lonely], placed: [], role: "statement"))
                    s.used.insert(lonely); s.usedInMoment += 1; s.whiteCards += 1; s.score -= PageScore.whiteCard
                    next.append(s)
                }
            }
            beam = next.sorted { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
            beam = Array(beam.prefix(PageScore.beamWidth))
        }
        let target = context.maxSlides
        func final(_ s: State) -> Double {
            let slides = s.steps.reduce(0) { $0 + ($1.pageID.flatMap { p in pages.first { $0.id == p }?.slideCount } ?? 1) }
            guard let target else { return s.score }
            return s.score - PageScore.slideCountMiss * Double(max(0, abs(slides - target) - 1))
        }
        guard let best = finished.max(by: { final($0) != final($1) ? final($0) < final($1) : $0.key > $1.key }) else { return nil }
        return Result(plan: materialize(best, direction: direction, id: id, pages: pages, context: context, seed: seed),
                      score: final(best), family: family, whiteCards: best.whiteCards,
                      warnings: best.steps.filter { $0.pageID == nil }.map { "\(id): \($0.photos[0].rawValue) fits no page in family \(family); white card" })
    }

    /// Renders the winning steps into SlidePlans with stored placements.
    static func materialize(_ state: State, direction: Direction, id: String, pages: [DesignedSet], context: CompositionContext, seed: UInt64) -> CarouselPlan {
        var plan = CarouselPlan(id: id, brief: direction.brief, direction: direction, compositionSeed: String(seed, radix: 16), slides: [])
        let layout = LayoutContext(aspect: context.aspect, photos: context.photos, features: context.features, stylePack: context.stylePack,
                                   seed: seed, storyHint: context.storyHint, pages: pages, keepOrder: context.keepOrder)
        var titlePlaced = false, captions = 0
        for step in state.steps {
            guard let pageID = step.pageID, let page = pages.first(where: { $0.id == pageID }) else {
                plan.slides.append(SlidePlan(primitive: .hero, mood: "", density: "quiet", photos: [.plain(step.photos[0])], decorations: [], stamps: []))
                continue
            }
            let rendered = TemplateVocabulary.render(page: page, placed: step.placed, plan: plan, start: plan.slides.count,
                                                     context: layout, titlePlaced: &titlePlaced, captionCount: &captions)
            for (offset, slide) in rendered.enumerated() {
                let onSlide = step.placed.filter { p in
                    let f = page.expandedSlots[p.slotIndex].frame
                    return Int(floor(f.x + f.width / 2)) == offset
                }.map(\.assetID)
                var photos = onSlide.map(PhotoElement.plain)
                for i in photos.indices where i > 0 { photos[i].role = "support" }
                let primitive: Primitive = photos.count <= 1 ? .hero : photos.count == 2 ? .asymmetricPair : .overlapCluster
                var s = SlidePlan(primitive: primitive, mood: "", density: "balanced", photos: photos, decorations: [], stamps: [])
                s.placement = SlidePlacement(catalogueVersion: DesignedSet.schemaVersion, pageID: page.id, runOffset: offset,
                                             runLength: page.slideCount, placed: step.placed, slide: slide)
                plan.slides.append(s)
            }
        }
        return plan
    }
}
```
Notes for the implementer:
- `TemplateVocabulary.render` reads the title from `plan.direction`, as `storyTitle(plan:context:)` does. `plan.direction` is set before rendering, so the cover gets `titleIdeas.first`.
- A run member with no photo centred on it still gets a `SlidePlan`. Because `photos` would be empty, give it the run's first photo as a non-rendering reference by setting `photos = [.plain(step.placed[0].assetID)]` with `role = "support"`. Also add a guard in `PlanEditor.remove` so removing that reference only clears the placement. Otherwise `PlanEditor` treats an empty slide as removable and breaks the run.
- `LayoutContext` must have the `keepOrder` init parameter from Task 3.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter PageSearchE2ETests`, then `swift test`.
Expected: PASS. If the 60-photo guard fails, profile with `swift test -c release --filter sixtyPhoto`. Reduce `pagesPerStep` only after checking the cache hit rate, and report the numbers.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Compose/PageSearch.swift Sources/Core/Compose/PageScore.swift Tests/CLITests/PageSearchE2ETests.swift
git commit -m "PageSearch: choose photos and authored pages together per family"
```

---

### Task 7: Wire PageSearch into options, and load pages everywhere

**Files:**
- Modify: `Sources/Core/Compose/ComposerEngine.swift:64-175` (`composeSet`, `distinct`, `templateFamilies`)
- Modify, passing `pages:` (and `keepOrder:` where it's known) into every `CompositionContext` and `LayoutContext`:
  - `Sources/CLI/RunPipeline.swift`
  - `Sources/iOSApp/StoryPipeline.swift` (around line 244)
  - `Sources/iOSApp/StoryEditingService.swift:119-122`
  - `Sources/Session/ConceptRendering.swift:23`
  - `Sources/Session/RunSession.swift`
  - the rerender command (search `recompose` in `Sources/CLI`)
- Test: `Tests/CLITests/ComposerE2ETests.swift` (extend)

**Interfaces:**
- Consumes: `PageSearch.search`, `candidateFamilies` (Task 6), and `StylePackLoader.loadDesignedPages()` (Task 1).
- Produces: `ComposerEngine.minimumPagesPerAspect = 20`. `composeSet` returns template-first options when the aspect has enough pages, and otherwise the current path with the warning `"template-first unavailable for <aspect>: <n> pages"`.

- [ ] **Step 1: Write the failing tests**

Add to `ComposerE2ETests.swift`, using the file's existing context builders and adding `pages:`:
```swift
@Test func composeSetGivesTemplateFirstOptionsFromDifferentFamiliesAndCovers() throws {
    let pages = try StylePackLoader.loadDesignedPages().vocabulary(for: .portrait4x5)
    let (context, spine, directions) = try realisticRun(aspect: .portrait4x5, pages: pages)   // 12 mixed photos, 3 directions with moments
    let set = ComposerEngine.composeSet(directions: directions, spine: spine, context: context, runID: "r1")
    let options = set.plans.filter { !$0.isBaseline }
    #expect((2...3).contains(options.count))
    #expect(options.allSatisfy { $0.slides.allSatisfy { $0.placement != nil || $0.primitive == .hero } })
    let families = options.map { Set($0.slides.compactMap(\.placement?.pageID).compactMap { id in pages.first { $0.id == id }?.familyID }) }
    #expect(families.allSatisfy { $0.subtracting(["layouts"]).count == 1 })
    #expect(Set(families.map { $0.subtracting(["layouts"]) }).count == options.count)
    #expect(Set(options.compactMap(\.coverAssetID)).count == options.count)
    #expect(set.plans.contains(where: \.isBaseline))
}

@Test func thinAspectFallsBackToTheCurrentEngineWithAWarning() throws {
    let (context, spine, directions) = try realisticRun(aspect: .square, pages: [])   // a mostly-landscape pool infers square
    let set = ComposerEngine.composeSet(directions: directions, spine: spine, context: context, runID: "r1")
    #expect(set.warnings.contains { $0.contains("template-first unavailable for 1:1") })
    #expect(set.plans.filter { !$0.isBaseline }.allSatisfy { !$0.slides.isEmpty })
}
```
`realisticRun` is a private helper. It builds photos with the file's photo helper (8 portrait, 4 landscape; 12 landscape for square), a `SelectionSpine` over all of them, and 3 `Direction`s with moments over different subsets and different `coverCandidates`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ComposerE2ETests`
Expected: FAIL. There are no placements, and no warning.

- [ ] **Step 3: Implement in `composeSet`**

At the start of the directions loop:
```swift
let pages = context.pages.filter { $0.aspect == context.aspect }
if pages.count >= minimumPagesPerAspect {
    var kept: [CarouselPlan] = [], usedFamilies = Set<String>(), usedCovers = Set<AssetID>()
    for (i, d) in directions.enumerated() where kept.count < 3 {
        let id = "c\(i + 1)", seed = layoutSeed(runID: runID, id: id)
        let families = PageSearch.candidateFamilies(pages, photos: d.orderedAssetIDs, context: context).filter { !usedFamilies.contains($0) }
        let results = families.compactMap { PageSearch.search(d, id: id, family: $0, pages: pages, context: context, seed: seed, excludedCovers: usedCovers) }
        guard let best = results.max(by: { $0.score != $1.score ? $0.score < $1.score : $0.family > $1.family }) else {
            let fallback = compose(d, id: id, context: context, seed: seed)
            warnings.append("\(id): no family fits; used the current engine"); kept.append(fallback.plan); continue
        }
        warnings += best.warnings
        usedFamilies.insert(best.family)
        if let cover = best.plan.coverAssetID { usedCovers.insert(cover) }
        kept.append(best.plan)
    }
    return finish(base: base, kept: kept, warnings: warnings, runID: runID)   // distances + presentation order, extracted from the existing tail
} else if !context.pages.isEmpty || !context.vocabulary.isEmpty {
    warnings.append("template-first unavailable for \(context.aspect.rawValue): \(pages.count) pages")
}
```
- **The AI is unavailable (`directions` is empty) and pages are available.** Build one offline direction from the spine: `Direction(brief: "offline", style: .baseline, coverAssetID: spine.orderedAssetIDs[0], orderedAssetIDs: spine.orderedAssetIDs, moments: timeMoments(spine))`. Here `timeMoments` starts a new moment whenever the capture-time gap to the previous photo is at least 20 minutes, with each moment's `size` from its count (1 → "1", 2–3 → "few", otherwise "many"). This is the spec's deterministic fallback. Add a test to this task's Step 1: an empty `directions` array with pages yields one non-baseline option whose slides have placements.
- Extract the existing tail of `composeSet` (distances, shuffled presentation order and return) into `private static func finish(...)`, so both paths share it.
- The overlap remedy loop stays only on the legacy path.
- In `distinct`: for two plans that both have placements, compare the page families from `placement.pageID` and the covers. There is no photo-overlap quota.
- `templateFamilies` reads `slides.compactMap(\.placement?.pageID)` when present, and otherwise keeps the current resolve.

**Wiring pages into every caller:**
- **Loading:** each place that calls `StylePackLoader.loadDesignedSets()` also calls `(try? StylePackLoader.loadDesignedPages())?.vocabulary(for: aspect) ?? []`, and passes it as `pages:` (with `plan.isBaseline ? [] : pages` for `LayoutContext`, mirroring `vocabulary`).
- **keepOrder:** pass `keepOrder:` where the caller has it: `RunPipeline`/`StoryPipeline` via the options, and `StoryEditingService` from the stored run options.
- **Rerender:** `ak14 rerender --recompose` reruns `composeSet` (the search). Plain rerender replays placements.

- [ ] **Step 4: Run all package tests, then the iOS UI tests**

Run: `swift test`
Then: `xcodebuild test -project iOS/AK14iOS.xcodeproj -scheme AK14iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: every test passes, including the 5 UI tests.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "Options come from PageSearch, one family and cover each; pages load on every path"
```

---

### Task 8: Worker constitution and ETag content revision

**Files:**
- Modify: `backend/worker/src/style-config.json:60`, `Sources/Render/Resources/StylePacks/starter-editorial.json`, and `Sources/Director/ArtDirector.swift` (`defaultConstitution`): remove `- Avoid recognizable template fingerprints.` from all three
- Modify: `backend/worker/src/index.js:113`
- Test: `backend/worker/test/worker.test.js`, and `Tests/CLITests/WorkerConfigE2ETests.swift`

- [ ] **Step 1: Write the failing tests**

In `worker.test.js`, follow its existing import of `createHandler`:
```js
test("config ETag carries a content revision and schema version 1", async () => {
  const handle = createHandler(async () => { throw new Error("no upstream"); });
  const res = await handle(new Request("https://x/v1/config"), {});
  const etag = res.headers.get("etag");
  assert.match(etag, /^"starter-editorial-1\.0\.0-config-1-[0-9a-f]{8}"$/);
  const body = await res.json();
  assert.equal(body.configVersion, 1);
  assert.ok(!JSON.stringify(body).includes("Avoid recognizable template fingerprints"));
  const again = await handle(new Request("https://x/v1/config", { headers: { "if-none-match": etag } }), {});
  assert.equal(again.status, 304);
});
```
In `WorkerConfigE2ETests.swift`, add an expectation that the bundled `starter-editorial.json` constitution does not contain `"Avoid recognizable template fingerprints"`, and still equals the Worker's copy. Extend the existing sync check.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend/worker && npm run check` and `swift test --filter WorkerConfig`
Expected: FAIL. The ETag has no revision, and the line is present.

- [ ] **Step 3: Implement**

```js
function fnv1a(text) { let h = 0x811c9dc5; for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; } return h.toString(16).padStart(8, "0"); }
const CONFIG_REVISION = fnv1a(JSON.stringify(styleConfig));
// in the /v1/config branch:
const etag = `"starter-editorial-1.0.0-config-${styleConfig.configVersion}-${CONFIG_REVISION}"`;
```
Remove the constitution line in all three places.

- [ ] **Step 4: Run the tests**

Run: `cd backend/worker && npm run check`, then `swift test`.
Expected: PASS.

- [ ] **Step 5: Commit** (the Worker is deployed only on the owner's say-so)

```bash
git add backend/worker Sources/Render/Resources/StylePacks/starter-editorial.json Sources/Director/ArtDirector.swift Tests/CLITests/WorkerConfigE2ETests.swift
git commit -m "Drop the anti-template constitution line; config ETag tracks content"
```

---

### Task 9: Evaluation: engine pairs and "would post" ratings

**Files:**
- Modify: `Sources/Core/Taste/EvalSet.swift`: `EvalPair.Stage` gains `engine`; add `EvalRating`
- Modify: `Sources/CLI/EvalCommand.swift` and `Sources/CLI/Arguments.swift:79-82`, `:114`
- Test: `Tests/CLITests/EvalE2ETests.swift` (extend)

**Interfaces:**
- Produces:
  - `ak14 eval compare <runDir>… --out <evalDir> [--seed HEX]`
  - `ak14 eval rate <evalDir> --rater <name>`
  - `eval score` reports engine preference, ratings and white-card rate
  ```swift
  public struct EvalRating: Codable, Sendable, Equatable { public var runID: String; public var optionID: String; public var engine: String; public var rating: String /* yes|almost|no */ ; public var rater: String }
  ```

- [ ] **Step 1: Write the failing test**

```swift
@Test func compareBuildsFrozenEnginePairsAndScoresPreferenceAndRatings() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let run = try await evalRun(tmp, folder: try evalScene(tmp, name: "scene"))
    let out = tmp.url.appending(path: "eval")
    try EvalCommand.compare(runDirectories: [run.root], out: out)
    let set = try JSONDecoder().decode(EvalSet.self, from: Data(contentsOf: out.appending(path: "evalset.json")))
    let pairs = set.pairs.filter { $0.stage == .engine }
    #expect(!pairs.isEmpty)
    for pair in pairs {
        #expect(Set([pair.left.carouselID.hasPrefix("legacy-"), pair.right.carouselID.hasPrefix("legacy-")]) == [true, false])
        #expect(Set(pair.left.assetIDs) == Set(pair.right.assetIDs))           // frozen selection
    }
    let labels = pairs.map { ["pairID": $0.pairID, "winner": $0.left.carouselID.hasPrefix("legacy-") ? "right" : "left", "rater": "o"] }
    let ratings = pairs.map { ["runID": $0.runID, "optionID": $0.right.carouselID, "engine": "pages", "rating": "yes", "rater": "o"] }
    let file = tmp.url.appending(path: "labels.json")
    try JSONSerialization.data(withJSONObject: ["labels": labels, "ratings": ratings]).write(to: file)
    try EvalCommand.importLabels(evalDirectory: out, file: file)
    let report = try EvalCommand.score(evalDirectory: out, stage: .engine)
    #expect(report.contains("new engine preferred: 100%"))
    #expect(report.contains("rated yes: 100%"))
}
```
Match the `labels.json` shape to what `importLabels` already accepts. Read `EvalCommand.importLabels` (line 111) and extend its format with an optional `ratings` array rather than inventing a new file.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter EvalE2ETests`
Expected: a compile failure. There is no `compare` and no `.engine`.

- [ ] **Step 3: Implement**

`EvalCommand.compare`: for each run:
1. Load the stored directions (`plan.direction`) of the non-baseline plans.
2. Freeze the selection. For each option, take the new engine's photo set: compose it with `pages` (the template-first path), then compose the legacy plan with `pages: []` from a `Direction` whose `orderedAssetIDs` equals exactly that photo set in the new plan's order. `moments` stays empty, so the legacy path runs.
3. Render both with `CarouselRenderer`, and write strips with the existing `StripRenderer` code in `pairs`.
4. Add an `EvalPair(stage: .engine, left:right:)` with ids `legacy-<cN>` and `pages-<cN>`. Randomize left/right with the eval seed, as `pairs` does.

Record engine versions in the pair's `CandidateRef.note` if that field exists; otherwise add `engine: String?` to `CandidateRef`, decoded with `decodeIfPresent`.

`eval rate` writes `ratings.json` through the same interactive flow as `eval label`, asking yes/almost/no per `pages-*` option. `eval score --stage engine` prints:
- `new engine preferred: N%` over non-tied pairs
- `neither/tie: N`
- `rated yes: N%`, `almost: N%`, `no: N%`
- `white cards: N% of slides` and `median crop kept: 0.NN`, from the rendered layouts

- [ ] **Step 4: Run the tests**

Run: `swift test --filter EvalE2ETests`, then `swift test`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Taste/EvalSet.swift Sources/CLI Tests/CLITests/EvalE2ETests.swift
git commit -m "eval compare: frozen old-vs-new layout pairs and would-post ratings"
```

---

### Task 10: Real-run verification and device install

**Files:**
- Modify: `docs/superpowers/specs/2026-09-29-template-first-engine-design.md` (fill in Results)
- Modify: `tasks/todo.md` (new section with checked items and a review note)

- [ ] **Step 1: Re-run the 8 IMG events**

Run: `for r in runs/*; do swift run ak14 rerender "$r" --source IMG --recompose; done`. Use the run directories listed in `tasks/todo.md` under "Designed look v1". If they're missing, run `swift run ak14 run IMG --all-events`.
Expected: no errors. Record the warnings count and the white-card rate per run.

- [ ] **Step 2: Contact sheets and self-review**

Render contact sheets of every option (the existing `StripRenderer` via `ak14 eval compare`), and look at every slide. Check:
- a title on each cover
- no cut faces
- no sample text
- one family per option
- wide group photos in wide slots

Fix any failure in the owning task's code before continuing.

- [ ] **Step 3: Owner evaluation**

Run: `swift run ak14 eval compare runs/<8 runs> --out /tmp/ak14-eval-engine`, then have the owner do `ak14 eval rate` and `ak14 eval label`, then `ak14 eval score /tmp/ak14-eval-engine --stage engine`.
Expected, the acceptance from spec §5:
- the new engine preferred in at least 70% of non-tied pairs
- no template-first option rated "no", and at least 75% rated "yes"
- white cards at most 10%
- first planner response valid in at least 95% of runs

- [ ] **Step 4: Device latency and install**

Build and install as in the last session:
```bash
xcodebuild -project iOS/AK14iOS.xcodeproj -scheme AK14iOS -configuration Release -destination 'id=00008150-000A69410E33401C' -derivedDataPath /tmp/ak14-device-dd -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008150-000A69410E33401C /tmp/ak14-device-dd/Build/Products/Release-iphoneos/AK14.app
```
The pipeline already logs stage timings in the progress callback. Read the composition stage's time from the device console for 8 generations, and record the p95. It must be at most 1.5 s.

- [ ] **Step 5: Record and commit**

Fill in the spec's Results section: page counts, latency p95, preference, ratings, white-card rate and first-response validity. Add a `tasks/todo.md` section with the checked items and a short review.
```bash
git add docs/superpowers/specs/2026-09-29-template-first-engine-design.md tasks/todo.md
git commit -m "Template-first engine: results on real runs and device"
```

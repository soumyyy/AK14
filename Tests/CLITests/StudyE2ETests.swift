import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director
@testable import Analysis
@testable import Session

private func folder(_ tmp: TempDirectory, _ name: String, scenes: Range<Int> = 0..<12) throws -> URL {
    let f = try tmp.sub(name)
    for i in scenes {
        var exif = FixtureFactory.Exif(); exif.date = String(format: "2026:05:29 %02d:10:00", 8 + i % 12)
        try FixtureFactory.writeScene(to: f.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    return f
}

private func run(_ tmp: TempDirectory, _ source: URL, code: String?, consent: Bool = true, model: FakeModel = FakeModel()) async throws -> RunStore {
    var o = RunOptions(folder: source, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: consent)
    o.studyCode = code
    return try await RunPipeline.live(options: o, client: ResponsesClient(transport: model, sleep: { _ in }), log: { _ in }).run(o)
}

@Test func withoutConsentNothingIsSentAndStudyCodeIsRecorded() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel()
    let store = try await run(tmp, try folder(tmp, "a"), code: "P01", consent: false, model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(model.stages.isEmpty && m.directorStatus == "skipped: no consent" && m.consent == nil)
    #expect(m.studyCode == "P01")
    #expect(throws: ArgumentError.invalidStudyCode("Jane Doe")) { try Arguments.parse(["run", "x", "--study-code", "Jane Doe"], cwd: tmp.url) }
    let consented = try await run(tmp, try folder(tmp, "b"), code: "P02")
    #expect(try consented.read(RunManifest.self, from: "manifest.json").consent?.disclosureVersion == Disclosure.version)
}

@Test func cohortSummaryAppliesThePreRegisteredBar() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let source = try folder(tmp, "trip")

    // P1: picks Designed, exports, posts on day 3, comes back with another event (second run).
    let r1 = try await run(tmp, source, code: "P1")
    let s1 = try RunSession(runDirectory: r1.root); try s1.setSource(source)
    try s1.select("c1"); try s1.export("c1", to: tmp.url.appending(path: "out1"))
    try Followup.record(runDirectory: r1.root, posted: true, postedDaysAfterHandoff: 3, platform: "instagram",
                        reusedAnotherEvent: nil, linkSeen: true)
    _ = try await run(tmp, source, code: "P1")

    // P2: picks Wildcard but replaces most photos before exporting → substantially rebuilt.
    let r2 = try await run(tmp, source, code: "P2")
    let s2 = try RunSession(runDirectory: r2.root); try s2.setSource(source)
    for _ in 0..<2 {
        let plan = try #require(s2.plan("c2"))
        let slide = try #require(plan.slides.firstIndex { $0.photos.count > 1 } ?? plan.slides.indices.last)
        let old = plan.slides[slide].photos[0].assetID
        if let new = s2.swapCandidates("c2", photo: old).first { try s2.apply(.swap(slide: slide, photo: old, with: new), to: "c2") }
    }
    try s2.reroll("c2")
    try s2.select("c2"); try s2.export("c2", to: tmp.url.appending(path: "out2"))
    try Followup.record(runDirectory: r2.root, posted: false, postedDaysAfterHandoff: nil, platform: nil, reusedAnotherEvent: false, linkSeen: nil)

    // P3: picks Plain, never exports.
    let r3 = try await run(tmp, source, code: "P3")
    try RunSession(runDirectory: r3.root).select("baseline")

    // An interrupted run (no completedAt) and an uncoded run are not counted.
    let broken = try await run(tmp, source, code: "P4")
    var m = try broken.read(RunManifest.self, from: "manifest.json"); m.completedAt = nil
    try broken.write(m, to: "manifest.json")
    _ = try await run(tmp, source, code: nil)

    let summary = StudySummary.compute(runsDirectory: tmp.url.appending(path: "runs"))
    #expect(summary.participants.map(\.studyCode) == ["P1", "P2", "P3"])
    #expect(summary.incompleteRunsSkipped == 1 && summary.runsWithoutStudyCode == 1)
    let p = Dictionary(uniqueKeysWithValues: summary.participants.map { ($0.studyCode, $0) })
    #expect(p["P1"]?.success["30%"] == true && p["P1"]?.postedWithin7Days == true && p["P1"]?.repeatDemand == true)
    #expect(p["P2"]?.rerolledBeforeHandoff == true && p["P2"]?.success["30%"] == false && p["P2"]?.exportedOrShared == true)
    #expect(p["P3"]?.selectedConcept == "baseline" && p["P3"]?.exportedOrShared == false)
    #expect(abs((summary.minimumSignal["30%"] ?? 0) - 1.0 / 3.0) < 1e-9 && !summary.minimumSignalMet)
    #expect(abs(summary.postedShare - 1.0 / 3.0) < 1e-9 && summary.strongSignalMet)
    // Each picked direction contributes one value per style axis (the composer may nudge an axis for diversity).
    let groupingPicks = summary.pickedStyles.filter { $0.key.hasPrefix("grouping=") }.values.reduce(0, +)
    #expect(summary.baselinePicked == 1 && summary.directionPicked == 2 && groupingPicks == 2, "\(summary.pickedStyles)")
    let md = summary.markdown()
    #expect(md.contains("| P1 |") && md.contains("≥ 50%") && !md.contains(tmp.url.path))
}

@Test func deletionRemovesTheRunAndOnlyUnsharedCache() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let shared = try folder(tmp, "a", scenes: 0..<8)
    let other = try tmp.sub("b")
    for i in 0..<6 { try FileManager.default.copyItem(at: shared.appending(path: String(format: "IMG_%04d.jpg", i)),
                                                    to: other.appending(path: String(format: "IMG_%04d.jpg", i))) }
    for i in 50..<53 { try FixtureFactory.writeScene(to: other.appending(path: "u\(i).jpg"), scene: i) }
    _ = try await run(tmp, shared, code: "A", consent: false)
    let b = try await run(tmp, other, code: "B", consent: false)
    let bIndex = try b.read(IngestResult.self, from: "input-index.json")
    let aShas = Set(try await FolderIngester().ingest(folder: shared, options: IngestOptions()).photos.map(\.contentSHA256))
    let unique = bIndex.photos.map(\.contentSHA256).filter { !aShas.contains($0) }
    #expect(unique.count == 3)

    let cache = tmp.url.appending(path: "cache")
    let removed = try RunDeletion.delete(runDirectory: b.root, cacheDirectory: cache)
    #expect(!FileManager.default.fileExists(atPath: b.root.path))
    let remaining = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)!.compactMap { ($0 as? URL)?.deletingPathExtension().lastPathComponent }
    #expect(removed > 0 && unique.allSatisfy { !remaining.contains($0) })
    #expect(aShas.allSatisfy { remaining.contains($0) })
}

// MARK: - M6 review fixes

@Test func ineligibleRunsNeverBecomeTheStudyRunOrRepeatDemand() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let source = try folder(tmp, "trip")
    _ = try await run(tmp, source, code: "P9", consent: false)             // operator answered N first
    let real = try await run(tmp, source, code: "P9")
    let s = try RunSession(runDirectory: real.root); try s.setSource(source)
    try s.select("c1")
    try s.export("c1", to: tmp.url.appending(path: "o"))
    // Playing with a reroll *after* hand-off must not count against what was handed off.
    try s.reroll("c1")
    try Followup.record(runDirectory: real.root, posted: true, postedDaysAfterHandoff: 2, platform: "instagram", reusedAnotherEvent: nil, linkSeen: nil)
    let summary = StudySummary.compute(runsDirectory: tmp.url.appending(path: "runs"))
    #expect(summary.ineligibleRunsSkipped == 1)
    let p = try #require(summary.participants.first)
    #expect(p.runs == 1 && !p.repeatDemand && p.runID == real.root.lastPathComponent)
    #expect(!p.rerolledBeforeHandoff && p.success["30%"] == true && p.postedWithin7Days, "\(p)")
}

@Test func postingWithoutAHandoffOrAfterDay7DoesNotCount() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let source = try folder(tmp, "trip")
    let a = try await run(tmp, source, code: "A1")
    try RunSession(runDirectory: a.root).select("baseline")              // never exported
    try Followup.record(runDirectory: a.root, posted: true, postedDaysAfterHandoff: 1, platform: nil, reusedAnotherEvent: nil, linkSeen: nil)
    let b = try await run(tmp, source, code: "B1")
    let sb = try RunSession(runDirectory: b.root); try sb.setSource(source)
    try sb.select("baseline"); try sb.export("baseline", to: tmp.url.appending(path: "o"))
    try Followup.record(runDirectory: b.root, posted: true, postedDaysAfterHandoff: 9, platform: nil, reusedAnotherEvent: nil, linkSeen: nil)
    let summary = StudySummary.compute(runsDirectory: tmp.url.appending(path: "runs"))
    #expect(summary.participants.allSatisfy { !$0.postedWithin7Days })
    #expect(summary.postedShare == 0 && !summary.strongSignalMet)
}

@Test func modelNeverSeesTheFolderNameOrCalendarDates() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let source = try folder(tmp, "Sarah30th")
    let store = try await run(tmp, source, code: "P5")
    for file in try FileManager.default.contentsOfDirectory(atPath: store.url("llm").path) {
        let text = try String(contentsOf: store.url("llm/\(file)"), encoding: .utf8)
        for token in ["Sarah30th", "May 2026", "2026:05", "Jun 2026", "2026-05"] {
            #expect(!text.contains(token), "\(file) leaks \(token)")
        }
    }
}

@Test func deleteRefusesNonRunsAndDeletesEveryRunForACode() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let source = try folder(tmp, "trip", scenes: 0..<12)
    let runs = tmp.url.appending(path: "runs")
    let first = try await run(tmp, source, code: "P7", consent: false)
    let second = try await run(tmp, source, code: "P7")
    var m = try second.read(RunManifest.self, from: "manifest.json"); m.completedAt = nil      // an interrupted run
    try second.write(m, to: "manifest.json")
    let other = try await run(tmp, try folder(tmp, "other", scenes: 20..<24), code: "P8", consent: false)

    #expect(throws: (any Error).self) { try RunDeletion.delete(runDirectory: runs, cacheDirectory: nil) }       // the runs root
    #expect(throws: (any Error).self) { try RunDeletion.delete(runDirectory: source, cacheDirectory: nil) }     // not a run
    #expect(FileManager.default.fileExists(atPath: first.root.path))

    let (count, removed) = try RunDeletion.delete(studyCode: "P7", runsDirectory: runs, cacheDirectory: tmp.url.appending(path: "cache"))
    #expect(count == 2 && removed > 0)
    #expect(!FileManager.default.fileExists(atPath: first.root.path) && !FileManager.default.fileExists(atPath: second.root.path))
    #expect(FileManager.default.fileExists(atPath: other.root.path))
    #expect(throws: ArgumentError.missingValue("--posted-days (days after hand-off they posted)")) {
        try Arguments.parse(["followup", "runs/x", "--posted", "yes"], cwd: tmp.url)
    }
}

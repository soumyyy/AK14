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
    try s1.select(.designed); try s1.export(.designed, to: tmp.url.appending(path: "out1"))
    try Followup.record(runDirectory: r1.root, posted: true, platform: "instagram", reusedAnotherEvent: nil, linkSeen: true,
                        now: Date().addingTimeInterval(3 * 86_400))
    _ = try await run(tmp, source, code: "P1")

    // P2: picks Wildcard but replaces most photos before exporting → substantially rebuilt.
    let r2 = try await run(tmp, source, code: "P2")
    let s2 = try RunSession(runDirectory: r2.root); try s2.setSource(source)
    for _ in 0..<2 {
        let plan = try #require(s2.plan(.wildcard))
        let slide = try #require(plan.slides.firstIndex { $0.photos.count > 1 } ?? plan.slides.indices.last)
        let old = plan.slides[slide].photos[0].assetID
        if let new = s2.swapCandidates(.wildcard, photo: old).first { try s2.apply(.swap(slide: slide, photo: old, with: new), to: .wildcard) }
    }
    try s2.reroll(.wildcard)
    try s2.select(.wildcard); try s2.export(.wildcard, to: tmp.url.appending(path: "out2"))
    try Followup.record(runDirectory: r2.root, posted: false, platform: nil, reusedAnotherEvent: false, linkSeen: nil)

    // P3: picks Plain, never exports.
    let r3 = try await run(tmp, source, code: "P3")
    try RunSession(runDirectory: r3.root).select(.plainDump)

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
    #expect(p["P2"]?.rerolled == true && p["P2"]?.success["30%"] == false && p["P2"]?.exportedOrShared == true)
    #expect(p["P3"]?.selectedConcept == "plainDump" && p["P3"]?.exportedOrShared == false)
    #expect(abs((summary.minimumSignal["30%"] ?? 0) - 1.0 / 3.0) < 1e-9 && !summary.minimumSignalMet)
    #expect(abs(summary.postedShare - 1.0 / 3.0) < 1e-9 && summary.strongSignalMet)
    #expect(summary.picks == ["designed": 1, "wildcard": 1, "plainDump": 1])
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

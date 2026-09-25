import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core

@Test func reductionClustersBurstsAndRejectsBlackFrames() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("event")
    for (i, second) in ["03", "04", "05"].enumerated() {               // burst: same frame, 1 s apart
        var exif = FixtureFactory.Exif(); exif.date = "2026:05:29 17:30:\(second)"
        try FixtureFactory.writeScene(to: folder.appending(path: "burst\(i).jpg"), scene: 100, exif: exif)
    }
    for i in 0..<4 {
        var exif = FixtureFactory.Exif(); exif.date = String(format: "2026:05:29 %02d:00:00", 9 + i)
        try FixtureFactory.writeScene(to: folder.appending(path: "scene\(i).jpg"), scene: i, exif: exif)
    }
    try FixtureFactory.writeJPEG(to: folder.appending(path: "black.jpg"), gray: 0)
    let o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                       cacheDirectory: tmp.url.appending(path: "cache"), noLLM: true)
    let store = try await RunPipeline.live(options: o, log: { _ in }).run(o)
    let r = try store.read(ReductionResult.self, from: "cache/reduction.json")
    let index = try store.read(IngestResult.self, from: "input-index.json")
    let name = Dictionary(uniqueKeysWithValues: index.photos.map { ($0.assetID, $0.sourceRelativePaths[0]) })

    let burst = try #require(r.clusters.first { $0.memberAssetIDs.count == 3 })
    #expect(Set(burst.memberAssetIDs.map { name[$0]! }) == ["burst0.jpg", "burst1.jpg", "burst2.jpg"])
    #expect(burst.kind == .nearDuplicate)
    let black = try #require(r.junk.first { name[$0.assetID] == "black.jpg" })
    #expect(black.verdict == .reject && black.reasons.contains("blackFrame"))
    #expect(r.funnel.junkRejected == 1 && r.funnel.representatives == 5)
    #expect(r.shortlist.count == 5 && !r.shortlist.contains { $0.assetID == black.assetID })
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.directorStatus == "skipped: --no-llm")
    #expect(!FileManager.default.fileExists(atPath: store.url("llm").path))
    let html = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    #expect(html.contains("blackFrame") && html.contains("Funnel") && html.contains("nearDuplicate"))
}

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

@Test func reductionSplitsPeopleFramingChangesAndChoosesTheBetterFaceCapture() throws {
    let ids = (0..<3).map { AssetID(rawValue: "a_burst\($0)") }
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let photos = ids.enumerated().map { i, id in
        PhotoRecord(assetID: id, contentSHA256: "fixture-\(i)", sourceRelativePaths: ["burst\(i).jpg"],
                    byteCount: 100, fileType: "public.jpeg", pixelWidth: 400, pixelHeight: 300,
                    exifOrientation: 1, metadata: CaptureMetadata(capturedAt: base.addingTimeInterval(Double(i))))
    }
    var first = PhotoFeatures(assetID: ids[0], analyzerVersion: "fixture")
    first.sharpness = 0.12; first.aestheticScore = 0
    first.faces = [FaceRegion(box: UnitRect(x: 0.20, y: 0.20, width: 0.25, height: 0.30), captureQuality: 0.2)]
    var second = PhotoFeatures(assetID: ids[1], analyzerVersion: "fixture")
    second.sharpness = 0.105; second.aestheticScore = 0
    second.faces = [FaceRegion(box: UnitRect(x: 0.21, y: 0.20, width: 0.25, height: 0.30), captureQuality: 0.95)]
    var changedFraming = PhotoFeatures(assetID: ids[2], analyzerVersion: "fixture")
    changedFraming.sharpness = 0.12; changedFraming.aestheticScore = 0
    changedFraming.faces = [FaceRegion(box: UnitRect(x: 0.67, y: 0.61, width: 0.22, height: 0.28), captureQuality: 0.8)]
    let features = [ids[0]: first, ids[1]: second, ids[2]: changedFraming]
    let distances: [Set<AssetID>: Double] = [
        Set([ids[0], ids[1]]): 0.05,
        Set([ids[0], ids[2]]): 0.18,
        Set([ids[1], ids[2]]): 0.18,
    ]
    let result = ReductionResult.reduce(photos: photos, features: features,
                                        distance: { a, b in distances[Set([a, b])] })
    #expect(result.clusters.count == 2)
    let burst = try #require(result.clusters.first { $0.memberAssetIDs.count == 2 })
    #expect(burst.representativeAssetID == ids[1])
    #expect(result.clusters.first { $0.memberAssetIDs == [ids[2]] }?.kind == .single)
}

@Test func triageCanPromoteCharacterfulPeopleFramesAndKeepLowScoresSoft() throws {
    let plainID = AssetID(rawValue: "plain")
    let candidID = AssetID(rawValue: "hillside-candid")
    let plain = RankedCandidate(assetID: plainID, clusterID: "plain", clusterSize: 1,
                                components: RankComponents(penalty: 0, base: 0.72), score: 0.72)
    let candid = RankedCandidate(assetID: candidID, clusterID: "candid", clusterSize: 1,
                                 components: RankComponents(penalty: 0, base: 0.60), score: 0.60)
    let scores: [AssetID: TriageScore] = [
        plainID: TriageScore(emotionalValue: 2, imperfection: "neutral", safety: [], tags: [], confidence: "high"),
        candidID: TriageScore(emotionalValue: 5, imperfection: "useful", safety: [], tags: ["candid", "people"], confidence: "high"),
    ]
    let config = ReductionConfig()
    let adjusted = CandidateRanker.applyTriage([plain, candid], triage: scores, config: config)
    #expect(config.triageMaxAdjustment == 0.4)
    #expect(adjusted.first?.assetID == candidID)
    #expect(adjusted.first?.effectiveScore ?? 0 >= 0.60 * 1.4)
    #expect(!CandidateRanker.isWeakTriageCandidate(adjusted.first!))

    let lowID = AssetID(rawValue: "low")
    let lowScore = TriageScore(emotionalValue: 1, imperfection: "neutral", safety: [], tags: [], confidence: "high")
    let low = CandidateRanker.applyTriage([RankedCandidate(assetID: lowID, clusterID: "low", clusterSize: 1,
                                          components: RankComponents(penalty: 0, base: 0.8), score: 0.8)],
                                          triage: [lowID: lowScore], config: config)[0]
    #expect(CandidateRanker.isWeakTriageCandidate(low))
}

@Test func triageCanReselectAUsableAlternateWithinABurst() throws {
    let ids = [AssetID(rawValue: "burst-a"), AssetID(rawValue: "burst-b"),
               AssetID(rawValue: "burst-black"), AssetID(rawValue: "solo")]
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let photos = ids.enumerated().map { index, id in
        PhotoRecord(assetID: id, contentSHA256: "fixture-\(index)", sourceRelativePaths: ["\(id).jpg"],
                    byteCount: 100, fileType: "public.jpeg", pixelWidth: 400, pixelHeight: 300,
                    exifOrientation: 1, metadata: CaptureMetadata(capturedAt: base.addingTimeInterval(Double(index))))
    }
    var polished = PhotoFeatures(assetID: ids[0], analyzerVersion: "fixture")
    polished.sharpness = 0.14; polished.aestheticScore = 0.8
    polished.faces = [FaceRegion(box: UnitRect(x: 0.2, y: 0.2, width: 0.25, height: 0.3), captureQuality: 0.9)]
    var candid = PhotoFeatures(assetID: ids[1], analyzerVersion: "fixture")
    candid.sharpness = 0.10; candid.aestheticScore = 0.1
    candid.faces = [FaceRegion(box: UnitRect(x: 0.2, y: 0.2, width: 0.25, height: 0.3), captureQuality: 0.3)]
    var black = PhotoFeatures(assetID: ids[2], analyzerVersion: "fixture")
    black.darkFraction = 1; black.meanLuminance = 0; black.sharpness = 0
    var solo = PhotoFeatures(assetID: ids[3], analyzerVersion: "fixture")
    solo.sharpness = 0.12; solo.aestheticScore = 0.2
    let features = [ids[0]: polished, ids[1]: candid, ids[2]: black, ids[3]: solo]
    let distances: [Set<AssetID>: Double] = [Set([ids[0], ids[1]]): 0.05, Set([ids[0], ids[2]]): 0.07]
    let distance: (AssetID, AssetID) -> Double? = { lhs, rhs in distances[Set([lhs, rhs])] }
    let reduction = ReductionResult.reduce(photos: photos, features: features, distance: distance)
    let candidates = reduction.triageCandidates(photos: photos, features: features)
    #expect(reduction.junk.first { $0.assetID == ids[2] }?.verdict == .reject)
    #expect(!candidates.contains { $0.assetID == ids[2] })
    let burstCluster = try #require(reduction.clusters.first { $0.memberAssetIDs.contains(ids[0]) })
    let burstCandidates = candidates.filter { $0.clusterID == burstCluster.clusterID }
    #expect(burstCandidates.count == 2)
    #expect(Set(burstCandidates.map(\.assetID)) == Set([ids[0], ids[1]]))

    let triage: [AssetID: TriageScore] = [
        ids[0]: TriageScore(emotionalValue: 2, imperfection: "neutral", safety: [], tags: [], confidence: "high"),
        ids[1]: TriageScore(emotionalValue: 5, imperfection: "useful", safety: [], tags: ["candid"], confidence: "high"),
    ]
    let photoByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
    let pool = DiversitySelector.selectPlanningPool(ranked: candidates, triage: triage, target: 2,
                                                    photos: photoByID, features: features, distance: distance,
                                                    config: reduction.config)
    #expect(pool.filter { $0.clusterID == burstCluster.clusterID }.map(\.assetID) == [ids[1]])
    #expect(pool.count == 2)

    let partialTriage = Dictionary(uniqueKeysWithValues: [(ids[0], triage[ids[0]]!)])
    let safeFallback = DiversitySelector.selectPlanningPool(ranked: candidates, triage: partialTriage, target: 2,
                                                            photos: photoByID, features: features, distance: distance,
                                                            config: reduction.config)
    #expect(safeFallback.filter { $0.clusterID == burstCluster.clusterID }.map(\.assetID) == [ids[0]])
}

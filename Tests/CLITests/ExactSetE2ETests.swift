import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director
@testable import Session

private func exactFolder(_ tmp: TempDirectory, count: Int = 9) throws -> URL {
    let folder = try tmp.sub("exact")
    for i in 0..<count {
        var exif = FixtureFactory.Exif()
        exif.date = String(format: "2026:05:29 %02d:10:00", 8 + i)
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    return folder
}

private func exactRun(_ tmp: TempDirectory, model: FakeModel, slides: Int? = nil, keepOrder: Bool = false) async throws -> RunStore {
    let folder = try exactFolder(tmp)
    var options = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                             cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
    options.exact = true; options.keepOrder = keepOrder; options.slides = slides
    return try await RunPipeline.live(options: options, client: ResponsesClient(transport: model, sleep: { _ in }), log: { _ in }).run(options)
}

@Test func exactSetUsesAllPhotosInBaselineAndEveryDirection() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await exactRun(tmp, model: FakeModel())
    let manifest = try store.read(RunManifest.self, from: "manifest.json")
    let report = try store.read(ConceptsReport.self, from: "plans/director.json")
    let expected = Set(try store.read(IngestResult.self, from: "input-index.json").photos.map(\.assetID))
    #expect(manifest.exactSet && manifest.chosenEvent == nil && manifest.events.isEmpty)
    #expect(report.pool.count == 9)
    for plan in report.plans {
        #expect(plan.photoAssetIDs.count == 9 && Set(plan.photoAssetIDs) == expected, "\(plan.id)")
    }
}

@Test func exactSetGroupsToHonorRequestedSlideLimit() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await exactRun(tmp, model: FakeModel(), slides: 5)
    let report = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(report.plans.allSatisfy { $0.slides.count <= 5 && $0.photoAssetIDs.count == 9 }, "\(report.warnings)")
    #expect(report.warnings.contains { $0.contains("grouped exact photos") })
}

@Test func exactSetRaisesGroupCapacityWhenNeededToHonorTightSlideLimit() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await exactRun(tmp, model: FakeModel(), slides: 2)
    let report = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(report.plans.allSatisfy { $0.slides.count <= 2 && $0.photoAssetIDs.count == 9 }, "\(report.warnings)")
    #expect(report.plans.contains { $0.slides.contains { $0.photos.count > 4 } })
}

@Test func exactKeepOrderUsesSourceFileNameOrderForEveryOption() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await exactRun(tmp, model: FakeModel(), keepOrder: true)
    let index = try store.read(IngestResult.self, from: "input-index.json")
    let expected = index.photos.sorted { $0.sourceRelativePaths[0] < $1.sourceRelativePaths[0] }.map(\.assetID)
    let report = try store.read(ConceptsReport.self, from: "plans/director.json")
    for plan in report.plans { #expect(plan.photoAssetIDs == expected, "\(plan.id)") }
}

@Test func omittedExactPhotoIsRepairedOrFallsBackToCompleteSpine() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.omitExact]])
    let store = try await exactRun(tmp, model: model)
    let report = try store.read(ConceptsReport.self, from: "plans/director.json")
    let ids = try store.read(IngestResult.self, from: "input-index.json").photos.map(\.assetID)
    #expect(model.stages.contains("repair") || model.stages.contains("retry"))
    #expect(report.spine?.orderedAssetIDs.count == ids.count && Set(report.spine?.orderedAssetIDs ?? []) == Set(ids))
}

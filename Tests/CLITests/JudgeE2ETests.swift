import Foundation
import Testing
import TestSupport
@testable import CLI
import Director
@testable import Core

private func judgeRun(_ tmp: TempDirectory, _ model: FakeModel) async throws -> RunStore {
    try await directorRun(tmp, folder: try directorSceneFolder(tmp), model: model, judge: true)
}

@Test func judgeRanksAvailableCandidatesAndSkipsDirectionsWithOnlyOne() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel()
    let store = try await judgeRun(tmp, model)
    let plans = try store.read(ConceptsReport.self, from: "plans/director.json").plans
    let results = try store.read([JudgeResult].self, from: "plans/judge.json")
    let manifest = try store.read(RunManifest.self, from: "manifest.json")
    #expect(results.count == 3)
    let ranked = results.filter { $0.skipped == nil }
    let skipped = results.filter { $0.skipped != nil }
    #expect(ranked.count == 2 && skipped.count == 1)
    #expect(model.stages.filter { $0 == "judge" }.count == ranked.count * 2)
    #expect(manifest.providerCalls.filter { $0.stage == "judge" }.count == ranked.count * 2)
    #expect(manifest.versions["judge"] != nil)
    for result in results {
        let plan = try #require(plans.first { $0.id == result.directionID })
        if result.skipped == nil {
            #expect(result.winnerIndex != nil)
            #expect(result.candidateFingerprints.count >= 2)
            #expect(result.stripSHA256.count == result.candidateFingerprints.count)
            #expect(Set(result.stripSHA256).count > 1)
        } else {
            #expect(result.skipped == "fewer than two safe candidates")
            #expect(result.winnerIndex == nil)
            #expect(result.candidateFingerprints.count <= 1)
            #expect(result.stripSHA256.isEmpty)
        }
    }
    let before = try Data(contentsOf: store.url("slides/c1/slide-01.png"))
    try RerenderCommand.rerender(runDirectory: store.root, source: tmp.url.appending(path: "trip"))
    #expect(try Data(contentsOf: store.url("slides/c1/slide-01.png")) == before)
    #expect(model.stages.filter { $0 == "judge" }.count == ranked.count * 2)
}

@Test func invalidJudgeResponseKeepsTheComposerPlan() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await judgeRun(tmp, FakeModel(["judge": [.garbage]]))
    let manifest = try store.read(RunManifest.self, from: "manifest.json")
    let results = try store.read([JudgeResult].self, from: "plans/judge.json")
    #expect(manifest.directorStatus == "ok")
    #expect(results.contains { $0.skipped != nil })
    #expect(try store.read(ConceptsReport.self, from: "plans/director.json").plans.count == 4)
}

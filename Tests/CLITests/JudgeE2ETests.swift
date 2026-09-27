import Foundation
import Testing
import TestSupport
@testable import CLI
import Director
@testable import Core

private func judgeRun(_ tmp: TempDirectory, _ model: FakeModel) async throws -> RunStore {
    try await directorRun(tmp, folder: try directorSceneFolder(tmp), model: model, judge: true)
}

@Test func judgeRanksCandidatesAndRerenderUsesStoredWinner() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel()
    let store = try await judgeRun(tmp, model)
    let plans = try store.read(ConceptsReport.self, from: "plans/director.json").plans
    let results = try store.read([JudgeResult].self, from: "plans/judge.json")
    let manifest = try store.read(RunManifest.self, from: "manifest.json")
    #expect(results.count == 3 && results.allSatisfy { $0.skipped == nil && !$0.ranking.isEmpty })
    #expect(model.stages.filter { $0 == "judge" }.count == 6)
    #expect(manifest.providerCalls.filter { $0.stage == "judge" }.count == 6)
    #expect(manifest.versions["judge"] != nil)
    for result in results {
        let plan = try #require(plans.first { $0.id == result.directionID })
        #expect(result.winnerIndex != nil)
        #expect(result.candidateFingerprints.count >= 2)
        #expect(result.stripSHA256.count >= 2)
        #expect(Set(result.stripSHA256).count > 1)
    }
    let before = try Data(contentsOf: store.url("slides/c1/slide-01.png"))
    try RerenderCommand.rerender(runDirectory: store.root, source: tmp.url.appending(path: "trip"))
    #expect(try Data(contentsOf: store.url("slides/c1/slide-01.png")) == before)
    #expect(model.stages.filter { $0 == "judge" }.count == 6)
}

@Test func invalidJudgeResponseFallsBackAndRecordsSkip() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await judgeRun(tmp, FakeModel(["judge": [.garbage]]))
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.directorStatus == "ok")
    let results = try store.read([JudgeResult].self, from: "plans/judge.json")
    #expect(results.first?.skipped != nil)
}

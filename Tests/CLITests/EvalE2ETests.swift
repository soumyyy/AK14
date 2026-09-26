import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director

private func evalScene(_ tmp: TempDirectory, name: String) throws -> URL {
    let folder = try tmp.sub(name)
    for i in 0..<12 {
        var exif = FixtureFactory.Exif()
        exif.date = String(format: "2026:05:29 %02d:10:00", 8 + i)
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    return folder
}

private func evalRun(_ tmp: TempDirectory, folder: URL) async throws -> RunStore {
    let options = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                             cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
    return try await RunPipeline.live(options: options, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in }).run(options)
}

@Test func evalPairsLabelsImportAndScoreEndToEnd() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let first = try await evalRun(tmp, folder: evalScene(tmp, name: "event-one"))
    let second = try await evalRun(tmp, folder: evalScene(tmp, name: "event-two"))
    let out = tmp.url.appending(path: "eval")

    if case .evalPairs(let dirs, let dir, let seed) = try Arguments.parse(["eval", "pairs", first.root.path, second.root.path, "--out", out.path, "--seed", "cafe"], cwd: tmp.url) {
        try EvalCommand.pairs(runDirectories: dirs, out: dir, seed: seed)
    } else { Issue.record("eval pairs arguments did not parse") }
    let set = try JSONCoding.decoder.decode(EvalSet.self, from: Data(contentsOf: out.appending(path: "evalset.json")))
    let plans1 = try first.read(ConceptsReport.self, from: "plans/director.json").plans.count
    let plans2 = try second.read(ConceptsReport.self, from: "plans/director.json").plans.count
    #expect(set.pairs.count == plans1 * (plans1 - 1) / 2 + plans2 * (plans2 - 1) / 2)
    #expect(set.pairs.allSatisfy { $0.left.runID == $0.runID && $0.right.runID == $0.runID })
    #expect(Set(set.pairs.map { "\($0.left.carouselID)/\($0.right.carouselID)" }).count > 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.appending(path: "strips").path).count == plans1 + plans2)

    let original = try Data(contentsOf: out.appending(path: "evalset.json"))
    try EvalCommand.pairs(runDirectories: [first.root, second.root], out: out, seed: 0xcafe)
    #expect(try Data(contentsOf: out.appending(path: "evalset.json")) == original)
    try EvalCommand.label(evalDirectory: out, rater: "owner")
    #expect(FileManager.default.fileExists(atPath: out.appending(path: "index.html").path))

    let labels = set.pairs.map { pair in
        EvalLabel(pairID: pair.pairID, rater: "owner", choice: .left, shownLeft: pair.left,
                  decidedAt: Date(timeIntervalSince1970: 1), versions: set.versions)
    }
    let labelsFile = tmp.url.appending(path: "labels-owner.json")
    try JSONCoding.encoder.encode(labels).write(to: labelsFile)
    if case .evalImport(let dir, let file) = try Arguments.parse(["eval", "import", out.path, labelsFile.path], cwd: tmp.url) {
        try EvalCommand.importLabels(evalDirectory: dir, file: file)
    } else { Issue.record("eval import arguments did not parse") }
    let imported = try JSONCoding.decoder.decode([EvalLabel].self, from: Data(contentsOf: out.appending(path: "labels/labels-owner.json")))
    #expect(imported == labels)
    let summary = try EvalCommand.score(evalDirectory: out)
    #expect(summary.contains("95% CI"))
    let report = try JSONCoding.decoder.decode(EvalReport.self, from: Data(contentsOf: out.appending(path: "eval/report.json")))
    #expect((0...1).contains(report.agreement))
    #expect(report.confidenceInterval.count == 2 && report.confidenceInterval[0] <= report.confidenceInterval[1])
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.appending(path: "eval").path).contains { $0.hasPrefix("report-") && $0.hasSuffix(".md") })
}

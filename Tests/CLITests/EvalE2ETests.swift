import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director
@testable import Render

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

@Test func groupedSplitStripMarksBoundariesForSamePhotos() throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    var firstExif = FixtureFactory.Exif(); firstExif.date = "2026:05:29 08:10:00"
    var secondExif = FixtureFactory.Exif(); secondExif.date = "2026:05:29 09:10:00"
    let first = tmp.url.appending(path: "one.jpg"), second = tmp.url.appending(path: "two.jpg")
    try FixtureFactory.writeScene(to: first, scene: 0, exif: firstExif)
    try FixtureFactory.writeScene(to: second, scene: 1, exif: secondExif)
    let renderer = StripRenderer()
    let merged = try renderer.strip(slides: [first, second])
    let split = try renderer.strip(groups: [[first], [second]])
    #expect(split != merged)
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
    #expect(set.pairs.filter { $0.stage == .layout }.count == plans1 * (plans1 - 1) / 2 + plans2 * (plans2 - 1) / 2)
    #expect(Set(set.pairs.map(\.stage)).contains(.cover))
    #expect(set.pairs.allSatisfy { $0.left.runID == $0.runID && $0.right.runID == $0.runID })
    #expect(Set(set.pairs.map { "\($0.left.carouselID)/\($0.right.carouselID)" }).count > 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.appending(path: "strips").path).count >= plans1 + plans2)

    let original = try Data(contentsOf: out.appending(path: "evalset.json"))
    try EvalCommand.pairs(runDirectories: [first.root, second.root], out: out, seed: 0xcafe)
    #expect(try Data(contentsOf: out.appending(path: "evalset.json")) == original)
    try EvalCommand.label(evalDirectory: out, rater: "owner")
    #expect(FileManager.default.fileExists(atPath: out.appending(path: "index.html").path))

    let labels = set.pairs.enumerated().map { index, pair in
        EvalLabel(pairID: pair.pairID, rater: "owner", choice: index == 0 ? .neither : (index == 1 ? .tie : .left), shownLeft: pair.left,
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
    #expect(report.stages.contains { $0.stage == .layout } && report.stages.contains { $0.neither > 0 })
    if case .evalScore(let dir, let stage) = try Arguments.parse(["eval", "score", out.path, "--stage", "cover"], cwd: tmp.url) {
        #expect(dir.resolvingSymlinksInPath().path == out.resolvingSymlinksInPath().path && stage == .cover)
    } else { Issue.record("eval score --stage did not parse") }
    let legacy = Data(#"{"seed":"e","createdAt":"1970-01-01T00:00:00Z","runs":[],"pairs":[{"pairID":"p","runID":"r","left":{"carouselID":"a","compositionSeed":"0","runID":"r"},"right":{"carouselID":"b","compositionSeed":"0","runID":"r"}}],"strips":{},"versions":{}}"#.utf8)
    let oldSet = try JSONCoding.decoder.decode(EvalSet.self, from: legacy)
    #expect(oldSet.pairs.first?.stage == .layout)
    let oldLabel = Data(#"{"pairID":"p","rater":"old","choice":"left","shownLeft":{"carouselID":"a","compositionSeed":"0","runID":"r"},"decidedAt":"1970-01-01T00:00:00Z","versions":{}}"#.utf8)
    #expect(try JSONCoding.decoder.decode(EvalLabel.self, from: oldLabel).choice == .left)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.appending(path: "eval").path).contains { $0.hasPrefix("report-") && $0.hasSuffix(".md") })
}

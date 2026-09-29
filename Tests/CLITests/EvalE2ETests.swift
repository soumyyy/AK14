import Foundation
import ImageIO
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

private func evalRun(_ tmp: TempDirectory, folder: URL, aspect: CarouselAspect? = nil) async throws -> RunStore {
    let options = RunOptions(folder: folder, aspect: aspect, runsDirectory: tmp.url.appending(path: "runs"),
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

@Test func compareBuildsFrozenEnginePairsAndScoresPreferenceAndRatings() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try evalScene(tmp, name: "scene")
    let run = try await evalRun(tmp, folder: folder, aspect: .portrait4x5)
    // Persist moments with optional alternatives, so composing the original pool on both sides would fail.
    var stored = try run.read(ConceptsReport.self, from: "plans/director.json")
    for index in stored.plans.indices where !stored.plans[index].isBaseline {
        var direction = try #require(stored.plans[index].direction)
        let tail = direction.orderedAssetIDs.filter { $0 != direction.coverAssetID }
        direction.moments = [.init(label: "cover", photos: [direction.coverAssetID], mustInclude: [direction.coverAssetID], size: "1")]
            + stride(from: 0, to: tail.count, by: 3).map { start in
                let photos = Array(tail[start..<min(start + 3, tail.count)])
                return .init(label: "moment", photos: photos, mustInclude: [photos[0]], size: "1")
            }
        direction.coverCandidates = [direction.coverAssetID]
        stored.plans[index].direction = direction
    }
    try run.write(stored, to: "plans/director.json")
    let savedReport = try Data(contentsOf: run.url("plans/director.json"))
    try FileManager.default.removeItem(at: run.url("cache/thumbnails"))
    let out = tmp.url.appending(path: "eval")
    #expect(throws: EvalCommand.EvalError.overlappingOutput) {
        try EvalCommand.compare(runDirectories: [run.root], source: folder, out: tmp.url)
    }
    if case .evalCompare(let dirs, let source, let dir, let seed) = try Arguments.parse(
        ["eval", "compare", run.root.path, "--source", folder.path, "--out", out.path, "--seed", "cafe"], cwd: tmp.url) {
        try EvalCommand.compare(runDirectories: dirs, source: source, out: dir, seed: seed)
    } else { Issue.record("eval compare arguments did not parse") }
    #expect(throws: ArgumentError.missingSource) {
        try Arguments.parse(["eval", "compare", run.root.path, "--out", out.path], cwd: tmp.url)
    }
    let set = try JSONCoding.decoder.decode(EvalSet.self, from: Data(contentsOf: out.appending(path: "evalset.json")))
    let pairs = set.pairs.filter { $0.stage == .engine }
    #expect(!pairs.isEmpty)
    #expect(try Data(contentsOf: run.url("plans/director.json")) == savedReport)
    let manifest = try run.read(RunManifest.self, from: "manifest.json")
    let features = Dictionary(uniqueKeysWithValues: try run.read([PhotoFeatures].self, from: "cache/features.json").map { ($0.assetID, $0) })
    var pageSlides: [ResolvedSlide] = []
    for pair in pairs {
        #expect(Set([pair.left.carouselID.hasPrefix("legacy-"), pair.right.carouselID.hasPrefix("legacy-")]) == [true, false])
        #expect(pair.left.assetIDs == pair.right.assetIDs)
        #expect(!pair.left.assetIDs.isEmpty && pair.left.engine != nil && pair.right.engine != nil)
        for ref in [pair.left, pair.right] {
            let root = out.appending(path: "runs/\(pair.runID)")
            let plan = try JSONCoding.decoder.decode(CarouselPlan.self, from: Data(contentsOf: root.appending(path: "plans/\(ref.carouselID).json")))
            #expect(plan.photoAssetIDs == ref.assetIDs)
            if ref.carouselID.hasPrefix("legacy-") { #expect(plan.direction?.moments.isEmpty == true) }
            else {
                #expect(plan.slides.allSatisfy { $0.placement != nil })
                let original = try #require(stored.plans.first { "pages-" + $0.id == ref.carouselID }?.direction)
                #expect(plan.photoAssetIDs.count < original.orderedAssetIDs.count)
                #expect(Set(original.moments.flatMap(\.mustInclude)).isSubset(of: Set(plan.photoAssetIDs)))
            }
            for index in plan.slides.indices {
                let slide = try JSONCoding.decoder.decode(ResolvedSlide.self, from: Data(contentsOf: root.appending(path: String(format: "layouts/%@/slide-%02d.json", ref.carouselID, index + 1))))
                if ref.carouselID.hasPrefix("pages-") { pageSlides.append(slide) }
                for element in slide.elements where element.kind == .photo {
                    let crop = try #require(element.crop)
                    #expect(crop.width * crop.height >= SlotAssignment.cropFloor)
                    #expect(CropPlanner.facesFit(element.assetID.flatMap { features[$0] }, crop: crop))
                    #expect(element.frame.x >= 0 && element.frame.y >= 0)
                    #expect(element.frame.x + element.frame.width <= 1.000001 && element.frame.y + element.frame.height <= 1.000001)
                }
                let imageURL = root.appending(path: String(format: "slides/%@/slide-%02d.png", ref.carouselID, index + 1))
                let image = try #require(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
                let props = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
                #expect(props[kCGImagePropertyPixelWidth] as? Int == manifest.aspectRatio.exportWidth)
                #expect(props[kCGImagePropertyPixelHeight] as? Int == manifest.aspectRatio.exportHeight)
            }
        }
    }
    let original = try Data(contentsOf: out.appending(path: "evalset.json"))
    let sample = try #require(pairs.first?.left)
    let renderedSlide = out.appending(path: "runs/\(sample.runID)/slides/\(sample.carouselID)/slide-01.png")
    let renderedBytes = try Data(contentsOf: renderedSlide)
    try EvalCommand.compare(runDirectories: [run.root], source: folder, out: out, seed: 0xcafe)
    #expect(try Data(contentsOf: out.appending(path: "evalset.json")) == original)
    #expect(try Data(contentsOf: renderedSlide) == renderedBytes)
    let labels = pairs.map { pair in
        EvalLabel(pairID: pair.pairID, rater: "o", choice: pair.left.carouselID.hasPrefix("legacy-") ? .right : .left,
                  shownLeft: pair.left, decidedAt: Date(timeIntervalSince1970: 1), versions: set.versions)
    }
    let ratings = pairs.map { pair in
        EvalRating(runID: pair.runID, optionID: pair.left.carouselID.hasPrefix("pages-") ? pair.left.carouselID : pair.right.carouselID,
                   engine: "pages", rating: "yes", rater: "o")
    }
    let file = tmp.url.appending(path: "labels.json")
    let labelsObject = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(labels))
    let ratingsObject = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(ratings))
    try JSONSerialization.data(withJSONObject: ["labels": labelsObject, "ratings": ratingsObject]).write(to: file)
    try EvalCommand.importLabels(evalDirectory: out, file: file)
    try EvalCommand.importLabels(evalDirectory: out, file: file)
    #expect(try JSONCoding.decoder.decode([EvalRating].self, from: Data(contentsOf: out.appending(path: "ratings.json"))) == ratings)
    let report = try EvalCommand.score(evalDirectory: out, stage: .engine)
    #expect(report.contains("new engine preferred: 100%"))
    #expect(report.contains("rated yes: 100%"))
    let whiteRate = Int((100 * Double(pageSlides.filter { $0.variant == "hero.clean" }.count) / Double(pageSlides.count)).rounded())
    #expect(report.contains("white cards: \(whiteRate)% of slides"))
    let crops = pageSlides.flatMap(\.elements).filter { $0.kind == .photo }.compactMap(\.crop).map { $0.width * $0.height }.sorted()
    let middle = crops.count / 2
    let median = crops.count % 2 == 0 ? (crops[middle - 1] + crops[middle]) / 2 : crops[middle]
    #expect(report.contains(String(format: "median crop kept: %.2f", median)))
    print(report)
    let tieLabels = pairs.map { pair in
        EvalLabel(pairID: pair.pairID, rater: "o", choice: .tie, shownLeft: pair.left,
                  decidedAt: Date(timeIntervalSince1970: 2), versions: set.versions)
    }
    let changedRatings = ratings.enumerated().map { index, rating in
        EvalRating(runID: rating.runID, optionID: rating.optionID, engine: rating.engine,
                   rating: index == 0 ? "almost" : "no", rater: rating.rater)
    }
    try JSONSerialization.data(withJSONObject: [
        "labels": JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(tieLabels)),
        "ratings": JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(changedRatings))
    ]).write(to: file)
    try EvalCommand.importLabels(evalDirectory: out, file: file)
    let tiedReport = try EvalCommand.score(evalDirectory: out, stage: .engine)
    #expect(tiedReport.contains("new engine preferred: 0%") && tiedReport.contains("neither/tie: \(pairs.count)"))
    #expect(tiedReport.contains("rated yes: 0%"))
    let bad = EvalRating(runID: ratings[0].runID, optionID: ratings[0].optionID, engine: "legacy", rating: "maybe", rater: "o")
    try JSONSerialization.data(withJSONObject: ["labels": [], "ratings": JSONSerialization.jsonObject(with: JSONCoding.encoder.encode([bad]))]).write(to: file)
    #expect(throws: EvalCommand.EvalError.invalidLabels) { try EvalCommand.importLabels(evalDirectory: out, file: file) }
    #expect(try JSONCoding.decoder.decode([EvalRating].self, from: Data(contentsOf: out.appending(path: "ratings.json"))) == changedRatings)
    try EvalCommand.label(evalDirectory: out, rater: "o")
    #expect(try String(contentsOf: out.appending(path: "index.html"), encoding: .utf8).contains("Which carousel layout is better?"))
    if case .evalRate(let dir, let rater) = try Arguments.parse(["eval", "rate", out.path, "--rater", "o"], cwd: tmp.url) {
        try EvalCommand.rate(evalDirectory: dir, rater: rater)
    } else { Issue.record("eval rate arguments did not parse") }
    let html = try String(contentsOf: out.appending(path: "index.html"), encoding: .utf8)
    #expect(html.contains("Would you post this option?"))
    #expect(html.contains("ratings.json") && html.contains("almost") && html.contains("data:image/png;base64,"))
    try Data("changed".utf8).write(to: folder.appending(path: "IMG_0000.jpg"))
    #expect(throws: (any Error).self) { try EvalCommand.compare(runDirectories: [run.root], source: folder, out: out) }
}

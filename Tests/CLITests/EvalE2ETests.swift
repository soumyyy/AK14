import Foundation
import ImageIO
import Session
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
    #expect(oldSet.skippedOptions == nil)
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
    var whiteCards = 0
    var nonWhiteSlides: [ResolvedSlide] = []
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
                if ref.carouselID.hasPrefix("pages-") {
                    pageSlides.append(slide)
                    if plan.slides[index].placement?.pageID == "white-card" { whiteCards += 1 }
                    else { nonWhiteSlides.append(slide) }
                }
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
    #expect(report.contains("runs with no postable option: 0 of 1"))
    #expect(report.contains("worst option per run: \(run.root.lastPathComponent): yes"))
    let whiteRate = Int((100 * Double(whiteCards) / Double(pageSlides.count)).rounded())
    #expect(report.contains("white cards: \(whiteRate)% of slides"))
    let crops = nonWhiteSlides.flatMap(\.elements).filter { $0.kind == .photo }.compactMap(\.crop).map { $0.width * $0.height }.sorted()
    let middle = crops.count / 2
    let median = crops.count % 2 == 0 ? (crops[middle - 1] + crops[middle]) / 2 : crops[middle]
    #expect(report.contains(String(format: "median crop kept: %.2f", median)))
    print(report)
    let almostRatings = ratings.map { rating in
        EvalRating(runID: rating.runID, optionID: rating.optionID, engine: rating.engine, rating: "almost", rater: rating.rater)
    }
    try JSONSerialization.data(withJSONObject: ["labels": [], "ratings": JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(almostRatings))]).write(to: file)
    try EvalCommand.importLabels(evalDirectory: out, file: file)
    let almostReport = try EvalCommand.score(evalDirectory: out, stage: .engine)
    #expect(almostReport.contains("runs with no postable option: 1 of 1"))
    #expect(almostReport.contains("worst option per run: \(run.root.lastPathComponent): almost"))
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
    #expect(tiedReport.contains("runs with no postable option: 1 of 1"))
    #expect(tiedReport.contains("worst option per run: \(run.root.lastPathComponent): no"))
    let bad = EvalRating(runID: ratings[0].runID, optionID: ratings[0].optionID, engine: "legacy", rating: "maybe", rater: "o")
    try JSONSerialization.data(withJSONObject: ["labels": [], "ratings": JSONSerialization.jsonObject(with: JSONCoding.encoder.encode([bad]))]).write(to: file)
    #expect(throws: EvalCommand.EvalError.invalidLabels) { try EvalCommand.importLabels(evalDirectory: out, file: file) }
    #expect(try JSONCoding.decoder.decode([EvalRating].self, from: Data(contentsOf: out.appending(path: "ratings.json"))) == changedRatings)
    try EvalCommand.label(evalDirectory: out, rater: "o")
    let labelHTML = try String(contentsOf: out.appending(path: "label.html"), encoding: .utf8)
    #expect(labelHTML.contains("Which carousel layout is better?"))
    #expect(!labelHTML.contains("data:image"))
    for path in set.strips.values {
        #expect(labelHTML.contains(path))
        #expect(FileManager.default.fileExists(atPath: out.appending(path: path).path))
    }
    #expect(labelHTML.contains("const key='ak14-eval-'+rater;"))
    #expect(try String(contentsOf: out.appending(path: "index.html"), encoding: .utf8) == labelHTML)
    if case .evalRate(let dir, let rater) = try Arguments.parse(["eval", "rate", out.path, "--rater", "o"], cwd: tmp.url) {
        try EvalCommand.rate(evalDirectory: dir, rater: rater)
    } else { Issue.record("eval rate arguments did not parse") }
    #expect(try String(contentsOf: out.appending(path: "label.html"), encoding: .utf8) == labelHTML)
    #expect(try String(contentsOf: out.appending(path: "index.html"), encoding: .utf8) == labelHTML)
    let html = try String(contentsOf: out.appending(path: "rate.html"), encoding: .utf8)
    #expect(html.contains("Would you post this option?"))
    #expect(html.contains("ratings.json") && html.contains("almost"))
    #expect(!html.contains("data:image"))
    for pair in pairs {
        let ref = pair.left.carouselID.hasPrefix("pages-") ? pair.left : pair.right
        let plan = try JSONCoding.decoder.decode(CarouselPlan.self, from: Data(contentsOf: out.appending(path: "runs/\(ref.runID)/plans/\(ref.carouselID).json")))
        for index in plan.slides.indices {
            let path = String(format: "runs/%@/slides/%@/slide-%02d.png", ref.runID, ref.carouselID, index + 1)
            #expect(html.contains(path))
            #expect(FileManager.default.fileExists(atPath: out.appending(path: path).path))
        }
    }
    try EvalCommand.label(evalDirectory: out, rater: "o")
    #expect(try String(contentsOf: out.appending(path: "rate.html"), encoding: .utf8) == html)
    let changedID = try #require(pairs.first?.left.assetIDs.first)
    let changedPath = try #require(try run.read(IngestResult.self, from: "input-index.json").photos.first { $0.assetID == changedID }?.sourceRelativePaths.first)
    try Data("changed".utf8).write(to: folder.appending(path: changedPath))
    #expect {
        try EvalCommand.compare(runDirectories: [run.root], source: folder, out: out)
    } throws: { error in
        guard case RerenderCommand.Failure.changed(let path) = error else { return false }
        return path == changedPath
    }
}

@Test func compareSkipsLegacyFallbackForMostlyLandscapeSquareRun() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try evalScene(tmp, name: "landscapes")
    let run = try await evalRun(tmp, folder: folder)
    #expect(try run.read(RunManifest.self, from: "manifest.json").aspectRatio == .square)
    let session = try RunSession(runDirectory: run.root)
    let context = session.compositionContext()
    let composed = ComposerEngine.composeSet(directions: session.concepts.plans.filter { !$0.isBaseline }.compactMap(\.direction),
        spine: try #require(session.concepts.spine), context: context, runID: session.runID)
    let options = composed.plans.filter { !$0.isBaseline }
    #expect(!options.isEmpty)
    #expect(options.allSatisfy { $0.slides.contains { $0.placement == nil } })
    let out = tmp.url.appending(path: "eval")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/debug/ak14")
    process.arguments = ["eval", "compare", run.root.path, "--source", folder.path, "--out", out.path]
    let output = Pipe()
    process.standardOutput = output
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let text = String(decoding: data, as: UTF8.self)
    let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    for option in options {
        #expect(errorText.contains("warning: \(run.root.lastPathComponent)/\(option.id): skipped option: template-first unavailable"))
        #expect(!text.contains("warning:"))
    }
    #expect(text.contains("\(run.root.lastPathComponent): no template-first options available"))
    let set = try JSONCoding.decoder.decode(EvalSet.self, from: Data(contentsOf: out.appending(path: "evalset.json")))
    #expect(set.pairs.isEmpty)
    #expect(set.skippedOptions == options.count)
    #expect(set.strips.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: out.appending(path: "runs/\(run.root.lastPathComponent)").path))
    let summary = try EvalCommand.score(evalDirectory: out, stage: .engine)
    #expect(summary.contains("skipped \(options.count) options: template-first unavailable"))
    #expect(summary.contains("no template-first options available"))
    let reports = try FileManager.default.contentsOfDirectory(at: out.appending(path: "eval"), includingPropertiesForKeys: nil)
    let markdown = try String(contentsOf: #require(reports.first { $0.pathExtension == "md" }), encoding: .utf8)
    #expect(markdown.contains("skipped \(options.count) options: template-first unavailable"))
}

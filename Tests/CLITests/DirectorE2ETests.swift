import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director

/// Fake Responses API: reads the strict schema out of each request and answers with valid JSON built from the
/// schema's own ID enums, or with scripted failures.
final class FakeModel: ResponsesTransport, @unchecked Sendable {
    enum Behaviour { case valid, duplicatePhoto, garbage, rateLimited, incomplete }
    private let lock = NSLock()
    private var script: [String: [Behaviour]]
    private(set) var stages: [String] = []
    /// When set, triage flags the first 3 photos (blink) and the planner puts flagged photos first (as cover).
    let flagCover: Bool
    private var flagged: [String] = []

    init(_ script: [String: [Behaviour]] = [:], flagCover: Bool = false) { self.script = script; self.flagCover = flagCover }

    func send(_ body: Data) async throws -> (status: Int, body: Data) {
        let request = try JSONDecoder().decode(JSONValue.self, from: body)
        let format = request["text"]!["format"]!
        let stage = format["name"]!.stringValue!
        let behaviour: Behaviour = lock.withLock {
            stages.append(stage)
            guard var queue = script[stage], !queue.isEmpty else { return .valid }
            let b = queue.removeFirst(); script[stage] = queue
            return b
        }
        if behaviour == .rateLimited { return (429, Data(#"{"error":{"message":"slow down"}}"#.utf8)) }
        let schema = format["schema"]!
        let text: String
        switch (stage, behaviour) {
        case (_, .garbage), (_, .incomplete): text = "not json"
        case ("triage", _), ("triage_repair", _):
            let ids = Self.enumValues(schema["properties"]?["results"]?["items"]?["properties"]?["id"])
            if flagCover { lock.withLock { flagged = Array(ids.prefix(3)) } }
            text = Self.triage(schema, flagged: flagCover ? Set(ids.prefix(3)) : [])
        default:
            let first = lock.withLock { flagged }
            text = Self.planner(schema, duplicate: behaviour == .duplicatePhoto, first: first)
        }
        let envelope: JSONValue = .object([
            ("id", .string("resp_test")), ("status", .string(behaviour == .incomplete ? "incomplete" : "completed")),
            ("incomplete_details", behaviour == .incomplete ? .object([("reason", .string("max_output_tokens"))]) : .null),
            ("output", .array([.object([("type", .string("message")), ("content", .array([
                .object([("type", .string("output_text")), ("text", .string(text))])]))])])),
            ("usage", .object([("input_tokens", .int(1000)), ("output_tokens", .int(200)),
                               ("input_tokens_details", .object([("cached_tokens", .int(0))])),
                               ("output_tokens_details", .object([("reasoning_tokens", .int(20))]))])),
        ])
        return (200, try JSONEncoder().encode(envelope))
    }

    static func enumValues(_ v: JSONValue?) -> [String] { v?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    static func triage(_ schema: JSONValue, flagged: Set<String> = []) -> String {
        let ids = enumValues(schema["properties"]?["results"]?["items"]?["properties"]?["id"])
        let results = ids.enumerated().map { i, id in
            let safety = flagged.contains(id) ? #"["blink"]"# : "[]"
            return #"{"id":"\#(id)","emotionalValue":\#(i % 6),"imperfection":"neutral","safety":\#(safety),"tags":["people"],"confidence":"high"}"#
        }
        return #"{"results":[\#(results.joined(separator: ","))]}"#
    }

    static func planner(_ schema: JSONValue, duplicate: Bool, first: [String] = []) -> String {
        let pool = enumValues(schema["properties"]?["spine"]?["properties"]?["orderedAssetIDs"]?["items"])
        let ids = pool.filter { first.contains($0) } + pool.filter { !first.contains($0) }
        let decos = enumValues(schema["properties"]?["plans"]?["items"]?["properties"]?["slides"]?["items"]?["properties"]?["decorations"]?["items"]?["properties"]?["decorationID"])
        func photo(_ i: Int, _ role: String = "hero") -> String {
            #"{"assetID":"\#(ids[i])","role":"\#(role)","importance":2,"cropIntent":"balanced","anchorIntent":"center","overlapIntent":"none","rotationIntent":"none"}"#
        }
        func slide(_ primitive: String, _ density: String, _ photos: [Int], deco: Bool = false) -> String {
            let d = deco ? "[" + decos.map { #"{"decorationID":"\#($0)","intensity":"medium"}"# }.joined(separator: ",") + "]" : "[]"
            let stamps = deco ? #"[{"kind":"date","placement":"bottomRight"},{"kind":"location","placement":"topLeft"}]"# : "[]"
            return #"{"primitive":"\#(primitive)","mood":"warm","density":"\#(density)","photos":[\#(photos.enumerated().map { photo($1, $0 == 0 ? "hero" : "support") }.joined(separator: ","))],"decorations":\#(d),"stamps":\#(stamps)}"#
        }
        let spine = Array(0..<6)
        let plain = spine.map { slide("full_bleed", "quiet", [$0]) }
        let designed = [slide("hero", "quiet", [0], deco: true), slide("asymmetric_pair", "balanced", [1, 2]),
                        slide("full_bleed", "quiet", [3]), slide("full_bleed", "quiet", [4]),
                        slide("full_bleed", "quiet", duplicate ? [0] : [5])]
        let wildcard = [slide("overlap_cluster", "dense", [7, 6], deco: true), slide("full_bleed", "balanced", [5]),
                        slide("hero", "dense", [4]), slide("full_bleed", "balanced", [3]), slide("inset", "dense", [2, 1])]
        func plan(_ type: String, _ slides: [String]) -> String {
            #"{"conceptType":"\#(type)","conceptNote":"test","slides":[\#(slides.joined(separator: ","))]}"#
        }
        let spineJSON = #"{"orderedAssetIDs":[\#(spine.map { "\"\(ids[$0])\"" }.joined(separator: ","))],"sequenceIntent":[\#(spine.map { _ in "\"build\"" }.joined(separator: ","))],"rationale":[]}"#
        return #"{"recommendedSlideCount":6,"spine":\#(spineJSON),"plans":[\#(plan("plainDump", plain)),\#(plan("designed", designed)),\#(plan("wildcard", wildcard))]}"#
    }
}

private func sceneFolder(_ tmp: TempDirectory, count: Int = 12) throws -> URL {
    let folder = try tmp.sub("trip")
    for i in 0..<count {
        var exif = FixtureFactory.Exif(); exif.date = String(format: "2026:05:29 %02d:10:00", 8 + i)
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    return folder
}

private func run(_ tmp: TempDirectory, folder: URL, model: FakeModel, slides: Int? = nil) async throws -> RunStore {
    var o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"))
    o.slides = slides
    let client = ResponsesClient(transport: model, sleep: { _ in })
    return try await RunPipeline.live(options: o, client: client, log: { _ in }).run(o)
}

@Test func happyPathProducesThreeConceptsAndPlainSlides() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel()
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.directorStatus == "ok", "\(m.warnings)")
    #expect(model.stages == ["triage", "planner"])
    #expect(m.providerCalls.count == 2 && m.providerCalls.allSatisfy(\.ok))
    #expect(m.totalEstimatedCost > 0)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.plans.map(\.conceptType) == [.plainDump, .designed, .wildcard])
    #expect(d.plainSlides.count == 6 && d.diversity?.passes == true)
    for s in d.plainSlides { #expect(FileManager.default.fileExists(atPath: store.url(s).path)) }
    #expect(m.funnel?.triaged == m.funnel?.shortlisted)
    // Raw LLM I/O is persisted without image data.
    let llm = try FileManager.default.contentsOfDirectory(atPath: store.url("llm").path).sorted()
    #expect(llm == ["1-triage.json", "2-planner.json"])
    let raw = try String(contentsOf: store.url("llm/1-triage.json"), encoding: .utf8)
    #expect(raw.contains("thumbnail:a_") && !raw.contains("base64"))
    let html = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    #expect(html.contains("slides/plainDump/slide-01.png") && html.contains("Model calls") && html.contains("Selection spine"))

    // rerender: no model calls, identical PNG bytes.
    let before = try Data(contentsOf: store.url("slides/plainDump/slide-01.png"))
    try RerenderCommand.rerender(runDirectory: store.root, source: tmp.url.appending(path: "trip"))
    #expect(try Data(contentsOf: store.url("slides/plainDump/slide-01.png")) == before)
    #expect(model.stages.count == 2)
}

@Test func invalidPlanTriggersRepairThenValid() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.duplicatePhoto]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(model.stages == ["triage", "planner", "repair"])
    #expect(m.directorStatus == "ok")
}

@Test func garbageEverywhereFallsBackToPlain() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.garbage], "repair": [.garbage], "retry": [.garbage]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model, slides: 5)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(model.stages == ["triage", "planner", "repair", "retry"])
    #expect(m.directorStatus == "fallback")
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.plans.map(\.conceptType) == [.plainDump])
    #expect(Set(d.unavailable.keys) == ["designed", "wildcard"])
    #expect(d.plainSlides.count == 5)
}

@Test func rateLimitIsRetriedAndRecorded() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["triage": [.rateLimited]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.providerCalls.first?.stage == "triage" && m.providerCalls.first?.retryCount == 1)
    #expect(m.directorStatus == "ok")
}

@Test func tinyFolderStillProducesAPlainDump() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp, count: 3)
    let store = try await run(tmp, folder: folder, model: FakeModel(["planner": [.garbage], "repair": [.garbage], "retry": [.garbage]]))
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.plainSlides.count == 3)
}


// MARK: - Review fixes

@Test func flaggedCoverIsNeverRendered() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: FakeModel(flagCover: true))
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    let flagged = Set(d.triage.filter { !$0.value.safety.isEmpty }.keys)
    #expect(flagged.count == 3)
    let cover = try #require(d.spine?.orderedAssetIDs.first)
    #expect(!flagged.contains(cover.rawValue))
    for p in d.plans { #expect(!flagged.contains(p.coverAssetID!.rawValue), "\(p.conceptType) cover flagged") }
}

@Test func failedFirstPlannerCallIsRetriedAndBilled() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.incomplete]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(model.stages == ["triage", "planner", "retry"])
    let failed = try #require(m.providerCalls.first { $0.stage == "planner" })
    #expect(!failed.ok && failed.estimatedCost > 0)
    #expect(m.directorStatus == "ok")
    #expect(FileManager.default.fileExists(atPath: store.url("llm/2-planner.json").path))
}

@Test func requestedSlideCountIsEnforced() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: FakeModel(), slides: 5)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect((d.spine?.orderedAssetIDs.count ?? 99) <= 5)
    #expect(d.plans.allSatisfy { $0.slides.count <= 5 || $0.conceptType != .plainDump })
}

@Test func invalidSpineMakesDesignedConceptsUnavailable() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    // 6-photo spine against a 5-slide request stays invalid through repair and retry.
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: FakeModel(), slides: 5)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.status == "fallback")
    #expect(d.plans.map(\.conceptType) == [.plainDump])
}

@Test func oldManifestsStillOpenInReport() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp, count: 2)
    let o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                       cacheDirectory: tmp.url.appending(path: "cache"), noLLM: true)
    let store = try await RunPipeline.live(options: o, log: { _ in }).run(o)
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url("manifest.json"))) as! [String: Any]
    for key in ["providerCalls", "totalEstimatedCost", "funnel", "directorStatus"] { json.removeValue(forKey: key) }
    try JSONSerialization.data(withJSONObject: json).write(to: store.url("manifest.json"))
    try ReportCommand.rebuild(runDirectory: store.root)
}

@Test func envFileWithCRLFIsRead() throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    try Data("# comment\r\nOTHER=1\r\nOPENAI_API_KEY=\"sk-test\"\r\n".utf8).write(to: tmp.url.appending(path: ".env"))
    #expect(Env.apiKey(cwd: tmp.url, environment: [:]) == "sk-test")
}

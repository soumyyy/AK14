import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director

/// Fake Responses API: reads the strict schema out of each request and answers with valid JSON built from the
/// schema's own ID enums, or with scripted failures.
final class FakeModel: ResponsesTransport, @unchecked Sendable {
    enum Behaviour { case valid, duplicatePhoto, garbage, rateLimited, incomplete, badDirection, splitGroups, mergeAll, delayed }
    /// How many directions the planner proposes (2-5).
    var directions = 3
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
        if behaviour == .delayed { try await Task.sleep(for: .seconds(1)) }
        if behaviour == .rateLimited { return (429, Data(#"{"error":{"message":"slow down"}}"#.utf8)) }
        let schema = format["schema"]!
        let text: String
        switch (stage, behaviour) {
        case (_, .garbage), (_, .incomplete): text = "not json"
        case ("triage", _), ("triage_repair", _):
            let ids = Self.enumValues(schema["properties"]?["results"]?["items"]?["properties"]?["id"])
            if flagCover { lock.withLock { flagged = Array(ids.prefix(3)) } }
            text = Self.triage(schema, flagged: flagCover ? Set(ids.prefix(3)) : [])
        case ("occasion_split", .splitGroups):
            let ids = Self.enumValues(schema["properties"]?["groups"]?["items"]?["items"])
            let half = max(2, ids.count / 2)
            let left = ids.prefix(half).map { "\"\($0)\"" }.joined(separator: ",")
            let right = ids.dropFirst(half).map { "\"\($0)\"" }.joined(separator: ",")
            text = #"{"groups":[[\#(left)],[\#(right)]]}"#
        case ("occasion_split", .mergeAll):
            let ids = Self.enumValues(schema["properties"]?["groups"]?["items"]?["items"])
            text = #"{"groups":[[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]]}"#
        case ("occasion_split", _):
            let ids = Self.enumValues(schema["properties"]?["groups"]?["items"]?["items"])
            let parts = request["input"]?.arrayValue?.last?["content"]?.arrayValue ?? []
            var localGroups: [Int: [String]] = [:]
            for part in parts {
                guard let line = part["text"]?.stringValue, line.hasPrefix("local event group ") else { continue }
                let fields = line.split(separator: ",")
                guard fields.count >= 3,
                      let group = Int(fields[0].replacingOccurrences(of: "local event group ", with: "").trimmingCharacters(in: .whitespaces)),
                      let id = fields[2].trimmingCharacters(in: .whitespaces).split(separator: " ").last.map(String.init) else { continue }
                localGroups[group, default: []].append(id)
            }
            let matched = localGroups.keys.sorted().map { localGroups[$0] ?? [] }.filter { $0.count >= 2 }
            let outputGroups = matched.isEmpty ? [ids] : matched.flatMap { $0.count >= 2 ? [$0] : [] }
            text = #"{"groups":[\#(outputGroups.map { "[\($0.map { "\"\($0)\"" }.joined(separator: ","))]" }.joined(separator: ","))]}"#
        default:
            let first = lock.withLock { flagged }
            text = Self.planner(schema, duplicate: behaviour == .duplicatePhoto, first: first, directions: directions,
                                badDirection: behaviour == .badDirection)
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
        let allowedTags = enumValues(schema["properties"]?["results"]?["items"]?["properties"]?["tags"]?["items"])
        let results = ids.enumerated().map { i, id in
            let safety = flagged.contains(id) ? #"["blink"]"# : "[]"
            let tag = i == 0 && allowedTags.contains("candid") ? "candid" : "people"
            return #"{"id":"\#(id)","emotionalValue":\#(i % 6),"imperfection":"neutral","safety":\#(safety),"tags":["\#(tag)"],"confidence":"high"}"#
        }
        return #"{"results":[\#(results.joined(separator: ","))]}"#
    }

    /// Styles for up to five directions; each pair differs on several axes.
    static let styles = [
        #"{"density":"balanced","overlap":"some","grouping":"mixed","decoration":"light","rotation":"none","whitespace":"tight"}"#,
        #"{"density":"dense","overlap":"bold","grouping":"collage","decoration":"rich","rotation":"some","whitespace":"tight"}"#,
        #"{"density":"quiet","overlap":"none","grouping":"single","decoration":"none","rotation":"none","whitespace":"airy"}"#,
        #"{"density":"varied","overlap":"some","grouping":"mixed","decoration":"rich","rotation":"some","whitespace":"airy"}"#,
        #"{"density":"balanced","overlap":"none","grouping":"mixed","decoration":"light","rotation":"none","whitespace":"tight"}"#,
    ]

    static func planner(_ schema: JSONValue, duplicate: Bool, first: [String] = [], directions: Int = 3,
                        badDirection: Bool = false) -> String {
        let pool = enumValues(schema["properties"]?["spine"]?["properties"]?["orderedAssetIDs"]?["items"])
        let ids = pool.filter { first.contains($0) } + pool.filter { !first.contains($0) }
        let spine = Array(ids.prefix(6))
        let quoted = { (list: [String]) in "[" + list.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        let items = (0..<directions).map { k -> String in
            // Each direction tells the story from a different opening photo, with one or two extra candidates.
            var list = Array(spine.dropFirst(k % spine.count) + spine.prefix(k % spine.count)) + Array(ids.dropFirst(6).prefix(k % 3))
            if duplicate && k == 0 { list.append(list[1]) }
            if badDirection && k == 1 { list.append("a_notacandidate") }
            let cover = list.first { !first.contains($0) } ?? list[0]
            let keep = k == 1 ? quoted([list[1], list[2]]) : ""
            let emphasis = k == 0 ? quoted([list[3]]) : "[]"
            return #"{"brief":"test direction \#(k + 1)","style":\#(styles[k % styles.count]),"coverAssetID":"\#(cover)","orderedAssetIDs":\#(quoted(list)),"keepTogether":[\#(keep)],"emphasisAssetIDs":\#(emphasis)}"#
        }
        let spineJSON = #"{"orderedAssetIDs":\#(quoted(spine)),"sequenceIntent":[\#(spine.map { _ in "\"build\"" }.joined(separator: ","))],"rationale":[]}"#
        return #"{"recommendedSlideCount":\#(spine.count),"spine":\#(spineJSON),"directions":[\#(items.joined(separator: ","))]}"#
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
    var o = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"), cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
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
    #expect(model.stages == ["occasion_split", "triage", "planner"])
    #expect(m.providerCalls.count == 3 && m.providerCalls.allSatisfy(\.ok))
    #expect(m.totalEstimatedCost > 0)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.triage.values.contains { $0.tags.contains("candid") })
    #expect(d.plans.map(\.id) == ["baseline", "c1", "c2", "c3"])
    #expect(Set(d.presentationOrder) == Set(d.plans.map(\.id)))
    #expect(d.baselineSlides.count == 6 && d.diversity.count == 3 && d.diversity.allSatisfy(\.passes), "\(d.diversity)")
    for s in d.baselineSlides { #expect(FileManager.default.fileExists(atPath: store.url(s).path)) }
    #expect(m.funnel?.triaged == m.funnel?.shortlisted)
    // Raw LLM I/O is persisted without image data.
    let llm = try FileManager.default.contentsOfDirectory(atPath: store.url("llm").path).sorted()
    #expect(llm == ["0-occasion-split.json", "1-triage.json", "2-planner.json"])
    let raw = try String(contentsOf: store.url("llm/1-triage.json"), encoding: .utf8)
    #expect(raw.contains("thumbnail:a_") && !raw.contains("base64"))
    let exchange = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let request = try #require(exchange["request"] as? [String: Any])
    #expect(request["store"] as? Bool == false, "photo planning should disable response storage")
    let html = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    #expect(html.contains("slides/baseline/slide-01.png") && html.contains("Model calls") && html.contains("Selection spine"))

    // rerender: no model calls, identical PNG bytes.
    let before = try Data(contentsOf: store.url("slides/baseline/slide-01.png"))
    try RerenderCommand.rerender(runDirectory: store.root, source: tmp.url.appending(path: "trip"))
    #expect(try Data(contentsOf: store.url("slides/baseline/slide-01.png")) == before)
    #expect(model.stages.count == 3)
}

@Test func invalidPlanTriggersRepairThenValid() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.duplicatePhoto]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(model.stages == ["occasion_split", "triage", "planner", "repair"])
    #expect(m.directorStatus == "ok")
}

@Test func garbageEverywhereFallsBackToPlain() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.garbage], "repair": [.garbage], "retry": [.garbage]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model, slides: 5)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(model.stages == ["occasion_split", "triage", "planner", "repair", "retry"])
    #expect(m.directorStatus == "fallback")
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.plans.map(\.id) == ["baseline"])
    #expect(Set(d.unavailable.keys) == ["directions"])
    #expect(d.baselineSlides.count == 5)
}

@Test func rateLimitIsRetriedAndRecorded() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["triage": [.rateLimited]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    let triage = try #require(m.providerCalls.first { $0.stage == "triage" })
    #expect(triage.retryCount == 1)
    #expect(m.directorStatus == "ok")
}

@Test func tinyFolderStillProducesAPlainDump() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try sceneFolder(tmp, count: 3)
    let store = try await run(tmp, folder: folder, model: FakeModel(["planner": [.garbage], "repair": [.garbage], "retry": [.garbage]]))
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.baselineSlides.count == 3)
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
    for p in d.plans { #expect(!flagged.contains(p.coverAssetID!.rawValue), "\(p.id) cover flagged") }
}

@Test func failedFirstPlannerCallIsRetriedAndBilled() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let model = FakeModel(["planner": [.incomplete]])
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: model)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(model.stages == ["occasion_split", "triage", "planner", "retry"])
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
    #expect(d.plans.allSatisfy { $0.slides.count <= 5 })
}

@Test func invalidSpineLeavesOnlyTheBaseline() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    // 6-photo spine against a 5-slide request stays invalid through repair and retry.
    let store = try await run(tmp, folder: try sceneFolder(tmp), model: FakeModel(), slides: 5)
    let d = try store.read(ConceptsReport.self, from: "plans/director.json")
    #expect(d.status == "fallback")
    #expect(d.plans.map(\.id) == ["baseline"])
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

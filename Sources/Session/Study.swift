import Core
import Foundation

/// Day-7 follow-up. Stores only structured answers: no post URLs, no free text.
public enum Followup {
    public static func record(runDirectory: URL, posted: Bool, platform: String?, reusedAnotherEvent: Bool?,
                              linkSeen: Bool?, now: Date = Date()) throws {
        let store = RunStore.open(runDirectory)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        let log = InteractionLog(url: store.url("interaction-events.jsonl"))
        let lastExport = log.read().filter { $0.event == "carousel_exported" || $0.event == "carousel_shared" }.map(\.timestamp).max()
        var answers = ["posted=\(posted ? "yes" : "no")"]
        if let platform { answers.append("platform=\(platform)") }
        if let reusedAnotherEvent { answers.append("reusedAnotherEvent=\(reusedAnotherEvent ? "yes" : "no")") }
        if let linkSeen { answers.append("linkSeen=\(linkSeen ? "yes" : "no")") }
        if let lastExport { answers.append("daysSinceExport=\(Int(now.timeIntervalSince(lastExport) / 86_400))") }
        try log.append(InteractionEvent(eventID: UUID().uuidString, runID: manifest.runID, timestamp: now,
                                        event: "followup_recorded", conceptID: nil, slideIndex: nil, assetIDs: nil,
                                        before: nil, after: answers, source: "operator"))
        try? RunReport.rebuild(runDirectory: runDirectory)
    }
}

/// Per-participant outcome and cohort go/no-go against the pre-registered bar (product spec §46, design spec §1.3).
public struct StudySummary: Codable, Sendable {
    public struct Participant: Codable, Sendable {
        public var studyCode: String
        public var runID: String
        public var runs: Int
        public var selectedConcept: String?
        public var exportedOrShared: Bool
        public var photoChangeFraction: Double
        public var slideRelayoutFraction: Double
        public var rerolled: Bool
        /// Threshold → success (selected + exported/shared + not substantially rebuilt).
        public var success: [String: Bool]
        public var postedWithin7Days: Bool
        public var followupRecorded: Bool
        public var repeatDemand: Bool
        public var costUSD: Double
        public var directorSeconds: Double
    }

    public var generatedAt: Date
    public var participants: [Participant]
    public var incompleteRunsSkipped: Int
    public var runsWithoutStudyCode: Int
    /// Threshold → share of participants meeting the minimum signal.
    public var minimumSignal: [String: Double]
    public var minimumSignalMet: Bool
    public var postedShare: Double
    public var strongSignalMet: Bool
    public var picks: [String: Int]
    public var medianPhotoChange: Double
    public var meanCostUSD: Double
    public var meanDirectorSeconds: Double

    public static let thresholds = [0.2, 0.3, 0.4]
    static func key(_ t: Double) -> String { String(format: "%.0f%%", t * 100) }

    public static func compute(runsDirectory: URL, now: Date = Date()) -> StudySummary {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        var incomplete = 0, uncoded = 0
        var byCode: [String: [(RunManifest, URL)]] = [:]
        for dir in dirs {
            guard let m = try? RunStore.open(dir).read(RunManifest.self, from: "manifest.json") else { continue }
            guard m.completedAt != nil else { incomplete += 1; continue }
            guard let code = m.studyCode else { uncoded += 1; continue }
            byCode[code, default: []].append((m, dir))
        }

        var participants: [Participant] = []
        for (code, runs) in byCode.sorted(by: { $0.key < $1.key }) {
            let ordered = runs.sorted { $0.0.createdAt < $1.0.createdAt }
            let (m, dir) = ordered[0]        // the participant's first run is the primary study run
            participants.append(participant(code: code, manifest: m, dir: dir, runCount: ordered.count))
        }

        let n = Double(max(1, participants.count))
        var minimum: [String: Double] = [:]
        for t in thresholds { minimum[key(t)] = Double(participants.filter { $0.success[key(t)] == true }.count) / n }
        let posted = Double(participants.filter(\.postedWithin7Days).count) / n
        var picks: [String: Int] = [:]
        for p in participants { if let c = p.selectedConcept { picks[c, default: 0] += 1 } }
        let changes = participants.map(\.photoChangeFraction).sorted()
        return StudySummary(
            generatedAt: now, participants: participants, incompleteRunsSkipped: incomplete, runsWithoutStudyCode: uncoded,
            minimumSignal: minimum, minimumSignalMet: !participants.isEmpty && (minimum[key(0.3)] ?? 0) >= 0.5,
            postedShare: posted, strongSignalMet: !participants.isEmpty && posted >= 1.0 / 3.0 - 1e-9, picks: picks,
            medianPhotoChange: changes.isEmpty ? 0 : changes[changes.count / 2],
            meanCostUSD: participants.map(\.costUSD).reduce(0, +) / n,
            meanDirectorSeconds: participants.map(\.directorSeconds).reduce(0, +) / n)
    }

    static func participant(code: String, manifest m: RunManifest, dir: URL, runCount: Int) -> Participant {
        let store = RunStore.open(dir)
        let events = InteractionLog(url: store.url("interaction-events.jsonl")).read()
        let selected = events.last { $0.event == "concept_selected" }?.conceptID
        let exported = selected.map { s in events.contains { ($0.event == "carousel_exported" || $0.event == "carousel_shared") && $0.conceptID == s } } ?? false
        let rerolled = selected.map { s in events.contains { $0.event == "concept_rerolled" && $0.conceptID == s } } ?? false

        var photoChange = 0.0, relayout = 0.0
        if let s = selected, let type = ConceptType(rawValue: s),
           let original = (try? store.read(ConceptsReport.self, from: "plans/director.json"))?.plans.first(where: { $0.conceptType == type }) {
            let final = (try? store.read(CarouselPlan.self, from: "edits/\(s)/plan.json")) ?? original
            let before = Set(original.photoAssetIDs), after = Set(final.photoAssetIDs)
            photoChange = before.isEmpty ? 0 : Double(before.subtracting(after).count) / Double(before.count)
            let finalSlides = final.slides.map { Set($0.photos.map(\.assetID)) }
            let changedSlides = original.slides.filter { !finalSlides.contains(Set($0.photos.map(\.assetID))) }.count
            relayout = rerolled ? 1 : Double(changedSlides) / Double(max(1, original.slides.count))
        }
        var success: [String: Bool] = [:]
        for t in thresholds {
            success[key(t)] = selected != nil && exported && photoChange <= t && relayout <= t
        }
        let followup = events.last { $0.event == "followup_recorded" }
        let answers = Dictionary((followup?.after ?? []).compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { _, b in b })
        let postedWithin7 = answers["posted"] == "yes" && (Int(answers["daysSinceExport"] ?? "0") ?? 0) <= 7
        return Participant(studyCode: code, runID: m.runID, runs: runCount, selectedConcept: selected, exportedOrShared: exported,
                           photoChangeFraction: photoChange, slideRelayoutFraction: relayout, rerolled: rerolled, success: success,
                           postedWithin7Days: postedWithin7, followupRecorded: followup != nil,
                           repeatDemand: runCount > 1 || answers["reusedAnotherEvent"] == "yes",
                           costUSD: m.totalEstimatedCost,
                           directorSeconds: m.stageTimings.first { $0.stage == "director" }?.seconds ?? 0)
    }

    public func markdown() -> String {
        func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
        var md = "# AK14 Phase 0 — study summary\n\nGenerated \(ISO8601DateFormatter().string(from: generatedAt)). "
        md += "\(participants.count) participants (by study code); \(incompleteRunsSkipped) incomplete runs and "
        md += "\(runsWithoutStudyCode) runs without a study code were not counted.\n\n## Go / no-go (pre-registered)\n\n"
        md += "| Signal | Bar | Result | Met |\n|---|---|---|---|\n"
        md += "| Minimum: selected + exported/shared, not substantially rebuilt (30% rule) | ≥ 50% | \(pct(minimumSignal[Self.key(0.3)] ?? 0)) | \(minimumSignalMet ? "yes" : "no") |\n"
        md += "| Strong: posted within 7 days | ≥ 33% | \(pct(postedShare)) | \(strongSignalMet ? "yes" : "no") |\n\n"
        md += "Sensitivity of the minimum signal: " + Self.thresholds.map { "\(Self.key($0)) rule → \(pct(minimumSignal[Self.key($0)] ?? 0))" }.joined(separator: ", ") + ".\n\n"
        md += "Concept picks: " + (picks.isEmpty ? "none" : picks.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        md += String(format: ". Median photos changed: %@. Mean model cost $%.4f, mean Director time %.0f s.\n\n", pct(medianPhotoChange), meanCostUSD, meanDirectorSeconds)
        md += "## Participants\n\n| Code | Runs | Selected | Exported/shared | Photos changed | Slides re-laid out | Success (30%) | Posted ≤7d | Follow-up | Repeat |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for p in participants {
            md += "| \(p.studyCode) | \(p.runs) | \(p.selectedConcept ?? "—") | \(p.exportedOrShared ? "yes" : "no") | \(pct(p.photoChangeFraction)) | "
            md += "\(pct(p.slideRelayoutFraction))\(p.rerolled ? " (rerolled)" : "") | \(p.success[Self.key(0.3)] == true ? "yes" : "no") | "
            md += "\(p.postedWithin7Days ? "yes" : "no") | \(p.followupRecorded ? "yes" : "pending") | \(p.repeatDemand ? "yes" : "no") |\n"
        }
        return md
    }
}

/// Participant data deletion (spec §10.5): the run directory, and optionally cache entries no other run uses.
public enum RunDeletion {
    /// Returns the number of cache files removed.
    @discardableResult
    public static func delete(runDirectory: URL, cacheDirectory: URL?) throws -> Int {
        let fm = FileManager.default
        let runs = runDirectory.deletingLastPathComponent()
        let shas = Set((try? RunStore.open(runDirectory).read(IngestResult.self, from: "input-index.json"))?.photos.map(\.contentSHA256) ?? [])
        try fm.removeItem(at: runDirectory)
        guard let cacheDirectory, !shas.isEmpty else { return 0 }
        var stillUsed = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? [] {
            if let index = try? RunStore.open(dir).read(IngestResult.self, from: "input-index.json") {
                stillUsed.formUnion(index.photos.map(\.contentSHA256))
            }
        }
        let purge = shas.subtracting(stillUsed)
        var removed = 0
        if let walker = fm.enumerator(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where purge.contains(url.deletingPathExtension().lastPathComponent) {
                try fm.removeItem(at: url); removed += 1
            }
        }
        return removed
    }
}

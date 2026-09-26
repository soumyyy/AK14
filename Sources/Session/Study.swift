import Core
import Foundation

/// Day-7 follow-up. Stores only structured answers: no post URLs, no free text.
public enum Followup {
    /// `postedDaysAfterHandoff`: how many days after receiving the carousel the participant posted (required when posted).
    public static func record(runDirectory: URL, posted: Bool, postedDaysAfterHandoff: Int?, platform: String?,
                              reusedAnotherEvent: Bool?, linkSeen: Bool?, now: Date = Date()) throws {
        let store = RunStore.open(runDirectory)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        var answers = ["posted=\(posted ? "yes" : "no")"]
        if let d = postedDaysAfterHandoff { answers.append("postedDays=\(d)") }
        if let platform { answers.append("platform=\(platform)") }
        if let reusedAnotherEvent { answers.append("reusedAnotherEvent=\(reusedAnotherEvent ? "yes" : "no")") }
        if let linkSeen { answers.append("linkSeen=\(linkSeen ? "yes" : "no")") }
        try InteractionLog(url: store.url("interaction-events.jsonl")).append(InteractionEvent(
            eventID: UUID().uuidString, runID: manifest.runID, timestamp: now, event: "followup_recorded", conceptID: nil,
            slideIndex: nil, assetIDs: nil, before: nil, after: answers, source: "operator"))
        try? RunReport.rebuild(runDirectory: runDirectory)
    }
}

/// Per-participant outcome and cohort go/no-go against the pre-registered bar (docs/study/protocol.md).
public struct StudySummary: Codable, Sendable {
    public struct Participant: Codable, Sendable {
        public var studyCode: String
        public var runID: String
        /// Eligible study runs (consented, with concepts) for this code.
        public var runs: Int
        public var selectedConcept: String?
        /// Whether the selected carousel was the photos-only baseline control.
        public var selectedBaseline: Bool?
        /// Style axes of the selected carousel ("grouping=collage", …); empty for the baseline and legacy plans.
        public var selectedStyle: [String]
        public var exportedOrShared: Bool
        /// nil when the handed-off plan could not be read (counted as not successful).
        public var photoChangeFraction: Double?
        public var slideRelayoutFraction: Double?
        public var rerolledBeforeHandoff: Bool
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
    public var ineligibleRunsSkipped: Int
    public var runsWithoutStudyCode: Int
    public var minimumSignal: [String: Double]
    public var minimumSignalMet: Bool
    public var postedShare: Double
    public var strongSignalMet: Bool
    /// Participants who selected the photos-only baseline / a designed direction.
    public var baselinePicked: Int
    public var directionPicked: Int
    /// How often each style axis value appears among selected directions ("density=dense": 2, …).
    public var pickedStyles: [String: Int]
    public var medianPhotoChange: Double
    public var meanCostUSD: Double
    public var meanDirectorSeconds: Double

    public static let thresholds = [0.2, 0.3, 0.4]
    static func key(_ t: Double) -> String { String(format: "%.0f%%", t * 100) }

    struct Run { let manifest: RunManifest; let dir: URL; let events: [InteractionEvent] }

    public static func compute(runsDirectory: URL, now: Date = Date()) -> StudySummary {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        var incomplete = 0, ineligible = 0, uncoded = 0
        var byCode: [String: [Run]] = [:]
        for dir in dirs {
            let store = RunStore.open(dir)
            guard let m = try? store.read(RunManifest.self, from: "manifest.json") else { continue }
            guard m.completedAt != nil else { incomplete += 1; continue }
            guard let code = m.studyCode else { uncoded += 1; continue }
            // A study run needs consent and concepts; failed / no-consent / --no-llm runs are neither the study run nor repeat demand.
            let concepts = try? store.read(ConceptsReport.self, from: "plans/director.json")
            guard m.consent != nil, let concepts, !concepts.plans.isEmpty else { ineligible += 1; continue }
            byCode[code, default: []].append(Run(manifest: m, dir: dir, events: InteractionLog(url: store.url("interaction-events.jsonl")).read()))
        }

        var participants: [Participant] = []
        for (code, runs) in byCode.sorted(by: { $0.key < $1.key }) {
            let ordered = runs.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
            participants.append(participant(code: code, runs: ordered))
        }

        let n = Double(max(1, participants.count))
        var minimum: [String: Double] = [:]
        for t in thresholds { minimum[key(t)] = Double(participants.filter { $0.success[key(t)] == true }.count) / n }
        let posted = Double(participants.filter(\.postedWithin7Days).count) / n
        var styles: [String: Int] = [:]
        for p in participants { for axis in p.selectedStyle { styles[axis, default: 0] += 1 } }
        let changes = participants.compactMap(\.photoChangeFraction).sorted()
        let median = changes.isEmpty ? 0 : changes.count % 2 == 1 ? changes[changes.count / 2]
            : (changes[changes.count / 2 - 1] + changes[changes.count / 2]) / 2
        return StudySummary(
            generatedAt: now, participants: participants, incompleteRunsSkipped: incomplete, ineligibleRunsSkipped: ineligible,
            runsWithoutStudyCode: uncoded, minimumSignal: minimum,
            minimumSignalMet: !participants.isEmpty && (minimum[key(0.3)] ?? 0) >= 0.5,
            postedShare: posted, strongSignalMet: !participants.isEmpty && posted >= 0.33,
            baselinePicked: participants.filter { $0.selectedBaseline == true }.count,
            directionPicked: participants.filter { $0.selectedBaseline == false }.count,
            pickedStyles: styles, medianPhotoChange: median,
            meanCostUSD: participants.map(\.costUSD).reduce(0, +) / n,
            meanDirectorSeconds: participants.map(\.directorSeconds).reduce(0, +) / n)
    }

    /// The participant's first eligible run is the study run; later eligible runs are repeat demand.
    static func participant(code: String, runs: [Run]) -> Participant {
        let primary = runs[0], m = primary.manifest, events = primary.events
        let store = RunStore.open(primary.dir)
        let selected = events.last { $0.event == "concept_selected" }?.conceptID
        // The hand-off that counts: the last export/share of the selected concept.
        let handoff = selected.flatMap { s in
            events.last { ($0.event == "carousel_exported" || $0.event == "carousel_shared") && $0.conceptID == s }
        }
        // Log order, not timestamps: events are appended in order, while stored times only have one-second precision.
        let handoffIndex = handoff.flatMap { h in events.lastIndex { $0.eventID == h.eventID } }
        let rerolled = handoffIndex.map { i in events[..<i].contains { $0.event == "concept_rerolled" && $0.conceptID == handoff?.conceptID } } ?? false

        var photoChange: Double?, relayout: Double?
        let selectedPlan = selected.flatMap { (try? store.read(ConceptsReport.self, from: "plans/director.json"))?.plan($0) }
        if let s = selected, let handoff, let original = selectedPlan {
            let snapshotID = handoff.after?.first { $0.hasPrefix("snapshot=") }.map { String($0.dropFirst("snapshot=".count)) }
            // Scored on exactly what was handed off. Older runs without a snapshot fall back to the current plan.
            let handed = snapshotID.flatMap { try? store.read(CarouselPlan.self, from: "handoffs/\(s)-\($0).json") }
                ?? (try? store.read(CarouselPlan.self, from: "edits/\(s)/plan.json")) ?? original
            let before = Set(original.photoAssetIDs), after = Set(handed.photoAssetIDs)
            photoChange = before.isEmpty ? 0 : Double(before.subtracting(after).count) / Double(before.count)
            let handedSlides = handed.slides.map { Set($0.photos.map(\.assetID)) }
            let changed = original.slides.filter { !handedSlides.contains(Set($0.photos.map(\.assetID))) }.count
            relayout = rerolled ? 1 : Double(changed) / Double(max(1, original.slides.count))
        }
        var success: [String: Bool] = [:]
        for t in thresholds {
            success[key(t)] = handoff != nil && (photoChange.map { $0 <= t } ?? false) && (relayout.map { $0 <= t } ?? false)
        }

        // Follow-up may have been recorded on any of the participant's runs; the latest answer wins.
        let followup = runs.flatMap { $0.events.filter { $0.event == "followup_recorded" } }.max { $0.timestamp < $1.timestamp }
        let answers = Dictionary((followup?.after ?? []).compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { _, b in b })
        let postedDays = answers["postedDays"].flatMap { Int($0) }
        let postedWithin7 = handoff != nil && answers["posted"] == "yes" && postedDays.map { (0...7).contains($0) } == true

        let style = selectedPlan?.isBaseline == false ? selectedPlan?.style : nil
        let axes = style.map { v in zip(StyleVector.axes.map(\.name), [v.density, v.overlap, v.grouping, v.decoration, v.rotation, v.whitespace])
            .map { "\($0)=\($1)" } } ?? []
        return Participant(studyCode: code, runID: m.runID, runs: runs.count, selectedConcept: selected,
                           selectedBaseline: selectedPlan?.isBaseline, selectedStyle: axes,
                           exportedOrShared: handoff != nil, photoChangeFraction: photoChange, slideRelayoutFraction: relayout,
                           rerolledBeforeHandoff: rerolled, success: success, postedWithin7Days: postedWithin7,
                           followupRecorded: followup != nil,
                           repeatDemand: runs.count > 1 || answers["reusedAnotherEvent"] == "yes",
                           costUSD: m.totalEstimatedCost,
                           directorSeconds: m.stageTimings.first { $0.stage == "director" }?.seconds ?? 0)
    }

    public func markdown() -> String {
        func pct(_ x: Double?) -> String { x.map { String(format: "%.0f%%", $0 * 100) } ?? "unknown" }
        var md = "# AK14 Phase 0 — study summary\n\nGenerated \(ISO8601DateFormatter().string(from: generatedAt)). "
        md += "\(participants.count) participants (by study code). Not counted: \(incompleteRunsSkipped) incomplete runs, "
        md += "\(ineligibleRunsSkipped) runs without consent or concepts, \(runsWithoutStudyCode) runs without a study code.\n\n"
        md += "## Go / no-go (pre-registered)\n\n| Signal | Bar | Result | Met |\n|---|---|---|---|\n"
        md += "| Minimum: selected + exported/shared, not substantially rebuilt (30% rule) | ≥ 50% | \(pct(minimumSignal[Self.key(0.3)] ?? 0)) | \(minimumSignalMet ? "yes" : "no") |\n"
        md += "| Strong: posted within 7 days | ≥ 33% | \(pct(postedShare)) | \(strongSignalMet ? "yes" : "no") |\n\n"
        md += "Sensitivity of the minimum signal: " + Self.thresholds.map { "\(Self.key($0)) rule → \(pct(minimumSignal[Self.key($0)] ?? 0))" }.joined(separator: ", ") + ".\n\n"
        md += "Picks: baseline (photos only) \(baselinePicked), designed direction \(directionPicked). Styles picked: "
        md += pickedStyles.isEmpty ? "none" : pickedStyles.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        md += String(format: ". Median photos changed: %@. Mean model cost $%.4f, mean Director time %.0f s.\n\n", pct(medianPhotoChange), meanCostUSD, meanDirectorSeconds)
        md += "## Participants\n\n| Code | Runs | Selected | Handed off | Photos changed | Slides re-laid out | Success (30%) | Posted ≤7d | Follow-up | Repeat |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for p in participants {
            md += "| \(p.studyCode) | \(p.runs) | \(p.selectedConcept ?? "—") | \(p.exportedOrShared ? "yes" : "no") | \(pct(p.photoChangeFraction)) | "
            md += "\(pct(p.slideRelayoutFraction))\(p.rerolledBeforeHandoff ? " (rerolled)" : "") | \(p.success[Self.key(0.3)] == true ? "yes" : "no") | "
            md += "\(p.postedWithin7Days ? "yes" : "no") | \(p.followupRecorded ? "yes" : "pending") | \(p.repeatDemand ? "yes" : "no") |\n"
        }
        return md
    }
}

/// Participant data deletion (spec §10.5).
public enum RunDeletion {
    public enum Failure: Error, CustomStringConvertible {
        case notARun(String), containsRuns(String)
        public var description: String {
            switch self {
            case .notARun(let p): "'\(p)' is not an AK14 run (no readable manifest.json); nothing deleted"
            case .containsRuns(let p): "'\(p)' contains other runs; pass a single run directory or --study-code"
            }
        }
    }

    /// Deletes one run directory, and optionally cache entries no other run uses. Returns cache files removed.
    @discardableResult
    public static func delete(runDirectory: URL, cacheDirectory: URL?) throws -> Int {
        try validate(runDirectory)
        return try purge([runDirectory], runsRoot: runDirectory.deletingLastPathComponent(), cacheDirectory: cacheDirectory)
    }

    /// Deletes every run (complete or not) recorded under `studyCode`. Returns (runs deleted, cache files removed).
    @discardableResult
    public static func delete(studyCode: String, runsDirectory: URL, cacheDirectory: URL?) throws -> (runs: Int, cacheFiles: Int) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        let matches = dirs.filter { (try? RunStore.open($0).read(RunManifest.self, from: "manifest.json"))?.studyCode == studyCode }
        return (matches.count, try purge(matches, runsRoot: runsDirectory, cacheDirectory: cacheDirectory))
    }

    static func validate(_ dir: URL) throws {
        let fm = FileManager.default
        guard (try? RunStore.open(dir).read(RunManifest.self, from: "manifest.json")) != nil else { throw Failure.notARun(dir.lastPathComponent) }
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if children.contains(where: { fm.fileExists(atPath: $0.appending(path: "manifest.json").path) }) { throw Failure.containsRuns(dir.lastPathComponent) }
    }

    static func purge(_ runs: [URL], runsRoot: URL, cacheDirectory: URL?) throws -> Int {
        let fm = FileManager.default
        var shas = Set<String>()
        for run in runs {
            try validate(run)
            shas.formUnion((try? RunStore.open(run).read(IngestResult.self, from: "input-index.json"))?.photos.map(\.contentSHA256) ?? [])
            try fm.removeItem(at: run)
        }
        guard let cacheDirectory, !shas.isEmpty, fm.fileExists(atPath: cacheDirectory.path) else { return 0 }
        var stillUsed = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: runsRoot, includingPropertiesForKeys: nil)) ?? [] {
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

import Core
import Foundation
import Render

enum EvalCommand {
    static func pairs(runDirectories: [URL], out: URL, seed: UInt64 = 14) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: out.appending(path: "strips"), withIntermediateDirectories: true)
        var records: [(id: String, root: URL, report: ConceptsReport)] = []
        for root in runDirectories {
            let report = try JSONCoding.decoder.decode(ConceptsReport.self, from: Data(contentsOf: root.appending(path: "plans/director.json")))
            records.append((root.lastPathComponent, root, report))
        }
        var stripMap: [String: String] = [:]
        var pairs: [EvalPair] = []
        for run in records {
            let plans = run.report.plans
            let inputIndexURL = run.root.appending(path: "input-index.json")
            let indexedPhotos = (try? JSONCoding.decoder.decode(IngestResult.self, from: Data(contentsOf: inputIndexURL)).photos)
                ?? (try? JSONCoding.decoder.decode([PhotoRecord].self, from: Data(contentsOf: inputIndexURL))) ?? []
            let photos = Dictionary(uniqueKeysWithValues: indexedPhotos.map { ($0.assetID, $0) })
            func thumb(_ id: AssetID) -> URL? {
                guard photos[id] != nil else { return nil }
                let url = run.root.appending(path: "cache/thumbnails/analysis/\(id.rawValue).jpg")
                return fm.fileExists(atPath: url.path) ? url : nil
            }
            func add(_ stage: EvalPair.Stage, _ leftID: String, _ leftAssets: [AssetID], _ rightID: String, _ rightAssets: [AssetID],
                    leftGroups: [[AssetID]]? = nil, rightGroups: [[AssetID]]? = nil) throws {
                guard !leftAssets.isEmpty, !rightAssets.isEmpty else { return }
                let refs = [CandidateRef(carouselID: leftID, compositionSeed: "0", runID: run.id), CandidateRef(carouselID: rightID, compositionSeed: "0", runID: run.id)]
                let sides = [leftAssets, rightAssets]
                for (i, ref) in refs.enumerated() {
                    let urls = sides[i].compactMap(thumb)
                    guard !urls.isEmpty else { return }
                    let assetGroups = (i == 0 ? leftGroups : rightGroups) ?? [sides[i]]
                    let urlGroups = assetGroups.map { $0.compactMap(thumb) }.filter { !$0.isEmpty }
                    let key = "\(run.id)/\(stage.rawValue)/\(ref.carouselID)"
                    let name = "\(run.id)-\(stage.rawValue)-\(ref.carouselID).jpg"
                    let data = (stage == .split && urlGroups.count > 1)
                        ? try StripRenderer().strip(groups: urlGroups, height: 128, quality: 0.82)
                        : try StripRenderer().strip(slides: urls, height: stage == .cover ? 420 : 128, quality: 0.82)
                    try data.write(to: out.appending(path: "strips/\(name)"), options: .atomic)
                    stripMap[key] = "strips/\(name)"
                }
                pairs.append(EvalPair(pairID: "\(run.id)-\(stage.rawValue)-\(pairs.filter { $0.runID == run.id && $0.stage == stage }.count + 1)", runID: run.id, stage: stage, left: refs[0], right: refs[1]))
            }
            if let spine = run.report.spine?.orderedAssetIDs, let ranked = try? JSONCoding.decoder.decode(ReductionResult.self, from: Data(contentsOf: run.root.appending(path: "cache/reduction.json"))) {
                let top = Array(ranked.ranked.map(\.assetID).prefix(spine.count))
                if top.count == spine.count && top != spine { try add(.selection, "model-spine", spine, "ranked-spine", top) }
            }
            let covers = plans.compactMap { $0.coverAssetID.map { ($0, $0) } }
            if covers.count >= 2 { try add(.cover, "cover-\(covers[0].0.rawValue)", [covers[0].1], "cover-\(covers[1].0.rawValue)", [covers[1].1]) }
            if let manifest = try? JSONCoding.decoder.decode(RunManifest.self, from: Data(contentsOf: run.root.appending(path: "manifest.json"))), manifest.events.count > 1,
               let all = run.report.spine?.orderedAssetIDs, !all.isEmpty, !indexedPhotos.isEmpty {
                let groups = EventSegmenter.segment(indexedPhotos).map { event in
                    all.filter { event.assetIDs.contains($0) }
                }.filter { !$0.isEmpty }
                if groups.count > 1 {
                    try add(.split, "event-groups", groups.flatMap { $0 }, "single-group", all,
                            leftGroups: groups, rightGroups: [all])
                }
            }
            for plan in plans {
                guard let paths = run.report.renderedSlides[plan.id], !paths.isEmpty else { continue }
                let filename = "\(run.id)-\(plan.id).jpg"
                let data = try StripRenderer().strip(slides: paths.map { run.root.appending(path: $0) }, quality: 0.75)
                try data.write(to: out.appending(path: "strips/\(filename)"), options: .atomic)
                stripMap["\(run.id)/\(plan.id)"] = "strips/\(filename)"
            }
            let candidates = plans.filter { stripMap["\(run.id)/\($0.id)"] != nil }
            let baseline = candidates.first(where: \.isBaseline)
            var combinations: [(CarouselPlan, CarouselPlan)] = []
            for i in candidates.indices { for j in candidates.indices where j > i { combinations.append((candidates[i], candidates[j])) } }
            if let baseline {
                for plan in candidates where plan.id != baseline.id && !combinations.contains(where: { $0.0.id == plan.id && $0.1.id == baseline.id || $0.1.id == plan.id && $0.0.id == baseline.id }) {
                    combinations.append((plan, baseline))
                }
            }
            for (index, combo) in combinations.enumerated() {
                func ref(_ p: CarouselPlan) -> CandidateRef {
                    CandidateRef(carouselID: p.id, compositionSeed: p.compositionSeed ?? "0", runID: run.id)
                }
                pairs.append(EvalPair(pairID: "\(run.id)-layout-\(index + 1)", runID: run.id, stage: .layout, left: ref(combo.0), right: ref(combo.1)))
            }
        }
        var rng = SeededRandom(seed: seed)
        for i in pairs.indices where rng.next() & 1 == 1 { (pairs[i].left, pairs[i].right) = (pairs[i].right, pairs[i].left) }
        let set = EvalSet(seed: String(seed, radix: 16), createdAt: Date(timeIntervalSince1970: 0), runs: records.map { $0.root.path }, pairs: pairs,
                          strips: stripMap, versions: ["composer": "composer-1", "layout": ResolvedCarousel.resolverVersion])
        try JSONCoding.encoder.encode(set).write(to: out.appending(path: "evalset.json"), options: .atomic)
    }

    static func label(evalDirectory: URL, rater: String) throws {
        let set = try readSet(evalDirectory)
        let pairsJSON = String(data: try JSONCoding.encoder.encode(set.pairs), encoding: .utf8)!
        let embeddedStrips = try set.strips.mapValues { path in
            "data:image/jpeg;base64," + (try Data(contentsOf: evalDirectory.appending(path: path))).base64EncodedString()
        }
        let stripsJSON = String(data: try JSONCoding.encoder.encode(embeddedStrips), encoding: .utf8)!
        let versionsJSON = String(data: try JSONCoding.encoder.encode(set.versions), encoding: .utf8)!
        let html = #"""
        <!doctype html><meta charset="utf-8"><title>AK14 Eval</title><style>body{font:16px system-ui;max-width:1200px;margin:2rem auto;background:#f5f3ee;color:#222}main{display:flex;gap:1rem;align-items:center}figure{margin:0;flex:1}img{width:100%;height:auto}button{padding:.8rem 1.2rem;font:inherit;margin:.5rem}#status{margin:1rem 0}</style>
        <h1>Carousel preference</h1><div id="status"></div><main><figure><figcaption>Left</figcaption><img id="left"></figure><figure><figcaption>Right</figcaption><img id="right"></figure></main>
        <button onclick="choose('left')">Left ←</button><button onclick="choose('right')">Right →</button><button onclick="choose('tie')">Can't choose (space)</button><button onclick="choose('neither')">Neither is postable (n)</button><button onclick="exportLabels()">Export</button>
        <script>const pairs=__PAIRS__,strips=__STRIPS__,versions=__VERSIONS__,rater=__RATER__;let i=0;const key='ak14-eval-'+rater;let labels=JSON.parse(localStorage.getItem(key)||'[]');function sk(p,r){return strips[p.runID+'/'+p.stage+'/'+r.carouselID]||strips[p.runID+'/'+r.carouselID]}function question(s){return ({split:'Which grouping tells the better story?',selection:'Which photo set tells the better story?',cover:'Which cover is more compelling?',layout:'Which carousel layout is better?'})[s]}function render(){while(i<pairs.length&&labels.some(x=>x.pairID===pairs[i].pairID))i++;if(i>=pairs.length){document.querySelector('#status').textContent='Complete';return}const p=pairs[i];document.querySelector('#status').textContent=`${p.stage} · ${question(p.stage)} · Pair ${i+1} of ${pairs.length}`;document.querySelector('#left').src=sk(p,p.left);document.querySelector('#right').src=sk(p,p.right)}function choose(choice){if(i>=pairs.length)return;const p=pairs[i];labels.push({pairID:p.pairID,rater,choice,shownLeft:p.left,decidedAt:new Date().toISOString(),versions});localStorage.setItem(key,JSON.stringify(labels));i++;render()}function exportLabels(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(labels,null,2)],{type:'application/json'}));a.download='labels-'+rater+'.json';a.click();URL.revokeObjectURL(a.href)}document.addEventListener('keydown',e=>{if(e.key==='ArrowLeft')choose('left');else if(e.key==='ArrowRight')choose('right');else if(e.key===' ')choose('tie');else if(e.key.toLowerCase()==='n')choose('neither')});render();</script>
        """#.replacingOccurrences(of: "__PAIRS__", with: pairsJSON).replacingOccurrences(of: "__STRIPS__", with: stripsJSON)
            .replacingOccurrences(of: "__VERSIONS__", with: versionsJSON).replacingOccurrences(of: "__RATER__", with: String(data: try JSONCoding.encoder.encode(rater), encoding: .utf8)!)
        try Data(html.utf8).write(to: evalDirectory.appending(path: "index.html"), options: .atomic)
    }

    static func importLabels(evalDirectory: URL, file: URL) throws {
        let set = try readSet(evalDirectory)
        let labels = try JSONCoding.decoder.decode([EvalLabel].self, from: Data(contentsOf: file))
        let ids = Set(set.pairs.map(\.pairID))
        guard labels.allSatisfy({ label in
            ids.contains(label.pairID) && !label.rater.isEmpty && set.pairs.first(where: { $0.pairID == label.pairID })?.left == label.shownLeft
        }) else { throw EvalError.invalidLabels }
        let dir = evalDirectory.appending(path: "labels"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: file.lastPathComponent)
        if fmExists(target) {
            let old = try JSONCoding.decoder.decode([EvalLabel].self, from: Data(contentsOf: target))
            try JSONCoding.encoder.encode(old.filter { prior in !labels.contains(where: { $0.pairID == prior.pairID && $0.rater == prior.rater }) } + labels).write(to: target, options: .atomic)
        } else { try JSONCoding.encoder.encode(labels).write(to: target, options: .atomic) }
    }

    static func score(evalDirectory: URL, stage selectedStage: EvalPair.Stage? = nil) throws -> String {
        let set = try readSet(evalDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: evalDirectory.appending(path: "labels"), includingPropertiesForKeys: nil)) ?? []
        var all: [EvalLabel] = []
        for file in files where file.pathExtension == "json" { all += try JSONCoding.decoder.decode([EvalLabel].self, from: Data(contentsOf: file)) }
        if let selectedStage {
            let selectedIDs = Set(set.pairs.filter { $0.stage == selectedStage }.map(\.pairID))
            all = all.filter { selectedIDs.contains($0.pairID) }
        }
        var cache: [String: (Double, String)] = [:]
        for runPath in set.runs {
            let root = URL(fileURLWithPath: runPath)
            let report = try JSONCoding.decoder.decode(ConceptsReport.self, from: Data(contentsOf: root.appending(path: "plans/director.json")))
            for p in report.plans {
                let layouts = report.renderedSlides[p.id]?.indices.compactMap { try? JSONCoding.decoder.decode(ResolvedSlide.self, from: Data(contentsOf: root.appending(path: String(format: "layouts/%@/slide-%02d.json", p.id, $0 + 1)))) } ?? []
                cache["\(root.lastPathComponent)/\(p.id)"] = (composerScore(p, layouts), root.lastPathComponent)
            }
        }
        var votes: [String: [Bool]] = [:], ties = 0
        let pairByID = Dictionary(uniqueKeysWithValues: set.pairs.map { ($0.pairID, $0) })
        for label in all {
            guard label.choice == .left || label.choice == .right else { if label.choice == .tie { ties += 1 }; continue }
            votes[label.pairID, default: []].append(label.choice == .left)
        }
        var pairCorrect: [Bool] = [], eventVotes: [String: [Bool]] = [:], majorityTies = 0
        for pairID in votes.keys.sorted() {
            let humanChoices = votes[pairID]!
            guard let pair = pairByID[pairID], let l = cache["\(pair.left.runID)/\(pair.left.carouselID)"], let r = cache["\(pair.right.runID)/\(pair.right.carouselID)"],
                  let chooserLeft = ComposerEvalChooser().prefersLeft(l.0, r.0) else { continue }
            let leftCount = humanChoices.filter { $0 }.count
            guard leftCount != humanChoices.count - leftCount else { majorityTies += 1; continue }
            let correct = (leftCount > humanChoices.count - leftCount) == chooserLeft
            pairCorrect.append(correct); eventVotes[pair.runID, default: []].append(correct)
        }
        ties += majorityTies
        let agreement = pairCorrect.isEmpty ? 0 : Double(pairCorrect.filter { $0 }.count) / Double(pairCorrect.count)
        var rng = SeededRandom(seed: UInt64(set.seed, radix: 16) ?? 14); var samples: [Double] = []
        if !pairCorrect.isEmpty { for _ in 0..<2000 { var correct = 0; for _ in pairCorrect.indices { if pairCorrect[Int(rng.next() % UInt64(pairCorrect.count))] { correct += 1 } }; samples.append(Double(correct) / Double(pairCorrect.count)) } }
        samples.sort()
        let ci = samples.isEmpty ? [0, 0] : [samples[Int(Double(samples.count - 1) * 0.025)], samples[Int(Double(samples.count - 1) * 0.975)]]
        let tieEvents = Dictionary(grouping: all.filter { $0.choice == .tie }, by: { label in pairByID[label.pairID]?.runID ?? "unknown" }).mapValues(\.count)
        let events = Set(eventVotes.keys).union(tieEvents.keys).sorted().map { key in
            let v = eventVotes[key] ?? []
            return EvalReport.Event(event: key, agreement: v.isEmpty ? 0 : Double(v.filter { $0 }.count) / Double(v.count), labelledPairs: v.count, ties: tieEvents[key] ?? 0)
        }
        let report = EvalReport(agreement: agreement, confidenceInterval: ci, labelledPairs: pairCorrect.count, ties: ties, events: events)
        let stagePairs = set.pairs.filter { selectedStage == nil || $0.stage == selectedStage }
        let stageLabels = all.filter { label in stagePairs.contains(where: { $0.pairID == label.pairID }) }
        let summaries = (selectedStage.map { [$0] } ?? EvalPair.Stage.allCases).map { stage in
            let pairs = stagePairs.filter { $0.stage == stage }
            let labels = stageLabels.filter { label in pairs.contains(where: { $0.pairID == label.pairID }) }
            let neither = labels.filter { $0.choice == .neither }.count
            var agreed = 0, compared = 0
            for pair in pairs {
                let choices = labels.filter { $0.pairID == pair.pairID }.map(\.choice).filter { $0 == .left || $0 == .right }
                guard !choices.isEmpty else { continue }
                let l = choices.filter { $0 == .left }.count, r = choices.count - l
                guard l != r else { continue }
                compared += 1; if max(l, r) == choices.count { agreed += 1 }
            }
            return EvalReport.StageSummary(stage: stage, agreement: compared == 0 ? 0 : Double(agreed) / Double(compared),
                                           neitherRate: labels.isEmpty ? 0 : Double(neither) / Double(labels.count), labelledPairs: labels.count, neither: neither)
        }
        var finalReport = report; finalReport.stages = summaries
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let markdown = "# Eval report\n\nAgreement: \(agreement) (95% bootstrap CI \(ci[0])–\(ci[1]))\n\nLabelled pairs: \(pairCorrect.count)\nTies: \(ties)\n\n| Stage | Agreement | Neither rate | Labelled | Neither |\n|---|---:|---:|---:|---:|\n" + summaries.map { "| \($0.stage.rawValue) | \($0.agreement) | \($0.neitherRate) | \($0.labelledPairs) | \($0.neither) |" }.joined(separator: "\n") + "\n\n| Event | Agreement | Pairs |\n|---|---:|---:|\n" + events.map { "| \($0.event) | \($0.agreement) | \($0.labelledPairs) |" }.joined(separator: "\n") + "\n"
        let reportDir = evalDirectory.appending(path: "eval")
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: reportDir.appending(path: "report-\(stamp).md"), options: .atomic)
        try JSONCoding.encoder.encode(finalReport).write(to: reportDir.appending(path: "report.json"), options: .atomic)
        return "Agreement: \(agreement) (95% CI \(ci[0])–\(ci[1])); \(pairCorrect.count) pairs; \(ties) ties\n" + summaries.map { "\($0.stage.rawValue): agreement \($0.agreement), neither rate \($0.neitherRate)" }.joined(separator: "\n")
    }

    private static func composerScore(_ plan: CarouselPlan, _ slides: [ResolvedSlide]) -> Double {
        guard !slides.isEmpty else { return .infinity }
        var perSlide = 0.0, coverageGap = 0.0, framed = 0.0
        for (slide, planned) in zip(slides, plan.slides) {
            guard let m = slide.metrics else { perSlide += 2; continue }
            perSlide += 0.8 * m.maxCropLoss
            if slide.warnings.contains(where: { $0.contains("people are cropped") }) { perSlide += 1 }
            if slide.warnings.contains(where: { $0.contains("could not fully") }) { perSlide += 1 }
            if let share = m.heroShare, share < 1.3 { perSlide += 1.3 - share }
            if slide.primitive != .fullBleed {
                let target = planned.density == "quiet" ? 0.52 : planned.density == "dense" ? 0.78 : 0.64
                coverageGap += abs(m.coverage - target); framed += 1
            }
        }
        var total = perSlide / Double(slides.count) + 0.8 * (framed > 0 ? coverageGap / framed : 0)
        let families = slides.compactMap { $0.variant?.split(separator: ".").prefix(2).joined(separator: ".") }
        let repeats = zip(families, families.dropFirst()).filter { $0 == $1 && $0 != "bleed" }.count
        total += 0.25 * Double(repeats) / Double(max(1, slides.count - 1))
        if let cover = slides.first?.metrics, cover.coverage < 0.45 { total += 0.3 }
        let target = plan.style?.grouping == "collage" ? 0.6 : plan.style?.grouping == "mixed" ? 0.35 : 0
        if slides.count > 1 { total += abs(Double(plan.slides.filter { $0.photos.count > 1 }.count) / Double(slides.count) - target) }
        return total
    }

    private static func readSet(_ dir: URL) throws -> EvalSet { try JSONCoding.decoder.decode(EvalSet.self, from: Data(contentsOf: dir.appending(path: "evalset.json"))) }
    private static func fmExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    enum EvalError: Error { case invalidLabels }
}

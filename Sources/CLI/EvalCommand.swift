import Core
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

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
            for plan in plans {
                guard let paths = run.report.renderedSlides[plan.id], !paths.isEmpty else { continue }
                let filename = "\(run.id)-\(plan.id).jpg"
                try makeStrip(paths.map { run.root.appending(path: $0) }, to: out.appending(path: "strips/\(filename)"))
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
                pairs.append(EvalPair(pairID: "\(run.id)-\(index + 1)", runID: run.id, left: ref(combo.0), right: ref(combo.1)))
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
        <button onclick="choose('left')">Left ←</button><button onclick="choose('right')">Right →</button><button onclick="choose('tie')">Can't choose (space)</button><button onclick="exportLabels()">Export</button>
        <script>const pairs=__PAIRS__,strips=__STRIPS__,versions=__VERSIONS__,rater=__RATER__;let i=0;const key='ak14-eval-'+rater;let labels=JSON.parse(localStorage.getItem(key)||'[]');function render(){while(i<pairs.length&&labels.some(x=>x.pairID===pairs[i].pairID))i++;if(i>=pairs.length){document.querySelector('#status').textContent='Complete';return}const p=pairs[i];document.querySelector('#status').textContent=`Pair ${i+1} of ${pairs.length}`;document.querySelector('#left').src=strips[p.left.runID+'/'+p.left.carouselID];document.querySelector('#right').src=strips[p.right.runID+'/'+p.right.carouselID]}function choose(choice){const p=pairs[i];labels.push({pairID:p.pairID,rater,choice,shownLeft:p.left,decidedAt:new Date().toISOString(),versions});localStorage.setItem(key,JSON.stringify(labels));i++;render()}function exportLabels(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(labels,null,2)],{type:'application/json'}));a.download='labels-'+rater+'.json';a.click();URL.revokeObjectURL(a.href)}document.addEventListener('keydown',e=>{if(e.key==='ArrowLeft')choose('left');else if(e.key==='ArrowRight')choose('right');else if(e.key===' ')choose('tie')});render();</script>
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

    static func score(evalDirectory: URL) throws -> String {
        let set = try readSet(evalDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: evalDirectory.appending(path: "labels"), includingPropertiesForKeys: nil)) ?? []
        var all: [EvalLabel] = []
        for file in files where file.pathExtension == "json" { all += try JSONCoding.decoder.decode([EvalLabel].self, from: Data(contentsOf: file)) }
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
            guard label.choice != .tie else { ties += 1; continue }
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
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let markdown = "# Eval report\n\nAgreement: \(agreement) (95% bootstrap CI \(ci[0])–\(ci[1]))\n\nLabelled pairs: \(pairCorrect.count)\nTies: \(ties)\n\n| Event | Agreement | Pairs |\n|---|---:|---:|\n" + events.map { "| \($0.event) | \($0.agreement) | \($0.labelledPairs) |" }.joined(separator: "\n") + "\n"
        let reportDir = evalDirectory.appending(path: "eval")
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: reportDir.appending(path: "report-\(stamp).md"), options: .atomic)
        try JSONCoding.encoder.encode(report).write(to: reportDir.appending(path: "report.json"), options: .atomic)
        return "Agreement: \(agreement) (95% CI \(ci[0])–\(ci[1])); \(pairCorrect.count) pairs; \(ties) ties"
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

    private static func makeStrip(_ paths: [URL], to url: URL) throws {
        let images = try paths.map { path -> CGImage in
            guard let source = CGImageSourceCreateWithURL(path as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw EvalError.image(path.path) }
            return image
        }
        let widths = images.map { max(1, Int((Double($0.width) * 96 / Double($0.height)).rounded())) }
        let width = widths.reduce(0, +) + max(0, images.count - 1) * 4
        guard let ctx = CGContext(data: nil, width: width, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EvalError.image(url.path) }
        ctx.setFillColor(CGColor(gray: 0.94, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: 96))
        var x = 0
        for (image, w) in zip(images, widths) { ctx.interpolationQuality = .high; ctx.draw(image, in: CGRect(x: x, y: 0, width: w, height: 96)); x += w + 4 }
        guard let result = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw EvalError.image(url.path) }
        CGImageDestinationAddImage(dest, result, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EvalError.image(url.path) }
    }

    private static func readSet(_ dir: URL) throws -> EvalSet { try JSONCoding.decoder.decode(EvalSet.self, from: Data(contentsOf: dir.appending(path: "evalset.json"))) }
    private static func fmExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    enum EvalError: Error { case invalidLabels, image(String) }
}

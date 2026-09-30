import Core
import Foundation
import Render
import Session

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

    static func compare(runDirectories: [URL], source: URL, out: URL, seed: UInt64 = 14,
                        loadDesignedPages: (() throws -> DesignedSetLibrary)? = nil) throws {
        let fm = FileManager.default
        var pairs: [EvalPair] = [], strips: [String: String] = [:]
        var skippedOptions = 0
        guard Set(runDirectories.map(\.lastPathComponent)).count == runDirectories.count else { throw EvalError.duplicateRuns }
        let inputPaths = runDirectories.map { $0.resolvingSymlinksInPath().path }
        let outputPath = out.resolvingSymlinksInPath().path
        let artifactPaths = runDirectories.map { out.appending(path: "runs/\($0.lastPathComponent)").resolvingSymlinksInPath().path }
        guard !inputPaths.contains(where: { input in
            outputPath == input || outputPath.hasPrefix(input + "/")
                || artifactPaths.contains { input == $0 || input.hasPrefix($0 + "/") }
        }) else { throw EvalError.overlappingOutput }
        try fm.createDirectory(at: out.appending(path: "strips"), withIntermediateDirectories: true)
        for run in runDirectories {
            let session = try RunSession(runDirectory: run)
            guard let spine = session.concepts.spine else { throw EvalError.noDirections(run.lastPathComponent) }
            let directions = session.concepts.plans.filter { !$0.isBaseline }.compactMap(\.direction)
            guard !directions.isEmpty else { throw EvalError.noDirections(run.lastPathComponent) }
            var context = session.compositionContext()
            if let loadDesignedPages { context.pages = try loadDesignedPages().vocabulary(for: context.aspect) }
            let newSet = ComposerEngine.composeSet(directions: directions, spine: spine, context: context, runID: session.runID)
            let runID = run.lastPathComponent
            let options = newSet.plans.filter { plan in
                guard !plan.isBaseline else { return false }
                guard !plan.slides.isEmpty, plan.slides.allSatisfy({ $0.placement != nil }) else {
                    skippedOptions += 1
                    FileHandle.standardError.write(Data("warning: \(runID)/\(plan.id): skipped option: template-first unavailable\n".utf8))
                    return false
                }
                return true
            }
            if options.isEmpty { print("\(runID): no template-first options available") }
            let folder = try RerenderCommand.verifiedSource(source, photos: context.photos,
                assetIDs: options.flatMap(\.photoAssetIDs))
            let root = out.appending(path: "runs/\(runID)")
            // Rebuilding the comparison replaces its own artifacts, never the original run.
            if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            for newPlan in options {
                guard let direction = newPlan.direction, let first = newPlan.photoAssetIDs.first else { continue }
                var legacyContext = context
                legacyContext.pages = []
                legacyContext.exactSet = true
                legacyContext.keepOrder = true
                let frozen = Direction(brief: direction.brief, style: direction.style, coverAssetID: first,
                    orderedAssetIDs: newPlan.photoAssetIDs, keepTogether: direction.keepTogether,
                    emphasisAssetIDs: direction.emphasisAssetIDs, seamless: direction.seamless, titleIdea: direction.titleIdea)
                let layoutSeed = ComposerEngine.layoutSeed(runID: session.runID, id: newPlan.id)
                let legacy = ComposerEngine.compose(frozen, id: newPlan.id, context: legacyContext, seed: layoutSeed).plan
                guard legacy.photoAssetIDs == newPlan.photoAssetIDs else { throw EvalError.selectionChanged(newPlan.id) }
                var refs: [CandidateRef] = []
                for (engine, original, composition) in [("legacy", legacy, legacyContext), ("pages", newPlan, context)] {
                    var plan = original
                    // Keep the same layout seed on both sides; the eval seed only blinds presentation.
                    var layout = LayoutResolver.resolve(plan, context: LayoutContext(aspect: context.aspect,
                        photos: context.photos, features: context.features, stylePack: context.stylePack, seed: layoutSeed,
                        storyHint: context.storyHint, vocabulary: composition.vocabulary, pages: composition.pages,
                        keepOrder: composition.keepOrder))
                    plan.id = "\(engine)-\(newPlan.id)"
                    layout.id = plan.id
                    let store = RunStore.open(root)
                    try store.write(plan, to: "plans/\(plan.id).json")
                    for slide in layout.slides {
                        try store.write(slide, to: String(format: "layouts/%@/slide-%02d.json", plan.id, slide.index + 1))
                    }
                    let slideDir = root.appending(path: "slides/\(plan.id)")
                    let outcome = try CarouselRenderer().render(layout, photos: context.photos, sourceFolder: folder, outputDirectory: slideDir)
                    guard outcome.failures.isEmpty else { throw EvalError.render(outcome.failures) }
                    let filename = "\(runID)-engine-\(plan.id).jpg"
                    try StripRenderer().strip(slides: outcome.names.map { slideDir.appending(path: $0) },
                        height: context.aspect.exportHeight, quality: 0.9).write(to: out.appending(path: "strips/\(filename)"), options: .atomic)
                    strips["\(runID)/engine/\(plan.id)"] = "strips/\(filename)"
                    refs.append(CandidateRef(carouselID: plan.id, compositionSeed: plan.compositionSeed ?? "0", runID: runID,
                        engine: "\(engine)@\(ComposerEngine.version)/\(ResolvedCarousel.resolverVersion)", assetIDs: plan.photoAssetIDs))
                }
                pairs.append(EvalPair(pairID: "\(runID)-engine-\(newPlan.id)", runID: runID, stage: .engine, left: refs[0], right: refs[1]))
            }
        }
        var rng = SeededRandom(seed: seed)
        for i in pairs.indices where rng.next() & 1 == 1 { (pairs[i].left, pairs[i].right) = (pairs[i].right, pairs[i].left) }
        let set = EvalSet(seed: String(seed, radix: 16), createdAt: Date(timeIntervalSince1970: 0), runs: runDirectories.map(\.path),
            pairs: pairs, strips: strips, versions: ["composer": ComposerEngine.version, "layout": ResolvedCarousel.resolverVersion,
                                                   "renderer": CarouselRenderer.version],
            skippedOptions: skippedOptions > 0 ? skippedOptions : nil)
        try JSONCoding.encoder.encode(set).write(to: out.appending(path: "evalset.json"), options: .atomic)
    }

    static func rate(evalDirectory: URL, rater: String) throws {
        let set = try readSet(evalDirectory)
        let options = set.pairs.filter { $0.stage == .engine }.map { pair in
            pair.left.carouselID.hasPrefix("pages-") ? pair.left : pair.right
        }
        var slides: [String: [String]] = [:]
        for ref in options {
            let root = evalDirectory.appending(path: "runs/\(ref.runID)")
            let plan = try JSONCoding.decoder.decode(CarouselPlan.self, from: Data(contentsOf: root.appending(path: "plans/\(ref.carouselID).json")))
            slides["\(ref.runID)/\(ref.carouselID)"] = plan.slides.indices.map { index in
                String(format: "runs/%@/slides/%@/slide-%02d.png", ref.runID, ref.carouselID, index + 1)
            }
        }
        let existing = try readRatings(evalDirectory).filter { $0.rater == rater }
        let html = #"""
        <!doctype html><meta charset="utf-8"><title>AK14 Eval</title><style>body{font:16px system-ui;margin:2rem;background:#f5f3ee;color:#222}main{display:flex;gap:1rem;overflow:auto}img{flex:none;max-width:none}button{padding:.8rem 1.2rem;font:inherit;margin:.5rem}#status{margin:1rem 0}</style>
        <h1>Would you post this option?</h1><div id="status"></div><main id="slides"></main>
        <button onclick="choose('yes')">Yes (y)</button><button onclick="choose('almost')">Almost (a)</button><button onclick="choose('no')">No (n)</button><button onclick="exportRatings()">Export</button>
        <script>const options=__OPTIONS__,slides=__SLIDES__,rater=__RATER__;let i=0;const key='ak14-rate-'+JSON.stringify(options)+rater;let ratings=JSON.parse(localStorage.getItem(key)||'__EMPTY__');function render(){while(i<options.length&&ratings.some(x=>x.runID===options[i].runID&&x.optionID===options[i].carouselID))i++;const main=document.querySelector('#slides');main.replaceChildren();if(i>=options.length){document.querySelector('#status').textContent='Complete';return}const o=options[i];document.querySelector('#status').textContent=`Option ${i+1} of ${options.length}`;for(const src of slides[o.runID+'/'+o.carouselID]){const img=document.createElement('img');img.src=src;main.append(img)}main.scrollLeft=0}function choose(rating){if(i>=options.length)return;const o=options[i];ratings.push({runID:o.runID,optionID:o.carouselID,engine:'pages',rating,rater});localStorage.setItem(key,JSON.stringify(ratings));i++;render()}function exportRatings(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify({labels:[],ratings},null,2)],{type:'application/json'}));a.download='ratings.json';a.click();URL.revokeObjectURL(a.href)}document.addEventListener('keydown',e=>{if(e.key==='y')choose('yes');else if(e.key==='a')choose('almost');else if(e.key==='n')choose('no')});render();</script>
        """#.replacingOccurrences(of: "__OPTIONS__", with: try embeddedJSON(options))
            .replacingOccurrences(of: "__SLIDES__", with: try embeddedJSON(slides))
            .replacingOccurrences(of: "__RATER__", with: try embeddedJSON(rater))
            .replacingOccurrences(of: "'__EMPTY__'", with: "JSON.stringify(\(try embeddedJSON(existing)))")
        try Data(html.utf8).write(to: evalDirectory.appending(path: "rate.html"), options: .atomic)
    }

    private static func embeddedJSON<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONCoding.encoder.encode(value), encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func label(evalDirectory: URL, rater: String) throws {
        let set = try readSet(evalDirectory)
        let pairsJSON = try embeddedJSON(set.pairs)
        let stripsJSON = try embeddedJSON(set.strips)
        let versionsJSON = try embeddedJSON(set.versions)
        let html = #"""
        <!doctype html><meta charset="utf-8"><title>AK14 Eval</title><style>body{font:16px system-ui;max-width:1200px;margin:2rem auto;background:#f5f3ee;color:#222}main{display:flex;gap:1rem;align-items:center}figure{margin:0;flex:1}img{width:100%;height:auto}button{padding:.8rem 1.2rem;font:inherit;margin:.5rem}#status{margin:1rem 0}</style>
        <h1>Carousel preference</h1><div id="status"></div><main><figure><figcaption>Left</figcaption><img id="left"></figure><figure><figcaption>Right</figcaption><img id="right"></figure></main>
        <button onclick="choose('left')">Left ←</button><button onclick="choose('right')">Right →</button><button onclick="choose('tie')">Can't choose (space)</button><button onclick="choose('neither')">Neither is postable (n)</button><button onclick="exportLabels()">Export</button>
        <script>const pairs=__PAIRS__,strips=__STRIPS__,versions=__VERSIONS__,rater=__RATER__;let i=0;const key='ak14-eval-'+rater;let labels=JSON.parse(localStorage.getItem(key)||'[]');function sk(p,r){return strips[p.runID+'/'+p.stage+'/'+r.carouselID]||strips[p.runID+'/'+r.carouselID]}function question(s){return ({split:'Which grouping tells the better story?',selection:'Which photo set tells the better story?',cover:'Which cover is more compelling?',layout:'Which carousel layout is better?',engine:'Which carousel layout is better?'})[s]}function render(){while(i<pairs.length&&labels.some(x=>x.pairID===pairs[i].pairID))i++;if(i>=pairs.length){document.querySelector('#status').textContent='Complete';return}const p=pairs[i];document.querySelector('#status').textContent=`${p.stage} · ${question(p.stage)} · Pair ${i+1} of ${pairs.length}`;document.querySelector('#left').src=sk(p,p.left);document.querySelector('#right').src=sk(p,p.right)}function choose(choice){if(i>=pairs.length)return;const p=pairs[i];labels.push({pairID:p.pairID,rater,choice,shownLeft:p.left,decidedAt:new Date().toISOString(),versions});localStorage.setItem(key,JSON.stringify(labels));i++;render()}function exportLabels(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(labels,null,2)],{type:'application/json'}));a.download='labels-'+rater+'.json';a.click();URL.revokeObjectURL(a.href)}document.addEventListener('keydown',e=>{if(e.key==='ArrowLeft')choose('left');else if(e.key==='ArrowRight')choose('right');else if(e.key===' ')choose('tie');else if(e.key.toLowerCase()==='n')choose('neither')});render();</script>
        """#.replacingOccurrences(of: "__PAIRS__", with: pairsJSON).replacingOccurrences(of: "__STRIPS__", with: stripsJSON)
            .replacingOccurrences(of: "__VERSIONS__", with: versionsJSON).replacingOccurrences(of: "__RATER__", with: try embeddedJSON(rater))
        try Data(html.utf8).write(to: evalDirectory.appending(path: "label.html"), options: .atomic)
        // Keep the existing label entry point for saved links and older workflows.
        try Data(html.utf8).write(to: evalDirectory.appending(path: "index.html"), options: .atomic)
    }

    static func importLabels(evalDirectory: URL, file: URL) throws {
        let set = try readSet(evalDirectory)
        let data = try Data(contentsOf: file)
        let labels: [EvalLabel], ratings: [EvalRating]
        if let old = try? JSONCoding.decoder.decode([EvalLabel].self, from: data) {
            labels = old; ratings = []
        } else {
            let imported = try JSONCoding.decoder.decode(ImportedLabels.self, from: data)
            labels = imported.labels; ratings = imported.ratings ?? []
        }
        guard ratings.allSatisfy({ rating in
            !rating.rater.isEmpty && ["yes", "almost", "no"].contains(rating.rating)
                && set.pairs.filter { $0.stage == .engine && $0.runID == rating.runID }.contains { pair in
                    [pair.left, pair.right].contains { $0.carouselID == rating.optionID && rating.optionID.hasPrefix("\(rating.engine)-")
                        && ["pages", "legacy"].contains(rating.engine) }
                }
        }) else { throw EvalError.invalidLabels }
        let ids = Set(set.pairs.map(\.pairID))
        guard labels.allSatisfy({ label in
            ids.contains(label.pairID) && !label.rater.isEmpty && set.pairs.first(where: { $0.pairID == label.pairID })?.left == label.shownLeft
        }) else { throw EvalError.invalidLabels }
        if !labels.isEmpty {
            let dir = evalDirectory.appending(path: "labels"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appending(path: file.lastPathComponent)
            let old = fmExists(target) ? try JSONCoding.decoder.decode([EvalLabel].self, from: Data(contentsOf: target)) : []
            try JSONCoding.encoder.encode(old.filter { prior in !labels.contains(where: { $0.pairID == prior.pairID && $0.rater == prior.rater }) } + labels).write(to: target, options: .atomic)
        }
        if !ratings.isEmpty {
            var merged = try readRatings(evalDirectory)
            for rating in ratings {
                merged.removeAll { $0.runID == rating.runID && $0.optionID == rating.optionID && $0.engine == rating.engine && $0.rater == rating.rater }
                merged.append(rating)
            }
            try JSONCoding.encoder.encode(merged).write(to: evalDirectory.appending(path: "ratings.json"), options: .atomic)
        }
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
        for runPath in set.runs where selectedStage != .engine {
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
        let engineSummary = selectedStage == nil || selectedStage == .engine
            ? try engineScore(set, labels: all, directory: evalDirectory) : ""
        let markdown = engineSummary + "\n\n" + "# Eval report\n\nAgreement: \(agreement) (95% bootstrap CI \(ci[0])–\(ci[1]))\n\nLabelled pairs: \(pairCorrect.count)\nTies: \(ties)\n\n| Stage | Agreement | Neither rate | Labelled | Neither |\n|---|---:|---:|---:|---:|\n" + summaries.map { "| \($0.stage.rawValue) | \($0.agreement) | \($0.neitherRate) | \($0.labelledPairs) | \($0.neither) |" }.joined(separator: "\n") + "\n\n| Event | Agreement | Pairs |\n|---|---:|---:|\n" + events.map { "| \($0.event) | \($0.agreement) | \($0.labelledPairs) |" }.joined(separator: "\n") + "\n"
        let reportDir = evalDirectory.appending(path: "eval")
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: reportDir.appending(path: "report-\(stamp).md"), options: .atomic)
        try JSONCoding.encoder.encode(finalReport).write(to: reportDir.appending(path: "report.json"), options: .atomic)
        return (engineSummary.isEmpty ? "" : engineSummary + "\n") + "Agreement: \(agreement) (95% CI \(ci[0])–\(ci[1])); \(pairCorrect.count) pairs; \(ties) ties\n" + summaries.map { "\($0.stage.rawValue): agreement \($0.agreement), neither rate \($0.neitherRate)" }.joined(separator: "\n")
    }

    private struct ImportedLabels: Decodable {
        var labels: [EvalLabel]
        var ratings: [EvalRating]?
    }

    private static func readRatings(_ directory: URL) throws -> [EvalRating] {
        let url = directory.appending(path: "ratings.json")
        return fmExists(url) ? try JSONCoding.decoder.decode([EvalRating].self, from: Data(contentsOf: url)) : []
    }

    private static func engineScore(_ set: EvalSet, labels: [EvalLabel], directory: URL) throws -> String {
        let pairs = set.pairs.filter { $0.stage == .engine }
        let skipped = set.skippedOptions ?? 0
        let availability = skipped > 0 ? "skipped \(skipped) options: template-first unavailable\n" : ""
        guard !pairs.isEmpty else {
            return skipped > 0 ? availability + "no template-first options available" : ""
        }
        var preferred = 0, compared = 0, ties = 0
        for pair in pairs {
            let votes = labels.filter { $0.pairID == pair.pairID }
            ties += votes.filter { $0.choice == .tie || $0.choice == .neither }.count
            let choices = votes.filter { $0.choice == .left || $0.choice == .right }
            let left = choices.filter { $0.choice == .left }.count, right = choices.count - left
            guard left != right else { if !choices.isEmpty { ties += 1 }; continue }
            compared += 1
            if (left > right ? pair.left : pair.right).carouselID.hasPrefix("pages-") { preferred += 1 }
        }
        let refs = pairs.map { $0.left.carouselID.hasPrefix("pages-") ? $0.left : $0.right }
        let ratings = try readRatings(directory).filter { rating in
            rating.engine == "pages" && refs.contains { $0.runID == rating.runID && $0.carouselID == rating.optionID }
        }
        let byRun = Dictionary(grouping: ratings, by: \.runID)
        let severity = ["yes": 0, "almost": 1, "no": 2]
        let noPostable = byRun.values.filter { !$0.contains { $0.rating == "yes" } }.count
        let worst = byRun.keys.sorted().map { run in
            let rating = byRun[run, default: []].max { severity[$0.rating, default: 0] < severity[$1.rating, default: 0] }?.rating ?? "no"
            return "worst option per run: \(run): \(rating)"
        }.joined(separator: "\n")
        var slides: [ResolvedSlide] = [], nonWhiteSlides: [ResolvedSlide] = []
        var whiteCards = 0
        for ref in refs {
            let root = directory.appending(path: "runs/\(ref.runID)")
            let plan = try JSONCoding.decoder.decode(CarouselPlan.self, from: Data(contentsOf: root.appending(path: "plans/\(ref.carouselID).json")))
            for index in plan.slides.indices {
                let slide = try JSONCoding.decoder.decode(ResolvedSlide.self, from: Data(contentsOf: root.appending(path: String(format: "layouts/%@/slide-%02d.json", ref.carouselID, index + 1))))
                slides.append(slide)
                if plan.slides[index].placement?.pageID == "white-card" { whiteCards += 1 }
                else { nonWhiteSlides.append(slide) }
            }
        }
        let crops = nonWhiteSlides.flatMap(\.elements).filter { $0.kind == .photo }.compactMap(\.crop).map { $0.width * $0.height }.sorted()
        let middle = crops.count / 2
        let median = crops.isEmpty ? 0 : crops.count % 2 == 0 ? (crops[middle - 1] + crops[middle]) / 2 : crops[middle]
        func percent(_ count: Int, _ total: Int) -> Int { total == 0 ? 0 : Int((100 * Double(count) / Double(total)).rounded()) }
        return availability + "new engine preferred: \(percent(preferred, compared))%\nneither/tie: \(ties)\n"
            + "rated yes: \(percent(ratings.filter { $0.rating == "yes" }.count, ratings.count))%, "
            + "almost: \(percent(ratings.filter { $0.rating == "almost" }.count, ratings.count))%, "
            + "no: \(percent(ratings.filter { $0.rating == "no" }.count, ratings.count))%\n"
            + "runs with no postable option: \(noPostable) of \(byRun.count)\n"
            + (worst.isEmpty ? "" : worst + "\n")
            + "white cards: \(percent(whiteCards, slides.count))% of slides\n"
            + String(format: "median crop kept: %.2f", median)
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
    enum EvalError: Error, Equatable, CustomStringConvertible {
        case invalidLabels, duplicateRuns, overlappingOutput, noDirections(String), selectionChanged(String), render([String])
        var description: String {
            switch self {
            case .render(let failures): "evaluation render failed: \(failures.prefix(5).joined(separator: "; "))"
            case .invalidLabels: "labels or ratings do not match this evaluation"
            case .overlappingOutput: "evaluation output overlaps an input run"
            case .duplicateRuns: "evaluation run directory names must be unique"
            case .noDirections(let run): "no stored directions or selection spine to compare in \(run)"
            case .selectionChanged(let option): "legacy composition changed the frozen photo order for \(option)"
            }
        }
    }
}

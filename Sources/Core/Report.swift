import Foundation

public func htmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(ch)
        }
    }
    return out
}

/// A concept as edited in Studio: working plan plus run-relative edited slide paths.
public struct EditedConcept: Sendable {
    public let plan: CarouselPlan
    public let slides: [String]
    public init(plan: CarouselPlan, slides: [String]) { self.plan = plan; self.slides = slides }
}

public struct ReportInput: Sendable {
    public let manifest: RunManifest
    public let photos: [PhotoRecord]
    public let skipped: [SkippedFile]
    public let features: [AssetID: PhotoFeatures]
    /// Run-relative thumbnail paths.
    public let thumbnails: [AssetID: String]
    public let reduction: ReductionResult?
    public let concepts: ConceptsReport?
    public let edits: [String: EditedConcept]
    public let events: [InteractionEvent]
    /// Concept → resolved slides, for the layout metrics.
    public let layouts: [String: [ResolvedSlide]]

    public init(manifest: RunManifest, photos: [PhotoRecord], skipped: [SkippedFile],
                features: [AssetID: PhotoFeatures], thumbnails: [AssetID: String],
                reduction: ReductionResult? = nil, concepts: ConceptsReport? = nil,
                edits: [String: EditedConcept] = [:], events: [InteractionEvent] = [],
                layouts: [String: [ResolvedSlide]] = [:]) {
        self.manifest = manifest; self.photos = photos; self.skipped = skipped
        self.features = features; self.thumbnails = thumbnails
        self.reduction = reduction; self.concepts = concepts; self.edits = edits; self.events = events
        self.layouts = layouts
    }
}

/// Builds a self-contained local HTML report. Never emits absolute paths or GPS coordinates.
public enum ReportBuilder {
    public static let version = "report-1"

    public static func html(_ input: ReportInput) -> String {
        let m = input.manifest
        let e = htmlEscape
        var h = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>AK14 run \(e(m.runID))</title>\n"
        h += "<style>\(css)</style></head><body>\n"
        h += "<h1>AK14 run \(e(m.runID))</h1>\n"
        h += "<p>Folder: <b>\(e(m.sourceFolderLabel))</b> · created \(e(iso(m.createdAt)))"
        h += " · aspect \(e(m.aspectRatio.rawValue))\(m.aspectOverridden ? " (override)" : " (inferred)")</p>\n"

        let photos = input.photos
        let noDate = photos.filter { $0.metadata.capturedAt == nil }.count
        let assumedTZ = photos.filter { $0.metadata.timeZoneAssumed }.count
        let noGPS = photos.filter { !$0.metadata.hasLocation }.count
        let noCamera = photos.filter { $0.metadata.cameraModel == nil }.count
        let screenshots = photos.filter { $0.metadata.isScreenshot }.count
        let dupGroups = photos.filter { $0.sourceRelativePaths.count > 1 }.count

        if let status = m.directorStatus { h += "<p>Director: <b>\(e(status))</b></p>\n" }
        if let c = input.concepts { h += conceptsSection(c, input: input) }
        if !input.edits.isEmpty || !input.events.isEmpty { h += studioSection(input) }
        if !m.providerCalls.isEmpty { h += costSection(m) }
        if let r = input.reduction { h += reductionSection(r, input: input) }

        h += "<h2>Summary</h2>\n<table>\n"
        for (k, v) in [("Photos", "\(photos.count)"), ("Skipped files", "\(input.skipped.count)"),
                       ("Exact-duplicate groups", "\(dupGroups)"), ("Missing capture date", "\(noDate)"),
                       ("Time zone assumed", "\(assumedTZ)"), ("Missing GPS", "\(noGPS)"),
                       ("No camera metadata (likely received/forwarded)", "\(noCamera)"),
                       ("Screenshots", "\(screenshots)"),
                       ("Analysis cache hits / misses", "\(m.cacheHits) / \(m.cacheMisses)")] {
            h += "<tr><th>\(e(k))</th><td>\(e(v))</td></tr>\n"
        }
        h += "</table>\n"

        let types = Dictionary(grouping: photos, by: \.fileType).mapValues(\.count).sorted { $0.key < $1.key }
        h += "<h2>File types</h2>\n<table>\n"
        for (t, c) in types { h += "<tr><th>\(e(t))</th><td>\(c)</td></tr>\n" }
        h += "</table>\n"

        h += "<h2>Stages</h2>\n<table>\n"
        for s in m.stageTimings { h += "<tr><th>\(e(s.stage))</th><td>\(String(format: "%.2f", s.seconds)) s</td></tr>\n" }
        h += "</table>\n<h2>Versions</h2>\n<table>\n"
        for (k, v) in m.versions.sorted(by: { $0.key < $1.key }) { h += "<tr><th>\(e(k))</th><td>\(e(v))</td></tr>\n" }
        h += "</table>\n"

        if !m.warnings.isEmpty {
            h += "<h2>Warnings</h2>\n<ul>\n"
            for w in m.warnings { h += "<li>\(e(w))</li>\n" }
            h += "</ul>\n"
        }

        h += "<h2>Skipped files</h2>\n"
        if input.skipped.isEmpty { h += "<p>None.</p>\n" } else {
            h += "<table>\n"
            for s in input.skipped {
                h += "<tr><th>\(e(s.relativePath))</th><td>\(e(s.reason.rawValue))\(s.detail.map { " · " + e($0) } ?? "")</td></tr>\n"
            }
            h += "</table>\n"
        }

        h += "<h2>Contact sheet</h2>\n"
        if photos.isEmpty {
            h += "<p>No photos were ingested.</p>\n"
        } else {
            h += "<div class=\"grid\">\n"
            let ordered = photos.sorted {
                switch ($0.metadata.capturedAt, $1.metadata.capturedAt) {
                case let (a?, b?): return a == b ? $0.assetID < $1.assetID : a < b
                case (nil, nil): return $0.assetID < $1.assetID
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            for p in ordered { h += card(p, features: input.features[p.assetID], thumb: input.thumbnails[p.assetID]) }
            h += "</div>\n"
        }

        h += "<h2>Privacy</h2>\n<p>This report is local. It contains thumbnails of your photos but no GPS coordinates "
        h += "or absolute file paths. When the Director ran, small thumbnails of the shortlisted photos (not originals) "
        h += "were sent to the model provider; the exact requests are in <code>llm/</code> with images replaced by references.</p>\n"
        h += "</body></html>\n"
        return h
    }

    private static func card(_ p: PhotoRecord, features f: PhotoFeatures?, thumb: String?) -> String {
        let e = htmlEscape
        var badges: [String] = []
        if p.metadata.capturedAt == nil { badges.append("no capture date") }
        if p.metadata.timeZoneAssumed { badges.append("time zone assumed") }
        if !p.metadata.hasLocation { badges.append("no GPS") }
        if p.metadata.cameraModel == nil { badges.append("no camera metadata") }
        if p.metadata.isScreenshot { badges.append("screenshot") }
        if p.sourceRelativePaths.count > 1 { badges.append("\(p.sourceRelativePaths.count) paths") }
        if let f {
            if !f.faces.isEmpty { badges.append("\(f.faces.count) face\(f.faces.count == 1 ? "" : "s")") }
            if f.isUtility == true { badges.append("utility") }
            if let d = f.darkFraction, d > 0.9 { badges.append("very dark") }
            if !f.failures.isEmpty { badges.append("analysis incomplete: " + f.failures.keys.sorted().joined(separator: ", ")) }
        } else {
            badges.append("not analyzed")
        }
        var c = "<figure>"
        if let thumb { c += "<img loading=\"lazy\" src=\"\(e(thumb))\" alt=\"\(e(p.assetID.rawValue))\">" }
        c += "<figcaption><code>\(e(p.assetID.rawValue))</code><br>\(e(p.sourceRelativePaths.joined(separator: ", ")))"
        c += "<br>\(p.metadata.capturedAt.map { e(iso($0)) } ?? "—")"
        if let score = f?.aestheticScore { c += " · aesthetic \(String(format: "%.2f", score))" }
        if let labels = f?.labels, !labels.isEmpty {
            c += "<br><small>\(e(labels.prefix(4).map(\.identifier).joined(separator: ", ")))</small>"
        }
        if !badges.isEmpty { c += "<br>" + badges.map { "<span class=\"b\">\(e($0))</span>" }.joined(separator: " ") }
        c += "</figcaption></figure>\n"
        return c
    }

    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    // MARK: - M2/M3 sections

    private static func img(_ id: AssetID, _ input: ReportInput, cls: String = "t") -> String {
        guard let t = input.thumbnails[id] else { return "<span class=\"miss\">\(htmlEscape(id.rawValue))</span>" }
        return "<img class=\"\(cls)\" loading=\"lazy\" src=\"\(htmlEscape(t))\" title=\"\(htmlEscape(id.rawValue))\">"
    }

    private static func conceptsSection(_ c: ConceptsReport, input: ReportInput) -> String {
        let e = htmlEscape
        var h = "<h2>Concepts</h2>\n<p>Status <b>\(e(c.status))</b> · style pack \(e(c.stylePackID))@\(e(c.stylePackVersion))"
        if let n = c.recommendedSlideCount { h += " · recommended length \(n)" }
        h += "</p>\n"
        for (k, v) in c.unavailable.sorted(by: { $0.key < $1.key }) { h += "<p class=\"warn\">\(e(k)) unavailable: \(e(v))</p>\n" }
        if let spine = c.spine {
            h += "<h3>Selection spine (\(spine.orderedAssetIDs.count) photos, cover first)</h3>\n<div class=\"strip\">"
            for (i, id) in spine.orderedAssetIDs.enumerated() {
                let intent = i < spine.sequenceIntent.count ? spine.sequenceIntent[i].rawValue : ""
                let reason = spine.rationale.first { $0.id == id }?.reason ?? ""
                h += "<figure class=\"s\">\(img(id, input))<figcaption>\(i + 1). \(e(intent)) \(e(reason))</figcaption></figure>"
            }
            h += "</div>\n"
        }
        for (position, plan) in c.orderedPlans.enumerated() {
            let id = plan.id
            h += "<h3>Option \(position + 1) · <code>\(e(id))</code>\(plan.isBaseline ? " (baseline control)" : "") · \(plan.slides.count) slides</h3>\n"
            h += "<p><i>\(e(plan.brief))</i>"
            if let style = plan.style, !plan.isBaseline { h += "<br><small>\(e(style.summary))</small>" }
            h += "</p>\n"
            if let d = c.deviations[id] {
                h += "<p>vs spine: +\(d.added.count) / −\(d.removed.count) photos, cover \(d.coverChanged ? "changed" : "same"), "
                h += "order agreement \(String(format: "%.2f", d.orderSimilarity))</p>\n"
            }
            if let slides = c.renderedSlides[id], !slides.isEmpty {
                h += "<div class=\"strip\">" + slides.map { "<img class=\"slide\" src=\"\(e($0))\">" }.joined() + "</div>\n"
            }
            h += layoutMetrics(input.layouts[id] ?? [])
            if plan.isBaseline { continue }
            h += "<details><summary>Slide plan</summary><div class=\"strip\">"
            for (i, s) in plan.slides.enumerated() {
                h += "<div class=\"slideplan\"><b>\(i + 1)</b> \(e(s.primitive.rawValue)) · \(e(s.density)) · \(e(s.mood))<br>"
                h += s.photos.map { img($0.assetID, input) + "<small>\(e($0.role))</small>" }.joined()
                if !s.decorations.isEmpty { h += "<br><small>deco: \(e(s.decorations.map { "\($0.decorationID)(\($0.intensity))" }.joined(separator: ", ")))</small>" }
                if !s.stamps.isEmpty { h += "<br><small>stamps: \(e(s.stamps.map { "\($0.kind)@\($0.placement)" }.joined(separator: ", ")))</small>" }
                h += "</div>"
            }
            h += "</div></details>\n"
        }
        if !c.diversity.isEmpty {
            h += "<h3>Diversity between directions</h3>\n<ul>"
            for d in c.diversity {
                h += "<li>\(e(d.a ?? "?")) vs \(e(d.b ?? "?")): \(d.passes ? "distinct" : "too similar") — photo overlap \(String(format: "%.2f", d.jaccard)), "
                if let s = d.styleDistance { h += "style distance \(String(format: "%.2f", s)), " }
                h += "same cover \(d.sameCover), structural differences: \(e(d.structuralDiffs.joined(separator: ", ")))</li>"
            }
            h += "</ul>\n"
        }
        return h
    }

    /// One line per concept plus a per-slide table: photo coverage, hero share, largest crop and arrangement.
    private static func layoutMetrics(_ slides: [ResolvedSlide]) -> String {
        let rows = slides.compactMap { s in s.metrics.map { (s, $0) } }
        guard !rows.isEmpty else { return "" }
        let e = htmlEscape, pct = { (v: Double) in String(format: "%.0f%%", v * 100) }
        let designed = rows.filter { $0.0.primitive != .fullBleed }
        let families = slides.compactMap { $0.variant?.split(separator: ".").prefix(2).joined(separator: ".") }
        let repeats = zip(families, families.dropFirst()).filter { $0 == $1 && $0 != "bleed" }.count
        var h = "<p class=\"metrics\">Layout: photo coverage "
        h += designed.isEmpty ? "full-bleed only" : pct(designed.map(\.1.coverage).reduce(0, +) / Double(designed.count)) + " avg on framed slides"
        h += " · largest crop \(pct(rows.map(\.1.maxCropLoss).max() ?? 0))"
        if let minShare = rows.compactMap(\.1.heroShare).min() { h += " · smallest hero share \(String(format: "%.1f×", minShare))" }
        h += " · consecutive repeated arrangements \(repeats)</p>\n"
        h += "<details><summary>Layout per slide</summary><table><tr><th>slide</th><th>arrangement</th><th>coverage</th><th>hero share</th><th>largest crop</th></tr>"
        for (s, m) in rows {
            h += "<tr><td>\(s.index + 1)</td><td>\(e(s.variant ?? s.primitive.rawValue))</td><td>\(pct(m.coverage))</td>"
            h += "<td>\(m.heroShare.map { String(format: "%.1f×", $0) } ?? "—")</td><td>\(pct(m.maxCropLoss))</td></tr>"
        }
        return h + "</table></details>\n"
    }

    private static func studioSection(_ input: ReportInput) -> String {
        let e = htmlEscape
        var h = "<h2>Studio edits</h2>\n"
        for (c, edit) in input.edits.sorted(by: { $0.key < $1.key }) {
            let original = input.concepts?.plan(c)
            let before = Set(original?.photoAssetIDs ?? []), after = Set(edit.plan.photoAssetIDs)
            h += "<h3>\(e(c)) (edited) · \(edit.plan.slides.count) slides</h3>\n"
            h += "<p>vs original: \(original?.slides.count ?? 0) → \(edit.plan.slides.count) slides, "
            h += "+\(after.subtracting(before).count) / −\(before.subtracting(after).count) photos, "
            h += "cover \(original?.coverAssetID == edit.plan.coverAssetID ? "same" : "changed")</p>\n"
            h += "<div class=\"strip\">" + edit.slides.map { "<img class=\"slide\" src=\"\(e($0))\">" }.joined() + "</div>\n"
        }
        h += "<h2>Interaction events (\(input.events.count))</h2>\n"
        if input.events.isEmpty { return h + "<p>None yet.</p>\n" }
        h += "<table><tr><th>time</th><th>event</th><th>concept</th><th>slide</th><th>detail</th><th>source</th></tr>\n"
        for ev in input.events {
            var detail: [String] = []
            if let ids = ev.assetIDs, !ids.isEmpty { detail.append(ids.map(\.rawValue).joined(separator: " → ")) }
            if let after = ev.after, ev.event == "carousel_exported" || ev.event == "carousel_shared" { detail += after }
            h += "<tr><td>\(e(iso(ev.timestamp)))</td><td>\(e(ev.event))</td><td>\(e(ev.conceptID ?? ""))</td>"
            h += "<td>\(ev.slideIndex.map { "\($0 + 1)" } ?? "")</td><td>\(e(detail.joined(separator: "; ")))</td><td>\(e(ev.source))</td></tr>\n"
        }
        return h + "</table>\n"
    }

    private static func costSection(_ m: RunManifest) -> String {
        var h = "<h2>Model calls</h2>\n<table><tr><th>stage</th><th>ok</th><th>in</th><th>cached</th><th>out</th><th>reasoning</th>"
        h += "<th>images</th><th>latency</th><th>retries</th><th>est. cost</th></tr>\n"
        for c in m.providerCalls {
            h += "<tr><td>\(htmlEscape(c.stage))</td><td>\(c.ok ? "✓" : htmlEscape(c.error ?? "✗"))</td><td>\(c.inputTokens)</td>"
            h += "<td>\(c.cachedTokens)</td><td>\(c.outputTokens)</td><td>\(c.reasoningTokens)</td><td>\(c.imageCount)</td>"
            h += "<td>\(String(format: "%.1f s", c.latencySeconds))</td><td>\(c.retryCount)</td><td>\(String(format: "$%.4f", c.estimatedCost))</td></tr>\n"
        }
        h += "<tr><th colspan=\"9\">total</th><th>\(String(format: "$%.4f", m.totalEstimatedCost))</th></tr></table>\n"
        return h
    }

    private static func reductionSection(_ r: ReductionResult, input: ReportInput) -> String {
        let e = htmlEscape, f = r.funnel
        var h = "<h2>Funnel</h2>\n<table>"
        for (k, v) in [("Ingested", f.ingested), ("Rejected as junk", f.junkRejected), ("Distinct moments (cluster representatives)", f.representatives),
                       ("Shortlisted for triage", f.shortlisted), ("Triaged by model", f.triaged), ("Planning pool", f.planningPool),
                       ("Selected in spine", f.selected)] {
            h += "<tr><th>\(e(k))</th><td>\(v)</td></tr>"
        }
        h += "</table>\n"

        let pool = Set(r.planningPool.map(\.assetID))
        h += "<h2>Shortlist (\(r.shortlist.count))</h2>\n<div class=\"grid\">"
        for c in r.shortlist {
            let comp = c.components
            var line = "score \(String(format: "%.2f", c.score))"
            if let a = c.adjustedScore { line += " → \(String(format: "%.2f", a))" }
            h += "<figure>\(img(c.assetID, input))<figcaption><code>\(e(c.assetID.rawValue))</code> · \(line)"
            h += "<br><small>use \(fmt(comp.usability)) ppl \(fmt(comp.people)) sal \(fmt(comp.saliency)) aes \(fmt(comp.aesthetic)) "
            h += "sem \(fmt(comp.semantic)) dist \(fmt(comp.distinctiveness))\(comp.penalty > 0 ? " −\(fmt(comp.penalty))" : "")</small><br>"
            var badges = [c.selectionReason ?? "rank"]
            if c.clusterSize > 1 { badges.append("best of \(c.clusterSize)") }
            if pool.contains(c.assetID) { badges.append("planning pool") }
            if let t = c.triage {
                badges.append("emotional \(t.emotionalValue)/5")
                if t.imperfection != "neutral" { badges.append(t.imperfection) }
                badges += t.safety.map { "⚠︎ \($0)" }
            }
            h += badges.map { "<span class=\"b\">\(e($0))</span>" }.joined(separator: " ") + "</figcaption></figure>\n"
        }
        h += "</div>\n"

        let multi = r.clusters.filter { $0.memberAssetIDs.count > 1 }.sorted { $0.memberAssetIDs.count > $1.memberAssetIDs.count }
        h += "<h2>Similar-shot clusters (\(multi.count) with 2+ frames)</h2>\n"
        for c in multi.prefix(40) {
            h += "<div class=\"cluster\"><small>\(e(c.kind.rawValue)) · \(c.memberAssetIDs.count) frames</small><br>"
            h += c.memberAssetIDs.prefix(12).map { img($0, input, cls: $0 == c.representativeAssetID ? "t rep" : "t") }.joined()
            h += "</div>\n"
        }

        let rejected = r.junk.filter { $0.verdict == .reject }
        h += "<h2>Rejected (\(rejected.count))</h2>\n"
        if rejected.isEmpty { h += "<p>None.</p>\n" } else {
            h += "<div class=\"grid\">" + rejected.map {
                "<figure>\(img($0.assetID, input))<figcaption>\(e($0.reasons.joined(separator: ", ")))</figcaption></figure>"
            }.joined() + "</div>\n"
        }
        return h
    }

    private static func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }

    private static let css = """
    body{font:14px -apple-system,system-ui,sans-serif;margin:24px;color:#111}
    table{border-collapse:collapse;margin-bottom:12px}th,td{border:1px solid #ddd;padding:4px 8px;text-align:left}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px}
    figure{margin:0;border:1px solid #eee;padding:6px}img{width:100%;height:auto;display:block}
    figcaption{font-size:12px;margin-top:4px}.b{background:#f3f3f3;border-radius:3px;padding:0 4px;white-space:nowrap}
    .strip{display:flex;gap:10px;overflow-x:auto;padding-bottom:8px}.slide{height:360px;width:auto;border:1px solid #ddd}
    .s{flex:0 0 120px}.s img{width:120px}.t{width:72px;height:auto;display:inline-block;margin:2px}
    .rep{outline:3px solid #2a7}.cluster{margin:6px 0}.slideplan{flex:0 0 190px;border:1px solid #ddd;padding:6px;font-size:12px}
    .warn{color:#a40}.note{color:#777;font-size:12px}.miss{font-size:10px;color:#999}
    """
}

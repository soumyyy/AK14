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

public struct ReportInput: Sendable {
    public let manifest: RunManifest
    public let photos: [PhotoRecord]
    public let skipped: [SkippedFile]
    public let features: [AssetID: PhotoFeatures]
    /// Run-relative thumbnail paths.
    public let thumbnails: [AssetID: String]

    public init(manifest: RunManifest, photos: [PhotoRecord], skipped: [SkippedFile],
                features: [AssetID: PhotoFeatures], thumbnails: [AssetID: String]) {
        self.manifest = manifest; self.photos = photos; self.skipped = skipped
        self.features = features; self.thumbnails = thumbnails
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
        let noGPS = photos.filter { $0.metadata.location == nil }.count
        let noCamera = photos.filter { $0.metadata.cameraModel == nil }.count
        let screenshots = photos.filter { $0.metadata.isScreenshot }.count
        let dupGroups = photos.filter { $0.sourceRelativePaths.count > 1 }.count

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
        h += "or absolute file paths. M1 runs make no network calls.</p>\n"
        h += "</body></html>\n"
        return h
    }

    private static func card(_ p: PhotoRecord, features f: PhotoFeatures?, thumb: String?) -> String {
        let e = htmlEscape
        var badges: [String] = []
        if p.metadata.capturedAt == nil { badges.append("no capture date") }
        if p.metadata.timeZoneAssumed { badges.append("time zone assumed") }
        if p.metadata.location == nil { badges.append("no GPS") }
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

    private static let css = """
    body{font:14px -apple-system,system-ui,sans-serif;margin:24px;color:#111}
    table{border-collapse:collapse;margin-bottom:12px}th,td{border:1px solid #ddd;padding:4px 8px;text-align:left}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px}
    figure{margin:0;border:1px solid #eee;padding:6px}img{width:100%;height:auto;display:block}
    figcaption{font-size:12px;margin-top:4px}.b{background:#f3f3f3;border-radius:3px;padding:0 4px;white-space:nowrap}
    """
}

import Foundation

public enum JunkVerdict: String, Codable, Sendable { case keep, penalize, reject }

public struct JunkDisposition: Codable, Sendable, Equatable {
    public let assetID: AssetID
    public let verdict: JunkVerdict
    public let reasons: [String]
}

/// Filter accidents, preserve personality: only clear technical failures are rejected.
public enum JunkFilter {
    public static func classify(photo: PhotoRecord, features f: PhotoFeatures?) -> JunkDisposition {
        guard let f else { return JunkDisposition(assetID: photo.assetID, verdict: .keep, reasons: ["notAnalyzed"]) }
        let dark = f.darkFraction ?? 0, lum = f.meanLuminance ?? 0.5, sharp = f.sharpness ?? 1
        let hasFaces = !f.faces.isEmpty
        let bigSalient = f.salientRegions.contains { $0.width * $0.height > 0.05 }

        var reject: [String] = []
        if dark > 0.97 && lum < 0.04 { reject.append("blackFrame") }
        if dark > 0.85 && sharp < 0.02 && !hasFaces && f.salientRegions.isEmpty { reject.append("pocketShot") }
        if sharp < 0.005 && !hasFaces && !bigSalient { reject.append("extremeBlur") }
        if !reject.isEmpty { return JunkDisposition(assetID: photo.assetID, verdict: .reject, reasons: reject) }

        var penalize: [String] = []
        if f.isUtility == true { penalize.append("utility") }
        if photo.metadata.isScreenshot { penalize.append("screenshot") }
        if sharp < 0.03 { penalize.append("lowSharpness") }
        if dark > 0.8 { penalize.append("veryDark") }
        if let a = f.aestheticScore, a < -0.3 { penalize.append("lowAesthetic") }
        return JunkDisposition(assetID: photo.assetID, verdict: penalize.isEmpty ? .keep : .penalize, reasons: penalize)
    }

    public static func penalty(_ d: JunkDisposition) -> Double {
        let per: [String: Double] = ["utility": 0.15, "screenshot": 0.1, "lowSharpness": 0.08, "veryDark": 0.08, "lowAesthetic": 0.08]
        return min(0.4, d.reasons.reduce(0) { $0 + (per[$1] ?? 0) })
    }
}

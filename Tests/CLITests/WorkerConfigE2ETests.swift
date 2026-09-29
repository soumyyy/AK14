import Foundation
import Testing
@testable import Render

/// The Worker's style config is what installed apps download. Serving a version they do not support breaks
/// generation for every user ("unsupported style config version"), so the checked-in config must stay loadable.
@Test func workerStyleConfigVersionIsSupportedByTheApp() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "backend/worker/src/style-config.json")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let version = try #require(json["configVersion"] as? Int)
    #expect(StyleConfigClient.supportedConfigVersions.contains(version),
            "Worker serves configVersion \(version); this app build supports \(StyleConfigClient.supportedConfigVersions)")
}

@Test func workerConfigConstitutionsStayInSync() throws {
    let bundled = try #require(StylePackLoader.load().constitution)
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "backend/worker/src/style-config.json")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let packs = try #require(json["stylePacks"] as? [[String: Any]])
    let worker = try #require(packs.first { $0["id"] as? String == StylePackLoader.defaultID }?["constitution"] as? String)
    #expect(bundled == worker)
    #expect(!bundled.contains("Avoid recognizable template fingerprints"))
    #expect(!worker.contains("Avoid recognizable template fingerprints"))
}

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

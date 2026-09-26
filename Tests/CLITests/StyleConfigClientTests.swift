import Foundation
import Testing
@testable import Render

private final class StyleConfigURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "worker.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let variant = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "case" })?.value
        let status = variant == "http-error" ? 503 : 200
        let activeID = variant == "missing" ? "unknown-pack" : "starter-editorial"
        let active = variant != "inactive"
        let version = variant == "bad-version" ? "vNext" : "1.0.0"
        let marginMax = variant == "bad-margin" ? 0.8 : 0.07
        let photoRotation = variant == "bad-rotation" ? -1 : 2
        let minVisible = variant == "bad-visibility" ? 0.2 : 0.55
        let weight = variant == "bad-weight" ? -0.1 : 0.3
        let decorations = variant == "bad-decoration" ? "[\"missing-decoration\"]"
            : variant == "good-assets" ? "[\"paper-warm\",\"date-stamp\"]" : "[]"
        let textures = variant == "bad-texture" ? "[\"missing-texture\"]"
            : variant == "good-assets" ? "[\"paper-warm\"]" : "[]"
        let body = """
        {"configVersion":1,"activeStylePack":"\(activeID)","stylePacks":[{
          "id":"starter-editorial","version":"\(version)","active":\(active),"minAppVersion":"0.1.0",
          "primitiveWeights":{"full_bleed":\(weight)},"decorationIDs":\(decorations),"fontIDs":[],"textureIDs":\(textures),
          "allowedRotations":{"photoDegrees":\(photoRotation)},"overlapRanges":{"minimumVisibleFraction":\(minVisible)},
          "spacingRanges":{"marginMin":0.04,"marginMax":\(marginMax)},"densityProfile":["balanced"],
          "promptHints":[],"explorationWeight":0.3
        }]}
        """
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json", "ETag": "\"pack-1\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StyleConfigURLProtocol.self]
    return URLSession(configuration: configuration)
}

@Test func remoteConfigReturnsValidatedActivePackAndPin() async throws {
    let loaded = try await StyleConfigClient.fetch(from: URL(string: "https://worker.test/v1/config?case=good-assets")!, session: stubSession())
    #expect(loaded.configVersion == 1)
    #expect(loaded.activeStylePackID == "starter-editorial")
    #expect(loaded.stylePack.id == "starter-editorial" && loaded.stylePack.version == "1.0.0")
    #expect(loaded.pin == StylePackPin(id: "starter-editorial", version: "1.0.0"))
    #expect(loaded.etag == "\"pack-1\"")
    #expect(loaded.stylePack.decorationIDs == ["paper-warm", "date-stamp"])
    #expect(loaded.stylePack.textureIDs == ["paper-warm"])
}

@Test(arguments: ["missing", "inactive", "bad-version", "http-error", "bad-margin", "bad-rotation", "bad-visibility", "bad-weight", "bad-decoration", "bad-texture", "nonlocal-http"])
func remoteConfigRejectsInvalidActivePackAndHTTPFailures(caseName: String) async throws {
    let scheme = caseName == "nonlocal-http" ? "http" : "https"
    let url = URL(string: "\(scheme)://worker.test/v1/config?case=\(caseName)")!
    await #expect(throws: StyleConfigError.self) {
        try await StyleConfigClient.fetch(from: url, session: stubSession())
    }
}

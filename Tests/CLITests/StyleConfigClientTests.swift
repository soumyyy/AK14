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
        let tasteFields: String
        if variant == "old" {
            tasteFields = ""
        } else {
            let constitution = variant == "bad-constitution" ? String(repeating: "x", count: 4_001) : "Taste it"
            let references = variant == "bad-references" ? String(String(repeating: "{\"id\":\"r\",\"sha256\":\"bad\",\"tags\":[]},", count: 13).dropLast())
                : "{\"id\":\"ref-1\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"tags\":[\"editorial\"]}"
            let referenceJSON = variant == "bad-ref-count"
                ? String(String(repeating: "{\"id\":\"r\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"tags\":[]},", count: 13).dropLast())
                : references
            let notes = variant == "bad-trends" ? "[\"\(String(repeating: "x", count: 201))\"]"
                : variant == "bad-trend-count" ? "[\(Array(repeating: "\"note\"", count: 9).joined(separator: ","))]" : "[\"current\"]"
            let judge = variant == "bad-judge" ? "{\"enabled\":false,\"candidates\":9}"
                : variant == "bad-judge-low" ? "{\"enabled\":false,\"candidates\":1}" : "{\"enabled\":false,\"candidates\":6}"
            tasteFields = "\"constitution\":\"\(constitution)\",\"referenceImages\":[\(referenceJSON)],\"trendNotes\":\(notes),\"judge\":\(judge),"
        }
        let packVersion = variant == "newer" ? "1.1.0" : version
        let body = """
        {"configVersion":1,"activeStylePack":"\(activeID)","stylePacks":[{
          "id":"starter-editorial","version":"\(packVersion)","active":\(active),"minAppVersion":"0.1.0",
          "primitiveWeights":{"full_bleed":\(weight)},"decorationIDs":\(decorations),"fontIDs":[],"textureIDs":\(textures),
          "allowedRotations":{"photoDegrees":\(photoRotation)},"overlapRanges":{"minimumVisibleFraction":\(minVisible)},
          "spacingRanges":{"marginMin":0.04,"marginMax":\(marginMax)},"densityProfile":["balanced"],
          "promptHints":[],"explorationWeight":0.3,\(tasteFields)
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

@Test func oldAndNewPacksDecodeAndPinsRemainStableAcrossUpdates() async throws {
    let old = try await StyleConfigClient.fetch(from: URL(string: "https://worker.test/v1/config?case=old")!, session: stubSession())
    #expect(old.stylePack.constitution == nil)
    let current = try await StyleConfigClient.fetch(from: URL(string: "https://worker.test/v1/config")!, session: stubSession())
    let pin = current.pin
    let newer = try await StyleConfigClient.fetch(from: URL(string: "https://worker.test/v1/config?case=newer")!, session: stubSession())
    #expect(current.stylePack.constitution == "Taste it")
    #expect(current.stylePack.referenceImages?.count == 1)
    #expect(current.stylePack.trendNotes == ["current"])
    #expect(current.stylePack.judge?.candidates == 6)
    #expect(pin == StylePackPin(id: "starter-editorial", version: "1.0.0"))
    #expect(newer.pin == StylePackPin(id: "starter-editorial", version: "1.1.0"))
    #expect(pin != newer.pin)
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

@Test(arguments: ["missing", "inactive", "bad-version", "http-error", "bad-margin", "bad-rotation", "bad-visibility", "bad-weight", "bad-decoration", "bad-texture", "bad-constitution", "bad-references", "bad-ref-count", "bad-trends", "bad-trend-count", "bad-judge", "bad-judge-low", "nonlocal-http"])
func remoteConfigRejectsInvalidActivePackAndHTTPFailures(caseName: String) async throws {
    let scheme = caseName == "nonlocal-http" ? "http" : "https"
    let url = URL(string: "\(scheme)://worker.test/v1/config?case=\(caseName)")!
    await #expect(throws: StyleConfigError.self) {
        try await StyleConfigClient.fetch(from: url, session: stubSession())
    }
}

import Foundation
import Testing
@testable import Core
@testable import Render

private final class RecipeConfigURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "recipes.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let variant = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "case" })?.value
        let data = Self.responseData(for: variant)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func responseData(for variant: String? = nil) -> Data {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Render/Resources/StylePacks/starter-editorial.json")
        var pack = try! JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        if let variant,
           var recipes = pack["recipes"] as? [[String: Any]],
           var pages = recipes[0]["pages"] as? [[String: Any]],
           var slots = pages[0]["photoSlots"] as? [[String: Any]] {
            switch variant {
            case "frame": slots[0]["frame"] = ["x": 0.8, "y": 0.1, "width": 0.5, "height": 0.4]
            case "aspect": slots[0]["aspectMin"] = -1
            case "rotations": slots[0]["rotationMin"] = 20
            case "six": slots.append(contentsOf: Array(repeating: slots[0], count: 6))
            case "font": var text = (pages[0]["textSlots"] as! [[String: Any]])[0]; text["fontID"] = "missing-font"; pages[0]["textSlots"] = [text]
            case "text-size": var text = (pages[0]["textSlots"] as! [[String: Any]])[0]; text["sizeMax"] = 300; pages[0]["textSlots"] = [text]
            case "gutter": pages[0]["gutter"] = ["min": 0.3, "max": 0.4]
            case "stickers": pages[0]["stickerBudget"] = [["category": "tape", "count": 20]]
            case "cross": slots[0]["allowCrossSlide"] = true; slots[0]["frame"] = ["x": 0.8, "y": 0.1, "width": 0.5, "height": 0.4]
            default: break
            }
            pages[0]["photoSlots"] = slots; recipes[0]["pages"] = pages; pack["recipes"] = recipes
        }
        return try! JSONSerialization.data(withJSONObject: ["configVersion": 1, "activeStylePack": "starter-editorial", "stylePacks": [pack]])
    }
}

private func recipeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RecipeConfigURLProtocol.self]
    return URLSession(configuration: config)
}

@Test func starterPackContainsValidatedStarterRecipesAndLegacyPacksStillDecode() async throws {
    let loaded = try await StyleConfigClient.fetch(from: URL(string: "https://recipes.test/v1/config")!, session: recipeSession())
    let recipes = try #require(loaded.stylePack.recipes)
    #expect(Set(recipes.map(\.family)) == Set(Recipe.Family.allCases))
    #expect(recipes.allSatisfy { (3...5).contains($0.pages.count) })
    #expect(recipes.flatMap(\.pages).allSatisfy { $0.photoSlots.count <= 6 })
    #expect(recipes.flatMap(\.pages).flatMap(\.textSlots).allSatisfy { $0.fontID.hasPrefix("font-") })
    let old = try JSONDecoder().decode(StylePack.self, from: Data(#"{"id":"old","version":"1.0.0","active":true,"minAppVersion":"0.1.0","primitiveWeights":{},"decorationIDs":[],"fontIDs":[],"textureIDs":[],"allowedRotations":{},"overlapRanges":{},"spacingRanges":{},"densityProfile":[],"promptHints":[],"explorationWeight":0.1}"#.utf8))
    #expect(old.recipes == nil)
}

@Test func recipeTypesEncodeDecode() throws {
    let root = try JSONSerialization.jsonObject(with: RecipeConfigURLProtocol.responseData()) as! [String: Any]
    let pack = try JSONSerialization.data(withJSONObject: (root["stylePacks"] as! [[String: Any]])[0])
    let recipe = try #require(try JSONDecoder().decode(StylePack.self, from: pack).recipes?.first)
    let data = try JSONEncoder().encode(recipe)
    #expect(try JSONDecoder().decode(Recipe.self, from: data) == recipe)
}

@Test(arguments: ["frame", "aspect", "rotations", "six", "font", "text-size", "gutter", "stickers", "cross"])
func recipeValidationRejectsInvalidData(caseName: String) async throws {
    await #expect(throws: StyleConfigError.self) {
        try await StyleConfigClient.fetch(from: URL(string: "https://recipes.test/v1/config?case=\(caseName)")!, session: recipeSession())
    }
}

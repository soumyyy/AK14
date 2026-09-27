import Foundation
import Testing
import TestSupport
@testable import Core
@testable import Analysis
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

@Test func generatedOptionsSelectDistinctCuratedRenderTreatmentsAndBaselineStaysClean() throws {
    let pack = try StylePackLoader.load()
    let assets: [AssetID] = [AssetID(rawValue: "photo-a")]
    let slides = [SlidePlan(primitive: .hero, mood: "", density: "balanced",
                            photos: [.plain(assets[0])], decorations: [], stamps: [])]
    let baseline = CarouselPlan(id: "baseline", brief: "", direction: nil, slides: slides)
    #expect(RecipeSelection.recipe(for: baseline, in: pack) == nil)

    func option(_ id: String, decoration: String, grouping: String, whitespace: String) -> CarouselPlan {
        let style = StyleVector(density: "balanced", overlap: "none", grouping: grouping,
                                decoration: decoration, rotation: "none", whitespace: whitespace)
        let direction = Direction(brief: "", style: style, coverAssetID: assets[0], orderedAssetIDs: assets)
        return CarouselPlan(id: id, brief: "", direction: direction, slides: slides)
    }
    let minimal = try #require(RecipeSelection.recipe(for: option("c1", decoration: "light", grouping: "single", whitespace: "tight"), in: pack))
    let journal = try #require(RecipeSelection.recipe(for: option("c2", decoration: "light", grouping: "single", whitespace: "airy"), in: pack))
    let scrapbook = try #require(RecipeSelection.recipe(for: option("c3", decoration: "rich", grouping: "single", whitespace: "tight"), in: pack))
    #expect(minimal.family == .minimal)
    #expect(journal.family == .journal)
    #expect(scrapbook.family == .scrapbook)
}

@Test func renderingUsesRecipeSlotsAndMaterialsWhileCleanBaselineRemainsDeterministic() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("recipe-source")
    try FixtureFactory.writeScene(to: folder.appending(path: "photo.jpg"), scene: 2)
    let record = try #require(try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos.first)
    let photo = ResolvedElement(kind: .photo, assetID: record.assetID, text: nil,
                                frame: UnitRect(x: 0.08, y: 0.08, width: 0.84, height: 0.82),
                                rotationDegrees: 0, crop: UnitRect(x: 0, y: 0, width: 1, height: 1),
                                zIndex: 0, opacity: 1, border: 0, shadow: false)
    let slide = ResolvedSlide(index: 0, primitive: .hero, requestedPrimitive: .hero, background: "plain",
                              grain: 0, filmEdge: false, elements: [photo], warnings: [])
    let carousel = ResolvedCarousel(id: "recipe-test", aspect: .portrait4x5, seed: "41",
                                    resolverVersion: ResolvedCarousel.resolverVersion, slides: [slide])
    let photos = [record.assetID: record]
    let renderer = CarouselRenderer()
    func render(_ name: String, recipe: Recipe? = nil) throws -> Data {
        let destination = tmp.url.appending(path: name, directoryHint: .isDirectory)
        _ = try renderer.render(carousel, photos: photos, sourceFolder: folder, outputDirectory: destination,
                                recipe: recipe, recipeText: "A day worth remembering")
        return try Data(contentsOf: destination.appending(path: "slide-01.png"))
    }
    let cleanFirst = try render("clean-a")
    let cleanAgain = try render("clean-b")
    #expect(cleanFirst == cleanAgain, "recipe-free output remains deterministic")
    let pack = try StylePackLoader.load()
    let journal = try #require(pack.recipes?.first { $0.family == .journal })
    let scrapbook = try #require(pack.recipes?.first { $0.family == .scrapbook })
    let minimal = try #require(pack.recipes?.first { $0.family == .minimal })
    let looks = [try render("minimal", recipe: minimal), try render("journal", recipe: journal),
                 try render("scrapbook", recipe: scrapbook)]
    #expect(Set(looks.map { $0.base64EncodedString() }).count == 3, "the curated recipe treatments render visibly distinct images")
    #expect(looks.allSatisfy { $0 != cleanFirst }, "recipes alter only the designed output; the clean baseline stays intact")
}

@Test(arguments: ["frame", "aspect", "rotations", "six", "font", "text-size", "gutter", "stickers", "cross"])
func recipeValidationRejectsInvalidData(caseName: String) async throws {
    await #expect(throws: StyleConfigError.self) {
        try await StyleConfigClient.fetch(from: URL(string: "https://recipes.test/v1/config?case=\(caseName)")!, session: recipeSession())
    }
}

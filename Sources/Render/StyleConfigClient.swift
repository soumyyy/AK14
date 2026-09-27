import Core
import Foundation

/// Stable identity for the style pack selected when a run is created. Persist this with the run so
/// rerenders keep using the same pack even after the Worker publishes a newer active version.
public struct StylePackPin: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

/// The validated active pack plus the metadata needed by a caller to pin it.
public struct LoadedStylePack: Sendable, Equatable {
    public let configVersion: Int
    public let activeStylePackID: String
    public let stylePack: StylePack
    public let pin: StylePackPin
    public let etag: String?

    public init(configVersion: Int, activeStylePackID: String, stylePack: StylePack, etag: String?) {
        self.configVersion = configVersion
        self.activeStylePackID = activeStylePackID
        self.stylePack = stylePack
        self.pin = StylePackPin(id: stylePack.id, version: stylePack.version)
        self.etag = etag
    }
}

public enum StyleConfigError: Error, LocalizedError, Sendable, Equatable {
    case insecureURL
    case invalidResponse
    case httpStatus(Int)
    case unsupportedConfigVersion(Int)
    case invalidActiveStylePackID(String)
    case missingOrDuplicateActivePack(String)
    case inactiveStylePack(String)
    case invalidStylePackVersion(String)
    case unsafeGeometry(String)
    case invalidNumericValue(String)
    case unsupportedDecorationID(String)
    case unsupportedTextureID(String)
    case assetManifestUnavailable
    case invalidConstitution
    case invalidReferenceImages
    case invalidTrendNotes
    case invalidJudgeConfig
    case invalidRecipes(String)
    case unsupportedRecipeFontID(String)
    case invalidDesignedSets(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL: "Style config URLs must use HTTPS; HTTP is allowed only for localhost development."
        case .invalidResponse: "The style config response was not a valid HTTP response."
        case .httpStatus(let status): "The style config request failed with HTTP \(status)."
        case .unsupportedConfigVersion(let version): "Unsupported style config version \(version)."
        case .invalidActiveStylePackID(let id): "Invalid active style pack ID: \(id)."
        case .missingOrDuplicateActivePack(let id): "Expected exactly one style pack with ID \(id)."
        case .inactiveStylePack(let id): "The active style pack \(id) is marked inactive."
        case .invalidStylePackVersion(let version): "Invalid style pack version: \(version)."
        case .unsafeGeometry(let field): "Unsafe style pack geometry value: \(field)."
        case .invalidNumericValue(let field): "Invalid numeric style pack value: \(field)."
        case .unsupportedDecorationID(let id): "Unsupported decoration ID: \(id)."
        case .unsupportedTextureID(let id): "Unsupported texture ID: \(id)."
        case .assetManifestUnavailable: "The bundled asset manifest could not be loaded."
        case .invalidConstitution: "Style pack constitution must be at most 4,000 characters."
        case .invalidReferenceImages: "Style pack reference images are invalid."
        case .invalidTrendNotes: "Style pack trend notes are invalid."
        case .invalidJudgeConfig: "Style pack judge configuration is invalid."
        case .invalidRecipes(let detail): "Style pack recipes are invalid: \(detail)."
        case .unsupportedRecipeFontID(let id): "Unsupported recipe font ID: \(id)."
        case .invalidDesignedSets(let detail): "Designed sets are invalid: \(detail)."
        }
    }
}

/// Fetches the Worker's `/v1/config` document and returns its active, validated StylePack.
/// This deliberately has no bundled fallback. Callers choose offline behavior explicitly by
/// catching an error and then calling `StylePackLoader.load()` if that is appropriate.
public enum StyleConfigClient {
    /// Config versions this build understands. The Worker must serve one of these (checked by WorkerConfigE2ETests),
    /// because shipped apps cannot be updated when the server moves on.
    public static let supportedConfigVersions: ClosedRange<Int> = 1...1

    public static func fetch(from url: URL, session: URLSession = .shared) async throws -> LoadedStylePack {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        guard scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1")) else {
            throw StyleConfigError.insecureURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Always revalidate (a cheap 304 when unchanged): a cached copy must never outlive a server-side fix.
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw StyleConfigError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw StyleConfigError.httpStatus(response.statusCode) }

        let config: StyleConfigDocument
        do { config = try JSONDecoder().decode(StyleConfigDocument.self, from: data) }
        catch { throw StyleConfigError.invalidResponse }

        guard supportedConfigVersions.contains(config.configVersion) else { throw StyleConfigError.unsupportedConfigVersion(config.configVersion) }
        guard isValidID(config.activeStylePack) else { throw StyleConfigError.invalidActiveStylePackID(config.activeStylePack) }
        let matches = config.stylePacks.filter { $0.id == config.activeStylePack }
        guard matches.count == 1 else { throw StyleConfigError.missingOrDuplicateActivePack(config.activeStylePack) }
        let pack = matches[0]
        guard pack.active else { throw StyleConfigError.inactiveStylePack(pack.id) }
        guard isValidVersion(pack.version) else { throw StyleConfigError.invalidStylePackVersion(pack.version) }
        try validate(pack)
        return LoadedStylePack(configVersion: config.configVersion, activeStylePackID: config.activeStylePack,
                              stylePack: pack, etag: response.value(forHTTPHeaderField: "etag"))
    }

    private static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
    }

    private static func isValidVersion(_ version: String) -> Bool {
        version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$", options: .regularExpression) != nil
    }

    private static func validate(_ pack: StylePack) throws {
        if let constitution = pack.constitution, constitution.count > 4_000 { throw StyleConfigError.invalidConstitution }
        if let images = pack.referenceImages {
            guard images.count <= 12, images.allSatisfy({ image in
                !image.id.isEmpty && image.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
                    && image.tags.allSatisfy { !$0.isEmpty }
            }) else { throw StyleConfigError.invalidReferenceImages }
        }
        if let notes = pack.trendNotes {
            guard notes.count <= 8, notes.allSatisfy({ $0.count <= 200 }) else {
                throw StyleConfigError.invalidTrendNotes
            }
        }
        if let judge = pack.judge, !(2...8).contains(judge.candidates) { throw StyleConfigError.invalidJudgeConfig }
        let numericGroups: [(String, [String: Double])] = [
            ("primitiveWeights", pack.primitiveWeights), ("allowedRotations", pack.allowedRotations),
            ("overlapRanges", pack.overlapRanges), ("spacingRanges", pack.spacingRanges),
        ]
        for (group, values) in numericGroups {
            for (key, value) in values where !value.isFinite || value < 0 {
                throw StyleConfigError.invalidNumericValue("\(group).\(key)")
            }
        }
        guard pack.explorationWeight.isFinite, pack.explorationWeight >= 0 else {
            throw StyleConfigError.invalidNumericValue("explorationWeight")
        }

        let marginMin = pack.spacingRanges["marginMin"] ?? 0.04
        let marginMax = pack.spacingRanges["marginMax"] ?? 0.07
        guard marginMin <= marginMax, marginMax <= 0.15 else {
            throw StyleConfigError.unsafeGeometry("spacingRanges.marginMin/marginMax")
        }
        let photoRotation = pack.allowedRotations["photoDegrees"] ?? 2
        let decorationRotation = pack.allowedRotations["decorationDegrees"] ?? 4
        guard photoRotation <= 5, decorationRotation <= 10 else {
            throw StyleConfigError.unsafeGeometry("allowedRotations")
        }
        let minVisible = pack.overlapRanges["minimumVisibleFraction"] ?? 0.55
        guard minVisible >= 0.55, minVisible <= 1 else {
            throw StyleConfigError.unsafeGeometry("overlapRanges.minimumVisibleFraction")
        }

        let assets: Set<String>
        let manifestFonts: Set<String>
        do {
            guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Assets") else {
                throw StyleConfigError.assetManifestUnavailable
            }
            let manifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
            assets = Set(manifest.assets.map(\.assetID))
            manifestFonts = Set(manifest.assets.filter { $0.assetType == "font" }.map(\.assetID))
        } catch let error as StyleConfigError { throw error }
        catch { throw StyleConfigError.assetManifestUnavailable }

        // Manifest entries identify bundled assets; this explicit set ensures every decoration is
        // also handled by the renderer. Date stamps are a built-in renderer feature without an asset.
        let renderedDecorations: Set<String> = ["grain-fine", "paper-warm", "tape-clear", "film-edge", "date-stamp"]
        for id in pack.decorationIDs where !renderedDecorations.contains(id) || (id != "date-stamp" && !assets.contains(id)) {
            throw StyleConfigError.unsupportedDecorationID(id)
        }
        let renderedTextures: Set<String> = ["paper-warm"]
        for id in pack.textureIDs where !renderedTextures.contains(id) || !assets.contains(id) {
            throw StyleConfigError.unsupportedTextureID(id)
        }
        if let recipes = pack.recipes {
            guard Set(recipes.map(\.id)).count == recipes.count else { throw StyleConfigError.invalidRecipes("duplicate IDs") }
            for recipe in recipes {
                guard !recipe.id.isEmpty, recipe.version > 0, !recipe.pages.isEmpty,
                      !recipe.slideRoles.isEmpty,
                      recipe.axes.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw StyleConfigError.invalidRecipes("metadata or axes")
                }
                for page in recipe.pages {
                    guard page.photoSlots.count <= 6 else { throw StyleConfigError.invalidRecipes("more than six photo slots") }
                    for slot in page.photoSlots {
                        let f = slot.frame
                        let boundsOK = f.x.isFinite && f.y.isFinite && f.width.isFinite && f.height.isFinite && f.width > 0 && f.height > 0 && f.x >= 0 && f.y >= 0 && (slot.allowCrossSlide && recipe.family == .panorama || f.x + f.width <= 1 && f.y + f.height <= 1)
                        guard boundsOK else { throw StyleConfigError.invalidRecipes("photo frame outside page") }
                        guard slot.aspectMin.isFinite, slot.aspectMax.isFinite, slot.aspectMin > 0, slot.aspectMin <= slot.aspectMax,
                              slot.rotationMin.isFinite, slot.rotationMax.isFinite, slot.rotationMin <= slot.rotationMax,
                              abs(slot.rotationMin) <= 15, abs(slot.rotationMax) <= 15 else { throw StyleConfigError.invalidRecipes("photo slot ranges") }
                    }
                    for slot in page.textSlots {
                        guard manifestFonts.contains(slot.fontID) else { throw StyleConfigError.unsupportedRecipeFontID(slot.fontID) }
                        guard slot.sizeMin.isFinite, slot.sizeMax.isFinite, slot.sizeMin > 0, slot.sizeMin <= slot.sizeMax, slot.sizeMax <= 200 else { throw StyleConfigError.invalidRecipes("text size range") }
                    }
                    guard validRange(page.gutter, maximum: 0.25), validRange(page.margin, maximum: 0.35),
                          page.stickerBudget.allSatisfy({ (0...12).contains($0.count) }) else { throw StyleConfigError.invalidRecipes("page spacing or sticker budget") }
                }
            }
        }
        if let file = pack.designedSetsFile {
            guard file.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  let url = Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "StylePacks") else {
                throw StyleConfigError.invalidDesignedSets("missing or unsafe resource name")
            }
            do {
                let library = try JSONDecoder().decode(DesignedSetLibrary.self, from: Data(contentsOf: url))
                if let error = library.validationError() { throw StyleConfigError.invalidDesignedSets(error) }
            } catch let error as StyleConfigError { throw error }
            catch { throw StyleConfigError.invalidDesignedSets("cannot decode library") }
        }
    }

    private static func validRange(_ range: Recipe.RangeRule, maximum: Double) -> Bool {
        range.min.isFinite && range.max.isFinite && range.min >= 0 && range.min <= range.max && range.max <= maximum
    }
}

private struct StyleConfigDocument: Decodable {
    let configVersion: Int
    let activeStylePack: String
    let stylePacks: [StylePack]
}

private struct AssetManifest: Decodable {
    struct Asset: Decodable { let assetID: String; let assetType: String? }
    let assets: [Asset]
}

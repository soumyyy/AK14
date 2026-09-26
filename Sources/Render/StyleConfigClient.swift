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
        }
    }
}

/// Fetches the Worker's `/v1/config` document and returns its active, validated StylePack.
/// This deliberately has no bundled fallback. Callers choose offline behavior explicitly by
/// catching an error and then calling `StylePackLoader.load()` if that is appropriate.
public enum StyleConfigClient {
    public static func fetch(from url: URL, session: URLSession = .shared) async throws -> LoadedStylePack {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        guard scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1")) else {
            throw StyleConfigError.insecureURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw StyleConfigError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw StyleConfigError.httpStatus(response.statusCode) }

        let config: StyleConfigDocument
        do { config = try JSONDecoder().decode(StyleConfigDocument.self, from: data) }
        catch { throw StyleConfigError.invalidResponse }

        guard config.configVersion == 1 else { throw StyleConfigError.unsupportedConfigVersion(config.configVersion) }
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
        do {
            guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Assets") else {
                throw StyleConfigError.assetManifestUnavailable
            }
            assets = Set(try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url)).assets.map(\.assetID))
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
    }
}

private struct StyleConfigDocument: Decodable {
    let configVersion: Int
    let activeStylePack: String
    let stylePacks: [StylePack]
}

private struct AssetManifest: Decodable {
    struct Asset: Decodable { let assetID: String }
    let assets: [Asset]
}

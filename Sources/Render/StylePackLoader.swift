import Core
import Foundation

public enum StylePackLoader {
    public static let defaultID = "starter-editorial"

    public static func load(id: String = defaultID) throws -> StylePack {
        guard let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "StylePacks") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "unknown style pack \(id)"])
        }
        return try JSONDecoder().decode(StylePack.self, from: Data(contentsOf: url))
    }

    public static func loadDesignedSets(file: String = "designed-sets") throws -> DesignedSetLibrary {
        guard let url = Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "StylePacks") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "unknown designed set library \(file)"])
        }
        return try JSONDecoder().decode(DesignedSetLibrary.self, from: Data(contentsOf: url))
    }
}

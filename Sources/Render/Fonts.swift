import CoreText
import Foundation

/// Registers every bundled font listed by the asset manifest exactly once per process.
public enum BundledFonts {
    private static let names: [String: String] = register()

    public static func font(id: String, size: Double) -> CTFont {
        let name = names[id] ?? (id == "DSEG7Classic-Bold" ? id : "Inter-Regular")
        return CTFontCreateWithName(name as CFString, CGFloat(size), nil)
    }

    /// Every asset-manifest font id that registered successfully with Core Text, for tests that need to
    /// exercise the whole typography kit without duplicating `Bundle.module` asset-manifest lookup.
    public static var registeredIDs: [String] { names.keys.sorted() }

    private static func register() -> [String: String] {
        var names: [String: String] = [:]
        guard let manifestURL = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Assets"),
              let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return names }
        for asset in assets where asset["assetType"] as? String == "font" {
            guard let id = asset["assetID"] as? String, let path = asset["relativePath"] as? String else { continue }
            let parts = path.split(separator: "/").map(String.init)
            guard let filename = parts.last else { continue }
            let subdirectory = "Assets/" + parts.dropLast().joined(separator: "/")
            guard let url = Bundle.module.url(forResource: (filename as NSString).deletingPathExtension,
                                              withExtension: (filename as NSString).pathExtension,
                                              subdirectory: subdirectory),
                  let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let cgFont = CGFont(provider) else { continue }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) || error == nil {
                names[id] = CTFontCopyPostScriptName(CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)) as String
            }
        }
        return names
    }
}

import CryptoKit
import Foundation

public struct Prompt: Sendable {
    public let text: String
    /// "<name> v<N>+<sha8>" from the header line `<!-- prompt: <name> v<N> -->` and the content digest.
    public let version: String
}

public enum Prompts {
    public static func load(_ name: String) throws -> Prompt {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "missing prompt \(name)"])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let header = text.split(separator: "\n").first.map(String.init) ?? ""
        let tag = header.firstMatch(of: /prompt:\s*(\S+)\s+(v\d+)/).map { "\($0.1) \($0.2)" } ?? "\(name) v0"
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return Prompt(text: text, version: "\(tag)+\(digest)")
    }
}

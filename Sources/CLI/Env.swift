import Foundation

enum Env {
    /// OPENAI_API_KEY from the environment, else from `.env` in the working directory. Never logged.
    static func apiKey(cwd: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let key = environment["OPENAI_API_KEY"], !key.isEmpty { return key }
        guard let text = try? String(contentsOf: cwd.appending(path: ".env"), encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<eq].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            guard name == "OPENAI_API_KEY" else { continue }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

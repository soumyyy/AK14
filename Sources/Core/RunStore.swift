import Foundation

public enum RunID {
    public static func make(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d",
                           c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        return "\(stamp)-\(suffix)"
    }
}

public struct RunStore: Sendable {
    public let root: URL

    public static func create(in runsDirectory: URL, runID: String) throws -> RunStore {
        let root = runsDirectory.appending(path: runID)
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return RunStore(root: root)
    }

    public static func open(_ root: URL) -> RunStore { RunStore(root: root) }

    public func url(_ relativePath: String) -> URL { root.appending(path: relativePath) }

    public func write<T: Encodable>(_ value: T, to relativePath: String) throws {
        try writeData(JSONCoding.encoder.encode(value), to: relativePath)
    }

    public func writeText(_ text: String, to relativePath: String) throws {
        try writeData(Data(text.utf8), to: relativePath)
    }

    public func read<T: Decodable>(_ type: T.Type, from relativePath: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(contentsOf: url(relativePath)))
    }

    private func writeData(_ data: Data, to relativePath: String) throws {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}

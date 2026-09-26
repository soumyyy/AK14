import Foundation

/// One behavioural event (spec §9.5). No image content, no free text.
public struct InteractionEvent: Codable, Sendable, Equatable {
    public var eventID: String
    public var runID: String
    public var timestamp: Date
    public var event: String
    public var conceptID: String?
    public var slideIndex: Int?
    public var assetIDs: [AssetID]?
    public var before: [String]?
    public var after: [String]?
    /// "operator" or "participant".
    public var source: String

    public init(eventID: String, runID: String, timestamp: Date, event: String, conceptID: String?, slideIndex: Int?,
                assetIDs: [AssetID]?, before: [String]?, after: [String]?, source: String) {
        self.eventID = eventID; self.runID = runID; self.timestamp = timestamp; self.event = event
        self.conceptID = conceptID; self.slideIndex = slideIndex; self.assetIDs = assetIDs
        self.before = before; self.after = after; self.source = source
    }
}

/// Append-only `interaction-events.jsonl` in the run directory.
public struct InteractionLog: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func append(_ e: InteractionEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(e); line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func read() -> [InteractionEvent] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(InteractionEvent.self, from: Data($0.utf8)) }
    }
}

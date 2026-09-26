import Core
import Foundation

/// Best-effort participant event logging for one generated run.
final class InteractionRecorder: @unchecked Sendable {
    let runDirectory: URL
    private let runID: String
    private let queue = DispatchQueue(label: "com.ak14.interaction-log", qos: .utility)

    init(runDirectory: URL) {
        self.runDirectory = runDirectory.standardizedFileURL
        runID = self.runDirectory.lastPathComponent
    }

    func record(_ event: String, conceptID: String? = nil, slideIndex: Int? = nil,
                assetIDs: [AssetID]? = nil, before: [String]? = nil, after: [String]? = nil) {
        queue.async { [runDirectory, runID] in
            guard FileManager.default.fileExists(atPath: runDirectory.path) else { return }
            let entry = InteractionEvent(eventID: UUID().uuidString, runID: runID, timestamp: Date(), event: event,
                                         conceptID: conceptID, slideIndex: slideIndex, assetIDs: assetIDs,
                                         before: before, after: after, source: "participant")
            try? InteractionLog(url: runDirectory.appending(path: "interaction-events.jsonl")).append(entry)
        }
    }
}

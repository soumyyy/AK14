import Core
import Foundation

/// One small, optional occasion-classification request over local analysis thumbnails.
/// Callers invoke this only after the user has opted into model assistance.
public enum OccasionSplitter {
    public static let maxRepresentatives = 12
    public static let maximumEstimatedCost = 0.001
    public static let timeout: Duration = .seconds(20)

    public struct Result: Sendable {
        public let events: [EventSegment]
        public let call: ProviderCallRecord
        public let exchange: Exchange
        public let promptVersion: String
    }

    private struct Groups: Decodable { let groups: [[String]] }
    private struct Timeout: Error {}

    /// Returns nil on a malformed, incomplete, failed, or timed-out response; callers retain
    /// their deterministic local segmentation in all such cases.
    public static func split(events: [EventSegment], photos: [PhotoRecord], thumbnails: [AssetID: URL],
                             features: [AssetID: PhotoFeatures] = [:],
                             client: ResponsesClient, timeout limit: Duration = timeout) async -> Result? {
        guard events.count > 1 || photos.count >= 6 else { return nil }
        guard let prompt = try? Prompts.load("occasion-split.system") else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
        let representatives = selectRepresentatives(events: events, photos: byID, features: features)
        guard representatives.count >= 4, representatives.count <= maxRepresentatives,
              representatives.allSatisfy({ thumbnails[$0] != nil }) else { return nil }
        var assembled: [ContentPart] = [.text("Group these representative thumbnails into distinct occasions. Keep a continuous trip together across changing scenery. Separate a wedding or other clearly different gathering from a trip. Return every supplied id exactly once. Use at least two representatives per group; if they are one occasion, return one group." )]
        var imageBytes = 0
        for (index, id) in representatives.enumerated() {
            guard byID[id] != nil, let url = thumbnails[id], let data = try? Data(contentsOf: url) else { return nil }
            imageBytes += data.count
            guard imageBytes <= 512 * 1024 else { return nil }
            let localEvent = events.firstIndex { $0.assetIDs.contains(id) }.map { $0 + 1 } ?? 0
            assembled.append(.text("local event group \(localEvent), chronological representative \(index + 1), id \(id.rawValue)"))
            assembled.append(.image(jpeg: data, assetID: id, detail: "low"))
        }
        let content = assembled
        // Twelve low-detail images (85 tokens each), bounded text, and a hard output ceiling
        // keep the preflight estimate below one tenth of a cent at the pinned Luna rates.
        let preflightInputTokens = maxRepresentatives * 85 + 1_200
        guard Pricing.estimate(Usage(input: preflightInputTokens, output: 1_200)) <= maximumEstimatedCost else { return nil }
        let schema = JSONValue.obj([("groups", .arr(.arr(.str(representatives.map(\.rawValue)), min: 2, max: maxRepresentatives), min: 1, max: maxRepresentatives))])
        let response: ResponsesResult
        do {
            response = try await withThrowingTaskGroup(of: ResponsesResult.self) { group in
                group.addTask {
                    try await client.call(system: prompt.text, content: content, schemaName: "occasion_split",
                                          schema: schema, reasoning: "low", maxOutputTokens: 1200)
                }
                group.addTask {
                    try await Task.sleep(for: limit)
                    throw Timeout()
                }
                guard let first = try await group.next() else { throw Timeout() }
                group.cancelAll()
                return first
            }
        } catch { return nil }
        guard let decoded = try? JSONDecoder().decode(Groups.self, from: Data(response.outputText.utf8)) else { return nil }
        guard Pricing.estimate(response.usage) <= maximumEstimatedCost else { return nil }
        let all = decoded.groups.flatMap { $0 }
        guard Set(all) == Set(representatives.map(\.rawValue)), all.count == representatives.count,
              decoded.groups.allSatisfy({ $0.count >= 2 }) else { return nil }
        let assignment = Dictionary(uniqueKeysWithValues: decoded.groups.enumerated().flatMap { group, ids in
            ids.map { ($0, group) }
        })
        var grouped: [[PhotoRecord]] = Array(repeating: [], count: decoded.groups.count)
        for event in events {
            let reps = representatives.filter { event.assetIDs.contains($0) }
            guard !reps.isEmpty else { continue }
            for id in event.assetIDs {
                guard let photo = byID[id] else { continue }
                let nearest = reps.min {
                    abs((captureTime($0, byID: byID) ?? .distantPast).timeIntervalSince(photo.metadata.capturedAt ?? .distantPast)) <
                    abs((captureTime($1, byID: byID) ?? .distantPast).timeIntervalSince(photo.metadata.capturedAt ?? .distantPast))
                }!
                if let bucket = assignment[nearest.rawValue] { grouped[bucket].append(photo) }
            }
        }
        guard grouped.allSatisfy({ $0.count >= 3 }) else { return nil }
        let orderedGroups = grouped.sorted {
            ($0.compactMap(\.metadata.capturedAt).min() ?? .distantPast) <
            ($1.compactMap(\.metadata.capturedAt).min() ?? .distantPast)
        }
        let resultEvents = orderedGroups.enumerated().map { index, group in
            let dates = group.compactMap(\.metadata.capturedAt)
            return EventSegment(index: index + 1, start: dates.min(), end: dates.max(), assetIDs: group.map(\.assetID).sorted())
        }
        var call = ProviderCallRecord(stage: "occasion_split", model: client.model, promptVersion: prompt.version)
        call.candidateCount = representatives.count
        call.inputTokens = response.usage.input; call.cachedTokens = response.usage.cached
        call.outputTokens = response.usage.output; call.reasoningTokens = response.usage.reasoning
        call.imageCount = response.imageCount; call.thumbnailBytes = response.imageBytes
        call.latencySeconds = response.latencySeconds; call.retryCount = response.retryCount
        call.estimatedCost = Pricing.estimate(response.usage); call.ok = true; call.responseID = response.responseID
        return Result(events: resultEvents, call: call,
                      exchange: Exchange(name: "occasion-split", request: response.redactedRequest, response: response.rawResponse),
                      promptVersion: prompt.version)
    }

    private static func selectRepresentatives(events: [EventSegment], photos: [AssetID: PhotoRecord],
                                              features: [AssetID: PhotoFeatures]) -> [AssetID] {
        // Two representatives from every locally detected cluster guarantee coverage of a
        // smaller occasion before larger-event samples consume the thumbnail budget.
        guard events.count <= maxRepresentatives / 2,
              events.allSatisfy({ $0.photoCount >= 2 }) else { return [] }
        var chosen: [AssetID] = []
        for event in events {
            let ordered = event.assetIDs.compactMap { photos[$0] }.sorted {
                ($0.metadata.capturedAt ?? .distantPast, $0.assetID) < ($1.metadata.capturedAt ?? .distantPast, $1.assetID)
            }
            guard ordered.count >= 2 else { return [] }
            let signatures = ordered.map { photo in
                Set(features[photo.assetID]?.labels.prefix(8).map { $0.identifier.lowercased() } ?? [])
                    .subtracting(["people", "adult", "outdoor", "sky", "land", "structure"])
            }
            var strongestBoundary: (index: Int, score: Double)?
            if ordered.count > 1 {
                for i in 1..<ordered.count {
                    let a = signatures[i - 1], b = signatures[i]
                    let sceneChange = Double(a.symmetricDifference(b).count) / Double(max(1, a.union(b).count))
                    let timeGap = ordered[i].metadata.capturedAt?.timeIntervalSince(ordered[i - 1].metadata.capturedAt ?? .distantPast) ?? 0
                    let score = sceneChange + (timeGap >= 4 * 3_600 ? 0.2 : 0)
                    if strongestBoundary.map({ score > $0.score }) ?? true { strongestBoundary = (i, score) }
                }
            }
            if let boundary = strongestBoundary, boundary.score >= 0.55 {
                chosen.append(ordered[boundary.index - 1].assetID)
                chosen.append(ordered[boundary.index].assetID)
            } else {
                chosen.append(ordered[ordered.count / 3].assetID)
                chosen.append(ordered[(ordered.count * 2) / 3].assetID)
            }
        }
        if chosen.count > maxRepresentatives { return [] }
        let remaining = maxRepresentatives - chosen.count
        let all = photos.values.sorted {
            ($0.metadata.capturedAt ?? .distantPast, $0.assetID) < ($1.metadata.capturedAt ?? .distantPast, $1.assetID)
        }.filter { !chosen.contains($0.assetID) }
        for index in 0..<min(remaining, all.count) {
            let position = min(all.count - 1, (index * (all.count - 1)) / max(1, min(remaining, all.count) - 1))
            let id = all[position].assetID
            if !chosen.contains(id) { chosen.append(id) }
        }
        return chosen.sorted {
            (captureTime($0, byID: photos) ?? .distantPast, $0) < (captureTime($1, byID: photos) ?? .distantPast, $1)
        }
    }

    private static func captureTime(_ id: AssetID, byID: [AssetID: PhotoRecord]) -> Date? { byID[id]?.metadata.capturedAt }
}

import Foundation
import Testing
import TestSupport
@testable import CLI
@testable import Core
@testable import Director

/// One event per day in `days`, with `counts[i]` photos an hour apart (the fake planner needs 6+ per event).
private func eventFixture(_ tmp: TempDirectory, days: [Int], counts: [Int]? = nil) throws -> URL {
    let folder = try tmp.sub("events")
    var n = 0
    for (i, day) in days.enumerated() {
        for hour in 8..<(8 + (counts?[i] ?? 8)) {
            var exif = FixtureFactory.Exif()
            exif.date = String(format: "2026:06:%02d %02d:00:00", day, hour)
            exif.latitude = 37.0; exif.longitude = -122.0
            try FixtureFactory.writeScene(to: folder.appending(path: "photo\(n).jpg"), scene: n + 30, exif: exif)
            n += 1
        }
    }
    return folder
}

private func eventRun(_ tmp: TempDirectory, folder: URL, model: FakeModel, event: Int? = nil,
                      all: Bool = false, story: String? = nil) async throws -> RunStore {
    var options = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                             cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
    options.event = event; options.allEvents = all; options.story = story
    let client = ResponsesClient(transport: model, sleep: { _ in })
    return try await RunPipeline.live(options: options, client: client, log: { _ in }).run(options)
}

@Test func eventSelectionLimitsPipelinePhotosAndPersistsChoices() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try eventFixture(tmp, days: [1, 5, 9], counts: [8, 12, 8])
    // Default: the largest event only.
    let defaultRun = try await eventRun(tmp, folder: folder, model: FakeModel())
    let manifest = try defaultRun.read(RunManifest.self, from: "manifest.json")
    #expect(manifest.events.count == 3 && manifest.events.map(\.photoCount) == [8, 12, 8])
    #expect(manifest.chosenEvent == 2 && manifest.photoCount == 12)
    #expect(try defaultRun.read(IngestResult.self, from: "input-index.json").photos.count == 12)

    let event1 = try await eventRun(tmp, folder: folder, model: FakeModel(), event: 1)
    let m1 = try event1.read(RunManifest.self, from: "manifest.json")
    #expect(m1.chosenEvent == 1 && m1.photoCount == 8)
    let all = try await eventRun(tmp, folder: folder, model: FakeModel(), all: true)
    let allManifest = try all.read(RunManifest.self, from: "manifest.json")
    #expect(allManifest.chosenEvent == nil && allManifest.photoCount == 28)
}

@Test func consecutiveTripDaysRemainOneEvent() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let photos = (0..<3).map { i in
        PhotoRecord(assetID: AssetID(rawValue: "trip\(i)"), contentSHA256: "\(i)", sourceRelativePaths: ["\(i).jpg"],
                    byteCount: 1, fileType: "public.jpeg", pixelWidth: 20, pixelHeight: 20, exifOrientation: 1,
                    metadata: CaptureMetadata(capturedAt: base.addingTimeInterval(Double(i) * 86_400 + 3_600)))
    }
    #expect(EventSegmenter.segment(photos).count == 1)
}

@Test func storyHintReachesModelRequestsAndManifestAndLongHintIsRejected() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try eventFixture(tmp, days: [1])
    let hint = "A quiet weekend with friends; leave out the restaurant photos."
    let store = try await eventRun(tmp, folder: folder, model: FakeModel(), story: hint)
    #expect(try store.read(RunManifest.self, from: "manifest.json").storyHint == hint)
    for file in ["llm/1-triage.json", "llm/2-planner.json"] {
        let data = try Data(contentsOf: store.url(file))
        #expect(String(decoding: data, as: UTF8.self).contains(hint))
    }
    do {
        _ = try Arguments.parse(["run", folder.path, "--story", String(repeating: "x", count: 281)], cwd: tmp.url)
        Issue.record("281-character story hint should be rejected")
    } catch let error as ArgumentError {
        #expect(error.description.contains("at most 280 characters"))
    }
}

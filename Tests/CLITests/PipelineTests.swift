import Foundation
import Testing
import TestSupport
@testable import Analysis
@testable import CLI
@testable import Core

private func options(_ tmp: TempDirectory, folder: URL) -> RunOptions {
    RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
               cacheDirectory: tmp.url.appending(path: "cache"))
}

private func run(_ o: RunOptions, now: Date = Date()) async throws -> RunStore {
    try await RunPipeline.live(options: o, log: { _ in }).run(o, now: now)
}

/// Full pipeline over a mixed folder: classification, metadata, orientation, duplicates, cache reuse,
/// rename stability, report escaping, and no absolute paths or coordinates in the report.
@Test func mixedFolderEndToEnd() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("event & <friends>")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "IMG_0001.JPG"), gray: 0.2)       // uppercase ext
    var rotated = FixtureFactory.Exif(); rotated.orientation = 6                                   // 90° CW -> portrait
    try FixtureFactory.writeJPEG(to: folder.appending(path: "rotated.jpg"), gray: 0.8, exif: rotated)
    var received = FixtureFactory.Exif(); received.model = nil; received.latitude = nil; received.offset = nil
    try FixtureFactory.writeJPEG(to: folder.appending(path: "wa <img>.jpg"), gray: 0.5, exif: received)
    try FileManager.default.copyItem(at: folder.appending(path: "IMG_0001.JPG"),
                                     to: folder.appending(path: "IMG_0001 copy.JPG"))          // exact duplicate
    try FixtureFactory.writeBytes("mov", to: folder.appending(path: "clip.MOV"))
    try FixtureFactory.writeBytes("hello", to: folder.appending(path: "notes.txt"))
    try FixtureFactory.writeBytes("garbage", to: folder.appending(path: "broken.jpg"))
    try FixtureFactory.writeBytes("x", to: folder.appending(path: ".DS_Store"))
    _ = try tmp.sub("event & <friends>/nested")
    let o = options(tmp, folder: folder)

    // First run: cold cache.
    let first = try await run(o, now: Date(timeIntervalSince1970: 1_000))
    let m1 = try first.read(RunManifest.self, from: "manifest.json")
    let index1 = try first.read(IngestResult.self, from: "input-index.json")
    #expect(m1.photoCount == 3 && m1.skippedCount == 5)
    #expect(m1.cacheMisses == 3 && m1.cacheHits == 0)
    #expect(m1.warnings.isEmpty, "\(m1.warnings)")
    #expect(m1.stageTimings.map(\.stage) == ["ingest", "thumbnails", "analysis"])
    #expect(m1.aspectRatio == .portrait4x5 && !m1.aspectOverridden)     // 1 portrait of 3 -> mixed
    #expect(m1.versions["analyzer"] == VisionAnalyzer.version)

    let reasons = Dictionary(uniqueKeysWithValues: index1.skipped.map { ($0.relativePath, $0.reason) })
    #expect(reasons == ["clip.MOV": .video, "notes.txt": .unsupportedType, "broken.jpg": .decodeFailure,
                        ".DS_Store": .hiddenFile, "nested": .directory])

    let dup = try #require(index1.photos.first { $0.sourceRelativePaths.count == 2 })
    #expect(dup.sourceRelativePaths == ["IMG_0001 copy.JPG", "IMG_0001.JPG"])
    #expect(dup.fileType == "public.jpeg" && dup.metadata.cameraModel == "iPhone 17")
    #expect(dup.metadata.capturedAt == ISO8601DateFormatter().date(from: "2026-05-29T12:00:03Z"))
    #expect(dup.assetID == AssetID(sha256Hex: dup.contentSHA256))

    let rot = try #require(index1.photos.first { $0.sourceRelativePaths == ["rotated.jpg"] })
    #expect(rot.pixelWidth == 300 && rot.pixelHeight == 400 && rot.orientation == .portrait)

    let wa = try #require(index1.photos.first { $0.sourceRelativePaths == ["wa <img>.jpg"] })
    #expect(wa.metadata.cameraModel == nil && wa.metadata.location == nil && wa.metadata.timeZoneAssumed)

    let feats = try first.read([PhotoFeatures].self, from: "cache/features.json")
    #expect(feats.count == 3 && feats.allSatisfy { $0.failures.isEmpty && $0.aestheticScore != nil })
    for id in index1.photos.map(\.assetID) {
        #expect(FileManager.default.fileExists(atPath: first.url("cache/thumbnails/analysis/\(id.rawValue).jpg").path))
    }

    // Second run after a rename: warm cache, same IDs, same input digest.
    try FileManager.default.moveItem(at: folder.appending(path: "rotated.jpg"), to: folder.appending(path: "renamed.jpg"))
    let second = try await run(o, now: Date(timeIntervalSince1970: 2_000))
    let m2 = try second.read(RunManifest.self, from: "manifest.json")
    #expect(m2.cacheHits == 3 && m2.cacheMisses == 0)
    #expect(m2.inputDigest == m1.inputDigest)
    #expect(try second.read(IngestResult.self, from: "input-index.json").photos.map(\.assetID) == index1.photos.map(\.assetID))

    let html = try String(contentsOf: second.url("report.html"), encoding: .utf8)
    #expect(html.contains("renamed.jpg"))
    #expect(html.contains("event &amp; &lt;friends&gt;"))
    #expect(html.contains("wa &lt;img&gt;.jpg"))
    #expect(!html.contains("<friends>") && !html.contains("<img>"))
    #expect(!html.contains(tmp.url.path))
    #expect(!html.contains("15.49") && !html.contains("73.82"))

    // Report rebuild from stored artifacts reproduces the same HTML.
    try FileManager.default.removeItem(at: second.url("report.html"))
    try ReportCommand.rebuild(runDirectory: second.root)
    #expect(try String(contentsOf: second.url("report.html"), encoding: .utf8) == html)
}

@Test func recursiveRunThroughSymlinkAndAspectOverride() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let day2 = try tmp.sub("real/day2")
    var portrait = FixtureFactory.Exif(); portrait.orientation = 6
    try FixtureFactory.writeJPEG(to: day2.appending(path: "x.jpg"), exif: portrait)
    let link = tmp.url.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tmp.url.appending(path: "real"))

    var o = options(tmp, folder: link); o.recursive = true
    let inferred = try await run(o)
    #expect(try inferred.read(IngestResult.self, from: "input-index.json").photos.map(\.sourceRelativePaths) == [["day2/x.jpg"]])
    #expect(try inferred.read(RunManifest.self, from: "manifest.json").aspectRatio == .portrait3x4)

    o.aspect = .square
    let m = try await run(o).read(RunManifest.self, from: "manifest.json")
    #expect(m.aspectRatio == .square && m.aspectOverridden)
}

@Test func videoOnlyFolderCompletes() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("videos")
    try FixtureFactory.writeBytes("m", to: folder.appending(path: "x.mp4"))
    let store = try await run(options(tmp, folder: folder))
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.photoCount == 0 && m.skippedCount == 1 && m.aspectRatio == .portrait4x5)
    #expect(try String(contentsOf: store.url("report.html"), encoding: .utf8).contains("No photos were ingested"))
}

@Test func missingFolderFails() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    await #expect(throws: (any Error).self) { _ = try await run(options(tmp, folder: tmp.url.appending(path: "nope"))) }
}

// MARK: - Review fixes

@Test func missingFolderFailsInRecursiveModeAndForFiles() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    var o = options(tmp, folder: tmp.url.appending(path: "Pictues")); o.recursive = true
    await #expect(throws: (any Error).self) { _ = try await run(o) }
    let file = tmp.url.appending(path: "a.jpg")
    try FixtureFactory.writeJPEG(to: file)
    var f = options(tmp, folder: file); f.recursive = true
    await #expect(throws: (any Error).self) { _ = try await run(f) }
}

@Test func recursiveRunSkipsPackagesAndOwnOutput() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("trip")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "a.jpg"))
    let package = try tmp.sub("trip/Library.app")          // package bundle: must not be descended
    try FixtureFactory.writeJPEG(to: package.appending(path: "internal.jpg"), gray: 0.9)
    // Output and cache live inside the input folder, like `cd trip && ak14 run . --recursive`.
    let o = RunOptions(folder: folder, recursive: true,
                       runsDirectory: folder.appending(path: "runs"), cacheDirectory: folder.appending(path: ".ak14-cache"))
    _ = try await run(o, now: Date(timeIntervalSince1970: 1))
    let second = try await run(o, now: Date(timeIntervalSince1970: 2))
    let index = try second.read(IngestResult.self, from: "input-index.json")
    #expect(index.photos.map(\.sourceRelativePaths) == [["a.jpg"]])
}

@Test func runArtifactsContainNoCoordinates() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("gps")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "a.jpg"))
    let store = try await run(options(tmp, folder: folder))
    let index = try store.read(IngestResult.self, from: "input-index.json")
    #expect(index.photos[0].metadata.location == nil)
    #expect(index.photos[0].metadata.hasLocation)
    for file in ["input-index.json", "manifest.json", "cache/features.json", "report.html"] {
        let text = try String(contentsOf: store.url(file), encoding: .utf8)
        #expect(!text.contains("15.49") && !text.contains("73.82"), "\(file) leaks coordinates")
    }
}

@Test func analysisCacheIsKeyedByThumbnailerVersionToo() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("v")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "a.jpg"))
    _ = try await run(options(tmp, folder: folder))
    let dir = tmp.url.appending(path: "cache/features/\(VisionAnalyzer.version)+\(Thumbnailer.version)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
}

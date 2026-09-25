# M1 — Harness, Analyzer, and Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ak14 run <folder>` ingests a photo folder, builds oriented thumbnails, extracts Vision features with a persistent cache, and writes a run directory with `manifest.json`, `input-index.json`, `cache/features.json` and a self-contained `report.html` contact sheet. It makes no LLM calls.

**Architecture:** One SwiftPM package. `Core` holds Foundation-only models, protocols, caching, the run store and the report builder. `Analysis` holds ImageIO/Vision ingest, thumbnailing and feature extraction. `CLI` (executable `ak14`) holds argument parsing and the pipeline that composes them. `Director`, `Render` and `Studio` are created in later milestones, not here.

**Tech Stack:** Swift 6.4, SwiftPM tools 6.4, macOS 27, Swift Testing (`import Testing`), ImageIO, Vision (Swift API: `ImageRequestHandler`, `GenerateImageFeaturePrintRequest`, `CalculateImageAestheticsScoresRequest`, `DetectFaceCaptureQualityRequest`, `DetectHumanRectanglesRequest`, `GenerateAttentionBasedSaliencyImageRequest`, `ClassifyImageRequest`), CryptoKit. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-26-ak14-phase0-design.md` (M1 = §12 "M1 — Harness, analyzer, and report"; data model §3.1, §3.9; analysis §4.1–4.3; run directory §9.3; report §9.4; errors §10.1–10.2).

## Global Constraints

- Package platform: `.macOS(.v27)`; swift-tools-version 6.4; Swift 6 language mode.
- Module names have no prefix: `Core`, `Analysis`, `CLI`. The executable product is named `ak14`.
- `Core` must not import Vision, AppKit, SwiftUI, CoreGraphics, CoreImage or ImageIO.
- `Analysis` depends only on `Core`. `CLI` depends on `Core` and `Analysis`.
- Zero third-party dependencies.
- Stable asset ID = `"a_"` + first 16 hex chars of the SHA-256 of the original file bytes. Renaming a file must not change its ID or invalidate the cache.
- Videos (`.mov`, `.mp4`, …) are skipped with reason `video`. Phase 0 is still photos only.
- Never fabricate a capture date. When EXIF has no offset, the date is interpreted in the current time zone and flagged `timeZoneAssumed = true`.
- Thumbnail tiers: analysis 384 px / quality 0.78, triage 160 / 0.72, planning 384 / 0.82, display 1200 / 0.88. M1 generates only the analysis tier.
- Thumbnails are orientation-corrected and carry no EXIF/GPS.
- Aspect inference: ≥70% portrait → 3:4, ≥70% landscape → 1:1, otherwise 4:5. Export sizes are 1080×1440, 1080×1080 and 1080×1350.
- Reports and manifests never contain absolute paths or GPS coordinates. The folder label is the last path component only.
- All JSON artifacts: pretty-printed, sorted keys, ISO-8601 dates, written atomically.
- Commit messages carry no AI attribution trailers.
- Persistent cache lives at `./.ak14-cache/` (gitignored). The run directory holds copies of what the report needs.

## Review Focus

1. **Uppercase extensions** (`IMG_1920.HEIC`, `.JPG`): must be treated as images, not skipped. Pinned in Task 4.
2. **Exact duplicate files under different names:** one `PhotoRecord` listing both paths, never two records with the same ID. Pinned in Task 4.
3. **Filenames or folder names with `<`, `&`, quotes or spaces:** the report must escape them and never break the HTML. Pinned in Task 7.
4. **Symlinked folder paths** (`/tmp` → `/private/tmp`): relative paths must still be computed correctly. Pinned in Task 4.
5. **Empty folder or all-video folder:** the run completes, the report shows 0 photos, and the aspect ratio defaults to 4:5 without a crash. Pinned in Task 9.

---

## File Structure

```text
Package.swift
Sources/
  Core/
    Models.swift            AssetID, PhotoRecord, CaptureMetadata, GeoPoint, PhotoOrientation, SkippedFile, IngestResult
    Features.swift          UnitRect, FaceRegion, SceneLabel, FeatureName, PhotoFeatures
    Aspect.swift            CarouselAspect + inference
    Thumbnails.swift        ThumbnailTier
    Protocols.swift         IngestOptions, PhotoIngesting, PhotoAnalyzing
    ConcurrentMap.swift     Array.concurrentMap(limit:_:), Duration.seconds
    JSONCoding.swift        shared encoder/decoder
    RunStore.swift          RunID, RunStore (run directory IO)
    RunManifest.swift       StageTiming, RunManifest
    AnalysisCache.swift     per-photo feature cache keyed by sha + analyzer version
    Report.swift            ReportInput, ReportBuilder, htmlEscape
  Analysis/
    FileHasher.swift        streaming SHA-256
    MetadataReader.swift    ImageIO dimensions/orientation/EXIF/GPS
    FolderIngester.swift    PhotoIngesting implementation
    Thumbnailer.swift       tiered, cached, oriented JPEG thumbnails
    ImageStats.swift        luminance / dark fraction
    VisionAnalyzer.swift    PhotoAnalyzing implementation
  CLI/
    AK14Command.swift       @main entry
    Arguments.swift         Command, RunOptions, parser, usage
    RunPipeline.swift       composes ingest → thumbnails → analysis → run dir → report
    ReportCommand.swift     rebuild report.html from a run dir
Tests/
  TestSupport/
    FixtureFactory.swift    synthetic JPEGs with EXIF; temp dirs
  CoreTests/
    ModelsTests.swift
    AspectTests.swift
    ConcurrentMapTests.swift
    RunStoreTests.swift
    AnalysisCacheTests.swift
    ReportTests.swift
  AnalysisTests/
    IngestTests.swift
    ThumbnailerTests.swift
    VisionAnalyzerTests.swift
  CLITests/
    ArgumentsTests.swift
    PipelineTests.swift
```

Test commands:
- `swift test --filter CoreTests`
- `swift test --filter AnalysisTests`
- `swift test --filter CLITests`

---

### Task 1: Package scaffold and Core models

**Files:**
- Create: `Package.swift`, `Sources/Core/Models.swift`, `Sources/Core/Features.swift`, `Sources/Core/Thumbnails.swift`, `Sources/Core/Protocols.swift`, `Sources/Core/JSONCoding.swift`
- Create: `Sources/Analysis/FileHasher.swift` (placeholder module file so the target builds; real content in Task 4)
- Create: `Sources/CLI/AK14Command.swift` (minimal; replaced in Task 8)
- Create: `Tests/TestSupport/FixtureFactory.swift`, `Tests/CoreTests/ModelsTests.swift`
- Create: `Tests/AnalysisTests/SmokeTests.swift`, `Tests/CLITests/SmokeTests.swift` (SwiftPM rejects test targets with no sources)
- Modify: `.gitignore` (add `.ak14-cache/`)

**Interfaces:**
- Produces:
  - `AssetID(sha256Hex:)` and `.rawValue` (single-value Codable)
  - `PhotoRecord`
  - `CaptureMetadata`
  - `GeoPoint`
  - `PhotoOrientation`
  - `SkipReason`
  - `SkippedFile`
  - `IngestResult`
  - `UnitRect`
  - `FaceRegion`
  - `SceneLabel`
  - `FeatureName`
  - `PhotoFeatures`
  - `ThumbnailTier`
  - `IngestOptions`
  - `PhotoIngesting.ingest(folder:options:) async throws -> IngestResult`
  - `PhotoAnalyzing.analyze(_:thumbnailURL:) async -> PhotoFeatures`
  - `JSONCoding.encoder`, `JSONCoding.decoder`
  - `FixtureFactory.writeJPEG(to:width:height:gray:exif:)`, `FixtureFactory.writeBytes(_:to:)`, `TempDirectory`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AK14",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "ak14", targets: ["CLI"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Analysis", dependencies: ["Core"]),
        .executableTarget(name: "CLI", dependencies: ["Core", "Analysis"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "AnalysisTests", dependencies: ["Analysis", "Core", "TestSupport"]),
        .testTarget(name: "CLITests", dependencies: ["CLI", "Analysis", "Core", "TestSupport"]),
    ]
)
```

- [ ] **Step 2: Write the failing test `Tests/CoreTests/ModelsTests.swift`**

```swift
import Foundation
import Testing
@testable import Core

@Test func assetIDDerivesFromDigestPrefix() {
    let id = AssetID(sha256Hex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    #expect(id.rawValue == "a_0123456789abcdef")
}

@Test func assetIDEncodesAsPlainString() throws {
    let data = try JSONCoding.encoder.encode([AssetID(rawValue: "a_1")])
    #expect(String(decoding: data, as: UTF8.self).contains("\"a_1\""))
    #expect(try JSONCoding.decoder.decode([AssetID].self, from: data) == [AssetID(rawValue: "a_1")])
}

@Test func orientationFromOrientedDimensions() {
    func record(_ w: Int, _ h: Int) -> PhotoRecord {
        PhotoRecord(assetID: AssetID(rawValue: "a"), contentSHA256: "x", sourceRelativePaths: ["p.jpg"],
                    byteCount: 1, fileType: "public.jpeg", pixelWidth: w, pixelHeight: h,
                    exifOrientation: 1, metadata: CaptureMetadata())
    }
    #expect(record(300, 400).orientation == .portrait)
    #expect(record(400, 300).orientation == .landscape)
    #expect(record(400, 400).orientation == .square)
}

@Test func photoFeaturesRoundTrip() throws {
    var f = PhotoFeatures(assetID: AssetID(rawValue: "a_1"), analyzerVersion: "v")
    f.faces = [FaceRegion(box: UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), captureQuality: 0.5)]
    f.failures[FeatureName.saliency.rawValue] = "boom"
    let back = try JSONCoding.decoder.decode(PhotoFeatures.self, from: JSONCoding.encoder.encode(f))
    #expect(back == f)
}
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `swift test --filter CoreTests`
Expected: FAIL to compile (`cannot find 'AssetID' in scope`).

- [ ] **Step 4: Write the Core model files**

`Sources/Core/JSONCoding.swift`:
```swift
import Foundation

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
```

`Sources/Core/Models.swift`:
```swift
import Foundation

public struct AssetID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(sha256Hex: String) { self.rawValue = "a_" + sha256Hex.prefix(16) }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func < (l: AssetID, r: AssetID) -> Bool { l.rawValue < r.rawValue }
}

public struct GeoPoint: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

public struct CaptureMetadata: Codable, Sendable, Equatable {
    public var capturedAt: Date?
    public var timeZoneAssumed: Bool
    public var location: GeoPoint?
    public var cameraModel: String?
    public var isScreenshot: Bool
    public init(capturedAt: Date? = nil, timeZoneAssumed: Bool = false, location: GeoPoint? = nil,
                cameraModel: String? = nil, isScreenshot: Bool = false) {
        self.capturedAt = capturedAt; self.timeZoneAssumed = timeZoneAssumed; self.location = location
        self.cameraModel = cameraModel; self.isScreenshot = isScreenshot
    }
}

public enum PhotoOrientation: String, Codable, Sendable { case portrait, landscape, square }

public struct PhotoRecord: Codable, Sendable, Equatable, Identifiable {
    public let assetID: AssetID
    public let contentSHA256: String
    /// Paths relative to the ingested folder. More than one entry means exact byte duplicates.
    public var sourceRelativePaths: [String]
    public let byteCount: Int
    /// UTType identifier, e.g. "public.heic".
    public let fileType: String
    /// Dimensions after applying EXIF orientation.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let exifOrientation: Int
    public let metadata: CaptureMetadata

    public init(assetID: AssetID, contentSHA256: String, sourceRelativePaths: [String], byteCount: Int,
                fileType: String, pixelWidth: Int, pixelHeight: Int, exifOrientation: Int, metadata: CaptureMetadata) {
        self.assetID = assetID; self.contentSHA256 = contentSHA256; self.sourceRelativePaths = sourceRelativePaths
        self.byteCount = byteCount; self.fileType = fileType; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.exifOrientation = exifOrientation; self.metadata = metadata
    }

    public var id: AssetID { assetID }
    public var orientation: PhotoOrientation {
        pixelHeight > pixelWidth ? .portrait : pixelWidth > pixelHeight ? .landscape : .square
    }
}

public enum SkipReason: String, Codable, Sendable, CaseIterable {
    case unsupportedType, video, decodeFailure, hiddenFile, directory
}

public struct SkippedFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let reason: SkipReason
    public let detail: String?
    public init(relativePath: String, reason: SkipReason, detail: String? = nil) {
        self.relativePath = relativePath; self.reason = reason; self.detail = detail
    }
}

public struct IngestResult: Codable, Sendable, Equatable {
    /// Sorted by assetID.
    public var photos: [PhotoRecord]
    /// Sorted by relativePath.
    public var skipped: [SkippedFile]
    public init(photos: [PhotoRecord], skipped: [SkippedFile]) { self.photos = photos; self.skipped = skipped }
}
```

`Sources/Core/Features.swift`:
```swift
import Foundation

/// Normalized rectangle with a TOP-LEFT origin (converted from Vision's bottom-left origin).
public struct UnitRect: Codable, Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct FaceRegion: Codable, Sendable, Equatable {
    public let box: UnitRect
    public let captureQuality: Double?
    public init(box: UnitRect, captureQuality: Double?) { self.box = box; self.captureQuality = captureQuality }
}

public struct SceneLabel: Codable, Sendable, Equatable {
    public let identifier: String
    public let confidence: Double
    public init(identifier: String, confidence: Double) { self.identifier = identifier; self.confidence = confidence }
}

public enum FeatureName: String, Codable, Sendable, CaseIterable {
    case image, featurePrint, aesthetics, faces, humans, saliency, classification, luminance
}

public struct PhotoFeatures: Codable, Sendable, Equatable {
    public let assetID: AssetID
    public let analyzerVersion: String
    public var aestheticScore: Double?
    public var isUtility: Bool?
    public var faces: [FaceRegion] = []
    public var humans: [UnitRect] = []
    public var salientRegions: [UnitRect] = []
    /// Confidence ≥ 0.3, at most 10, sorted by confidence descending.
    public var labels: [SceneLabel] = []
    public var meanLuminance: Double?
    /// Fraction of pixels with luma < 0.06.
    public var darkFraction: Double?
    /// Path relative to the cache root.
    public var featurePrintFile: String?
    /// FeatureName.rawValue → error description. Empty means complete.
    public var failures: [String: String] = [:]

    public init(assetID: AssetID, analyzerVersion: String) {
        self.assetID = assetID; self.analyzerVersion = analyzerVersion
    }
}
```

`Sources/Core/Thumbnails.swift`:
```swift
public enum ThumbnailTier: String, Codable, Sendable, CaseIterable {
    case analysis, triage, planning, display

    public var longEdge: Int {
        switch self { case .analysis: 384; case .triage: 160; case .planning: 384; case .display: 1200 }
    }
    public var jpegQuality: Double {
        switch self { case .analysis: 0.78; case .triage: 0.72; case .planning: 0.82; case .display: 0.88 }
    }
}
```

`Sources/Core/Protocols.swift`:
```swift
import Foundation

public struct IngestOptions: Sendable, Equatable {
    public var recursive: Bool
    public init(recursive: Bool = false) { self.recursive = recursive }
}

public protocol PhotoIngesting: Sendable {
    func ingest(folder: URL, options: IngestOptions) async throws -> IngestResult
}

public protocol PhotoAnalyzing: Sendable {
    /// Never throws: per-feature failures are recorded in `PhotoFeatures.failures`.
    func analyze(_ record: PhotoRecord, thumbnailURL: URL) async -> PhotoFeatures
}
```

`Sources/Analysis/FileHasher.swift` (temporary so the target has a source file):
```swift
import Core
```

`Sources/CLI/AK14Command.swift` (temporary):
```swift
@main
struct AK14Command {
    static func main() async {
        print("ak14")
    }
}
```

`Tests/TestSupport/FixtureFactory.swift`:
```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct TempDirectory {
    public let url: URL
    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "ak14-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func sub(_ name: String) throws -> URL {
        let u = url.appending(path: name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    public func remove() { try? FileManager.default.removeItem(at: url) }
}

public enum FixtureFactory {
    public struct Exif: Sendable {
        public var date: String? = "2026:05:29 17:30:03"
        public var offset: String? = "+05:30"
        public var latitude: Double? = 15.4989
        public var longitude: Double? = 73.8278
        public var model: String? = "iPhone 17"
        public var orientation: Int = 1
        public var userComment: String? = nil
        public init() {}
    }

    /// Writes a JPEG filled with `gray` plus a darker block so images have some structure.
    public static func writeJPEG(to url: URL, width: Int = 400, height: Int = 300,
                                 gray: Double = 0.5, exif: Exif = Exif()) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: gray * 0.3, green: gray * 0.5, blue: gray * 0.7, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 3, height: height / 3))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }

        var exifDict: [CFString: Any] = [:]
        if let d = exif.date { exifDict[kCGImagePropertyExifDateTimeOriginal] = d }
        if let o = exif.offset { exifDict[kCGImagePropertyExifOffsetTimeOriginal] = o }
        if let c = exif.userComment { exifDict[kCGImagePropertyExifUserComment] = c }
        var props: [CFString: Any] = [kCGImagePropertyOrientation: exif.orientation,
                                      kCGImagePropertyExifDictionary: exifDict]
        if let m = exif.model { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFModel: m] }
        if let lat = exif.latitude, let lon = exif.longitude {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
            ]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    public static func writeBytes(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
```

`Tests/AnalysisTests/SmokeTests.swift`:
```swift
import Testing
@testable import Analysis

@Test func analysisModuleLoads() {}
```

`Tests/CLITests/SmokeTests.swift`:
```swift
import Testing
@testable import CLI

@Test func cliModuleLoads() {}
```

Append to `.gitignore`:
```text
.ak14-cache/
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `swift test`
Expected: PASS (4 CoreTests + 2 smoke tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "feat(core): scaffold package and core photo models"
```

---

### Task 2: Aspect inference and concurrent map

**Files:**
- Create: `Sources/Core/Aspect.swift`, `Sources/Core/ConcurrentMap.swift`
- Test: `Tests/CoreTests/AspectTests.swift`, `Tests/CoreTests/ConcurrentMapTests.swift`

**Interfaces:**
- Consumes: `PhotoRecord.orientation` (Task 1)
- Produces:
  - `CarouselAspect` (`.portrait3x4 = "3:4"`, `.square = "1:1"`, `.portrait4x5 = "4:5"`)
  - `CarouselAspect.infer(from: [PhotoRecord]) -> CarouselAspect`
  - `.exportWidth`, `.exportHeight`
  - `Array.concurrentMap(limit:_:) async throws -> [T]`
  - `Duration.seconds: Double`

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/AspectTests.swift`:
```swift
import Testing
@testable import Core

private func photos(portrait: Int, landscape: Int) -> [PhotoRecord] {
    let p = (0..<portrait).map { i in
        PhotoRecord(assetID: AssetID(rawValue: "p\(i)"), contentSHA256: "p\(i)", sourceRelativePaths: ["p\(i)"],
                    byteCount: 1, fileType: "public.jpeg", pixelWidth: 3, pixelHeight: 4,
                    exifOrientation: 1, metadata: CaptureMetadata())
    }
    let l = (0..<landscape).map { i in
        PhotoRecord(assetID: AssetID(rawValue: "l\(i)"), contentSHA256: "l\(i)", sourceRelativePaths: ["l\(i)"],
                    byteCount: 1, fileType: "public.jpeg", pixelWidth: 4, pixelHeight: 3,
                    exifOrientation: 1, metadata: CaptureMetadata())
    }
    return p + l
}

@Test func mostlyPortraitInfers3x4() { #expect(CarouselAspect.infer(from: photos(portrait: 7, landscape: 3)) == .portrait3x4) }
@Test func mostlyLandscapeInfersSquare() { #expect(CarouselAspect.infer(from: photos(portrait: 3, landscape: 7)) == .square) }
@Test func mixedInfers4x5() { #expect(CarouselAspect.infer(from: photos(portrait: 5, landscape: 5)) == .portrait4x5) }
@Test func emptyInfers4x5() { #expect(CarouselAspect.infer(from: []) == .portrait4x5) }

@Test func exportSizes() {
    #expect((CarouselAspect.portrait3x4.exportWidth, CarouselAspect.portrait3x4.exportHeight) == (1080, 1440))
    #expect((CarouselAspect.portrait4x5.exportWidth, CarouselAspect.portrait4x5.exportHeight) == (1080, 1350))
    #expect((CarouselAspect.square.exportWidth, CarouselAspect.square.exportHeight) == (1080, 1080))
}
```

`Tests/CoreTests/ConcurrentMapTests.swift`:
```swift
import Testing
@testable import Core

private actor Gauge {
    var current = 0, peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func exit() { current -= 1 }
}

@Test func concurrentMapPreservesOrder() async throws {
    let out = try await Array(0..<50).concurrentMap(limit: 4) { i in
        try await Task.sleep(for: .milliseconds(Int.random(in: 0...3)))
        return i * 2
    }
    #expect(out == Array(0..<50).map { $0 * 2 })
}

@Test func concurrentMapRespectsLimit() async throws {
    let gauge = Gauge()
    _ = try await Array(0..<20).concurrentMap(limit: 3) { i in
        await gauge.enter()
        try await Task.sleep(for: .milliseconds(5))
        await gauge.exit()
        return i
    }
    #expect(await gauge.peak <= 3)
}

@Test func durationSeconds() {
    #expect(abs(Duration.milliseconds(1500).seconds - 1.5) < 1e-9)
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter CoreTests`
Expected: FAIL to compile (`cannot find 'CarouselAspect' in scope`).

- [ ] **Step 3: Implement**

`Sources/Core/Aspect.swift`:
```swift
public enum CarouselAspect: String, Codable, Sendable, CaseIterable {
    case portrait3x4 = "3:4"
    case square = "1:1"
    case portrait4x5 = "4:5"

    public var exportWidth: Int { 1080 }
    public var exportHeight: Int {
        switch self { case .portrait3x4: 1440; case .square: 1080; case .portrait4x5: 1350 }
    }

    /// "Mostly" means at least 70% of photos share an orientation. Squares count toward neither.
    public static func infer(from photos: [PhotoRecord]) -> CarouselAspect {
        guard !photos.isEmpty else { return .portrait4x5 }
        let total = Double(photos.count)
        let portrait = Double(photos.filter { $0.orientation == .portrait }.count) / total
        let landscape = Double(photos.filter { $0.orientation == .landscape }.count) / total
        if portrait >= 0.7 { return .portrait3x4 }
        if landscape >= 0.7 { return .square }
        return .portrait4x5
    }
}
```

`Sources/Core/ConcurrentMap.swift`:
```swift
extension Array where Element: Sendable {
    /// Maps with at most `limit` concurrent tasks and returns results in input order.
    public func concurrentMap<T: Sendable>(
        limit: Int, _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        precondition(limit > 0)
        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: count)
            var next = 0
            while next < Swift.min(limit, count) {
                let i = next, element = self[i]
                group.addTask { (i, try await transform(element)) }
                next += 1
            }
            while let (i, value) = try await group.next() {
                results[i] = value
                if next < count {
                    let j = next, element = self[j]
                    group.addTask { (j, try await transform(element)) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }
}

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `swift test --filter CoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core Tests/CoreTests
git commit -m "feat(core): aspect inference and bounded concurrent map"
```

---

### Task 3: Run store, manifest, and analysis cache

**Files:**
- Create: `Sources/Core/RunStore.swift`, `Sources/Core/RunManifest.swift`, `Sources/Core/AnalysisCache.swift`
- Test: `Tests/CoreTests/RunStoreTests.swift`, `Tests/CoreTests/AnalysisCacheTests.swift`

**Interfaces:**
- Consumes: `JSONCoding`, `PhotoFeatures`, `CarouselAspect`
- Produces:
  - `RunID.make(now: Date) -> String`, in the format `yyyyMMdd-HHmmss-xxxxxx` (UTC)
  - `RunStore.create(in:runID:) throws -> RunStore`
  - `RunStore.open(_ root: URL) -> RunStore`
  - `RunStore.url(_:) -> URL`
  - `RunStore.write(_:to:) throws`
  - `RunStore.writeText(_:to:) throws`
  - `RunStore.read(_:from:) throws -> T`
  - `StageTiming(stage:seconds:)`
  - `RunManifest` (fields below)
  - `AnalysisCache(root:analyzerVersion:)`
  - `AnalysisCache.load(sha:) -> PhotoFeatures?`
  - `AnalysisCache.store(_:sha:) throws`

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/RunStoreTests.swift`:
```swift
import Foundation
import Testing
@testable import Core

@Test func runIDFormat() {
    let id = RunID.make(now: Date(timeIntervalSince1970: 0))
    #expect(id.hasPrefix("19700101-000000-"))
    #expect(id.count == "19700101-000000-".count + 6)
}

@Test func storeWritesAtomicSortedJSONAndReadsBack() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "rs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RunStore.create(in: root, runID: "r1")
    #expect(store.root.lastPathComponent == "r1")
    let manifest = RunManifest(runID: "r1", createdAt: Date(timeIntervalSince1970: 10), sourceFolderLabel: "goa")
    try store.write(manifest, to: "manifest.json")
    let text = try String(contentsOf: store.url("manifest.json"), encoding: .utf8)
    #expect(text.contains("\"runID\" : \"r1\""))
    #expect(text.contains("1970-01-01T00:00:10Z"))
    let back = try store.read(RunManifest.self, from: "manifest.json")
    #expect(back.runID == "r1")
    #expect(back.schemaVersion == RunManifest.currentSchemaVersion)
    try store.writeText("<html></html>", to: "nested/dir/report.html")
    #expect(FileManager.default.fileExists(atPath: store.url("nested/dir/report.html").path))
}

@Test func createRefusesExistingRun() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "rs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try RunStore.create(in: root, runID: "same")
    #expect(throws: (any Error).self) { _ = try RunStore.create(in: root, runID: "same") }
}
```

`Tests/CoreTests/AnalysisCacheTests.swift`:
```swift
import Foundation
import Testing
@testable import Core

@Test func cacheRoundTripKeyedByShaAndVersion() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ac-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let v1 = AnalysisCache(root: root, analyzerVersion: "v1")
    var f = PhotoFeatures(assetID: AssetID(rawValue: "a_1"), analyzerVersion: "v1")
    f.aestheticScore = 0.4
    #expect(v1.load(sha: "abc") == nil)
    try v1.store(f, sha: "abc")
    #expect(v1.load(sha: "abc") == f)
    #expect(AnalysisCache(root: root, analyzerVersion: "v2").load(sha: "abc") == nil)
}

@Test func corruptCacheEntryIsAMiss() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ac-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = AnalysisCache(root: root, analyzerVersion: "v1")
    let url = cache.url(sha: "bad")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: url)
    #expect(cache.load(sha: "bad") == nil)
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter CoreTests`
Expected: FAIL to compile (`cannot find 'RunID' in scope`).

- [ ] **Step 3: Implement**

`Sources/Core/RunManifest.swift`:
```swift
import Foundation

public struct StageTiming: Codable, Sendable, Equatable {
    public let stage: String
    public let seconds: Double
    public init(stage: String, seconds: Double) { self.stage = stage; self.seconds = seconds }
}

public struct RunManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = RunManifest.currentSchemaVersion
    public let runID: String
    public let createdAt: Date
    public var completedAt: Date?
    /// Last path component of the input folder only; never an absolute path.
    public let sourceFolderLabel: String
    /// SHA-256 over the sorted content digests of all ingested photos.
    public var inputDigest: String = ""
    public var photoCount: Int = 0
    public var skippedCount: Int = 0
    public var aspectRatio: CarouselAspect = .portrait4x5
    public var aspectOverridden: Bool = false
    /// Component name → version, e.g. "analyzer": "vision-1".
    public var versions: [String: String] = [:]
    public var stageTimings: [StageTiming] = []
    public var cacheHits: Int = 0
    public var cacheMisses: Int = 0
    public var warnings: [String] = []

    public init(runID: String, createdAt: Date, sourceFolderLabel: String) {
        self.runID = runID; self.createdAt = createdAt; self.sourceFolderLabel = sourceFolderLabel
    }
}
```

`Sources/Core/RunStore.swift`:
```swift
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
```

`Sources/Core/AnalysisCache.swift`:
```swift
import Foundation

/// Per-photo feature cache. Key = content SHA-256 + analyzer version, so renames never invalidate it.
public struct AnalysisCache: Sendable {
    public let root: URL
    public let analyzerVersion: String

    public init(root: URL, analyzerVersion: String) {
        self.root = root; self.analyzerVersion = analyzerVersion
    }

    public func url(sha: String) -> URL {
        root.appending(path: "features/\(analyzerVersion)/\(sha).json")
    }

    /// Missing or unreadable entries are treated as misses.
    public func load(sha: String) -> PhotoFeatures? {
        guard let data = try? Data(contentsOf: url(sha: sha)) else { return nil }
        return try? JSONCoding.decoder.decode(PhotoFeatures.self, from: data)
    }

    public func store(_ features: PhotoFeatures, sha: String) throws {
        let target = url(sha: sha)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(features).write(to: target, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `swift test --filter CoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core Tests/CoreTests
git commit -m "feat(core): run store, manifest, and analysis cache"
```

---

### Task 4: Folder ingest (hashing, metadata, skip reasons)

**Files:**
- Modify: `Sources/Analysis/FileHasher.swift` (replace the placeholder)
- Create: `Sources/Analysis/MetadataReader.swift`, `Sources/Analysis/FolderIngester.swift`
- Test: `Tests/AnalysisTests/IngestTests.swift`

**Interfaces:**
- Consumes: `PhotoIngesting`, `IngestOptions`, `IngestResult`, `PhotoRecord`, `SkippedFile`, `CaptureMetadata` (Task 1); `FixtureFactory`, `TempDirectory` (Task 1)
- Produces:
  - `FileHasher.sha256Hex(of: URL) throws -> String`
  - `ImageMetadata`
  - `MetadataReader.read(_ url: URL) -> ImageMetadata?`
  - `MetadataReader.parseDate(_:offset:) -> (Date?, Bool)`
  - `FolderIngester()` conforming to `PhotoIngesting`

- [ ] **Step 1: Write the failing tests**

`Tests/AnalysisTests/IngestTests.swift`:
```swift
import Foundation
import Testing
import TestSupport
@testable import Analysis
@testable import Core

@Test func ingestClassifiesFilesAndReadsMetadata() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("event")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "IMG_0001.JPG"))          // uppercase ext
    var rotated = FixtureFactory.Exif(); rotated.orientation = 6                         // 90° CW
    try FixtureFactory.writeJPEG(to: folder.appending(path: "rotated.jpg"), gray: 0.3, exif: rotated)
    try FixtureFactory.writeBytes("not a movie", to: folder.appending(path: "clip.MOV"))
    try FixtureFactory.writeBytes("hello", to: folder.appending(path: "notes.txt"))
    try FixtureFactory.writeBytes("garbage", to: folder.appending(path: "broken.jpg"))
    try FixtureFactory.writeBytes("x", to: folder.appending(path: ".DS_Store"))
    _ = try tmp.sub("event/nested")

    let result = try await FolderIngester().ingest(folder: folder, options: IngestOptions())

    #expect(result.photos.count == 2)
    #expect(result.photos == result.photos.sorted { $0.assetID < $1.assetID })
    let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.relativePath, $0.reason) })
    #expect(reasons["clip.MOV"] == .video)
    #expect(reasons["notes.txt"] == .unsupportedType)
    #expect(reasons["broken.jpg"] == .decodeFailure)
    #expect(reasons[".DS_Store"] == .hiddenFile)
    #expect(reasons["nested"] == .directory)

    let upper = try #require(result.photos.first { $0.sourceRelativePaths == ["IMG_0001.JPG"] })
    #expect(upper.fileType == "public.jpeg")
    #expect(upper.pixelWidth == 400 && upper.pixelHeight == 300)
    #expect(upper.metadata.cameraModel == "iPhone 17")
    #expect(upper.metadata.timeZoneAssumed == false)
    #expect(upper.metadata.capturedAt == ISO8601DateFormatter().date(from: "2026-05-29T12:00:03Z"))
    let loc = try #require(upper.metadata.location)
    #expect(abs(loc.latitude - 15.4989) < 1e-4 && abs(loc.longitude - 73.8278) < 1e-4)
    #expect(upper.assetID == AssetID(sha256Hex: upper.contentSHA256))

    let rot = try #require(result.photos.first { $0.sourceRelativePaths == ["rotated.jpg"] })
    #expect(rot.exifOrientation == 6)
    #expect(rot.pixelWidth == 300 && rot.pixelHeight == 400)
    #expect(rot.orientation == .portrait)
}

@Test func exactDuplicatesCollapseIntoOneRecord() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("dups")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "b.jpg"))
    try FileManager.default.copyItem(at: folder.appending(path: "b.jpg"), to: folder.appending(path: "a copy.jpg"))
    let result = try await FolderIngester().ingest(folder: folder, options: IngestOptions())
    #expect(result.photos.count == 1)
    #expect(result.photos[0].sourceRelativePaths == ["a copy.jpg", "b.jpg"])
}

@Test func recursiveIngestUsesRelativeSubpathsThroughSymlink() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let real = try tmp.sub("real")
    let day2 = try tmp.sub("real/day2")
    try FixtureFactory.writeJPEG(to: day2.appending(path: "x.jpg"))
    let link = tmp.url.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let result = try await FolderIngester().ingest(folder: link, options: IngestOptions(recursive: true))
    #expect(result.photos.map(\.sourceRelativePaths) == [["day2/x.jpg"]])
    #expect(result.skipped.isEmpty)
}

@Test func missingOffsetFlagsAssumedTimeZoneAndMissingDateStaysNil() {
    let (assumed, flag) = MetadataReader.parseDate("2026:05:29 17:30:03", offset: nil)
    #expect(assumed != nil && flag == true)
    let (none, noneFlag) = MetadataReader.parseDate(nil, offset: "+05:30")
    #expect(none == nil && noneFlag == false)
    let (bad, _) = MetadataReader.parseDate("0000:00:00 00:00:00", offset: nil)
    #expect(bad == nil)
}

@Test func screenshotCommentIsDetected() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("s")
    var exif = FixtureFactory.Exif(); exif.userComment = "Screenshot"; exif.model = nil; exif.latitude = nil
    try FixtureFactory.writeJPEG(to: folder.appending(path: "shot.jpg"), exif: exif)
    let result = try await FolderIngester().ingest(folder: folder, options: IngestOptions())
    #expect(result.photos[0].metadata.isScreenshot)
    #expect(result.photos[0].metadata.cameraModel == nil)
    #expect(result.photos[0].metadata.location == nil)
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter AnalysisTests`
Expected: FAIL to compile (`cannot find 'FolderIngester' in scope`).

- [ ] **Step 3: Implement**

`Sources/Analysis/FileHasher.swift`:
```swift
import CryptoKit
import Foundation

public enum FileHasher {
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

`Sources/Analysis/MetadataReader.swift`:
```swift
import Core
import Foundation
import ImageIO

public struct ImageMetadata: Sendable, Equatable {
    public let pixelWidth: Int     // oriented
    public let pixelHeight: Int    // oriented
    public let exifOrientation: Int
    public let capture: CaptureMetadata
}

public enum MetadataReader {
    /// Returns nil when ImageIO cannot fully read the image header/properties.
    public static func read(_ url: URL) -> ImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawW = props[kCGImagePropertyPixelWidth] as? Int,
              let rawH = props[kCGImagePropertyPixelHeight] as? Int, rawW > 0, rawH > 0
        else { return nil }

        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let (date, assumed) = parseDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                                        offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        let capture = CaptureMetadata(
            capturedAt: date,
            timeZoneAssumed: assumed,
            location: gpsPoint(props[kCGImagePropertyGPSDictionary] as? [CFString: Any]),
            cameraModel: (tiff[kCGImagePropertyTIFFModel] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isScreenshot: (exif[kCGImagePropertyExifUserComment] as? String) == "Screenshot"
        )
        return ImageMetadata(pixelWidth: swapped ? rawH : rawW, pixelHeight: swapped ? rawW : rawH,
                             exifOrientation: orientation, capture: capture)
    }

    /// EXIF "yyyy:MM:dd HH:mm:ss" + optional "+05:30". Without an offset, uses the current
    /// time zone and returns `assumed = true`. Invalid or missing dates return (nil, false).
    static func parseDate(_ raw: String?, offset: String?) -> (Date?, Bool) {
        guard let raw else { return (nil, false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        var assumed = true
        if let offset, let tz = timeZone(fromOffset: offset) {
            formatter.timeZone = tz
            assumed = false
        } else {
            formatter.timeZone = .current
        }
        guard let date = formatter.date(from: raw) else { return (nil, false) }
        return (date, assumed)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let pattern = /^([+-])(\d{2}):(\d{2})$/
        guard let m = offset.wholeMatch(of: pattern), let h = Int(m.2), let mm = Int(m.3) else { return nil }
        let seconds = (h * 3600 + mm * 60) * (m.1 == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func gpsPoint(_ gps: [CFString: Any]?) -> GeoPoint? {
        guard let gps,
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latSign = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1.0 : 1.0
        let lonSign = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1.0 : 1.0
        return GeoPoint(latitude: lat * latSign, longitude: lon * lonSign)
    }
}
```

`Sources/Analysis/FolderIngester.swift`:
```swift
import Core
import Foundation
import UniformTypeIdentifiers

public struct FolderIngester: PhotoIngesting {
    public init() {}

    public func ingest(folder: URL, options: IngestOptions) async throws -> IngestResult {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey, .contentTypeKey, .fileSizeKey]
        let fm = FileManager.default

        let urls: [URL]
        if options.recursive {
            let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: Array(keys),
                                           options: [.skipsHiddenFiles])
            urls = (enumerator?.allObjects as? [URL] ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
        } else {
            urls = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: Array(keys), options: [])
        }

        var bySHA: [String: PhotoRecord] = [:]
        var skipped: [SkippedFile] = []

        for url in urls {
            let rel = relativePath(of: url, base: base)
            let values = try url.resourceValues(forKeys: keys)
            if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                skipped.append(SkippedFile(relativePath: rel, reason: .hiddenFile)); continue
            }
            if values.isDirectory == true {
                skipped.append(SkippedFile(relativePath: rel, reason: .directory)); continue
            }
            guard let type = values.contentType else {
                skipped.append(SkippedFile(relativePath: rel, reason: .unsupportedType)); continue
            }
            if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
                skipped.append(SkippedFile(relativePath: rel, reason: .video, detail: type.identifier)); continue
            }
            guard type.conforms(to: .image) else {
                skipped.append(SkippedFile(relativePath: rel, reason: .unsupportedType, detail: type.identifier)); continue
            }
            guard let meta = MetadataReader.read(url) else {
                skipped.append(SkippedFile(relativePath: rel, reason: .decodeFailure, detail: type.identifier)); continue
            }
            let sha = try FileHasher.sha256Hex(of: url)
            if var existing = bySHA[sha] {
                existing.sourceRelativePaths = (existing.sourceRelativePaths + [rel]).sorted()
                bySHA[sha] = existing
            } else {
                bySHA[sha] = PhotoRecord(
                    assetID: AssetID(sha256Hex: sha), contentSHA256: sha, sourceRelativePaths: [rel],
                    byteCount: values.fileSize ?? 0, fileType: type.identifier,
                    pixelWidth: meta.pixelWidth, pixelHeight: meta.pixelHeight,
                    exifOrientation: meta.exifOrientation, metadata: meta.capture)
            }
        }
        return IngestResult(photos: bySHA.values.sorted { $0.assetID < $1.assetID },
                            skipped: skipped.sorted { $0.relativePath < $1.relativePath })
    }

    private func relativePath(of url: URL, base: URL) -> String {
        let full = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `swift test --filter AnalysisTests`
Expected: PASS (5 tests). If `clip.MOV` resolves to a type that isn't a movie, print `values.contentType` in the test and match the conformance check to it. Do not special-case the extension string.

- [ ] **Step 5: Commit**

```bash
git add Sources/Analysis Tests/AnalysisTests
git commit -m "feat(analysis): folder ingest with stable IDs, EXIF metadata, and skip reasons"
```

---

### Task 5: Thumbnailer

**Files:**
- Create: `Sources/Analysis/Thumbnailer.swift`
- Test: `Tests/AnalysisTests/ThumbnailerTests.swift`

**Interfaces:**
- Consumes: `ThumbnailTier` (Task 1)
- Produces:
  - `Thumbnailer(cacheRoot:)`
  - `Thumbnailer.version` (`"thumb-1"`)
  - `Thumbnailer.url(sha:tier:) -> URL`
  - `Thumbnailer.thumbnail(sha:source:tier:) throws -> URL`
  - `ThumbnailError`

- [ ] **Step 1: Write the failing tests**

`Tests/AnalysisTests/ThumbnailerTests.swift`:
```swift
import Foundation
import ImageIO
import Testing
import TestSupport
@testable import Analysis
@testable import Core

@Test func thumbnailIsOrientedSizedStrippedAndCached() throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let src = tmp.url.appending(path: "rot.jpg")
    var exif = FixtureFactory.Exif(); exif.orientation = 6
    try FixtureFactory.writeJPEG(to: src, width: 800, height: 600, exif: exif)
    let thumbs = Thumbnailer(cacheRoot: tmp.url.appending(path: "cache"))

    let out = try thumbs.thumbnail(sha: "abc", source: src, tier: .analysis)
    #expect(out == thumbs.url(sha: "abc", tier: .analysis))
    let isrc = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(isrc, 0, nil) as? [CFString: Any])
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 288)
    #expect(props[kCGImagePropertyPixelHeight] as? Int == 384)
    #expect(props[kCGImagePropertyGPSDictionary] == nil)
    #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)

    let mtime = try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date
    _ = try thumbs.thumbnail(sha: "abc", source: src, tier: .analysis)
    let mtime2 = try FileManager.default.attributesOfItem(atPath: out.path)[.modificationDate] as? Date
    #expect(mtime == mtime2)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path)
    #expect(leftovers == ["abc.jpg"])
}

@Test func unreadableSourceThrows() throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let src = tmp.url.appending(path: "bad.jpg")
    try FixtureFactory.writeBytes("nope", to: src)
    #expect(throws: ThumbnailError.self) {
        _ = try Thumbnailer(cacheRoot: tmp.url).thumbnail(sha: "bad", source: src, tier: .triage)
    }
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter AnalysisTests`
Expected: FAIL to compile (`cannot find 'Thumbnailer' in scope`).

- [ ] **Step 3: Implement `Sources/Analysis/Thumbnailer.swift`**

```swift
import Core
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailError: Error, Equatable {
    case decodeFailed, encodeFailed
}

/// Orientation-corrected JPEG thumbnails without source metadata, cached by content digest + tier + version.
public struct Thumbnailer: Sendable {
    public static let version = "thumb-1"
    public let cacheRoot: URL

    public init(cacheRoot: URL) { self.cacheRoot = cacheRoot }

    public func url(sha: String, tier: ThumbnailTier) -> URL {
        cacheRoot.appending(path: "thumbnails/\(Self.version)/\(tier.rawValue)/\(sha).jpg")
    }

    public func thumbnail(sha: String, source: URL, tier: ThumbnailTier) throws -> URL {
        let out = url(sha: sha, tier: tier)
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { return out }
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: tier.longEdge,
        ]
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { throw ThumbnailError.decodeFailed }

        // Write to a temp name, then move, so a crash never leaves a partial file at the cached path.
        let tmp = out.deletingLastPathComponent().appending(path: ".\(sha)-\(UUID().uuidString).tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ThumbnailError.encodeFailed }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: tier.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: tmp)
            throw ThumbnailError.encodeFailed
        }
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: tmp); return out }
        try fm.moveItem(at: tmp, to: out)
        return out
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `swift test --filter AnalysisTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Analysis/Thumbnailer.swift Tests/AnalysisTests/ThumbnailerTests.swift
git commit -m "feat(analysis): cached oriented thumbnails without source metadata"
```

---

### Task 6: Vision analyzer

**Files:**
- Create: `Sources/Analysis/ImageStats.swift`, `Sources/Analysis/VisionAnalyzer.swift`
- Test: `Tests/AnalysisTests/VisionAnalyzerTests.swift`

**Interfaces:**
- Consumes: `PhotoAnalyzing`, `PhotoFeatures`, `UnitRect`, `FaceRegion`, `SceneLabel`, `FeatureName` (Task 1); `Thumbnailer` (Task 5, in tests)
- Produces:
  - `VisionAnalyzer(cacheRoot:)` conforming to `PhotoAnalyzing`
  - `VisionAnalyzer.version` (`"vision-1"`)
  - `ImageStats.luminance(of: CGImage) -> (mean: Double, darkFraction: Double)?`
  - `UnitRect(visionRect: CGRect)`
- Verified API facts (Xcode 27 / macOS 27 SDK):
  - `ImageRequestHandler(cgImage)` and `handler.perform(request)` return typed results.
  - `DetectFaceCaptureQualityRequest` → `[FaceObservation]` with `.boundingBox.cgRect` and `.captureQuality?.score` (Float).
  - `DetectHumanRectanglesRequest` → `[HumanObservation]` with `.boundingBox.cgRect`.
  - `GenerateAttentionBasedSaliencyImageRequest` → `SaliencyImageObservation` with `.salientObjects[].boundingBox.cgRect`.
  - `ClassifyImageRequest` → `[ClassificationObservation]` with `.identifier` and `.confidence` (Float).
  - `CalculateImageAestheticsScoresRequest` → `.overallScore` (Float) and `.isUtility`.
  - `GenerateImageFeaturePrintRequest` → `FeaturePrintObservation`, which is Codable; `distance(to:)` returns Double.
  - Vision rects have a bottom-left origin.

- [ ] **Step 1: Write the failing tests**

`Tests/AnalysisTests/VisionAnalyzerTests.swift`:
```swift
import Foundation
import Testing
import TestSupport
import Vision
@testable import Analysis
@testable import Core

private func record(sha: String) -> PhotoRecord {
    PhotoRecord(assetID: AssetID(sha256Hex: sha), contentSHA256: sha, sourceRelativePaths: ["x.jpg"],
                byteCount: 1, fileType: "public.jpeg", pixelWidth: 400, pixelHeight: 300,
                exifOrientation: 1, metadata: CaptureMetadata())
}

@Test func darkFrameProducesCompleteFeatures() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let src = tmp.url.appending(path: "black.jpg")
    try FixtureFactory.writeJPEG(to: src, gray: 0.0)
    let sha = String(repeating: "b", count: 64)
    let thumb = try Thumbnailer(cacheRoot: tmp.url).thumbnail(sha: sha, source: src, tier: .analysis)

    let f = await VisionAnalyzer(cacheRoot: tmp.url).analyze(record(sha: sha), thumbnailURL: thumb)

    #expect(f.failures.isEmpty, "\(f.failures)")
    #expect(f.analyzerVersion == VisionAnalyzer.version)
    #expect(try #require(f.darkFraction) > 0.95)
    #expect(try #require(f.meanLuminance) < 0.05)
    #expect(f.faces.isEmpty)
    #expect(f.aestheticScore != nil && f.isUtility != nil)
    #expect(f.labels.count <= 10)
    #expect(f.labels == f.labels.sorted { $0.confidence > $1.confidence })
    let fpPath = try #require(f.featurePrintFile)
    let data = try Data(contentsOf: tmp.url.appending(path: fpPath))
    let fp = try JSONDecoder().decode(FeaturePrintObservation.self, from: data)
    #expect(try fp.distance(to: fp) == 0)
}

@Test func unreadableThumbnailIsRecordedNotThrown() async {
    let f = await VisionAnalyzer(cacheRoot: FileManager.default.temporaryDirectory)
        .analyze(record(sha: "c"), thumbnailURL: URL(fileURLWithPath: "/nonexistent/x.jpg"))
    #expect(f.failures[FeatureName.image.rawValue] != nil)
}

@Test func visionRectConvertsToTopLeftOrigin() {
    let r = UnitRect(visionRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    #expect(abs(r.x - 0.1) < 1e-9 && abs(r.y - 0.4) < 1e-9)
    #expect(abs(r.width - 0.3) < 1e-9 && abs(r.height - 0.4) < 1e-9)
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter AnalysisTests`
Expected: FAIL to compile (`cannot find 'VisionAnalyzer' in scope`).

- [ ] **Step 3: Implement**

`Sources/Analysis/ImageStats.swift`:
```swift
import CoreGraphics
import Core

extension UnitRect {
    /// Converts a Vision normalized rect (bottom-left origin) to top-left origin, clamped to 0...1.
    public init(visionRect r: CGRect) {
        let x = min(max(Double(r.minX), 0), 1)
        let y = min(max(1 - Double(r.maxY), 0), 1)
        self.init(x: x, y: y,
                  width: min(max(Double(r.width), 0), 1 - x),
                  height: min(max(Double(r.height), 0), 1 - y))
    }
}

public enum ImageStats {
    /// Mean luma (0...1) and fraction of pixels darker than 0.06, measured on a 32×32 gray downsample.
    public static func luminance(of image: CGImage) -> (mean: Double, darkFraction: Double)? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let dark = Double(values.filter { $0 < 0.06 }.count) / Double(values.count)
        return (mean, dark)
    }
}
```

`Sources/Analysis/VisionAnalyzer.swift`:
```swift
import Core
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Extracts local features from an analysis-tier thumbnail. Each Vision request is isolated:
/// a failure is recorded in `failures` and the remaining features are still produced.
public struct VisionAnalyzer: PhotoAnalyzing {
    public static let version = "vision-1"
    public let cacheRoot: URL

    public init(cacheRoot: URL) { self.cacheRoot = cacheRoot }

    public func analyze(_ record: PhotoRecord, thumbnailURL: URL) async -> PhotoFeatures {
        var f = PhotoFeatures(assetID: record.assetID, analyzerVersion: Self.version)
        guard let src = CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            f.failures[FeatureName.image.rawValue] = "thumbnail unreadable"
            return f
        }
        let handler = ImageRequestHandler(image)

        do {
            let featurePrint = try await handler.perform(GenerateImageFeaturePrintRequest())
            let rel = "featureprints/\(Self.version)/\(record.contentSHA256).json"
            let target = cacheRoot.appending(path: rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(featurePrint).write(to: target, options: .atomic)
            f.featurePrintFile = rel
        } catch { f.failures[FeatureName.featurePrint.rawValue] = "\(error)" }

        do {
            let a = try await handler.perform(CalculateImageAestheticsScoresRequest())
            f.aestheticScore = Double(a.overallScore)
            f.isUtility = a.isUtility
        } catch { f.failures[FeatureName.aesthetics.rawValue] = "\(error)" }

        do {
            let faces = try await handler.perform(DetectFaceCaptureQualityRequest())
            f.faces = faces.map {
                FaceRegion(box: UnitRect(visionRect: $0.boundingBox.cgRect),
                           captureQuality: $0.captureQuality.map { Double($0.score) })
            }
        } catch { f.failures[FeatureName.faces.rawValue] = "\(error)" }

        do {
            let humans = try await handler.perform(DetectHumanRectanglesRequest())
            f.humans = humans.map { UnitRect(visionRect: $0.boundingBox.cgRect) }
        } catch { f.failures[FeatureName.humans.rawValue] = "\(error)" }

        do {
            let saliency = try await handler.perform(GenerateAttentionBasedSaliencyImageRequest())
            f.salientRegions = saliency.salientObjects.map { UnitRect(visionRect: $0.boundingBox.cgRect) }
        } catch { f.failures[FeatureName.saliency.rawValue] = "\(error)" }

        do {
            let labels = try await handler.perform(ClassifyImageRequest())
            f.labels = labels
                .filter { $0.confidence >= 0.3 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(10)
                .map { SceneLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }
        } catch { f.failures[FeatureName.classification.rawValue] = "\(error)" }

        if let stats = ImageStats.luminance(of: image) {
            f.meanLuminance = stats.mean
            f.darkFraction = stats.darkFraction
        } else {
            f.failures[FeatureName.luminance.rawValue] = "could not draw image"
        }
        return f
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `swift test --filter AnalysisTests`
Expected: PASS. The first Vision call loads models, which takes a few seconds; that's expected.

- [ ] **Step 5: Commit**

```bash
git add Sources/Analysis Tests/AnalysisTests/VisionAnalyzerTests.swift
git commit -m "feat(analysis): Vision feature extraction with per-feature failure isolation"
```

---

### Task 7: HTML report builder

**Files:**
- Create: `Sources/Core/Report.swift`
- Test: `Tests/CoreTests/ReportTests.swift`

**Interfaces:**
- Consumes: `RunManifest`, `PhotoRecord`, `SkippedFile`, `PhotoFeatures` (Tasks 1–3)
- Produces:
  - `ReportInput(manifest:photos:skipped:features:thumbnails:)`, where `features: [AssetID: PhotoFeatures]` and `thumbnails: [AssetID: String]` (run-relative paths)
  - `ReportBuilder.version` (`"report-1"`)
  - `ReportBuilder.html(_:) -> String`
  - `htmlEscape(_:) -> String`

- [ ] **Step 1: Write the failing tests**

`Tests/CoreTests/ReportTests.swift`:
```swift
import Foundation
import Testing
@testable import Core

private func sampleInput(label: String = "goa <trip> & \"friends\"") -> ReportInput {
    var manifest = RunManifest(runID: "r1", createdAt: Date(timeIntervalSince1970: 0), sourceFolderLabel: label)
    manifest.photoCount = 2; manifest.skippedCount = 1; manifest.aspectRatio = .portrait3x4
    manifest.cacheHits = 1; manifest.cacheMisses = 1
    manifest.stageTimings = [StageTiming(stage: "ingest", seconds: 1.25)]
    manifest.versions = ["analyzer": "vision-1"]
    manifest.warnings = ["thumbnail failed: <x>.jpg"]
    let withGPS = PhotoRecord(
        assetID: AssetID(rawValue: "a_1"), contentSHA256: "1", sourceRelativePaths: ["IMG <1>.HEIC"],
        byteCount: 10, fileType: "public.heic", pixelWidth: 3, pixelHeight: 4, exifOrientation: 1,
        metadata: CaptureMetadata(capturedAt: Date(timeIntervalSince1970: 100),
                                  location: GeoPoint(latitude: 15.498912, longitude: 73.827812),
                                  cameraModel: "iPhone 17"))
    let bare = PhotoRecord(
        assetID: AssetID(rawValue: "a_2"), contentSHA256: "2", sourceRelativePaths: ["wa.jpg", "wa copy.jpg"],
        byteCount: 10, fileType: "public.jpeg", pixelWidth: 4, pixelHeight: 3, exifOrientation: 1,
        metadata: CaptureMetadata())
    var f = PhotoFeatures(assetID: AssetID(rawValue: "a_1"), analyzerVersion: "vision-1")
    f.aestheticScore = 0.86; f.faces = [FaceRegion(box: UnitRect(x: 0, y: 0, width: 0.1, height: 0.1), captureQuality: 0.5)]
    f.labels = [SceneLabel(identifier: "people", confidence: 0.8)]
    return ReportInput(manifest: manifest, photos: [withGPS, bare],
                       skipped: [SkippedFile(relativePath: "clip.MOV", reason: .video)],
                       features: [f.assetID: f], thumbnails: [AssetID(rawValue: "a_1"): "cache/thumbnails/analysis/a_1.jpg"])
}

@Test func reportEscapesUserControlledText() {
    let html = ReportBuilder.html(sampleInput())
    #expect(html.contains("goa &lt;trip&gt; &amp; &quot;friends&quot;"))
    #expect(html.contains("IMG &lt;1&gt;.HEIC"))
    #expect(!html.contains("<trip>"))
    #expect(!html.contains("<x>.jpg"))
}

@Test func reportShowsCountsFlagsAndNoCoordinates() {
    let html = ReportBuilder.html(sampleInput())
    #expect(html.hasPrefix("<!doctype html>"))
    for needle in ["r1", "a_1", "a_2", "3:4", "clip.MOV", "video", "vision-1", "people",
                   "cache/thumbnails/analysis/a_1.jpg", "no capture date", "no GPS", "no camera metadata",
                   "2 paths", "1 face", "0.86", "ingest"] {
        #expect(html.contains(needle), "missing \(needle)")
    }
    #expect(!html.contains("15.49"))
    #expect(!html.contains("73.82"))
}

@Test func reportHandlesEmptyRun() {
    let manifest = RunManifest(runID: "empty", createdAt: Date(timeIntervalSince1970: 0), sourceFolderLabel: "e")
    let html = ReportBuilder.html(ReportInput(manifest: manifest, photos: [], skipped: [], features: [:], thumbnails: [:]))
    #expect(html.contains("No photos were ingested"))
}

@Test func escapeCoversAllSpecials() {
    #expect(htmlEscape("<a href='x'>&\"</a>") == "&lt;a href=&#39;x&#39;&gt;&amp;&quot;&lt;/a&gt;")
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter CoreTests`
Expected: FAIL to compile (`cannot find 'ReportBuilder' in scope`).

- [ ] **Step 3: Implement `Sources/Core/Report.swift`**

```swift
import Foundation

public func htmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(ch)
        }
    }
    return out
}

public struct ReportInput: Sendable {
    public let manifest: RunManifest
    public let photos: [PhotoRecord]
    public let skipped: [SkippedFile]
    public let features: [AssetID: PhotoFeatures]
    /// Run-relative thumbnail paths.
    public let thumbnails: [AssetID: String]

    public init(manifest: RunManifest, photos: [PhotoRecord], skipped: [SkippedFile],
                features: [AssetID: PhotoFeatures], thumbnails: [AssetID: String]) {
        self.manifest = manifest; self.photos = photos; self.skipped = skipped
        self.features = features; self.thumbnails = thumbnails
    }
}

/// Builds a self-contained local HTML report. Never emits absolute paths or GPS coordinates.
public enum ReportBuilder {
    public static let version = "report-1"

    public static func html(_ input: ReportInput) -> String {
        let m = input.manifest
        let e = htmlEscape
        var h = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>AK14 run \(e(m.runID))</title>\n"
        h += "<style>\(css)</style></head><body>\n"
        h += "<h1>AK14 run \(e(m.runID))</h1>\n"
        h += "<p>Folder: <b>\(e(m.sourceFolderLabel))</b> · created \(e(iso(m.createdAt)))"
        h += " · aspect \(e(m.aspectRatio.rawValue))\(m.aspectOverridden ? " (override)" : " (inferred)")</p>\n"

        let photos = input.photos
        let noDate = photos.filter { $0.metadata.capturedAt == nil }.count
        let assumedTZ = photos.filter { $0.metadata.timeZoneAssumed }.count
        let noGPS = photos.filter { $0.metadata.location == nil }.count
        let noCamera = photos.filter { $0.metadata.cameraModel == nil }.count
        let screenshots = photos.filter { $0.metadata.isScreenshot }.count
        let dupGroups = photos.filter { $0.sourceRelativePaths.count > 1 }.count

        h += "<h2>Summary</h2>\n<table>\n"
        for (k, v) in [("Photos", "\(photos.count)"), ("Skipped files", "\(input.skipped.count)"),
                       ("Exact-duplicate groups", "\(dupGroups)"), ("Missing capture date", "\(noDate)"),
                       ("Time zone assumed", "\(assumedTZ)"), ("Missing GPS", "\(noGPS)"),
                       ("No camera metadata (likely received/forwarded)", "\(noCamera)"),
                       ("Screenshots", "\(screenshots)"),
                       ("Analysis cache hits / misses", "\(m.cacheHits) / \(m.cacheMisses)")] {
            h += "<tr><th>\(e(k))</th><td>\(e(v))</td></tr>\n"
        }
        h += "</table>\n"

        let types = Dictionary(grouping: photos, by: \.fileType).mapValues(\.count).sorted { $0.key < $1.key }
        h += "<h2>File types</h2>\n<table>\n"
        for (t, c) in types { h += "<tr><th>\(e(t))</th><td>\(c)</td></tr>\n" }
        h += "</table>\n"

        h += "<h2>Stages</h2>\n<table>\n"
        for s in m.stageTimings { h += "<tr><th>\(e(s.stage))</th><td>\(String(format: "%.2f", s.seconds)) s</td></tr>\n" }
        h += "</table>\n<h2>Versions</h2>\n<table>\n"
        for (k, v) in m.versions.sorted(by: { $0.key < $1.key }) { h += "<tr><th>\(e(k))</th><td>\(e(v))</td></tr>\n" }
        h += "</table>\n"

        if !m.warnings.isEmpty {
            h += "<h2>Warnings</h2>\n<ul>\n"
            for w in m.warnings { h += "<li>\(e(w))</li>\n" }
            h += "</ul>\n"
        }

        h += "<h2>Skipped files</h2>\n"
        if input.skipped.isEmpty { h += "<p>None.</p>\n" } else {
            h += "<table>\n"
            for s in input.skipped {
                h += "<tr><th>\(e(s.relativePath))</th><td>\(e(s.reason.rawValue))\(s.detail.map { " · " + e($0) } ?? "")</td></tr>\n"
            }
            h += "</table>\n"
        }

        h += "<h2>Contact sheet</h2>\n"
        if photos.isEmpty {
            h += "<p>No photos were ingested.</p>\n"
        } else {
            h += "<div class=\"grid\">\n"
            let ordered = photos.sorted {
                switch ($0.metadata.capturedAt, $1.metadata.capturedAt) {
                case let (a?, b?): return a == b ? $0.assetID < $1.assetID : a < b
                case (nil, nil): return $0.assetID < $1.assetID
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            for p in ordered { h += card(p, features: input.features[p.assetID], thumb: input.thumbnails[p.assetID]) }
            h += "</div>\n"
        }

        h += "<h2>Privacy</h2>\n<p>This report is local. It contains thumbnails of your photos but no GPS coordinates "
        h += "or absolute file paths. M1 runs make no network calls.</p>\n"
        h += "</body></html>\n"
        return h
    }

    private static func card(_ p: PhotoRecord, features f: PhotoFeatures?, thumb: String?) -> String {
        let e = htmlEscape
        var badges: [String] = []
        if p.metadata.capturedAt == nil { badges.append("no capture date") }
        if p.metadata.timeZoneAssumed { badges.append("time zone assumed") }
        if p.metadata.location == nil { badges.append("no GPS") }
        if p.metadata.cameraModel == nil { badges.append("no camera metadata") }
        if p.metadata.isScreenshot { badges.append("screenshot") }
        if p.sourceRelativePaths.count > 1 { badges.append("\(p.sourceRelativePaths.count) paths") }
        if let f {
            if !f.faces.isEmpty { badges.append("\(f.faces.count) face\(f.faces.count == 1 ? "" : "s")") }
            if f.isUtility == true { badges.append("utility") }
            if let d = f.darkFraction, d > 0.9 { badges.append("very dark") }
            if !f.failures.isEmpty { badges.append("analysis incomplete: " + f.failures.keys.sorted().joined(separator: ", ")) }
        } else {
            badges.append("not analyzed")
        }
        var c = "<figure>"
        if let thumb { c += "<img loading=\"lazy\" src=\"\(e(thumb))\" alt=\"\(e(p.assetID.rawValue))\">" }
        c += "<figcaption><code>\(e(p.assetID.rawValue))</code><br>\(e(p.sourceRelativePaths.joined(separator: ", ")))"
        c += "<br>\(p.metadata.capturedAt.map { e(iso($0)) } ?? "—")"
        if let score = f?.aestheticScore { c += " · aesthetic \(String(format: "%.2f", score))" }
        if let labels = f?.labels, !labels.isEmpty {
            c += "<br><small>\(e(labels.prefix(4).map(\.identifier).joined(separator: ", ")))</small>"
        }
        if !badges.isEmpty { c += "<br>" + badges.map { "<span class=\"b\">\(e($0))</span>" }.joined(separator: " ") }
        c += "</figcaption></figure>\n"
        return c
    }

    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private static let css = """
    body{font:14px -apple-system,system-ui,sans-serif;margin:24px;color:#111}
    table{border-collapse:collapse;margin-bottom:12px}th,td{border:1px solid #ddd;padding:4px 8px;text-align:left}
    .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px}
    figure{margin:0;border:1px solid #eee;padding:6px}img{width:100%;height:auto;display:block}
    figcaption{font-size:12px;margin-top:4px}.b{background:#f3f3f3;border-radius:3px;padding:0 4px;white-space:nowrap}
    """
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `swift test --filter CoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Report.swift Tests/CoreTests/ReportTests.swift
git commit -m "feat(core): self-contained HTML contact-sheet report"
```

---

### Task 8: CLI arguments and entry point

**Files:**
- Create: `Sources/CLI/Arguments.swift`
- Modify: `Sources/CLI/AK14Command.swift` (replace the placeholder)
- Test: `Tests/CLITests/ArgumentsTests.swift`

**Interfaces:**
- Consumes: `CarouselAspect` (Task 2)
- Produces:
  - `Command` (`.run(RunOptions)`, `.report(runDirectory: URL)`, `.help`)
  - `RunOptions(folder:recursive:aspect:runsDirectory:cacheDirectory:)`
  - `Arguments.parse(_:cwd:) throws -> Command`
  - `Arguments.usage`
  - `ArgumentError`
- Note: `AK14Command.main` calls `RunPipeline.live(options:)` and `ReportCommand.rebuild(runDirectory:)`, both built in Task 9. In this task, `main` handles only `.help` and parse errors, so the package still builds. Task 9 wires the other two cases.

- [ ] **Step 1: Write the failing tests**

`Tests/CLITests/ArgumentsTests.swift`:
```swift
import Foundation
import Testing
@testable import CLI
@testable import Core

private let cwd = URL(fileURLWithPath: "/work")

@Test func runDefaults() throws {
    let cmd = try Arguments.parse(["run", "IMG"], cwd: cwd)
    #expect(cmd == .run(RunOptions(folder: URL(fileURLWithPath: "/work/IMG"), recursive: false, aspect: nil,
                                   runsDirectory: URL(fileURLWithPath: "/work/runs"),
                                   cacheDirectory: URL(fileURLWithPath: "/work/.ak14-cache"))))
}

@Test func runWithOptions() throws {
    let cmd = try Arguments.parse(["run", "/abs/IMG", "--recursive", "--aspect", "4:5",
                                   "--runs", "out", "--cache", "/c"], cwd: cwd)
    #expect(cmd == .run(RunOptions(folder: URL(fileURLWithPath: "/abs/IMG"), recursive: true, aspect: .portrait4x5,
                                   runsDirectory: URL(fileURLWithPath: "/work/out"),
                                   cacheDirectory: URL(fileURLWithPath: "/c"))))
}

@Test func aspectAutoMeansInfer() throws {
    guard case .run(let o) = try Arguments.parse(["run", "x", "--aspect", "auto"], cwd: cwd) else {
        Issue.record("expected run"); return
    }
    #expect(o.aspect == nil)
}

@Test func reportAndHelp() throws {
    #expect(try Arguments.parse(["report", "runs/r1"], cwd: cwd) == .report(runDirectory: URL(fileURLWithPath: "/work/runs/r1")))
    #expect(try Arguments.parse([], cwd: cwd) == .help)
    #expect(try Arguments.parse(["--help"], cwd: cwd) == .help)
}

@Test func errors() {
    #expect(throws: ArgumentError.missingFolder) { try Arguments.parse(["run"], cwd: cwd) }
    #expect(throws: ArgumentError.unknownCommand("nope")) { try Arguments.parse(["nope"], cwd: cwd) }
    #expect(throws: ArgumentError.invalidAspect("2:3")) { try Arguments.parse(["run", "x", "--aspect", "2:3"], cwd: cwd) }
    #expect(throws: ArgumentError.missingValue("--runs")) { try Arguments.parse(["run", "x", "--runs"], cwd: cwd) }
    #expect(throws: ArgumentError.unknownOption("--bogus")) { try Arguments.parse(["run", "x", "--bogus"], cwd: cwd) }
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter CLITests`
Expected: FAIL to compile (`cannot find 'Arguments' in scope`).

- [ ] **Step 3: Implement**

`Sources/CLI/Arguments.swift`:
```swift
import Core
import Foundation

struct RunOptions: Equatable, Sendable {
    var folder: URL
    var recursive: Bool = false
    /// nil = infer from photos.
    var aspect: CarouselAspect? = nil
    var runsDirectory: URL
    var cacheDirectory: URL
}

enum Command: Equatable {
    case run(RunOptions)
    case report(runDirectory: URL)
    case help
}

enum ArgumentError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String), missingFolder, missingRunDirectory
    case missingValue(String), unknownOption(String), invalidAspect(String)

    var description: String {
        switch self {
        case .unknownCommand(let c): "unknown command '\(c)'"
        case .missingFolder: "run needs a photo folder"
        case .missingRunDirectory: "report needs a run directory"
        case .missingValue(let o): "\(o) needs a value"
        case .unknownOption(let o): "unknown option '\(o)'"
        case .invalidAspect(let a): "invalid aspect '\(a)' (use auto, 3:4, 1:1, 4:5)"
        }
    }
}

enum Arguments {
    static let usage = """
    usage:
      ak14 run <folder> [--recursive] [--aspect auto|3:4|1:1|4:5] [--runs DIR] [--cache DIR]
      ak14 report <runDir>
    """

    static func parse(_ args: [String], cwd: URL) throws -> Command {
        guard let command = args.first, command != "--help", command != "-h", command != "help" else { return .help }
        var rest = Array(args.dropFirst())
        func path(_ s: String) -> URL {
            let full = s.hasPrefix("/") ? s : (cwd.path as NSString).appendingPathComponent(s)
            return URL(fileURLWithPath: (full as NSString).standardizingPath)
        }

        switch command {
        case "report":
            guard let dir = rest.first else { throw ArgumentError.missingRunDirectory }
            return .report(runDirectory: path(dir))
        case "run":
            guard let folder = rest.first, !folder.hasPrefix("--") else { throw ArgumentError.missingFolder }
            rest.removeFirst()
            var o = RunOptions(folder: path(folder), runsDirectory: path("runs"), cacheDirectory: path(".ak14-cache"))
            while !rest.isEmpty {
                let flag = rest.removeFirst()
                func value() throws -> String {
                    guard !rest.isEmpty else { throw ArgumentError.missingValue(flag) }
                    return rest.removeFirst()
                }
                switch flag {
                case "--recursive": o.recursive = true
                case "--aspect":
                    let v = try value()
                    if v == "auto" { o.aspect = nil }
                    else if let a = CarouselAspect(rawValue: v) { o.aspect = a }
                    else { throw ArgumentError.invalidAspect(v) }
                case "--runs": o.runsDirectory = path(try value())
                case "--cache": o.cacheDirectory = path(try value())
                default: throw ArgumentError.unknownOption(flag)
                }
            }
            return .run(o)
        default:
            throw ArgumentError.unknownCommand(command)
        }
    }
}
```

`Sources/CLI/AK14Command.swift`:
```swift
import Foundation

@main
struct AK14Command {
    static func main() async {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do {
            switch try Arguments.parse(Array(CommandLine.arguments.dropFirst()), cwd: cwd) {
            case .help:
                print(Arguments.usage)
            case .run, .report:
                fail("not implemented yet")
            }
        } catch {
            fail("\(error)\n\(Arguments.usage)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `swift test --filter CLITests && swift run ak14 --help`
Expected: tests PASS; the usage text is printed.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLI Tests/CLITests/ArgumentsTests.swift
git commit -m "feat(cli): argument parsing and ak14 entry point"
```

---

### Task 9: Run pipeline, report rebuild, and end-to-end test

**Files:**
- Create: `Sources/CLI/RunPipeline.swift`, `Sources/CLI/ReportCommand.swift`
- Modify: `Sources/CLI/AK14Command.swift` (wire `.run` and `.report`)
- Test: `Tests/CLITests/PipelineTests.swift`

**Interfaces:**
- Consumes: everything above
- Produces:
  - `RunPipeline(ingester:thumbnailer:analyzer:cache:log:)`
  - `RunPipeline.live(options:log:)`
  - `RunPipeline.run(_:now:) async throws -> RunStore`
  - `ReportCommand.rebuild(runDirectory:) throws`
  - Run directory layout (subset of spec §9.3):
    - `manifest.json`
    - `input-index.json` (`IngestResult`)
    - `cache/features.json` (`[PhotoFeatures]`)
    - `cache/thumbnails/analysis/<assetID>.jpg`
    - `report.html`

- [ ] **Step 1: Write the failing tests**

`Tests/CLITests/PipelineTests.swift`:
```swift
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

@Test func secondRunHitsCacheAndIDsSurviveRename() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("event & <friends>")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "a.jpg"), gray: 0.2)
    try FixtureFactory.writeJPEG(to: folder.appending(path: "b.HEIC.jpg"), gray: 0.5)
    var portrait = FixtureFactory.Exif(); portrait.orientation = 6
    try FixtureFactory.writeJPEG(to: folder.appending(path: "c.jpg"), gray: 0.8, exif: portrait)
    try FixtureFactory.writeBytes("mov", to: folder.appending(path: "clip.mov"))
    let o = options(tmp, folder: folder)
    let pipeline = RunPipeline.live(options: o, log: { _ in })

    let first = try await pipeline.run(o, now: Date(timeIntervalSince1970: 1_000))
    let m1 = try first.read(RunManifest.self, from: "manifest.json")
    #expect(m1.photoCount == 3 && m1.skippedCount == 1)
    #expect(m1.cacheMisses == 3 && m1.cacheHits == 0)
    #expect(m1.completedAt != nil)
    #expect(m1.sourceFolderLabel == "event & <friends>")
    #expect(m1.versions["analyzer"] == VisionAnalyzer.version)
    #expect(m1.versions["thumbnailer"] == Thumbnailer.version)
    #expect(m1.versions["report"] == ReportBuilder.version)
    #expect(m1.stageTimings.map(\.stage) == ["ingest", "thumbnails", "analysis"])
    #expect(m1.aspectRatio == .portrait4x5 && !m1.aspectOverridden)   // 1 portrait of 3 → mixed
    let ids1 = try first.read(IngestResult.self, from: "input-index.json").photos.map(\.assetID)
    let feats = try first.read([PhotoFeatures].self, from: "cache/features.json")
    #expect(feats.count == 3)
    for id in ids1 {
        #expect(FileManager.default.fileExists(atPath: first.url("cache/thumbnails/analysis/\(id.rawValue).jpg").path))
    }

    try FileManager.default.moveItem(at: folder.appending(path: "a.jpg"), to: folder.appending(path: "renamed.jpg"))
    let second = try await pipeline.run(o, now: Date(timeIntervalSince1970: 2_000))
    let m2 = try second.read(RunManifest.self, from: "manifest.json")
    #expect(m2.cacheHits == 3 && m2.cacheMisses == 0)
    #expect(m2.inputDigest == m1.inputDigest)
    #expect(try second.read(IngestResult.self, from: "input-index.json").photos.map(\.assetID) == ids1)

    let html = try String(contentsOf: second.url("report.html"), encoding: .utf8)
    #expect(html.contains("renamed.jpg"))
    #expect(html.contains("event &amp; &lt;friends&gt;"))
    #expect(!html.contains(tmp.url.path))
}

@Test func aspectOverrideIsRecorded() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("e")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "a.jpg"))
    var o = options(tmp, folder: folder); o.aspect = .square
    let store = try await RunPipeline.live(options: o, log: { _ in }).run(o)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.aspectRatio == .square && m.aspectOverridden)
}

@Test func emptyAndVideoOnlyFoldersComplete() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("videos")
    try FixtureFactory.writeBytes("m", to: folder.appending(path: "x.mp4"))
    let o = options(tmp, folder: folder)
    let store = try await RunPipeline.live(options: o, log: { _ in }).run(o)
    let m = try store.read(RunManifest.self, from: "manifest.json")
    #expect(m.photoCount == 0 && m.skippedCount == 1 && m.aspectRatio == .portrait4x5)
    #expect(try String(contentsOf: store.url("report.html"), encoding: .utf8).contains("No photos were ingested"))
}

@Test func reportRebuildMatchesOriginal() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("r")
    try FixtureFactory.writeJPEG(to: folder.appending(path: "a.jpg"))
    let o = options(tmp, folder: folder)
    let store = try await RunPipeline.live(options: o, log: { _ in }).run(o)
    let original = try String(contentsOf: store.url("report.html"), encoding: .utf8)
    try FileManager.default.removeItem(at: store.url("report.html"))
    try ReportCommand.rebuild(runDirectory: store.root)
    #expect(try String(contentsOf: store.url("report.html"), encoding: .utf8) == original)
}

@Test func missingFolderFailsClearly() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let o = options(tmp, folder: tmp.url.appending(path: "nope"))
    await #expect(throws: (any Error).self) { _ = try await RunPipeline.live(options: o, log: { _ in }).run(o) }
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `swift test --filter CLITests`
Expected: FAIL to compile (`cannot find 'RunPipeline' in scope`).

- [ ] **Step 3: Implement**

`Sources/CLI/RunPipeline.swift`:
```swift
import Analysis
import Core
import CryptoKit
import Foundation

struct RunPipeline: Sendable {
    let ingester: any PhotoIngesting
    let thumbnailer: Thumbnailer
    let analyzer: any PhotoAnalyzing
    let cache: AnalysisCache
    let log: @Sendable (String) -> Void

    static func live(options: RunOptions,
                     log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    -> RunPipeline {
        RunPipeline(ingester: FolderIngester(),
                    thumbnailer: Thumbnailer(cacheRoot: options.cacheDirectory),
                    analyzer: VisionAnalyzer(cacheRoot: options.cacheDirectory),
                    cache: AnalysisCache(root: options.cacheDirectory, analyzerVersion: VisionAnalyzer.version),
                    log: log)
    }

    func run(_ options: RunOptions, now: Date = Date()) async throws -> RunStore {
        let clock = ContinuousClock()
        var timings: [StageTiming] = []
        var warnings: [String] = []

        // 1. Ingest
        var start = clock.now
        let ingest = try await ingester.ingest(folder: options.folder, options: IngestOptions(recursive: options.recursive))
        timings.append(StageTiming(stage: "ingest", seconds: (clock.now - start).seconds))
        log("Finding the best moments… \(ingest.photos.count) photos, \(ingest.skipped.count) skipped")

        // 2. Analysis-tier thumbnails (cached across runs)
        start = clock.now
        let thumbnailer = self.thumbnailer
        let folder = options.folder.resolvingSymlinksInPath()
        let thumbURLs: [URL?] = try await ingest.photos.concurrentMap(limit: 4) { p in
            try? thumbnailer.thumbnail(sha: p.contentSHA256, source: folder.appending(path: p.sourceRelativePaths[0]),
                                       tier: .analysis)
        }
        var thumbByID: [AssetID: URL] = [:]
        for (p, url) in zip(ingest.photos, thumbURLs) {
            if let url { thumbByID[p.assetID] = url } else { warnings.append("thumbnail failed: \(p.sourceRelativePaths[0])") }
        }
        timings.append(StageTiming(stage: "thumbnails", seconds: (clock.now - start).seconds))

        // 3. Vision features (cached by content digest + analyzer version)
        start = clock.now
        var features: [AssetID: PhotoFeatures] = [:]
        var pending: [(PhotoRecord, URL)] = []
        for p in ingest.photos {
            guard let url = thumbByID[p.assetID] else { continue }
            if let cached = cache.load(sha: p.contentSHA256) { features[p.assetID] = cached } else { pending.append((p, url)) }
        }
        let hits = features.count
        log("Analyzing \(pending.count) photos (\(hits) cached)…")
        let analyzer = self.analyzer
        let fresh = try await pending.concurrentMap(limit: 4) { pair in await analyzer.analyze(pair.0, thumbnailURL: pair.1) }
        for ((p, _), f) in zip(pending, fresh) {
            features[p.assetID] = f
            if f.failures.isEmpty {
                try cache.store(f, sha: p.contentSHA256)
            } else {
                warnings.append("analysis incomplete for \(p.sourceRelativePaths[0]): \(f.failures.keys.sorted().joined(separator: ", "))")
            }
        }
        timings.append(StageTiming(stage: "analysis", seconds: (clock.now - start).seconds))

        // 4. Run directory
        let store = try RunStore.create(in: options.runsDirectory, runID: RunID.make(now: now))
        var thumbRel: [AssetID: String] = [:]
        for (id, url) in thumbByID.sorted(by: { $0.key < $1.key }) {
            let rel = "cache/thumbnails/analysis/\(id.rawValue).jpg"
            let target = store.url(rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            thumbRel[id] = rel
        }

        var manifest = RunManifest(runID: store.root.lastPathComponent, createdAt: now,
                                   sourceFolderLabel: options.folder.lastPathComponent)
        manifest.inputDigest = Self.inputDigest(ingest.photos)
        manifest.photoCount = ingest.photos.count
        manifest.skippedCount = ingest.skipped.count
        manifest.aspectRatio = options.aspect ?? CarouselAspect.infer(from: ingest.photos)
        manifest.aspectOverridden = options.aspect != nil
        manifest.versions = ["analyzer": VisionAnalyzer.version, "thumbnailer": Thumbnailer.version,
                             "report": ReportBuilder.version, "manifestSchema": "\(RunManifest.currentSchemaVersion)"]
        manifest.stageTimings = timings
        manifest.cacheHits = hits
        manifest.cacheMisses = pending.count
        manifest.warnings = warnings
        manifest.completedAt = now.addingTimeInterval(timings.reduce(0) { $0 + $1.seconds })

        try store.write(ingest, to: "input-index.json")
        try store.write(ingest.photos.compactMap { features[$0.assetID] }, to: "cache/features.json")
        try store.write(manifest, to: "manifest.json")
        try store.writeText(ReportBuilder.html(ReportInput(manifest: manifest, photos: ingest.photos, skipped: ingest.skipped,
                                                           features: features, thumbnails: thumbRel)),
                            to: "report.html")
        log("Report: \(store.url("report.html").path)")
        return store
    }

    static func inputDigest(_ photos: [PhotoRecord]) -> String {
        let joined = photos.map(\.contentSHA256).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

`Sources/CLI/ReportCommand.swift`:
```swift
import Core
import Foundation

enum ReportCommand {
    /// Rebuilds report.html from stored artifacts only. Never touches the source folder or the network.
    static func rebuild(runDirectory: URL) throws {
        let store = RunStore.open(runDirectory)
        let manifest = try store.read(RunManifest.self, from: "manifest.json")
        let ingest = try store.read(IngestResult.self, from: "input-index.json")
        let features = try store.read([PhotoFeatures].self, from: "cache/features.json")
        var thumbs: [AssetID: String] = [:]
        for p in ingest.photos {
            let rel = "cache/thumbnails/analysis/\(p.assetID.rawValue).jpg"
            if FileManager.default.fileExists(atPath: store.url(rel).path) { thumbs[p.assetID] = rel }
        }
        let html = ReportBuilder.html(ReportInput(
            manifest: manifest, photos: ingest.photos, skipped: ingest.skipped,
            features: Dictionary(uniqueKeysWithValues: features.map { ($0.assetID, $0) }), thumbnails: thumbs))
        try store.writeText(html, to: "report.html")
    }
}
```

In `Sources/CLI/AK14Command.swift`, replace the `case .run, .report:` branch with:
```swift
            case .run(let options):
                let store = try await RunPipeline.live(options: options).run(options)
                print(store.url("report.html").path)
            case .report(let dir):
                try ReportCommand.rebuild(runDirectory: dir)
                print(dir.appending(path: "report.html").path)
```

- [ ] **Step 4: Run all tests to confirm they pass**

Run: `swift test`
Expected: all CoreTests, AnalysisTests and CLITests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLI Tests/CLITests/PipelineTests.swift
git commit -m "feat(cli): ak14 run pipeline with cached analysis and report rebuild"
```

---

### Task 10: M1 exit demo on the real `IMG/` folder

**Files:**
- Modify: `tasks/todo.md` (mark M1 done; add a review section)

**Interfaces:**
- Consumes: the built `ak14` binary.
- Produces: verified M1 exit criteria (spec §12 M1).

- [ ] **Step 1: First run (cold cache)**

Run: `swift build -c release && time .build/release/ak14 run IMG`
Expected:
- It exits 0 and prints the report path.
- The log shows `458 photos, 42 skipped` (374 HEIC + 82 JPG + 2 PNG; 37 MOV + 5 MP4). If the counts differ, explain why in the review before continuing.

- [ ] **Step 2: Inspect the manifest**

Run: `cat runs/*/manifest.json | head -60`
Expected:
- `cacheMisses` = 458, `photoCount` = 458, `skippedCount` = 42.
- `aspectRatio` is inferred from real orientations.
- `warnings` is empty or explained.

- [ ] **Step 3: Second run (warm cache)**

Run: `time .build/release/ak14 run IMG`
Expected:
- The newest manifest shows `cacheHits` = 458 and `cacheMisses` = 0.
- Wall time is well under the first run's.
- `inputDigest` matches the first run.

- [ ] **Step 4: Report checks**

Run: `open "$(ls -d runs/* | tail -1)/report.html"`
Check by eye:
- Counts match.
- Videos are listed as skipped.
- The ~77 received photos show "no camera metadata".
- Thumbnails are upright.

Then run: `grep -c "/Users/" "$(ls -d runs/* | tail -1)/report.html"`
Expected: `0`.

- [ ] **Step 5: Report rebuild**

Run: `.build/release/ak14 report "$(ls -d runs/* | tail -1)"`
Expected: exits 0 and `report.html` is rewritten.

- [ ] **Step 6: Record the result and commit**

Update `tasks/todo.md`: tick the M1 items and add a `## Review` section with the counts, timings (cold vs warm), aspect ratio and any warnings.

```bash
git add tasks/todo.md
git commit -m "docs: record M1 exit demo results"
```

---

## Self-review notes

- **Spec coverage (M1 scope):**

  | Spec requirement | Task |
  |---|---|
  | Folder ingest | 4 |
  | Stable IDs | 1, 4 |
  | Thumbnail tiers | 1 defines all tiers, 5 builds analysis |
  | Vision features | 6 |
  | File/error reporting | 4, 7 |
  | Cache | 3, 5, 9 |
  | Run manifest | 3, 9 |
  | Contact sheet + `report.html` with accepted/rejected reasons | 7 |
  | API-free local mode | M1 has no provider at all |
  | Exit demo: run twice, cache reuse, rename stability, report contents | 9 automated, 10 on real data |

- **Deferred to M2+ on purpose:**
  - clustering, junk filter, rank → M2
  - triage/planning tiers used, Director → M3
  - Render → M4
  - Studio → M5
  - `llm/`, `plans/`, `layouts/`, `slides/`, `interaction-events.jsonl` run-dir entries → the milestones that produce them
- **Deviation from spec:** the per-run `cache/` holds only the files the report needs (analysis thumbnails, `features.json`). The persistent cross-run cache lives in `.ak14-cache/`. Spec §9.3 is silent on where the reusable cache lives, and M1's exit demo requires cross-run reuse.

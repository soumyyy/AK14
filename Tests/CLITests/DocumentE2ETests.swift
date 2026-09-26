import CoreGraphics
import Foundation
import ImageIO
import Testing
import TestSupport
@testable import Analysis
@testable import CLI
@testable import Core
@testable import Director
@testable import Render

@Test func canvasDocumentRoundTripsThroughJSONAndSlicesOnSlideBoundaries() throws {
    let layer = DocumentLayer(id: "photo-1", kind: .photo,
                              frame: UnitRect(x: 0.2, y: 0.1, width: 0.4, height: 0.7), slideHint: 1,
                              assetID: AssetID(rawValue: "photo"), crop: UnitRect(x: 0.1, y: 0.2, width: 0.8, height: 0.7))
    let document = CanvasDocument(id: "c1", aspect: .square, slideCount: 3, seamless: true,
                                  background: .colour("#ffffff"), layers: [layer], seed: "a")
    let data = try JSONEncoder().encode(document)
    #expect(try JSONDecoder().decode(CanvasDocument.self, from: data) == document)
    #expect(document.version == "document-1")
    #expect(document.layers(onSlide: 1) == [layer])
    #expect(document.sliceGeometry(forSlide: 2).x == 2160)
}

private func documentRun(_ tmp: TempDirectory) async throws -> RunStore {
    let folder = try tmp.sub("photos")
    for i in 0..<14 {
        var exif = FixtureFactory.Exif()
        exif.date = String(format: "2026:05:29 %02d:%02d:00", 8 + i / 3, (i % 3) * 20)
        exif.orientation = i % 3 == 0 ? 6 : 1
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    let options = RunOptions(folder: folder, runsDirectory: tmp.url.appending(path: "runs"),
                             cacheDirectory: tmp.url.appending(path: "cache"), consent: true)
    return try await RunPipeline.live(options: options, client: ResponsesClient(transport: FakeModel(), sleep: { _ in }), log: { _ in }).run(options)
}

/// Two slides that force every `ResolvedElement` kind to appear, independent of the pipeline's own
/// choices: a `runID`-derived composition seed (see `RunID.make`) means a FakeModel run's decoration
/// budget lands its tape/date-stamp decorations on different slides on every process launch, so relying
/// on a real run to exercise `.tape` and `.stamp` would make this test flaky. Slide 0 is still resolved
/// through the real `LayoutResolver` (with a forced `tape-clear` decoration) so its geometry and safety
/// checks run for real; slide 1's stamp is a hand-built `ResolvedElement`, since date-stamp placement
/// itself depends on that same random seed.
private func forcedElementsCarousel(_ tmp: TempDirectory) async throws -> (carousel: ResolvedCarousel, photos: [AssetID: PhotoRecord], sourceFolder: URL) {
    let folder = try tmp.sub("forced")
    for i in 0..<3 {
        var exif = FixtureFactory.Exif(); exif.date = String(format: "2026:05:29 %02d:00:00", 8 + i)
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    let records = try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, $0) })
    let ids = records.map(\.assetID)
    let style = StyleVector(density: "dense", overlap: "bold", grouping: "collage", decoration: "rich", rotation: "some", whitespace: "tight")
    let direction = Direction(brief: "", style: style, coverAssetID: ids[0], orderedAssetIDs: ids)
    let clusterSlide = SlidePlan(primitive: .overlapCluster, mood: "", density: "dense", photos: ids.map { .plain($0) },
                                 decorations: [DecorationElement(decorationID: "tape-clear", intensity: "medium")], stamps: [])
    let plan = CarouselPlan(id: "forced", brief: "", direction: direction, slides: [clusterSlide])
    let features = Dictionary(uniqueKeysWithValues: ids.map { ($0, PhotoFeatures(assetID: $0, analyzerVersion: "test")) })
    let context = LayoutContext(aspect: .square, photos: byID, features: features, stylePack: try StylePackLoader.load(), seed: 4471)
    let resolvedCluster = try #require(LayoutResolver.resolve(plan, context: context).slides.first)
    #expect(resolvedCluster.elements.contains { $0.kind == .tape })

    let stampSlide = ResolvedSlide(index: 1, primitive: .hero, requestedPrimitive: .hero, background: "plain",
                                   grain: 0, filmEdge: false, elements: [
                                       ResolvedElement(kind: .photo, assetID: ids[0], text: nil,
                                                       frame: UnitRect(x: 0, y: 0, width: 1, height: 1), rotationDegrees: 0,
                                                       crop: nil, zIndex: 0, opacity: 1, border: 0, shadow: false),
                                       ResolvedElement(kind: .stamp, assetID: nil, text: "29 MAY",
                                                       frame: UnitRect(x: 0.6, y: 0.85, width: 0.35, height: 0.08), rotationDegrees: 0,
                                                       crop: nil, zIndex: 1, opacity: 1, border: 0, shadow: false),
                                   ], warnings: [])
    let carousel = ResolvedCarousel(id: "forced", aspect: .square, seed: "1194",
                                    resolverVersion: ResolvedCarousel.resolverVersion, slides: [resolvedCluster, stampSlide])
    return (carousel, byID, folder)
}

@Test func documentRendererMatchesLegacyForEveryFakeModelOptionAndConvertsAllElements() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let store = try await documentRun(tmp)
    let report = try store.read(ConceptsReport.self, from: "plans/director.json")
    let photos = try store.read(IngestResult.self, from: "input-index.json").photos
    let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.assetID, $0) })
    var sawKinds = Set<ElementKind>(), sawBackgrounds = Set<String>()
    // One case per option, run through the pipeline for real.
    for option in report.plans {
        let slides = try report.renderedSlides[option.id]!.indices.map {
            try store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", option.id, $0 + 1))
        }
        let carousel = ResolvedCarousel(id: option.id, aspect: .portrait4x5, seed: option.compositionSeed ?? "0",
                                        resolverVersion: ResolvedCarousel.resolverVersion, slides: slides)
        let document = CanvasDocument(from: carousel, photos: byID)
        #expect(document.layers.count == slides.reduce(0) { $0 + $1.elements.count })
        for slide in slides {
            sawBackgrounds.insert(slide.background)
            for element in slide.elements { sawKinds.insert(element.kind) }
        }
        let old = try CarouselRenderer().legacyRender(carousel, photos: byID, sourceFolder: tmp.url.appending(path: "photos"), outputDirectory: tmp.url.appending(path: "old-\(option.id)"))
        let new = try CarouselRenderer().render(carousel, photos: byID, sourceFolder: tmp.url.appending(path: "photos"), outputDirectory: tmp.url.appending(path: "new-\(option.id)"))
        #expect(old.failures.isEmpty && new.failures.isEmpty)
        for name in old.names { #expect(try Data(contentsOf: tmp.url.appending(path: "old-\(option.id)/\(name)")) == Data(contentsOf: tmp.url.appending(path: "new-\(option.id)/\(name)"))) }
    }
    // Force every remaining element kind (see forcedElementsCarousel's doc comment for why a real
    // FakeModel run cannot be relied on for this) and prove conversion and byte identity for those too.
    let (forcedCarousel, forcedPhotos, forcedFolder) = try await forcedElementsCarousel(tmp)
    let forcedDocument = CanvasDocument(from: forcedCarousel, photos: forcedPhotos)
    #expect(forcedDocument.layers.count == forcedCarousel.slides.reduce(0) { $0 + $1.elements.count })
    for slide in forcedCarousel.slides {
        sawBackgrounds.insert(slide.background)
        for element in slide.elements { sawKinds.insert(element.kind) }
    }
    let oldForced = try CarouselRenderer().legacyRender(forcedCarousel, photos: forcedPhotos, sourceFolder: forcedFolder, outputDirectory: tmp.url.appending(path: "old-forced"))
    let newForced = try CarouselRenderer().render(forcedCarousel, photos: forcedPhotos, sourceFolder: forcedFolder, outputDirectory: tmp.url.appending(path: "new-forced"))
    #expect(oldForced.failures.isEmpty && newForced.failures.isEmpty)
    for name in oldForced.names { #expect(try Data(contentsOf: tmp.url.appending(path: "old-forced/\(name)")) == Data(contentsOf: tmp.url.appending(path: "new-forced/\(name)"))) }

    #expect(sawKinds == Set(ElementKind.allCases))
    #expect(!sawBackgrounds.isEmpty)
}

private func singlePhoto(_ tmp: TempDirectory, folderName: String) async throws -> (PhotoRecord, URL) {
    let folder = try tmp.sub(folderName)
    try FixtureFactory.writeScene(to: folder.appending(path: "IMG_0000.jpg"), scene: 0, exif: FixtureFactory.Exif())
    let record = try #require(try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos.first)
    return (record, folder)
}

@Test func neutralAdjustmentsMatchNoAdjustmentsButExposureChangesTheOutput() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (photo, folder) = try await singlePhoto(tmp, folderName: "adjustments")
    let byID = [photo.assetID: photo]
    func document(adjustments: PhotoAdjustments?) -> CanvasDocument {
        let layer = DocumentLayer(id: "p1", kind: .photo, frame: UnitRect(x: 0, y: 0, width: 1, height: 1), slideHint: 0,
                                  assetID: photo.assetID, crop: UnitRect(x: 0, y: 0, width: 1, height: 1), adjustments: adjustments)
        return CanvasDocument(id: "adj", aspect: .square, slideCount: 1, layers: [layer])
    }
    func renderedPNG(_ document: CanvasDocument, name: String) throws -> Data {
        let dir = tmp.url.appending(path: name)
        let outcome = try DocumentRenderer().render(document, photos: byID, sourceFolder: folder, outputDirectory: dir)
        #expect(outcome.failures.isEmpty)
        return try Data(contentsOf: dir.appending(path: try #require(outcome.names.first)))
    }
    let noAdjustments = try renderedPNG(document(adjustments: nil), name: "none")
    let neutral = try renderedPNG(document(adjustments: PhotoAdjustments()), name: "neutral")
    #expect(noAdjustments == neutral, "a neutral PhotoAdjustments must rerender byte-identically to no adjustments at all")
    let exposed = try renderedPNG(document(adjustments: PhotoAdjustments(exposure: 0.8)), name: "exposed")
    #expect(exposed != noAdjustments, "a non-neutral exposure must change the rendered bytes")
}

/// Draws the image into a 1x1 sRGB context: a cheap, format-independent average of a small sample rect.
private func averageColor(of image: CGImage, sampleRect: CGRect) -> (r: Double, g: Double, b: Double) {
    guard let cropped = image.cropping(to: sampleRect) else { return (-1, -1, -1) }
    var pixel = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
}

@Test func seamlessDocumentExportsSlideSizedPNGsWithAPhotoStraddlingTheEdge() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (photo, folder) = try await singlePhoto(tmp, folderName: "seamless")
    let byID = [photo.assetID: photo]
    // Document space spans 3 slides (x in 0...1); this layer sits at x 0.25...0.45, straddling the
    // slide-0/slide-1 boundary at x = 1/3.
    let layer = DocumentLayer(id: "p1", kind: .photo, frame: UnitRect(x: 0.25, y: 0.3, width: 0.2, height: 0.4),
                              assetID: photo.assetID, crop: UnitRect(x: 0, y: 0, width: 1, height: 1))
    let document = CanvasDocument(id: "seam", aspect: .square, slideCount: 3, seamless: true, layers: [layer])
    let outDir = tmp.url.appending(path: "seam-out")
    let outcome = try DocumentRenderer().render(document, photos: byID, sourceFolder: folder, outputDirectory: outDir)
    #expect(outcome.failures.isEmpty)
    #expect(outcome.names.count == 3)

    let W = CarouselAspect.square.exportWidth, H = CarouselAspect.square.exportHeight
    var images: [CGImage] = []
    for name in outcome.names {
        let src = try #require(CGImageSourceCreateWithURL(outDir.appending(path: name) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(image.width == W && image.height == H, "\(name) is not a full slide-sized PNG")
        images.append(image)
    }
    // Paper background colour (see CarouselRenderer.paperColor): distinguishing a photo pixel from the
    // background needs only a loose threshold, since the fixture scene is randomly, vividly coloured.
    func isBackground(_ c: (r: Double, g: Double, b: Double)) -> Bool {
        abs(c.r - 244) < 12 && abs(c.g - 241) < 12 && abs(c.b - 234) < 12
    }
    // On slide 0 the layer is visible on its right portion (local x in [0.75, 1.0]); on slide 1, its left
    // portion (local x in [0.0, 0.35]). Sample well inside each, away from edges/antialiasing.
    let onSlide0 = CarouselRenderer.cgRect(UnitRect(x: 0.85, y: 0.48, width: 0.06, height: 0.06), W: Double(W), H: Double(H))
    let onSlide1 = CarouselRenderer.cgRect(UnitRect(x: 0.15, y: 0.48, width: 0.06, height: 0.06), W: Double(W), H: Double(H))
    let colourOnSlide0 = averageColor(of: images[0], sampleRect: onSlide0)
    let colourOnSlide1 = averageColor(of: images[1], sampleRect: onSlide1)
    #expect(!isBackground(colourOnSlide0), "the straddling photo should show on slide 0 near its right edge")
    #expect(!isBackground(colourOnSlide1), "the straddling photo should show on slide 1 near its left edge")
}

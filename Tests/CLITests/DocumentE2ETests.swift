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

@Test func carouselConversionPreservesTemplateProvenanceBackgroundsAndSeamContinuity() {
    let photo = AssetID(rawValue: "template-photo")
    let first = ResolvedSlide(index: 0, primitive: .hero, requestedPrimitive: .hero, background: "#FAF6F3",
        grain: 0.12, filmEdge: true,
        elements: [ResolvedElement(kind: .photo, assetID: photo, text: nil,
            frame: UnitRect(x: 0.5, y: 0.2, width: 0.5, height: 0.6), rotationDegrees: 0,
            crop: UnitRect(x: 0, y: 0.1, width: 0.5, height: 0.8), zIndex: 0, opacity: 1, border: 0, shadow: false)],
        warnings: [], variant: "template.panorama-test")
    let second = ResolvedSlide(index: 1, primitive: .hero, requestedPrimitive: .hero, background: "white",
        grain: 0, filmEdge: false,
        elements: [ResolvedElement(kind: .photo, assetID: photo, text: nil,
            frame: UnitRect(x: 0, y: 0.2, width: 0.5, height: 0.6), rotationDegrees: 0,
            crop: UnitRect(x: 0.5, y: 0.1, width: 0.5, height: 0.8), zIndex: 0, opacity: 1, border: 0, shadow: false)],
        warnings: [], variant: "template.panorama-test")
    let carousel = ResolvedCarousel(id: "template-test", aspect: .square, seed: "a14",
        resolverVersion: ResolvedCarousel.resolverVersion, slides: [first, second])
    let document = CanvasDocument(from: carousel, photos: [:])
    #expect(document.templateID == "panorama-test")
    #expect(document.slideVariants == ["template.panorama-test", "template.panorama-test"])
    #expect(document.slideBackgrounds == ["#FAF6F3", "white"])
    #expect(document.slideGrain == [0.12, 0])
    #expect(document.slideFilmEdges == [true, false])
    #expect(document.seamless)
}

@Test func mixedTemplateVariantsStayOnDocumentRendererAndKeepHexBackgrounds() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let photo = AssetID(rawValue: "unavailable-template-photo")
    let slides = ["#FF0000", "#00FF00"].enumerated().map { index, background in
        ResolvedSlide(index: index, primitive: .hero, requestedPrimitive: .hero, background: background,
            grain: 0, filmEdge: false,
            elements: [ResolvedElement(kind: .photo, assetID: photo, text: nil,
                frame: UnitRect(x: 0, y: 0, width: 1, height: 1), rotationDegrees: 0,
                crop: UnitRect(x: 0, y: 0, width: 1, height: 1), zIndex: 0, opacity: 1, border: 0, shadow: false)],
            warnings: [], variant: "template.variant-\(index)")
    }
    let document = CanvasDocument(from: ResolvedCarousel(id: "mixed-template", aspect: .square, seed: "10",
        resolverVersion: ResolvedCarousel.resolverVersion, slides: slides), photos: [:])
    #expect(document.templateID == nil)
    #expect(document.slideVariants == ["template.variant-0", "template.variant-1"])

    let output = tmp.url.appending(path: "mixed-template")
    let result = try DocumentRenderer().render(document, photos: [:], sourceFolder: tmp.url, outputDirectory: output)
    #expect(result.failures.isEmpty)
    #expect(result.names.count == 2)
    let first = try rgba(of: output.appending(path: "slide-01.png"))
    let second = try rgba(of: output.appending(path: "slide-02.png"))
    let center = (CarouselAspect.square.exportHeight / 2 * first.width + first.width / 2) * 4
    #expect(first.bytes[center] == 255 && first.bytes[center + 1] == 0 && first.bytes[center + 2] == 0)
    #expect(second.bytes[center] == 0 && second.bytes[center + 1] == 255 && second.bytes[center + 2] == 0)
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
    // One case per option, run through the pipeline for real. A recipe-filled option (spec §3) renders
    // straight from a CanvasDocument and never had a ResolvedCarousel to convert, so byte-identity to
    // legacyRender — which is a property of the conversion, not of every option — does not apply to it.
    for option in report.plans where FileManager.default.fileExists(atPath: store.url("layouts/\(option.id)").path) {
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
        // Options with imported template pages render natively (hex grounds, seams), so byte identity to
        // legacyRender does not apply; they must still render every slide.
        if slides.contains(where: { $0.variant?.hasPrefix("template.") == true }) {
            let native = try DocumentRenderer().render(document, photos: byID, sourceFolder: tmp.url.appending(path: "photos"), outputDirectory: tmp.url.appending(path: "native-\(option.id)"))
            #expect(native.failures.isEmpty && native.names.count == slides.count)
            continue
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

    // The legacy bridge still exercises every legacy kind; template `.text` and `.frame` are
    // rendered natively and are covered by the dedicated template renderer tests.
    #expect(sawKinds.isSuperset(of: [.photo, .tape, .stamp]))
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

@Test func addingModernTextKeepsConvertedWashTapeGrainAndFilmEdge() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (photo, folder) = try await singlePhoto(tmp, folderName: "treatment-preservation")
    let byID = [photo.assetID: photo]
    let slide = ResolvedSlide(index: 0, primitive: .hero, requestedPrimitive: .hero,
        background: "wash:\(photo.assetID.rawValue)", grain: 0.35, filmEdge: true,
        elements: [
            ResolvedElement(kind: .photo, assetID: photo.assetID, text: nil,
                frame: UnitRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), rotationDegrees: 0,
                crop: UnitRect(x: 0, y: 0, width: 1, height: 1), zIndex: 0, opacity: 1, border: 0, shadow: false),
            ResolvedElement(kind: .tape, assetID: nil, text: nil,
                frame: UnitRect(x: 0.08, y: 0.1, width: 0.2, height: 0.06), rotationDegrees: -4,
                crop: nil, zIndex: 1, opacity: 0.8, border: 0, shadow: false),
        ], warnings: [])
    let carousel = ResolvedCarousel(id: "treatment-preservation", aspect: .square, seed: "cafe",
        resolverVersion: ResolvedCarousel.resolverVersion, slides: [slide])
    var document = CanvasDocument(from: carousel, photos: byID)
    document.layers.append(DocumentLayer(id: "new-text", kind: .text,
        frame: UnitRect(x: 0.2, y: 0.88, width: 0.6, height: 0.06), z: 2, slideHint: 0,
        string: "Edited title", fontID: "font-inter", size: 32, colour: "#222222"))

    func png(_ value: CanvasDocument, _ directory: String) throws -> Data {
        let output = tmp.url.appending(path: directory)
        let result = try DocumentRenderer().render(value, photos: byID, sourceFolder: folder, outputDirectory: output)
        #expect(result.failures.isEmpty)
        return try Data(contentsOf: output.appending(path: "slide-01.png"))
    }
    let rendered = try png(document, "with-treatment")

    var noTape = document
    noTape.layers.removeAll { $0.id == "s0-1" }
    #expect(rendered != (try png(noTape, "without-tape")), "converted tape must remain visible after modern text forces document rendering")

    var untreated = document
    untreated.slideBackgrounds = ["plain"]
    untreated.slideGrain = [0]
    untreated.slideFilmEdges = [false]
    #expect(rendered != (try png(untreated, "without-slide-treatment")), "wash, grain and film edge must survive the renderer switch")
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
    let preview = try DocumentRenderer().renderSlide(document, slide: 0, photos: byID, sourceFolder: folder)
    let previewPath = tmp.url.appending(path: "preview.png")
    try CarouselRenderer.writePNG(preview, to: previewPath)
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
    #expect(try Data(contentsOf: previewPath) == Data(contentsOf: outDir.appending(path: "slide-01.png")))
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

// MARK: - CS-4b: kit, fonts, masks

/// A `UnitRect` (y measured from the slide's top, per the document model) converted into the pixel rect of a
/// top-down buffer such as `rgba(of:)` below. `CarouselRenderer.cgRect` is deliberately not reused here: it
/// converts into bottom-up CGContext user space (for drawing), which is a different coordinate system.
private func topDownRect(_ u: UnitRect, W: Double, H: Double) -> CGRect {
    CGRect(x: u.x * W, y: u.y * H, width: u.width * W, height: u.height * H)
}

/// Full RGBA buffer of a PNG file, top-left origin (row 0 = image top), for pixel-exact comparisons.
private func rgba(of url: URL) throws -> (width: Int, height: Int, bytes: [UInt8]) {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, bytes)
}

@Test func documentWithOneLayerOfEveryKindRendersDeterministically() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (photo, folder) = try await singlePhoto(tmp, folderName: "every-kind")
    let byID = [photo.assetID: photo]
    let layers: [DocumentLayer] = [
        DocumentLayer(id: "photo", kind: .photo, frame: UnitRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5), slideHint: 0,
                     assetID: photo.assetID, crop: UnitRect(x: 0, y: 0, width: 1, height: 1)),
        DocumentLayer(id: "text", kind: .text, frame: UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.15), slideHint: 0,
                     string: "Every kind", fontID: "font-inter", size: 24, colour: "#111111"),
        DocumentLayer(id: "sticker", kind: .sticker, frame: UnitRect(x: 0.5, y: 0.7, width: 0.2, height: 0.15), slideHint: 0,
                     assetID: AssetID(rawValue: "doodle-star")),
        DocumentLayer(id: "shape", kind: .shape, frame: UnitRect(x: 0.75, y: 0.7, width: 0.2, height: 0.15), slideHint: 0,
                     shapeKind: "roundedRect", fill: "#3355AA"),
        DocumentLayer(id: "texture", kind: .texture, frame: UnitRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5), slideHint: 0,
                     assetID: AssetID(rawValue: "grain-fine"), textureBlend: "multiply", intensity: 0.5),
    ]
    let document = CanvasDocument(id: "one-of-each", aspect: .square, slideCount: 1, background: .colour("#F4F1EA"), layers: layers)
    let first = try DocumentRenderer().render(document, photos: byID, sourceFolder: folder, outputDirectory: tmp.url.appending(path: "first"))
    let second = try DocumentRenderer().render(document, photos: byID, sourceFolder: folder, outputDirectory: tmp.url.appending(path: "second"))
    #expect(first.failures.isEmpty && second.failures.isEmpty)
    #expect(first.names == ["slide-01.png"] && second.names == first.names)
    let a = try Data(contentsOf: tmp.url.appending(path: "first/slide-01.png"))
    let b = try Data(contentsOf: tmp.url.appending(path: "second/slide-01.png"))
    #expect(a == b, "a document with one layer of every kind must render byte-identically across runs")
}

@Test func everyBundledFontRendersVisibleTextPixelsInsideItsTextBox() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (photo, folder) = try await singlePhoto(tmp, folderName: "fonts")
    let byID = [photo.assetID: photo]
    // The typography kit's OFL fonts (spec §4); the legacy DSEG7 digital-clock font is covered separately
    // by stampsUseLocalCaptureDateAndFilmEdgeKeepsContentClear.
    let fontIDs = BundledFonts.registeredIDs.filter { $0 != "font-dseg7-classic-bold" }
    #expect(fontIDs.count >= 6, "expected the 6-8 OFL fonts from spec §4, found \(fontIDs.count)")

    let frame = UnitRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
    let W = CarouselAspect.square.exportWidth, H = CarouselAspect.square.exportHeight
    let box = topDownRect(frame, W: Double(W), H: Double(H))
    for fontID in fontIDs {
        let layer = DocumentLayer(id: "t", kind: .text, frame: frame, slideHint: 0, string: "Aq gj 17", fontID: fontID, size: 64, colour: "#111111")
        let document = CanvasDocument(id: fontID, aspect: .square, slideCount: 1, background: .colour("#F4F1EA"), layers: [layer])
        let dir = tmp.url.appending(path: fontID)
        let outcome = try DocumentRenderer().render(document, photos: byID, sourceFolder: folder, outputDirectory: dir)
        #expect(outcome.failures.isEmpty, "\(fontID) failed to render: \(outcome.failures)")
        let (w, h, bytes) = try rgba(of: dir.appending(path: try #require(outcome.names.first)))
        var sawGlyphPixel = false
        let x0 = max(0, Int(box.minX)), x1 = min(w, Int(box.maxX)), y0 = max(0, Int(box.minY)), y1 = min(h, Int(box.maxY))
        outer: for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                let o = (y * w + x) * 4
                // Background is the warm paper "#F4F1EA" ≈ (244,241,234); a dark glyph pixel differs sharply.
                if Int(bytes[o]) < 200 || Int(bytes[o + 1]) < 200 || Int(bytes[o + 2]) < 200 { sawGlyphPixel = true; break outer }
            }
        }
        #expect(sawGlyphPixel, "\(fontID) drew no visible glyph pixels inside its text box")
    }
}

@Test func stickerLayerChangesPixelsOnlyInsideItsFrame() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (photo, folder) = try await singlePhoto(tmp, folderName: "sticker-bounds")
    let byID = [photo.assetID: photo]
    let frame = UnitRect(x: 0.55, y: 0.62, width: 0.18, height: 0.12)
    func document(withSticker: Bool) -> CanvasDocument {
        let layers = withSticker ? [DocumentLayer(id: "s", kind: .sticker, frame: frame, slideHint: 0, assetID: AssetID(rawValue: "doodle-heart"))] : []
        return CanvasDocument(id: "sticker-bounds", aspect: .square, slideCount: 1, background: .colour("#F4F1EA"), layers: layers)
    }
    let plainDir = tmp.url.appending(path: "plain"), stickerDir = tmp.url.appending(path: "sticker")
    let plain = try DocumentRenderer().render(document(withSticker: false), photos: byID, sourceFolder: folder, outputDirectory: plainDir)
    let withSticker = try DocumentRenderer().render(document(withSticker: true), photos: byID, sourceFolder: folder, outputDirectory: stickerDir)
    #expect(plain.failures.isEmpty && withSticker.failures.isEmpty)
    let (w, h, a) = try rgba(of: plainDir.appending(path: try #require(plain.names.first)))
    let (w2, h2, b) = try rgba(of: stickerDir.appending(path: try #require(withSticker.names.first)))
    #expect(w == w2 && h == h2)
    let W = CarouselAspect.square.exportWidth, H = CarouselAspect.square.exportHeight
    let box = topDownRect(frame, W: Double(W), H: Double(H))
    var sawChangeInsideFrame = false, allChangesInsideFrame = true
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            guard a[o] != b[o] || a[o + 1] != b[o + 1] || a[o + 2] != b[o + 2] else { continue }
            let inside = CGFloat(x) >= box.minX && CGFloat(x) < box.maxX && CGFloat(y) >= box.minY && CGFloat(y) < box.maxY
            if inside { sawChangeInsideFrame = true } else { allChangesInsideFrame = false }
        }
    }
    #expect(sawChangeInsideFrame, "the sticker should visibly change pixels inside its frame")
    #expect(allChangesInsideFrame, "the sticker must not change any pixel outside its frame")
}

@Test func tornMaskClipsThePhoto() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let (photo, folder) = try await singlePhoto(tmp, folderName: "torn-mask")
    let byID = [photo.assetID: photo]
    // A frame well inside the canvas, so any background revealed by the torn edge is unambiguous.
    let frame = UnitRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    func document(mask: Mask?) -> CanvasDocument {
        let layer = DocumentLayer(id: "p", kind: .photo, frame: frame, slideHint: 0, assetID: photo.assetID,
                                  crop: UnitRect(x: 0, y: 0, width: 1, height: 1), mask: mask)
        return CanvasDocument(id: "torn", aspect: .square, slideCount: 1, background: .colour("#F4F1EA"), layers: [layer], seed: "0")
    }
    let rectDir = tmp.url.appending(path: "rect"), tornDir = tmp.url.appending(path: "torn")
    let rectOutcome = try DocumentRenderer().render(document(mask: nil), photos: byID, sourceFolder: folder, outputDirectory: rectDir)
    let tornOutcome = try DocumentRenderer().render(document(mask: .torn), photos: byID, sourceFolder: folder, outputDirectory: tornDir)
    #expect(rectOutcome.failures.isEmpty && tornOutcome.failures.isEmpty)
    let (w, h, rectBytes) = try rgba(of: rectDir.appending(path: try #require(rectOutcome.names.first)))
    let (_, _, tornBytes) = try rgba(of: tornDir.appending(path: try #require(tornOutcome.names.first)))
    let W = CarouselAspect.square.exportWidth, H = CarouselAspect.square.exportHeight
    let box = topDownRect(frame, W: Double(W), H: Double(H))
    // The paper background "#F4F1EA" ≈ (244,241,234); count pixels that still match it inside the frame.
    func backgroundPixelCount(_ bytes: [UInt8]) -> Int {
        var count = 0
        for y in Int(box.minY)..<min(h, Int(box.maxY)) {
            for x in Int(box.minX)..<min(w, Int(box.maxX)) {
                let o = (y * w + x) * 4
                if abs(Int(bytes[o]) - 244) < 8 && abs(Int(bytes[o + 1]) - 241) < 8 && abs(Int(bytes[o + 2]) - 234) < 8 { count += 1 }
            }
        }
        return count
    }
    let rectBackground = backgroundPixelCount(rectBytes), tornBackground = backgroundPixelCount(tornBytes)
    #expect(rectBackground < 20, "an unmasked photo should fill essentially all of its frame; \(rectBackground) background pixels leaked through")
    #expect(tornBackground > rectBackground + 50, "a torn mask should clip visible slivers of the photo, revealing background: rect=\(rectBackground) torn=\(tornBackground)")
}

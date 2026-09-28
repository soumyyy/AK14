import Core
import Foundation
import ImageIO
import Render
import UniformTypeIdentifiers

/// The persisted document is the editor's source of truth. Preview and export requests are
/// serialized by `DocumentRenderQueue`; a failed preview leaves the last complete revision up.
@MainActor @Observable
final class EditorModel {
    let option: StoryOption
    let photos: [AssetID: PhotoRecord]
    private(set) var document: CanvasDocument
    private(set) var previewURLs: [URL] = []
    private(set) var revision = 0
    private(set) var isRendering = false
    private(set) var isExporting = false
    var visibleSlide = 0
    var selectedLayerID: String?
    var alert: String?
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    private var saveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let renderSessionID = UUID().uuidString
    private let recorder: InteractionRecorder
    private let renderQueue = DocumentRenderQueue()
    private let openedFromSavedDocument: Bool
    private let baselineDocument: CanvasDocument
    private var pendingPreviewSlides: Set<Int> = []

    init(option: StoryOption, records: [PhotoRecord]) throws {
        self.option = option
        photos = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, $0) })
        recorder = InteractionRecorder(runDirectory: option.runDirectory)
        let store = RunStore.open(option.runDirectory)
        let savedPath = "documents/\(option.id).json"
        let saved = try? store.read(CanvasDocument.self, from: savedPath)
        openedFromSavedDocument = saved != nil
        let layouts = (try? store.read([ResolvedSlide].self, from: "layouts/\(option.id)/slides.json"))
            ?? (0..<option.slides.count).compactMap { index in
                try? store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", option.id, index + 1))
            }
        guard saved != nil || (!layouts.isEmpty && layouts.count == option.slides.count) else {
            throw EditorFailure.missingDocument
        }
        let manifest = try? store.read(RunManifest.self, from: "manifest.json")
        let aspect = manifest?.aspectRatio ?? .infer(from: records)
        let runID = manifest?.runID ?? option.runDirectory.lastPathComponent
        let seed = ComposerEngine.layoutSeed(runID: runID, id: option.id)
        let carousel = ResolvedCarousel(id: option.id, aspect: aspect, seed: String(seed, radix: 16), resolverVersion: ResolvedCarousel.resolverVersion, slides: layouts)
        let reconstructedBaseline = CanvasDocument(from: carousel, photos: photos)
        baselineDocument = (try? store.read(CanvasDocument.self, from: "documents/originals/\(option.id).json")) ?? reconstructedBaseline
        if let saved {
            document = saved
        } else {
            document = baselineDocument
        }
        previewURLs = alignedPipelineSlides(for: document.slideCount)
        if openedFromSavedDocument {
            let differing = slidesNeedingRender(comparedTo: baselineDocument)
            if !differing.isEmpty {
                requestPreview(slides: differing, prioritySlide: visibleSlide)
            }
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selectedLayer: DocumentLayer? { document.layers.first { $0.id == selectedLayerID } }
    var hasSeamCrossingLayers: Bool {
        guard document.seamless, document.slideCount > 1 else { return false }
        return document.layers.contains { layer in
            (1..<document.slideCount).contains { seam in
                let x = Double(seam) / Double(document.slideCount)
                return layer.frame.x < x - 0.0001 && layer.frame.x + layer.frame.width > x + 0.0001
            }
        }
    }

    func selectLayer(at x: Double, y: Double, on slide: Int) -> String? {
        let count = Double(max(1, document.slideCount))
        return document.layers(onSlide: slide).reversed().first { layer in
            let localX = layer.frame.x * count - Double(slide)
            return x >= localX && x <= localX + layer.frame.width * count && y >= layer.frame.y && y <= layer.frame.y + layer.frame.height
        }?.id
    }

    func change(_ event: String, layerID: String? = nil, structural: Bool = false, _ edit: (inout CanvasDocument) -> Void) {
        guard !isExporting else { return }
        let old = document
        undoStack.append(old)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        edit(&document)
        let layer = document.layers.first { $0.id == layerID }
        recorder.record(event, conceptID: option.id, slideIndex: layer?.slideHint ?? visibleSlide,
                        assetIDs: layer?.assetID.map { [$0] }, before: [String(describing: old.layers.count)], after: [String(describing: document.layers.count)])
        revision += 1
        scheduleSave()
        let affected = affectedSlides(old: old, new: document, layerID: layerID, structural: structural)
        requestPreview(slides: affected, prioritySlide: visibleSlide)
    }

    func textLayer(on slide: Int) -> DocumentLayer? {
        document.layers(onSlide: slide).filter { $0.kind == .text }.max { $0.z < $1.z }
    }

    func replaceText(layerID: String, with string: String) {
        change("text_edited", layerID: layerID) { doc in
            guard let index = doc.layers.firstIndex(where: { $0.id == layerID }) else { return }
            doc.layers[index].string = string
        }
    }

    func addText(_ string: String) {
        let count = Double(max(1, document.slideCount))
        let layer = DocumentLayer(id: UUID().uuidString, kind: .text,
            frame: UnitRect(x: (Double(visibleSlide) + 0.12) / count, y: 0.38, width: 0.30 / count, height: 0.08),
            z: (document.layers.map(\.z).max() ?? 0) + 1, slideHint: visibleSlide, string: string,
            fontID: "font-fraunces", size: 56, colour: "#222222", alignment: "center")
        change("layer_added", layerID: layer.id) { $0.layers.append(layer) }
        selectedLayerID = layer.id
    }

    func deleteLayer(_ id: String) {
        change("layer_deleted", layerID: id) { $0.layers.removeAll { $0.id == id } }
        selectedLayerID = nil
    }

    func replacePhoto(layerID: String, with photo: PhotoRecord) {
        guard !document.seamless else { return }
        guard let layer = document.layers.first(where: { $0.id == layerID }), layer.kind == .photo else { return }
        let slideCount = Double(max(1, document.slideCount))
        let slotAspect = Double(document.aspect.exportWidth) / Double(document.aspect.exportHeight)
            * layer.frame.width * slideCount / max(layer.frame.height, 0.0001)
        let imageAspect = Double(photo.pixelWidth) / Double(max(1, photo.pixelHeight))
        let crop = CropPlanner.cover(imageAspect: imageAspect, boxAspect: slotAspect, features: nil)
        change("photo_replaced", layerID: layerID) { doc in
            guard let index = doc.layers.firstIndex(where: { $0.id == layerID }) else { return }
            doc.layers[index].assetID = photo.assetID
            doc.layers[index].crop = crop
        }
    }

    /// Drag values are normalized to one slide, then converted to document-space coordinates.
    func move(_ id: String, dx: Double, dy: Double) {
        change("layer_moved", layerID: id) { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }), !doc.layers[i].locked else { return }
            let f = doc.layers[i].frame
            if doc.seamless && self.layerCrossesSeam(doc.layers[i], slideCount: doc.slideCount) { return }
            let scale = Double(max(1, doc.slideCount))
            let deltaX = dx / scale
            let minX = doc.seamless ? -f.width + 0.02 : Double(doc.layers[i].slideHint ?? self.visibleSlide) / scale
            let maxX = doc.seamless ? 1 : (Double((doc.layers[i].slideHint ?? self.visibleSlide) + 1) / scale)
            doc.layers[i].frame = UnitRect(x: min(maxX - 0.02, max(minX, f.x + deltaX)), y: min(0.98 - f.height, max(0.02, f.y + dy)), width: f.width, height: f.height)
        }
    }

    func resize(_ id: String, scale: Double) {
        change("layer_resized", layerID: id) { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            if doc.seamless && self.layerCrossesSeam(doc.layers[i], slideCount: doc.slideCount) { return }
            let f = doc.layers[i].frame
            let s = min(2.0, max(0.5, scale))
            let count = Double(max(1, doc.slideCount))
            doc.layers[i].frame = UnitRect(x: f.x, y: f.y, width: min(0.9 / count, f.width * s), height: min(0.9, f.height * s))
        }
    }

    func rotate(_ id: String, degrees: Double = 5) {
        change("layer_rotated", layerID: id) { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            if doc.seamless && self.layerCrossesSeam(doc.layers[i], slideCount: doc.slideCount) { return }
            doc.layers[i].rotation += degrees
        }
    }

    func applyCrop(_ id: String, inset: Double) {
        change("photo_cropped", layerID: id) { doc in
            guard !doc.seamless, let i = doc.layers.firstIndex(where: { $0.id == id }), doc.layers[i].kind == .photo else { return }
            let crop = doc.layers[i].crop ?? UnitRect(x: 0, y: 0, width: 1, height: 1)
            let amount = min(0.15, max(0, inset))
            let width = max(0.65, crop.width - amount * 2), height = max(0.65, crop.height - amount * 2)
            doc.layers[i].crop = UnitRect(x: min(max(0, crop.x + amount), 1 - width),
                                          y: min(max(0, crop.y + amount), 1 - height), width: width, height: height)
        }
    }

    func adjust(_ id: String, _ adjustments: PhotoAdjustments) {
        guard document.layers.contains(where: { $0.id == id && $0.kind == .photo }) else { return }
        change("photo_adjusted", layerID: id) { doc in
            guard let index = doc.layers.firstIndex(where: { $0.id == id }), doc.layers[index].kind == .photo else { return }
            doc.layers[index].adjustments = adjustments
        }
    }

    func applyLookToAll(from id: String) {
        guard let source = document.layers.first(where: { $0.id == id && $0.kind == .photo }) else { return }
        let look = source.adjustments ?? PhotoAdjustments()
        change("look_applied_all", layerID: id, structural: true) { doc in
            for index in doc.layers.indices where doc.layers[index].kind == .photo {
                var next = doc.layers[index].adjustments ?? PhotoAdjustments()
                next.exposure = look.exposure
                next.contrast = look.contrast
                next.warmth = look.warmth
                next.saturation = look.saturation
                doc.layers[index].adjustments = next
            }
        }
    }

    var canEditSlidesSafely: Bool { !document.seamless && !hasSeamCrossingLayers }
    var selectedPhotoEditingSafe: Bool { selectedLayer?.kind == .photo && !document.seamless }

    private func layerCrossesSeam(_ layer: DocumentLayer, slideCount: Int) -> Bool {
        guard slideCount > 1 else { return false }
        return (1..<slideCount).contains { seam in
            let x = Double(seam) / Double(slideCount)
            return layer.frame.x < x - 0.0001 && layer.frame.x + layer.frame.width > x + 0.0001
        }
    }

    func moveSlide(from source: Int, to destination: Int) {
        guard canEditSlidesSafely, source != destination,
              (0..<document.slideCount).contains(source), (0..<document.slideCount).contains(destination) else { return }
        change("slide_reordered", structural: true) { doc in
            let count = Double(max(1, doc.slideCount))
            for index in doc.layers.indices {
                let old = doc.layers[index].slideHint ?? min(doc.slideCount - 1, max(0, Int(doc.layers[index].frame.x * count)))
                let next: Int
                if old == source { next = destination }
                else if source < destination && (source..<destination).contains(old) { next = old - 1 }
                else if destination < source && (destination...source).contains(old) { next = old + 1 }
                else { continue }
                let localX = doc.layers[index].frame.x * count - Double(old)
                let frame = doc.layers[index].frame
                doc.layers[index].slideHint = next
                doc.layers[index].frame = UnitRect(x: (Double(next) + localX) / count, y: frame.y, width: frame.width, height: frame.height)
            }
            func reorder<T>(_ values: inout [T]) {
                guard values.indices.contains(source) else { return }
                let item = values.remove(at: source)
                if values.indices.contains(destination) { values.insert(item, at: destination) }
            }
            reorder(&doc.slideBackgrounds); reorder(&doc.slideGrain); reorder(&doc.slideFilmEdges)
        }
    }

    func removeSlide(at index: Int) {
        guard canEditSlidesSafely, document.slideCount > 1, (0..<document.slideCount).contains(index) else { return }
        change("slide_removed", structural: true) { doc in
            let count = Double(doc.slideCount)
            var kept: [DocumentLayer] = []
            for original in doc.layers {
                var layer = original
                let old = min(doc.slideCount - 1, max(0, layer.slideHint ?? Int(layer.frame.x * count)))
                if old == index { continue }
                let next = old > index ? old - 1 : old
                let localX = layer.frame.x * count - Double(old)
                let frame = layer.frame
                layer.slideHint = next
                layer.frame = UnitRect(x: (Double(next) + localX) / (count - 1), y: frame.y,
                                       width: frame.width * count / (count - 1), height: frame.height)
                kept.append(layer)
            }
            doc.layers = kept
            if doc.slideBackgrounds.indices.contains(index) { doc.slideBackgrounds.remove(at: index) }
            if doc.slideGrain.indices.contains(index) { doc.slideGrain.remove(at: index) }
            if doc.slideFilmEdges.indices.contains(index) { doc.slideFilmEdges.remove(at: index) }
            doc.slideCount -= 1
        }
        visibleSlide = min(index, document.slideCount - 1)
        selectedLayerID = nil
        previewURLs = alignedPipelineSlides(for: document.slideCount)
    }

    func undo() {
        guard !isExporting, let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        let current = document
        document = previous
        revision += 1
        scheduleSave()
        requestPreview(slides: affectedSlides(old: current, new: document, layerID: nil, structural: true), prioritySlide: visibleSlide)
    }
    func redo() {
        guard !isExporting, let next = redoStack.popLast() else { return }
        undoStack.append(document)
        let current = document
        document = next
        revision += 1
        scheduleSave()
        requestPreview(slides: affectedSlides(old: current, new: document, layerID: nil, structural: true), prioritySlide: visibleSlide)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = document
        saveTask = Task { try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }; try? RunStore.open(option.runDirectory).write(snapshot, to: "documents/\(option.id).json") }
    }

    func flushSave() {
        saveTask?.cancel()
        try? RunStore.open(option.runDirectory).write(document, to: "documents/\(option.id).json")
    }

    private func alignedPipelineSlides(for slideCount: Int) -> [URL] {
        guard slideCount > 0, !option.slides.isEmpty else { return [] }
        if option.slides.count >= slideCount { return Array(option.slides.prefix(slideCount)) }
        var urls = option.slides
        while urls.count < slideCount {
            urls.append(option.slides.last ?? option.slides[0])
        }
        return urls
    }

    private func slidesNeedingRender(comparedTo baseline: CanvasDocument) -> Set<Int> {
        let count = max(document.slideCount, baseline.slideCount)
        var differing: Set<Int> = []
        for slide in 0..<count {
            if slideFingerprint(document, slide: slide) != slideFingerprint(baseline, slide: slide) {
                differing.insert(slide)
            }
        }
        return differing
    }

    private func slideFingerprint(_ doc: CanvasDocument, slide: Int) -> String {
        guard slide >= 0, slide < doc.slideCount else { return "" }
        let layers = doc.layers(onSlide: slide)
        let bg = doc.slideBackgrounds.indices.contains(slide) ? doc.slideBackgrounds[slide] : ""
        let grain = doc.slideGrain.indices.contains(slide) ? doc.slideGrain[slide] : 0
        let edge = doc.slideFilmEdges.indices.contains(slide) ? doc.slideFilmEdges[slide] : false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let layersData = (try? encoder.encode(layers)) ?? Data()
        let variant = doc.slideVariants.flatMap { values in
            values.indices.contains(slide) ? (values[slide] ?? "") : ""
        } ?? ""
        let context = [doc.aspect.rawValue, String(doc.slideCount), doc.seamless.description,
                       String(describing: doc.background), doc.recipeID ?? "", doc.templateID ?? "",
                       doc.sourcePlanID ?? "", doc.version, doc.seed,
                       variant, bg, String(grain), edge.description]
        return context.joined(separator: ";") + ";" + layersData.base64EncodedString()
    }

    private func slideIndex(for layer: DocumentLayer, in doc: CanvasDocument) -> Int {
        if let hint = layer.slideHint { return min(max(0, hint), max(0, doc.slideCount - 1)) }
        let count = Double(max(1, doc.slideCount))
        return min(doc.slideCount - 1, max(0, Int(layer.frame.x * count)))
    }

    private func affectedSlides(old: CanvasDocument, new: CanvasDocument, layerID: String?, structural: Bool) -> Set<Int> {
        if structural || new.seamless || old.seamless || old.slideCount != new.slideCount {
            return Set(0..<new.slideCount)
        }
        var slides = Set<Int>()
        if let layerID {
            if let layer = old.layers.first(where: { $0.id == layerID }) { slides.insert(slideIndex(for: layer, in: old)) }
            if let layer = new.layers.first(where: { $0.id == layerID }) { slides.insert(slideIndex(for: layer, in: new)) }
        }
        if slides.isEmpty { return Set(0..<new.slideCount) }
        return slides
    }

    private func requestPreview(slides: Set<Int>, prioritySlide: Int) {
        pendingPreviewSlides.formUnion(slides)
        previewTask?.cancel()
        let snapshot = document
        let token = revision
        pendingPreviewSlides = pendingPreviewSlides.filter { $0 >= 0 && $0 < snapshot.slideCount }
        let indices = orderedSlideIndices(pendingPreviewSlides, priority: prioritySlide, slideCount: snapshot.slideCount)
        guard !indices.isEmpty else { return }
        isRendering = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            // Give each document revision a distinct URL so the pager knows to replace the cached image.
            let folder = option.runDirectory.appending(path: "documents/previews/\(option.id)-\(renderSessionID)-r\(token)", directoryHint: .isDirectory)
            do {
                for slide in indices {
                    guard !Task.isCancelled, revision == token else { return }
                    let url = try await renderQueue.previewSlide(snapshot, slide: slide, photos: photos,
                                                                 sourceFolder: option.sourceFolder, folder: folder)
                    guard revision == token else { return }
                    if previewURLs.indices.contains(slide) {
                        previewURLs[slide] = url
                    } else {
                        previewURLs = alignedPipelineSlides(for: snapshot.slideCount)
                        if previewURLs.indices.contains(slide) { previewURLs[slide] = url }
                    }
                    pendingPreviewSlides.remove(slide)
                }
                guard revision == token else { return }
                isRendering = false
            } catch {
                guard revision == token else { return }
                isRendering = false
                alert = "Preview could not update: \(error.localizedDescription)"
            }
        }
    }

    private func orderedSlideIndices(_ slides: Set<Int>, priority: Int, slideCount: Int) -> [Int] {
        let valid = slides.filter { $0 >= 0 && $0 < slideCount }.sorted()
        guard let priorityIndex = valid.firstIndex(of: priority) else { return valid }
        var ordered = [valid[priorityIndex]]
        ordered.append(contentsOf: valid[..<priorityIndex])
        ordered.append(contentsOf: valid[(priorityIndex + 1)...])
        return ordered
    }

    func export() async throws -> [URL] { try await exportRevision().urls }

    func exportRevision() async throws -> (document: CanvasDocument, revision: Int, urls: [URL]) {
        guard !isExporting else { throw EditorFailure.exportInProgress }
        flushSave()
        let snapshot = document
        let snapshotRevision = revision
        isExporting = true
        defer { isExporting = false }
        let urls = try await renderQueue.export(snapshot, photos: photos, sourceFolder: option.sourceFolder,
                                                runDirectory: option.runDirectory, optionID: option.id, revision: snapshotRevision, sessionID: renderSessionID)
        guard document == snapshot, revision == snapshotRevision else { throw EditorFailure.revisionChanged }
        recorder.record("design_exported", conceptID: option.id, after: ["\(urls.count) slides", "revision=\(snapshotRevision)"])
        return (snapshot, snapshotRevision, urls)
    }

    /// Persist the exact revision handed to Photos or a share extension for parent bookkeeping.
    func handoffSnapshot(_ snapshot: CanvasDocument, revision: Int) throws -> String {
        let name = "\(option.id)-revision-\(revision)-\(UUID().uuidString).json"
        try RunStore.open(option.runDirectory).write(snapshot, to: "handoffs/\(name)")
        return name
    }
}

private enum EditorFailure: LocalizedError {
    case exportInProgress, revisionChanged, missingDocument, renderFailed(String)
    var errorDescription: String? {
        switch self {
        case .exportInProgress: "An export is already in progress."
        case .revisionChanged: "The design changed while it was being exported. Please share again."
        case .missingDocument: "The original slide layout is missing, so this option cannot be edited safely."
        case .renderFailed(let message): message
        }
    }
}

/// This actor owns the expensive raster and file work. Its synchronous actor methods run away
/// from the main actor and serialize preview/export revisions for a given editor.
private actor DocumentRenderQueue {
    private let renderer = DocumentRenderer()

    func previewSlide(_ document: CanvasDocument, slide: Int, photos: [AssetID: PhotoRecord],
                      sourceFolder: URL, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: String(format: "slide-%02d.png", slide + 1))
        try write(renderer.renderSlide(document, slide: slide, photos: photos, sourceFolder: sourceFolder), to: url)
        return url
    }

    func export(_ document: CanvasDocument, photos: [AssetID: PhotoRecord], sourceFolder: URL,
                runDirectory: URL, optionID: String, revision: Int, sessionID: String) throws -> [URL] {
        let folder = runDirectory.appending(path: "documents/export-\(optionID)-\(sessionID)-r\(revision)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for slide in 0..<document.slideCount {
            let url = folder.appending(path: String(format: "slide-%02d.png", slide + 1))
            try write(renderer.renderSlide(document, slide: slide, photos: photos, sourceFolder: sourceFolder), to: url)
            urls.append(url)
        }
        guard !urls.isEmpty else { throw EditorFailure.renderFailed("The design has no slides to preview.") }
        return urls
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EditorFailure.renderFailed("Could not create slide image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EditorFailure.renderFailed("Could not finish slide image.") }
    }
}

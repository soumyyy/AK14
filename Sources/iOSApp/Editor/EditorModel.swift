import Core
import Foundation
import Photos
import Render
import UIKit

@MainActor @Observable
final class EditorModel {
    let option: StoryOption
    let photos: [AssetID: PhotoRecord]
    private(set) var document: CanvasDocument
    var selectedLayerID: String?
    var visibleSlide = 0
    var alert: String?
    private var undoStack: [CanvasDocument] = []
    private var redoStack: [CanvasDocument] = []
    private var saveTask: Task<Void, Never>?
    private let recorder: InteractionRecorder

    init(option: StoryOption, records: [PhotoRecord]) throws {
        self.option = option
        photos = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, $0) })
        recorder = InteractionRecorder(runDirectory: option.runDirectory)
        let store = RunStore.open(option.runDirectory)
        if let saved = try? store.read(CanvasDocument.self, from: "documents/\(option.id).json") { document = saved }
        else {
            let layouts = (0..<option.slides.count).compactMap { index in
                try? store.read(ResolvedSlide.self, from: String(format: "layouts/%@/slide-%02d.json", option.id, index + 1))
            }
            let aspect = (try? store.read(CarouselAspect.self, from: "aspect.json")) ?? .portrait4x5
            let carousel = ResolvedCarousel(id: option.id, aspect: aspect, seed: "0", resolverVersion: ResolvedCarousel.resolverVersion, slides: layouts)
            document = CanvasDocument(from: carousel, photos: photos)
            if layouts.isEmpty { document.slideCount = max(1, option.slides.count) }
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selectedLayer: DocumentLayer? { document.layers.first { $0.id == selectedLayerID } }

    func change(_ event: String, layerID: String? = nil, _ edit: (inout CanvasDocument) -> Void) {
        undoStack.append(document); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack.removeAll()
        let old = document
        edit(&document)
        let layer = document.layers.first { $0.id == layerID }
        recorder.record(event, conceptID: option.id, slideIndex: layer?.slideHint ?? visibleSlide,
                        assetIDs: layer?.assetID.map { [$0] }, before: [String(describing: old.layers.count)], after: [String(describing: document.layers.count)])
        scheduleSave()
    }

    func move(_ id: String, dx: Double, dy: Double) {
        change("layer_moved", layerID: id) { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }), !doc.layers[i].locked else { return }
            let f = doc.layers[i].frame
            doc.layers[i].frame = UnitRect(x: f.x + dx, y: f.y + dy, width: f.width, height: f.height)
        }
    }
    func resize(_ id: String, scale: Double) {
        change("layer_resized", layerID: id) { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            let f = doc.layers[i].frame
            doc.layers[i].frame = UnitRect(x: f.x, y: f.y, width: f.width * scale, height: f.height * scale)
        }
    }
    func rotate(_ id: String, angle: Double) {
        change("layer_rotated", layerID: id) { doc in guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }; doc.layers[i].rotation += angle * 180 / .pi }
    }
    func addText(_ string: String) {
        let count = Double(document.slideCount)
        let layer = DocumentLayer(id: UUID().uuidString, kind: .text, frame: UnitRect(x: (Double(visibleSlide) + 0.12) / count, y: 0.38, width: 0.30 / count, height: 0.08), z: (document.layers.map(\.z).max() ?? 0) + 1, slideHint: visibleSlide, string: string, fontID: "font-fraunces", size: 56, colour: "#222222", alignment: "center")
        change("layer_added", layerID: layer.id) { $0.layers.append(layer) }; selectedLayerID = layer.id
    }
    func addSticker(_ id: String) {
        let count = Double(document.slideCount)
        let layer = DocumentLayer(id: UUID().uuidString, kind: .sticker, frame: UnitRect(x: (Double(visibleSlide) + 0.42) / count, y: 0.42, width: 0.13 / count, height: 0.13), z: (document.layers.map(\.z).max() ?? 0) + 1, slideHint: visibleSlide, assetID: AssetID(rawValue: id))
        change("layer_added", layerID: layer.id) { $0.layers.append(layer) }; selectedLayerID = layer.id
    }
    func deleteSelected() { guard let id = selectedLayerID else { return }; change("layer_deleted", layerID: id) { $0.layers.removeAll { $0.id == id } }; selectedLayerID = nil }
    func arrange(_ direction: String) {
        guard let id = selectedLayerID else { return }
        change("layer_moved", layerID: id) { doc in
            guard let i = doc.layers.firstIndex(where: { $0.id == id }) else { return }
            switch direction {
            case "forward": doc.layers[i].z += 1
            case "backward": doc.layers[i].z -= 1
            case "front": doc.layers[i].z = (doc.layers.map(\.z).max() ?? 0) + 1
            default: doc.layers[i].z = (doc.layers.map(\.z).min() ?? 0) - 1
            }
        }
    }
    func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(document); document = previous; scheduleSave() }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(document); document = next; scheduleSave() }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(350)); guard !Task.isCancelled else { return }; try? RunStore.open(option.runDirectory).write(document, to: "documents/\(option.id).json") }
    }
    func flushSave() { saveTask?.cancel(); try? RunStore.open(option.runDirectory).write(document, to: "documents/\(option.id).json") }

    func export() async throws -> [URL] {
        flushSave()
        let out = option.runDirectory.appending(path: "documents/export-\(option.id)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: out)
        let result = try DocumentRenderer().render(document, photos: photos, sourceFolder: option.sourceFolder, outputDirectory: out)
        guard result.failures.isEmpty, !result.names.isEmpty else { throw NSError(domain: "Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: result.failures.joined(separator: "; ")]) }
        recorder.record("design_exported", conceptID: option.id, after: ["\(result.names.count) slides"])
        return result.names.map { out.appending(path: $0) }
    }
    func saveToPhotos() async {
        do {
            let urls = try await export()
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { alert = "Allow AK14 to add photos in Settings."; return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({ urls.forEach { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: $0) } }) { ok, error in
                    if let error { continuation.resume(throwing: error) } else if ok { continuation.resume() } else { continuation.resume(throwing: NSError(domain: "Editor", code: 2)) }
                }
            }
            alert = "Saved to Photos"
        } catch { alert = "Could not save: \(error.localizedDescription)" }
    }
}

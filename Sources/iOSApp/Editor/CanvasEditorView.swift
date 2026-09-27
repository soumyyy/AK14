import Core
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// The option is edited on its own full-screen carousel. Paging remains a native UIScrollView;
/// every edit writes the document and replaces the preview only after a complete render succeeds.
struct CanvasEditorView: View {
    @State private var model: EditorModel
    @State private var page = 0
    @State private var newText = ""
    @State private var textDrafts: [String: String] = [:]
    @State private var transformPreview: TransformPreview?
    @State private var cropSession: CropSession?
    @State private var cropGestureStart: UnitRect?
    @State private var cropImage: UIImage?
    @State private var adjustDraft: AdjustDraft?
    @State private var adjustDragging = false
    @State private var adjustCommitTask: Task<Void, Never>?

    init(option: StoryOption, records: [PhotoRecord]) throws {
        _model = State(initialValue: try EditorModel(option: option, records: records))
    }

    init(model: EditorModel) { _model = State(initialValue: model) }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let aspect = CGFloat(model.document.aspect.exportWidth) / CGFloat(max(1, model.document.aspect.exportHeight))
                let pageWidth = geo.size.width
                let pageHeight = min(geo.size.height, pageWidth / aspect)
                ZStack(alignment: .bottom) {
                    SlidePager(urls: model.previewURLs, page: $page)
                        .frame(width: pageWidth, height: pageHeight)
                        .simultaneousGesture(SpatialTapGesture().onEnded { value in
                            guard cropSession == nil else { return }
                            let x = Double(value.location.x / max(1, pageWidth))
                            let y = Double(value.location.y / max(1, pageHeight))
                            model.selectedLayerID = model.selectLayer(at: x, y: y, on: page)
                        })
                        .overlay {
                            editorOverlay(size: CGSize(width: pageWidth, height: pageHeight))
                        }
                    if model.document.slideCount > 1 {
                        HStack(spacing: 5) {
                            ForEach(0..<model.document.slideCount, id: \.self) { index in
                                Capsule().fill(index == page ? AK14Palette.field : Color.white.opacity(0.4))
                                    .frame(width: index == page ? 18 : 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .padding(.bottom, 14).allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Slide \(page + 1) of \(model.document.slideCount)")
                    }
                    adjustmentPanel
                }
                .frame(width: pageWidth, height: pageHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 10) {
                if model.isRendering { ProgressView().controlSize(.small).accessibilityLabel("Updating preview") }
                Spacer()
                Text("Slide \(page + 1) of \(model.document.slideCount)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            elementControls
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
        }
        .background(Color.black)
        .onChange(of: page) { _, index in
            model.visibleSlide = index
            model.selectedLayerID = nil
            transformPreview = nil
            cropSession = nil
            adjustDraft = nil
            adjustDragging = false
        }
        .onChange(of: model.selectedLayerID) { _, id in
            if adjustDraft?.layerID != id {
                adjustDraft = nil
                adjustDragging = false
            }
        }
        .onChange(of: adjustmentSignature) { _, _ in
            guard !adjustDragging else { return }
            scheduleAdjustCommit()
        }
        .sensoryFeedback(.selection, trigger: page)
        .alert("Design", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .task(id: cropSession?.layerID) {
            guard let session = cropSession,
                  let layer = model.document.layers.first(where: { $0.id == session.layerID }),
                  let assetID = layer.assetID,
                  let record = model.photos[assetID],
                  let relativePath = record.sourceRelativePaths.first else {
                cropImage = nil
                return
            }
            let path = model.option.sourceFolder.appending(path: relativePath).path
            if let cgImage = await Task.detached(priority: .utility, operation: {
                EditorThumbnailLoader.load(path: path, maxPixel: 900)
            }).value {
                cropImage = UIImage(cgImage: cgImage)
            }
        }
        .onDisappear { model.flushSave() }
    }


    private func transformGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .simultaneously(with: MagnifyGesture())
            .simultaneously(with: RotationGesture())
            .onChanged { value in
                beginTransformIfNeeded()
                guard let start = transformPreview else { return }
                let translation = value.first?.first?.translation ?? .zero
                let magnification = value.first?.second?.magnification ?? 1
                let rotation = value.second?.radians ?? 0
                transformPreview = TransformPreview(
                    layerID: start.layerID,
                    baseFrame: start.baseFrame,
                    frame: transformedFrame(start, translation: translation, magnification: magnification, size: size),
                    rotation: start.baseRotation + rotation
                )
            }
            .onEnded { _ in commitTransform() }
    }

    private func cropGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .simultaneously(with: MagnifyGesture())
            .onChanged { value in
                guard let session = cropSession else { return }
                if cropGestureStart == nil { cropGestureStart = session.crop }
                guard let start = cropGestureStart else { return }
                let translation = value.first?.translation ?? .zero
                let magnification = value.second?.magnification ?? 1
                cropSession = CropSession(
                    layerID: session.layerID,
                    originalCrop: session.originalCrop,
                    crop: transformedCrop(start, translation: translation, magnification: magnification, frame: frame)
                )
            }
            .onEnded { _ in cropGestureStart = nil }
    }

    private func beginTransformIfNeeded() {
        guard transformPreview == nil, let layer = model.selectedLayer else { return }
        transformPreview = TransformPreview(layerID: layer.id, baseFrame: layer.frame, frame: layer.frame, rotation: layer.rotation)
    }

    /// Scales about the centre, then moves. The only limit is that the centre stays on its slide (or on the canvas
    /// when seamless), so full-bleed and bleeding layers keep their size and a gesture with no movement changes nothing.
    private func transformedFrame(_ start: TransformPreview, translation: CGSize, magnification: CGFloat, size: CGSize) -> UnitRect {
        let count = Double(max(1, model.document.slideCount))
        let base = start.baseFrame
        let scale = min(4, max(0.25, Double(magnification)))
        let width = base.width * scale, height = base.height * scale
        var centerX = base.x + base.width / 2 + Double(translation.width / max(1, size.width)) / count
        var centerY = base.y + base.height / 2 + Double(translation.height / max(1, size.height))
        let low = model.document.seamless ? 0 : Double(page) / count
        let high = model.document.seamless ? 1 : Double(page + 1) / count
        centerX = min(high, max(low, centerX))
        centerY = min(1, max(0, centerY))
        return UnitRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    private func transformedCrop(_ start: UnitRect, translation: CGSize, magnification: CGFloat, frame: CGRect) -> UnitRect {
        let scale = min(20, max(0.05, Double(magnification)))
        let width = min(1, max(0.05, start.width / scale))
        let height = min(1, max(0.05, start.height / scale))
        let x = min(1 - width, max(0, start.x + (start.width - width) / 2
            + Double(translation.width / max(1, frame.width))))
        let y = min(1 - height, max(0, start.y + (start.height - height) / 2
            + Double(translation.height / max(1, frame.height))))
        return UnitRect(x: x, y: y, width: width, height: height)
    }

    private func commitTransform() {
        guard let preview = transformPreview,
              let current = model.document.layers.first(where: { $0.id == preview.layerID }),
              !(model.document.seamless && crossesSeam(current.frame)),
              current.frame != preview.frame || abs(current.rotation - preview.rotation) > 0.0001 else {
            transformPreview = nil
            return
        }
        let nextFrame = preview.frame
        let nextRotation = preview.rotation
        model.change("layer_transformed", layerID: preview.layerID) { document in
            guard let index = document.layers.firstIndex(where: { $0.id == preview.layerID }),
                  !document.layers[index].locked else { return }
            document.layers[index].frame = nextFrame
            document.layers[index].rotation = nextRotation
        }
        transformPreview = nil
    }

    private func beginCrop(for layer: DocumentLayer) {
        guard layer.kind == .photo, !model.document.seamless else { return }
        adjustDraft = nil
        adjustDragging = false
        let crop = layer.crop ?? UnitRect(x: 0, y: 0, width: 1, height: 1)
        cropSession = CropSession(layerID: layer.id, originalCrop: crop, crop: crop)
        cropImage = nil
    }

    private func finishCrop() {
        guard let session = cropSession else { return }
        if session.crop != session.originalCrop {
            let crop = session.crop
            model.change("photo_cropped", layerID: session.layerID) { document in
                guard !document.seamless,
                      let index = document.layers.firstIndex(where: { $0.id == session.layerID }),
                      document.layers[index].kind == .photo else { return }
                document.layers[index].crop = crop
            }
        }
        cropSession = nil
        cropGestureStart = nil
        cropImage = nil
    }

    @ViewBuilder
    private func editorOverlay(size: CGSize) -> some View {
        if let layer = model.selectedLayer,
           let baseFrame = unitFrame(layer, page: page) {
            let documentFrame = transformPreview?.layerID == layer.id ? transformPreview!.frame : layer.frame
            let localFrame = localFrame(documentFrame, page: page)
            if let cropSession, cropSession.layerID == layer.id {
                cropOverlay(layer: layer, crop: cropSession.crop, frame: baseFrame, size: size)
            } else {
                let wash = liveWash(for: layer)
                transformOverlay(layer: layer, frame: localFrame, size: size, wash: wash)
                    .gesture(transformGesture(size: size))
                    .simultaneousGesture(TapGesture(count: 2).onEnded { beginCrop(for: layer) })
            }
        }
    }

    private func transformOverlay(layer: DocumentLayer, frame: CGRect, size: CGSize, wash: PhotoAdjustments?) -> some View {
        let previewing = transformPreview?.layerID == layer.id
        let rotation = transformPreview?.rotation ?? layer.rotation
        return ZStack {
            if let wash {
                AdjustmentWash(adjustments: wash)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(previewing ? AK14Palette.accent.opacity(0.13) : .clear)
            if previewing {
                Image(systemName: layer.kind == .photo ? "photo" : "textformat")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AK14Palette.accent.opacity(0.85))
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(AK14Palette.accent, style: StrokeStyle(lineWidth: 2, dash: previewing ? [7, 4] : []))
        }
        .frame(width: max(22, frame.width * size.width), height: max(22, frame.height * size.height))
        .rotationEffect(.degrees(rotation))
        .position(x: frame.midX * size.width, y: frame.midY * size.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layer.kind == .photo ? "Selected photo" : "Selected text")
        .accessibilityHint("Drag to move. Pinch to resize. Use a two-finger twist to rotate. Double-tap a photo to crop.")
        .accessibilityAction(named: "Move left") { model.move(layer.id, dx: -0.025, dy: 0) }
        .accessibilityAction(named: "Move right") { model.move(layer.id, dx: 0.025, dy: 0) }
        .accessibilityAction(named: "Move up") { model.move(layer.id, dx: 0, dy: -0.025) }
        .accessibilityAction(named: "Move down") { model.move(layer.id, dx: 0, dy: 0.025) }
        .accessibilityAction(named: "Resize smaller") { model.resize(layer.id, scale: 0.9) }
        .accessibilityAction(named: "Resize larger") { model.resize(layer.id, scale: 1.1) }
        .accessibilityAction(named: "Rotate") { model.rotate(layer.id) }
    }

    private func cropOverlay(layer: DocumentLayer, crop: UnitRect, frame: CGRect, size: CGSize) -> some View {
        CropPreview(image: cropImage, crop: crop)
            .frame(width: max(22, frame.width * size.width), height: max(22, frame.height * size.height))
            .rotationEffect(.degrees(layer.rotation))
            .position(x: frame.midX * size.width, y: frame.midY * size.height)
            .contentShape(Rectangle())
            .gesture(cropGesture(frame: frame))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Crop photo")
            .accessibilityHint("Drag to pan the crop and pinch to zoom. Activate Done when finished.")
    }

    @ViewBuilder
    private var elementControls: some View {
        if let layer = model.selectedLayer,
           layer.slideHint == nil || layer.slideHint == page || model.document.seamless {
            if cropSession?.layerID == layer.id {
                cropControls
            } else {
                selectedControls(for: layer)
            }
        } else {
            emptyControls
        }
    }

    private func selectedControls(for layer: DocumentLayer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(layer.kind == .photo ? "Photo" : "Text", systemImage: layer.kind == .photo ? "photo" : "textformat")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if layer.kind == .photo {
                    Button {
                        toggleAdjust(for: layer)
                    } label: {
                        Label("Adjust", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("adjustPhotoButton")
                }
            }
            if layer.kind == .text {
                HStack {
                    TextField("Edit text", text: Binding(get: { textDrafts[layer.id] ?? layer.string ?? "" }, set: { textDrafts[layer.id] = $0 }), axis: .vertical)
                        .lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityIdentifier("selectedTextField")
                    Button("Apply") {
                        model.replaceText(layerID: layer.id, with: textDrafts[layer.id] ?? layer.string ?? "")
                        textDrafts[layer.id] = nil
                    }.buttonStyle(.borderedProminent)
                }
            } else if layer.kind == .photo {
                photoStrip(for: layer)
            }
            secondaryControls(selectedLayerID: layer.id)
        }
        .padding(12).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("elementControls")
    }

    private var cropControls: some View {
        HStack {
            Label("Crop photo", systemImage: "crop")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Done") { finishCrop() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("elementControls")
    }

    private var emptyControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Add text to this slide", text: $newText)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("newSlideText")
                Button("Add text", systemImage: "plus") {
                    let value = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    model.addText(value)
                    newText = ""
                }
                .buttonStyle(.borderedProminent).disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add text")
            }
            secondaryControls()
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain).accessibilityIdentifier("emptyElementControls")
    }

    private func secondaryControls(selectedLayerID: String? = nil) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let selectedLayerID {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        model.deleteLayer(selectedLayerID)
                    }
                    .accessibilityLabel("Remove selected element")
                }
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                    .disabled(!model.canUndo || model.isExporting).accessibilityLabel("Undo edit")
                Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                    .disabled(!model.canRedo || model.isExporting).accessibilityLabel("Redo edit")
            }
            .buttonStyle(.bordered).controlSize(.small)
            if model.canEditSlidesSafely {
                HStack(spacing: 8) {
                    Button("Move slide left", systemImage: "chevron.left") {
                        let destination = max(0, page - 1)
                        model.moveSlide(from: page, to: destination)
                        page = destination
                    }
                    .disabled(page == 0)
                    Button("Move slide right", systemImage: "chevron.right") {
                        let destination = min(model.document.slideCount - 1, page + 1)
                        model.moveSlide(from: page, to: destination)
                        page = destination
                    }
                    .disabled(page == model.document.slideCount - 1)
                    Button("Remove slide", systemImage: "xmark", role: .destructive) {
                        model.removeSlide(at: page)
                        page = model.visibleSlide
                    }
                    .disabled(model.document.slideCount <= 1)
                }
                .font(.caption).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var adjustmentPanel: some View {
        if let draft = adjustDraft, cropSession == nil, model.selectedLayer?.id == draft.layerID {
            PhotoAdjustPanel(
                exposure: adjustBinding(\.exposure),
                contrast: adjustBinding(\.contrast),
                warmth: adjustBinding(\.warmth),
                saturation: adjustBinding(\.saturation),
                onEditingChanged: sliderEditing(_:),
                onReset: resetAdjustments,
                onApplyAll: applyLookFromDraft
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var adjustmentSignature: String {
        guard let draft = adjustDraft else { return "" }
        return "\(draft.layerID)|\(draft.exposure)|\(draft.contrast)|\(draft.warmth)|\(draft.saturation)"
    }

    private func adjustBinding(_ keyPath: WritableKeyPath<AdjustDraft, Double>) -> Binding<Double> {
        Binding {
            adjustDraft?[keyPath: keyPath] ?? 0
        } set: { newValue in
            guard var draft = adjustDraft else { return }
            draft[keyPath: keyPath] = newValue
            adjustDraft = draft
        }
    }

    private func toggleAdjust(for layer: DocumentLayer) {
        if adjustDraft?.layerID == layer.id {
            adjustDraft = nil
            adjustDragging = false
            return
        }
        let current = layer.adjustments ?? PhotoAdjustments()
        adjustDragging = false
        adjustDraft = AdjustDraft(
            layerID: layer.id,
            exposure: current.exposure,
            contrast: current.contrast,
            warmth: current.warmth,
            saturation: current.saturation,
            grain: current.grain,
            filmLook: current.filmLook
        )
    }

    private func sliderEditing(_ editing: Bool) {
        adjustDragging = editing
        adjustCommitTask?.cancel()
        adjustCommitTask = nil
        if !editing { commitAdjustmentsIfIdle() }
    }

    private func scheduleAdjustCommit() {
        adjustCommitTask?.cancel()
        adjustCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, !adjustDragging else { return }
            commitAdjustmentsIfIdle()
        }
    }

    private func resetAdjustments() {
        guard var draft = adjustDraft else { return }
        adjustDragging = false
        draft.exposure = 0
        draft.contrast = 0
        draft.warmth = 0
        draft.saturation = 0
        adjustDraft = draft
        commitAdjustmentsIfIdle()
    }

    private func applyLookFromDraft() {
        guard let draft = adjustDraft, !adjustDragging else { return }
        commitAdjustmentsIfIdle()
        model.applyLookToAll(from: draft.layerID)
    }

    private func liveWash(for layer: DocumentLayer) -> PhotoAdjustments? {
        guard adjustDragging, let draft = adjustDraft, draft.layerID == layer.id else { return nil }
        return adjustments(from: draft)
    }

    private func adjustments(from draft: AdjustDraft) -> PhotoAdjustments {
        PhotoAdjustments(
            exposure: draft.exposure,
            contrast: draft.contrast,
            warmth: draft.warmth,
            saturation: draft.saturation,
            grain: draft.grain,
            filmLook: draft.filmLook
        )
    }

    private func commitAdjustmentsIfIdle() {
        guard let draft = adjustDraft, !adjustDragging else { return }
        guard let layer = model.document.layers.first(where: { $0.id == draft.layerID }), layer.kind == .photo else { return }
        let next = adjustments(from: draft)
        let current = layer.adjustments ?? PhotoAdjustments()
        guard current != next else { return }
        model.adjust(draft.layerID, next)
    }

    private func photoStrip(for layer: DocumentLayer) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(photoRecords, id: \.assetID) { photo in
                    let selected = photo.assetID == layer.assetID
                    Button {
                        model.replacePhoto(layerID: layer.id, with: photo)
                    } label: {
                        PhotoThumbnail(
                            sourceURL: model.option.sourceFolder.appending(path: photo.sourceRelativePaths[0]),
                            selected: selected
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.document.seamless || model.isExporting)
                    .accessibilityLabel("Replace photo with \(photo.sourceRelativePaths.first ?? photo.assetID.rawValue)")
                    .accessibilityValue(selected ? "Current photo" : "")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 60)
    }

    private var photoRecords: [PhotoRecord] {
        model.photos.values.sorted { ($0.sourceRelativePaths.first ?? "") < ($1.sourceRelativePaths.first ?? "") }
    }

    private func crossesSeam(_ frame: UnitRect) -> Bool {
        guard model.document.slideCount > 1 else { return false }
        return (1..<model.document.slideCount).contains { seam in
            let boundary = Double(seam) / Double(model.document.slideCount)
            return frame.x < boundary - 0.0001 && frame.x + frame.width > boundary + 0.0001
        }
    }

    private func unitFrame(_ layer: DocumentLayer, page: Int) -> CGRect? {
        let frame = localFrame(layer.frame, page: page)
        guard frame.maxX > 0, frame.minX < 1 else { return nil }
        return frame
    }

    private func localFrame(_ frame: UnitRect, page: Int) -> CGRect {
        let scale = Double(max(1, model.document.slideCount))
        return CGRect(x: frame.x * scale - Double(page), y: frame.y,
                      width: frame.width * scale, height: frame.height)
    }

}

private struct AdjustDraft {
    var layerID: String
    var exposure: Double
    var contrast: Double
    var warmth: Double
    var saturation: Double
    var grain: Double
    var filmLook: Double
}

private struct PhotoAdjustPanel: View {
    @Binding var exposure: Double
    @Binding var contrast: Double
    @Binding var warmth: Double
    @Binding var saturation: Double
    var onEditingChanged: (Bool) -> Void
    var onReset: () -> Void
    var onApplyAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LookSlider(title: "Brightness", value: $exposure, range: -1...1, span: 1, onEditingChanged: onEditingChanged)
            LookSlider(title: "Contrast", value: $contrast, range: -0.5...0.5, span: 0.5, onEditingChanged: onEditingChanged)
            LookSlider(title: "Warmth", value: $warmth, range: -0.5...0.5, span: 0.5, onEditingChanged: onEditingChanged)
            LookSlider(title: "Saturation", value: $saturation, range: -0.6...0.6, span: 0.6, onEditingChanged: onEditingChanged)
            HStack(spacing: 8) {
                Button("Reset", action: onReset)
                Button("Apply look to all photos", action: onApplyAll)
                    .lineLimit(1)
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(10)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct LookSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let span: Double
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 78, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(spoken)
            Text(signed)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var spoken: String {
        let percent = Int((value / span * 100).rounded())
        return "\(percent) percent"
    }

    private var signed: String {
        if abs(value) < 0.005 { return "0" }
        return String(format: "%+.2f", value)
    }
}

private struct AdjustmentWash: View {
    let adjustments: PhotoAdjustments

    var body: some View {
        ZStack {
            Color.white.opacity(max(0, adjustments.exposure) * 0.35)
            Color.black.opacity(max(0, -adjustments.exposure) * 0.4)
            Color.white.opacity(max(0, adjustments.contrast) * 0.16)
            Color.black.opacity(max(0, -adjustments.contrast) * 0.2)
            Color.orange.opacity(max(0, adjustments.warmth) * 0.55)
            Color(red: 0.45, green: 0.75, blue: 1).opacity(max(0, -adjustments.warmth) * 0.5)
            Color.gray.opacity(max(0, -adjustments.saturation) * 0.55)
        }
    }
}

private struct TransformPreview {
    let layerID: String
    let baseFrame: UnitRect
    var frame: UnitRect
    var rotation: Double
    var baseRotation: Double

    init(layerID: String, baseFrame: UnitRect, frame: UnitRect, rotation: Double) {
        self.layerID = layerID
        self.baseFrame = baseFrame
        self.frame = frame
        self.rotation = rotation
        baseRotation = rotation
    }
}

private struct CropSession {
    let layerID: String
    let originalCrop: UnitRect
    var crop: UnitRect
}

private struct CropPreview: View {
    let image: UIImage?
    let crop: UnitRect

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: geometry.size.width / CGFloat(max(0.05, crop.width)),
                               height: geometry.size.height / CGFloat(max(0.05, crop.height)))
                        .position(x: geometry.size.width * CGFloat(0.5 - crop.x) / CGFloat(max(0.05, crop.width)),
                                  y: geometry.size.height * CGFloat(0.5 - crop.y) / CGFloat(max(0.05, crop.height)))
                } else {
                    Color.white.opacity(0.08)
                }
                Color.black.opacity(0.12)
                CropGrid()
            }
            .clipped()
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AK14Palette.accent, lineWidth: 2))
    }
}

private struct CropGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                path.move(to: CGPoint(x: width / 3, y: 0))
                path.addLine(to: CGPoint(x: width / 3, y: height))
                path.move(to: CGPoint(x: width * 2 / 3, y: 0))
                path.addLine(to: CGPoint(x: width * 2 / 3, y: height))
                path.move(to: CGPoint(x: 0, y: height / 3))
                path.addLine(to: CGPoint(x: width, y: height / 3))
                path.move(to: CGPoint(x: 0, y: height * 2 / 3))
                path.addLine(to: CGPoint(x: width, y: height * 2 / 3))
            }
            .stroke(.white.opacity(0.7), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct PhotoThumbnail: View {
    let sourceURL: URL
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.white.opacity(0.08)).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, AK14Palette.accent)
                    .padding(3)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(selected ? AK14Palette.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
        .task(id: sourceURL.path) {
            let path = sourceURL.path
            if let cgImage = await Task.detached(priority: .utility, operation: {
                EditorThumbnailLoader.load(path: path, maxPixel: 180)
            }).value {
                image = UIImage(cgImage: cgImage)
            }
        }
    }
}

private enum EditorThumbnailLoader {
    nonisolated static func load(path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return image
            }
        }
        return UIImage(contentsOfFile: path)?.cgImage
    }
}

private struct SlidePager: UIViewRepresentable {
    var urls: [URL]
    @Binding var page: Int
    func makeCoordinator() -> Coordinator { Coordinator(page: $page) }
    func makeUIView(context: Context) -> PagerStrip {
        let strip = PagerStrip()
        strip.onPage = { index in if context.coordinator.page.wrappedValue != index { context.coordinator.page.wrappedValue = index } }
        strip.setURLs(urls)
        return strip
    }
    func updateUIView(_ strip: PagerStrip, context: Context) {
        context.coordinator.page = $page
        strip.setURLs(urls)
        strip.showPage(page)
    }
    final class Coordinator { var page: Binding<Int>; init(page: Binding<Int>) { self.page = page } }
}

private final class PagerStrip: UIScrollView, UIScrollViewDelegate {
    var onPage: (Int) -> Void = { _ in }
    private var urls: [URL] = []
    private var tiles: [UIImageView] = []
    private var laidOutWidth: CGFloat = 0
    private var currentPage = 0
    override init(frame: CGRect) {
        super.init(frame: frame); isPagingEnabled = true; bounces = true; alwaysBounceHorizontal = true
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never; backgroundColor = .black; clipsToBounds = true
        delegate = self; delaysContentTouches = false
    }
    required init?(coder: NSCoder) { nil }
    func setURLs(_ urls: [URL]) {
        guard urls != self.urls else { return }
        self.urls = urls
        tiles.forEach { $0.removeFromSuperview() }
        tiles = urls.map { _ in
            let view = UIImageView(); view.contentMode = .scaleAspectFill; view.clipsToBounds = true
            view.backgroundColor = .black; view.isAccessibilityElement = true; addSubview(view); return view
        }
        currentPage = min(currentPage, max(0, urls.count - 1)); laidOutWidth = 0
        let paths = urls.map(\.path)
        Task.detached(priority: .userInitiated) {
            let images = paths.map { UIImage(contentsOfFile: $0) }
            await MainActor.run { [weak self] in
                guard let self, self.urls.map(\.path) == paths else { return }
                for (tile, image) in zip(self.tiles, images) { tile.image = image }
            }
        }
        setNeedsLayout()
    }
    func showPage(_ page: Int) {
        currentPage = min(max(page, 0), max(0, tiles.count - 1))
        if bounds.width > 1 { contentOffset = CGPoint(x: CGFloat(currentPage) * bounds.width, y: 0) }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); let width = bounds.width; let height = bounds.height
        guard width > 1, height > 1, !tiles.isEmpty else { return }
        let widthChanged = abs(width - laidOutWidth) > 0.5
        for (index, tile) in tiles.enumerated() {
            tile.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
            tile.accessibilityLabel = "Slide \(index + 1) of \(tiles.count)"
        }
        contentSize = CGSize(width: width * CGFloat(tiles.count), height: height)
        if widthChanged { laidOutWidth = width; if !isDragging && !isDecelerating { contentOffset = CGPoint(x: CGFloat(currentPage) * width, y: 0) } }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 1, !tiles.isEmpty else { return }
        let index = min(max(0, Int((scrollView.contentOffset.x / width).rounded())), tiles.count - 1)
        guard index != currentPage else { return }
        currentPage = index; onPage(index)
    }
}

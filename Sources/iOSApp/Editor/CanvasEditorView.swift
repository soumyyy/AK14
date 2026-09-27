import Core
import Render
import SwiftUI
import UIKit

struct CanvasEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: EditorModel
    @State private var showStickers = false
    @State private var showText = false
    @State private var text = ""
    @State private var exportBusy = false
    @State private var shareItems: [URL] = []
    @State private var sharePresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(option: StoryOption, records: [PhotoRecord]) throws { _model = State(initialValue: try EditorModel(option: option, records: records)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                canvasArea
                toolbar
            }
            .navigationTitle("Edit design").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { model.flushSave(); dismiss() } } }
            .sheet(isPresented: $showStickers) { StickerBrowser { model.addSticker($0); showStickers = false } }
            .alert("Add text", isPresented: $showText) {
                TextField("Text", text: $text)
                Button("Add") { model.addText(text); text = "" }
                Button("Cancel", role: .cancel) { }
            }
            .alert("", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                Button("OK", role: .cancel) { model.alert = nil }
            } message: { Text(model.alert ?? "") }
            .sheet(isPresented: $sharePresented) { ActivityShareSheet(items: shareItems) { _, _ in } }
        }
    }

    private var header: some View {
        HStack {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }.disabled(!model.canRedo)
            Spacer()
            Text("Slide \(model.visibleSlide + 1) of \(model.document.slideCount)").font(.subheadline)
        }.padding(.horizontal).padding(.vertical, 10)
    }

    private var canvasArea: some View {
        GeometryReader { (geo: GeometryProxy) -> AnyView in
            let slideW: CGFloat = geo.size.height * CGFloat(self.model.document.aspect.exportWidth) / CGFloat(self.model.document.aspect.exportHeight)
            let content = ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(0..<self.model.document.slideCount, id: \.self) { (index: Int) in
                        self.slideCell(index: index, slideWidth: slideW, height: geo.size.height)
                    }
                }
            }.scrollIndicators(.hidden)
            return AnyView(content)
        }.padding(.vertical, 10)
    }

    private func slideCell(index: Int, slideWidth: CGFloat, height: CGFloat) -> some View {
        let totalWidth = slideWidth * CGFloat(model.document.slideCount)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(hex: backgroundColour(index)))
            slideLayers(index: index, totalWidth: totalWidth, height: height)
            Rectangle().stroke(Color.primary.opacity(0.35), lineWidth: 1).allowsHitTesting(false)
            Text("\(index + 1)").font(.caption).padding(5).background(.regularMaterial, in: Capsule()).padding(7).accessibilityHidden(true)
        }
        .frame(width: slideWidth, height: height)
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.9)).frame(width: 2) }
        .contentShape(Rectangle()).onTapGesture { model.visibleSlide = index }
    }

    private func slideLayers(index: Int, totalWidth: CGFloat, height: CGFloat) -> some View {
        ForEach(model.document.layers(onSlide: index), id: \.id) { (layer: DocumentLayer) in
            layerView(layer, slide: index, width: totalWidth, height: height)
        }
    }

    private func layerView(_ layer: DocumentLayer, slide: Int, width: CGFloat, height: CGFloat) -> some View {
        let slideWidth = width / CGFloat(model.document.slideCount)
        let fullX = (CGFloat(layer.frame.x) * CGFloat(model.document.slideCount) - CGFloat(slide)) * slideWidth
        let w = CGFloat(layer.frame.width) * width
        let h = CGFloat(layer.frame.height) * height
        return Group {
            if layer.kind == .photo, let id = layer.assetID, let record = model.photos[id], let path = record.sourceRelativePaths.first,
               let image = UIImage(contentsOfFile: model.option.sourceFolder.appending(path: path).path) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: w, height: h).clipped().clipShape(RoundedRectangle(cornerRadius: layer.mask == .rounded ? 12 : 0))
            } else if layer.kind == .sticker, let id = layer.assetID, let asset = KitAssetRegistry.asset(id: id.rawValue) {
                Image(uiImage: stickerImage(asset, size: CGSize(width: max(32,w), height: max(32,h)))).resizable().scaledToFit().frame(width: w,height: h)
            } else if layer.kind == .text {
                Text(layer.string ?? "Text").font(.system(size: CGFloat(layer.size ?? 32), weight: .medium, design: layer.fontID?.contains("fraunces") == true ? .serif : .default)).foregroundStyle(Color(hex: layer.colour ?? "#222222")).multilineTextAlignment(.center).minimumScaleFactor(0.25)
            } else { Color.clear }
        }
        .frame(width: w, height: h)
        .overlay { if model.selectedLayerID == layer.id { Rectangle().stroke(Color.accentColor, lineWidth: 2).overlay(alignment: .topLeading) { Circle().fill(.white).frame(width: 12,height: 12).overlay(Circle().stroke(Color.accentColor)).offset(x: -6,y: -6) }.overlay(alignment: .bottomTrailing) { Circle().fill(.white).frame(width: 12,height: 12).overlay(Circle().stroke(Color.accentColor)).offset(x: 6,y: 6) } } }
        .rotationEffect(.degrees(layer.rotation))
        .position(x: fullX + w / 2, y: CGFloat(layer.frame.y) * height + h / 2)
        .accessibilityElement().accessibilityLabel(layer.kind == .photo ? "Photo layer \((layer.slideHint ?? 0) + 1)" : layer.kind == .text ? "Text: \(layer.string ?? "")" : "Sticker layer")
        .onTapGesture { model.selectedLayerID = layer.id }
        .gesture(DragGesture(minimumDistance: 4).onChanged { _ in model.selectedLayerID = layer.id }.onEnded { value in
            guard !layer.locked else { return }
            let dx = Double(value.translation.width / width), dy = Double(value.translation.height / height)
            if abs(dx) + abs(dy) > 0.002 { model.move(layer.id, dx: dx, dy: dy); if !reduceMotion { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
        })
        .simultaneousGesture(MagnificationGesture().onEnded { scale in if scale != 1 { model.resize(layer.id, scale: Double(scale)) } })
        .simultaneousGesture(RotationGesture().onEnded { angle in if angle != .zero { model.rotate(layer.id, angle: angle.radians) } })
        .onTapGesture(count: 2) { if layer.kind == .photo { model.selectedLayerID = layer.id } }
    }

    private var toolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Button("Text", systemImage: "textformat") { showText = true }
                Button("Stickers", systemImage: "face.smiling") { showStickers = true }
                Button("Background", systemImage: "paintpalette") { model.change("background_changed") { $0.background = .colour("#F4F1EA") } }
                if let layer = model.selectedLayer {
                    if layer.kind == .photo {
                        Button("Replace", systemImage: "arrow.triangle.2.circlepath") { replacePhoto(layer) }
                        Button("Crop", systemImage: "crop") { model.selectedLayerID = layer.id }
                        Button("Adjust", systemImage: "slider.horizontal.3") { model.change("photo_adjusted", layerID: layer.id) { doc in if let i = doc.layers.firstIndex(where: {$0.id == layer.id}) { var a = doc.layers[i].adjustments ?? PhotoAdjustments(); a.exposure += 0.1; doc.layers[i].adjustments = a } } }
                        Menu("Mask") { ForEach([Mask.rect,.rounded,.torn],id:\.self) { mask in Button(mask.rawValue.capitalized) { model.change("layer_resized",layerID:layer.id) { doc in if let i=doc.layers.firstIndex(where:{$0.id == layer.id}) { doc.layers[i].mask=mask } } } } }
                        Button("Border") { model.change("layer_resized",layerID:layer.id) { doc in if let i=doc.layers.firstIndex(where:{$0.id == layer.id}) { doc.layers[i].border = doc.layers[i].border == 0 ? 0.01 : 0 } } }
                    }
                    Button("Forward") { model.change("layer_moved",layerID:layer.id) { doc in if let i=doc.layers.firstIndex(where:{$0.id == layer.id}) { doc.layers[i].z += 1 } } }
                    Button("Lock") { model.change("layer_moved",layerID:layer.id) { doc in if let i=doc.layers.firstIndex(where:{$0.id == layer.id}) { doc.layers[i].locked.toggle() } } }
                    Button("Delete",systemImage:"trash",role:.destructive) { model.deleteSelected() }
                }
                Button("Save to Photos",systemImage:"square.and.arrow.down") { Task { await model.saveToPhotos() } }.disabled(exportBusy)
                Button("Share",systemImage:"square.and.arrow.up") { Task { if let urls = try? await model.export() { shareItems = urls; sharePresented = true } } }
            }.font(.body).buttonStyle(.bordered).padding(12)
        }.scrollIndicators(.hidden).background(.regularMaterial)
    }

    private func replacePhoto(_ layer: DocumentLayer) {
        guard let replacement = model.photos.values.first(where: { $0.assetID != layer.assetID }) else { return }
        model.change("photo_replaced", layerID: layer.id) { doc in if let i=doc.layers.firstIndex(where:{$0.id == layer.id}) { doc.layers[i].assetID = replacement.assetID } }
    }
    private func backgroundColour(_ slide: Int) -> String {
        if slide < model.document.slideBackgrounds.count, model.document.slideBackgrounds[slide] == "paper" { return "#F1EBDD" }
        if case .colour(let value) = model.document.background { return value }
        return "#F4F1EA"
    }
    private func stickerImage(_ asset: KitAsset, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { renderer in
            asset.draw(in: renderer.cgContext, rect: CGRect(origin: .zero, size: size), seed: 0)
        }
    }
}

private struct StickerBrowser: View {
    let choose: (String) -> Void
    @State private var category: KitCategory = .doodle
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Category", selection: $category) { ForEach(KitCategory.allCases,id:\.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.menu)
                List(KitAssetRegistry.all.filter { $0.category == category }) { asset in Button(asset.id) { choose(asset.id) }.accessibilityLabel(asset.id) }
            }.navigationTitle("Stickers").navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255, opacity: 1)
    }
}

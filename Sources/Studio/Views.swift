import AppKit
import Core
import Session
import SwiftUI

struct RunPickerView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        List(model.runs, selection: Binding(get: { model.session.map { $0.root } }, set: { url in
            if let run = model.runs.first(where: { $0.url == url }) { model.open(run) }
        })) { run in
            VStack(alignment: .leading, spacing: 2) {
                Text(run.label).font(.headline)
                Text(run.created.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                Text("\(run.photos) photos · \(run.status)").font(.caption).foregroundStyle(.secondary)
            }
            .tag(run.url)
        }
        .navigationTitle("Runs")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshRuns() }
            Button("Runs folder…", systemImage: "folder") { model.chooseRunsDirectory() }
        }
    }
}

struct ConceptBoardView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        if let s = model.session {
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(ConceptType.allCases, id: \.self) { c in ConceptColumn(session: s, concept: c) }
                    }.padding()
                }
                if let sel = model.selection { Divider(); SlideInspector(session: s, ref: sel).frame(width: 340) }
            }
            .navigationTitle(s.manifest.sourceFolderLabel)
            .toolbar {
                Button("Source folder…", systemImage: "photo.on.rectangle") { model.chooseSource() }
            }
        }
    }
}

struct ConceptColumn: View {
    @Environment(StudioModel.self) private var model
    let session: RunSession
    let concept: ConceptType

    var title: String {
        switch concept { case .plainDump: "Plain Dump"; case .designed: "Designed"; case .wildcard: "Wildcard" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.bold())
                if session.isEdited(concept) { Text("edited").font(.caption).padding(.horizontal, 6).background(.yellow.opacity(0.3), in: Capsule()) }
            }
            if let plan = session.plan(concept) {
                Text(plan.conceptNote).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(width: 260, alignment: .leading)
                HStack {
                    Button("Use this") { model.perform("Saving…") { try $0.select(concept) } }
                    Button("Reroll layout") { model.perform { try $0.reroll(concept) } }
                    Button("Export…") { model.export(concept) }
                    ShareButton(urls: session.slideURLs(concept)) { service in
                        model.perform("Saving…") { try $0.shared(concept, service: service) }
                    }.frame(width: 28, height: 22)
                }.controlSize(.small)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(session.slideURLs(concept).enumerated()), id: \.offset) { i, url in
                            let selected = model.selection == SlideRef(concept: concept, index: i)
                            SlideImage(url: url, revision: model.revision)
                                .frame(width: 260)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
                                .overlay(alignment: .topLeading) {
                                    Text("\(i + 1)").font(.caption.bold()).padding(4).background(.thinMaterial, in: Circle()).padding(6)
                                }
                                .onTapGesture { model.selection = SlideRef(concept: concept, index: i) }
                        }
                    }
                }
            } else {
                Text(session.concepts.unavailable[concept.rawValue] ?? "Not available in this run")
                    .font(.callout).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
            }
        }
        .frame(width: 280)
    }
}

struct SlideImage: View {
    let url: URL
    let revision: Int
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().id("\(url.path)#\(revision)")
        } else {
            Rectangle().fill(.quaternary).aspectRatio(0.75, contentMode: .fit)
        }
    }
}

/// Only the spec's edits: move, swap, remove. No free positioning, resizing or typography.
struct SlideInspector: View {
    @Environment(StudioModel.self) private var model
    let session: RunSession
    let ref: SlideRef
    @State private var swapping: AssetID?

    var body: some View {
        let plan = session.plan(ref.concept)
        let slides = session.slideURLs(ref.concept)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let plan, plan.slides.indices.contains(ref.index) {
                    let slide = plan.slides[ref.index]
                    Text("Slide \(ref.index + 1) of \(plan.slides.count)").font(.headline)
                    Text("\(slide.primitive.rawValue) · \(slide.density) · \(slide.mood)").font(.caption).foregroundStyle(.secondary)
                    if slides.indices.contains(ref.index) { SlideImage(url: slides[ref.index], revision: model.revision) }
                    HStack {
                        Button("Move earlier", systemImage: "arrow.up") { move(-1, count: plan.slides.count) }.disabled(ref.index == 0)
                        Button("Move later", systemImage: "arrow.down") { move(1, count: plan.slides.count) }.disabled(ref.index == plan.slides.count - 1)
                    }.controlSize(.small)
                    Divider()
                    Text("Photos").font(.subheadline.bold())
                    ForEach(slide.photos, id: \.assetID) { p in
                        HStack(alignment: .top) {
                            AsyncThumb(url: session.thumbnailURL(p.assetID)).frame(width: 96, height: 96)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(p.role).font(.caption)
                                Button("Swap…") { swapping = p.assetID }
                                    .popover(isPresented: Binding(get: { swapping == p.assetID }, set: { if !$0 { swapping = nil } })) {
                                        SwapPicker(session: session, concept: ref.concept, photo: p.assetID) { new in
                                            swapping = nil
                                            let i = ref.index, c = ref.concept, old = p.assetID
                                            model.perform { try $0.apply(.swap(slide: i, photo: old, with: new), to: c) }
                                        }
                                    }
                                Button("Remove", role: .destructive) {
                                    let i = ref.index, c = ref.concept, id = p.assetID
                                    let dropsSlide = slide.photos.count == 1
                                    model.perform { try $0.apply(.remove(slide: i, photo: id), to: c) }
                                    if dropsSlide { model.selection = nil }
                                }
                            }.controlSize(.small)
                        }
                    }
                } else {
                    Text("Select a slide").foregroundStyle(.secondary)
                }
            }.padding()
        }
    }

    func move(_ delta: Int, count: Int) {
        let from = ref.index, to = ref.index + delta, c = ref.concept
        model.perform { try $0.apply(.reorder(from: from, to: to), to: c) }
        model.selection = SlideRef(concept: c, index: to)
    }
}

struct SwapPicker: View {
    let session: RunSession
    let concept: ConceptType
    let photo: AssetID
    let choose: (AssetID) -> Void

    var body: some View {
        let candidates = session.swapCandidates(concept, photo: photo)
        VStack(alignment: .leading) {
            Text("Swap with (similar shots first)").font(.headline)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 4), spacing: 8) {
                    ForEach(candidates.prefix(40), id: \.self) { id in
                        AsyncThumb(url: session.thumbnailURL(id)).frame(width: 96, height: 96)
                            .onTapGesture { choose(id) }
                    }
                }
            }.frame(width: 430, height: 360)
        }.padding()
    }
}

struct AsyncThumb: View {
    let url: URL
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill().clipped()
        } else { Rectangle().fill(.quaternary) }
    }
}

/// NSSharingServicePicker so we learn which service was actually chosen (a behavioural signal).
struct ShareButton: NSViewRepresentable {
    let urls: [URL]
    let onShare: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                              target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.bezelStyle = .accessoryBarAction
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.urls = urls
        context.coordinator.onShare = onShare
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var urls: [URL] = []
        var onShare: (String) -> Void = { _ in }

        @objc func show(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: urls)
            picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if let service { onShare(service.title) }
        }
    }
}

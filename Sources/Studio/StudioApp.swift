import AppKit
import ImageIO
import Session
import SwiftUI

@main
struct StudioApp: App {
    @State private var model = StudioModel()

    init() {
        // Headless verification: AK14_STUDIO_SNAPSHOT="<runDir>|<sourceFolder>|<out.png>" renders the concept board and exits.
        if let spec = ProcessInfo.processInfo.environment["AK14_STUDIO_SNAPSHOT"] {
            MainActor.assumeIsolated { Snapshot.run(spec) }
        }
        // A SwiftPM-built executable is not an app bundle; make it a regular foreground app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate() }
    }

    var body: some Scene {
        WindowGroup("AK14 Studio") {
            RootView().environment(model).frame(minWidth: 1100, minHeight: 720)
        }
    }
}

struct RootView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        NavigationSplitView {
            RunPickerView()
        } detail: {
            if model.session != nil { ConceptBoardView() } else {
                ContentUnavailableView("Open a run", systemImage: "photo.stack",
                                       description: Text("Pick a run made by `ak14 run <folder>` from the list."))
            }
        }
        .overlay(alignment: .bottom) { StatusBar() }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct StatusBar: View {
    @Environment(StudioModel.self) private var model
    var body: some View {
        if let busy = model.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule()).padding(.bottom, 12)
        }
    }
}

@MainActor
enum Snapshot {
    static func run(_ spec: String) {
        let parts = spec.split(separator: "|").map(String.init)
        guard parts.count == 3 else { fatalError("AK14_STUDIO_SNAPSHOT needs runDir|sourceFolder|out.png") }
        let model = StudioModel()
        do {
            let session = try RunSession(runDirectory: URL(fileURLWithPath: parts[0]))
            try session.setSource(URL(fileURLWithPath: parts[1]))
            model.session = session
            model.selection = session.availableConcepts.first.map { SlideRef(concept: $0, index: 0) }
        } catch { fatalError("snapshot: \(error)") }
        let view = ConceptBoardView().environment(model).frame(width: 1300, height: 900).background(Color.white)
        // Host the real AppKit-backed hierarchy (scroll views, controls) off-screen and let AppKit draw it.
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1300, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("snapshot: no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("snapshot: encode") }
        try? png.write(to: URL(fileURLWithPath: parts[2]))
        exit(0)
    }
}

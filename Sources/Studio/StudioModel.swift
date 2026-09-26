import AppKit
import Core
import Foundation
import Observation
import Session

struct RunSummary: Identifiable, Hashable {
    let url: URL
    let label: String
    let created: Date
    let photos: Int
    let status: String
    var id: URL { url }
}

struct SlideRef: Equatable {
    let concept: ConceptType
    let index: Int
}

@MainActor @Observable
final class StudioModel {
    var runsDirectory: URL
    var runs: [RunSummary] = []
    var session: RunSession?
    var selection: SlideRef?
    var busy: String?
    var error: String?
    /// Bumped after every render so slide images reload.
    var revision = 0

    init() {
        runsDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "runs")
        refreshRuns()
    }

    func refreshRuns() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        runs = dirs.compactMap { url in
            guard fm.fileExists(atPath: url.appending(path: "plans/director.json").path),
                  let data = try? Data(contentsOf: url.appending(path: "manifest.json")),
                  let m = try? decoder.decode(RunManifest.self, from: data) else { return nil }
            return RunSummary(url: url, label: m.sourceFolderLabel, created: m.createdAt, photos: m.photoCount,
                              status: m.directorStatus ?? "—")
        }.sorted { $0.created > $1.created }
    }

    func chooseRunsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the folder that contains AK14 runs"
        if panel.runModal() == .OK, let url = panel.url { runsDirectory = url; refreshRuns() }
    }

    func open(_ run: RunSummary) {
        do {
            let s = try RunSession(runDirectory: run.url)
            if let saved = UserDefaults.standard.url(forKey: "source.\(s.runID)") { try? s.setSource(saved) }
            session = s
            selection = nil
            try s.presented()
            if s.sourceFolder == nil { chooseSource() }
        } catch { self.error = "\(error)" }
    }

    /// The source photo folder is remembered in app preferences, never inside the run directory.
    func chooseSource() {
        guard let s = session else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the photo folder this run was made from (\(s.manifest.sourceFolderLabel))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try s.setSource(url)
            UserDefaults.standard.set(url, forKey: "source.\(s.runID)")
        } catch { self.error = "\(error)" }
    }

    /// Runs a session operation off the main thread with the spec's progress wording.
    func perform(_ label: String = "Rendering your options…", _ work: @escaping @Sendable (RunSession) throws -> Void) {
        guard let s = session else { return }
        if s.sourceFolder == nil { chooseSource(); if s.sourceFolder == nil { return } }
        busy = label
        Task.detached {
            do {
                try work(s)
                await MainActor.run { self.busy = nil; self.revision += 1 }
            } catch {
                await MainActor.run { self.busy = nil; self.error = "\(error)" }
            }
        }
    }

    func export(_ concept: ConceptType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to save the slides, in order"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("Exporting…") { try $0.export(concept, to: url) }
    }
}

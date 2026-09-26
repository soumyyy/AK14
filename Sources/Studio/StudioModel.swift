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
                  let m = try? decoder.decode(RunManifest.self, from: data), m.completedAt != nil else { return nil }
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
        guard busy == nil else { return }
        do {
            let s = try RunSession(runDirectory: run.url)
            session = s
            selection = nil
            images.removeAll()
            record { try $0.presented() }
            if let saved = UserDefaults.standard.url(forKey: "source.\(s.runID)") {
                verifySource(saved, remembered: true)
            } else {
                chooseSource()
            }
        } catch { self.error = "\(error)" }
    }

    /// The source photo folder is remembered in app preferences, never inside the run directory.
    func chooseSource() {
        guard let s = session, busy == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the photo folder this run was made from (\(s.manifest.sourceFolderLabel))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        verifySource(url, remembered: false)
    }

    /// Hashing originals can take seconds; do it off the main thread and say why a folder was rejected.
    private func verifySource(_ url: URL, remembered: Bool) {
        guard let s = session else { return }
        busy = "Checking photos…"
        Task.detached {
            do {
                try s.setSource(url)
                await MainActor.run {
                    self.busy = nil
                    UserDefaults.standard.set(url, forKey: "source.\(s.runID)")
                }
            } catch {
                await MainActor.run {
                    self.busy = nil
                    self.error = (remembered ? "The remembered photo folder no longer matches this run: " : "") + "\(error)"
                }
            }
        }
    }

    /// Runs one mutating operation at a time, off the main thread, with the spec's progress wording.
    /// `done` runs on the main thread only if the operation succeeded.
    func perform(_ work: @escaping @Sendable (RunSession) throws -> Void, label: String = "Rendering your options…",
                 done: (@MainActor () -> Void)? = nil) {
        guard let s = session, busy == nil else { return }
        guard s.sourceFolder != nil else { chooseSource(); return }
        busy = label
        Task.detached {
            do {
                try work(s)
                await MainActor.run { self.busy = nil; self.images.removeAll(); self.revision += 1; done?() }
            } catch {
                await MainActor.run { self.busy = nil; self.error = "\(error)" }
            }
        }
    }

    /// Behaviour logging (select, share, presented) needs no source folder and never blocks editing state.
    func record(_ work: @escaping @Sendable (RunSession) throws -> Void) {
        guard let s = session else { return }
        Task.detached {
            do { try work(s) } catch { await MainActor.run { self.error = "\(error)" } }
        }
    }

    // MARK: - Image cache (slides re-decode only after a render)

    @ObservationIgnored private var images: [URL: NSImage] = [:]

    func image(_ url: URL) -> NSImage? {
        if let cached = images[url] { return cached }
        let image = NSImage(contentsOf: url)
        images[url] = image
        return image
    }

    func export(_ concept: ConceptType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to save the slides, in order"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform({ try $0.export(concept, to: url) }, label: "Exporting…")
    }
}

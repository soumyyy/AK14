import Core
import Foundation
import Session

@main
struct AK14Command {
    static func main() async {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do {
            switch try Arguments.parse(Array(CommandLine.arguments.dropFirst()), cwd: cwd) {
            case .help:
                print(Arguments.usage)
            case .run(var options):
                if !options.noLLM && !options.assumeYes {
                    options.consent = askConsent()
                }
                let store = try await RunPipeline.live(options: options).run(options)
                print(store.url("report.html").path)
            case .rerender(let dir, let source, let seed):
                try RerenderCommand.rerender(runDirectory: dir, source: source, seed: seed)
                try ReportCommand.rebuild(runDirectory: dir)
                print(dir.appending(path: "report.html").path)
            case .followup(let dir, let posted, let platform, let reused, let linkSeen):
                try Followup.record(runDirectory: dir, posted: posted, platform: platform, reusedAnotherEvent: reused, linkSeen: linkSeen)
                print("follow-up recorded")
            case .studySummary(let runs, let out):
                let summary = StudySummary.compute(runsDirectory: runs)
                let dir = out ?? runs
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try JSONCoding.encoder.encode(summary).write(to: dir.appending(path: "study-summary.json"))
                try Data(summary.markdown().utf8).write(to: dir.appending(path: "study-summary.md"))
                print(summary.markdown())
            case .delete(let dir, let cache):
                let removed = try RunDeletion.delete(runDirectory: dir, cacheDirectory: cache)
                print("deleted run\(cache == nil ? "" : " and \(removed) cache files")")
            case .versions:
                for (k, v) in Versions.all.sorted(by: { $0.key < $1.key }) { print("\(k)\t\(v)") }
            case .report(let dir):
                try ReportCommand.rebuild(runDirectory: dir)
                print(dir.appending(path: "report.html").path)
            }
        } catch let error as ArgumentError {
            fail("\(error)\n\(Arguments.usage)")
        } catch {
            fail("\(error)")
        }
    }

    /// Shows the provider disclosure and asks before any thumbnail is sent. Non-interactive runs need --yes.
    static func askConsent() -> Bool {
        FileHandle.standardError.write(Data((Disclosure.text + "\n").utf8))
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data("Not a terminal: pass --yes to consent. Continuing without the model.\n".utf8))
            return false
        }
        FileHandle.standardError.write(Data("Send thumbnails to the model? [y/N] ".utf8))
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

import Analysis
import Director
import Render

enum Versions {
    static var all: [String: String] {
        var v = ["analyzer": VisionAnalyzer.version, "thumbnailer": Thumbnailer.version, "report": ReportBuilder.version,
                 "manifestSchema": "\(RunManifest.currentSchemaVersion)", "reduction": ReductionConfig().version,
                 "pricing": Pricing.version, "model": ResponsesClient(transport: OpenAITransport(apiKey: "")).model,
                 "resolver": ResolvedCarousel.resolverVersion, "renderer": CarouselRenderer.version,
                 "disclosure": Disclosure.version]
        for name in ["triage.system", "planner.system", "repair.system", "mutation.system"] {
            v["prompt:\(name)"] = (try? Prompts.load(name).version) ?? "missing"
        }
        if let pack = try? StylePackLoader.load() { v["stylePack"] = "\(pack.id)@\(pack.version)" }
        return v
    }
}

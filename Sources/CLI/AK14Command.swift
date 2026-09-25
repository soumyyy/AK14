import Foundation

@main
struct AK14Command {
    static func main() async {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        do {
            switch try Arguments.parse(Array(CommandLine.arguments.dropFirst()), cwd: cwd) {
            case .help:
                print(Arguments.usage)
            case .run(let options):
                let store = try await RunPipeline.live(options: options).run(options)
                print(store.url("report.html").path)
            case .rerender(let dir, let source):
                try RerenderCommand.rerender(runDirectory: dir, source: source)
                print(dir.appending(path: "slides/plainDump").path)
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

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

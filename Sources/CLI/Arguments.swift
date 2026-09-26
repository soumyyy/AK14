import Core
import Foundation

struct RunOptions: Equatable, Sendable {
    var folder: URL
    var recursive: Bool = false
    /// nil = infer from photos.
    var aspect: CarouselAspect? = nil
    var runsDirectory: URL
    var cacheDirectory: URL
    /// Requested slide count (5...20); nil lets the planner recommend.
    var slides: Int? = nil
    var noLLM: Bool = false
    var studyCode: String? = nil
    /// Provider disclosure acknowledged (via prompt or --yes). Without it, no thumbnails leave the machine.
    var consent: Bool = false
    /// --yes given: skip the interactive consent prompt.
    var assumeYes: Bool = false
}

enum Command: Equatable {
    case run(RunOptions)
    case report(runDirectory: URL)
    case rerender(runDirectory: URL, source: URL, seed: UInt64?)
    case followup(runDirectory: URL, posted: Bool, platform: String?, reused: Bool?, linkSeen: Bool?)
    case studySummary(runsDirectory: URL, out: URL?)
    case delete(runDirectory: URL, cache: URL?)
    case versions
    case help
}

enum ArgumentError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String), missingFolder, missingRunDirectory, missingSource
    case missingValue(String), unknownOption(String), invalidAspect(String), invalidSlides(String), invalidSeed(String)
    case invalidStudyCode(String), invalidValue(String, String)

    var description: String {
        switch self {
        case .unknownCommand(let c): "unknown command '\(c)'"
        case .missingFolder: "run needs a photo folder"
        case .missingRunDirectory: "report/rerender needs a run directory"
        case .missingSource: "rerender needs --source <folder>"
        case .invalidSlides(let s): "invalid --slides '\(s)' (use 5...20)"
        case .invalidSeed(let s): "invalid --seed '\(s)' (hex)"
        case .invalidValue(let f, let v): "invalid value '\(v)' for \(f)"
        case .invalidStudyCode(let s): "invalid --study-code '\(s)' (1-16 letters, digits, - or _; never a name)"
        case .missingValue(let o): "\(o) needs a value"
        case .unknownOption(let o): "unknown option '\(o)'"
        case .invalidAspect(let a): "invalid aspect '\(a)' (use auto, 3:4, 1:1, 4:5)"
        }
    }
}

enum Arguments {
    static let usage = """
    usage:
      ak14 run <folder> [--study-code CODE] [--yes] [--slides 5-20] [--no-llm] [--recursive] [--aspect auto|3:4|1:1|4:5] [--runs DIR] [--cache DIR]
      ak14 report <runDir>
      ak14 rerender <runDir> --source <folder> [--seed HEX]
      ak14 followup <runDir> --posted yes|no [--platform instagram|other] [--reused-another-event yes|no] [--link-seen yes|no]
      ak14 study summary [runsDir] [--out DIR]
      ak14 delete <runDir> [--purge-cache [--cache DIR]]
      ak14 versions
    """

    static func parse(_ args: [String], cwd: URL) throws -> Command {
        guard let command = args.first, command != "--help", command != "-h", command != "help" else { return .help }
        var rest = Array(args.dropFirst())
        func path(_ s: String) -> URL {
            let full = s.hasPrefix("/") ? s : (cwd.path as NSString).appendingPathComponent(s)
            return URL(fileURLWithPath: (full as NSString).standardizingPath)
        }

        func yesNo(_ v: String, _ flag: String) throws -> Bool {
            switch v.lowercased() { case "yes", "y", "true": return true; case "no", "n", "false": return false
            default: throw ArgumentError.invalidValue(flag, v) }
        }
        func flags(_ allowed: Set<String>, switches: Set<String> = []) throws -> [String: String] {
            var out: [String: String] = [:]
            while !rest.isEmpty {
                let flag = rest.removeFirst()
                if switches.contains(flag) { out[flag] = "yes"; continue }
                guard allowed.contains(flag) else { throw ArgumentError.unknownOption(flag) }
                guard !rest.isEmpty else { throw ArgumentError.missingValue(flag) }
                out[flag] = rest.removeFirst()
            }
            return out
        }

        switch command {
        case "versions":
            return .versions
        case "followup":
            guard let dir = rest.first, !dir.hasPrefix("--") else { throw ArgumentError.missingRunDirectory }
            rest.removeFirst()
            let f = try flags(["--posted", "--platform", "--reused-another-event", "--link-seen"])
            guard let posted = f["--posted"] else { throw ArgumentError.missingValue("--posted") }
            if let p = f["--platform"], !["instagram", "other"].contains(p) { throw ArgumentError.invalidValue("--platform", p) }
            return .followup(runDirectory: path(dir), posted: try yesNo(posted, "--posted"), platform: f["--platform"],
                             reused: try f["--reused-another-event"].map { try yesNo($0, "--reused-another-event") },
                             linkSeen: try f["--link-seen"].map { try yesNo($0, "--link-seen") })
        case "study":
            guard rest.first == "summary" else { throw ArgumentError.unknownCommand("study \(rest.first ?? "")") }
            rest.removeFirst()
            var runs = path("runs")
            if let first = rest.first, !first.hasPrefix("--") { runs = path(first); rest.removeFirst() }
            let f = try flags(["--out"])
            return .studySummary(runsDirectory: runs, out: f["--out"].map(path))
        case "delete":
            guard let dir = rest.first, !dir.hasPrefix("--") else { throw ArgumentError.missingRunDirectory }
            rest.removeFirst()
            let f = try flags(["--cache"], switches: ["--purge-cache"])
            return .delete(runDirectory: path(dir), cache: f["--purge-cache"] != nil ? path(f["--cache"] ?? ".ak14-cache") : nil)
        case "report":
            guard let dir = rest.first else { throw ArgumentError.missingRunDirectory }
            return .report(runDirectory: path(dir))
        case "rerender":
            guard let dir = rest.first, !dir.hasPrefix("--") else { throw ArgumentError.missingRunDirectory }
            rest.removeFirst()
            var source: URL?, seed: UInt64?
            while !rest.isEmpty {
                let flag = rest.removeFirst()
                guard !rest.isEmpty else { throw ArgumentError.missingValue(flag) }
                let v = rest.removeFirst()
                switch flag {
                case "--source": source = path(v)
                case "--seed":
                    guard let s = UInt64(v, radix: 16) else { throw ArgumentError.invalidSeed(v) }
                    seed = s
                default: throw ArgumentError.unknownOption(flag)
                }
            }
            guard let source else { throw ArgumentError.missingSource }
            return .rerender(runDirectory: path(dir), source: source, seed: seed)
        case "run":
            guard let folder = rest.first, !folder.hasPrefix("--") else { throw ArgumentError.missingFolder }
            rest.removeFirst()
            var o = RunOptions(folder: path(folder), runsDirectory: path("runs"), cacheDirectory: path(".ak14-cache"))
            while !rest.isEmpty {
                let flag = rest.removeFirst()
                func value() throws -> String {
                    guard !rest.isEmpty else { throw ArgumentError.missingValue(flag) }
                    return rest.removeFirst()
                }
                switch flag {
                case "--recursive": o.recursive = true
                case "--no-llm": o.noLLM = true
                case "--yes": o.assumeYes = true; o.consent = true
                case "--study-code":
                    let v = try value()
                    guard StudyCode.isValid(v) else { throw ArgumentError.invalidStudyCode(v) }
                    o.studyCode = v
                case "--slides":
                    let v = try value()
                    guard let n = Int(v), (5...20).contains(n) else { throw ArgumentError.invalidSlides(v) }
                    o.slides = n
                case "--aspect":
                    let v = try value()
                    if v == "auto" { o.aspect = nil }
                    else if let a = CarouselAspect(rawValue: v) { o.aspect = a }
                    else { throw ArgumentError.invalidAspect(v) }
                case "--runs": o.runsDirectory = path(try value())
                case "--cache": o.cacheDirectory = path(try value())
                default: throw ArgumentError.unknownOption(flag)
                }
            }
            return .run(o)
        default:
            throw ArgumentError.unknownCommand(command)
        }
    }
}

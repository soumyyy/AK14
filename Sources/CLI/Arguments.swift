import Core
import Foundation

struct RunOptions: Equatable, Sendable {
    var folder: URL
    var recursive: Bool = false
    /// nil = infer from photos.
    var aspect: CarouselAspect? = nil
    var runsDirectory: URL
    var cacheDirectory: URL
}

enum Command: Equatable {
    case run(RunOptions)
    case report(runDirectory: URL)
    case help
}

enum ArgumentError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String), missingFolder, missingRunDirectory
    case missingValue(String), unknownOption(String), invalidAspect(String)

    var description: String {
        switch self {
        case .unknownCommand(let c): "unknown command '\(c)'"
        case .missingFolder: "run needs a photo folder"
        case .missingRunDirectory: "report needs a run directory"
        case .missingValue(let o): "\(o) needs a value"
        case .unknownOption(let o): "unknown option '\(o)'"
        case .invalidAspect(let a): "invalid aspect '\(a)' (use auto, 3:4, 1:1, 4:5)"
        }
    }
}

enum Arguments {
    static let usage = """
    usage:
      ak14 run <folder> [--recursive] [--aspect auto|3:4|1:1|4:5] [--runs DIR] [--cache DIR]
      ak14 report <runDir>
    """

    static func parse(_ args: [String], cwd: URL) throws -> Command {
        guard let command = args.first, command != "--help", command != "-h", command != "help" else { return .help }
        var rest = Array(args.dropFirst())
        func path(_ s: String) -> URL {
            let full = s.hasPrefix("/") ? s : (cwd.path as NSString).appendingPathComponent(s)
            return URL(fileURLWithPath: (full as NSString).standardizingPath)
        }

        switch command {
        case "report":
            guard let dir = rest.first else { throw ArgumentError.missingRunDirectory }
            return .report(runDirectory: path(dir))
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

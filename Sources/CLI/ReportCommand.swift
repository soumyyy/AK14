import Foundation
import Session

enum ReportCommand {
    static func rebuild(runDirectory: URL) throws { try RunReport.rebuild(runDirectory: runDirectory) }
}

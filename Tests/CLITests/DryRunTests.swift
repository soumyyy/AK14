import Foundation
import Testing
@testable import Core
@testable import Session

/// Opt-in operator dry run against a real run: AK14_DRYRUN="<runDir>|<sourceFolder>|<exportDir>".
/// Performs the same RunSession calls Studio makes (edits, reroll, select, export).
@Test(.enabled(if: ProcessInfo.processInfo.environment["AK14_DRYRUN"] != nil))
func operatorDryRun() throws {
    let parts = ProcessInfo.processInfo.environment["AK14_DRYRUN"]!.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
    let session = try RunSession(runDirectory: parts[0])
    try session.setSource(parts[1])
    try session.presented()
    let designed = try #require(session.plan("c1"))
    if designed.slides.count > 1 { try session.apply(.reorder(from: 1, to: 0), to: "c1") }
    let photo = try #require(session.plan("c1")).slides[0].photos[0].assetID
    if let alt = session.swapCandidates("c1", photo: photo).first { try session.apply(.swap(slide: 0, photo: photo, with: alt), to: "c1") }
    try session.reroll("c2")
    try session.select("c1")
    let files = try session.export("c1", to: parts[2])
    #expect(!files.isEmpty)
}

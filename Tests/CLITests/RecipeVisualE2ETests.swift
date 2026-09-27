import Foundation
import Testing
import TestSupport
@testable import Analysis
@testable import Core
@testable import Render

/// Renders a full multi-slide document for several recipe families (spec §3/§4) through the real
/// composer → RecipeFiller → DocumentRenderer pipeline, and copies the PNGs to a fixed path under /tmp
/// so they can be inspected by eye against the 17V28 quality bar. This is a visual-review aid, not a
/// strict pixel assertion suite (`RecipeFillE2ETests` and `DocumentE2ETests` cover the safety rules).
@Test func recipeFamiliesRenderDeterministicallyForVisualReview() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("trip")
    // A dozen visually distinct photos across a day, a mix of portrait and landscape sources.
    for i in 0..<12 {
        var exif = FixtureFactory.Exif()
        exif.date = String(format: "2026:06:14 %02d:%02d:00", 9 + i / 2, (i % 2) * 30)
        exif.orientation = i % 4 == 0 ? 6 : 1
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: exif)
    }
    let records = try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, $0) })
    let features = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, PhotoFeatures(assetID: $0.assetID, analyzerVersion: "test")) })
    let ids = records.map(\.assetID)
    let pack = try StylePackLoader.load()
    let recipes = try #require(pack.recipes)
    let context = CompositionContext(aspect: .portrait4x5, photos: byID, features: features, triage: [:],
                                     flagged: [], sequenceIntent: [:], stylePack: pack, maxSlides: nil)

    // Style vectors chosen against the axis weights in starter-editorial.json (RecipeFiller.select's
    // scoring) so each direction unambiguously earns its target family. Scrapbook and journal share
    // identical axes and tie; seed 1 (odd) breaks the tie towards scrapbook (ids sorted alphabetically,
    // "journal" < "scrapbook").
    let cases: [(family: Recipe.Family, style: StyleVector, seed: UInt64, title: String)] = [
        (.minimal, StyleVector(density: "balanced", overlap: "none", grouping: "single", decoration: "none", rotation: "none", whitespace: "airy"), 2, "A quiet afternoon"),
        (.film, StyleVector(density: "balanced", overlap: "none", grouping: "single", decoration: "none", rotation: "none", whitespace: "tight"), 2, "Reel 3, June"),
        (.scrapbook, StyleVector(density: "balanced", overlap: "some", grouping: "mixed", decoration: "rich", rotation: "some", whitespace: "tight"), 1, "Our day out"),
        (.panorama, StyleVector(density: "balanced", overlap: "bold", grouping: "collage", decoration: "none", rotation: "none", whitespace: "tight"), 2, "The whole afternoon"),
    ]

    for (family, style, seed, title) in cases {
        let direction = Direction(brief: "test direction", style: style, coverAssetID: ids[0], orderedAssetIDs: ids, titleIdea: title)
        let composition = ComposerEngine.compose(direction, id: "vq-\(family.rawValue)", context: context, seed: seed)
        let plan = composition.plan
        #expect(!plan.slides.isEmpty, "\(family) produced no slides")
        let picked = try #require(RecipeFiller.select(for: style, recipes: recipes, seed: seed),
                                  "\(family) style vector scored below the fill threshold")
        #expect(picked.family == family, "style vector meant for \(family) selected \(picked.family) instead")
        let document = RecipeFiller.fill(plan: plan, direction: direction, recipe: picked, context: context, seed: seed)
        let outDir = tmp.url.appending(path: family.rawValue)
        let outcome = try DocumentRenderer().render(document, photos: byID, sourceFolder: folder, outputDirectory: outDir)
        #expect(outcome.failures.isEmpty, "\(family) failed to render: \(outcome.failures)")
        #expect(outcome.names.count == document.slideCount)

        // Determinism: rendering the same document again must be byte-identical.
        let again = try DocumentRenderer().render(document, photos: byID, sourceFolder: folder, outputDirectory: tmp.url.appending(path: "\(family.rawValue)-again"))
        for name in outcome.names {
            let a = try Data(contentsOf: outDir.appending(path: name))
            let b = try Data(contentsOf: tmp.url.appending(path: "\(family.rawValue)-again/\(name)"))
            #expect(a == b, "\(family) \(name) is not deterministic")
        }

        // Copy to a fixed path for visual review.
        let reviewDir = URL(fileURLWithPath: "/tmp/ak14-studio/\(family.rawValue)")
        try? FileManager.default.removeItem(at: reviewDir)
        try FileManager.default.createDirectory(at: reviewDir, withIntermediateDirectories: true)
        for name in outcome.names {
            try FileManager.default.copyItem(at: outDir.appending(path: name), to: reviewDir.appending(path: name))
        }
    }
}

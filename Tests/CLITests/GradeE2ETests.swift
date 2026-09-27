import Foundation
import Testing
import TestSupport
@testable import Analysis
@testable import Core
@testable import Render

private func colorProfile(l: Double, warmth: Double = 0, saturation: Double = 0.5) -> ColorProfile {
    ColorProfile(l: l, a: 0, b: 0, saturation: saturation, warmth: warmth, contrast: 0.2)
}

private func features(_ id: AssetID, l: Double, warmth: Double = 0, saturation: Double = 0.5) -> PhotoFeatures {
    var f = PhotoFeatures(assetID: id, analyzerVersion: "test")
    f.color = colorProfile(l: l, warmth: warmth, saturation: saturation)
    return f
}

@Test func carouselGradePullsBrightOutliersAndRespectsDeadZoneAndMinimumSetSize() throws {
    let a = AssetID(rawValue: "a"), b = AssetID(rawValue: "b"), c = AssetID(rawValue: "c"), d = AssetID(rawValue: "d")
    let map: [AssetID: PhotoFeatures] = [
        a: features(a, l: 50),
        b: features(b, l: 52),
        c: features(c, l: 48),
        d: features(d, l: 90),
    ]
    let grades = CarouselGrade.adjustments(for: [a, b, c, d], features: map)
    let bright = try #require(grades[d])
    #expect(bright.exposure < 0 && bright.exposure >= -0.35)

    let near = CarouselGrade.adjustments(for: [a, b, c], features: [
        a: features(a, l: 50, warmth: 0.1, saturation: 0.5),
        b: features(b, l: 51, warmth: 0.11, saturation: 0.51),
        c: features(c, l: 49, warmth: 0.09, saturation: 0.49),
    ])
    #expect(near[a]?.exposure == 0 || near[a] == nil)
    #expect(near[b] == nil || (near[b]?.exposure == 0 && near[b]?.warmth == 0 && near[b]?.saturation == 0))

    let twoOnly = CarouselGrade.adjustments(for: [a, b], features: [a: map[a]!, b: map[b]!])
    #expect(twoOnly.isEmpty)
}

@Test func layoutResolverAppliesGradeOnlyForNonBaselinePlans() async throws {
    let tmp = try TempDirectory(); defer { tmp.remove() }
    let folder = try tmp.sub("photos")
    for i in 0..<4 {
        try FixtureFactory.writeScene(to: folder.appending(path: String(format: "IMG_%04d.jpg", i)), scene: i, exif: FixtureFactory.Exif())
    }
    let records = try await FolderIngester().ingest(folder: folder, options: IngestOptions()).photos
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.assetID, $0) })
    let ids = records.map(\.assetID)
    let slides = ids.map { id in
        SlidePlan(primitive: .hero, mood: "", density: "balanced", photos: [.plain(id)], decorations: [], stamps: [])
    }
    let style = StyleVector(density: "balanced", overlap: "none", grouping: "single", decoration: "none", rotation: "none", whitespace: "standard")
    let direction = Direction(brief: "", style: style, coverAssetID: ids[0], orderedAssetIDs: ids)

    var featureMap: [AssetID: PhotoFeatures] = [:]
    let ls: [Double] = [48, 50, 52, 85]
    for (id, l) in zip(ids, ls) {
        featureMap[id] = features(id, l: l)
    }
    let context = LayoutContext(aspect: .portrait4x5, photos: byID, features: featureMap, stylePack: try StylePackLoader.load(), seed: 42)

    let baselinePlan = CarouselPlan(id: CarouselPlan.baselineID, brief: "", direction: direction, slides: slides)
    let baseline = LayoutResolver.resolve(baselinePlan, context: context)
    for slide in baseline.slides {
        for element in slide.elements where element.kind == .photo {
            #expect(element.adjustments == nil)
        }
    }

    let designedPlan = CarouselPlan(id: "c1", brief: "", direction: direction, slides: slides)
    let designed = LayoutResolver.resolve(designedPlan, context: context)
    var adjustedCount = 0
    for slide in designed.slides {
        for element in slide.elements where element.kind == .photo && element.adjustments != nil {
            adjustedCount += 1
        }
    }
    #expect(adjustedCount > 0)
    let outlierID = ids[3]
    var sawNegativeExposure = false
    for slide in designed.slides {
        for element in slide.elements where element.assetID == outlierID {
            if (element.adjustments?.exposure ?? 0) < 0 { sawNegativeExposure = true }
        }
    }
    #expect(sawNegativeExposure)
}

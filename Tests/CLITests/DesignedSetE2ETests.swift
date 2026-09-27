import Core
import Render
import XCTest

final class DesignedSetE2ETests: XCTestCase {
    func testBundledDesignedSetLibraryDecodesAndValidates() throws {
        let library = try StylePackLoader.loadDesignedSets()
        XCTAssertNil(library.validationError())
        XCTAssertEqual(library.sets.count, 55)
        XCTAssertEqual(library.sets.filter { $0.sourceRef.hasPrefix("17v28:layout-") }.count, 27)
        XCTAssertTrue(library.sets.contains { !($0.texts?.isEmpty ?? true) })
        XCTAssertTrue(library.sets.contains { !($0.frames?.isEmpty ?? true) })
        XCTAssertTrue(library.sets.allSatisfy { ($0.decorCoverage ?? 0) <= 0.12 })
        XCTAssertTrue(library.sets.allSatisfy { $0.texts?.allSatisfy { $0.role != "sample" } ?? true })
        for frame in library.sets.flatMap({ $0.frames ?? [] }) {
            XCTAssertNotNil(FrameAssetRegistry.asset(imageAssetID: frame.frameAssetID), frame.frameAssetID)
        }
        XCTAssertEqual(Set(library.sets.map(\.id)).count, library.sets.count)
        XCTAssertEqual(library.sets.map(\.id), library.sets.map(\.id).sorted())

        let counts = library.countsByAspect
        print("Designed sets per aspect: \(counts)")
        XCTAssertGreaterThan(counts[CarouselAspect.portrait4x5.rawValue] ?? 0, 0)
        XCTAssertGreaterThan(counts[CarouselAspect.portrait3x4.rawValue] ?? 0, 0)
        XCTAssertGreaterThan(counts[CarouselAspect.square.rawValue] ?? 0, 0)
        for set in library.sets {
            let areas = set.slots.map { slot in
                slot.components?.reduce(0) { $0 + $1.frame.width * $1.frame.height } ?? slot.frame.width * slot.frame.height
            }
            XCTAssertEqual(areas, areas.sorted(by: >), "slots should be ordered by area in \(set.id)")
        }
    }

    func testSeamCrossingIsDerivedFromDocumentCoordinates() throws {
        let library = try StylePackLoader.loadDesignedSets()
        let crossingSlots = library.sets.flatMap { set in
            set.slots.filter { $0.crossesSeam }.map { (set, $0) }
        }
        XCTAssertFalse(crossingSlots.isEmpty)
        for (set, slot) in crossingSlots {
            XCTAssertTrue((1..<set.slideCount).contains { seam in
                Double(seam) > slot.frame.x && Double(seam) < slot.frame.x + slot.frame.width
            })
        }
        for set in library.sets {
            for slot in set.slots {
                let parts = slot.components?.map { ($0.frame, $0.crossesSeam) } ?? [(slot.frame, slot.crossesSeam)]
                for (frame, crosses) in parts {
                    let actual = (1..<set.slideCount).contains { seam in
                        Double(seam) > frame.x + 0.000001 && Double(seam) < frame.x + frame.width - 0.000001
                    }
                    XCTAssertEqual(crosses, actual, "incorrect seam flag in \(set.id)")
                }
            }
        }
        XCTAssertTrue(library.sets.contains(where: \.crossesSeam))
    }
}

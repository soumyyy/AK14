#!/usr/bin/env swift
import AppKit
import Foundation

struct Point: Decodable { let x: Double; let y: Double }
struct Size: Decodable { let width: Double; let height: Double }
struct RawColor: Decodable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}
struct RawText: Decodable {
    let textColor: RawColor?
    let numberOfLines: Int?
    let fontName: String?
    let fontSize: Double?
    let text: String?
    let textAlignment: Int?
    let lineSpacing: Double?
    let letterSpacing: Double?
}
struct RawBox: Decodable {
    let center: Point?
    let size: Size?
    let frame: RawFrame?
}
struct RawFrame: Decodable {
    let origin: Point
    let size: Size
}
struct RawNestedLayout: Decodable {
    let frameIndex: Int?
    let placeholders: [RawNestedPlaceholder]?
}
struct RawNestedPlaceholder: Decodable {
    let relativeFrame: RawFrame?
    let frame: RawFrame?
}
struct RawLayer: Decodable {
    let id: String
    let placeholderCenter: Point?
    let placeholderSize: Size?
    let center: Point?
    let size: Size?
    let text: RawText?
    let scaling: Double?
    let rotation: Double?
    let cornerRadius: Double?
    let frameCenter: Point?
    let frameSize: Size?
    let frameImage: String?
    let framePlaceholders: [RawBox]?
    let image: String?
    let imageExtension: String?
    let layout: RawNestedLayout?
}
struct RawTemplate: Decodable {
    let id: String; let categoryId: String?; let frameType: String; let numberOfFrames: Int
    let backgroundColor: String?; let layers: [RawLayer]
}
struct RawLayout: Decodable {
    struct Placeholder: Decodable {
        struct Frame: Decodable { let origin: Point; let size: Size }
        let frame: Frame
    }
    let id: String; let placeholders: [Placeholder]
}
struct Rect: Codable {
    let x: Double; let y: Double; let width: Double; let height: Double
}
struct Slot: Codable {
    let frame: Rect; let aspect: Double; let z: Int; let rotation: Double
    let crossesSeam: Bool; let roleHint: String; let components: [Component]?; let cornerRadius: Double?
}
struct Component: Codable {
    let frame: Rect; let aspect: Double; let z: Int; let rotation: Double
    let crossesSeam: Bool; let roleHint: String
}
struct SetRecord: Codable {
    let id: String; let sourceRef: String; let aspect: String; let slideCount: Int
    let background: String; let slots: [Slot]; let version: Int
    let texts: [TextLayer]?; let frames: [FrameLayer]?; let family: String?; let decorCoverage: Double?
}
struct PageRecord: Codable {
    let id: String; let sourceRef: String; let aspect: String; let slideCount: Int
    let background: String; let slots: [Slot]; let version: Int
    let texts: [TextLayer]?; let frames: [FrameLayer]?; let family: String?; let decorCoverage: Double?
    let sourceTemplate: String; let pageIndex: Int; let pageRole: String; let coverCapable: Bool
}
struct TextLayer: Codable {
    let frame: Rect; let fontID: String; let size: Double; let colour: String; let alignment: String
    let lineSpacing: Double; let letterSpacing: Double; let numberOfLines: Int; let rotation: Double; let role: String
}
struct FrameLayer: Codable {
    let frame: Rect; let frameAssetID: String; let slotFrame: Rect?; let photoWindowAspect: Double?
    let z: Int; let rotation: Double
}
struct Library: Codable {
    let version: Int; let frameInference: String; let sets: [SetRecord]
}
struct PageLibrary: Codable { let version: Int; let frameInference: String; let sets: [PageRecord] }
struct Box { let x: Double; let y: Double; let width: Double; let height: Double }

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = URL(fileURLWithPath: "/Applications/app17v28.app/Wrapper/app17v28.app")
let output = root.appendingPathComponent("Sources/Render/Resources/StylePacks/designed-sets.json")
let bleed = 0.03
let libraryVersion = 2

func lenientDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let text = String(decoding: data, as: UTF8.self)
    let regex = try NSRegularExpression(pattern: ",\\s*([}\\]])")
    let clean = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    return try JSONDecoder().decode(type, from: Data(clean.utf8))
}

func templateFiles() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.range(of: "^template-[0-9]+\\.json$", options: .regularExpression) != nil }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func canvas(frameType: String) -> (Double, Double, String)? {
    switch frameType {
    case "portrait": return (216, 270, "4:5")
    case "portrait2": return (216, 288, "3:4")
    case "square": return (216, 216, "1:1")
    default: return nil
    }
}

func normalized(_ boxes: [Box], canvasWidth: Double, canvasHeight: Double, slideCount: Int, aspect: String, unitSpace: Bool = false, pageRescue: Bool = false) -> [Slot]? {
    guard !boxes.isEmpty else { return nil }
    let prepared = boxes.enumerated().map { index, b in
        let f = Rect(x: b.x / canvasWidth, y: b.y / canvasHeight,
                     width: b.width / canvasWidth, height: b.height / canvasHeight)
        let ratio = (b.width / b.height) * (unitSpace ? (aspect == "4:5" ? 4.0 / 5.0 : aspect == "3:4" ? 3.0 / 4.0 : 1.0) : 1)
        return (index, f, ratio, f.width * f.height)
    }
    guard prepared.allSatisfy({ _, f, _, _ in f.width > 0 && f.height > 0 && (pageRescue || (f.x >= -bleed && f.y >= -bleed && f.x + f.width <= Double(slideCount) + bleed && f.y + f.height <= 1 + bleed)) }) else { return nil }
    let order = prepared.sorted { $0.3 == $1.3 ? $0.0 < $1.0 : $0.3 > $1.3 }
    let roles = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.0, $0.offset == 0 ? "hero" : "support") })
    return prepared.sorted { $0.3 == $1.3 ? $0.0 < $1.0 : $0.3 > $1.3 }.map { index, frame, ratio, _ in
        let seams = slideCount > 1 && (1..<slideCount).contains {
            Double($0) > frame.x + 0.000001 && Double($0) < frame.x + frame.width - 0.000001
        }
        return Slot(frame: frame, aspect: ratio, z: index, rotation: 0, crossesSeam: seams,
                    roleHint: roles[index]!, components: nil, cornerRadius: nil)
    }
}

struct ImportedFrame: Decodable {
    struct Window: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
    let imageAssetID: String
    let imageWidth: Int
    let imageHeight: Int
    let photoWindow: Window
}

func normalizedRect(_ box: Box, canvasWidth: Double, canvasHeight: Double) -> Rect {
    Rect(x: box.x / canvasWidth, y: box.y / canvasHeight,
         width: box.width / canvasWidth, height: box.height / canvasHeight)
}

func directBox(_ center: Point?, _ size: Size?) -> Box? {
    guard let center, let size, size.width > 0, size.height > 0 else { return nil }
    return Box(x: center.x - size.width / 2, y: center.y - size.height / 2,
               width: size.width, height: size.height)
}

func rawBox(_ box: RawBox) -> Box? {
    directBox(box.center, box.size) ?? box.frame.map {
        Box(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height)
    }
}

func nestedBoxes(_ layer: RawLayer, canvasWidth: Double, canvasHeight: Double) -> [Box] {
    guard let layout = layer.layout, let placeholders = layout.placeholders else { return [] }
    return placeholders.compactMap { placeholder in
        let frame = placeholder.relativeFrame ?? placeholder.frame
        guard let frame else { return nil }
        let page = Double(layout.frameIndex ?? 0)
        return Box(x: (page + frame.origin.x) * canvasWidth,
                   y: frame.origin.y * canvasHeight,
                   width: frame.size.width * canvasWidth,
                   height: frame.size.height * canvasHeight)
    }
}

func placeholderBoxes(_ layer: RawLayer, canvasWidth: Double, canvasHeight: Double, pageSpaceFrames: Bool = false) -> [Box] {
    if let direct = directBox(layer.placeholderCenter, layer.placeholderSize) {
        return [direct]
    }
    if let frames = layer.framePlaceholders {
        guard pageSpaceFrames, let frame = directBox(layer.frameCenter, layer.frameSize) else { return frames.compactMap(rawBox) }
        return frames.compactMap(rawBox).map { window in
            Box(x: frame.x + window.x, y: frame.y + window.y, width: window.width, height: window.height)
        }
    }
    return nestedBoxes(layer, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
}

func deduplicated(_ boxes: [Box]) -> [Box] {
    boxes.reduce(into: [Box]()) { result, box in
        guard !result.contains(where: {
            abs($0.x - box.x) < 0.0001 && abs($0.y - box.y) < 0.0001 &&
            abs($0.width - box.width) < 0.0001 && abs($0.height - box.height) < 0.0001
        }) else { return }
        result.append(box)
    }
}

func isSymbolOnly(_ value: String) -> Bool {
    !value.unicodeScalars.contains { scalar in
        CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}

func fontID(_ name: String) -> String {
    // The explicit mappings preserve the faces named by the 17V28 source.
    if name.hasPrefix("Inter-") || name.hasPrefix("Roboto-") { return "font-inter" }
    if name.hasPrefix("DotGothic16") { return "font-dotgothic16" }
    if name.hasPrefix("InstrumentSerif-Italic") { return "font-instrumentserif-italic" }
    if name.hasPrefix("InstrumentSerif") { return "font-instrumentserif" }
    if name.hasPrefix("AmaticSC") { return "font-amaticsc" }
    if name.hasPrefix("Anton") { return "font-anton" }
    if name.hasPrefix("PinyonScript") { return "font-pinyonscript" }
    if name.hasPrefix("Cedarville-Cursive") { return "font-cedarvillecursive" }
    if name.hasPrefix("Outfit") { return "font-outfit" }
    if name.hasPrefix("Ballet") { return "font-ballet" }
    if name.hasPrefix("SpecialElite") { return "font-specialelite" }
    // Fallbacks are deliberately explicit: these source faces are not bundled, so the closest
    // existing families keep the page's visual job without copying the source font.
    if name.hasPrefix("RobotoMono") { return "font-jetbrainsmono" } // closest bundled mono
    if name.hasPrefix("Unbounded") { return "font-unbounded" } // closest bundled geometric display
    if name.hasPrefix("Caveat") { return "font-caveat" } // closest bundled handwriting
    if name.hasPrefix("DelaGothicOne") { return "font-delagothicone" } // closest bundled display
    if name.hasPrefix("NewAmsterdam") { return "font-newamsterdam" } // closest bundled display
    if name.hasPrefix("HomemadeApple") { return "font-homemadeapple" } // closest bundled script
    if name.hasPrefix("RockSalt") { return "font-rocksalt" } // closest bundled marker
    if name.hasPrefix("Mansalva") { return "font-mansalva" } // closest bundled handwriting
    if name.hasPrefix("ShantellSans") { return "font-shantellsans" } // closest bundled handwriting sans
    return "font-inter" // unknown source face: safe neutral fallback
}

func hexColor(_ color: RawColor?) -> String {
    guard let color else { return "#000000" }
    let clamp: (Double) -> Int = { Int((min(1, max(0, $0)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", clamp(color.red), clamp(color.green), clamp(color.blue))
}

func alignment(_ value: Int?) -> String {
    switch value ?? 0 {
    case 1: return "center"
    case 2: return "right"
    default: return "left"
    }
}

func unionArea(_ boxes: [Box]) -> Double {
    guard !boxes.isEmpty else { return 0 }
    let xs = Set(boxes.flatMap { [$0.x, $0.x + $0.width] }).sorted()
    let ys = Set(boxes.flatMap { [$0.y, $0.y + $0.height] }).sorted()
    var area = 0.0
    for x in zip(xs, xs.dropFirst()) {
        for y in zip(ys, ys.dropFirst()) {
            let cell = Box(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
            if boxes.contains(where: {
                max($0.x, cell.x) < min($0.x + $0.width, cell.x + cell.width) &&
                max($0.y, cell.y) < min($0.y + $0.height, cell.y + cell.height)
            }) { area += cell.width * cell.height }
        }
    }
    return area
}

func pageRole(slots: [Slot], texts: [TextLayer], length: Double) -> String {
    let areas = slots.map { $0.frame.width * $0.frame.height / length }
    if slots.count == 1, areas[0] >= 0.8 { return texts.contains { $0.role == "title" } ? "cover" : "statement" }
    if texts.contains(where: { $0.role == "title" }) { return "cover" }
    if slots.count <= 1, (areas.first ?? 0) < 0.35 { return "quiet" }
    let xs = Set(slots.map { ($0.frame.x * 20).rounded() })
    let ys = Set(slots.map { ($0.frame.y * 20).rounded() })
    if (2...4).contains(slots.count), xs.count == 1 || ys.count == 1 { return "strip" }
    let maxArea = areas.max() ?? 0, minArea = areas.min() ?? 0
    if slots.count >= 3, minArea / max(maxArea, 0.0001) >= 0.7 { return "grid" }
    return areas.count == 1 ? "statement" : "grid"
}

func pages(templateID: Int, aspect: String, pageCount: Int, background: String, family: String,
           slots: [Slot], texts: [TextLayer], frames: [FrameLayer], decor: [Box],
           rejectionCounts: inout [String: Int]) -> [PageRecord] {
    guard pageCount > 0 else { return [] }
    func spans(_ x: Double, _ width: Double) -> ClosedRange<Int> {
        let lo = min(pageCount - 1, max(0, Int(floor(x + 0.001))))
        let hi = min(pageCount - 1, max(lo, Int(floor(x + width - 0.001))))
        return lo...hi
    }
    var parent = Array(0..<pageCount)
    func find(_ index: Int) -> Int {
        if parent[index] != index { parent[index] = find(parent[index]) }
        return parent[index]
    }
    // Only content that participates in rendering links pages. Decorative images are omitted
    // from this phase, so they must not turn neighboring pages into a linked run.
    let ranges = slots.map { spans($0.frame.x, $0.frame.width) }
        + texts.map { spans($0.frame.x, $0.frame.width) }
        + frames.map { spans($0.frame.x, $0.frame.width) }
    for range in ranges where range.count > 1 {
        let root = find(range.lowerBound)
        for index in range.dropFirst() { parent[find(index)] = root }
    }
    let groups = Dictionary(grouping: 0..<pageCount, by: find).values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    return groups.compactMap { group in
        let first = group[0], length = Double(group.count), start = Double(first)
        func local(_ rect: Rect) -> Rect { Rect(x: rect.x - start, y: rect.y, width: rect.width, height: rect.height) }
        func inside(_ x: Double, _ width: Double) -> Bool {
            x + 0.001 >= start && x + width - 0.001 <= start + length
        }
        func belongsToGroup(_ x: Double, _ width: Double) -> Bool {
            let occupied = spans(x, width)
            return occupied.lowerBound >= group[0] && occupied.upperBound <= group[group.count - 1]
        }
        let selectedSlots = slots.filter {
            group.count > 1 ? belongsToGroup($0.frame.x, $0.frame.width) : inside($0.frame.x, $0.frame.width)
        }.map { slot in
            let rect = local(slot.frame)
            let seam = group.count > 1 && (1..<group.count).contains {
                Double($0) > rect.x + 0.000001 && Double($0) < rect.x + rect.width - 0.000001
            }
            return Slot(frame: rect, aspect: slot.aspect, z: slot.z, rotation: slot.rotation, crossesSeam: seam,
                        roleHint: slot.roleHint, components: slot.components, cornerRadius: slot.cornerRadius)
        }
        guard selectedSlots.allSatisfy({ slot in
            let f = slot.frame
            return f.x >= -bleed && f.y >= -bleed && f.x + f.width <= length + bleed && f.y + f.height <= 1 + bleed
        }) else {
            rejectionCounts["\(aspect) photo window outside page", default: 0] += 1
            return nil
        }
        guard !selectedSlots.isEmpty else { rejectionCounts["\(aspect) no photo slots", default: 0] += 1; return nil }
        let selectedTexts = texts.filter {
            group.count > 1 ? belongsToGroup($0.frame.x, $0.frame.width) : inside($0.frame.x, $0.frame.width)
        }.map {
            TextLayer(frame: local($0.frame), fontID: $0.fontID, size: $0.size, colour: $0.colour,
                      alignment: $0.alignment, lineSpacing: $0.lineSpacing, letterSpacing: $0.letterSpacing,
                      numberOfLines: $0.numberOfLines, rotation: $0.rotation, role: $0.role)
        }
        let selectedFrames = frames.filter {
            group.count > 1 ? belongsToGroup($0.frame.x, $0.frame.width) : inside($0.frame.x, $0.frame.width)
        }.map {
            FrameLayer(frame: local($0.frame), frameAssetID: $0.frameAssetID, slotFrame: $0.slotFrame.map(local),
                       photoWindowAspect: $0.photoWindowAspect, z: $0.z, rotation: $0.rotation)
        }
        // Measure only the portion of each decoration inside this page or linked run.
        // Vertical clipping is to the normalized page bounds; horizontal clipping is to the run.
        let clippedDecor = decor.compactMap { decoration -> Box? in
            let x0 = max(start, decoration.x), x1 = min(start + length, decoration.x + decoration.width)
            let y0 = max(0, decoration.y), y1 = min(1, decoration.y + decoration.height)
            guard x1 > x0, y1 > y0 else { return nil }
            return Box(x: x0 - start, y: y0, width: x1 - x0, height: y1 - y0)
        }
        let coverage = min(1, unionArea(clippedDecor) / length)
        // A small edge overlap is allowed. Reject only when one decoration covers
        // more than 15% of an individual photo slot's area; decorations are never rendered.
        let overlapsPhotoOverLimit = clippedDecor.contains { decoration in
            selectedSlots.contains { slot in
                let intersectionWidth = max(0, min(decoration.x + decoration.width, slot.frame.x + slot.frame.width) - max(decoration.x, slot.frame.x))
                let intersectionHeight = max(0, min(decoration.y + decoration.height, slot.frame.y + slot.frame.height) - max(decoration.y, slot.frame.y))
                let slotArea = slot.frame.width * slot.frame.height
                return slotArea > 0 && intersectionWidth * intersectionHeight > 0.15 * slotArea
            }
        }
        guard coverage <= 0.12, !overlapsPhotoOverLimit else {
            let reason = overlapsPhotoOverLimit ? "decoration overlap over 15% of photo slot" : "decoration coverage over 12%"
            rejectionCounts["\(aspect) \(reason)", default: 0] += 1
            return nil
        }
        let role = pageRole(slots: selectedSlots, texts: selectedTexts, length: length)
        let dominant = selectedSlots.map { $0.frame.width * $0.frame.height }.max()! / length
        let cover = group.count == 1 && (selectedTexts.contains { $0.role == "title" } || dominant >= 0.6)
        let id = group.count == 1 ? "17v28-t\(templateID)-p\(first)" : "17v28-t\(templateID)-p\(first)-\(group.last!)"
        let record = PageRecord(id: id, sourceRef: "17v28:template-\(templateID)", aspect: aspect, slideCount: group.count,
                                background: background, slots: selectedSlots, version: libraryVersion,
                                texts: selectedTexts.isEmpty ? nil : selectedTexts, frames: selectedFrames.isEmpty ? nil : selectedFrames,
                                family: family, decorCoverage: coverage, sourceTemplate: "template-\(templateID)",
                                pageIndex: first, pageRole: role, coverCapable: cover)
        let emittedOverlapViolation = clippedDecor.contains { decoration in
            record.slots.contains { slot in
                let width = max(0, min(decoration.x + decoration.width, slot.frame.x + slot.frame.width) - max(decoration.x, slot.frame.x))
                let height = max(0, min(decoration.y + decoration.height, slot.frame.y + slot.frame.height) - max(decoration.y, slot.frame.y))
                let slotArea = slot.frame.width * slot.frame.height
                return slotArea > 0 && width * height > 0.15 * slotArea
            }
        }
        precondition(!emittedOverlapViolation, "Importer emitted \(id) with a decoration covering over 15% of a photo slot")
        return record
    }
}

func closestFrameAsset(windowAspect: Double, candidates: [ImportedFrame]) -> String? {
    guard !candidates.isEmpty, windowAspect.isFinite, windowAspect > 0 else { return nil }
    return candidates.min {
        abs(log(max(0.01, $0.photoWindow.width * Double($0.imageWidth) /
                         ($0.photoWindow.height * Double($0.imageHeight)) / windowAspect))) <
        abs(log(max(0.01, $1.photoWindow.width * Double($1.imageWidth) /
                         ($1.photoWindow.height * Double($1.imageHeight)) / windowAspect)))
    }?.imageAssetID
}

func frameAssetCandidates() throws -> [ImportedFrame] {
    let url = root.appendingPathComponent("Sources/Render/Resources/Assets/frames.json")
    return try JSONDecoder().decode([ImportedFrame].self, from: Data(contentsOf: url))
}

func packDenseLayout(_ slots: [Slot], slideCount: Int, aspect: String) -> [Slot] {
    guard slideCount == 1, slots.count > 12 else { return slots }
    let groupCount = slots.count - 11
    let ordinary = Array(slots.dropLast(groupCount))
    let grouped = Array(slots.suffix(groupCount))
    let minX = grouped.map(\.frame.x).min()!, minY = grouped.map(\.frame.y).min()!
    let maxX = grouped.map { $0.frame.x + $0.frame.width }.max()!
    let maxY = grouped.map { $0.frame.y + $0.frame.height }.max()!
    let frame = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    let rate = aspect == "4:5" ? 0.8 : aspect == "3:4" ? 0.75 : 1.0
    let components = grouped.enumerated().map { i, s in
        Component(frame: s.frame, aspect: s.aspect, z: s.z, rotation: s.rotation, crossesSeam: s.crossesSeam, roleHint: s.roleHint)
    }
    let z = grouped.map(\.z).min() ?? ordinary.count
    let packed = ordinary + [Slot(frame: frame, aspect: frame.width / frame.height * rate, z: z, rotation: 0,
                                  crossesSeam: false, roleHint: grouped.contains(where: { $0.roleHint == "hero" }) ? "hero" : "support",
                                  components: components, cornerRadius: nil)]
    return packed.sorted {
        let a = $0.components?.reduce(0) { $0 + $1.frame.width * $1.frame.height } ?? $0.frame.width * $0.frame.height
        let b = $1.components?.reduce(0) { $0 + $1.frame.width * $1.frame.height } ?? $1.frame.width * $1.frame.height
        return a == b ? $0.z < $1.z : a > b
    }
}

func main() throws {
    let files = try templateFiles()
    let frameCandidates = try frameAssetCandidates()
    var records: [SetRecord] = []
    var pageRecords: [PageRecord] = []
    var pageRejectionCounts: [String: Int] = [:]
    var rejected: [(String, String)] = []
    for file in files {
        let t = try lenientDecode(RawTemplate.self, from: Data(contentsOf: file))
        guard let (width, height, aspect) = canvas(frameType: t.frameType) else { continue }
        let boxes = deduplicated(t.layers.flatMap { placeholderBoxes($0, canvasWidth: width, canvasHeight: height) })
        guard let slots = normalized(boxes, canvasWidth: width, canvasHeight: height, slideCount: t.numberOfFrames, aspect: aspect) else {
            rejected.append(("template-\(t.id)", "empty or degenerate/outside geometry")); continue
        }
        func enrich(_ slots: [Slot], pageSpaceFrames: Bool = false) -> [Slot] {
            let slotCorners: [(Box, Double)] = t.layers.flatMap { layer in
                guard let radius = layer.cornerRadius else { return [(Box, Double)]() }
                return placeholderBoxes(layer, canvasWidth: width, canvasHeight: height, pageSpaceFrames: pageSpaceFrames).map {
                    ($0, min(0.5, max(0, radius / min($0.width, $0.height))))
                }
            }
            return slots.map { slot -> Slot in
                let box = Box(x: slot.frame.x * width, y: slot.frame.y * height,
                              width: slot.frame.width * width, height: slot.frame.height * height)
                let radius = slotCorners.first(where: {
                    abs($0.0.x - box.x) < 0.01 && abs($0.0.y - box.y) < 0.01 &&
                    abs($0.0.width - box.width) < 0.01 && abs($0.0.height - box.height) < 0.01
                })?.1
                return Slot(frame: slot.frame, aspect: slot.aspect, z: slot.z, rotation: slot.rotation,
                            crossesSeam: slot.crossesSeam, roleHint: slot.roleHint,
                            components: slot.components, cornerRadius: radius)
            }
        }
        let enrichedSlots = enrich(slots)
        let textCandidates: [(RawLayer, RawText, Box)] = t.layers.compactMap { layer in
            guard let text = layer.text, let box = directBox(layer.center, layer.size) else { return nil }
            let scale = max(0.01, layer.scaling ?? 1)
            return (layer, text, Box(x: box.x - box.width * (scale - 1) / 2,
                                     y: box.y - box.height * (scale - 1) / 2,
                                     width: box.width * scale, height: box.height * scale))
        }
        let largestText = textCandidates.enumerated().max {
            ($0.element.1.fontSize ?? 0) * ($0.element.0.scaling ?? 1) <
            ($1.element.1.fontSize ?? 0) * ($1.element.0.scaling ?? 1)
        }?.offset
        let texts: [TextLayer] = textCandidates.enumerated().map { index, item in
            let (layer, text, box) = item
            let sample = text.text ?? ""
            let role = isSymbolOnly(sample) ? "accent" : index == largestText ? "title" : "caption"
            return TextLayer(frame: normalizedRect(box, canvasWidth: width, canvasHeight: height),
                             fontID: fontID(text.fontName ?? "Inter-Regular"),
                             size: (text.fontSize ?? 16) * max(0.01, layer.scaling ?? 1),
                             colour: hexColor(text.textColor), alignment: alignment(text.textAlignment),
                             lineSpacing: text.lineSpacing ?? 0, letterSpacing: text.letterSpacing ?? 0,
                             numberOfLines: max(1, text.numberOfLines ?? 1), rotation: layer.rotation ?? 0,
                             role: role)
        }
        let decorBoxes = t.layers.compactMap { layer -> Box? in
            guard layer.image != nil, layer.placeholderCenter == nil else { return nil }
            return directBox(layer.center, layer.size)
        }
        let frames: [FrameLayer] = t.layers.enumerated().compactMap { index, layer in
            guard let center = layer.frameCenter, let size = layer.frameSize, layer.frameImage != nil else { return nil }
            let frameBox = directBox(center, size)!
            let rawPlaceholder = layer.framePlaceholders?.compactMap(rawBox).first
            let windowAspect = rawPlaceholder.map { $0.width / max(0.01, $0.height) } ?? frameBox.width / max(0.01, frameBox.height)
            guard let asset = closestFrameAsset(windowAspect: windowAspect, candidates: frameCandidates) else { return nil }
            let candidate = frameCandidates.first { $0.imageAssetID == asset }
            let photoWindowAspect = candidate.map {
                $0.photoWindow.width * Double($0.imageWidth) /
                max(0.01, $0.photoWindow.height * Double($0.imageHeight))
            }
            return FrameLayer(frame: normalizedRect(frameBox, canvasWidth: width, canvasHeight: height),
                              frameAssetID: asset, slotFrame: rawPlaceholder.map { normalizedRect($0, canvasWidth: width, canvasHeight: height) },
                              photoWindowAspect: photoWindowAspect,
                              z: 100 + index, rotation: layer.rotation ?? 0)
        }
        let templateBackground = "#" + (t.backgroundColor ?? "FFFFFF").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if ["4:5", "3:4", "1:1"].contains(aspect) {
            // Correct frame-local windows for page rescue while keeping legacy sets byte-identical.
            let pageBoxes = deduplicated(t.layers.flatMap {
                placeholderBoxes($0, canvasWidth: width, canvasHeight: height, pageSpaceFrames: true)
            })
            let pageSlots = normalized(pageBoxes, canvasWidth: width, canvasHeight: height,
                                       slideCount: t.numberOfFrames, aspect: aspect, pageRescue: true) ?? []
            let pageFrames = frames.map { frame in
                let window = frame.slotFrame.map {
                    Rect(x: frame.frame.x + $0.x, y: frame.frame.y + $0.y, width: $0.width, height: $0.height)
                }
                return FrameLayer(frame: frame.frame, frameAssetID: frame.frameAssetID, slotFrame: window,
                                  photoWindowAspect: frame.photoWindowAspect, z: frame.z, rotation: frame.rotation)
            }
            pageRecords += pages(templateID: Int(t.id) ?? 0, aspect: aspect, pageCount: t.numberOfFrames,
                                 background: templateBackground, family: t.categoryId ?? "uncategorized",
                                 slots: enrich(pageSlots, pageSpaceFrames: true), texts: texts, frames: pageFrames,
                                 decor: decorBoxes.map { normalizedRect($0, canvasWidth: width, canvasHeight: height) }.map {
                                     Box(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                                 }, rejectionCounts: &pageRejectionCounts)
        }
        let pageArea = width * height * Double(max(1, t.numberOfFrames))
        let decorCoverage = min(1, unionArea(decorBoxes) / max(pageArea, 1))
        let decorOverPhoto = decorBoxes.contains { decor in
            boxes.contains {
                max(decor.x, $0.x) < min(decor.x + decor.width, $0.x + $0.width) &&
                max(decor.y, $0.y) < min(decor.y + decor.height, $0.y + $0.height)
            }
        }
        if decorCoverage > 0.12 || decorOverPhoto {
            rejected.append(("template-\(t.id)", decorOverPhoto ? "decor intersects photo slot" : "decor coverage \(decorCoverage)"))
            continue
        }
        records.append(SetRecord(id: "17v28-template-\(t.id)", sourceRef: "17v28:template-\(t.id)", aspect: aspect,
                                 slideCount: t.numberOfFrames, background: templateBackground,
                                 slots: enrichedSlots, version: libraryVersion, texts: texts.isEmpty ? nil : texts,
                                 frames: frames.isEmpty ? nil : frames, family: t.categoryId ?? "uncategorized",
                                 decorCoverage: decorCoverage))
    }

    let layoutsURL = source.appendingPathComponent("layouts.json")
    let layouts = try lenientDecode([RawLayout].self, from: Data(contentsOf: layoutsURL))
    for layout in layouts {
        let boxes = layout.placeholders.map { p in Box(x: p.frame.origin.x, y: p.frame.origin.y, width: p.frame.size.width, height: p.frame.size.height) }
        guard let slots = normalized(boxes, canvasWidth: 1, canvasHeight: 1, slideCount: 1, aspect: "4:5", unitSpace: true) else {
            rejected.append(("layout-\(layout.id)", "empty or degenerate/outside geometry")); continue
        }
        records.append(SetRecord(id: "17v28-layout-\(layout.id)", sourceRef: "17v28:layout-\(layout.id)", aspect: "4:5",
                                 slideCount: 1, background: "#FFFFFF", slots: packDenseLayout(slots, slideCount: 1, aspect: "4:5"),
                                 version: libraryVersion, texts: nil, frames: nil, family: "layouts", decorCoverage: 0))
    }
    records.sort { $0.id < $1.id }
    let frameInference = "Canvas width is 216pt. Single-frame portrait templates with full-bleed placeholders consistently measure 216×270pt (4:5); square measures 216×216pt. portrait2 is mapped to 216×288pt (3:4), supported by full-height placeholders measuring 216×288pt in multi-frame template-196; its sole single-frame example (template-201) has an inset 216×162.7pt placeholder and does not reveal canvas bounds. Multi-frame coordinates are treated as one continuous canvas whose width is frame width × numberOfFrames. Layouts use their supplied unit square. Source files are decoded after removing trailing commas; no raw source data is included."
    let library = Library(version: libraryVersion, frameInference: frameInference,
        sets: records)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(library).write(to: output)
    let pagesURL = output.deletingLastPathComponent().appendingPathComponent("designed-pages.json")
    let pageLibrary = PageLibrary(version: libraryVersion, frameInference: frameInference, sets: pageRecords.sorted { $0.id < $1.id })
    try encoder.encode(pageLibrary).write(to: pagesURL)
    try renderContactSheets(records, prefix: "sets")
    try renderContactSheets(pageRecords.map {
        SetRecord(id: $0.id, sourceRef: $0.sourceRef, aspect: $0.aspect, slideCount: $0.slideCount,
                  background: $0.background, slots: $0.slots, version: $0.version, texts: $0.texts,
                  frames: $0.frames, family: $0.family, decorCoverage: $0.decorCoverage)
    }, prefix: "pages")
    let pageCounts = Dictionary(grouping: pageRecords, by: \.aspect).mapValues(\.count)
    print("Imported \(pageRecords.count) pages (\(pageCounts["4:5", default: 0]) 4:5, \(pageCounts["3:4", default: 0]) 3:4, \(pageCounts["1:1", default: 0]) 1:1)")
    for aspect in ["4:5", "3:4", "1:1"] {
        let matching = pageRecords.filter { $0.aspect == aspect }
        print("\(aspect) records: \(matching.filter { $0.slideCount == 1 }.count) single pages, \(matching.filter { $0.slideCount > 1 }.count) linked runs")
    }
    print("Rejected page groups by reason: \(pageRejectionCounts)")
    print("Imported \(records.count) sets (\(records.filter { $0.sourceRef.contains(":template-") }.count) templates, \(layouts.count) layouts); rejected \(rejected.count): \(rejected)")
    print("Wrote \(output.path)")
}

func renderContactSheets(_ records: [SetRecord], prefix: String) throws {
    for aspect in ["3:4", "4:5", "1:1"] {
        let subset = records.filter { $0.aspect == aspect }
        guard !subset.isEmpty else { continue }
        let cols = 6, rows = (subset.count + cols - 1) / cols
        let cellW = 190, cellH = 260, margin = 20
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols * cellW + margin * 2,
            pixelsHigh: rows * cellH + margin * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh)).fill()
        for (idx, record) in subset.enumerated() {
            let cx = margin + (idx % cols) * cellW, cy = margin + (idx / cols) * cellH
            let totalPreviewWidth: CGFloat = 142, ratio: CGFloat = aspect == "3:4" ? 0.75 : aspect == "4:5" ? 0.8 : 1
            let slideW = totalPreviewWidth / CGFloat(record.slideCount)
            let slideH = totalPreviewWidth / ratio
            for slide in 0..<record.slideCount {
                let x0 = CGFloat(cx) + CGFloat(slide) * slideW
                let y0 = CGFloat(cy) + 8
                NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: x0, y: y0, width: slideW, height: slideH)).fill()
                NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
                let border = NSBezierPath(rect: NSRect(x: x0, y: y0, width: slideW, height: slideH)); border.lineWidth = 1; border.stroke()
                if slide > 0 { let seam = NSBezierPath(); seam.move(to: NSPoint(x: x0, y: y0)); seam.line(to: NSPoint(x: x0, y: y0 + slideH)); seam.lineWidth = 1; seam.stroke() }
            }
            for (slotIndex, slot) in record.slots.enumerated() {
                let displayedParts = slot.components?.map { ($0.frame, $0.z) } ?? [(slot.frame, slotIndex)]
                for (partFrame, partOrder) in displayedParts {
                let f = partFrame, scaleX = slideW, scaleY = slideH
                let rect = NSRect(x: CGFloat(cx) + CGFloat(f.x) * scaleX,
                                  y: CGFloat(cy + 8) + (1 - CGFloat(f.y + f.height)) * scaleY,
                                  width: CGFloat(f.width) * scaleX, height: CGFloat(f.height) * scaleY)
                NSColor(calibratedWhite: 0.7, alpha: 0.7).setFill(); NSBezierPath(rect: rect).fill()
                NSColor.darkGray.setStroke(); let outline = NSBezierPath(rect: rect); outline.lineWidth = 1; outline.stroke()
                let label = "\(partOrder + 1)" as NSString
                label.draw(at: NSPoint(x: rect.midX - 4, y: rect.midY - 7), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.black])
                }
            }
            (record.id as NSString).draw(at: NSPoint(x: cx, y: cy + 8 + Int(totalPreviewWidth / ratio) + 12), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let dest = URL(fileURLWithPath: "/tmp/ak14-designed-\(prefix)-\(aspect.replacingOccurrences(of: ":", with: "x")).png")
        try image.representation(using: .png, properties: [:])!.write(to: dest)
        print("Preview: \(dest.path)")
    }
}

try main()

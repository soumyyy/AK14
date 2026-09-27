import Foundation

/// Fills a validated style recipe with the photos and grounded text from a composed plan.
public enum RecipeFiller {
    public static let minimumAxisScore = 0.48

    public static func select(for style: StyleVector, recipes: [Recipe], seed: UInt64) -> Recipe? {
        guard style.normalized != .baseline else { return nil }
        let scored = recipes.map { recipe in (recipe, score(recipe, style)) }
        guard let best = scored.map(\.1).max(), best >= minimumAxisScore else { return nil }
        let ties = scored.filter { abs($0.1 - best) < 0.000001 }.sorted { $0.0.id < $1.0.id }
        return ties[Int(seed % UInt64(ties.count))].0
    }

    private static func score(_ recipe: Recipe, _ style: StyleVector) -> Double {
        let values: [(String, Double)] = [
            ("decoration", style.decoration == "rich" ? 1 : style.decoration == "light" ? 0.5 : 0),
            ("whitespace", style.whitespace == "airy" ? 1 : 0),
            ("density", style.density == "dense" ? 1 : style.density == "quiet" ? 0 : 0.5),
            ("overlap", style.overlap == "bold" ? 1 : style.overlap == "some" ? 0.5 : 0),
        ]
        let terms = values.compactMap { name, value -> Double? in recipe.axes[name].map { 1 - abs($0 - value) } }
        return terms.isEmpty ? 0 : terms.reduce(0, +) / Double(terms.count)
    }

    public static func fill(plan: CarouselPlan, direction: Direction, recipe: Recipe,
                            context: CompositionContext, seed: UInt64) -> CanvasDocument {
        let slides = max(1, plan.slides.count), seamless = direction.seamless || recipe.family == .panorama
        var rng = SeededRandom(seed: seed), layers: [DocumentLayer] = [], backgrounds: [String] = []
        let pages = recipe.pages
        for (index, slide) in plan.slides.enumerated() {
            let role: Recipe.SlideRole = index == 0 ? .cover : index == slides - 1 ? .closer : .body
            let rolePages = pages.filter { $0.role == role }
            let bodyPages = pages.filter { $0.role == .body }
            let candidates = rolePages.isEmpty ? bodyPages : rolePages
            let page = candidates.min { abs($0.photoSlots.count - slide.photos.count) < abs($1.photoSlots.count - slide.photos.count) }
                ?? pages.first!
            backgrounds.append(page.background.kind == .paper ? "paper" : "plain")
            let slots = adapted(page.photoSlots, count: slide.photos.count)
            let ordered = slide.photos.sorted { a, b in
                if a.assetID == direction.coverAssetID { return true }
                if b.assetID == direction.coverAssetID { return false }
                return a.role == "hero" && b.role != "hero"
            }
            for (slotIndex, pair) in zip(slots, ordered).enumerated() {
                let (slot, photo) = pair
                guard let record = context.photos[photo.assetID] else { continue }
                let aspect = Double(record.pixelWidth) / max(1, Double(record.pixelHeight))
                let canvasAspect = Double(context.aspect.exportWidth) / Double(context.aspect.exportHeight)
                var crop = CropPlanner.cover(imageAspect: aspect, boxAspect: canvasAspect * slot.frame.width / slot.frame.height,
                                             features: context.features[photo.assetID], cropIntent: photo.cropIntent, anchorIntent: photo.anchorIntent)
                if !CropPlanner.facesFit(context.features[photo.assetID], crop: crop) {
                    crop = UnitRect(x: 0, y: 0, width: 1, height: 1)
                }
                guard CropPlanner.facesFit(context.features[photo.assetID], crop: crop) else { continue }
                var frame = UnitRect(x: (Double(index) + slot.frame.x) / Double(slides), y: slot.frame.y,
                                     width: slot.frame.width / Double(slides), height: slot.frame.height)
                if seamless, slot.allowCrossSlide {
                    // Nudge a flowing print away from a seam whenever a detected face would cross the cut.
                    for _ in 0..<20 {
                        let canvas = Box(x: frame.x * Double(slides), y: frame.y,
                                         w: frame.width * Double(slides), h: frame.height)
                        let crosses = CropPlanner.facesOnCanvas(context.features[photo.assetID], crop: crop, frame: canvas)
                            .contains { face in
                                (1..<slides).contains { boundary in
                                    let x = Double(boundary)
                                    return face.x < x && face.maxX > x
                                }
                            }
                        if !crosses { break }
                        frame = UnitRect(x: frame.x + 0.012 / Double(slides), y: frame.y, width: frame.width, height: frame.height)
                    }
                }
                layers.append(DocumentLayer(id: "photo-\(index)-\(slotIndex)", kind: .photo, frame: frame,
                    rotation: slot.rotationMin == slot.rotationMax ? slot.rotationMin : rng.range(slot.rotationMin, slot.rotationMax),
                    z: slot.z, slideHint: seamless ? nil : index, assetID: photo.assetID, crop: crop,
                    mask: slot.mask == .rounded ? .rounded : slot.mask == .torn ? .torn : .rect))
            }
            for textSlot in page.textSlots {
                let value: String? = switch textSlot.role {
                case .title: direction.titleIdea?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? context.storyHint.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }.flatMap(\.nilIfEmpty)
                case .date: slide.photos.first.flatMap { context.photos[$0.assetID]?.metadata.capturedAt }?.formatted(date: .abbreviated, time: .omitted)
                case .place, .caption: nil
                }
                guard let value else { continue }
                let frame = UnitRect(x: (Double(index) + 0.08) / Double(slides), y: 0.83, width: 0.84 / Double(slides), height: 0.1)
                layers.append(DocumentLayer(id: "text-\(index)-\(textSlot.role)", kind: .text, frame: frame,
                    z: 20, slideHint: seamless ? nil : index, string: value, fontID: textSlot.fontID,
                    size: (textSlot.sizeMin + textSlot.sizeMax) / 2, colour: "#24221E", alignment: textSlot.alignment.rawValue))
            }
            // Keep accents in the outer margin, clear of photo and face boxes, with a conservative area cap.
            for budget in page.stickerBudget where budget.count > 0 {
                let ids = stickerIDs(for: budget.category)
                guard !ids.isEmpty else { continue }
                for n in 0..<min(2, budget.count) {
                    let edge = rng.bool()
                    let w = 0.11 / Double(slides), h = 0.06
                    let x = (Double(index) + (edge ? 0.02 : 0.87)) / Double(slides), y = n == 0 ? 0.02 : 0.91
                    let frame = UnitRect(x: x, y: y, width: w, height: h)
                    guard !layers.contains(where: { $0.kind == .photo && overlaps(frame, $0.frame) }) else { continue }
                    layers.append(DocumentLayer(id: "sticker-\(index)-\(budget.category)-\(n)", kind: .sticker, frame: frame,
                        z: 30, slideHint: seamless ? nil : index, assetID: AssetID(rawValue: ids[Int(rng.next() % UInt64(ids.count))])))
                }
            }
        }
        let background: Fill = recipe.pages.first?.background.kind == .paper ? .paper(nil) : .colour("#F4F1EA")
        return CanvasDocument(id: plan.id, aspect: context.aspect, slideCount: slides, seamless: seamless, background: background,
            layers: layers, recipeID: recipe.id, stylePackPin: "\(context.stylePack.id)@\(context.stylePack.version)",
            sourcePlanID: plan.id, version: "document-1", slideBackgrounds: backgrounds,
            seed: String(seed, radix: 16))
    }

    private static func adapted(_ slots: [Recipe.PhotoSlot], count: Int) -> [Recipe.PhotoSlot] {
        guard !slots.isEmpty else { return [] }
        if count <= slots.count { return Array(slots.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }.prefix(count)) }
        return (0..<count).map { i in
            var slot = slots[i % slots.count]
            let cols = count > 2 ? 2.0 : Double(count), rows = ceil(Double(count) / cols)
            slot.frame = Recipe.Frame(x: Double(i % Int(cols)) / cols, y: Double(i / Int(cols)) / rows,
                                      width: 1 / cols, height: 1 / rows)
            return slot
        }
    }
    private static func overlaps(_ a: UnitRect, _ b: UnitRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }
    private static func stickerIDs(for category: Recipe.StickerCategory) -> [String] {
        switch category {
        case .tape: ["tape-washi-cream", "tape-washi-sage"]
        case .paper: ["paper-kraft", "paper-cotton"]
        case .film: ["film-frame-35mm", "instant-frame-classic"]
        case .doodle: ["doodle-star", "doodle-heart", "doodle-sparkle"]
        case .label: ["label-blank", "label-rounded"]
        case .texture: ["grain-fine", "dust-sparse"]
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

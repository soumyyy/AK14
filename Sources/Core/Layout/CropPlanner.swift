import Foundation

/// Chooses source crops so faces (then salient subjects) stay in frame.
public enum CropPlanner {
    /// People large enough to matter in the frame (small background figures are ignored).
    static func significantPeople(_ f: PhotoFeatures?) -> [UnitRect] {
        (f?.humans ?? []).filter { $0.height >= 0.2 }
    }

    /// Faces union if any, else the largest salient region, else nil (centre). With faces, the horizontal extent
    /// also covers significant people so group shots are centred on everyone, not just their faces.
    public static func focus(_ f: PhotoFeatures?) -> UnitRect? {
        if let faces = f?.faces.map(\.box), !faces.isEmpty {
            let people = significantPeople(f)
            guard !people.isEmpty else { return union(faces) }
            let wide = union(faces + people), heads = union(faces)
            return UnitRect(x: wide.x, y: heads.y, width: wide.width, height: heads.height)
        }
        if let people = Optional(significantPeople(f)), !people.isEmpty { return union(people) }
        return f?.salientRegions.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Cover crop of an image with aspect `imageAspect` (w/h) into a box with aspect `boxAspect`,
    /// centred on the focus and clamped inside the image. Returns source-normalized coordinates.
    public static func cover(imageAspect: Double, boxAspect: Double, features: PhotoFeatures?,
                             cropIntent: String = "balanced", anchorIntent: String = "center") -> UnitRect {
        var cw = 1.0, ch = 1.0
        if imageAspect > boxAspect { cw = boxAspect / imageAspect } else { ch = imageAspect / boxAspect }
        let hasFaces = !(features?.faces.isEmpty ?? true)
        let f = focus(features)
        // Tight crops zoom in on the subject, but never so far that faces are cut.
        if cropIntent == "tight", let f {
            let zoom = min(1.3, max(1, min(cw / max(f.width * 1.4, 0.01), ch / max(f.height * 1.4, 0.01))))
            cw /= zoom; ch /= zoom
        }
        var fx = f.map { $0.x + $0.width / 2 } ?? 0.5
        var fy = f.map { $0.y + $0.height / 2 } ?? 0.5
        switch anchorIntent {
        case "top": fy -= 0.12
        case "bottom": fy += 0.12
        case "left": fx -= 0.12
        case "right": fx += 0.12
        default: break
        }
        var x = fx - cw / 2, y = fy - ch / 2
        if hasFaces, let f {
            // Anchor shifts and tight zoom must never push a face out when the faces can fit.
            if f.width <= cw { x = min(max(x, f.x + f.width - cw), f.x) }
            if f.height <= ch { y = min(max(y, f.y + f.height - ch), f.y) } else { y = f.y - ch * 0.05 }  // heads over chins
        }
        x = min(max(0, x), 1 - cw); y = min(max(0, y), 1 - ch)
        return UnitRect(x: x, y: y, width: cw, height: ch)
    }

    /// True when every face is fully inside the crop and no significant person is cut at the sides
    /// (at most 12% of their width) or loses their head / more than 40% of their height.
    public static func facesFit(_ f: PhotoFeatures?, crop: UnitRect) -> Bool {
        let facesIn = (f?.faces ?? []).allSatisfy {
            $0.box.x >= crop.x - 0.01 && $0.box.y >= crop.y - 0.01 &&
            $0.box.x + $0.box.width <= crop.x + crop.width + 0.01 && $0.box.y + $0.box.height <= crop.y + crop.height + 0.01
        }
        let peopleIn = significantPeople(f).allSatisfy { h in
            let cutLeft = max(0, crop.x - h.x), cutRight = max(0, (h.x + h.width) - (crop.x + crop.width))
            let visibleTop = max(h.y, crop.y), visibleBottom = min(h.y + h.height, crop.y + crop.height)
            return cutLeft <= 0.12 * h.width && cutRight <= 0.12 * h.width
                && h.y >= crop.y - 0.02 && (visibleBottom - visibleTop) >= 0.6 * h.height
        }
        return facesIn && peopleIn
    }

    /// Face boxes mapped into canvas pixels for a photo drawn with `crop` into `frame`.
    public static func facesOnCanvas(_ f: PhotoFeatures?, crop: UnitRect, frame: Box) -> [Box] {
        (f?.faces ?? []).compactMap { face in
            let b = face.box
            let x = (b.x - crop.x) / crop.width, y = (b.y - crop.y) / crop.height
            let box = Box(x: frame.x + x * frame.w, y: frame.y + y * frame.h,
                          w: b.width / crop.width * frame.w, h: b.height / crop.height * frame.h)
            let clipped = box.intersection(frame)
            return clipped.area > 0 ? clipped : nil
        }
    }

    static func union(_ rects: [UnitRect]) -> UnitRect {
        let x0 = rects.map(\.x).min()!, y0 = rects.map(\.y).min()!
        let x1 = rects.map { $0.x + $0.width }.max()!, y1 = rects.map { $0.y + $0.height }.max()!
        return UnitRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

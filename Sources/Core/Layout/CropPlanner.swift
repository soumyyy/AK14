import Foundation

/// Chooses source crops so faces (then salient subjects) stay in frame.
public enum CropPlanner {
    /// Faces union if any, else the largest salient region, else nil (centre).
    public static func focus(_ f: PhotoFeatures?) -> UnitRect? {
        if let faces = f?.faces.map(\.box), !faces.isEmpty { return union(faces) }
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
        if hasFaces, let f, f.height > ch { y = f.y - ch * 0.05 }   // keep heads rather than chins
        x = min(max(0, x), 1 - cw); y = min(max(0, y), 1 - ch)
        return UnitRect(x: x, y: y, width: cw, height: ch)
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

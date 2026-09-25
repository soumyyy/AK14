import Core
import Foundation
import ImageIO

public struct ImageMetadata: Sendable, Equatable {
    public let pixelWidth: Int     // oriented
    public let pixelHeight: Int    // oriented
    public let exifOrientation: Int
    public let capture: CaptureMetadata
}

public enum MetadataReader {
    /// Returns nil when ImageIO cannot fully read the image header/properties.
    public static func read(_ url: URL) -> ImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawW = props[kCGImagePropertyPixelWidth] as? Int,
              let rawH = props[kCGImagePropertyPixelHeight] as? Int, rawW > 0, rawH > 0
        else { return nil }

        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let (date, assumed) = parseDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                                        offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        let capture = CaptureMetadata(
            capturedAt: date,
            timeZoneAssumed: assumed,
            location: gpsPoint(props[kCGImagePropertyGPSDictionary] as? [CFString: Any]),
            cameraModel: (tiff[kCGImagePropertyTIFFModel] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isScreenshot: (exif[kCGImagePropertyExifUserComment] as? String) == "Screenshot"
        )
        return ImageMetadata(pixelWidth: swapped ? rawH : rawW, pixelHeight: swapped ? rawW : rawH,
                             exifOrientation: orientation, capture: capture)
    }

    /// EXIF "yyyy:MM:dd HH:mm:ss" + optional "+05:30". Without an offset, uses the current
    /// time zone and returns `assumed = true`. Invalid or missing dates return (nil, false).
    static func parseDate(_ raw: String?, offset: String?) -> (Date?, Bool) {
        guard let raw else { return (nil, false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        var assumed = true
        if let offset, let tz = timeZone(fromOffset: offset) {
            formatter.timeZone = tz
            assumed = false
        } else {
            formatter.timeZone = .current
        }
        guard let date = formatter.date(from: raw) else { return (nil, false) }
        return (date, assumed)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let pattern = /^([+-])(\d{2}):(\d{2})$/
        guard let m = offset.wholeMatch(of: pattern), let h = Int(m.2), let mm = Int(m.3) else { return nil }
        let seconds = (h * 3600 + mm * 60) * (m.1 == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func gpsPoint(_ gps: [CFString: Any]?) -> GeoPoint? {
        guard let gps,
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latSign = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1.0 : 1.0
        let lonSign = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1.0 : 1.0
        return GeoPoint(latitude: lat * latSign, longitude: lon * lonSign)
    }
}

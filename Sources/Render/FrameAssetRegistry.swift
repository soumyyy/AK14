import Core
import CoreGraphics
import Foundation
import ImageIO

public enum FrameAssetRegistry {
    private static let values: [String: FrameAsset] = {
        guard let url = Bundle.module.url(forResource: "frames", withExtension: "json", subdirectory: "Assets"),
              let data = try? Data(contentsOf: url),
              let frames = try? JSONDecoder().decode([FrameAsset].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: frames.map { ($0.imageAssetID, $0) })
    }()

    public static func asset(imageAssetID: String) -> FrameAsset? { values[imageAssetID] }
    public static var all: [FrameAsset] { values.values.sorted { $0.id < $1.id } }

    public static func image(imageAssetID: String) -> CGImage? {
        guard let frame = values[imageAssetID],
              let url = Bundle.module.url(forResource: frame.imageAssetID.hasPrefix("frame-") ? String(frame.imageAssetID.dropFirst(6)) : frame.imageAssetID,
                                          withExtension: "png", subdirectory: "Assets/frames"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

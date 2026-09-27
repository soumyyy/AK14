import Foundation

/// A licensed decorative frame with its photo opening normalized to the image bounds.
public struct FrameAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var category: String
    public var imageAssetID: String
    public var imageWidth: Int
    public var imageHeight: Int
    public var photoWindow: UnitRect

    public init(id: String, category: String, imageAssetID: String, imageWidth: Int, imageHeight: Int, photoWindow: UnitRect) {
        self.id = id; self.category = category; self.imageAssetID = imageAssetID
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.photoWindow = photoWindow
    }

    public var windowAspect: Double { photoWindow.width * Double(imageWidth) / (photoWindow.height * Double(imageHeight)) }
}

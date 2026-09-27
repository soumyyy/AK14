import Core
import CoreGraphics
import CoreImage

/// Shared Core Image path for photo adjustments (legacy slides and document layers).
enum PhotoAdjustmentFilter {
    static let context = CIContext(options: [.useSoftwareRenderer: true])

    static func apply(to image: CGImage, adjustments: PhotoAdjustments?) -> CGImage {
        guard let a = adjustments else { return image }
        var ci = CIImage(cgImage: image)
        if a.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.contrast != 0 {
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + a.contrast])
        }
        if a.saturation != 0 {
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + a.saturation])
        }
        // A higher source neutral warms the image: positive warmth means warmer (verified on a grey patch).
        if a.warmth != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500 + a.warmth * 1000, y: 0)])
        }
        return context.createCGImage(ci, from: ci.extent) ?? image
    }
}

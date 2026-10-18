import AVFoundation
import CoreImage
import Foundation

/// Applies color grading as a second pass over an already-rendered video.
///
/// Grading can vary over time: each `Span` maps a time range of the output to a
/// `Look`, so the user can grade the whole video one way ("full video") or give
/// different clips/sections different looks. If every span is `.none`, the input
/// is returned untouched (no re-encode).
struct ColorGrader {

    struct Span {
        let start: Double
        let end: Double
        let look: Look
    }

    func grade(url: URL, spans: [Span], onProgress: @escaping @Sendable (Float) -> Void) async throws -> URL {
        guard spans.contains(where: { $0.look != .none }) else { return url }

        let asset = AVURLAsset(url: url)
        let context = CIContext(options: nil)

        // Resolve the look for a given time (first matching span, else original).
        func look(at time: Double) -> Look {
            for span in spans where time >= span.start && time < span.end {
                return span.look
            }
            return spans.last?.look ?? .none
        }

        let videoComposition = AVMutableVideoComposition(asset: asset) { request in
            let look = look(at: request.compositionTime.seconds)
            let output = ColorGrader.apply(look, to: request.sourceImage)
            request.finish(with: output, context: context)
        }

        return try await VideoComposer().export(asset, videoComposition: videoComposition, onProgress: onProgress)
    }

    /// Builds the CIImage for a look. Color filters preserve the image extent, so
    /// the output matches the composition's render size.
    static func apply(_ look: Look, to image: CIImage) -> CIImage {
        switch look {
        case .none:
            return image
        case .vivid:
            return image
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.35,
                    kCIInputContrastKey: 1.08
                ])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35])
        case .warm:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5200, y: 0)
            ])
        case .cool:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 8200, y: 0)
            ])
        case .cinematic:
            return image
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.12,
                    kCIInputSaturationKey: 1.05
                ])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5800, y: -12)
                ])
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .vintage:
            return image.applyingFilter("CIPhotoEffectInstant")
        }
    }
}

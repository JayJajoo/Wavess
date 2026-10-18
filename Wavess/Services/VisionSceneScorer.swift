import AVFoundation
import CoreGraphics
import Vision

/// Scores each detected scene by on-device visual quality using the Vision
/// framework — image aesthetics (iOS 18+) plus saliency ("is there a clear,
/// confident subject"). This moves highlight selection beyond "how much the
/// pixels change" toward "how good / meaningful the shot actually looks."
///
/// One representative frame (the scene's midpoint) is scored per scene. All
/// values are `0...1`; everything fails soft (a scene that can't be scored just
/// gets 0 and falls back to the motion score), so this can never regress or
/// crash the analysis pipeline.
struct VisionSceneScorer {

    /// Content score in `0...1` for each scene, in the same order.
    func score(asset: AVURLAsset, scenes: [Scene]) async -> [Double] {
        guard !scenes.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var scores = [Double](repeating: 0, count: scenes.count)
        for (index, scene) in scenes.enumerated() {
            let midpoint = (scene.start + scene.end) / 2
            guard let image = try? await cgImage(generator, atSeconds: midpoint) else { continue }
            scores[index] = contentScore(for: image)
        }
        return scores
    }

    private func cgImage(_ generator: AVAssetImageGenerator, atSeconds seconds: Double) async throws -> CGImage {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    private func contentScore(for image: CGImage) -> Double {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Saliency: how much of the frame is a clear, confident subject.
        var saliency = 0.0
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        if (try? handler.perform([saliencyRequest])) != nil,
           let observation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
           let objects = observation.salientObjects, !objects.isEmpty {
            let coverage = objects.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
            let confidence = objects.reduce(0.0) { $0 + Double($1.confidence) } / Double(objects.count)
            saliency = min(1, coverage) * confidence
        }

        // Aesthetics (iOS 18+): overall "how good does this shot look."
        if #available(iOS 18.0, *) {
            let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
            if (try? handler.perform([aestheticsRequest])) != nil,
               let observation = aestheticsRequest.results?.first as? VNImageAestheticsScoresObservation {
                // overallScore is roughly -1...1; map to 0...1.
                var aesthetic = Double((observation.overallScore + 1) / 2)
                if observation.isUtility { aesthetic *= 0.3 }  // screenshots / documents / junk
                return max(0, min(1, 0.7 * aesthetic + 0.3 * saliency))
            }
        }

        // Pre-iOS 18, or aesthetics unavailable: fall back to saliency alone.
        return saliency
    }
}

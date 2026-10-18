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

    /// How many scenes to actually run Vision on per clip. A long clip can have
    /// hundreds of scenes; scoring every one across a large batch is what blows
    /// memory/time, so we evenly sample up to this many and give the rest the
    /// average (neutral) score.
    private let maxScenesScored = 16

    /// Content score in `0...1` for each scene, in the same order.
    func score(asset: AVURLAsset, scenes: [Scene]) async -> [Double] {
        guard !scenes.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 384)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // Pick which scene indices to score (evenly sampled when there are many).
        let indices: [Int]
        if scenes.count <= maxScenesScored {
            indices = Array(scenes.indices)
        } else {
            indices = (0..<maxScenesScored).map {
                Int((Double($0) * Double(scenes.count - 1) / Double(maxScenesScored - 1)).rounded())
            }
        }

        var scores = [Double](repeating: -1, count: scenes.count)
        var scored: [Double] = []
        for i in indices {
            let midpoint = (scenes[i].start + scenes[i].end) / 2
            guard let image = try? await cgImage(generator, atSeconds: midpoint) else { continue }
            // Release each frame's Vision/Core Graphics memory before the next —
            // essential when a batch has dozens of clips.
            let value = autoreleasepool { contentScore(for: image) }
            scores[i] = value
            scored.append(value)
        }

        // Fill any unscored scenes with the average so they aren't unfairly dropped.
        let average = scored.isEmpty ? 0 : scored.reduce(0, +) / Double(scored.count)
        for i in scores.indices where scores[i] < 0 { scores[i] = average }
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

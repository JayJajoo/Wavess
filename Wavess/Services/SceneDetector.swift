import AVFoundation
import CoreGraphics
import Foundation

/// Detects shot/scene boundaries by sampling frames and comparing them.
///
/// Frames are generated at `settings.sampleFPS`, downscaled to small grayscale
/// signatures, and compared consecutively. A large frame-to-frame difference
/// marks a cut. The stretches between cuts become scenes, each scored by how
/// much visual change happens inside it — the basis for highlight selection.
struct SceneDetector {

    func detectScenes(in asset: AVURLAsset, total: CMTime, settings: AnalysisSettings) async throws -> [Scene] {
        let totalSeconds = total.seconds
        guard totalSeconds > 0 else { return [] }

        // Build the list of sample times.
        let step = 1.0 / max(0.5, settings.sampleFPS)
        var times: [CMTime] = []
        var t = 0.0
        while t < totalSeconds {
            times.append(CMTime(seconds: t, preferredTimescale: TimeRangeMath.timescale))
            t += step
        }
        guard times.count >= 2 else {
            // Too short to segment — treat the whole clip as one scene.
            return [Scene(range: CMTimeRange(start: .zero, end: total), score: 1, isSelected: true)]
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 96)
        generator.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: TimeRangeMath.timescale)
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: TimeRangeMath.timescale)

        let frames = await generateSignatures(generator: generator, times: times)
        guard frames.count >= 2 else {
            return [Scene(range: CMTimeRange(start: .zero, end: total), score: 1, isSelected: true)]
        }

        // Map sensitivity (0...1) to a frame-difference threshold.
        // High sensitivity => low threshold => more cuts.
        let threshold = 0.35 - 0.30 * settings.sceneSensitivity

        // Difference series keyed by the time of the *second* frame in each pair.
        var diffs: [(time: Double, diff: Double)] = []
        var cutTimes: [Double] = [0.0]
        for i in 1..<frames.count {
            let diff = meanAbsDifference(frames[i - 1].signature, frames[i].signature)
            diffs.append((frames[i].time, diff))
            if diff > threshold {
                cutTimes.append(frames[i].time)
            }
        }
        cutTimes.append(totalSeconds)

        // De-duplicate and sort boundary times.
        let boundaries = Array(Set(cutTimes)).sorted()

        var scenes: [Scene] = []
        for i in 0..<(boundaries.count - 1) {
            let startSeconds = boundaries[i]
            let endSeconds = boundaries[i + 1]
            guard endSeconds > startSeconds else { continue }

            // Average visual motion within the scene.
            let inside = diffs.filter { $0.time > startSeconds && $0.time <= endSeconds }
            let meanMotion = inside.isEmpty ? 0 : inside.map(\.diff).reduce(0, +) / Double(inside.count)

            // Weight motion by (log-scaled) length so a single flashy frame
            // doesn't beat a sustained interesting shot.
            let duration = endSeconds - startSeconds
            let score = (meanMotion + 0.01) * log(1 + duration)

            scenes.append(Scene(
                range: CMTimeRange(
                    start: TimeRangeMath.time(startSeconds),
                    end: TimeRangeMath.time(endSeconds)
                ),
                score: score
            ))
        }

        return scenes
    }

    // MARK: - Frame generation

    private struct FrameSignature {
        let time: Double
        let signature: [UInt8]
    }

    /// Generates downscaled grayscale signatures for every requested time,
    /// returned in ascending time order.
    private func generateSignatures(generator: AVAssetImageGenerator, times: [CMTime]) async -> [FrameSignature] {
        await withCheckedContinuation { continuation in
            var collected: [FrameSignature] = []
            let lock = NSLock()
            var remaining = times.count

            generator.generateCGImagesAsynchronously(forTimes: times.map { NSValue(time: $0) }) { requested, image, _, result, _ in
                var signature: [UInt8]? = nil
                if result == .succeeded, let image {
                    signature = image.grayscaleSignature()
                }

                lock.lock()
                if let signature {
                    collected.append(FrameSignature(time: requested.seconds, signature: signature))
                }
                remaining -= 1
                let done = remaining <= 0
                lock.unlock()

                if done {
                    collected.sort { $0.time < $1.time }
                    continuation.resume(returning: collected)
                }
            }
        }
    }
}

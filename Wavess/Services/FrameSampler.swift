import AVFoundation
import CoreGraphics
import Foundation

/// A single sampled frame reduced to a tiny grayscale signature for cheap
/// comparison.
struct SampledFrame {
    let time: Double
    let signature: [UInt8]
}

/// Samples frames from a video at a fixed rate and reduces each to a grayscale
/// signature. This one pass feeds every visual analyzer (scene detection and
/// still/low-motion detection), so we never decode frames twice.
struct FrameSampler {

    func sample(asset: AVURLAsset, total: CMTime, fps: Double) async -> [SampledFrame] {
        let totalSeconds = total.seconds
        guard totalSeconds > 0 else { return [] }

        let step = 1.0 / max(0.5, fps)
        var times: [CMTime] = []
        var t = 0.0
        while t < totalSeconds {
            times.append(CMTime(seconds: t, preferredTimescale: TimeRangeMath.timescale))
            t += step
        }
        guard !times.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 96)
        generator.requestedTimeToleranceBefore = CMTime(seconds: step / 2, preferredTimescale: TimeRangeMath.timescale)
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: TimeRangeMath.timescale)

        return await withCheckedContinuation { continuation in
            var collected: [SampledFrame] = []
            let lock = NSLock()
            var remaining = times.count

            generator.generateCGImagesAsynchronously(forTimes: times.map { NSValue(time: $0) }) { requested, image, _, result, _ in
                var signature: [UInt8]? = nil
                if result == .succeeded, let image {
                    signature = image.grayscaleSignature()
                }

                lock.lock()
                if let signature {
                    collected.append(SampledFrame(time: requested.seconds, signature: signature))
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

    /// Visual change between consecutive frames (normalized `0...1`), keyed by
    /// the later frame's time. This is the raw signal both the scene and still
    /// detectors work from.
    static func motionSeries(_ frames: [SampledFrame]) -> [(time: Double, motion: Double)] {
        guard frames.count >= 2 else { return [] }
        var series: [(time: Double, motion: Double)] = []
        series.reserveCapacity(frames.count - 1)
        for i in 1..<frames.count {
            let diff = meanAbsDifference(frames[i - 1].signature, frames[i].signature)
            series.append((time: frames[i].time, motion: diff))
        }
        return series
    }
}

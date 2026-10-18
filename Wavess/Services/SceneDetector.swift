import AVFoundation
import Foundation

/// Detects shot/scene boundaries from the shared frame sample.
///
/// Consecutive frame signatures are compared; a large frame-to-frame difference
/// marks a cut. The stretches between cuts become scenes, each scored by how
/// much visual change happens inside it — the basis for highlight selection.
/// For scenery/driving footage this surfaces the most visually dynamic moments.
struct SceneDetector {

    func detectScenes(frames: [SampledFrame], total: CMTime, settings: AnalysisSettings) -> [Scene] {
        let totalSeconds = total.seconds
        guard totalSeconds > 0 else { return [] }
        guard frames.count >= 2 else {
            // Too short to segment — treat the whole clip as one scene.
            return [Scene(range: CMTimeRange(start: .zero, end: total), score: 1, isSelected: true)]
        }

        // Map sensitivity (0...1) to a frame-difference threshold.
        // High sensitivity => low threshold => more cuts.
        let threshold = 0.35 - 0.30 * settings.sceneSensitivity

        let series = FrameSampler.motionSeries(frames)
        var cutTimes: [Double] = [0.0]
        for entry in series where entry.motion > threshold {
            cutTimes.append(entry.time)
        }
        cutTimes.append(totalSeconds)

        let boundaries = Array(Set(cutTimes)).sorted()

        // Longest a candidate scene may be. A continuous single-shot clip has no
        // internal cuts, so it would otherwise be one scene spanning the whole
        // video; splitting long shots into sub-scenes lets highlight selection
        // pick the best *moments* instead of keeping the entire clip.
        let maxSceneLength = 3.5

        var scenes: [Scene] = []
        for i in 0..<(boundaries.count - 1) {
            let shotStart = boundaries[i]
            let shotEnd = boundaries[i + 1]
            guard shotEnd > shotStart else { continue }

            let shotLength = shotEnd - shotStart
            let parts = max(1, Int((shotLength / maxSceneLength).rounded(.up)))
            let partLength = shotLength / Double(parts)

            for p in 0..<parts {
                let startSeconds = shotStart + Double(p) * partLength
                let endSeconds = (p == parts - 1) ? shotEnd : startSeconds + partLength
                guard endSeconds > startSeconds else { continue }

                // Average visual motion within the sub-scene.
                let inside = series.filter { $0.time > startSeconds && $0.time <= endSeconds }
                let meanMotion = inside.isEmpty ? 0 : inside.map(\.motion).reduce(0, +) / Double(inside.count)

                // Weight motion by (log-scaled) length so a single flashy frame
                // doesn't beat a sustained interesting shot.
                let score = (meanMotion + 0.01) * log(1 + (endSeconds - startSeconds))

                scenes.append(Scene(
                    range: CMTimeRange(
                        start: TimeRangeMath.time(startSeconds),
                        end: TimeRangeMath.time(endSeconds)
                    ),
                    score: score
                ))
            }
        }

        return scenes
    }
}

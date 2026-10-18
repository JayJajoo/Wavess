import AVFoundation
import Foundation

/// Finds low-motion ("still") stretches — the visual equivalent of silence.
///
/// This is the right tool for footage without meaningful speech (scenery,
/// driving, b-roll): instead of listening for quiet, it watches for stretches
/// where almost nothing changes on screen — a stopped car, a long static hold —
/// so they can be trimmed, keeping the parts where the view is actually moving.
struct MotionAnalyzer {

    /// Returns the still ranges to cut, derived from the shared frame sample.
    func detectStillRanges(frames: [SampledFrame], total: CMTime, settings: AnalysisSettings) -> [CMTimeRange] {
        let series = FrameSampler.motionSeries(frames)
        guard !series.isEmpty else { return [] }

        var ranges: [CMTimeRange] = []
        var runStart: Double? = nil
        // Each motion sample describes the interval *ending* at its time, so the
        // start of a still run is the previous sample's time.
        var intervalStart = 0.0

        func closeRun(end: Double) {
            if let start = runStart, end - start >= settings.minStillDuration {
                ranges.append(CMTimeRange(
                    start: TimeRangeMath.time(start),
                    end: TimeRangeMath.time(end)
                ))
            }
            runStart = nil
        }

        for entry in series {
            if entry.motion <= settings.motionStillThreshold {
                if runStart == nil { runStart = intervalStart }
            } else {
                closeRun(end: entry.time)
            }
            intervalStart = entry.time
        }
        closeRun(end: total.seconds)

        return ranges
    }
}

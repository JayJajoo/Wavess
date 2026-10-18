import CoreMedia
import Foundation

/// Pure helpers for manipulating ordered lists of `CMTimeRange`s.
///
/// These power the edit modes: the trim modes invert the detected still/silent
/// ranges to get what to keep, and every mode merges/clamps/pads ranges before
/// export.
enum TimeRangeMath {

    static let timescale: CMTimeScale = 600

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: timescale)
    }

    /// Returns the complement of `ranges` within `[0, total]` — i.e. every
    /// stretch of the timeline *not* covered by an input range.
    static func invert(_ ranges: [CMTimeRange], total: CMTime) -> [CMTimeRange] {
        let sorted = ranges
            .filter { $0.duration > .zero }
            .sorted { $0.start < $1.start }

        var result: [CMTimeRange] = []
        var cursor = CMTime.zero

        for range in sorted {
            if range.start > cursor {
                result.append(CMTimeRange(start: cursor, end: range.start))
            }
            cursor = max(cursor, range.end)
        }
        if cursor < total {
            result.append(CMTimeRange(start: cursor, end: total))
        }
        return result
    }

    /// Merges overlapping or near-adjacent ranges. Ranges separated by a gap of
    /// `gap` or less are fused into one, which keeps the final cut from having
    /// lots of tiny back-to-back segments.
    static func merge(_ ranges: [CMTimeRange], gap: CMTime = .zero) -> [CMTimeRange] {
        let sorted = ranges
            .filter { $0.duration > .zero }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }

        var result: [CMTimeRange] = []
        for range in sorted.dropFirst() {
            if range.start <= current.end + gap {
                let end = max(current.end, range.end)
                current = CMTimeRange(start: current.start, end: end)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }

    /// Expands each range by `padding` seconds on both sides, clamped to
    /// `[0, total]`, then merges any ranges that now overlap.
    static func pad(_ ranges: [CMTimeRange], by padding: Double, total: CMTime) -> [CMTimeRange] {
        guard padding > 0 else { return merge(ranges) }
        let pad = time(padding)
        let expanded = ranges.map { range -> CMTimeRange in
            let start = max(.zero, range.start - pad)
            let end = min(total, range.end + pad)
            return CMTimeRange(start: start, end: end)
        }
        return merge(expanded)
    }

    /// Total duration covered by a list of ranges, in seconds.
    static func totalSeconds(_ ranges: [CMTimeRange]) -> Double {
        ranges.reduce(0) { $0 + $1.duration.seconds }
    }
}

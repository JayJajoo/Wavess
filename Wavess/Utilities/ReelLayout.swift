import Foundation

/// Pure (Double-based) timeline layout for the plain reel, mirroring
/// `ReelBuilder`'s placement. Used to map output time ranges back to segments
/// (e.g. for per-clip color grading) without duplicating the builder's logic
/// ad hoc.
enum ReelLayout {

    /// - Parameters:
    ///   - durations: each segment's source duration (seconds).
    ///   - transitionIntoNext: per segment, whether it overlaps into the next.
    ///   - transitionDuration: requested overlap (clamped to 40% of the shorter neighbor).
    /// - Returns: each segment's timeline start, the per-boundary overlaps, and the total length.
    static func compute(durations: [Double], transitionIntoNext: [Bool], transitionDuration: Double) -> (starts: [Double], overlaps: [Double], total: Double) {
        guard !durations.isEmpty else { return ([], [], 0) }

        var overlaps = [Double](repeating: 0, count: durations.count)
        for i in durations.indices {
            if i == durations.count - 1 || !transitionIntoNext[i] {
                overlaps[i] = 0
            } else {
                overlaps[i] = min(transitionDuration, 0.4 * min(durations[i], durations[i + 1]))
            }
        }

        var starts = [Double](repeating: 0, count: durations.count)
        var cursor = 0.0
        for i in durations.indices {
            starts[i] = cursor
            cursor += durations[i] - overlaps[i]
        }
        let total = starts[durations.count - 1] + durations[durations.count - 1]
        return (starts, overlaps, total)
    }
}

import Foundation

/// Tunable parameters for the on-device analysis passes.
///
/// Defaults are chosen to work well for typical phone footage. Every value is
/// exposed to the user via sliders so they can dial the edit in for their clip.
struct AnalysisSettings: Equatable {

    // MARK: Still / low-motion detection (visual) — for scenery, driving, b-roll

    /// Frame-to-frame visual change (normalized `0...1`) below this level counts
    /// as "still". Stretches that stay this still are candidates to cut. Lower
    /// values only cut footage that's almost completely frozen.
    var motionStillThreshold: Double = 0.02

    /// Still stretches shorter than this (seconds) are kept, so brief holds
    /// aren't chopped out.
    var minStillDuration: Double = 1.0

    // MARK: Silence detection (audio) — for talking videos

    /// Loudness below this level (in dBFS, where 0 dB is full scale) is treated
    /// as silence. Quieter rooms want a lower (more negative) threshold.
    var silenceThresholdDB: Double = -35

    /// Silent stretches shorter than this (seconds) are kept — avoids chopping
    /// the natural micro-pauses between words.
    var minSilenceDuration: Double = 0.4

    // MARK: Shared

    /// How much footage to preserve on each side of a kept segment (seconds),
    /// so cuts don't feel abrupt.
    var keepPadding: Double = 0.1

    // MARK: Scene detection

    /// 0 = only hard cuts are detected, 1 = even subtle changes count as a new
    /// scene. Drives the frame-difference threshold.
    var sceneSensitivity: Double = 0.5

    /// Frames sampled per second during visual analysis. Higher is more precise
    /// but slower. 3 fps balances precision and speed.
    var sampleFPS: Double = 3.0

    /// When building a highlight reel, aim for roughly this fraction of the
    /// original duration (0.4 = a ~40%-length cut of the best moments).
    var highlightTargetFraction: Double = 0.4
}

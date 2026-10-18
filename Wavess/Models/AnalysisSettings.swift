import Foundation

/// Tunable parameters for the on-device analysis passes.
///
/// Defaults are chosen to work well for typical talking-head / handheld
/// phone footage. Every value is exposed to the user via sliders so they can
/// dial the edit in for their specific clip.
struct AnalysisSettings: Equatable {

    // MARK: Silence detection

    /// Loudness below this level (in dBFS, where 0 dB is full scale) is treated
    /// as silence. Quieter rooms want a lower (more negative) threshold.
    var silenceThresholdDB: Double = -35

    /// Silent stretches shorter than this (seconds) are kept — this avoids
    /// chopping the natural micro-pauses between words.
    var minSilenceDuration: Double = 0.4

    /// How much speech to preserve on each side of a kept segment (seconds),
    /// so cuts don't clip the start/end of words or feel abrupt.
    var speechPadding: Double = 0.08

    // MARK: Scene detection

    /// 0 = only hard cuts are detected, 1 = even subtle changes count as a new
    /// scene. Drives the frame-difference threshold.
    var sceneSensitivity: Double = 0.5

    /// Frames sampled per second during scene analysis. Higher is more precise
    /// but slower. 2 fps is a good balance for highlight-finding.
    var sampleFPS: Double = 2.0

    /// When building a highlight reel, aim for roughly this fraction of the
    /// original duration (0.4 = a ~40%-length cut of the best moments).
    var highlightTargetFraction: Double = 0.4
}

import Foundation

/// Configures how the reel's key scenes are stitched together.
struct TransitionSettings: Equatable {

    enum Style: String, CaseIterable, Identifiable {
        case crossDissolve = "Dissolve"
        case none = "Hard cut"
        var id: String { rawValue }
    }

    /// Where transitions are applied. Scenery reels look best with transitions
    /// only where one clip hands off to the next — not at every internal cut.
    enum Frequency: String, CaseIterable, Identifiable {
        case betweenClips = "Between clips"
        case everyScene = "Every scene"
        var id: String { rawValue }
    }

    var style: Style = .crossDissolve
    var frequency: Frequency = .betweenClips

    /// Transition length in seconds (clamped per-boundary so short scenes stay valid).
    var duration: Double = 0.6

    /// Fraction of each clip to keep as key scenes (0.3 = ~30% of each clip).
    var perClipFraction: Double = 0.3

    /// Whether a given boundary (between two consecutive scenes in the reel) gets
    /// a transition, given whether it crosses from one clip to the next.
    func wantsTransition(crossesClip: Bool) -> Bool {
        guard style != .none else { return false }
        switch frequency {
        case .everyScene:   return true
        case .betweenClips: return crossesClip
        }
    }
}

import Foundation

/// Configures how the reel's key scenes are stitched together.
struct TransitionSettings: Equatable {

    enum Style: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case crossDissolve = "Dissolve"
        case fadeToBlack = "Fade"
        case slide = "Slide"
        case none = "Cut"
        var id: String { rawValue }

        /// Whether this style lets Wavess choose the transition per boundary from
        /// the analysis, rather than using one fixed effect everywhere.
        var isAuto: Bool { self == .auto }

        /// The fixed rendering effect for this style (nil = a hard cut). `.auto`
        /// falls back to a dissolve where a single effect is needed.
        var effect: ReelTransition? {
            switch self {
            case .auto, .crossDissolve: return .crossDissolve
            case .fadeToBlack:          return .fadeToBlack
            case .slide:                return .slide
            case .none:                 return nil
            }
        }
    }

    /// Where transitions are applied. Scenery reels look best with transitions
    /// only where one clip hands off to the next — not at every internal cut.
    enum Frequency: String, CaseIterable, Identifiable {
        case betweenClips = "Between clips"
        case everyScene = "Every scene"
        var id: String { rawValue }
    }

    var style: Style = .auto
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

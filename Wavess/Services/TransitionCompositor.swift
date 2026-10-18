import AVFoundation
import CoreGraphics

/// Visual effect used to blend one reel segment into the next.
enum ReelTransition {
    case crossDissolve
    case fadeToBlack
    case slide
}

/// Configures the outgoing/incoming layer instructions for a transition's time
/// range, so the music reel and the plain reel render transitions identically.
///
/// `from` is the outgoing segment (added first, so it draws on top); `to` is the
/// incoming one. Transforms are the per-segment fit transforms.
enum TransitionCompositor {

    static func apply(
        _ transition: ReelTransition,
        from: AVMutableVideoCompositionLayerInstruction,
        to: AVMutableVideoCompositionLayerInstruction,
        fromTransform: CGAffineTransform,
        toTransform: CGAffineTransform,
        range: CMTimeRange,
        renderSize: CGSize
    ) {
        switch transition {
        case .crossDissolve:
            // Outgoing fades out on top of the fully-opaque incoming segment.
            from.setTransform(fromTransform, at: range.start)
            from.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
            to.setTransform(toTransform, at: range.start)

        case .fadeToBlack:
            // Dip to black: outgoing fades to 0 over the first half (revealing
            // black, since the incoming segment is still 0), then the incoming
            // segment fades up over the second half.
            let half = CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5)
            let firstHalf = CMTimeRange(start: range.start, duration: half)
            let secondHalf = CMTimeRange(start: range.start + half, end: range.end)
            from.setTransform(fromTransform, at: range.start)
            from.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: firstHalf)
            to.setTransform(toTransform, at: range.start)
            to.setOpacity(0, at: range.start)
            to.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: secondHalf)

        case .slide:
            // Push: outgoing slides out to the left while incoming slides in from
            // the right. They occupy complementary halves, so no cross-fade.
            let w = renderSize.width
            from.setTransformRamp(
                fromStart: fromTransform,
                toEnd: fromTransform.concatenating(CGAffineTransform(translationX: -w, y: 0)),
                timeRange: range
            )
            to.setTransformRamp(
                fromStart: toTransform.concatenating(CGAffineTransform(translationX: w, y: 0)),
                toEnd: toTransform,
                timeRange: range
            )
        }
    }
}

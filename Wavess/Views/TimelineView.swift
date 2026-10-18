import CoreMedia
import SwiftUI

/// A compact visual timeline: a dim full-width bar for the whole clip, with the
/// kept segments highlighted in the accent color. Works for both edit modes —
/// in "Tighten" the accent is the speech; in "Highlights" it's the chosen
/// scenes.
struct TimelineView: View {
    let duration: Double
    let keep: [CMTimeRange]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let safeDuration = max(duration, 0.001)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.18))

                ForEach(Array(keep.enumerated()), id: \.offset) { _, range in
                    let x = CGFloat(range.start.seconds / safeDuration) * width
                    let w = CGFloat(range.duration.seconds / safeDuration) * width
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor)
                        .frame(width: max(w, 1.5))
                        .offset(x: x)
                }
            }
        }
        .frame(height: 30)
        .accessibilityLabel("Edit timeline")
        .accessibilityValue("Keeping \(keep.count) segments")
    }
}

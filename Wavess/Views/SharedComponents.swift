import AVKit
import SwiftUI

/// A video preview card that rebuilds its player when the URL changes.
/// Shared by the single-clip editor and the reel builder.
struct PlayerCard: View {
    let url: URL
    var height: CGFloat = 220
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onChange(of: url) { _, newURL in
                player?.pause()
                player = AVPlayer(url: newURL)
            }
            .onDisappear { player?.pause() }
    }
}

/// A labeled slider with a value readout and an optional commit callback that
/// fires when the user lifts their finger (used to trigger a recompute).
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String
    var onCommit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(display)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onCommit?() }
            }
            .tint(.accentColor)
        }
    }
}

/// A tappable row representing one detected scene, with a selection checkmark
/// and an interest-score meter.
struct SceneRow: View {
    let scene: Scene
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: scene.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(scene.isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Formatting.timecode(scene.start)) – \(Formatting.timecode(scene.end))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(Formatting.shortDuration(scene.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ScoreBar(score: scene.score)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal row of color-look chips bound to a selection.
struct LookChips: View {
    @Binding var selection: Look

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Look.allCases) { look in
                    let isOn = look == selection
                    Button { selection = look } label: {
                        VStack(spacing: 4) {
                            Image(systemName: look.symbol)
                                .font(.title3)
                            Text(look.rawValue)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(width: 70, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isOn ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isOn ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .foregroundStyle(isOn ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }
}

/// A tiny 5-dot meter visualizing a scene's relative "interest" score.
struct ScoreBar: View {
    let score: Double

    private var filled: Int {
        // Scores are small positive numbers; map to 1...5 dots.
        let normalized = min(1, max(0, score / 0.15))
        return max(1, Int((normalized * 5).rounded()))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Interest score \(filled) of 5")
    }
}

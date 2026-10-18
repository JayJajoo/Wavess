import SwiftUI

/// Instagram-style music trimmer: the whole song drawn as a waveform, two
/// draggable handles to crop the start→end window, and a playhead that sweeps
/// while the selected section previews (preview plays only inside the window).
struct MusicTrimmer: View {
    let model: ReelViewModel

    private let trackHeight: CGFloat = 60
    private let handleWidth: CGFloat = 16
    private let space = "trimmer"

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let W = geo.size.width
                let full = max(0.001, model.musicFullDuration)
                let startX = clampX(CGFloat(model.musicStart / full) * W, W)
                let endX = clampX(CGFloat(model.musicEnd / full) * W, W)
                let playX = clampX(CGFloat(min(max(model.previewTime, 0), full) / full) * W, W)

                ZStack(alignment: .leading) {
                    WaveBars(samples: model.musicWaveform, color: Color.secondary.opacity(0.30))

                    WaveBars(samples: model.musicWaveform, color: Color.accentColor)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, endX - startX)).offset(x: startX)
                        }

                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: max(handleWidth, endX - startX), height: trackHeight)
                        .offset(x: startX)

                    Capsule().fill(.white)
                        .frame(width: 2.5, height: trackHeight + 6)
                        .offset(x: playX - 1.25)
                        .shadow(radius: 1)
                        .opacity(model.isPreviewingMusic ? 1 : 0.6)

                    grip.offset(x: startX)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                            .onChanged { setStart(x: $0.location.x, width: W) }
                            .onEnded { _ in commit() })

                    grip.offset(x: endX - handleWidth)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                            .onChanged { setEnd(x: $0.location.x, width: W) }
                            .onEnded { _ in commit() })
                }
                .frame(width: W, height: trackHeight)
                .coordinateSpace(name: space)
            }
            .frame(height: trackHeight)

            HStack(spacing: 14) {
                Button { model.togglePreview() } label: {
                    Image(systemName: model.isPreviewingMusic ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Formatting.timecode(model.musicStart)) – \(Formatting.timecode(model.musicEnd))")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    Text("Drag the ends to crop · tap play to hear this part")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var grip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor)
                .frame(width: handleWidth, height: trackHeight + 6)
            Capsule().fill(.white).frame(width: 3, height: trackHeight * 0.35)
        }
        .contentShape(Rectangle().inset(by: -12))
    }

    private func clampX(_ x: CGFloat, _ width: CGFloat) -> CGFloat { min(max(0, x), width) }

    private func setStart(x: CGFloat, width: CGFloat) {
        let full = model.musicFullDuration
        guard full > 0, width > 0 else { return }
        let t = Double(min(max(0, x), width) / width) * full
        let end = model.musicEnd
        let minS = model.minMusicSectionDuration
        let maxS = model.maxMusicSectionDuration
        let newStart = min(max(0, max(end - maxS, t)), end - minS)
        model.musicStart = max(0, newStart)
        model.musicSectionDuration = end - model.musicStart
        model.seekPreview(to: model.musicStart)
    }

    private func setEnd(x: CGFloat, width: CGFloat) {
        let full = model.musicFullDuration
        guard full > 0, width > 0 else { return }
        let t = Double(min(max(0, x + handleWidth), width) / width) * full
        let start = model.musicStart
        let minS = model.minMusicSectionDuration
        let maxS = model.maxMusicSectionDuration
        let newEnd = max(min(t, min(full, start + maxS)), start + minS)
        model.musicSectionDuration = newEnd - start
        model.seekPreview(to: start)
    }

    private func commit() {
        Task { await model.analyzeMusicSection() }
    }
}

/// Draws an amplitude envelope as rounded vertical bars.
private struct WaveBars: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            if samples.isEmpty {
                Capsule().fill(color)
                    .frame(width: w, height: 3)
                    .position(x: w / 2, y: h / 2)
            } else {
                let slot = w / CGFloat(samples.count)
                Path { path in
                    for (i, s) in samples.enumerated() {
                        let barH = max(3, CGFloat(s) * (h - 6))
                        let bw = max(1, slot * 0.5)
                        let x = CGFloat(i) * slot + (slot - bw) / 2
                        let y = (h - barH) / 2
                        path.addRoundedRect(in: CGRect(x: x, y: y, width: bw, height: barH),
                                            cornerSize: CGSize(width: bw / 2, height: bw / 2))
                    }
                }
                .fill(color)
            }
        }
    }
}

import SwiftUI

/// The home screen. Offers two entry points: edit a single clip, or build a
/// reel from several clips.
struct ImportView: View {
    var onChooseSingle: () -> Void
    var onChooseReel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .padding(.top, 24)

                VStack(spacing: 10) {
                    Text("Intelligent video editing")
                        .font(.title2.bold())
                    Text("On-device, no accounts, no network. Wavess trims the dull stretches and stitches your best moments together.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 14) {
                    ActionCard(
                        icon: "sparkles.rectangle.stack",
                        title: "Build a Reel",
                        detail: "Combine several clips (e.g. drives & scenery) — Wavess picks the key scenes from each and stitches them with transitions.",
                        prominent: true,
                        action: onChooseReel
                    )
                    ActionCard(
                        icon: "scissors",
                        title: "Edit one clip",
                        detail: "Trim still/boring stretches or pull the highlights out of a single video.",
                        prominent: false,
                        action: onChooseSingle
                    )
                }
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 12) {
                    FeatureRow(icon: "car.fill", title: "Made for scenery & driving", detail: "Works on silent footage — no speech needed.")
                    FeatureRow(icon: "wand.and.rays", title: "Selective transitions", detail: "Dissolves where clips meet, clean cuts elsewhere.")
                    FeatureRow(icon: "lock.fill", title: "Fully on-device", detail: "No uploads, no accounts, no network.")
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct ActionCard: View {
    let icon: String
    let title: String
    let detail: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(prominent ? Color.white : Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(prominent ? Color.white : Color.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(prominent ? Color.white.opacity(0.9) : .secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(prominent ? Color.white.opacity(0.9) : .secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    ImportView(onChooseSingle: {}, onChooseReel: {})
}

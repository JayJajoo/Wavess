import SwiftUI

/// The empty-state / landing screen inviting the user to pick a video.
struct ImportView: View {
    var onChoose: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "wand.and.stars")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 10) {
                Text("Intelligent video editing")
                    .font(.title2.bold())
                Text("Pick a clip and Wavess will trim the dead air and find your best moments — all on your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(icon: "speaker.slash.fill", title: "Auto-remove silence", detail: "Cuts the quiet gaps and keeps the talking.")
                FeatureRow(icon: "film.stack", title: "Scene highlights", detail: "Detects shots and assembles a short cut.")
                FeatureRow(icon: "lock.fill", title: "Fully on-device", detail: "No uploads, no accounts, no network.")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onChoose) {
                Label("Choose Video", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
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
    ImportView(onChoose: {})
}

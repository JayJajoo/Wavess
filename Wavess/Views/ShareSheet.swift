import SwiftUI
import UIKit

/// Presents the system share sheet (`UIActivityViewController`) for the given
/// items — used to share or "Save to Files" the exported video.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

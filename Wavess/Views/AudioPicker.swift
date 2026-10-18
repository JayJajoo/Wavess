import SwiftUI
import UniformTypeIdentifiers

/// A document picker for choosing a music file (mp3/m4a/wav/aac…) from Files or
/// iCloud, returning a local copy's URL. Imported as a copy so we can read its
/// samples without security-scope juggling.
struct AudioPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onError: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onError: onError)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onError: (String) -> Void

        init(onPick: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.onPick = onPick
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let source = urls.first else { return }
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("wavess-music-\(UUID().uuidString).\(ext)")
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                onPick(destination)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

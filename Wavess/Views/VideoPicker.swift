import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A thin SwiftUI wrapper around `PHPickerViewController` that returns a local
/// file URL for the chosen video.
///
/// The picker runs out-of-process, so it needs no photo-library permission to
/// read. The supplied item is copied into a temporary file we own, because the
/// URL handed to `loadFileRepresentation` is deleted as soon as the callback
/// returns.
struct VideoPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onError: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onError: onError)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL) -> Void
        let onError: (String) -> Void

        init(onPick: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.onPick = onPick
            self.onError = onError
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider else { return }
            let typeIdentifier = UTType.movie.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                onError("That file isn't a supported video.")
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [onPick, onError] url, error in
                if let error {
                    DispatchQueue.main.async { onError(error.localizedDescription) }
                    return
                }
                guard let url else {
                    DispatchQueue.main.async { onError("Couldn't read the selected video.") }
                    return
                }

                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("wavess-input-\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    DispatchQueue.main.async { onPick(destination) }
                } catch {
                    DispatchQueue.main.async { onError(error.localizedDescription) }
                }
            }
        }
    }
}

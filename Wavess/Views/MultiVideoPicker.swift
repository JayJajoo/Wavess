import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A `PHPickerViewController` wrapper that allows selecting several videos and
/// returns local file URLs for all of them, preserving the pick order.
struct MultiVideoPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    var onError: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 0  // unlimited
        config.selection = .ordered  // reel follows the order clips are tapped
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
        let onPick: ([URL]) -> Void
        let onError: (String) -> Void

        init(onPick: @escaping ([URL]) -> Void, onError: @escaping (String) -> Void) {
            self.onPick = onPick
            self.onError = onError
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            let typeIdentifier = UTType.movie.identifier
            var urls = [URL?](repeating: nil, count: results.count)
            let group = DispatchGroup()
            let lock = NSLock()

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { continue }

                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("wavess-reel-\(UUID().uuidString).\(ext)")
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                        lock.lock()
                        urls[index] = destination
                        lock.unlock()
                    } catch {
                        // Skip this item; others may still succeed.
                    }
                }
            }

            group.notify(queue: .main) { [onPick, onError] in
                let ordered = urls.compactMap { $0 }
                if ordered.isEmpty {
                    onError("Couldn't load the selected videos.")
                } else {
                    onPick(ordered)
                }
            }
        }
    }
}

import Photos
import Foundation

/// Saves an exported video file into the user's photo library, requesting
/// add-only permission first.
enum PhotoSaver {

    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw EditorError.photoLibraryDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

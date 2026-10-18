import AVFoundation
import Foundation

/// Assembles the kept time ranges into a new video and exports it to a file.
///
/// A single `AVMutableComposition` is built by inserting each kept range of the
/// source's video (and audio) track back-to-back, preserving orientation. The
/// result is exported with `AVAssetExportSession`.
struct VideoComposer {

    /// Builds a composition containing only `keep` (in timeline order).
    func makeComposition(asset: AVURLAsset, keep: [CMTimeRange]) async throws -> AVComposition {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw EditorError.noVideoTrack
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw EditorError.exportSetupFailed
        }
        let audioTrack = sourceAudio == nil ? nil : composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        for range in keep where range.duration > .zero {
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let sourceAudio, let audioTrack {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = cursor + range.duration
        }

        // Preserve the source orientation (portrait vs landscape).
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        return composition
    }

    /// Exports an asset (optionally driven by a video composition and/or audio
    /// mix, e.g. for reel transitions and a music soundtrack) to a temporary
    /// `.mp4`, reporting progress `0...1`.
    func export(_ asset: AVAsset, videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil, onProgress: @escaping @Sendable (Float) -> Void) async throws -> URL {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw EditorError.exportSetupFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavess-\(UUID().uuidString).mp4")

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let videoComposition {
            session.videoComposition = videoComposition
        }
        if let audioMix {
            session.audioMix = audioMix
        }

        // Poll progress while the export runs.
        let progressTask = Task {
            while !Task.isCancelled {
                onProgress(session.progress)
                try? await Task.sleep(nanoseconds: 150_000_000)
                let status = session.status
                if status == .completed || status == .failed || status == .cancelled {
                    break
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        progressTask.cancel()

        switch session.status {
        case .completed:
            onProgress(1.0)
            return outputURL
        case .cancelled:
            throw EditorError.exportFailed("Export was cancelled.")
        default:
            throw EditorError.exportFailed(session.error?.localizedDescription ?? "Unknown error.")
        }
    }
}

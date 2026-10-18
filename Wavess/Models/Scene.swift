import CoreMedia
import Foundation

/// A detected shot/scene in the source video.
///
/// `score` is a heuristic measure of how "interesting" the scene is (how much
/// visual change happens inside it, weighted by length). Highlight selection
/// keeps the highest-scoring scenes.
struct Scene: Identifiable, Equatable {
    let id = UUID()
    let range: CMTimeRange
    var score: Double
    var isSelected: Bool = false

    var start: Double { range.start.seconds }
    var end: Double { range.end.seconds }
    var duration: Double { range.duration.seconds }
}

/// Errors surfaced by the editing pipeline.
enum EditorError: LocalizedError {
    case noVideoTrack
    case exportSetupFailed
    case exportFailed(String)
    case nothingToExport
    case photoLibraryDenied

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "This file doesn't contain a video track."
        case .exportSetupFailed:
            return "Couldn't set up the video exporter."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .nothingToExport:
            return "Nothing to export — adjust your selection so at least one segment is kept."
        case .photoLibraryDenied:
            return "Wavess needs permission to add videos to your photo library. Enable it in Settings."
        }
    }
}

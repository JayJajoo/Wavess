import AVFoundation
import Foundation

/// One source video in a reel, with its detected scenes and which of them are
/// currently selected as key scenes.
struct ReelClip: Identifiable {
    let id = UUID()
    let url: URL
    let asset: AVURLAsset
    let duration: Double
    var scenes: [Scene]

    /// Per-clip color look override. `nil` means "use the reel-wide look".
    var look: Look? = nil

    var fileName: String { url.lastPathComponent }

    /// Selected key scenes, in timeline order.
    var selectedScenes: [Scene] {
        scenes.filter(\.isSelected).sorted { $0.range.start < $1.range.start }
    }

    var selectedCount: Int { scenes.filter(\.isSelected).count }
}

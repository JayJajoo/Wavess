import SwiftUI

/// Entry point for Wavess — an on-device intelligent video editor.
///
/// Everything runs locally on the phone: audio is analyzed for silent gaps,
/// video frames are sampled to detect scene cuts, and the edited result is
/// assembled and exported with AVFoundation. No network, no API keys.
@main
struct WavessApp: App {
    // Qualified as SwiftUI.Scene because this module also declares a `Scene`
    // model type (a detected video scene), which would otherwise shadow it.
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
        }
    }
}

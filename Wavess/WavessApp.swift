import SwiftUI

/// Entry point for Wavess — an on-device intelligent video editor.
///
/// Everything runs locally on the phone: audio is analyzed for silent gaps,
/// video frames are sampled to detect scene cuts, and the edited result is
/// assembled and exported with AVFoundation. No network, no API keys.
@main
struct WavessApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

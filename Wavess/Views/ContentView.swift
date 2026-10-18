import SwiftUI

/// Root view. A simple home screen routes to either the single-clip editor or
/// the multi-clip reel builder.
struct ContentView: View {
    private enum Screen { case home, editor, reel }

    @State private var editor = EditorViewModel()
    @State private var reel = ReelViewModel()
    @State private var screen: Screen = .home

    @State private var showSinglePicker = false
    @State private var showReelPicker = false
    @State private var pickerError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch screen {
                case .home:
                    ImportView(
                        onChooseSingle: { showSinglePicker = true },
                        onChooseReel: { showReelPicker = true }
                    )
                case .editor:
                    EditorView(model: editor)
                case .reel:
                    ReelView(model: reel)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if screen != .home {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Home", systemImage: "chevron.left") { goHome() }
                    }
                }
            }
        }
        .sheet(isPresented: $showSinglePicker) {
            VideoPicker(
                onPick: { url in
                    showSinglePicker = false
                    screen = .editor
                    Task { await editor.load(url: url) }
                },
                onError: { message in
                    showSinglePicker = false
                    pickerError = message
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showReelPicker) {
            MultiVideoPicker(
                onPick: { urls in
                    showReelPicker = false
                    screen = .reel
                    Task { await reel.loadClips(urls: urls) }
                },
                onError: { message in
                    showReelPicker = false
                    pickerError = message
                }
            )
            .ignoresSafeArea()
        }
        .alert("Couldn't open that", isPresented: Binding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            Button("OK", role: .cancel) { pickerError = nil }
        } message: {
            Text(pickerError ?? "")
        }
    }

    private var title: String {
        switch screen {
        case .home:   return "Wavess"
        case .editor: return "Edit Clip"
        case .reel:   return "Build Reel"
        }
    }

    private func goHome() {
        editor.reset()
        reel.reset()
        screen = .home
    }
}

#Preview {
    ContentView()
}

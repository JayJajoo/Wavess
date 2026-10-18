import SwiftUI

/// Root view. Shows the import screen until a clip is loaded, then the editor.
struct ContentView: View {
    @State private var model = EditorViewModel()
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if model.sourceURL == nil {
                    ImportView(onChoose: { showPicker = true })
                } else {
                    EditorView(model: model)
                }
            }
            .navigationTitle("Wavess")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.sourceURL != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New", systemImage: "plus") { model.reset() }
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            VideoPicker(
                onPick: { url in
                    showPicker = false
                    Task { await model.load(url: url) }
                },
                onError: { message in
                    showPicker = false
                    model.errorMessage = message
                }
            )
            .ignoresSafeArea()
        }
    }
}

#Preview {
    ContentView()
}

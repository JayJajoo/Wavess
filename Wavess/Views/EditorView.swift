import SwiftUI

/// The main editing surface: preview, mode switch, on-device analysis controls,
/// and export. Reads/writes `EditorViewModel` via `@Bindable`.
struct EditorView: View {
    @Bindable var model: EditorViewModel

    @State private var showShareSheet = false
    @State private var showSavedConfirmation = false
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let url = model.sourceURL {
                    PlayerCard(url: url)
                }

                modePicker

                switch model.phase {
                case .analyzing:
                    analyzingCard
                case .ready, .exporting, .done:
                    resultsSection
                case .empty:
                    EmptyView()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showShareSheet) {
            if let url = model.resultURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Mode

    private var modePicker: some View {
        VStack(spacing: 8) {
            Picker("Edit mode", selection: $model.mode) {
                ForEach(EditorViewModel.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(model.mode.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Analyzing

    private var analyzingCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.progress)
                .tint(.accentColor)
            Text(model.statusMessage.isEmpty ? "Analyzing…" : model.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(spacing: 20) {
            statsCard
            TimelineView(duration: model.duration, keep: model.keepRanges)

            switch model.mode {
            case .trimStill:
                trimStillControls
            case .trimSilence:
                trimSilenceControls
            case .highlights:
                highlightControls
            }

            exportArea

            if model.phase == .done, let url = model.resultURL {
                resultCard(url: url)
            }
        }
    }

    private var statsCard: some View {
        HStack {
            stat(title: "Original", value: Formatting.timecode(model.duration))
            Divider().frame(height: 34)
            stat(title: "New length", value: Formatting.timecode(model.estimatedDuration))
            Divider().frame(height: 34)
            stat(
                title: "Saved",
                value: Formatting.shortDuration(model.timeSaved),
                highlight: model.timeSaved > 0
            )
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(title: String, value: String, highlight: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(highlight ? Color.accentColor : .primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Trim-still controls (visual — scenery / driving)

    private var trimStillControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remove still footage").font(.subheadline.weight(.semibold))
            Text("No speech needed — this cuts the stretches where the view barely changes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledSlider(
                title: "Stillness threshold",
                value: $model.settings.motionStillThreshold,
                range: 0.005 ... 0.08,
                step: 0.005,
                display: String(format: "%.1f%%", model.settings.motionStillThreshold * 100),
                onCommit: recomputeVisualAction
            )
            LabeledSlider(
                title: "Min. still length",
                value: $model.settings.minStillDuration,
                range: 0.3 ... 5,
                step: 0.1,
                display: String(format: "%.1fs", model.settings.minStillDuration),
                onCommit: recomputeVisualAction
            )
            keepPaddingSlider
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Trim-silence controls (audio — talking videos)

    private var trimSilenceControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remove silence").font(.subheadline.weight(.semibold))
            if !model.hasAudio {
                Text("This clip has no audio — try “Still” or “Highlights” instead.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabeledSlider(
                title: "Silence threshold",
                value: $model.settings.silenceThresholdDB,
                range: -60 ... -20,
                step: 1,
                display: "\(Int(model.settings.silenceThresholdDB)) dB",
                onCommit: recomputeAudioAction
            )
            LabeledSlider(
                title: "Min. silence length",
                value: $model.settings.minSilenceDuration,
                range: 0.1 ... 1.5,
                step: 0.05,
                display: String(format: "%.2fs", model.settings.minSilenceDuration),
                onCommit: recomputeAudioAction
            )
            keepPaddingSlider
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Shared "keep around cuts" slider — applied live, no recompute needed.
    private var keepPaddingSlider: some View {
        LabeledSlider(
            title: "Keep around cuts",
            value: $model.settings.keepPadding,
            range: 0 ... 0.5,
            step: 0.01,
            display: String(format: "%.2fs", model.settings.keepPadding),
            onCommit: nil
        )
    }

    // MARK: Highlight controls

    private var highlightControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Highlights").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.selectedSceneCount) of \(model.scenes.count) scenes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledSlider(
                title: "Target length",
                value: $model.settings.highlightTargetFraction,
                range: 0.1 ... 0.9,
                step: 0.05,
                display: "\(Int(model.settings.highlightTargetFraction * 100))%",
                onCommit: nil
            )
            LabeledSlider(
                title: "Scene sensitivity",
                value: $model.settings.sceneSensitivity,
                range: 0 ... 1,
                step: 0.05,
                display: "\(Int(model.settings.sceneSensitivity * 100))%",
                onCommit: recomputeVisualAction
            )

            if !model.scenes.isEmpty {
                Divider()
                ForEach(model.scenes) { scene in
                    SceneRow(scene: scene) { model.toggleScene(scene) }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: model.settings.highlightTargetFraction) { _, _ in
            model.autoSelectHighlights()
        }
    }

    // MARK: Export

    private var exportArea: some View {
        VStack(spacing: 12) {
            if model.phase == .exporting {
                ProgressView(value: model.progress) {
                    Text(model.statusMessage.isEmpty ? "Rendering…" : model.statusMessage)
                        .font(.subheadline)
                }
                .tint(.accentColor)
            } else {
                Button {
                    Task { await model.export() }
                } label: {
                    Label(model.phase == .done ? "Re-export" : "Export edit", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canExport)
            }
        }
    }

    // MARK: Result

    private func resultCard(url: URL) -> some View {
        VStack(spacing: 14) {
            Label("Your edit is ready", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            PlayerCard(url: url)

            HStack(spacing: 12) {
                Button {
                    Task {
                        isSaving = true
                        let ok = await model.saveResultToPhotos()
                        isSaving = false
                        if ok { showSavedConfirmation = true }
                    }
                } label: {
                    if isSaving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Save to Photos", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            if showSavedConfirmation {
                Text("Saved to Photos ✓")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    /// Visual slider changed — recompute scenes & still ranges from cached
    /// frames (fast, no re-scan).
    private func recomputeVisualAction() {
        showSavedConfirmation = false
        model.recomputeVisual()
    }

    /// Audio slider changed — re-run only the silence pass.
    private func recomputeAudioAction() {
        showSavedConfirmation = false
        Task { await model.recomputeAudio() }
    }
}

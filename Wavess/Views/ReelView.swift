import SwiftUI
import AVKit

/// The reel-builder screen: shows each imported clip's key scenes, transition
/// controls, and export. Stitches key scenes from multiple videos into one reel.
struct ReelView: View {
    @Bindable var model: ReelViewModel

    @State private var showShareSheet = false
    @State private var showSavedConfirmation = false
    @State private var isSaving = false
    @State private var showAudioPicker = false
    @State private var playingClip: ReelClip?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if model.phase == .analyzing {
                    analyzingCard
                } else if !model.clips.isEmpty {
                    statsCard
                    musicCard
                    transitionCard
                    colorCard

                    ForEach(model.clips) { clip in
                        clipCard(clip)
                    }

                    exportArea

                    if model.phase == .done, let url = model.resultURL {
                        resultCard(url: url)
                    }
                } else {
                    emptyClipsCard
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showAudioPicker) {
            AudioPicker(
                onPick: { url in
                    showAudioPicker = false
                    Task { await model.loadMusic(url: url) }
                },
                onError: { message in
                    showAudioPicker = false
                    model.errorMessage = message
                }
            )
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = model.resultURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(item: $playingClip) { clip in
            ClipPlayer(url: clip.url)
        }
    }

    private var emptyClipsCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No clips in this reel")
                .font(.headline)
            Text("Tap Home to add videos and photos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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

    // MARK: - Stats

    private var statsCard: some View {
        HStack {
            stat(title: "Clips", value: "\(model.clips.count)")
            Divider().frame(height: 34)
            stat(title: "Key scenes", value: "\(model.totalSelectedScenes)")
            Divider().frame(height: 34)
            stat(title: "Reel length", value: "~\(Formatting.timecode(model.estimatedDuration))", highlight: true)
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

    // MARK: - Music

    private var musicCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Music").font(.subheadline.weight(.semibold))
                Spacer()
                if model.musicAsset != nil {
                    Button("Remove") { model.clearMusic() }.font(.caption)
                }
            }

            if model.musicAsset == nil {
                Button { showAudioPicker = true } label: {
                    Label("Add music", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("Pick a song — the cuts, transitions and speed ramps sync to its beat, and the reel runs as long as your chosen section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.musicURL?.lastPathComponent ?? "Music")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if model.isAnalyzingMusic {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Analyzing beats…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let bpm = model.detectedBPM {
                    Label("~\(bpm) BPM detected", systemImage: "metronome")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Instagram-style trimmer: crop the start→end window on the song's
                // waveform and preview just that part.
                MusicTrimmer(model: model)

                Picker("Cut pace", selection: Binding<Int>(
                    get: { model.autoPace ? 0 : model.beatsPerCut },
                    set: {
                        if $0 == 0 { model.autoPace = true }
                        else { model.autoPace = false; model.beatsPerCut = $0 }
                    }
                )) {
                    Text("Auto").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)

                Text(model.autoPace
                     ? "Cut pace follows the song — fast cuts in the energetic parts, longer holds in the calm parts."
                     : "Cut every \(model.beatsPerCut) beat\(model.beatsPerCut == 1 ? "" : "s"). Lower = snappier, higher = calmer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Speed ramps (slow-mo / fast-forward)", isOn: $model.speedEffectsEnabled)
                    .font(.subheadline)

                Text("Speed ramps are added only on intelligently chosen beats — strong beats get slow-mo, long static shots get sped up.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Color

    private var colorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color").font(.subheadline.weight(.semibold))
            LookChips(selection: $model.reelLook)
            Text("Applies to the whole reel. Give any clip below its own look to grade just that section.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Transitions

    private var transitionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transitions").font(.subheadline.weight(.semibold))

            Picker("Style", selection: $model.transition.style) {
                ForEach(TransitionSettings.Style.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.transition.style == .auto {
                Text("Wavess picks the transition for each cut from the beat and the scenes — punchy cuts on strong beats, smooth blends between clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("When", selection: $model.transition.frequency) {
                ForEach(TransitionSettings.Frequency.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.transition.style == .none || model.transition.style == .auto)

            LabeledSlider(
                title: "Transition length",
                value: $model.transition.duration,
                range: 0.2 ... 1.5,
                step: 0.1,
                display: String(format: "%.1fs", model.transition.duration),
                onCommit: nil
            )
            .disabled(model.transition.style == .none)

            Divider()

            LabeledSlider(
                title: "Key scenes per clip",
                value: $model.transition.perClipFraction,
                range: 0.1 ... 0.8,
                step: 0.05,
                display: "\(Int(model.transition.perClipFraction * 100))%",
                onCommit: { model.reselectKeyScenes() }
            )

            Text(transitionHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var transitionHint: String {
        if model.transition.style == .none {
            return "Scenes are joined with hard cuts."
        }
        switch model.transition.frequency {
        case .betweenClips: return "A dissolve is added only where one clip hands off to the next — not at every cut."
        case .everyScene:   return "A dissolve is added at every scene change."
        }
    }

    // MARK: - Clips

    private func clipCard(_ clip: ReelClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { playingClip = clip } label: {
                    ZStack {
                        if let thumb = clip.thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.2))
                        }
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .frame(width: 54, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(Formatting.timecode(clip.duration)) · \(clip.selectedCount)/\(clip.scenes.count) key scenes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Tap to play")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    model.removeClip(clipID: clip.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }

            DisclosureGroup {
                VStack(spacing: 2) {
                    ForEach(clip.scenes) { scene in
                        SceneRow(scene: scene) {
                            model.toggleScene(clipID: clip.id, sceneID: scene.id)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Key scenes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "paintpalette")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Match reel") { model.setClipLook(clipID: clip.id, look: nil) }
                    ForEach(Look.allCases) { look in
                        Button(look.rawValue) { model.setClipLook(clipID: clip.id, look: look) }
                    }
                } label: {
                    Text("Look: \(clip.look?.rawValue ?? "Match reel")")
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Export

    private var exportArea: some View {
        VStack(spacing: 8) {
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
                    Label(model.phase == .done ? "Re-export reel" : "Build reel", systemImage: "sparkles.rectangle.stack")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canExport)
            }

            Text("Reels export without audio — add music in Photos or your editor.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Result

    private func resultCard(url: URL) -> some View {
        VStack(spacing: 14) {
            Label("Your reel is ready", systemImage: "checkmark.circle.fill")
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
}

/// Full-screen player used to preview a source clip (or photo still) from the list.
private struct ClipPlayer: View {
    let url: URL
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
            }
            .onDisappear { player.pause() }
    }
}

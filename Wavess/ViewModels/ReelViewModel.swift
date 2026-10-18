import AVFoundation
import Observation
import SwiftUI

/// Orchestrates building a reel from several source videos: analyzes each clip,
/// auto-selects its key scenes, stitches them with selective transitions, and
/// exports one combined video.
@MainActor
@Observable
final class ReelViewModel {

    enum Phase: Equatable {
        case empty
        case analyzing
        case ready
        case exporting
        case done
    }

    // MARK: Inputs

    var settings = AnalysisSettings()
    var transition = TransitionSettings()

    // MARK: State

    private(set) var clips: [ReelClip] = []

    var phase: Phase = .empty
    var progress: Double = 0
    var statusMessage: String = ""
    var errorMessage: String?
    private(set) var resultURL: URL?

    // MARK: Derived

    var totalSelectedScenes: Int {
        clips.reduce(0) { $0 + $1.selectedCount }
    }

    /// Rough estimate of the finished reel's length: selected scene durations
    /// minus the time removed by overlapping transitions.
    var estimatedDuration: Double {
        let segments = makeSegments()
        guard !segments.isEmpty else { return 0 }
        let raw = segments.reduce(0.0) { $0 + $1.range.duration.seconds }
        let overlaps = segments.dropLast().enumerated().reduce(0.0) { acc, pair in
            segments[pair.offset].transitionIntoNext ? acc + transition.duration : acc
        }
        return max(0, raw - overlaps)
    }

    var canExport: Bool {
        (phase == .ready || phase == .done) && totalSelectedScenes > 0
    }

    // MARK: - Loading & analysis

    func loadClips(urls: [URL]) async {
        reset()
        guard !urls.isEmpty else { return }
        phase = .analyzing

        var loaded: [ReelClip] = []
        for (index, url) in urls.enumerated() {
            progress = Double(index) / Double(urls.count)
            statusMessage = "Analyzing clip \(index + 1) of \(urls.count)…"

            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }

            let frames = await FrameSampler().sample(asset: asset, total: duration, fps: settings.sampleFPS)
            var scenes = SceneDetector().detectScenes(frames: frames, total: duration, settings: settings)
            selectKeyScenes(&scenes, duration: duration.seconds, fraction: transition.perClipFraction)

            loaded.append(ReelClip(url: url, asset: asset, duration: duration.seconds, scenes: scenes))
        }

        clips = loaded
        progress = 1
        statusMessage = ""
        resultURL = nil

        if clips.isEmpty {
            errorMessage = "Couldn't read the selected videos."
            phase = .empty
        } else {
            phase = .ready
        }
    }

    /// Re-picks key scenes for every clip at the current target fraction.
    func reselectKeyScenes() {
        for index in clips.indices {
            var scenes = clips[index].scenes
            selectKeyScenes(&scenes, duration: clips[index].duration, fraction: transition.perClipFraction)
            clips[index].scenes = scenes
        }
        resultURL = nil
    }

    func toggleScene(clipID: UUID, sceneID: UUID) {
        guard
            let clipIndex = clips.firstIndex(where: { $0.id == clipID }),
            let sceneIndex = clips[clipIndex].scenes.firstIndex(where: { $0.id == sceneID })
        else { return }
        clips[clipIndex].scenes[sceneIndex].isSelected.toggle()
        resultURL = nil
    }

    // MARK: - Export

    func export() async {
        let segments = makeSegments()
        guard !segments.isEmpty else {
            errorMessage = "Select at least one scene to include."
            return
        }

        phase = .exporting
        progress = 0
        errorMessage = nil
        statusMessage = "Building your reel…"

        do {
            let builder = ReelBuilder()
            let (composition, videoComposition) = try await builder.build(
                segments: segments,
                transitionDuration: transition.duration
            )
            let url = try await VideoComposer().export(composition, videoComposition: videoComposition) { [weak self] value in
                Task { @MainActor in self?.progress = Double(value) }
            }
            resultURL = url
            statusMessage = ""
            phase = .done
        } catch {
            errorMessage = (error as? EditorError)?.localizedDescription ?? error.localizedDescription
            statusMessage = ""
            phase = .ready
        }
    }

    func saveResultToPhotos() async -> Bool {
        guard let resultURL else { return false }
        do {
            try await PhotoSaver.save(resultURL)
            return true
        } catch {
            errorMessage = (error as? EditorError)?.localizedDescription ?? error.localizedDescription
            return false
        }
    }

    func reset() {
        clips = []
        phase = .empty
        progress = 0
        statusMessage = ""
        errorMessage = nil
        resultURL = nil
    }

    // MARK: - Helpers

    /// Flattens every clip's selected scenes into ordered segments, marking each
    /// boundary that should carry a transition.
    func makeSegments() -> [ReelSegment] {
        var flat: [(clipIndex: Int, asset: AVURLAsset, range: CMTimeRange)] = []
        for (clipIndex, clip) in clips.enumerated() {
            for scene in clip.selectedScenes {
                flat.append((clipIndex, clip.asset, scene.range))
            }
        }

        return flat.enumerated().map { index, item in
            var wantsTransition = false
            if index < flat.count - 1 {
                let crossesClip = flat[index + 1].clipIndex != item.clipIndex
                wantsTransition = transition.wantsTransition(crossesClip: crossesClip)
            }
            return ReelSegment(asset: item.asset, range: item.range, transitionIntoNext: wantsTransition)
        }
    }

    private func selectKeyScenes(_ scenes: inout [Scene], duration: Double, fraction: Double) {
        guard !scenes.isEmpty else { return }
        let target = duration * fraction
        let ranked = scenes.enumerated().sorted { $0.element.score > $1.element.score }

        var accumulated = 0.0
        var chosen = Set<Int>()
        for (index, scene) in ranked {
            if accumulated >= target && !chosen.isEmpty { break }
            chosen.insert(index)
            accumulated += scene.duration
        }

        for index in scenes.indices {
            scenes[index].isSelected = chosen.contains(index)
        }
    }
}

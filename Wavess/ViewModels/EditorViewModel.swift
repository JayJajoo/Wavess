import AVFoundation
import Observation
import SwiftUI

/// Drives the whole edit: loading a clip, running the on-device analysis,
/// turning the results + user settings into a set of "keep" ranges, and
/// exporting the final video.
@MainActor
@Observable
final class EditorViewModel {

    enum Phase: Equatable {
        case empty        // no clip loaded yet
        case analyzing
        case ready        // analyzed, user can tweak and export
        case exporting
        case done
    }

    enum Mode: String, CaseIterable, Identifiable {
        case trimStill = "Still"
        case highlights = "Highlights"
        case trimSilence = "Silence"
        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .trimStill:   return "Cut static / stopped stretches — great for scenery & driving"
            case .highlights:  return "Auto-pick the most dynamic scenes into a short cut"
            case .trimSilence: return "Cut quiet gaps — for talking videos"
            }
        }
    }

    // MARK: Source

    private(set) var sourceURL: URL?
    private(set) var asset: AVURLAsset?
    private(set) var duration: Double = 0

    // MARK: Inputs

    var settings = AnalysisSettings()
    var mode: Mode = .trimStill

    // MARK: Analysis results

    /// Cached frame sample — reused so slider tweaks recompute instantly without
    /// re-decoding the video.
    private var frames: [SampledFrame] = []
    private(set) var stillRanges: [CMTimeRange] = []
    private(set) var silentRanges: [CMTimeRange] = []
    var scenes: [Scene] = []

    // MARK: Status

    var phase: Phase = .empty
    var progress: Double = 0
    var statusMessage: String = ""
    var errorMessage: String?

    private(set) var resultURL: URL?

    // MARK: - Derived values

    /// The ranges that will make it into the exported video, in order.
    var keepRanges: [CMTimeRange] {
        guard duration > 0 else { return [] }
        let total = TimeRangeMath.time(duration)

        switch mode {
        case .trimStill:
            let moving = TimeRangeMath.invert(stillRanges, total: total)
            return TimeRangeMath.pad(moving, by: settings.keepPadding, total: total)
        case .trimSilence:
            let speech = TimeRangeMath.invert(silentRanges, total: total)
            return TimeRangeMath.pad(speech, by: settings.keepPadding, total: total)
        case .highlights:
            let selected = scenes
                .filter(\.isSelected)
                .sorted { $0.range.start < $1.range.start }
                .map(\.range)
            return TimeRangeMath.merge(selected)
        }
    }

    var estimatedDuration: Double {
        TimeRangeMath.totalSeconds(keepRanges)
    }

    var timeSaved: Double {
        max(0, duration - estimatedDuration)
    }

    var selectedSceneCount: Int {
        scenes.filter(\.isSelected).count
    }

    var hasAudio: Bool {
        !silentRanges.isEmpty || audioTrackPresent
    }
    private var audioTrackPresent = false

    var canExport: Bool {
        (phase == .ready || phase == .done) && !keepRanges.isEmpty
    }

    // MARK: - Actions

    func load(url: URL) async {
        reset()
        sourceURL = url
        let asset = AVURLAsset(url: url)
        self.asset = asset

        do {
            let loadedDuration = try await asset.load(.duration)
            duration = loadedDuration.seconds
            audioTrackPresent = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
            await analyze()
        } catch {
            fail(error)
        }
    }

    /// Full analysis: sample frames once, then derive scenes, still ranges, and
    /// (if there's audio) silent ranges.
    func analyze() async {
        guard let asset else { return }
        phase = .analyzing
        progress = 0
        errorMessage = nil
        resultURL = nil

        let total = TimeRangeMath.time(duration)

        statusMessage = "Scanning the video…"
        frames = await FrameSampler().sample(asset: asset, total: total, fps: settings.sampleFPS)
        progress = 0.55

        statusMessage = "Finding scenes & motion…"
        recomputeVisual()
        progress = 0.8

        statusMessage = "Checking audio…"
        silentRanges = (try? await SilenceDetector().detectSilence(in: asset, settings: settings)) ?? []

        progress = 1
        statusMessage = ""
        phase = .ready
    }

    /// Recomputes scene and still results from the cached frames — fast, no I/O.
    /// Used when a visual slider (still threshold, min still, scene sensitivity)
    /// changes.
    func recomputeVisual() {
        guard duration > 0 else { return }
        let total = TimeRangeMath.time(duration)
        scenes = SceneDetector().detectScenes(frames: frames, total: total, settings: settings)
        stillRanges = MotionAnalyzer().detectStillRanges(frames: frames, total: total, settings: settings)
        autoSelectHighlights()
    }

    /// Re-runs only the audio silence pass. Used when a silence slider changes.
    func recomputeAudio() async {
        guard let asset else { return }
        silentRanges = (try? await SilenceDetector().detectSilence(in: asset, settings: settings)) ?? []
    }

    /// Picks the highest-scoring scenes until the highlight reel reaches the
    /// target fraction of the original length.
    func autoSelectHighlights() {
        guard !scenes.isEmpty else { return }
        let targetSeconds = duration * settings.highlightTargetFraction
        let ranked = scenes.enumerated().sorted { $0.element.score > $1.element.score }

        var accumulated = 0.0
        var chosen = Set<Int>()
        for (index, scene) in ranked {
            if accumulated >= targetSeconds && !chosen.isEmpty { break }
            chosen.insert(index)
            accumulated += scene.duration
        }

        for index in scenes.indices {
            scenes[index].isSelected = chosen.contains(index)
        }
    }

    func toggleScene(_ scene: Scene) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index].isSelected.toggle()
    }

    func export() async {
        guard let asset else { return }
        let ranges = keepRanges
        guard !ranges.isEmpty else {
            errorMessage = EditorError.nothingToExport.localizedDescription
            return
        }

        phase = .exporting
        progress = 0
        errorMessage = nil
        statusMessage = "Rendering your cut…"

        do {
            let composer = VideoComposer()
            let composition = try await composer.makeComposition(asset: asset, keep: ranges)
            let url = try await composer.export(composition) { [weak self] value in
                Task { @MainActor in self?.progress = Double(value) }
            }
            resultURL = url
            statusMessage = ""
            phase = .done
        } catch {
            fail(error)
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
        sourceURL = nil
        asset = nil
        duration = 0
        frames = []
        stillRanges = []
        silentRanges = []
        scenes = []
        audioTrackPresent = false
        resultURL = nil
        progress = 0
        statusMessage = ""
        errorMessage = nil
        phase = .empty
    }

    // MARK: - Helpers

    private func fail(_ error: Error) {
        errorMessage = (error as? EditorError)?.localizedDescription ?? error.localizedDescription
        statusMessage = ""
        if phase == .analyzing { phase = asset == nil ? .empty : .ready }
    }
}

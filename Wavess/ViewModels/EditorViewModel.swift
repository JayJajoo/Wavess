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
        case tighten = "Tighten"
        case highlights = "Highlights"
        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .tighten: return "Remove silent gaps, keep the talking"
            case .highlights: return "Auto-pick the best scenes into a short cut"
            }
        }
    }

    // MARK: Source

    private(set) var sourceURL: URL?
    private(set) var asset: AVURLAsset?
    private(set) var duration: Double = 0

    // MARK: Inputs

    var settings = AnalysisSettings()
    var mode: Mode = .tighten

    // MARK: Analysis results

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
        case .tighten:
            let speech = TimeRangeMath.invert(silentRanges, total: total)
            return TimeRangeMath.pad(speech, by: settings.speechPadding, total: total)
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
            await analyze()
        } catch {
            fail(error)
        }
    }

    func analyze() async {
        guard let asset else { return }
        phase = .analyzing
        progress = 0
        errorMessage = nil
        resultURL = nil

        do {
            statusMessage = "Listening for silence…"
            let silence = try await SilenceDetector().detectSilence(in: asset, settings: settings)
            silentRanges = silence
            progress = 0.5

            statusMessage = "Scanning for scenes…"
            let total = TimeRangeMath.time(duration)
            let detected = try await SceneDetector().detectScenes(in: asset, total: total, settings: settings)
            scenes = detected
            autoSelectHighlights()

            progress = 1
            statusMessage = ""
            phase = .ready
        } catch {
            fail(error)
        }
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
        silentRanges = []
        scenes = []
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

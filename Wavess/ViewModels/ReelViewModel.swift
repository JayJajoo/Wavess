import AVFoundation
import Observation
import SwiftUI

/// A beat-synced plan: where to cut, which footage fills each slot (and at what
/// speed), and which boundaries carry a transition.
struct MusicPlan {
    let cutTimes: [Double]
    let slots: [MusicSlot]
    let transitions: [Bool]
}

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

    /// Color look applied to the whole reel (per-clip looks can override it).
    var reelLook: Look = .none

    // MARK: Music

    private(set) var musicURL: URL?
    private(set) var musicAsset: AVURLAsset?
    private(set) var musicFullDuration: Double = 0
    var musicStart: Double = 0
    var musicSectionDuration: Double = 60
    /// Cut the video every N beats (1 = on every beat, 4 = once per bar-ish).
    var beatsPerCut: Int = 2
    /// Add intelligent slow-mo / fast-forward on selected beats.
    var speedEffectsEnabled = true
    private(set) var musicAnalysis: MusicAnalysis?
    var isAnalyzingMusic = false

    var hasMusic: Bool { musicAsset != nil && musicAnalysis != nil }
    var detectedBPM: Int? { musicAnalysis.map { Int($0.bpm.rounded()) } }

    /// Valid range for the "music section length" slider for the loaded track.
    var minMusicSectionDuration: Double { min(30, musicFullDuration) }
    var maxMusicSectionDuration: Double { min(120, musicFullDuration) }
    var maxMusicStart: Double { max(0, musicFullDuration - musicSectionDuration) }

    /// The chosen section expressed as an end time (start + length). Backs the
    /// "End time" control; setting it keeps the start fixed and adjusts the
    /// section length, clamped to the track and the allowed length range.
    var musicEnd: Double {
        get { musicStart + musicSectionDuration }
        set {
            let clamped = min(max(newValue, minMusicEnd), maxMusicEnd)
            musicSectionDuration = clamped - musicStart
        }
    }
    var minMusicEnd: Double { musicStart + minMusicSectionDuration }
    var maxMusicEnd: Double { min(musicFullDuration, musicStart + maxMusicSectionDuration) }

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

    /// Rough estimate of the finished reel's length. With music, the reel is the
    /// length of the chosen music section; otherwise it's the kept scene
    /// durations minus the time removed by overlapping transitions.
    var estimatedDuration: Double {
        if hasMusic { return musicSectionDuration }
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

            // Re-rank scenes by on-device visual quality (aesthetics + saliency),
            // not just motion, so the best-looking / most meaningful shots win.
            let contentScores = await VisionSceneScorer().score(asset: asset, scenes: scenes)
            applyContentScores(&scenes, content: contentScores)

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

    func setClipLook(clipID: UUID, look: Look?) {
        guard let clipIndex = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[clipIndex].look = look
        resultURL = nil
    }

    // MARK: - Export

    func export() async {
        guard totalSelectedScenes > 0 else {
            errorMessage = "Select at least one scene to include."
            return
        }

        if hasMusic, let plan = makeMusicPlan(), let musicAsset {
            await exportMusicReel(plan: plan, musicAsset: musicAsset)
        } else {
            await exportPlainReel()
        }
    }

    private func exportPlainReel() async {
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
                transitionDuration: transition.style == .none ? 0 : transition.duration,
                transition: transition.style.effect ?? .crossDissolve
            )
            let url = try await VideoComposer().export(composition, videoComposition: videoComposition) { [weak self] value in
                Task { @MainActor in self?.progress = Double(value) }
            }
            resultURL = try await gradedIfNeeded(url, spans: plainGradeSpans())
            statusMessage = ""
            phase = .done
        } catch {
            fail(error)
        }
    }

    private func exportMusicReel(plan: MusicPlan, musicAsset: AVURLAsset) async {
        phase = .exporting
        progress = 0
        errorMessage = nil
        statusMessage = "Syncing to the beat…"

        do {
            let builder = MusicReelBuilder()
            let (composition, videoComposition, audioMix) = try await builder.build(
                cutTimes: plan.cutTimes,
                slots: plan.slots,
                transitionIntoNext: plan.transitions,
                transitionDuration: transition.style == .none ? 0 : transition.duration,
                transition: transition.style.effect ?? .crossDissolve,
                music: (musicAsset, musicStart)
            )
            let url = try await VideoComposer().export(composition, videoComposition: videoComposition, audioMix: audioMix) { [weak self] value in
                Task { @MainActor in self?.progress = Double(value) }
            }
            resultURL = try await gradedIfNeeded(url, spans: musicGradeSpans(plan))
            statusMessage = ""
            phase = .done
        } catch {
            fail(error)
        }
    }

    /// Runs the color-grading pass if any span asks for a non-original look.
    private func gradedIfNeeded(_ url: URL, spans: [ColorGrader.Span]) async throws -> URL {
        guard spans.contains(where: { $0.look != .none }) else { return url }
        statusMessage = "Applying color…"
        progress = 0
        return try await ColorGrader().grade(url: url, spans: spans) { [weak self] value in
            Task { @MainActor in self?.progress = Double(value) }
        }
    }

    private func fail(_ error: Error) {
        errorMessage = (error as? EditorError)?.localizedDescription ?? error.localizedDescription
        statusMessage = ""
        phase = .ready
    }

    // MARK: - Music

    func loadMusic(url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            errorMessage = "Couldn't read that audio file."
            return
        }
        musicURL = url
        musicAsset = asset
        musicFullDuration = duration.seconds
        musicStart = 0
        musicSectionDuration = min(60, duration.seconds)
        await analyzeMusicSection()
    }

    func analyzeMusicSection() async {
        guard let musicAsset else { return }
        // Clamp the selection into the track.
        musicSectionDuration = min(max(musicSectionDuration, minMusicSectionDuration), maxMusicSectionDuration)
        musicStart = min(max(0, musicStart), maxMusicStart)

        isAnalyzingMusic = true
        musicAnalysis = try? await MusicAnalyzer().analyze(
            asset: musicAsset,
            start: musicStart,
            duration: musicSectionDuration
        )
        isAnalyzingMusic = false
        resultURL = nil
    }

    func clearMusic() {
        musicURL = nil
        musicAsset = nil
        musicFullDuration = 0
        musicStart = 0
        musicSectionDuration = 60
        musicAnalysis = nil
        resultURL = nil
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
        reelLook = .none
        clearMusic()
    }

    // MARK: - Helpers

    private struct FlatScene {
        let asset: AVURLAsset
        let range: CMTimeRange
        let clipIndex: Int
        let start: Double
        let score: Double
    }

    /// Every clip's selected key scenes, flattened into timeline order.
    private func makeFlat() -> [FlatScene] {
        var flat: [FlatScene] = []
        for (clipIndex, clip) in clips.enumerated() {
            for scene in clip.selectedScenes {
                flat.append(FlatScene(asset: clip.asset, range: scene.range, clipIndex: clipIndex, start: scene.start, score: scene.score))
            }
        }
        return flat
    }

    private func wantsTransition(at index: Int, in flat: [FlatScene]) -> Bool {
        guard index < flat.count - 1 else { return false }
        let crossesClip = flat[index + 1].clipIndex != flat[index].clipIndex
        return transition.wantsTransition(crossesClip: crossesClip)
    }

    /// Ordered segments for the plain (no-music) reel.
    func makeSegments() -> [ReelSegment] {
        let flat = makeFlat()
        return flat.indices.map { index in
            ReelSegment(asset: flat[index].asset, range: flat[index].range, transitionIntoNext: wantsTransition(at: index, in: flat))
        }
    }

    // MARK: - Music plan

    /// Scene pool for the music plan: the user's selected key scenes, topped up
    /// with the best remaining scenes (across all clips, highest score first)
    /// when there are more beat slots than selected scenes — so a long clip
    /// fills the song with distinct footage instead of repeating a handful.
    private func makeMusicPool(slotCount: Int) -> [FlatScene] {
        let selected = makeFlat()
        guard selected.count < slotCount else { return selected }

        var extras: [FlatScene] = []
        for (clipIndex, clip) in clips.enumerated() {
            for scene in clip.scenes where !scene.isSelected {
                extras.append(FlatScene(asset: clip.asset, range: scene.range, clipIndex: clipIndex, start: scene.start, score: scene.score))
            }
        }
        extras.sort { $0.score > $1.score }

        var pool = selected + Array(extras.prefix(slotCount - selected.count))
        pool.sort { ($0.clipIndex, $0.start) < ($1.clipIndex, $1.start) }
        return pool
    }

    func makeMusicPlan() -> MusicPlan? {
        guard let analysis = musicAnalysis else { return nil }
        let total = musicSectionDuration

        // Cut times: 0, every `beatsPerCut`-th beat (min slot 0.5s), then total.
        let internalBeats = analysis.beats.filter { $0 > 0.15 && $0 < total - 0.15 }
        var cuts: [Double] = [0]
        for (i, beat) in internalBeats.enumerated() where i % max(1, beatsPerCut) == 0 {
            if beat - (cuts.last ?? 0) >= 0.5 { cuts.append(beat) }
        }
        if let last = cuts.last, total - last < 0.5, cuts.count > 1 { cuts.removeLast() }
        cuts.append(total)
        guard cuts.count >= 2 else { return nil }

        let slotCount = cuts.count - 1

        // Fill one scene per beat slot. Source footage is virtually always
        // longer than the chosen song section, so when the selected key scenes
        // don't cover every slot we top the pool up with the next best-scoring
        // scenes instead of just repeating the few selected ones — a longer clip
        // then fills the song with distinct footage.
        let pool = makeMusicPool(slotCount: slotCount)
        guard !pool.isEmpty else { return nil }

        var slots: [MusicSlot] = (0..<slotCount).map { j in
            let item = pool[j % pool.count]
            return MusicSlot(asset: item.asset, sourceStart: item.start, clipIndex: item.clipIndex)
        }
        let transitions: [Bool] = (0..<slotCount).map { j in
            guard j < slotCount - 1 else { return false }
            let crosses = slots[j + 1].clipIndex != slots[j].clipIndex
            return transition.wantsTransition(crossesClip: crosses)
        }

        if speedEffectsEnabled {
            assignSpeeds(&slots, cuts: cuts, pool: pool, analysis: analysis)
        }

        return MusicPlan(cutTimes: cuts, slots: slots, transitions: transitions)
    }

    /// Intelligently places slow-mo / fast-forward on a *subset* of beats:
    /// slow-mo on strong, visually dynamic beats (drops), fast-forward through
    /// long static stretches — never two effects back-to-back.
    private func assignSpeeds(_ slots: inout [MusicSlot], cuts: [Double], pool: [FlatScene], analysis: MusicAnalysis) {
        let count = slots.count
        guard count > 2 else { return }

        var beatStrength = [Double](repeating: 0.5, count: count)
        var sceneScore = [Double](repeating: 0, count: count)
        var slotLength = [Double](repeating: 0, count: count)
        for j in 0..<count {
            beatStrength[j] = analysis.strength(at: cuts[j])
            sceneScore[j] = pool[j % pool.count].score
            slotLength[j] = cuts[j + 1] - cuts[j]
        }

        func quantile(_ values: [Double], _ q: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
        }
        let strongBeat = quantile(beatStrength, 0.8)   // top ~20% of beats
        let highMotion = quantile(sceneScore, 0.5)     // above median motion
        let lowMotion = quantile(sceneScore, 0.3)      // bottom ~30% motion
        let avgLength = slotLength.reduce(0, +) / Double(count)

        var previousChanged = false
        for j in 0..<count {
            if previousChanged { previousChanged = false; continue }
            if beatStrength[j] >= strongBeat && sceneScore[j] >= highMotion {
                slots[j].speed = 0.5          // dramatic slow-mo on a strong, dynamic beat
                previousChanged = true
            } else if sceneScore[j] <= lowMotion && slotLength[j] >= avgLength {
                slots[j].speed = 1.8          // speed through long, static footage
                previousChanged = true
            }
        }
    }

    // MARK: - Color grade spans

    private func lookForClip(_ clipIndex: Int) -> Look {
        (clipIndex < clips.count ? clips[clipIndex].look : nil) ?? reelLook
    }

    private func musicGradeSpans(_ plan: MusicPlan) -> [ColorGrader.Span] {
        plan.slots.indices.map { j in
            ColorGrader.Span(start: plan.cutTimes[j], end: plan.cutTimes[j + 1], look: lookForClip(plan.slots[j].clipIndex))
        }
    }

    private func plainGradeSpans() -> [ColorGrader.Span] {
        let flat = makeFlat()
        guard !flat.isEmpty else { return [] }
        let durations = flat.map { $0.range.duration.seconds }
        let transitions = flat.indices.map { wantsTransition(at: $0, in: flat) }
        let layout = ReelLayout.compute(
            durations: durations,
            transitionIntoNext: transitions,
            transitionDuration: transition.style == .none ? 0 : transition.duration
        )

        var spans: [ColorGrader.Span] = []
        var boundary = 0.0
        for i in flat.indices {
            let next = (i == flat.count - 1) ? layout.total : layout.starts[i + 1] + layout.overlaps[i] / 2
            spans.append(ColorGrader.Span(start: boundary, end: next, look: lookForClip(flat[i].clipIndex)))
            boundary = next
        }
        return spans
    }

    /// Blends Vision content scores (0...1) with the motion-based scene scores so
    /// selection is led by visual quality but still rewards dynamic, longer shots.
    /// If Vision produced nothing (older OS or a failure), scores are left as-is.
    private func applyContentScores(_ scenes: inout [Scene], content: [Double]) {
        guard scenes.count == content.count,
              let maxContent = content.max(), maxContent > 0.0001 else { return }
        let maxMotion = scenes.map(\.score).max() ?? 0
        for i in scenes.indices {
            let motion = maxMotion > 0 ? scenes[i].score / maxMotion : 0   // 0...1, duration-aware
            scenes[i].score = 0.6 * content[i] + 0.4 * motion
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

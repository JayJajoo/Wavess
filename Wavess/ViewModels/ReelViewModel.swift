import AVFoundation
import Observation
import SwiftUI

/// A beat-synced plan: where to cut, which footage fills each slot (and at what
/// speed), and which boundaries carry a transition.
struct MusicPlan {
    let cutTimes: [Double]
    let slots: [MusicSlot]
    /// Per-boundary transition effect (index j = from slot j into j+1). `nil`
    /// means a hard cut at that boundary; the last entry is always `nil`.
    let transitions: [ReelTransition?]
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
    /// When on, the cut pace follows the song's energy — fast cuts in intense
    /// sections, longer holds in calm ones. When off, `beatsPerCut` is used.
    var autoPace: Bool = true
    /// Manual pace: cut every N beats (1 = on every beat, 4 = once per bar-ish).
    var beatsPerCut: Int = 2
    /// Add intelligent slow-mo / fast-forward on selected beats.
    var speedEffectsEnabled = true
    private(set) var musicAnalysis: MusicAnalysis?
    var isAnalyzingMusic = false
    /// Coarse amplitude envelope of the whole song (0...1), for the trimmer waveform.
    private(set) var musicWaveform: [Float] = []

    // MARK: Music preview playback
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: Timer?
    /// Whether the section preview is currently playing.
    var isPreviewingMusic = false
    /// Current playhead, in absolute seconds within the track (kept inside the
    /// chosen start…end section). Drives — and is driven by — the scrubber.
    var previewTime: Double = 0

    var hasMusic: Bool { musicAsset != nil && musicAnalysis != nil }
    var detectedBPM: Int? { musicAnalysis.map { Int($0.bpm.rounded()) } }

    /// Valid range for the "music section length" slider for the loaded track.
    var minMusicSectionDuration: Double { min(30, musicFullDuration) }
    var maxMusicSectionDuration: Double { musicFullDuration }
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

        // Target frame for photos = the reel's video aspect, so a photo fills the
        // same frame as the videos (with a blurred background) instead of
        // letterboxing to a different height. Defaults to vertical 9:16.
        let photoTarget = await reelVideoFrameSize(urls: urls)

        var loaded: [ReelClip] = []
        for (index, url) in urls.enumerated() {
            progress = Double(index) / Double(urls.count)
            statusMessage = "Analyzing item \(index + 1) of \(urls.count)…"

            // Photos arrive as images — turn each into a short still video so it
            // flows through the same analysis/compose pipeline as a video clip
            // and keeps its place in the selected order (photos between videos).
            var clipURL = url
            let hasVideoTrack = ((try? await AVURLAsset(url: url).loadTracks(withMediaType: .video))?.isEmpty == false)
            if !hasVideoTrack {
                guard let stillURL = await ImageClipMaker.makeStillVideo(from: url, targetSize: photoTarget) else { continue }
                clipURL = stillURL
            }

            let asset = AVURLAsset(url: clipURL)
            guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }

            let frames = await FrameSampler().sample(asset: asset, total: duration, fps: settings.sampleFPS)
            var scenes = SceneDetector().detectScenes(frames: frames, total: duration, settings: settings)

            // Re-rank scenes by on-device visual quality (aesthetics + saliency),
            // not just motion, so the best-looking / most meaningful shots win.
            let contentScores = await VisionSceneScorer().score(asset: asset, scenes: scenes)
            applyContentScores(&scenes, content: contentScores)

            selectKeyScenes(&scenes, duration: duration.seconds, fraction: transition.perClipFraction)

            let thumbnail = await ThumbnailMaker.make(asset: asset)
            loaded.append(ReelClip(url: clipURL, asset: asset, duration: duration.seconds, scenes: scenes, thumbnail: thumbnail))
        }

        clips = loaded
        progress = 1
        statusMessage = ""
        resultURL = nil

        if clips.isEmpty {
            errorMessage = "Couldn't read the selected photos or videos."
            phase = .empty
        } else {
            phase = .ready
        }
    }

    /// The oriented frame size of the first real video in the selection — the
    /// aspect photos should fill. Falls back to vertical 9:16 when there are no
    /// videos (all photos).
    private func reelVideoFrameSize(urls: [URL]) async -> CGSize {
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let natural = (try? await track.load(.naturalSize)) ?? .zero
            let oriented = VideoGeometry.orientedSize(natural: natural, transform: transform)
            if oriented.width > 1, oriented.height > 1 { return oriented }
        }
        return CGSize(width: 1080, height: 1920)
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

    /// Remove a clip (or photo) from the reel.
    func removeClip(clipID: UUID) {
        clips.removeAll { $0.id == clipID }
        resultURL = nil
        if clips.isEmpty { phase = .empty }
    }

    // MARK: - Export

    func export() async {
        stopPreview()
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
                boundaryTransitions: plan.transitions,
                transitionDuration: transition.style == .none ? 0 : transition.duration,
                music: (musicAsset, musicStart, musicSectionDuration)
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
        musicWaveform = await WaveformSampler.sample(asset: asset)
        await analyzeMusicSection()
    }

    func analyzeMusicSection() async {
        guard let musicAsset else { return }
        // Clamp the selection into the track.
        musicSectionDuration = min(max(musicSectionDuration, minMusicSectionDuration), maxMusicSectionDuration)
        musicStart = min(max(0, musicStart), maxMusicStart)

        // The section moved — snap the preview playhead back to the new start.
        pausePreview()
        previewTime = musicStart

        isAnalyzingMusic = true
        musicAnalysis = try? await MusicAnalyzer().analyze(
            asset: musicAsset,
            start: musicStart,
            duration: musicSectionDuration
        )
        isAnalyzingMusic = false
        rebalanceKeyScenesForMusic()
        resultURL = nil
    }

    /// Sizes how many moments to keep per clip so the whole reel fits the chosen
    /// music section — instead of a fixed 30%. Longer music ⇒ keep more per clip;
    /// shorter music ⇒ compress to fewer. Every clip keeps at least one moment.
    private func rebalanceKeyScenesForMusic() {
        guard let analysis = musicAnalysis, !clips.isEmpty else { return }
        let section = musicSectionDuration
        let internalBeats = analysis.beats.filter { $0 > 0.15 && $0 < section - 0.15 }.count
        let intervals = max(1, internalBeats + 1)
        // Average beats per cut: Auto varies ~1–4 (≈2.5), else the manual pace.
        let averageSpan = autoPace ? 2.5 : Double(max(1, beatsPerCut))
        let targetMoments = max(1, Int((Double(intervals) / averageSpan).rounded()))

        let totalCandidates = clips.reduce(0) { $0 + $1.scenes.count }
        guard totalCandidates > 0 else { return }

        // Fraction of each clip's moments to keep so the totals fill the section.
        transition.perClipFraction = min(1.0, max(0.05, Double(targetMoments) / Double(totalCandidates)))
        reselectKeyScenes()
    }

    func clearMusic() {
        stopPreview()
        previewTime = 0
        musicWaveform = []
        musicURL = nil
        musicAsset = nil
        musicFullDuration = 0
        musicStart = 0
        musicSectionDuration = 60
        musicAnalysis = nil
        resultURL = nil
    }

    // MARK: - Music preview

    /// Play / pause the section preview.
    func togglePreview() {
        isPreviewingMusic ? pausePreview() : startPreview()
    }

    func startPreview() {
        guard let musicURL else { return }
        if previewPlayer == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            previewPlayer = try? AVAudioPlayer(contentsOf: musicURL)
            previewPlayer?.prepareToPlay()
        }
        guard let player = previewPlayer else { return }
        if previewTime < musicStart || previewTime >= musicEnd { previewTime = musicStart }
        player.currentTime = previewTime
        player.play()
        isPreviewingMusic = true

        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPreview() }
        }
    }

    func pausePreview() {
        previewPlayer?.pause()
        isPreviewingMusic = false
        previewTimer?.invalidate()
        previewTimer = nil
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewingMusic = false
        previewTimer?.invalidate()
        previewTimer = nil
    }

    /// Move the playhead (from the scrubber); plays on from there if previewing.
    func seekPreview(to time: Double) {
        let clamped = min(max(time, musicStart), max(musicStart, musicEnd))
        previewTime = clamped
        previewPlayer?.currentTime = clamped
    }

    private func tickPreview() {
        guard let player = previewPlayer, isPreviewingMusic else { return }
        previewTime = player.currentTime
        if previewTime >= musicEnd {           // loop within the chosen section
            seekPreview(to: musicStart)
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

    func makeMusicPlan() -> MusicPlan? {
        guard let analysis = musicAnalysis else { return nil }
        let section = musicSectionDuration
        guard section > 0.5 else { return nil }

        // Every selected scene, in selection/timeline order, used exactly once —
        // nothing repeated, nothing skipped. The reel grows (and the music loops
        // under it) to fit them all, instead of being capped to the music section.
        let pool = makeFlat()
        guard !pool.isEmpty else { return nil }
        let maxScore = pool.map(\.score).max() ?? 0

        // One loop's worth of beat cut-points within the chosen section.
        let internalBeats = analysis.beats.filter { $0 > 0.15 && $0 < section - 0.15 }.sorted()
        let baseGrid = Array(Set([0] + internalBeats + [section])).sorted()
        let baseIntervals = baseGrid.count - 1
        guard baseIntervals >= 1 else { return nil }

        // Loudness envelope (0...1 per beat) for Auto pacing: calm verses hold
        // longer, loud build-ups and choruses cut faster.
        let energyEnvelope = analysis.beatEnergies
        func autoBeats(sectionTime t: Double) -> Double {
            guard !energyEnvelope.isEmpty else { return 2 }
            var nearest = 0
            var nearestDelta = Double.greatestFiniteMagnitude
            for (i, beat) in analysis.beats.enumerated() where i < energyEnvelope.count {
                let delta = abs(beat - t)
                if delta < nearestDelta { nearestDelta = delta; nearest = i }
            }
            return 1 + (1 - energyEnvelope[nearest]) * 3   // loud → ~1 beat/cut, quiet → ~4
        }

        // Fill the chosen section ONCE, in order: place scenes until the music runs
        // out. The reel never grows past the section (so it matches your music
        // length), and scenes keep their selected/timeline order — no reordering.
        var cuts: [Double] = [0]
        var chosen: [FlatScene] = []
        var cursor = 0
        var poolIndex = 0
        while cursor < baseIntervals && poolIndex < pool.count {
            let item = pool[poolIndex]
            let norm = maxScore > 0 ? max(0, min(1, item.score / maxScore)) : 0.5
            let baseline = autoPace ? autoBeats(sectionTime: baseGrid[cursor]) : Double(max(1, beatsPerCut))
            let span = max(1, Int((baseline * (0.5 + norm)).rounded()))
            var next = min(cursor + span, baseIntervals)
            while next < baseIntervals && baseGrid[next] - baseGrid[cursor] < 0.5 { next += 1 }        // slots ≥ 0.5s
            if next < baseIntervals && baseGrid[baseIntervals] - baseGrid[next] < 0.5 { next = baseIntervals }  // no tiny tail
            cuts.append(baseGrid[next])
            chosen.append(item)
            cursor = next
            poolIndex += 1
        }
        guard !chosen.isEmpty, cuts.count == chosen.count + 1 else { return nil }

        // Mark the slot that lands on the drop (hard cut + slow-mo applied below) —
        // without reordering, so the sequence stays intact.
        var dropSlot: Int?
        if let dropBeat = analysis.dropBeatIndex, dropBeat < analysis.beats.count {
            let dropTime = analysis.beats[dropBeat]
            dropSlot = (0..<chosen.count).first(where: { cuts[$0] <= dropTime && dropTime < cuts[$0 + 1] })
        }

        var slots: [MusicSlot] = chosen.map {
            MusicSlot(asset: $0.asset, sourceStart: $0.start, clipIndex: $0.clipIndex)
        }
        let sceneScores: [Double] = chosen.map { maxScore > 0 ? max(0, min(1, $0.score / maxScore)) : 0.5 }

        // Per-boundary transition (Auto analyses each stitch; fixed styles use the
        // frequency rule; the last boundary is nil). Beat strength is read
        // section-relative so it stays meaningful across loops.
        let boundaryStrength: [Double] = (0..<max(0, slots.count - 1)).map {
            analysis.strength(at: cuts[$0 + 1].truncatingRemainder(dividingBy: section))
        }
        let maxStrength = boundaryStrength.max() ?? 0
        var transitions: [ReelTransition?] = (0..<slots.count).map { j in
            guard j < slots.count - 1 else { return nil }
            let crosses = slots[j + 1].clipIndex != slots[j].clipIndex
            if transition.style.isAuto {
                let strengthNorm = maxStrength > 0 ? boundaryStrength[j] / maxStrength : 0.5
                return autoTransition(strengthNorm: strengthNorm, crosses: crosses,
                                      scoreA: sceneScores[j], scoreB: sceneScores[j + 1])
            } else {
                guard transition.wantsTransition(crossesClip: crosses) else { return nil }
                return transition.style.effect
            }
        }

        if speedEffectsEnabled {
            assignSpeeds(&slots, cuts: cuts, sceneScores: sceneScores, analysis: analysis)
        }

        // Drop impact: hard cut into the hero shot, and hold it in slow motion.
        if let slot = dropSlot {
            if slot > 0 { transitions[slot - 1] = nil }
            if speedEffectsEnabled { slots[slot].speed = 0.5 }
        }

        return MusicPlan(cutTimes: cuts, slots: slots, transitions: transitions)
    }

    /// Picks a transition for one stitch from the analysis (not at random):
    /// strong beats punch (hard cut within a clip, energetic slide across clips),
    /// softer clip changes blend (dissolve, or dip-to-black when quality dips),
    /// and gentle in-clip boundaries get a soft dissolve or a clean cut.
    private func autoTransition(strengthNorm: Double, crosses: Bool, scoreA: Double, scoreB: Double) -> ReelTransition? {
        if strengthNorm > 0.75 {
            return crosses ? .slide : nil          // punch on the strong beat
        } else if crosses {
            return min(scoreA, scoreB) < 0.4 ? .fadeToBlack : .crossDissolve
        } else {
            return strengthNorm < 0.4 ? .crossDissolve : nil
        }
    }

    /// Intelligently places slow-mo / fast-forward on a *subset* of beats:
    /// slow-mo on strong, visually dynamic beats (drops), fast-forward through
    /// long static stretches — never two effects back-to-back.
    private func assignSpeeds(_ slots: inout [MusicSlot], cuts: [Double], sceneScores: [Double], analysis: MusicAnalysis) {
        let count = slots.count
        guard count > 2, sceneScores.count == count else { return }

        var beatStrength = [Double](repeating: 0.5, count: count)
        var sceneScore = [Double](repeating: 0, count: count)
        var slotLength = [Double](repeating: 0, count: count)
        for j in 0..<count {
            beatStrength[j] = analysis.strength(at: cuts[j])
            sceneScore[j] = sceneScores[j]
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

    /// Blends Vision content scores (0...1) with the motion-based scene scores.
    /// Selection is led strongly by visual quality (so a calm, beautiful shot
    /// beats a busy-but-plain one); motion is only a light nudge so the busiest
    /// stretches don't dominate. If Vision produced nothing, scores are left as-is.
    private func applyContentScores(_ scenes: inout [Scene], content: [Double]) {
        guard scenes.count == content.count,
              let maxContent = content.max(), maxContent > 0.0001 else { return }
        let maxMotion = scenes.map(\.score).max() ?? 0
        for i in scenes.indices {
            let motion = maxMotion > 0 ? scenes[i].score / maxMotion : 0   // 0...1, duration-aware
            scenes[i].score = 0.85 * content[i] + 0.15 * motion
        }
    }

    private func selectKeyScenes(_ scenes: inout [Scene], duration: Double, fraction: Double) {
        guard !scenes.isEmpty else { return }
        let n = scenes.count
        // How many scenes to keep (a fraction of the candidates), at least one.
        let keep = max(1, Int((Double(n) * fraction).rounded()))

        var chosen = Set<Int>()
        if keep >= n {
            chosen = Set(scenes.indices)
        } else {
            // Spread the picks across the clip's timeline so calm stretches are
            // represented too — divide into `keep` time buckets and take the
            // best-looking scene from each (not just the busiest region).
            for b in 0..<keep {
                let lo = b * n / keep
                let hi = max(lo + 1, (b + 1) * n / keep)
                let bucket = lo..<min(hi, n)
                if let best = bucket.max(by: { scenes[$0].score < scenes[$1].score }) {
                    chosen.insert(best)
                }
            }
        }

        for index in scenes.indices {
            scenes[index].isSelected = chosen.contains(index)
        }
    }
}

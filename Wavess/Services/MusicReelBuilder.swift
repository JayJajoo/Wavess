import AVFoundation
import CoreGraphics
import Foundation

/// One beat-slot's video source: which clip to pull from, where, and at what
/// playback speed (1 = normal, <1 = slow motion, >1 = fast forward). The slot
/// always occupies the same on-beat timeline length regardless of speed.
struct MusicSlot {
    let asset: AVURLAsset
    let sourceStart: Double
    let clipIndex: Int
    var speed: Double = 1.0
}

/// Builds a music-synced reel: video segments are placed so their cuts land on
/// the beat grid, transitions are centered on the beat (so the perceived cut
/// stays on-beat and the timeline length is preserved), and the chosen music
/// section is laid under the whole thing as the soundtrack.
struct MusicReelBuilder {

    private let frameRate: Int32 = 30

    private struct SourceInfo {
        let videoTrack: AVAssetTrack
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
        let duration: Double
    }

    /// - Parameters:
    ///   - cutTimes: beat-aligned boundaries including 0 and the total; length == slots + 1.
    ///   - slots: one source descriptor per slot (cutTimes.count - 1 of them).
    ///   - transitionIntoNext: per slot, whether a dissolve bridges into the next (last is ignored).
    ///   - transitionDuration: requested dissolve length (clamped per the shortest slot).
    ///   - music: the soundtrack asset and the start time of the chosen section.
    func build(
        cutTimes: [Double],
        slots: [MusicSlot],
        boundaryTransitions: [ReelTransition?],
        transitionDuration: Double,
        music: (asset: AVURLAsset, start: Double)
    ) async throws -> (composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix?) {
        guard slots.count >= 1,
              cutTimes.count == slots.count + 1,
              boundaryTransitions.count == slots.count else {
            throw EditorError.nothingToExport
        }

        // Load each distinct source once.
        var infoCache: [ObjectIdentifier: SourceInfo] = [:]
        for slot in slots {
            let key = ObjectIdentifier(slot.asset)
            if infoCache[key] == nil {
                guard let track = try await slot.asset.loadTracks(withMediaType: .video).first else {
                    throw EditorError.noVideoTrack
                }
                let transform = try await track.load(.preferredTransform)
                let natural = try await track.load(.naturalSize)
                let duration = try await slot.asset.load(.duration)
                infoCache[key] = SourceInfo(videoTrack: track, preferredTransform: transform, naturalSize: natural, duration: duration.seconds)
            }
        }
        func info(_ slot: MusicSlot) -> SourceInfo { infoCache[ObjectIdentifier(slot.asset)]! }

        let total = cutTimes.last ?? 0
        let renderSize = VideoGeometry.evenSize(
            VideoGeometry.orientedSize(natural: info(slots[0]).naturalSize, transform: info(slots[0]).preferredTransform)
        )

        // Clamp the dissolve so it never swallows a whole slot.
        var minSlot = Double.greatestFiniteMagnitude
        for j in slots.indices { minSlot = min(minSlot, cutTimes[j + 1] - cutTimes[j]) }
        let dissolve = max(0, min(transitionDuration, 0.8 * minSlot))
        let half = dissolve / 2

        // A boundary carries a transition when it has a chosen effect, isn't the
        // last slot, and the dissolve has room.
        func hasTransition(_ j: Int) -> Bool {
            j >= 0 && j < slots.count - 1 && boundaryTransitions[j] != nil && dissolve > 0
        }
        func leftExt(_ j: Int) -> Double { (j > 0 && hasTransition(j - 1)) ? half : 0 }
        func rightExt(_ j: Int) -> Double { hasTransition(j) ? half : 0 }

        let composition = AVMutableComposition()
        guard
            let trackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw EditorError.exportSetupFailed
        }
        let tracks = [trackA, trackB]

        // Insert each slot's footage on alternating tracks, extended to cover its
        // transitions, and record the fit transform.
        var transforms: [CGAffineTransform] = []
        for j in slots.indices {
            let slot = slots[j]
            let source = info(slot)
            let track = tracks[j % 2]

            // Target on-beat footprint (never changes, so cuts stay on the beat).
            let targetLength = (cutTimes[j + 1] - cutTimes[j]) + leftExt(j) + rightExt(j)

            // Amount of source footage to consume for the chosen speed: faster =>
            // more footage compressed into the slot; slower => less, stretched out.
            let speed = max(0.1, slot.speed)
            let sourceLength = min(targetLength * speed, source.duration)

            var srcStart = slot.sourceStart
            if srcStart < 0 { srcStart = 0 }
            if srcStart + sourceLength > source.duration {
                srcStart = max(0, source.duration - sourceLength)
            }

            let timelineStart = cutTimes[j] - leftExt(j)
            let srcRange = CMTimeRange(start: TimeRangeMath.time(srcStart), duration: TimeRangeMath.time(sourceLength))
            try track.insertTimeRange(srcRange, of: source.videoTrack, at: TimeRangeMath.time(timelineStart))

            // Scale the inserted footage to the target length — this is what makes
            // it play slow or fast while keeping the slot locked to the beat grid.
            if abs(sourceLength - targetLength) > 0.001 {
                track.scaleTimeRange(
                    CMTimeRange(start: TimeRangeMath.time(timelineStart), duration: TimeRangeMath.time(sourceLength)),
                    toDuration: TimeRangeMath.time(targetLength)
                )
            }

            transforms.append(VideoGeometry.fitTransform(natural: source.naturalSize, preferred: source.preferredTransform, into: renderSize))
        }

        // Lay the music under the whole reel, with short fades. This is added
        // before the video instructions are built so `composition.duration`
        // already reflects the soundtrack when the instruction chain is pinned
        // to it below — otherwise the video-only length can fall a sub-frame
        // short of the music and leave an uncovered tail.
        var audioMix: AVAudioMix? = nil
        if let musicTrack = try await music.asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicRange = CMTimeRange(start: TimeRangeMath.time(music.start), duration: TimeRangeMath.time(total))
            try audioTrack.insertTimeRange(musicRange, of: musicTrack, at: .zero)

            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            let fade = min(1.0, total * 0.1)
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                 timeRange: CMTimeRange(start: .zero, duration: TimeRangeMath.time(fade)))
            params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: TimeRangeMath.time(total - fade), duration: TimeRangeMath.time(fade)))

            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        // Build the instructions as a single contiguous chain: a solo
        // pass-through per slot and a transition centered on each flagged beat
        // boundary. Each segment starts exactly where the previous one ends
        // (sharing the same CMTime), so the ranges tile [0, duration] with no
        // gaps. Rounding every boundary independently to the composition
        // timescale would otherwise leave sub-frame gaps between a transition
        // and the next solo, making the whole composition invalid
        // (AVErrorInvalidVideoComposition, -11841).
        enum Segment {
            case solo(slot: Int)
            case transition(from: Int)
        }

        // Ordered segments with their end boundary.
        var plan: [(segment: Segment, end: CMTime)] = []
        for j in slots.indices {
            let soloEnd = hasTransition(j) ? cutTimes[j + 1] - half : cutTimes[j + 1]
            plan.append((.solo(slot: j), TimeRangeMath.time(soloEnd)))
            if hasTransition(j) {
                plan.append((.transition(from: j), TimeRangeMath.time(cutTimes[j + 1] + half)))
            }
        }
        // Pin the final boundary to the composition's real duration so the
        // instructions cover the whole timeline with nothing left uncovered.
        if !plan.isEmpty {
            plan[plan.count - 1].end = composition.duration
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        for step in plan {
            let end = max(cursor, step.end)   // keep the chain strictly forward
            let range = CMTimeRange(start: cursor, end: end)
            cursor = end
            guard range.duration > .zero else { continue }  // drop empties; chain stays contiguous

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            switch step.segment {
            case .solo(let j):
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[j % 2])
                layer.setTransform(transforms[j], at: range.start)
                instruction.layerInstructions = [layer]
            case .transition(let j):
                let fromLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[j % 2])
                let toLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[(j + 1) % 2])
                TransitionCompositor.apply(
                    boundaryTransitions[j] ?? .crossDissolve,
                    from: fromLayer, to: toLayer,
                    fromTransform: transforms[j], toTransform: transforms[j + 1],
                    range: range, renderSize: renderSize
                )
                instruction.layerInstructions = [fromLayer, toLayer]
            }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = instructions

        return (composition, videoComposition, audioMix)
    }
}

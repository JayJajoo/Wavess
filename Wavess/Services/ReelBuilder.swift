import AVFoundation
import CoreGraphics
import Foundation

/// One ordered segment of the reel: a time range from a source asset, plus
/// whether a transition should blend it into the following segment.
struct ReelSegment {
    let asset: AVURLAsset
    let range: CMTimeRange
    let transitionIntoNext: Bool
}

/// Builds a single reel from ordered key-scene segments across multiple source
/// videos, applying cross-dissolve transitions selectively (where requested).
///
/// The classic AVFoundation transition recipe: segments alternate between two
/// video tracks so neighbors can overlap; a transition overlaps the pair by the
/// transition duration and ramps the outgoing segment's opacity to zero,
/// revealing the incoming one. Boundaries without a transition are hard cuts
/// (zero overlap). Output is **video-only** — montages are scored with music
/// added afterward.
struct ReelBuilder {

    private let frameRate: Int32 = 30

    private struct SourceInfo {
        let videoTrack: AVAssetTrack
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
    }

    func build(segments: [ReelSegment], transitionDuration: Double) async throws -> (composition: AVComposition, videoComposition: AVVideoComposition) {
        guard !segments.isEmpty else { throw EditorError.nothingToExport }

        // Load each distinct source's video track + orientation once.
        var infoCache: [ObjectIdentifier: SourceInfo] = [:]
        for segment in segments {
            let key = ObjectIdentifier(segment.asset)
            if infoCache[key] == nil {
                guard let track = try await segment.asset.loadTracks(withMediaType: .video).first else {
                    throw EditorError.noVideoTrack
                }
                let transform = try await track.load(.preferredTransform)
                let natural = try await track.load(.naturalSize)
                infoCache[key] = SourceInfo(videoTrack: track, preferredTransform: transform, naturalSize: natural)
            }
        }

        func info(for segment: ReelSegment) -> SourceInfo {
            infoCache[ObjectIdentifier(segment.asset)]!
        }

        // Canonical render size from the first segment's oriented size.
        let first = info(for: segments[0])
        let renderSize = VideoGeometry.evenSize(
            VideoGeometry.orientedSize(natural: first.naturalSize, transform: first.preferredTransform)
        )

        let composition = AVMutableComposition()
        guard
            let trackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let trackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw EditorError.exportSetupFailed
        }
        let tracks = [trackA, trackB]

        let requestedOverlap = TimeRangeMath.time(max(0, transitionDuration))

        // Per-boundary overlap. Zero for hard cuts; otherwise clamped to 40% of
        // each neighbor so a segment is never fully consumed by its two overlaps.
        var overlaps: [CMTime] = []
        for i in segments.indices {
            if i == segments.count - 1 || !segments[i].transitionIntoNext {
                overlaps.append(.zero)
            } else {
                let shorter = CMTimeMinimum(segments[i].range.duration, segments[i + 1].range.duration)
                let cap = CMTimeMultiplyByFloat64(shorter, multiplier: 0.4)
                overlaps.append(CMTimeMinimum(requestedOverlap, cap))
            }
        }

        // Start time of each segment on the composition timeline.
        var starts: [CMTime] = []
        var cursor = CMTime.zero
        for i in segments.indices {
            starts.append(cursor)
            cursor = cursor + segments[i].range.duration - overlaps[i]
        }
        let totalDuration = starts[segments.count - 1] + segments[segments.count - 1].range.duration

        // Insert media into alternating tracks.
        for i in segments.indices {
            let track = tracks[i % 2]
            try track.insertTimeRange(segments[i].range, of: info(for: segments[i]).videoTrack, at: starts[i])
        }

        // Precompute each segment's fit transform.
        let transforms: [CGAffineTransform] = segments.map {
            let source = info(for: $0)
            return VideoGeometry.fitTransform(natural: source.naturalSize, preferred: source.preferredTransform, into: renderSize)
        }

        // Build contiguous instructions: a pass-through per segment's solo region,
        // and a transition instruction for each overlap.
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for i in segments.indices {
            let track = tracks[i % 2]

            // Solo region (only this segment is visible).
            let soloStart = (i == 0) ? .zero : starts[i] + overlaps[i - 1]
            let soloEnd = (i == segments.count - 1) ? totalDuration : starts[i + 1]
            if soloEnd > soloStart {
                let range = CMTimeRange(start: soloStart, end: soloEnd)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(transforms[i], at: range.start)

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = range
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }

            // Transition region into the next segment.
            if i < segments.count - 1, overlaps[i] > .zero {
                let range = CMTimeRange(start: starts[i + 1], duration: overlaps[i])
                let nextTrack = tracks[(i + 1) % 2]

                // Outgoing in front, fading out; incoming behind at full opacity.
                let fromLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                fromLayer.setTransform(transforms[i], at: range.start)
                fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)

                let toLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: nextTrack)
                toLayer.setTransform(transforms[i + 1], at: range.start)

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = range
                instruction.layerInstructions = [fromLayer, toLayer]
                instructions.append(instruction)
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = instructions

        return (composition, videoComposition)
    }
}

import AVFoundation
import Foundation

/// Beat/tempo analysis for a section of a music track.
struct MusicAnalysis {
    /// Beat times in seconds, relative to the start of the analyzed section.
    let beats: [Double]
    /// Onset strength at each beat (normalized `0...1`), aligned with `beats` —
    /// higher means a stronger accent/hit (drops, downbeats).
    let beatStrengths: [Double]
    /// Smoothed loudness at each beat (normalized `0...1`), aligned with `beats` —
    /// the song's energy over time (quiet verses low, choruses/drops high).
    let beatEnergies: [Double]
    /// Index into `beats` of the detected drop — the biggest sustained jump in
    /// energy (chorus/drop). `nil` when the song has no clear lift.
    let dropBeatIndex: Int?
    /// Estimated tempo in beats per minute.
    let bpm: Double

    /// Onset strength nearest the given time, or a neutral 0.5 if unknown.
    func strength(at time: Double) -> Double {
        guard !beats.isEmpty else { return 0.5 }
        var bestIndex = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (i, beat) in beats.enumerated() {
            let delta = abs(beat - time)
            if delta < bestDelta { bestDelta = delta; bestIndex = i }
        }
        return bestIndex < beatStrengths.count ? beatStrengths[bestIndex] : 0.5
    }
}

/// Detects beats in a slice of audio, entirely on-device and without FFT.
///
/// Pipeline: decode the section to mono PCM → short-window energy → onset
/// envelope (positive energy flux) → autocorrelation of the envelope to find
/// the dominant tempo → phase search to lock the beat grid to the music. The
/// result is a clean, evenly spaced beat grid ideal for cutting a montage.
struct MusicAnalyzer {

    private let sampleRate: Double = 22_050
    private let frameSize = 1_024
    private let hop = 512

    func analyze(asset: AVURLAsset, start: Double, duration: Double) async throws -> MusicAnalysis {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EditorError.exportFailed("The selected file has no audio.")
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: TimeRangeMath.time(start),
            duration: TimeRangeMath.time(duration)
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw EditorError.exportFailed("Couldn't read the audio.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? EditorError.exportFailed("Couldn't read the audio.")
        }

        // Frame energies, computed on the fly as samples stream in.
        let dt = Double(hop) / sampleRate
        var energies: [Double] = []
        var window = [Float](repeating: 0, count: frameSize)
        var windowCount = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
                  let dataPointer else { continue }

            let count = length / MemoryLayout<Int16>.size
            dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                for i in 0..<count {
                    window[windowCount] = Float(samples[i]) / 32_768.0
                    windowCount += 1
                    if windowCount == frameSize {
                        energies.append(windowEnergy(window))
                        // Slide by hop: keep the last (frameSize - hop) samples.
                        for k in 0..<(frameSize - hop) { window[k] = window[k + hop] }
                        windowCount = frameSize - hop
                    }
                }
            }
        }

        if reader.status == .failed {
            throw reader.error ?? EditorError.exportFailed("Audio analysis failed.")
        }

        guard energies.count > 8 else {
            return fallbackGrid(duration: duration)
        }

        // Onset envelope = positive energy flux, normalized.
        var flux = [Double](repeating: 0, count: energies.count)
        for n in 1..<energies.count {
            flux[n] = max(0, energies[n] - energies[n - 1])
        }
        if let maxFlux = flux.max(), maxFlux > 0 {
            for n in flux.indices { flux[n] /= maxFlux }
        } else {
            return fallbackGrid(duration: duration)
        }

        // Tempo via autocorrelation of the onset envelope (BPM 70–180).
        let minLag = max(1, Int((60.0 / 180.0) / dt))
        let maxLag = min(flux.count - 1, Int((60.0 / 70.0) / dt))
        guard maxLag > minLag else { return fallbackGrid(duration: duration) }

        var bestLag = minLag
        var bestScore = -1.0
        for lag in minLag...maxLag {
            var score = 0.0
            var n = 0
            while n + lag < flux.count {
                score += flux[n] * flux[n + lag]
                n += 1
            }
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestScore > 0 else { return fallbackGrid(duration: duration) }

        // Phase: the offset within one beat period that best aligns to onsets.
        var bestOffset = 0
        var bestPhaseScore = -1.0
        for offset in 0..<bestLag {
            var score = 0.0
            var k = offset
            while k < flux.count {
                score += flux[k]
                k += bestLag
            }
            if score > bestPhaseScore {
                bestPhaseScore = score
                bestOffset = offset
            }
        }

        var beats: [Double] = []
        var strengths: [Double] = []
        var index = bestOffset
        while index < flux.count {
            beats.append(Double(index) * dt)
            strengths.append(flux[index])
            index += bestLag
        }

        let bpm = (Double(bestLag) * dt) > 0 ? 60.0 / (Double(bestLag) * dt) : 120

        // Song structure: a smoothed loudness envelope per beat, and the drop.
        let (beatEnergies, dropBeatIndex) = Self.structure(energies: energies, dt: dt, beats: beats)

        return MusicAnalysis(beats: beats, beatStrengths: strengths,
                             beatEnergies: beatEnergies, dropBeatIndex: dropBeatIndex, bpm: bpm)
    }

    /// Smoothed, normalized loudness at each beat, plus the drop beat (the biggest
    /// sustained energy jump) if there's a clear one.
    private static func structure(energies: [Double], dt: Double, beats: [Double]) -> (energies: [Double], drop: Int?) {
        guard !energies.isEmpty, !beats.isEmpty else {
            return (Array(repeating: 0.5, count: beats.count), nil)
        }

        // ~1s moving average.
        let window = max(1, Int(1.0 / max(dt, 0.0001)))
        var smooth = [Double](repeating: 0, count: energies.count)
        var running = 0.0
        for i in energies.indices {
            running += energies[i]
            if i >= window { running -= energies[i - window] }
            smooth[i] = running / Double(min(i + 1, window))
        }
        let minE = smooth.min() ?? 0
        let maxE = smooth.max() ?? 1
        let span = maxE - minE
        func norm(_ v: Double) -> Double { span > 0 ? (v - minE) / span : 0.5 }

        let beatEnergies = beats.map { time -> Double in
            let idx = min(smooth.count - 1, max(0, Int(time / max(dt, 0.0001))))
            return norm(smooth[idx])
        }

        // Drop = the position with the largest sustained rise (quiet-ish before,
        // loud after), scanning ~2s windows.
        let w = max(1, Int(2.0 / max(dt, 0.0001)))
        var bestRise = 0.0
        var bestHop: Int?
        if smooth.count > 2 * w {
            var n = w
            let step = max(1, Int(0.1 / max(dt, 0.0001)))
            while n < smooth.count - w {
                let before = smooth[(n - w)..<n].reduce(0, +) / Double(w)
                let after = smooth[n..<(n + w)].reduce(0, +) / Double(w)
                let rise = norm(after) - norm(before)
                if rise > bestRise && norm(after) > 0.6 { bestRise = rise; bestHop = n }
                n += step
            }
        }

        var drop: Int?
        if let hop = bestHop, bestRise > 0.15 {
            let time = Double(hop) * dt
            var best = 0
            var bestDelta = Double.greatestFiniteMagnitude
            for (i, beat) in beats.enumerated() {
                let delta = abs(beat - time)
                if delta < bestDelta { bestDelta = delta; best = i }
            }
            drop = best
        }
        return (beatEnergies, drop)
    }

    private func windowEnergy(_ window: [Float]) -> Double {
        var sum = 0.0
        for value in window {
            let v = Double(value)
            sum += v * v
        }
        return sum
    }

    /// When the track is too quiet/flat to analyze, fall back to a steady
    /// 120 BPM grid so the montage still works.
    private func fallbackGrid(duration: Double) -> MusicAnalysis {
        let period = 0.5
        var beats: [Double] = []
        var t = 0.0
        while t < duration {
            beats.append(t)
            t += period
        }
        return MusicAnalysis(beats: beats,
                             beatStrengths: Array(repeating: 0.5, count: beats.count),
                             beatEnergies: Array(repeating: 0.5, count: beats.count),
                             dropBeatIndex: nil, bpm: 120)
    }
}

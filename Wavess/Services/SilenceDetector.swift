import AVFoundation
import Foundation

/// Finds silent stretches in a video's audio track entirely on-device.
///
/// The audio is decoded to mono 16 kHz PCM and scanned in short windows. Each
/// window's RMS loudness is converted to dBFS; runs of windows below the
/// threshold that last at least `minSilenceDuration` become silent ranges.
struct SilenceDetector {

    /// Sample rate we decode to. 16 kHz is plenty for loudness analysis and
    /// keeps the scan fast and memory-light.
    private let sampleRate: Double = 16_000

    /// Analysis window length in seconds.
    private let windowDuration: Double = 0.02  // 20 ms

    func detectSilence(in asset: AVURLAsset, settings: AnalysisSettings) async throws -> [CMTimeRange] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return []  // no audio => nothing to trim as silence
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? EditorError.exportFailed("Couldn't read audio.")
        }

        let windowSampleCount = max(1, Int(sampleRate * windowDuration))
        let thresholdDB = settings.silenceThresholdDB

        // Per-window loudness in dBFS, one entry per `windowDuration` of audio.
        var windowLevels: [Double] = []
        var windowSum: Double = 0
        var windowCount = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer else { continue }

            let sampleCount = length / MemoryLayout<Int16>.size
            dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    let value = Double(samples[i]) / 32_768.0
                    windowSum += value * value
                    windowCount += 1
                    if windowCount == windowSampleCount {
                        windowLevels.append(rmsToDB(sum: windowSum, count: windowCount))
                        windowSum = 0
                        windowCount = 0
                    }
                }
            }
        }

        if reader.status == .failed {
            throw reader.error ?? EditorError.exportFailed("Audio analysis failed.")
        }

        // Flush any trailing partial window.
        if windowCount > 0 {
            windowLevels.append(rmsToDB(sum: windowSum, count: windowCount))
        }

        return silentRanges(
            from: windowLevels,
            thresholdDB: thresholdDB,
            minSilenceDuration: settings.minSilenceDuration
        )
    }

    private func rmsToDB(sum: Double, count: Int) -> Double {
        guard count > 0 else { return -120 }
        let rms = (sum / Double(count)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }

    /// Collapses the per-window loudness array into silent `CMTimeRange`s.
    private func silentRanges(from levels: [Double], thresholdDB: Double, minSilenceDuration: Double) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        var runStart: Int? = nil

        func closeRun(end: Int) {
            guard let start = runStart else { return }
            let startSeconds = Double(start) * windowDuration
            let endSeconds = Double(end) * windowDuration
            if endSeconds - startSeconds >= minSilenceDuration {
                ranges.append(CMTimeRange(
                    start: TimeRangeMath.time(startSeconds),
                    end: TimeRangeMath.time(endSeconds)
                ))
            }
            runStart = nil
        }

        for (index, level) in levels.enumerated() {
            if level <= thresholdDB {
                if runStart == nil { runStart = index }
            } else {
                closeRun(end: index)
            }
        }
        closeRun(end: levels.count)

        return ranges
    }
}

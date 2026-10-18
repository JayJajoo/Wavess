import AVFoundation

/// Produces a coarse amplitude envelope for a whole audio track — a handful of
/// normalized peaks (0...1) used to draw the song's waveform in the trimmer.
/// Reads mono at a low sample rate and decimates heavily, so it stays cheap.
enum WaveformSampler {

    static func sample(asset: AVURLAsset, buckets: Int = 160) async -> [Float] {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 11_025,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var amplitudes: [Float] = []
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Int16>.size
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                var i = 0
                while i < count {            // decimate: one peak every 16 samples
                    amplitudes.append(abs(Float(samples[i])) / 32_768.0)
                    i += 16
                }
            }
        }
        guard !amplitudes.isEmpty else { return [] }

        // Collapse into `buckets` peaks, then normalize to 0...1.
        var result = [Float](repeating: 0, count: buckets)
        let per = max(1, amplitudes.count / buckets)
        for b in 0..<buckets {
            let lo = b * per
            let hi = min(amplitudes.count, lo + per)
            guard lo < hi else { break }
            var peak: Float = 0
            for k in lo..<hi { peak = max(peak, amplitudes[k]) }
            result[b] = peak
        }
        let maxPeak = result.max() ?? 1
        if maxPeak > 0 { for i in result.indices { result[i] /= maxPeak } }
        return result
    }
}

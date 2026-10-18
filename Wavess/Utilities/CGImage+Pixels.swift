import CoreGraphics

extension CGImage {

    /// Renders the image into a tiny square grayscale buffer suitable for
    /// cheap frame-to-frame comparison during scene detection.
    ///
    /// Downscaling to e.g. 32×32 makes comparison fast and robust to noise,
    /// small motion, and compression artifacts while still capturing the
    /// large-scale changes that mark a real scene cut.
    func grayscaleSignature(size: Int = 32) -> [UInt8]? {
        let width = size
        let height = size
        var data = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return ok ? data : nil
    }
}

/// Mean absolute difference between two equal-length grayscale signatures,
/// normalized to `0...1`. Returns 0 when the inputs don't match in length.
func meanAbsDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var total = 0
    for i in a.indices {
        total += abs(Int(a[i]) - Int(b[i]))
    }
    return Double(total) / Double(a.count) / 255.0
}

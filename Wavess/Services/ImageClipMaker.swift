import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Turns a still photo into a short silent video clip (H.264, even dimensions)
/// so images can flow through the exact same reel pipeline as video clips —
/// analysed, Vision-scored, beat-synced and stitched like any other segment.
///
/// Photos are decoded **downsampled** straight to a small size via ImageIO, so a
/// 48-megapixel HEIC never loads at full resolution (~200 MB) — that full-res
/// decode was what pushed memory over the device's per-app limit and crashed the
/// app when images were added.
enum ImageClipMaker {

    /// Shared across photos — a CIContext is expensive to create, so reusing one
    /// avoids a GPU-resource spike when converting many images in a batch.
    private static let ciContext = CIContext()

    static func makeStillVideo(from imageURL: URL, seconds: Double = 3.0) async -> URL? {
        guard let image = downsampledImage(from: imageURL, maxPixel: 1280) else { return nil }
        let size = evenSize(for: image)
        guard size.width >= 2, size.height >= 2 else { return nil }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavess-image-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: output)

        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        guard let buffer = pixelBuffer(from: image, size: size) else {
            writer.cancelWriting()
            return nil
        }
        let fps: Int32 = 15
        let frameCount = max(2, Int(seconds * Double(fps)))
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed ? output : nil
    }

    /// Decodes the image straight to a thumbnail no larger than `maxPixel` on its
    /// long edge, with EXIF orientation baked in — without ever decoding the
    /// full-resolution original into memory.
    private static func downsampledImage(from url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The decoded image rounded to even width/height (encoders prefer even).
    private static func evenSize(for image: CGImage) -> CGSize {
        func even(_ value: Int) -> CGFloat { CGFloat(max(2, value & ~1)) }
        return CGSize(width: even(image.width), height: even(image.height))
    }

    private static func pixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32ARGB, attributes, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        let ciImage = CIImage(cgImage: image)
        let scaleX = size.width / CGFloat(image.width)
        let scaleY = size.height / CGFloat(image.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: buffer,
                         bounds: CGRect(origin: .zero, size: size),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }
}

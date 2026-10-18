import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Turns a still photo into a short silent video clip (H.264) so images can flow
/// through the same reel pipeline as video clips — analysed, Vision-scored,
/// beat-synced and stitched like any other segment.
///
/// The photo is rendered onto a canvas matching the reel's video frame, fitted
/// and sharp, over a blurred aspect-fill copy of itself — so a photo of a
/// different shape fills the frame (Instagram-style) instead of letterboxing to
/// a different height than the videos.
///
/// Decoded downsampled via ImageIO, so a 48-megapixel HEIC never loads at full
/// resolution (that full-res decode was what crashed the app on photos).
enum ImageClipMaker {

    private static let ciContext = CIContext()

    static func makeStillVideo(from imageURL: URL, targetSize rawTarget: CGSize, seconds: Double = 3.0) async -> URL? {
        guard let image = downsampledImage(from: imageURL, maxPixel: 1280) else { return nil }
        let size = evenSize(fitting: rawTarget, maxLongEdge: 1280)
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

        guard let buffer = blurredFillPixelBuffer(image, size: size) else {
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

    private static func downsampledImage(from url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Target canvas scaled to fit `maxLongEdge`, rounded to even width/height.
    private static func evenSize(fitting target: CGSize, maxLongEdge: CGFloat) -> CGSize {
        var width = max(2, target.width)
        var height = max(2, target.height)
        let longest = max(width, height)
        if longest > maxLongEdge {
            let scale = maxLongEdge / longest
            width *= scale
            height *= scale
        }
        func even(_ value: CGFloat) -> CGFloat { CGFloat(max(2, Int(value.rounded()) & ~1)) }
        return CGSize(width: even(width), height: even(height))
    }

    /// Composites the photo (aspect-fit, sharp) over a blurred aspect-fill copy
    /// of itself, filling `size` with no letterbox bars.
    private static func blurredFillPixelBuffer(_ image: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32ARGB, attributes, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        let ciImage = CIImage(cgImage: image)
        let iw = ciImage.extent.width
        let ih = ciImage.extent.height
        guard iw > 0, ih > 0 else { return nil }
        let targetRect = CGRect(origin: .zero, size: size)

        // Blurred aspect-fill background.
        let fillScale = max(size.width / iw, size.height / ih)
        let filled = ciImage.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        let filledSize = CGSize(width: iw * fillScale, height: ih * fillScale)
        let background = filled
            .transformed(by: CGAffineTransform(translationX: (size.width - filledSize.width) / 2,
                                               y: (size.height - filledSize.height) / 2))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28])
            .cropped(to: targetRect)

        // Sharp aspect-fit foreground.
        let fitScale = min(size.width / iw, size.height / ih)
        let fittedSize = CGSize(width: iw * fitScale, height: ih * fitScale)
        let foreground = ciImage
            .transformed(by: CGAffineTransform(scaleX: fitScale, y: fitScale))
            .transformed(by: CGAffineTransform(translationX: (size.width - fittedSize.width) / 2,
                                               y: (size.height - fittedSize.height) / 2))

        let composite = foreground.composited(over: background)
        ciContext.render(composite, to: buffer,
                         bounds: targetRect,
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }
}

import CoreGraphics

/// Geometry helpers for compositing clips of differing resolution/orientation
/// into a single reel frame.
enum VideoGeometry {

    /// The on-screen size of a track after its preferred transform is applied.
    static func orientedSize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Rounds a size to even dimensions (encoders prefer even width/height).
    static func evenSize(_ size: CGSize) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat {
            let rounded = Int(value.rounded())
            return CGFloat(max(2, rounded - (rounded % 2)))
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// Transform that bakes in the source orientation and aspect-fits it into the
    /// render size, centered (letterboxed if aspect ratios differ).
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, into renderSize: CGSize) -> CGAffineTransform {
        let oriented = orientedSize(natural: natural, transform: preferred)
        guard oriented.width > 0, oriented.height > 0 else { return preferred }

        let scale = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
        let tx = (renderSize.width - oriented.width * scale) / 2
        let ty = (renderSize.height - oriented.height * scale) / 2

        let fit = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return preferred.concatenating(fit)
    }
}

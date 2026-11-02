import CoreImage

enum ScreenDisplay {
    /// Core Image's origin is bottom-left; drawable texture rows start at the
    /// top. Convert only the display destination, never decoded/recorded pixels.
    static func imageForDrawable(_ image: CIImage, bounds: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                               tx: 0, ty: bounds.minY + bounds.maxY))
    }
}

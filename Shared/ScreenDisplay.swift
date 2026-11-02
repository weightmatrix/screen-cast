import CoreImage

enum ScreenDisplay {
    /// Keep the decoded image intact. Raw texture row indices do not establish
    /// the visible orientation of an MTKView/CAMetalLayer presentation.
    static func imageForDrawable(_ image: CIImage, bounds: CGRect) -> CIImage {
        image
    }
}

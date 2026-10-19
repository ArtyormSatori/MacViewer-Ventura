import CoreGraphics
import Foundation

/// Aspect-fit ("letterbox") geometry for the Mode-2 video
/// surface (M1 part 3b), pure so it is fully unit-tested.
///
/// Same formula as Mode 1's renderer (`RemoteScreenNSView`'s
/// image rect): scale = min(view/content) per axis, content
/// centered. Coordinates here are AppKit's: points are in the
/// container view's bounds space, origin at the BOTTOM-left,
/// y growing up. Normalized output is the media plane's space:
/// (0, 0) is the content's TOP-left corner, (1, 1) its
/// bottom-right — matching `MeshInputGeometry`, where (0, 0)
/// maps to host pixel (0, 0), the top-left of the capture.
///
/// Pinned decision: a point inside the letterbox bars maps to
/// nil and the event is DROPPED, never clamped. Clamping would
/// park the host pointer on a screen edge the user never
/// pointed at; a click in a bar is a click on nothing.
enum MeshLetterbox {
    /// The rect the content occupies inside a container of
    /// `viewSize`, aspect-fitted and centered. `.zero` when
    /// either size is degenerate (nothing to show or map yet).
    static func contentRect(viewSize: CGSize, contentSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0,
              contentSize.width > 0, contentSize.height > 0,
              viewSize.width.isFinite, viewSize.height.isFinite,
              contentSize.width.isFinite, contentSize.height.isFinite
        else { return .zero }
        let scale = min(viewSize.width / contentSize.width,
                        viewSize.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale,
                          height: contentSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2,
                      y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Maps a container-space point to normalized content
    /// coordinates, or nil when the point falls in the bars
    /// (or nothing is mappable yet). Points exactly on the
    /// content's edge are inside and clamp to 0 or 1 by the
    /// ratio itself.
    static func normalizedPoint(_ point: CGPoint, viewSize: CGSize,
                                contentSize: CGSize) -> (x: Double, y: Double)? {
        let rect = contentRect(viewSize: viewSize, contentSize: contentSize)
        guard rect.width > 0, rect.height > 0,
              point.x.isFinite, point.y.isFinite,
              rect.contains(point) else { return nil }
        let nx = Double((point.x - rect.minX) / rect.width)
        // AppKit y grows up from the container's bottom; the
        // normalized space's y grows down from the content's
        // top — hence the flip against the rect's top edge.
        let ny = Double((rect.maxY - point.y) / rect.height)
        guard nx.isFinite, ny.isFinite else { return nil }
        return (min(1, max(0, nx)), min(1, max(0, ny)))
    }
}

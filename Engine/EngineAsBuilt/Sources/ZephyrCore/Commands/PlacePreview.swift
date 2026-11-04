import Foundation

// MARK: - PlacePreview
//
// Pure ghost-preview geometry for the PLACEVIEW/PLACECALLOUT canvas click
// (the same bounding-box ghost INSERT draws): paper-frame rectangle corners
// from a center + size, in Y-up paper coordinates. Rendering itself needs a
// live engine/canvas, so it stays in the commands' renderOverlay and is
// covered by the manual interactive run; the math here is unit-tested.

public enum PlacePreview {
    /// Four corners (minX/minY, maxX/minY, maxX/maxY, minX/maxY) of the
    /// rectangle centered at (centerX, centerY) with the given size.
    public static func rectCorners(
        centerX: Double, centerY: Double,
        width: Double, height: Double
    ) -> [(x: Double, y: Double)] {
        let hw = width / 2.0
        let hh = height / 2.0
        return [
            (centerX - hw, centerY - hh),
            (centerX + hw, centerY - hh),
            (centerX + hw, centerY + hh),
            (centerX - hw, centerY + hh),
        ]
    }
}

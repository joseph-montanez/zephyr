import Foundation

// =========================================================================
// MARK: - SavedInitialView
// -------------------------------------------------------------------------
// The `*ACTIVE` VPORT record stores the camera (view center + view height)
// active when the drawing was last saved. Desktop AutoCAD restores it on
// open; Zephyr historically always zoomed to extents instead.
//
// Restoring blindly is wrong when the record is stale (an ODA conversion can
// carry absolute pre-regen values, and a drawing may simply have been saved
// zoomed elsewhere), so the open flow restores only when the gate below
// passes and otherwise keeps the zoom-extents fit.
// =========================================================================

/// Saved Model-space view camera in Zephyr world coordinates (Y already
/// flipped at import, like all other geometry).
public struct SavedModelView: Sendable, Equatable {
    /// World point the saved view was centered on.
    public var centerX: Double
    public var centerY: Double
    /// World-units-tall the saved view showed (VPORT group 40 / VIEWSIZE).
    public var height: Double

    public init(centerX: Double, centerY: Double, height: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.height = height
    }
}

public enum SavedInitialView {

    /// True when restoring `saved` is sane: finite values, a positive
    /// non-absurd height, and a view rect that overlaps the visible content.
    /// A saved view that misses the content entirely (stale record, saved
    /// zoomed elsewhere) falls back to zoom-extents.
    public static func shouldRestore(
        saved: SavedModelView,
        content: BoundingBox3D?,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> Bool {
        guard saved.centerX.isFinite, saved.centerY.isFinite,
              saved.height.isFinite, saved.height > 1e-9,
              viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0,
              let content else { return false }
        let size = content.size
        let contentDiag = hypot(size.x, size.y)
        guard saved.height <= 1e4 * max(contentDiag, 1e-9) else { return false }
        let halfW = (saved.height * viewportWidth / viewportHeight) * 0.5
        let halfH = saved.height * 0.5
        let epsilon = 1e-9
        return saved.centerX + halfW >= content.min.x - epsilon
            && saved.centerX - halfW <= content.max.x + epsilon
            && saved.centerY + halfH >= content.min.y - epsilon
            && saved.centerY - halfH <= content.max.y + epsilon
    }

    /// Live camera readout: the world point at the viewport center
    /// (`VIEWCTR`) and the world-units-tall visible height (`VIEWSIZE`).
    /// Exact inverse of `camera(saved:...)`: round-trips its output.
    /// Mirrors the viewport-centering math in `PhrostEngine.zoomExtents`.
    public static func liveView(
        offsetX: Double,
        offsetY: Double,
        zoom: Double,
        rotation: Double,
        viewportX: Double,
        viewportY: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        windowWidth: Double,
        windowHeight: Double
    ) -> (centerX: Double, centerY: Double, height: Double) {
        let width = max(viewportWidth, 1.0)
        let height = max(viewportHeight, 1.0)
        let safeZoom = max(zoom, 1e-9)
        let viewportCenterX = viewportX + width * 0.5
        let viewportCenterY = viewportY + height * 0.5
        let windowCenterX = windowWidth * 0.5
        let windowCenterY = windowHeight * 0.5
        let cameraSpaceX = (viewportCenterX - windowCenterX) / safeZoom
        let cameraSpaceY = (viewportCenterY - windowCenterY) / safeZoom
        let rotationCos = cos(rotation)
        let rotationSin = sin(rotation)
        let worldShiftX = cameraSpaceX * rotationCos - cameraSpaceY * rotationSin
        let worldShiftY = cameraSpaceX * rotationSin + cameraSpaceY * rotationCos
        return (
            centerX: offsetX + worldShiftX,
            centerY: offsetY + worldShiftY,
            height: height / safeZoom)
    }

    /// Camera (offset + zoom) that shows `saved` in the given viewport,
    /// mirroring the viewport-centering math in `PhrostEngine.zoomExtents`.
    public static func camera(
        saved: SavedModelView,
        viewportX: Double,
        viewportY: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        windowWidth: Double,
        windowHeight: Double,
        rotation: Double
    ) -> (offsetX: Double, offsetY: Double, zoom: Double) {
        let width = max(viewportWidth, 1.0)
        let height = max(viewportHeight, 1.0)
        let zoom = height / max(saved.height, 1e-9)
        let viewportCenterX = viewportX + width * 0.5
        let viewportCenterY = viewportY + height * 0.5
        let windowCenterX = windowWidth * 0.5
        let windowCenterY = windowHeight * 0.5
        let cameraSpaceX = (viewportCenterX - windowCenterX) / zoom
        let cameraSpaceY = (viewportCenterY - windowCenterY) / zoom
        let rotationCos = cos(rotation)
        let rotationSin = sin(rotation)
        let worldShiftX = cameraSpaceX * rotationCos - cameraSpaceY * rotationSin
        let worldShiftY = cameraSpaceX * rotationSin + cameraSpaceY * rotationCos
        return (
            offsetX: saved.centerX - worldShiftX,
            offsetY: saved.centerY - worldShiftY,
            zoom: zoom)
    }
}

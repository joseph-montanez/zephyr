import Foundation
import SwiftSDL

// =========================================================================
// MARK: - EngineSnapManager
//
// Encapsulates configuration and state for object snapping (OSNAP), 
// polar tracking, and object snap tracking (OTRACK).
// 
// By moving this logic out of the core Engine dependency container,
// we adhere to the Single Responsibility Principle (SRP). This manager
// evaluates snapping priorities and maintains the hysteresis state machine
// (the "sticky" feel when a cursor snaps to an endpoint).
// =========================================================================
@MainActor
public final class EngineSnapManager {
    // MARK: Grid Settings
    /// Whether the background grid is visible (toggled via "GRID" command).
    public var gridVisible: Bool = false
    /// Whether snapping to grid intersections is enabled (toggled via "GRID SNAP" command).
    /// Independent from entity anchor snapping (which is always active).
    public var gridSnapEnabled: Bool = false
    /// Base grid spacing in world units. The visual spacing adapts to zoom;
    /// this is the minimum (finest) grid step. Configured via "GRID SPACING".
    public var gridBaseSpacing: Double = 10.0
    /// Grid origin X in world coordinates. Configured via "GRID ORIGIN".
    public var gridOriginX: Double = 0.0
    /// Grid origin Y in world coordinates. Configured via "GRID ORIGIN".
    public var gridOriginY: Double = 0.0

    /// Computes the effective (visual) grid spacing at a given camera zoom,
    /// snapping to a "nice" number so that ~20-40 lines are visible horizontally.
    /// Never goes below the user-configured `gridBaseSpacing`.
    public func effectiveGridSpacing(windowWidth: Int32, cameraZoom zoom: Double) -> Double {
        let viewportWorldWidth = Double(windowWidth) / zoom
        let targetCells = 25.0
        let raw = viewportWorldWidth / targetCells
        // List of "nice" grid spacings (powers-of-10 and half-powers)
        let niceSpacings: [Double] = [
            0.001, 0.002, 0.005, 0.01, 0.02, 0.05,
            0.1, 0.2, 0.5, 1, 2, 5,
            10, 20, 50, 100, 200, 500,
            1000, 2000, 5000, 10000, 20000, 50000, 100000
        ]
        let effective = niceSpacings.first { $0 >= raw } ?? 100.0
        return max(effective, gridBaseSpacing)
    }

    /// Snap engine for precision drafting.
    public let snapEngine = SnapEngine()
    /// Object snap tracking (OTRACK) engine — acquires tracking points via hover dwell.
    public let snapTrackingEngine = SnapTrackingEngine()



    
    // MARK: - Snap Settings
    // These properties configure which inference engines are allowed to
    // influence the cursor position during drawing commands.

    /// Enable polar tracking (cursor snaps to polar angle increments from last draw point).
    public var polarTrackingEnabled: Bool = true
    /// Polar angle increment in degrees (e.g. 15, 30, 45, 90). Default 45°.
    public var polarAngleIncrement: Double = 45.0
    /// Enable object snap tracking (acquire tracking points, alignment-line intersection snaps).
    public var objectSnapTrackingEnabled: Bool = true
    /// Enable extension snapping (snap to line/arc extensions past endpoints).
    public var extensionSnapEnabled: Bool = true

    /// Enable Ortho mode (F8) — hard-constrains cursor to cardinal axes (0°/90°/180°/270°)
    /// from the current reference point. Ortho beats polar tracking when both are on.
    public var orthoEnabled: Bool = false
    /// Hysteresis: was the last ortho constraint horizontal? Prevents oscillation at 45° diagonals.
    public var orthoLastWasHorizontal: Bool = false
    /// Hysteresis: was the last ortho constraint vertical? Prevents oscillation at 45° diagonals.
    public var orthoLastWasVertical: Bool = false

    /// Wiggle room in screen pixels before the hover dwell timer resets.
    /// Does NOT affect the drawing — only the cursor and ortho direction.
    public var snapAngle: Double = 0.0

    /// Wiggle room in screen pixels before the hover dwell timer resets.
    public var hoverWigglePixels: Double = 5.0

    // MARK: - Snap Hysteresis ("sticky" snap)

    /// Screen-space aperture for snap acquisition in pixels.
    public var snapAperturePixels: Double = 12.0

    /// Screen-space aperture (in pixels) for drawing-trajectory snap acquisition.
    public var trajectoryTrackingAperturePixels: Double = 96.0

    /// Angular tolerance in degrees for drawing-trajectory snap.
    public var trajectoryTrackingAngularToleranceDeg: Double = 6.0

    /// Screen-space aperture for extension-line snap (EXT) in pixels.
    public var extensionSnapAperturePixels: Double = 24.0

    /// How far (screen-space pixels) to search for entity endpoints to extend from.
    public var extensionSnapReachPixels: Double = 200.0
    
    // MARK: - Snap State
    
    /// Current snap result (updated on mouse move when a draw command is active).
    public internal(set) var currentSnapResult: SnapResult? = nil
    
    /// Last polar tracking result (for renderer overlay).
    public internal(set) var lastPolarResult: PolarTrackingResult? = nil

    /// The snap the cursor is currently "locked" to (hysteresis state).
    public internal(set) var lockedSnap: SnapResult? = nil
    
    public init() {}
    
    // MARK: - Threshold Helpers
    // These functions translate screen-space pixel apertures into 
    // world-space radii based on the current camera zoom.
    // This ensures that the physical distance a user must move their mouse
    // to break a snap remains constant, regardless of how far zoomed in they are.

    /// World-space acquisition threshold — how close the cursor must get to enter a snap.
    public func snapAcquisitionThreshold(cameraZoom: Double) -> Double {
        snapAperturePixels / max(cameraZoom, 0.001)
    }

    /// World-space release threshold — wider than acquisition to create hysteresis.
    public func snapReleaseThreshold(cameraZoom: Double) -> Double {
        (snapAperturePixels + 8.0) / max(cameraZoom, 0.001)
    }

    /// World-space acquisition threshold for drawing trajectory snap.
    public func trajectoryTrackingThreshold(cameraZoom: Double) -> Double {
        trajectoryTrackingAperturePixels / max(cameraZoom, 0.001)
    }

    /// World-space perpendicular threshold for extension snap.
    public func extensionSnapThreshold(cameraZoom: Double) -> Double {
        extensionSnapAperturePixels / max(cameraZoom, 0.001)
    }

    /// World-space reach distance for finding extension-snap candidate endpoints.
    public func extensionSnapReachThreshold(cameraZoom: Double) -> Double {
        extensionSnapReachPixels / max(cameraZoom, 0.001)
    }
    
    // MARK: - Hysteresis Logic
    
    /// Dynamic snaps (trajectory, polar, nearest-on-curve) must be recomputed every frame.
    /// Static anchors benefit from hysteresis because their world position doesn't change.
    public func shouldStickyLock(_ snap: SnapResult) -> Bool {
        switch snap.anchor {
        case .nearest:
            return false
        default:
            return true
        }
    }

    public func applyStickyLockIfNeeded(_ snap: SnapResult) {
        if shouldStickyLock(snap) {
            lockedSnap = snap
        } else {
            lockedSnap = nil
        }
    }
    
    public func clear() {
        currentSnapResult = nil
        lastPolarResult = nil
        lockedSnap = nil
    }
}

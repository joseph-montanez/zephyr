import Foundation
import SwiftSDL

// =========================================================================
// MARK: - EngineCameraManager
//
// Manages camera state (offset, zoom, rotation) and coordinates transforms
// between screen and world space. Replaces functionality previously found
// in Engine+Camera.swift and state variables in Engine.swift.
// =========================================================================

/// A read-only snapshot of the camera's state used for coordinate transformations.
/// Passed by value (Sendable) to decouple mathematical operations from the MainActor state.
public struct CameraTransform: Sendable {
    /// World X coordinate at the exact center of the screen
    public let camX: Double
    /// World Y coordinate at the exact center of the screen
    public let camY: Double
    public let camZoom: Double
    public let camSin: Double
    public let camCos: Double
    public let screenCenterX: Double
    public let screenCenterY: Double
}

@MainActor
public final class EngineCameraManager {
    
    // MARK: - State Properties
    
    /// Camera world position (what point is at the center of the screen)
    public var offset: (x: Double, y: Double) = (0.0, 0.0) {
        didSet { renderGeneration &+= 1 }
    }
    
    /// Camera zoom (1.0 = no zoom, >1 = zoom in, <1 = zoom out)
    public var zoom: Double = 1.0 {
        didSet { renderGeneration &+= 1 }
    }
    
    /// Camera rotation in radians
    public var rotation: Double = 0.0 {
        didSet { renderGeneration &+= 1 }
    }
    
    /// Optional sprite to follow; camera will center on this sprite each frame
    public var followTarget: SpriteID? = nil
    
    /// Incremented when camera or window size changes. Primitives cache screen-space
    /// vertices keyed to this generation to avoid per-frame world→screen transform.
    public internal(set) var renderGeneration: Int = 0

    // MARK: - View History (for ZOOM Previous)

    /// Stack of prior camera states, newest last. Capped at 20 entries.
    /// Pushed just before a zoom command permanently changes the camera.
    private var viewHistory: [CameraState] = []

    /// Snapshots the current camera into `CameraState` and pushes onto the history stack.
    /// Call this *before* executing a ZOOM operation so "ZOOM Previous" can roll back.
    /// Does NOT push during continuous interactive modes (pan, scroll, dynamic drag).
    public func pushViewState() {
        let state = CameraState(
            offsetX: offset.x, offsetY: offset.y,
            zoom: zoom, rotation: rotation)
        viewHistory.append(state)
        if viewHistory.count > 20 {
            viewHistory.removeFirst()
        }
    }

    /// Pops the most recent `CameraState` from the view history and restores it.
    /// - Returns: `true` if a state was restored, `false` if history is empty.
    @discardableResult
    public func popViewState() -> Bool {
        guard let state = viewHistory.popLast() else { return false }
        offset = (state.offsetX, state.offsetY)
        zoom = state.zoom
        rotation = state.rotation
        return true
    }

    /// Current camera state snapshot (for tab saving, etc.).
    public func currentState() -> CameraState {
        CameraState(offsetX: offset.x, offsetY: offset.y, zoom: zoom, rotation: rotation)
    }

    /// Restore camera from a `CameraState`.
    public func applyState(_ state: CameraState) {
        offset = (state.offsetX, state.offsetY)
        zoom = state.zoom
        rotation = state.rotation
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Screen → World Transform

    /// Convert screen-space coordinates to world-space using the given camera transform.
    /// Pure math — no mutable state, safe to call from any concurrent actor context.
    /// 
    /// - Parameters:
    ///   - screenX: The physical screen pixel X coordinate (0 at left).
    ///   - screenY: The physical screen pixel Y coordinate (0 at top).
    ///   - cam: A snapshot of the camera parameters.
    /// - Returns: A tuple of `(worldX, worldY)` corresponding to the screen location.
    public nonisolated static func screenToWorld(screenX: Float, screenY: Float, cam: CameraTransform) -> (Double, Double) {
        let zx = Double(screenX) - cam.screenCenterX
        let zy = Double(screenY) - cam.screenCenterY
        let rx = zx / cam.camZoom
        let ry = zy / cam.camZoom

        let rxCos = rx * cam.camCos
        let rySin = ry * cam.camSin
        let outX = rxCos + rySin + cam.camX

        let rxSinNeg = -rx * cam.camSin
        let ryCos = ry * cam.camCos
        let outY = rxSinNeg + ryCos + cam.camY

        return (outX, outY)
    }

    // MARK: - Public Camera API

    public func setPosition(x: Double, y: Double) {
        offset = (x, y)
    }

    public func move(dx: Double, dy: Double) {
        offset.x += dx
        offset.y += dy
    }

    public func setZoom(_ newZoom: Double) {
        zoom = max(0.000001, min(newZoom, 1e15))
    }

    public func setRotation(_ radians: Double) {
        rotation = radians
    }

    public func followSprite(_ id1: Int64, _ id2: Int64) {
        followTarget = SpriteID(id1: id1, id2: id2)
    }

    public func stopFollowing() {
        followTarget = nil
    }

    /// Called each frame to update camera if following a target.
    internal func updateFollow(spriteManager: SpriteManager) {
        guard let target = followTarget,
            let sprite = spriteManager.getSprite(for: target)
        else { return }
        
        let newX = sprite.position.0
        let newY = sprite.position.1
        if newX != offset.x || newY != offset.y {
            offset.x = newX
            offset.y = newY
            renderGeneration &+= 1
        }
    }

    // MARK: - Camera Transform Helpers

    /// Build a `CameraTransform` from the current camera state.
    public func currentTransform(windowWidth: Int32, windowHeight: Int32) -> CameraTransform {
        return CameraTransform(
            camX: offset.x, camY: offset.y,
            camZoom: zoom,
            camSin: sin(-rotation), camCos: cos(-rotation),
            screenCenterX: Double(windowWidth) / 2.0,
            screenCenterY: Double(windowHeight) / 2.0
        )
    }

    /// Convert screen-space coordinates to world-space.
    internal func screenToWorld(screenX: Float, screenY: Float, windowWidth: Int32, windowHeight: Int32) -> (Double, Double) {
        let cam = currentTransform(windowWidth: windowWidth, windowHeight: windowHeight)
        return Self.screenToWorld(screenX: screenX, screenY: screenY, cam: cam)
    }

    /// Compute the world-space axis-aligned bounding box of the current viewport.
    internal func worldViewportRect(windowWidth: Int32, windowHeight: Int32) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let cam = currentTransform(windowWidth: windowWidth, windowHeight: windowHeight)
        let w = Float(windowWidth)
        let h = Float(windowHeight)
        let corners: [(Float, Float)] = [(0, 0), (w, 0), (0, h), (w, h)]
        
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        
        for (sx, sy) in corners {
            let (wx, wy) = Self.screenToWorld(screenX: sx, screenY: sy, cam: cam)
            minX = Swift.min(minX, wx)
            minY = Swift.min(minY, wy)
            maxX = Swift.max(maxX, wx)
            maxY = Swift.max(maxY, wy)
        }
        return (minX, minY, maxX, maxY)
    }

    /// Convert world-space coordinates to screen-space (static method).
    public nonisolated static func worldToScreen(worldX: Double, worldY: Double, cam: CameraTransform) -> SDL_FPoint {
        let rx = worldX - cam.camX
        let ry = worldY - cam.camY
        let rotX = (rx * cam.camCos) - (ry * cam.camSin)
        let rotY = (rx * cam.camSin) + (ry * cam.camCos)
        return SDL_FPoint(
            x: Float(rotX * cam.camZoom + cam.screenCenterX),
            y: Float(rotY * cam.camZoom + cam.screenCenterY))
    }
    
    internal func transformWorldToScreen(worldX: Double, worldY: Double, cam: CameraTransform) -> SDL_FPoint {
        return Self.worldToScreen(worldX: worldX, worldY: worldY, cam: cam)
    }

    /// Compute the 4×4 camera projection matrix for GPU uniform upload.
    /// This matrix maps 2D world coordinates into NDC (Normalized Device Coordinates)
    /// expected by the SDL GPU API.
    ///
    /// - Parameters:
    ///   - windowW: The width of the viewport.
    ///   - windowH: The height of the viewport.
    /// - Returns: A column-major array of 16 floats representing the 4x4 projection matrix.
    internal func computeMatrix(windowW: Double, windowH: Double) -> [Float] {
        let camX = offset.x
        let camY = offset.y
        let camZoom = zoom
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)

        let a = Float(2.0 * camZoom * cosR / windowW)
        let b = Float(-2.0 * camZoom * sinR / windowW)
        let c = Float(-2.0 * camZoom * (camX * cosR - camY * sinR) / windowW)
        
        let d = Float(-2.0 * camZoom * sinR / windowH)
        let e = Float(-2.0 * camZoom * cosR / windowH)
        let f = Float(2.0 * camZoom * (camX * sinR + camY * cosR) / windowH)

        return [
            a, d, 0.0, 0.0,
            b, e, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            c, f, 0.0, 1.0
        ]
    }

    /// Compute a 4×4 camera matrix specifically scaled and offset for the GPU ID-buffer pick pass.
    /// This creates a tiny logical viewport (e.g. 9x9 pixels) centered around the mouse cursor,
    /// so the GPU only rasterizes and tests geometry immediately under the mouse.
    /// This is a massive performance optimization over reading back the entire screen buffer.
    internal func computePickMatrix(cursorScreenX: Float, cursorScreenY: Float, windowWidth: Int32, windowHeight: Int32) -> [Float] {
        let (worldCX, worldCY) = screenToWorld(screenX: cursorScreenX, screenY: cursorScreenY, windowWidth: windowWidth, windowHeight: windowHeight)
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)

        let ww: Double = 9.0
        let wh: Double = 9.0

        let a = Float(2.0 * zoom * cosR / ww)
        let b = Float(-2.0 * zoom * sinR / ww)
        let c = Float(-2.0 * zoom * (worldCX * cosR - worldCY * sinR) / ww)

        let d = Float(-2.0 * zoom * sinR / wh)
        let e = Float(-2.0 * zoom * cosR / wh)
        let f = Float(2.0 * zoom * (worldCX * sinR + worldCY * cosR) / wh)

        return [
            a, d, 0.0, 0.0,
            b, e, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            c, f, 0.0, 1.0
        ]
    }

    // MARK: - View Zoom

    public func zoomView(factor: Double, screenX: Float, screenY: Float, windowWidth: Int32, windowHeight: Int32) {
        let oldZoom = zoom
        zoom = max(0.000001, min(zoom * factor, 1e15))
        guard abs(zoom - oldZoom) > 1e-9 else { return }

        let zx = Double(screenX) - Double(windowWidth) / 2.0
        let zy = Double(screenY) - Double(windowHeight) / 2.0
        let cr = -rotation
        let cosR = cos(cr)
        let sinR = sin(cr)
        let rx_zl = zx * cosR + zy * sinR
        let ry_zl = -zx * sinR + zy * cosR

        let dz = 1.0 / oldZoom - 1.0 / zoom
        offset.x += dz * rx_zl
        offset.y += dz * ry_zl
    }

    public func zoomViewCentered(factor: Double) {
        let oldZoom = zoom
        zoom = max(0.000001, min(zoom * factor, 1e15))
        guard abs(zoom - oldZoom) > 1e-9 else { return }
    }
}

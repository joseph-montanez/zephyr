import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PanPressDragTracker
//
// Pure press-and-hold state machine behind the PAN command (AutoCAD parity:
// pan only while the button is held; releasing stops the pan but stays in
// the command so another drag can follow).
//
// Kept free of engine types so the press/drag/release transitions are
// unit-testable without a live PhrostEngine.
// =========================================================================

public struct PanPressDragTracker: Sendable {
    private var anchorX: Float?
    private var anchorY: Float?

    public init() {}

    /// True between `press` and `release`/`cancel`.
    public var isDragging: Bool { anchorX != nil }

    /// Button pressed at screen position (`x`, `y`).
    public mutating func press(atX x: Float, y: Float) {
        anchorX = x
        anchorY = y
    }

    /// Pointer moved to (`x`, `y`). Returns the screen-space delta since the
    /// last press/motion event, or nil when the button is not held.
    public mutating func motion(toX x: Float, y: Float) -> (dx: Float, dy: Float)? {
        guard let ax = anchorX, let ay = anchorY else { return nil }
        anchorX = x
        anchorY = y
        return (x - ax, y - ay)
    }

    /// Button released: stop panning, stay armed for the next press.
    public mutating func release() {
        anchorX = nil
        anchorY = nil
    }

    /// Command cancelled: same as release.
    public mutating func cancel() {
        release()
    }
}

// =========================================================================
// MARK: - PanCommand
//
// AutoCAD-style PAN (P) command. Activates a hand-cursor mode:
//   - Press and hold the left button, drag to pan the view
//   - Release to stop (the command stays active for another drag)
//   - Escape or Enter to exit
//
// While active, the standard middle-mouse pan is suppressed and this command
// takes over panning via left-mouse drag.
// =========================================================================

@MainActor
public final class PanCommand: FeatureCommand {

    private var drag = PanPressDragTracker()

    public init() {}

    // MARK: - FeatureCommand

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        drag.cancel()
        processor.commandPrompt = "Press and drag to pan. Release to stop, Esc or Enter to exit."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        drag.cancel()
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        drag.press(atX: engine.interaction.lastMouseX, y: engine.interaction.lastMouseY)
        return .continue
    }

    public func handleMouseUp(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        drag.release()
        return .handled
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Heal a missed button-up (e.g. released outside the window): without
        // the button held there is no drag, so never pan from hover alone.
        // Tablet-pen drags carry their own button state in penState.
        if !engine.interaction.penState.penDrawing,
           let io = engine.io, !io.pointee.MouseDown.0 {
            drag.release()
            return
        }
        guard let delta = drag.motion(
            toX: engine.interaction.lastMouseX,
            y: engine.interaction.lastMouseY)
        else { return }

        // Convert the screen drag through the current view rotation + zoom.
        engine.camera.panByScreenDelta(dx: Double(delta.dx), dy: Double(delta.dy))
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE,
             SDL_SCANCODE_RETURN,
             SDL_SCANCODE_KP_ENTER:
            return .finished
        default:
            return .continue
        }
    }

    public var isSnappingEnabled: Bool { false }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

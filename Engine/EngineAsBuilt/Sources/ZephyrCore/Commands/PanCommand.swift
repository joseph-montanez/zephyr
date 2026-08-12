import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PanCommand
//
// AutoCAD-style PAN (P) command. Activates a hand-cursor mode:
//   - Click and drag to pan the view
//   - Escape or Enter to exit
//
// While active, the standard middle-mouse pan is suppressed and this command
// takes over panning via left-mouse drag.
// =========================================================================

@MainActor
public final class PanCommand: FeatureCommand {

    private var panActive = false
    private var lastScreenX: Float = 0
    private var lastScreenY: Float = 0

    public init() {}

    // MARK: - FeatureCommand

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Click and drag to pan. Press Esc or Enter to exit."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        panActive = false
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        panActive = true
        lastScreenX = engine.interaction.lastMouseX
        lastScreenY = engine.interaction.lastMouseY
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard panActive else { return }
        let curX = engine.interaction.lastMouseX
        let curY = engine.interaction.lastMouseY
        let dx = Double(curX - lastScreenX)
        let dy = Double(curY - lastScreenY)
        lastScreenX = curX
        lastScreenY = curY

        // Convert the screen drag through the current view rotation + zoom.
        engine.camera.panByScreenDelta(dx: dx, dy: dy)
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

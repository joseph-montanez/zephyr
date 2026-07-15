import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - DViewCommand
//
// AutoCAD-style DVIEW (Dynamic View) command — primarily the TWist option
// for rotating the 2D view. In full AutoCAD, DVIEW has many sub-options;
// this implementation provides TW (twist).
//
// Usage:
//   DVIEW → "Select objects or press Enter for all" → Enter (all)
//        → prompt "[TWist]" → type TW or press T
//        → "Specify view twist angle <0.00>:" → type angle or drag mouse
// =========================================================================

@MainActor
public final class DViewCommand: FeatureCommand {

    enum Phase {
        case pickObjects
        case chooseOption
        case twist(anchorAngleRad: Double, anchorMouseX: Float, anchorMouseY: Float)
    }

    private var phase: Phase = .pickObjects

    public init() {}

    // MARK: - FeatureCommand

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .pickObjects
        processor.commandPrompt = "Select objects or press Enter for all."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .pickObjects
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch phase {
        case .pickObjects:
            // For simplicity, any click selects objects. Enter presses mean "all objects".
            // We'll treat a click as "select this entity" — but since we do TW on the view
            // (not on specific objects), we just advance to the option phase.
            phase = .chooseOption
            processor.commandPrompt = "Enter option [TWist] <TW>:"
            return .continue

        case .chooseOption:
            // Click while choosing option — default to TWist
            let currentRotation = engine.camera.rotation
            phase = .twist(
                anchorAngleRad: currentRotation,
                anchorMouseX: engine.interaction.lastMouseX,
                anchorMouseY: engine.interaction.lastMouseY
            )
            let currentDeg = currentRotation * 180.0 / .pi
            processor.commandPrompt = "Specify view twist angle <\(String(format: "%.2f", currentDeg))>:"
            return .continue

        case .twist:
            // Finalize the twist
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard case .twist(let anchorRad, _, let anchorMY) = phase else { return }
        let curY = engine.interaction.lastMouseY
        let dy = Double(curY - anchorMY)
        // Map screen pixels to degrees: ~2 pixels per degree (adjustable sensitivity)
        let sensitivity = 0.5  // degrees per pixel
        let deltaDeg = dy * sensitivity
        engine.camera.rotation = anchorRad + deltaDeg * .pi / 180.0
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            // Cancel: restore original rotation? No — AutoCAD's DVIEW commits on Esc too.
            return .finished

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            switch phase {
            case .pickObjects, .chooseOption:
                let currentRotation = engine.camera.rotation
                phase = .twist(
                    anchorAngleRad: currentRotation,
                    anchorMouseX: engine.interaction.lastMouseX,
                    anchorMouseY: engine.interaction.lastMouseY
                )
                let currentDeg = currentRotation * 180.0 / .pi
                processor.commandPrompt = "Specify view twist angle <\(String(format: "%.2f", currentDeg))>:"
                return .continue
            case .twist:
                return .finished
            }

        case SDL_SCANCODE_T:
            // T = TWist shortcut from option phase
            if case .chooseOption = phase {
                let currentRotation = engine.camera.rotation
                phase = .twist(
                    anchorAngleRad: currentRotation,
                    anchorMouseX: engine.interaction.lastMouseX,
                    anchorMouseY: engine.interaction.lastMouseY
                )
                let currentDeg = currentRotation * 180.0 / .pi
                processor.commandPrompt = "Specify view twist angle <\(String(format: "%.2f", currentDeg))>:"
            }
            return .continue

        default:
            return .continue
        }
    }

    public var isSnappingEnabled: Bool { false }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

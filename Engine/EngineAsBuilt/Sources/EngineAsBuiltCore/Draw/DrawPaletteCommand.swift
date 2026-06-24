import Foundation
import SwiftSDL

// =========================================================================
// MARK: - DrawPaletteCommand
// =========================================================================

/// Toggles the Draw Tools palette window. Does not draw anything itself —
/// the palette is rendered by `main.swift` via `imguiFrameCallback`.
@MainActor
public final class DrawPaletteCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.drawPaletteVisible.toggle()
        if engine.ui.drawPaletteVisible {
            processor.commandPrompt = "Draw tools palette opened. Click a tool to start drawing."
        } else {
            processor.commandPrompt = nil
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .finished  // Immediately done — just toggled the palette
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

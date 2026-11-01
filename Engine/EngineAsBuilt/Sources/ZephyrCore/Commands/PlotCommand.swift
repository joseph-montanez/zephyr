import Foundation
import CSDL3
import SwiftSDL

/// `PLOT` / `PRINT`: opens the Plot dialog for the active layout.
/// `-PLOT` stays command-line (Phase 4 step 25).
@MainActor
public final class PlotCommand: FeatureCommand {
    private weak var processor: CADCommandProcessor?

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        self.processor = processor
        engine.ui.plotDialogActive = true
        processor.commandPrompt = "Plot the active layout to PDF."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.plotDialogActive = false
        self.processor = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        .handled
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            engine.ui.plotDialogActive = false
            return .finished
        }
        return .handled
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func renderImGui(engine: PhrostEngine) {
        guard !engine.ui.plotDialogActive, let processor else { return }
        processor.finishFeatureCommand(engine: engine)
        self.processor = nil
    }
}

import Foundation
import CSDL3
import SwiftSDL

/// `PAGESETUP`: opens the Page Setup Manager for the active layout.
/// Full manager/dialog UI lands in Phase 2 steps 13–15; the command,
/// descriptors, and UI flags land here so the surface is invokable and
/// parity-tested end to end.
@MainActor
public final class PageSetupCommand: FeatureCommand {
    private weak var processor: CADCommandProcessor?

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        self.processor = processor
        engine.ui.pageSetupManagerActive = true
        processor.commandPrompt = "Manage page setups for the active layout."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.pageSetupManagerActive = false
        engine.ui.pageSetupDialogActive = false
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
            engine.ui.pageSetupManagerActive = false
            engine.ui.pageSetupDialogActive = false
            return .finished
        }
        return .handled
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func renderImGui(engine: PhrostEngine) {
        guard !engine.ui.pageSetupManagerActive,
              !engine.ui.pageSetupDialogActive,
              let processor else { return }
        processor.finishFeatureCommand(engine: engine)
        self.processor = nil
    }
}

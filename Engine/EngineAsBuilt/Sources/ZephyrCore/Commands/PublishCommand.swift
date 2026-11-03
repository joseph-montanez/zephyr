import Foundation
import CSDL3
import SwiftSDL

/// `PUBLISH`: opens the Publish dialog for batch sheet publishing
/// (sheet picking, Master setup assignment, and `.dsd` I/O).
/// `+PUBLISH [file.dsd]` preloads a sheet list into the dialog;
/// `-PUBLISH` publishes a sheet list from the command line (foreground).
@MainActor
public final class PublishCommand: FeatureCommand {
    private weak var processor: CADCommandProcessor?

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        self.processor = processor
        engine.ui.publishDialogActive = true
        processor.commandPrompt = "Batch-publish drawing sheets to PDF."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.publishDialogActive = false
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
            engine.ui.publishDialogActive = false
            return .finished
        }
        return .handled
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func renderImGui(engine: PhrostEngine) {
        guard !engine.ui.publishDialogActive, let processor else { return }
        processor.finishFeatureCommand(engine: engine)
        self.processor = nil
    }
}

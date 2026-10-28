import Foundation
import CSDL3
import SwiftSDL

/// DIMSTYLE (D, DST): opens the dimension style manager. Mirrors
/// StyleCommand: the window owns the session, Escape or closing the
/// window finishes the feature command.
@MainActor
public final class DimStyleCommand: FeatureCommand {
    private weak var processor: CADCommandProcessor?

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        self.processor = processor
        engine.ui.dimStyleManagerActive = true
        processor.commandPrompt = "Manage dimension styles."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.dimStyleManagerActive = false
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
            engine.ui.dimStyleManagerActive = false
            return .finished
        }
        return .handled
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func renderImGui(engine: PhrostEngine) {
        guard !engine.ui.dimStyleManagerActive, let processor else { return }
        processor.finishFeatureCommand(engine: engine)
        self.processor = nil
    }
}

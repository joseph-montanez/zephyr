// Sources/ZephyrCore/Commands/OopsCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// OOPS, Phase 2.2g: restores the last erased entity set without a full
/// UNDO. `CADDocument.removeEntity`/`removeEntities` record every real
/// removal into the session-state `oopsBuffer`; `oopsRestore()` re-inserts
/// the buffered entities with their original handles under one undo entry
/// and clears the buffer. Empty buffer restores nothing and pushes no undo.
@MainActor
public final class OopsCommand: FeatureCommand {

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let restored = engine.document.oopsRestore()
        if restored > 0 {
            engine.tabManager.markActiveDirty()
            processor.commandPrompt =
                "Restored \(restored) object\(restored == 1 ? "" : "s")."
        } else {
            processor.commandPrompt = "Nothing to restore."
        }
        processor.finishFeatureCommand(engine: engine)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

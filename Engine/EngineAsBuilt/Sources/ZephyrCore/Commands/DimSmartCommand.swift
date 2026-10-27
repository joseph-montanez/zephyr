// Sources/ZephyrCore/Commands/DimSmartCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// Smart DIM (Phase 2.1): chooses the dimension type from the
/// selection/context, announces it with a result line, and transfers to
/// that type's normal flow via executeCommand — no duplicated builders.
/// A lone dimension chains (DIMCONTINUE adopts the selection); an empty
/// click falls back to manual linear points. The result line names the
/// choice and its evidence, so a wrong guess is visible and overridable
/// by typing another dimension command.
@MainActor
public final class DimSmartCommand: FeatureCommand {

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let entities = engine.cadSelection.selectedHandles.compactMap {
            engine.document.entity(for: $0)
        }
        if let choice = DimSmartChoice.resolve(entities: entities, in: engine.document) {
            transfer(choice, engine: engine, processor: processor)
        } else if entities.isEmpty {
            processor.commandPrompt = "Select a line, arc, circle, or dimension:"
        } else {
            processor.commandPrompt = "Ambiguous selection — select one line, arc, circle, or dimension:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX, worldY: worldY, document: engine.document),
              let entity = engine.document.entity(for: handle),
              let choice = DimSmartChoice.resolve(entities: [entity], in: engine.document)
        else {
            // Empty space: manual linear points, announced like any choice.
            print("[CAD] DIM: Linear from points.")
            processor.executeCommand("DIMLINEAR")
            return .handled
        }
        transfer(choice, engine: engine, processor: processor)
        return .handled
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
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            let entities = engine.cadSelection.selectedHandles.compactMap {
                engine.document.entity(for: $0)
            }
            guard let choice = DimSmartChoice.resolve(entities: entities, in: engine.document) else {
                processor.commandPrompt = "Select a line, arc, circle, or dimension:"
                return .handled
            }
            transfer(choice, engine: engine, processor: processor)
            return .handled
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    /// Prints the result line, then replaces this command with the chosen
    /// flow. executeCommand overwrites activeFeatureCommand (the standard
    /// handoff, as in the ALIGN/PAN cases), so callers must return
    /// .handled — never .finished, which would cancel the new flow.
    private func transfer(
        _ choice: DimSmartChoice,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        print(choice.resultLine())
        processor.executeCommand(choice.targetCommand)
    }
}

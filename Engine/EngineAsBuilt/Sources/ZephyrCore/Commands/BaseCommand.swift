// Sources/ZephyrCore/Commands/BaseCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// BASE, Phase 2.3a: sets the drawing insertion base point
/// (`CADDocument.insertionBase`, DXF `$INSBASE`).
///
/// Like a sysvar: session state, never undoable. Accepts a typed
/// `x,y[,z]` point, a mouse pick (z = 0), or Enter to keep the current
/// value. The point round-trips through DXF HEADER and EAB metadata.
@MainActor
public final class BaseCommand: FeatureCommand {

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt =
            "Enter insertion base point <\(fmt(engine.document.insertionBase))>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        engine.document.insertionBase = Vector3(x: worldX, y: worldY, z: 0)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt =
            "Insertion base point set to \(fmt(engine.document.insertionBase))."
        return .finished
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let point = WblockCommand.parsePoint(trimmed) else {
                processor.commandPrompt =
                    "Enter base point as x,y[,z], pick a point, or press Enter:"
                return .continue
            }
            engine.document.insertionBase = point
            engine.tabManager.markActiveDirty()
            processor.commandPrompt =
                "Insertion base point set to \(fmt(point))."
        } else {
            processor.commandPrompt =
                "Insertion base point is \(fmt(engine.document.insertionBase))."
        }
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func fmt(_ point: Vector3) -> String {
        "\(point.x),\(point.y),\(point.z)"
    }
}

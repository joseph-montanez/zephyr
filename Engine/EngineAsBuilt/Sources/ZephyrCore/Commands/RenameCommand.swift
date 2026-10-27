// Sources/ZephyrCore/Commands/RenameCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// RENAME, Phase 2.2g: renames blocks, dimension styles, layers,
/// linetypes, text styles, and leader styles by name.
///
/// Three prompts — object type, old name, new name — following the
/// -RENAME command-line flow. Validation (protected names like `0` and
/// `Standard`, collisions, illegal characters) reports through the prompt
/// and re-asks the failing step instead of aborting. Each successful
/// rename lands in exactly one undo entry via `CADDocument.rename`.
@MainActor
public final class RenameCommand: FeatureCommand {

    private enum Phase {
        case kind
        case oldName
        case newName
    }

    private var phase: Phase = .kind
    private var kind: CADRename.Kind?

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .kind
        kind = nil
        processor.commandPrompt =
            "Enter object type to rename [Block/Dimstyle/Layer/Linetype/Text style/Leader style]:"
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .kind:
            guard let matched = CADRename.Kind.match(trimmed) else {
                processor.commandPrompt =
                    "Unknown type '\(trimmed)'. Enter object type to rename " +
                    "[Block/Dimstyle/Layer/Linetype/Text style/Leader style]:"
                return .continue
            }
            kind = matched
            phase = .oldName
            processor.commandPrompt = "Enter old \(matched.rawValue.lowercased()) name:"
            return .continue
        case .oldName:
            guard let kind else {
                phase = .kind
                return .continue
            }
            guard !trimmed.isEmpty else {
                processor.commandPrompt = "Old name cannot be blank. " +
                    "Enter old \(kind.rawValue.lowercased()) name:"
                return .continue
            }
            lastOldName = trimmed
            phase = .newName
            processor.commandPrompt = "Enter new \(kind.rawValue.lowercased()) name:"
            return .continue
        case .newName:
            guard let kind else {
                phase = .kind
                return .continue
            }
            // The old name prompt just ran, so its answer is the previous
            // prompt's input: recover it from the stored phase handoff.
            guard let oldName = lastOldName else {
                phase = .oldName
                processor.commandPrompt =
                    "Enter old \(kind.rawValue.lowercased()) name:"
                return .continue
            }
            if let error = engine.document.rename(
                kind: kind, from: oldName, to: trimmed) {
                processor.commandPrompt = "\(error) Enter new " +
                    "\(kind.rawValue.lowercased()) name:"
                return .continue
            }
            engine.tabManager.markActiveDirty()
            processor.commandPrompt =
                "\(kind.rawValue) '\(oldName)' renamed to '\(trimmed)'."
            lastOldName = nil
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    /// Handoff between the old-name and new-name prompts.
    private var lastOldName: String?
}

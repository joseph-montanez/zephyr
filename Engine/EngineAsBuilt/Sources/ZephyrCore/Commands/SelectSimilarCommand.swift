// Sources/ZephyrCore/Commands/SelectSimilarCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// SELECTSIMILAR, Phase 2.2a: select every entity matching a reference
/// object under the SELECTSIMILARMODE bitmask (type 1, layer 2, color 4,
/// linetype 8, lineweight 16, name 128; default 130 = layer+name).
/// Adopt a single selection as the reference, or pick one; `Settings`
/// edits the bitmask through the shared sysvar validation. Matches respect
/// the on/off visibility model (invisible layers never select); frozen and
/// locked layers do not exist in the model yet, so there is nothing further
/// to honor. Plot/object-style bits (32/64) have no model and are reported
/// as ignored, never silently applied.
@MainActor
public final class SelectSimilarCommand: FeatureCommand {

    private enum Phase {
        case pickReference
        case modeValue
    }

    private var phase = Phase.pickReference

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .pickReference
        let handles = engine.cadSelection.selectedHandles
        if handles.count == 1,
           let first = handles.first,
           engine.document.entity(for: first) != nil {
            apply(referenceHandle: first, engine: engine, processor: processor)
            processor.commandPrompt = "Select reference object or [Settings]:"
            return
        }
        processor.commandPrompt = "Select reference object or [Settings]:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .pickReference else { return .continue }
        let hitHandle = engine.cadSelection.hitTest(
            worldX: worldX, worldY: worldY,
            document: engine.document,
            threshold: 12.0 / engine.camera.zoom)
        guard let handle = hitHandle,
              engine.document.entity(for: handle) != nil else {
            processor.commandPrompt = "No object there. Select reference object or [Settings]:"
            return .continue
        }
        apply(referenceHandle: handle, engine: engine, processor: processor)
        processor.commandPrompt = "Select reference object or [Settings]:"
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
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return .continue
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .pickReference:
            guard trimmed.uppercased() == "S" || trimmed.uppercased() == "SETTINGS" else {
                return .continue
            }
            phase = .modeValue
            processor.commandPrompt = "Enter SELECTSIMILARMODE (0-255)"
                + " <\(engine.document.selectSimilarMode)>:"
            return .continue
        case .modeValue:
            guard let value = Int(trimmed) else {
                processor.commandPrompt = "Enter SELECTSIMILARMODE (0-255)"
                    + " <\(engine.document.selectSimilarMode)>:"
                return .continue
            }
            if let rejection = processor.lispVars.set(
                "SELECTSIMILARMODE", .int(value), document: engine.document) {
                processor.commandPrompt = rejection + ". Enter SELECTSIMILARMODE (0-255)"
                    + " <\(engine.document.selectSimilarMode)>:"
                return .continue
            }
            let mode = engine.document.selectSimilarMode
            processor.commandPrompt = "SELECTSIMILARMODE = \(mode)"
                + " (\(EntityFilter.modeDescription(mode)))."
                + " Select reference object or [Settings]:"
            phase = .pickReference
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func currentMode(engine: PhrostEngine, processor: CADCommandProcessor) -> Int {
        if case .int(let mode) = processor.lispVars.get(
            "SELECTSIMILARMODE", document: engine.document, activeCommand: nil) {
            return mode
        }
        return engine.document.selectSimilarMode
    }

    private func apply(
        referenceHandle: UUID, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let reference = engine.document.entity(for: referenceHandle) else {
            return
        }
        let mode = currentMode(engine: engine, processor: processor)
        var matched: [UUID] = []
        for entity in engine.document.allEntities.sorted(
            by: { $0.handle.uuidString < $1.handle.uuidString }) {
            guard EntityFilter.isVisibleForSelection(entity, in: engine.document),
                  EntityFilter.similar(
                      to: reference, candidate: entity,
                      mode: mode, in: engine.document) else {
                continue
            }
            matched.append(entity.handle)
        }
        engine.cadSelection.selectedHandles = Set(matched)
        engine.cadSelection.lastSelectedHandle = referenceHandle
        var message = "Selected \(matched.count) similar object(s)"
            + " by \(EntityFilter.modeDescription(mode)) (mode \(mode))."
        let ignored = EntityFilter.ignoredModeBits(mode)
        if !ignored.isEmpty {
            message += " Ignored without model: \(ignored.joined(separator: ", "))."
        }
        print("[SELECTSIMILAR] \(message)")
        processor.commandPrompt = message
    }
}

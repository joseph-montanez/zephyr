// Sources/ZephyrCore/Commands/IsolateCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// ISOLATEOBJECTS / HIDEOBJECTS / UNISOLATEOBJECTS, Phase 2.2e: per-entity
/// isolation over `CADDocument.isolatedHiddenHandles`.
///
/// Isolation is render-only session state, never undoable and never
/// persisted: the hide/isolate/unisolate methods push no undo, snapshots
/// carry the set to the renderer but restore paths ignore it, and DXF/EAB
/// IO never sees it. Hidden entities are skipped by rendering (renderer
/// bridge spec pass), hit-testing, rectangle selection, select-all, grips,
/// object snap, zoom extents, and the `EntityFilter` selection predicate
/// (so SELECTSIMILAR/QSELECT/FILTER skip them too).
///
/// - ISOLATEOBJECTS hides everything except the selection (or picked
///   objects when the selection is empty); the kept objects stay selected.
/// - HIDEOBJECTS hides the selection (or picked objects) and deselects
///   what it hid.
/// - UNISOLATEOBJECTS restores everything hidden by either command.
@MainActor
public final class IsolateCommand: FeatureCommand {

    public enum Mode {
        case isolate
        case hide
        case unisolate
    }

    private let mode: Mode
    private var picking = false

    public init(mode: Mode) {
        self.mode = mode
    }

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        switch mode {
        case .unisolate:
            let restored = engine.document.unisolateEntities()
            if restored > 0 {
                engine.tabManager.markActiveDirty()
            }
            processor.commandPrompt = restored > 0
                ? "\(restored) object\(restored == 1 ? "" : "s") restored."
                : "No isolated objects."
            processor.finishFeatureCommand(engine: engine)
        case .isolate, .hide:
            if !engine.cadSelection.selectedHandles.isEmpty {
                apply(engine: engine, processor: processor)
                processor.finishFeatureCommand(engine: engine)
            } else {
                picking = true
                processor.commandPrompt = mode == .isolate
                    ? "Select objects to isolate, then press Enter:"
                    : "Select objects to hide, then press Enter:"
            }
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
        guard picking else { return .continue }
        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks
        ) else {
            return .handled
        }
        let shiftHeld = engine.io?.pointee.KeyShift ?? false
        if shiftHeld {
            engine.cadSelection.removeFromSelection(handle)
        } else {
            engine.cadSelection.addToSelection(handle)
        }
        let verb = mode == .isolate ? "isolate" : "hide"
        processor.commandPrompt =
            "Select objects to \(verb), then press Enter " +
            "(\(engine.cadSelection.selectedCount) selected)"
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
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard picking else { return .finished }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            picking = false
            apply(engine: engine, processor: processor)
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func apply(engine: PhrostEngine, processor: CADCommandProcessor) {
        let handles = engine.cadSelection.selectedHandles
        guard !handles.isEmpty else {
            processor.commandPrompt = "Nothing selected; nothing changed."
            return
        }
        switch mode {
        case .isolate:
            engine.document.isolateEntities(keeping: handles)
            let hidden = engine.document.isolatedHiddenHandles.count
            processor.commandPrompt =
                "\(hidden) object\(hidden == 1 ? "" : "s") isolated."
        case .hide:
            engine.document.hideEntitiesIsolated(handles)
            for handle in handles {
                engine.cadSelection.removeFromSelection(handle)
            }
            processor.commandPrompt =
                "\(handles.count) object\(handles.count == 1 ? "" : "s") hidden."
        case .unisolate:
            break
        }
    }
}

// Sources/ZephyrCore/Commands/GroupCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// GROUP / UNGROUP, Phase 2.2f: named selection groups over
/// `CADDocument.groups` (`CADGroup`).
///
/// GROUP takes the pre-selection (or a click-pick loop when empty), then
/// asks for a name defaulting to the next LT-style anonymous `*A<n>` name,
/// and creates the group with one undo entry. UNGROUP takes the
/// pre-selection (or one pick) and removes every group containing the
/// picked/first-selected entity, also one undo entry. An empty pick
/// changes nothing. Pick behavior under PICKSTYLE comes from the
/// `CADSelectionManager.groupExpansionProvider` hook, not from here.
@MainActor
public final class GroupCommand: FeatureCommand {

    public enum Mode {
        case group
        case ungroup
    }

    private enum Phase {
        case pick
        case name
    }

    private let mode: Mode
    private var phase: Phase = .pick
    private var pendingName = ""

    public init(mode: Mode) {
        self.mode = mode
    }

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if !engine.cadSelection.selectedHandles.isEmpty {
            advance(engine: engine, processor: processor)
        } else {
            phase = .pick
            processor.commandPrompt = mode == .group
                ? "Select objects for group, then press Enter:"
                : "Select object in group to ungroup, then press Enter:"
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
        guard phase == .pick else { return .continue }
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
        let verb = mode == .group ? "for group" : "in group to ungroup"
        processor.commandPrompt =
            "Select objects \(verb), then press Enter " +
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .pick:
            guard trimmed.isEmpty else { return .continue }
            return advance(engine: engine, processor: processor)
        case .name:
            let name = trimmed.isEmpty ? pendingName : trimmed
            guard let group = engine.document.createGroup(
                named: name, members: Array(engine.cadSelection.selectedHandles))
            else {
                processor.commandPrompt = "Group not created; nothing selected."
                return .finished
            }
            engine.tabManager.markActiveDirty()
            processor.commandPrompt =
                "Group '\(group.name)' created with \(group.members.count) " +
                "object\(group.members.count == 1 ? "" : "s")."
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    /// Runs after the pick step. Returns the command result for the
    /// caller's context (Enter key or immediate pre-selection).
    @discardableResult
    private func advance(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard !engine.cadSelection.selectedHandles.isEmpty else {
            processor.commandPrompt = "Nothing selected; nothing changed."
            return .finished
        }
        switch mode {
        case .group:
            phase = .name
            pendingName = engine.document.nextAnonymousGroupName()
            processor.commandPrompt = "Group name <\(pendingName)>:"
            return .continue
        case .ungroup:
            let targets = ungroupTargets(
                handles: engine.cadSelection.selectedHandles,
                in: engine.document)
            guard !targets.isEmpty else {
                processor.commandPrompt =
                    "Selected objects are in no group; nothing changed."
                return .finished
            }
            for name in targets {
                engine.document.ungroup(named: name)
            }
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = targets.count == 1
                ? "Group '\(targets[0])' removed."
                : "Groups removed: \(targets.joined(separator: ", "))."
            return .finished
        }
    }

    /// Names of every group containing any selected handle, in sorted
    /// order for stable output.
    private func ungroupTargets(
        handles: Set<UUID>, in document: CADDocument
    ) -> [String] {
        var names = Set<String>()
        for handle in handles {
            for group in document.groups.values where group.members.contains(handle) {
                names.insert(group.name)
            }
        }
        return names.sorted()
    }
}

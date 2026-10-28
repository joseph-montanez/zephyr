import Foundation
import CSDL3
import ImGui

// =========================================================================
// ATTEDIT — edit attribute values on selected inserts: one prompt per
// editable definition (constants skipped), in definition order. Empty
// input keeps the current value. All touched inserts commit under one
// undo entry via `updateEntities`.
// =========================================================================

@MainActor
public final class AtteditCommand: FeatureCommand {
    public var name: String { "ATTEDIT" }

    private var targets: [CADEntity] = []
    private var targetIndex = 0
    private var pendingDefs: [CADAttributeDefinition] = []
    private var defIndex = 0
    private var staged: [UUID: [String: CADAttributeValue]] = [:]
    private var skippedConstants = 0
    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        targets = engine.cadSelection.selectedHandles.compactMap { handle in
            guard let entity = engine.document.entity(for: handle),
                  entity.blockID != nil,
                  engine.document.block(for: entity.blockID!) != nil else {
                return nil
            }
            return entity
        }
        guard !targets.isEmpty else {
            processor.commandPrompt = "No block references selected."
            finished = true
            return
        }
        targetIndex = 0
        advanceToNextEditable(engine: engine, processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = true
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard !finished, targetIndex < targets.count,
              defIndex < pendingDefs.count else {
            return .finished
        }
        let def = pendingDefs[defIndex]
        let input = text.trimmingCharacters(in: .newlines)
        if !input.isEmpty {
            var values = staged[targets[targetIndex].handle] ?? [:]
            values[def.key] = CADAttributeValue(value: input)
            staged[targets[targetIndex].handle] = values
        }
        defIndex += 1
        advanceToNextEditable(engine: engine, processor: processor)
        return finished ? .finished : .continue
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        finished ? .finished : .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func advanceToNextEditable(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        while targetIndex < targets.count {
            let entity = targets[targetIndex]
            guard let bid = entity.blockID,
                  let block = engine.document.block(for: bid) else {
                targetIndex += 1
                continue
            }
            if defIndex >= pendingDefs.count {
                // (Re)seed definition list when moving to a new target.
                pendingDefs = block.attributeDefinitions
                defIndex = 0
            }
            while defIndex < pendingDefs.count, pendingDefs[defIndex].isConstant {
                skippedConstants += 1
                defIndex += 1
            }
            guard defIndex < pendingDefs.count else {
                targetIndex += 1
                pendingDefs = []
                defIndex = 0
                continue
            }
            let def = pendingDefs[defIndex]
            let stagedValues = staged[entity.handle] ?? entity.attributeValues
            let current = stagedValues[def.key]?.value ?? def.defaultValue
            let label = targets.count > 1
                ? "[\(targetIndex + 1)/\(targets.count)] \(def.tag) <\(current)>:"
                : "\(def.tag) <\(current)>:"
            openTextPrompt(label, processor: processor)
            return
        }
        commit(engine: engine, processor: processor)
    }

    private func commit(engine: PhrostEngine, processor: CADCommandProcessor) {
        var updated: [CADEntity] = []
        for entity in targets {
            guard let values = staged[entity.handle] else { continue }
            var copy = entity
            for (key, value) in values {
                copy.attributeValues[key] = value
            }
            updated.append(copy)
        }
        if !updated.isEmpty {
            engine.document.updateEntities(updated)
            engine.tabManager.markActiveDirty()
        }
        let scope = targets.count == 1 ? "1 insert" : "\(targets.count) inserts"
        processor.commandPrompt =
            "Updated \(updated.count) of \(scope). (\(skippedConstants) constant skipped.)"
        finished = true
    }

    private func openTextPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }
}

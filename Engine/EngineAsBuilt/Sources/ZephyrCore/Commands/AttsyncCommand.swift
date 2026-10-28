import Foundation
import CSDL3
import ImGui

// =========================================================================
// ATTSYNC — re-apply attribute definitions to inserts: preselected
// inserts sync directly, otherwise a block name (or ALL) picks the set.
// Missing tags gain defaults, orphaned tags drop, edited values survive.
// One undo entry for the whole run.
// =========================================================================

@MainActor
public final class AttsyncCommand: FeatureCommand {
    public var name: String { "ATTSYNC" }

    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let selected = engine.cadSelection.selectedHandles.compactMap { handle in
            engine.document.entity(for: handle)
        }.filter { $0.blockID != nil }
        if !selected.isEmpty {
            sync(
                handles: selected.map(\.handle),
                engine: engine, processor: processor)
            finished = true
            return
        }
        openTextPrompt(
            "Enter block name or ALL <ALL>:", processor: processor)
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
        guard !finished else { return .finished }
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty || input.uppercased() == "ALL" {
            let count = engine.document.syncAttributesForBlock(nil)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "ATTSYNC updated \(count) insert(s)."
            finished = true
            return .finished
        }
        guard let block = engine.document.allBlocks.first(where: {
            $0.name.caseInsensitiveCompare(input) == .orderedSame
        }) else {
            openTextPrompt(
                "Block \"\(input)\" not found. Enter block name or ALL <ALL>:",
                processor: processor)
            return .continue
        }
        let count = engine.document.syncAttributesForBlock(block.handle)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt =
            "ATTSYNC updated \(count) insert(s) of \"\(block.name)\"."
        finished = true
        return .finished
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

    private func sync(
        handles: [UUID], engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // One undo entry for the whole run (mirrors FIND's applyCollected).
        let before = engine.document.snapshot()
        var updated: [CADEntity] = []
        for handle in handles {
            guard var entity = engine.document.entity(for: handle),
                  let bid = entity.blockID,
                  let block = engine.document.block(for: bid),
                  !block.isXref else { continue }
            entity.attributeValues = CADAttributeSync.apply(
                definitions: block.attributeDefinitions, to: entity.attributeValues)
            updated.append(entity)
        }
        for entity in updated {
            engine.document.updateEntityLive(entity)
        }
        engine.document.invalidateEntityGrid()
        engine.document.pushUndo(before)
        if !updated.isEmpty { engine.tabManager.markActiveDirty() }
        processor.commandPrompt = "ATTSYNC updated \(updated.count) insert(s)."
    }

    private func openTextPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }
}

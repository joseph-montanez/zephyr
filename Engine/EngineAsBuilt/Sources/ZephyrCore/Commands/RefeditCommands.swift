import Foundation
import CSDL3
import ImGui

// =========================================================================
// REFEDIT — edit a block or xref in place. Regular blocks reuse the
// block-editor session (BEDIT-equivalent); xrefs materialize the loaded
// shadow geometry, and REFCLOSE saves back to the xref file.
// DWG-backed xrefs are refused until ODA write-back is proven; unloaded
// or pathless xrefs are refused with guidance instead of a dead session.
// REFCLOSE — end the session: [Save/Discard]. Block sessions commit
// through the block editor; xref sessions save back to the file, refresh
// through the reload path, and never touch the host block table.
// =========================================================================

@MainActor
public final class RefeditCommand: FeatureCommand {
    public var name: String { "REFEDIT" }

    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = false
        if let handle = engine.cadSelection.selectedHandles.first,
           let entity = engine.document.entity(for: handle),
           entity.blockID != nil {
            begin(entity: entity, engine: engine, processor: processor)
            finished = true
            return
        }
        XrefCommandSupport.showCanvasPrompt(
            "Select a block reference or xref to edit:", processor: processor)
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
        .finished
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard !finished else { return .finished }
        guard let handle = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY, document: engine.document),
              let entity = engine.document.entity(for: handle),
              entity.blockID != nil else {
            return .continue
        }
        begin(entity: entity, engine: engine, processor: processor)
        finished = true
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func begin(
        entity: CADEntity, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let bid = entity.blockID,
              let block = engine.document.block(for: bid) else {
            processor.commandPrompt = "Not a block reference."
            return
        }
        guard engine.tabManager.activeTab?.editingBlockID == nil else {
            processor.commandPrompt = "Already editing a block. Close it first (REFCLOSE)."
            return
        }
        guard !block.isXref else {
            beginXref(block: block, engine: engine, processor: processor)
            return
        }
        engine.tabManager.enterBlockEditor(blockID: bid)
        processor.commandPrompt =
            "Editing block \"\(block.name)\". REFCLOSE saves or discards."
    }

    private func beginXref(
        block: CADBlock, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let ctx = XrefCommandSupport.tabContext(engine: engine) else {
            return
        }
        guard let entry = ctx.store.entry(for: block.handle) else {
            processor.commandPrompt = "Xref \"\(block.name)\" has no runtime entry."
            return
        }
        guard let shadow = entry.shadow, entry.status.hasShadowGeometry else {
            processor.commandPrompt =
                "Xref \"\(block.name)\" is not loaded. Reload it first."
            return
        }
        guard let filePath = entry.foundAtPath, !filePath.isEmpty else {
            processor.commandPrompt =
                "Xref \"\(block.name)\" cannot be resolved to a file."
            return
        }
        guard URL(fileURLWithPath: filePath).pathExtension.lowercased() != "dwg" else {
            processor.commandPrompt =
                "DWG-backed xrefs cannot be edited in place yet."
            return
        }
        engine.tabManager.enterBlockEditor(blockID: block.handle, shadow: shadow)
        processor.commandPrompt =
            "Editing xref \"\(block.name)\" in place. REFCLOSE saves back to the file."
    }
}

@MainActor
public final class RefcloseCommand: FeatureCommand {
    public var name: String { "REFCLOSE" }

    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = false
        guard let tab = engine.tabManager.activeTab,
              let blockID = tab.editingBlockID,
              let parentDoc = tab.parentDocument,
              let block = parentDoc.block(for: blockID) else {
            processor.commandPrompt = "No reference being edited."
            finished = true
            return
        }
        if block.isXref {
            XrefCommandSupport.openTextPrompt(
                "Save xref changes back to the file? [Yes/No] <Yes>:",
                processor: processor)
        } else {
            XrefCommandSupport.openTextPrompt(
                "Save block changes? [Yes/No] <Yes>:", processor: processor)
        }
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
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let tab = engine.tabManager.activeTab,
              let blockID = tab.editingBlockID,
              let parentDoc = tab.parentDocument,
              let block = parentDoc.block(for: blockID) else {
            finished = true
            return .finished
        }
        if input == "N" || input == "NO" {
            engine.tabManager.exitBlockEditor(saveChanges: false)
            processor.commandPrompt = "Discarded reference-edit changes."
            finished = true
            return .finished
        }
        guard block.isXref else {
            engine.tabManager.exitBlockEditor(saveChanges: true)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "Saved block \"\(block.name)\"."
            finished = true
            return .finished
        }
        saveXref(block: block, engine: engine, processor: processor)
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

    private func saveXref(
        block: CADBlock, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let ctx = XrefCommandSupport.tabContext(engine: engine),
              let tab = engine.tabManager.activeTab,
              let parentDoc = tab.parentDocument,
              let entry = ctx.store.entry(for: block.handle),
              let filePath = entry.foundAtPath, !filePath.isEmpty else {
            processor.commandPrompt =
                "Cannot save back: xref path is no longer resolvable. Session stays open."
            return
        }
        guard URL(fileURLWithPath: filePath).pathExtension.lowercased() != "dwg" else {
            processor.commandPrompt =
                "DWG-backed xrefs cannot be saved back yet. Session stays open."
            return
        }
        do {
            let count = try RefeditSaveBack.save(
                tempEntities: tab.document.allEntities,
                hostDocument: parentDoc,
                to: URL(fileURLWithPath: filePath))
            engine.tabManager.exitBlockEditor(saveChanges: false)
            XrefLoader.requestLoad(
                store: ctx.store, blockHandle: block.handle,
                documents: ctx.documents, hostFolder: ctx.hostFolder,
                forceReload: true)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt =
                "Saved \(count) entit(ies) back to \"\(block.name)\"."
            finished = true
        } catch {
            processor.commandPrompt =
                "Save-back failed (\(error)). Session stays open."
        }
    }
}

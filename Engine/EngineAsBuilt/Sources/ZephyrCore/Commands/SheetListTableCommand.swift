import Foundation
import CSDL3

// MARK: - SheetListTableCommand
//
// SHEETLISTTABLE: inserts the current sheet set's sheet list (Number +
// Title, titled with the set name) at a picked point. Headless
// equivalent of SSM "Insert Sheet List Table"; the table is a snapshot.

@MainActor
public final class SheetListTableCommand: FeatureCommand {
    private enum Phase {
        case pickInsertion
    }

    private var phase: Phase = .pickInsertion

    public init() {}

    public var isSnappingEnabled: Bool { phase == .pickInsertion }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard processor.sheetSetStore.current != nil else {
            processor.commandPrompt = "No sheet set open. Use OPENSHEETSET or NEWSHEETSET first."
            return
        }
        processor.commandPrompt = "Specify insertion point:"
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .pickInsertion else { return .continue }
        let picked = engine.snap.currentSnapResult?.worldPos
            ?? Vector3(x: worldX, y: worldY, z: 0)
        insert(at: picked, engine: engine, processor: processor)
        return .finished
    }

    public func handleMouseUp(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func insert(at point: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        guard let set = processor.sheetSetStore.current else {
            processor.commandPrompt = "No sheet set open. Nothing inserted."
            return
        }
        let data = SheetSetSheetListTable.data(for: set)
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            blockID: nil,
            localGeometry: [.table(data: data, origin: point, color: nil)],
            transform: .identity,
            xdata: [:])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        engine.cadSelection.select(entity.handle)
        engine.interaction.selectTable(handle: entity.handle)
        processor.commandPrompt = "Sheet list table created."
    }
}

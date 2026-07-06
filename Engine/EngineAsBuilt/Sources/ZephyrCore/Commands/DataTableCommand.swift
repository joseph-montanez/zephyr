import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - DataTableCommand
//
// Toggles the DataTable panel visibility and can create a new table entity
// via a click-to-place workflow.
// =========================================================================

@MainActor
public final class DataTableCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.dataTablePanelVisible = true
        processor.commandPrompt = "Data table panel opened. Click in drawing to place a new table, or use panel to edit existing tables."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        // Panel stays open — user can close it manually
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Create a simple table at the click point
        let columns = [
            DataTableColumn(name: "A"),
            DataTableColumn(name: "B"),
            DataTableColumn(name: "C"),
        ]
        var rows: [DataTableRow] = []
        for _ in 0..<3 {
            rows.append(DataTableRow(cells: columns.map { DataTableCell(columnID: $0.id, value: .empty) }))
        }
        let data = DataTableData(
            columns: columns,
            rows: rows,
            title: "Table",
            rowHeights: [],
            defaultRowHeight: 2.0,
            defaultColumnWidth: 5.0,
            headerRowCount: 1,
            cellMargin: 0.25,
            textHeight: 1.5,
            cellAlignment: .left
        )

        let origin = Vector3(x: worldX, y: worldY, z: 0)
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            blockID: nil,
            localGeometry: [.table(data: data, origin: origin, color: nil)],
            transform: .identity,
            xdata: [:]
        )
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Table created at (\(String(format: "%.2f", worldX)), \(String(format: "%.2f", worldY)))."

        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // No-op
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        // No overlay
    }
}

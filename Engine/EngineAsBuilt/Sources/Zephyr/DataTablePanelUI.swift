import ZephyrCore
import Foundation
import ImGui

// =========================================================================
// MARK: - DataTablePanelUI
//
// ImGui panel for listing and editing DataTable entities in the document.
// Shows a table list with create/delete controls, and a spreadsheet-like
// cell editor for the selected table.
// =========================================================================

@MainActor
struct DataTablePanelUI {

    static var _isDocked: Bool = false

    /// Track which table entity is being edited and which cell is active.
    private static var editingTableHandle: UUID? = nil
    private static var editingCellRow: Int = -1
    private static var editingCellCol: Int = -1
    private static var cellEditBuffer: String = ""

    static func render(engine: PhrostEngine) {
        let doc = engine.document

        ImGuiSetNextWindowSize(
            ImVec2(x: ImGuiGetFontSize() * 28, y: ImGuiGetFontSize() * 35),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let isDocked = _isDocked
        var flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
        if isDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("Data Tables##DataTablePanel", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("Data Tables##DataTablePanel", &opened, flags)
        }

        guard entered else {
            _isDocked = ImGuiIsWindowDocked()
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
            return
        }
        _isDocked = ImGuiIsWindowDocked()
        defer {
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
        }

        if !isDocked && !opened {
            engine.ui.dataTablePanelVisible = false
            return
        }

        ImGuiTextV("Data Tables")
        ImGuiSameLine(0, 8)

        if igButton("Create Table", ImVec2(x: 0, y: 0)) {
            createNewTable(engine: engine)
        }

        igSeparator()

        // Find all table entities
        let tableEntities = doc.allEntities.compactMap { entity -> (CADEntity, DataTableData)? in
            guard let geom = entity.localGeometry else { return nil }
            for prim in geom {
                if case .table(let data, _, _) = prim {
                    return (entity, data)
                }
            }
            return nil
        }

        if tableEntities.isEmpty {
            ImGuiTextV("No tables in this document.")
        } else {
            // List tables and provide editing
            for (entity, data) in tableEntities {
                let title = data.title ?? "Table (\(data.rows.count) × \(data.columns.count))"
                let label = "\(title)##tbl\(entity.handle)"

                var nodeFlags = Int32(ImGuiTreeNodeFlags_OpenOnArrow.rawValue) |
                    Int32(ImGuiTreeNodeFlags_SpanAvailWidth.rawValue)
                if editingTableHandle == entity.handle {
                    nodeFlags |= Int32(ImGuiTreeNodeFlags_Selected.rawValue)
                }

                let expanded = igTreeNodeEx_Str(label, nodeFlags)

                // Context menu for delete
                if igBeginPopupContextItem("##tblctx\(entity.handle)", Int32(ImGuiPopupFlags_MouseButtonRight.rawValue)) {
                    if igMenuItem_Bool("Delete Table", nil, false, true) {
                        engine.document.removeEntity(handle: entity.handle)
                        if editingTableHandle == entity.handle {
                            editingTableHandle = nil
                        }
                        engine.tabManager.markActiveDirty()
                    }
                    ImGuiEndPopup()
                }

                if expanded {
                    ImGuiTextV("Rows: \(data.rows.count)  Columns: \(data.columns.count)")

                    if igSmallButton("Add Row##ar\(entity.handle)") {
                        addRow(to: entity.handle, engine: engine)
                    }
                    ImGuiSameLine(0, 4)
                    if igSmallButton("Delete Row##dr\(entity.handle)") {
                        deleteLastRow(from: entity.handle, engine: engine)
                    }
                    ImGuiSameLine(0, 4)
                    if igSmallButton("Add Column##ac\(entity.handle)") {
                        addColumn(to: entity.handle, engine: engine)
                    }

                    // Render a simple grid of cells
                    if igBeginTable("grid##\(entity.handle)", Int32(data.columns.count + 1),
                                    Int32(ImGuiTableFlags_Borders.rawValue |
                                          ImGuiTableFlags_ScrollX.rawValue |
                                          ImGuiTableFlags_ScrollY.rawValue),
                                    ImVec2(x: 0, y: ImGuiGetFontSize() * 20),
                                    ImGuiGetFontSize() * 15) {

                        // Header row
                        igTableSetupColumn("Row", Int32(ImGuiTableColumnFlags_WidthFixed.rawValue), ImGuiGetFontSize() * 4, 0)
                        for col in data.columns {
                            igTableSetupColumn(col.name, Int32(ImGuiTableColumnFlags_WidthFixed.rawValue), ImGuiGetFontSize() * 8, 0)
                        }
                        igTableHeadersRow()

                        // Data rows
                        for (rowIdx, row) in data.rows.enumerated() {
                            igTableNextRow(Int32(ImGuiTableRowFlags_None.rawValue), 0)
                            igTableSetColumnIndex(0)
                            ImGuiTextV("\(rowIdx + 1)")

                            for (colIdx, col) in data.columns.enumerated() {
                                igTableSetColumnIndex(Int32(colIdx + 1))
                                let cellValue = cellDisplayText(row: row, columnID: col.id)
                                let cellLabel = "##c\(entity.handle)r\(rowIdx)c\(colIdx)"

                                if editingTableHandle == entity.handle &&
                                    editingCellRow == rowIdx && editingCellCol == colIdx {
                                    // Active cell editing
                                    igPushItemWidth(ImGuiGetFontSize() * 10)
                                    if igInputText(cellLabel, &cellEditBuffer, 256,
                                                   Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue), nil, nil) {
                                        commitCellEdit(entity: entity, row: rowIdx, column: col, engine: engine)
                                        editingCellRow = -1
                                        editingCellCol = -1
                                    }
                                    igPopItemWidth()
                                } else {
                                    ImGuiTextV(cellValue)
                                    if igIsItemClicked(0) {
                                        editingTableHandle = entity.handle
                                        editingCellRow = rowIdx
                                        editingCellCol = colIdx
                                        cellEditBuffer = cellValue
                                    }
                                }
                            }
                        }

                        igEndTable()
                    }

                    igTreePop()
                }
            }
        }
    }

    // MARK: - Helpers

    private static func cellDisplayText(row: DataTableRow, columnID: UUID) -> String {
        for cell in row.cells where cell.columnID == columnID {
            if cell.coveredByMerge { return "" }
            // Prefer cached display text for FIELD cells
            if let display = cell.cachedDisplayText, !display.isEmpty {
                return display
            }
            switch cell.value {
            case .string(let s): return s
            case .number(let d): return String(format: "%g", d)
            case .integer(let i): return String(i)
            case .boolean(let b): return b ? "true" : "false"
            case .empty: return ""
            }
        }
        return ""
    }

    private static func createNewTable(engine: PhrostEngine) {
        let data = DataTableData(
            columns: [
                DataTableColumn(name: "A"),
                DataTableColumn(name: "B"),
                DataTableColumn(name: "C"),
            ],
            rows: [
                DataTableRow(cells: [
                    DataTableCell(columnID: UUID(), value: .string("")),
                    DataTableCell(columnID: UUID(), value: .string("")),
                    DataTableCell(columnID: UUID(), value: .string("")),
                ]),
                DataTableRow(cells: [
                    DataTableCell(columnID: UUID(), value: .string("")),
                    DataTableCell(columnID: UUID(), value: .string("")),
                    DataTableCell(columnID: UUID(), value: .string("")),
                ]),
                DataTableRow(cells: [
                    DataTableCell(columnID: UUID(), value: .string("")),
                    DataTableCell(columnID: UUID(), value: .string("")),
                    DataTableCell(columnID: UUID(), value: .string("")),
                ]),
            ],
            title: "New Table",
            rowHeights: [],
            defaultRowHeight: 2.0,
            defaultColumnWidth: 5.0,
            headerRowCount: 1,
            cellMargin: 0.25,
            textHeight: 1.5,
            cellAlignment: .left
        )

        // Fix column IDs in rows to match actual column IDs
        var fixedData = data
        for rowIdx in 0..<fixedData.rows.count {
            for cellIdx in 0..<fixedData.rows[rowIdx].cells.count {
                if cellIdx < fixedData.columns.count {
                    fixedData.rows[rowIdx].cells[cellIdx].columnID = fixedData.columns[cellIdx].id
                }
            }
        }

        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            blockID: nil,
            localGeometry: [.table(data: fixedData, origin: .zero, color: nil)],
            transform: .identity,
            xdata: [:]
        )
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
    }

    private static func addRow(to handle: UUID, engine: PhrostEngine) {
        guard var entity = engine.document.entity(for: handle),
              let geom = entity.localGeometry else { return }
        for (i, prim) in geom.enumerated() {
            if case .table(var data, let origin, let color) = prim {
                var cells: [DataTableCell] = []
                for col in data.columns {
                    cells.append(DataTableCell(columnID: col.id, value: .empty))
                }
                data.rows.append(DataTableRow(cells: cells))
                entity.localGeometry = nil
                var newGeom = geom
                newGeom[i] = .table(data: data, origin: origin, color: color)
                entity.localGeometry = newGeom
                engine.document.updateEntity(entity)
                engine.tabManager.markActiveDirty()
                return
            }
        }
    }

    private static func deleteLastRow(from handle: UUID, engine: PhrostEngine) {
        guard var entity = engine.document.entity(for: handle),
              let geom = entity.localGeometry else { return }
        for (i, prim) in geom.enumerated() {
            if case .table(var data, let origin, let color) = prim, !data.rows.isEmpty {
                data.rows.removeLast()
                var newGeom = geom
                newGeom[i] = .table(data: data, origin: origin, color: color)
                entity.localGeometry = newGeom
                engine.document.updateEntity(entity)
                engine.tabManager.markActiveDirty()
                return
            }
        }
    }

    private static func addColumn(to handle: UUID, engine: PhrostEngine) {
        guard var entity = engine.document.entity(for: handle),
              let geom = entity.localGeometry else { return }
        for (i, prim) in geom.enumerated() {
            if case .table(var data, let origin, let color) = prim {
                let newCol = DataTableColumn(name: "Col \(data.columns.count + 1)")
                data.columns.append(newCol)
                for rowIdx in 0..<data.rows.count {
                    data.rows[rowIdx].cells.append(DataTableCell(columnID: newCol.id, value: .empty))
                }
                var newGeom = geom
                newGeom[i] = .table(data: data, origin: origin, color: color)
                entity.localGeometry = newGeom
                engine.document.updateEntity(entity)
                engine.tabManager.markActiveDirty()
                return
            }
        }
    }

    private static func commitCellEdit(entity: CADEntity, row: Int, column: DataTableColumn, engine: PhrostEngine) {
        var updatedEntity = entity
        guard let geom = entity.localGeometry else { return }
        for (i, prim) in geom.enumerated() {
            if case .table(var data, let origin, let color) = prim,
               row < data.rows.count {
                for cellIdx in 0..<data.rows[row].cells.count {
                    if data.rows[row].cells[cellIdx].columnID == column.id {
                        data.rows[row].cells[cellIdx].value = .string(cellEditBuffer)
                        var newGeom = geom
                        newGeom[i] = .table(data: data, origin: origin, color: color)
                        updatedEntity.localGeometry = newGeom
                        engine.document.updateEntity(updatedEntity)
                        engine.tabManager.markActiveDirty()
                        return
                    }
                }
                // Column not in row yet — add it
                data.rows[row].cells.append(DataTableCell(columnID: column.id, value: .string(cellEditBuffer)))
                var newGeom = geom
                newGeom[i] = .table(data: data, origin: origin, color: color)
                updatedEntity.localGeometry = newGeom
                engine.document.updateEntity(updatedEntity)
                engine.tabManager.markActiveDirty()
                return
            }
        }
    }
}

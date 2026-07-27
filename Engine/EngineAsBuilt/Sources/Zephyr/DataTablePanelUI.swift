import ZephyrCore
import Foundation
import ImGui

@MainActor
struct DataTablePanelUI {
    static var _isDocked: Bool = false
    private static var metadataTableHandle: UUID?
    private static var titleEditBuffer = ""
    private static var editingColumnIndex: Int?
    private static var columnNameBuffer = ""
    private static var metadataEditNeedsFocus = false

    static func render(engine: PhrostEngine) {
        ImGuiSetNextWindowSize(
            ImVec2(x: ImGuiGetFontSize() * 42, y: ImGuiGetFontSize() * 38),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let isDocked = _isDocked
        var flags = Int32(0)
        if isDocked { flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue) }

        var opened = true
        ImGuiPushStyleColor(
            Int32(ImGuiCol_WindowBg.rawValue),
            isDocked ? engine.ui.theme.panelBg : engine.ui.theme.panelBgDim)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), isDocked ? 0.0 : 1.0)
        let entered: Bool
        if isDocked {
            entered = igBegin("Data Tables##DataTablePanel", nil, flags)
        } else {
            entered = igBegin("Data Tables##DataTablePanel", &opened, flags)
        }
        _isDocked = ImGuiIsWindowDocked()
        AppLayout.reportCurrentDockedPanel(engine: engine)

        guard entered else {
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
            return
        }
        defer {
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
        }

        if !isDocked && !opened {
            engine.ui.dataTablePanelVisible = false
            return
        }

        renderHeader(engine: engine)
        igSeparator()

        guard let selection = selectedTable(engine: engine) else {
            renderTableList(engine: engine)
            return
        }

        renderSelectedTable(
            handle: selection.handle,
            entity: selection.entity,
            data: selection.data,
            engine: engine)
    }

    private static func renderHeader(engine: PhrostEngine) {
        if let bold = engine.ui.boldFont { ImGuiPushFont(bold, 0) }
        ImGuiTextV("Data Tables")
        if engine.ui.boldFont != nil { ImGuiPopFont() }
        ImGuiSameLine(0, 10)
        if igButton("New Table", ImVec2(x: 0, y: 0)) {
            engine.commandProcessor.executeCommand("TABLE")
        }
        if engine.interaction.selectedTableHandle != nil {
            ImGuiSameLine(0, 6)
            if igButton("Show All", ImVec2(x: 0, y: 0)) {
                if engine.interaction.tableCellEditorActive {
                    DataTableEditor.commitCellEditing(engine: engine)
                }
                engine.cadSelection.clearSelection()
                engine.interaction.clearDataTableEditingState()
            }
        }
    }

    private static func renderTableList(engine: PhrostEngine) {
        let tables = engine.document.allEntities.compactMap { entity -> (CADEntity, DataTableData)? in
            guard let payload = DataTableEditor.payload(in: entity) else { return nil }
            return (entity, payload.data)
        }

        guard !tables.isEmpty else {
            ImGuiTextV("No tables in this document.")
            ImGuiTextV("Choose New Table to create one.")
            return
        }

        ImGuiTextV("Select a table to edit:")
        ImGuiDummy(ImVec2(x: 0, y: 4))
        for (entity, data) in tables {
            let title = data.title?.isEmpty == false
                ? data.title!
                : "Table"
            let label = "\(title)   \(data.rows.count) rows × \(data.columns.count) columns##\(entity.handle)"
            if ImGuiSelectable(label, false, 0, ImVec2(x: 0, y: 0)) {
                engine.cadSelection.select(entity.handle)
                engine.interaction.selectTable(handle: entity.handle)
            }
            if igBeginPopupContextItem("##tableListContext\(entity.handle)", Int32(ImGuiPopupFlags_MouseButtonRight.rawValue)) {
                if igMenuItem_Bool("Delete Table", nil, false, true) {
                    engine.document.removeEntity(handle: entity.handle)
                    engine.tabManager.markActiveDirty()
                }
                ImGuiEndPopup()
            }
        }
    }

    private static func renderSelectedTable(
        handle: UUID,
        entity: CADEntity,
        data: DataTableData,
        engine: PhrostEngine
    ) {
        if metadataTableHandle != handle {
            metadataTableHandle = handle
            titleEditBuffer = data.title ?? ""
            editingColumnIndex = nil
            columnNameBuffer = ""
            metadataEditNeedsFocus = false
        }

        ImGuiTextV("Title")
        ImGuiSameLine(0, 8)
        ImGuiPushItemWidth(max(160, ImGuiGetContentRegionAvail().x - 150))
        let titleSubmitted = inputText(
            id: "##DataTableTitle",
            value: &titleEditBuffer,
            enterReturnsTrue: true)
        let titleDeactivated = ImGuiIsItemDeactivatedAfterEdit()
        ImGuiPopItemWidth()
        if titleSubmitted || titleDeactivated {
            DataTableEditor.setTitle(handle: handle, title: titleEditBuffer, engine: engine)
        }
        ImGuiSameLine(0, 10)
        ImGuiTextV("\(data.rows.count) × \(data.columns.count)")

        let range = engine.interaction.tableSelectionRange
        if igSmallButton("Add Row") {
            let index = min(data.rows.count, (range?.maxRow ?? data.rows.count - 1) + 1)
            DataTableEditor.insertRow(handle: handle, at: index, engine: engine)
            selectNearest(handle: handle, row: index, column: range?.minColumn ?? 0, engine: engine)
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Add Column") {
            let index = min(data.columns.count, (range?.maxColumn ?? data.columns.count - 1) + 1)
            DataTableEditor.insertColumn(handle: handle, at: index, engine: engine)
            selectNearest(handle: handle, row: range?.minRow ?? 0, column: index, engine: engine)
        }
        ImGuiSameLine(0, 4)
        ImGuiBeginDisabled(range == nil)
        if igSmallButton("Merge") {
            if let range { DataTableEditor.mergeCells(handle: handle, range: range, engine: engine) }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Split") {
            if let address = range?.focus {
                DataTableEditor.splitCell(handle: handle, address: address, engine: engine)
            }
        }
        ImGuiEndDisabled()
        ImGuiSameLine(0, 4)
        if igSmallButton("Delete Table") {
            if engine.interaction.tableCellEditorActive {
                DataTableEditor.cancelCellEditing(engine: engine)
            }
            engine.document.removeEntity(handle: handle)
            engine.tabManager.markActiveDirty()
            engine.cadSelection.clearSelection()
            engine.interaction.clearDataTableEditingState()
            return
        }

        ImGuiDummy(ImVec2(x: 0, y: 4))
        ImGuiBeginDisabled(range == nil)
        if igSmallButton("Delete Row") {
            if let range, data.rows.count > 1 {
                DataTableEditor.deleteRows(handle: handle, range: range.minRow...range.maxRow, engine: engine)
                selectNearest(handle: handle, row: range.minRow, column: range.minColumn, engine: engine)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Delete Column") {
            if let range, data.columns.count > 1 {
                DataTableEditor.deleteColumns(handle: handle, range: range.minColumn...range.maxColumn, engine: engine)
                selectNearest(handle: handle, row: range.minRow, column: range.minColumn, engine: engine)
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Clear Cells"), let range {
            DataTableEditor.clearCells(handle: handle, range: range, engine: engine)
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Equal Rows"), let range {
            DataTableEditor.sizeRowsEqually(handle: handle, range: range.minRow...range.maxRow, engine: engine)
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Equal Columns"), let range {
            DataTableEditor.sizeColumnsEqually(handle: handle, range: range.minColumn...range.maxColumn, engine: engine)
        }
        ImGuiEndDisabled()

        ImGuiDummy(ImVec2(x: 0, y: 6))
        renderGrid(handle: handle, data: data, engine: engine)
    }

    private static func renderGrid(
        handle: UUID,
        data: DataTableData,
        engine: PhrostEngine
    ) {
        guard !data.columns.isEmpty else {
            ImGuiTextV("This table has no columns.")
            return
        }

        let flags = Int32(ImGuiTableFlags_Borders.rawValue)
            | Int32(ImGuiTableFlags_ScrollX.rawValue)
            | Int32(ImGuiTableFlags_ScrollY.rawValue)
            | Int32(ImGuiTableFlags_RowBg.rawValue)
        let height = max(180, ImGuiGetContentRegionAvail().y - 8)

        guard igBeginTable(
            "DataTableGrid##\(handle)",
            Int32(data.columns.count + 1),
            flags,
            ImVec2(x: 0, y: height),
            ImGuiGetFontSize() * 12) else { return }
        defer { igEndTable() }

        igTableSetupColumn("#", Int32(ImGuiTableColumnFlags_WidthFixed.rawValue), ImGuiGetFontSize() * 3.5, 0)
        for (column, value) in data.columns.enumerated() {
            igTableSetupColumn(
                "\(value.name)##header\(column)",
                Int32(ImGuiTableColumnFlags_WidthFixed.rawValue),
                ImGuiGetFontSize() * 10,
                UInt32(column + 1))
        }

        igTableNextRow(Int32(ImGuiTableRowFlags_Headers.rawValue), 0)
        igTableSetColumnIndex(0)
        ImGuiTextV("")
        for column in data.columns.indices {
            igTableSetColumnIndex(Int32(column + 1))
            if editingColumnIndex == column {
                if metadataEditNeedsFocus {
                    igSetKeyboardFocusHere(0)
                    metadataEditNeedsFocus = false
                }
                ImGuiPushItemWidth(-1)
                let submitted = inputText(
                    id: "##columnName\(column)",
                    value: &columnNameBuffer,
                    enterReturnsTrue: true)
                let deactivated = ImGuiIsItemDeactivatedAfterEdit()
                let escape = ImGuiIsKeyPressed(ImGuiKey_Escape, false)
                ImGuiPopItemWidth()
                if escape {
                    editingColumnIndex = nil
                    columnNameBuffer = ""
                } else if submitted || deactivated {
                    DataTableEditor.setColumnName(
                        handle: handle,
                        column: column,
                        name: columnNameBuffer,
                        engine: engine)
                    editingColumnIndex = nil
                    columnNameBuffer = ""
                }
            } else {
                let selected = isColumnSelected(column, range: engine.interaction.tableSelectionRange, rowCount: data.rows.count)
                if ImGuiSelectable(
                    "\(data.columns[column].name)##columnHeader\(column)",
                    selected,
                    0,
                    ImVec2(x: 0, y: 0)) {
                    guard !data.rows.isEmpty else { continue }
                    engine.interaction.selectedTableHandle = handle
                    engine.interaction.tableEditingMode = .cell
                    engine.interaction.tableSelectionRange = DataTableCellRange(
                        anchor: DataTableCellAddress(row: 0, column: column),
                        focus: DataTableCellAddress(row: data.rows.count - 1, column: column))
                }
                if ImGuiIsItemHovered(0) && ImGuiIsMouseDoubleClicked(0) {
                    editingColumnIndex = column
                    columnNameBuffer = data.columns[column].name
                    metadataEditNeedsFocus = true
                }
            }
        }

        for row in data.rows.indices {
            igTableNextRow(Int32(ImGuiTableRowFlags_None.rawValue), 0)
            igTableSetColumnIndex(0)
            let rowSelected = isRowSelected(row, range: engine.interaction.tableSelectionRange, columnCount: data.columns.count)
            if ImGuiSelectable("\(row + 1)##rowHeader\(row)", rowSelected, 0, ImVec2(x: 0, y: 0)) {
                engine.interaction.selectedTableHandle = handle
                engine.interaction.tableEditingMode = .cell
                engine.interaction.tableSelectionRange = DataTableCellRange(
                    anchor: DataTableCellAddress(row: row, column: 0),
                    focus: DataTableCellAddress(row: row, column: data.columns.count - 1))
            }

            for column in data.columns.indices {
                igTableSetColumnIndex(Int32(column + 1))
                let address = DataTableCellAddress(row: row, column: column)
                let selected = contains(address: address, range: engine.interaction.tableSelectionRange)
                let editing = engine.interaction.tableCellEditorActive
                    && engine.interaction.selectedTableHandle == handle
                    && engine.interaction.tableSelectionRange?.focus == address

                if editing {
                    if engine.interaction.tableCellEditNeedsFocus {
                        igSetKeyboardFocusHere(0)
                        engine.interaction.tableCellEditNeedsFocus = false
                    }
                    ImGuiPushItemWidth(-1)
                    let submitted = igInputText(
                        "##panelCell\(row)_\(column)",
                        &engine.interaction.tableCellEditBuffer,
                        4096,
                        Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue),
                        nil,
                        nil)
                    ImGuiPopItemWidth()
                    let tabPressed = ImGuiIsKeyPressed(ImGuiKey_Tab, false)
                    let escapePressed = ImGuiIsKeyPressed(ImGuiKey_Escape, false)
                    if escapePressed {
                        DataTableEditor.cancelCellEditing(engine: engine)
                    } else if submitted || tabPressed {
                        let forward = !(ImGuiGetIO()?.pointee.KeyShift ?? false)
                        DataTableEditor.commitCellEditing(engine: engine)
                        if let updated = DataTableEditor.payload(handle: handle, document: engine.document) {
                            let next = DataTableEditor.advanceAddress(
                                address,
                                data: updated.data,
                                forward: forward,
                                vertical: submitted)
                            DataTableEditor.beginCellEditing(handle: handle, address: next, engine: engine)
                        }
                    }
                } else {
                    let text = DataTableEditor.cellText(data: data, address: address)
                    let label = "\(text.isEmpty ? " " : text)##cell\(row)_\(column)"
                    if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                        let extending = ImGuiGetIO()?.pointee.KeyShift ?? false
                        engine.interaction.selectTableCell(
                            handle: handle,
                            address: address,
                            extending: extending)
                    }
                    if ImGuiIsItemHovered(0) && ImGuiIsMouseDoubleClicked(0) {
                        DataTableEditor.beginCellEditing(handle: handle, address: address, engine: engine)
                    }
                }
            }
        }
    }


    private static func inputText(
        id: String,
        value: inout String,
        enterReturnsTrue: Bool
    ) -> Bool {
        let bufferSize = 1024
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let bytes = value.utf8CString
        let copyCount = min(bytes.count, bufferSize - 1)
        buffer.withUnsafeMutableBufferPointer { pointer in
            _ = pointer.initialize(from: bytes.prefix(copyCount))
        }
        let flags = enterReturnsTrue
            ? Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue)
            : 0
        let submitted = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return igInputText(id, base, bufferSize, flags, nil, nil)
        }
        value = buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
        return submitted
    }

    private static func selectedTable(
        engine: PhrostEngine
    ) -> (handle: UUID, entity: CADEntity, data: DataTableData)? {
        let handle = engine.interaction.selectedTableHandle
            ?? (engine.cadSelection.selectedCount == 1 ? engine.cadSelection.lastSelectedHandle : nil)
        guard let handle,
              engine.cadSelection.selectedHandles.contains(handle),
              let entity = engine.document.entity(for: handle),
              let payload = DataTableEditor.payload(in: entity) else { return nil }
        if engine.interaction.selectedTableHandle != handle {
            engine.interaction.selectTable(handle: handle)
        }
        return (handle, entity, payload.data)
    }

    private static func selectNearest(
        handle: UUID,
        row: Int,
        column: Int,
        engine: PhrostEngine
    ) {
        guard let data = DataTableEditor.payload(handle: handle, document: engine.document)?.data,
              !data.rows.isEmpty,
              !data.columns.isEmpty else { return }
        engine.interaction.selectTableCell(
            handle: handle,
            address: DataTableCellAddress(
                row: max(0, min(row, data.rows.count - 1)),
                column: max(0, min(column, data.columns.count - 1))),
            extending: false)
    }

    private static func contains(
        address: DataTableCellAddress,
        range: DataTableCellRange?
    ) -> Bool {
        guard let range else { return false }
        return address.row >= range.minRow
            && address.row <= range.maxRow
            && address.column >= range.minColumn
            && address.column <= range.maxColumn
    }

    private static func isRowSelected(
        _ row: Int,
        range: DataTableCellRange?,
        columnCount: Int
    ) -> Bool {
        guard let range else { return false }
        return range.minRow == row
            && range.maxRow == row
            && range.minColumn == 0
            && range.maxColumn == max(0, columnCount - 1)
    }

    private static func isColumnSelected(
        _ column: Int,
        range: DataTableCellRange?,
        rowCount: Int
    ) -> Bool {
        guard let range else { return false }
        return range.minColumn == column
            && range.maxColumn == column
            && range.minRow == 0
            && range.maxRow == max(0, rowCount - 1)
    }
}

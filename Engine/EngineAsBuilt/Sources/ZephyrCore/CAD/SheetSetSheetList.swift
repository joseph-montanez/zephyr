import Foundation

// =========================================================================
// MARK: - Sheet List Table builder (Step 6: Insert Sheet List Table)
// -------------------------------------------------------------------------
// Builds the `DataTableData` behind LT's "Insert Sheet List Table": one
// row per sheet in display order with Number + Title columns, titled with
// the set name. Snapshot semantics: the table does not live-update when
// the set changes (a refresh path arrives with the property editor).
// =========================================================================

public enum SheetSetSheetListTable {
    public static let numberColumnWidth = 20.0
    public static let titleColumnWidth = 80.0

    /// Table data for a set. All sheets list (publish flags do not apply
    /// to the list — LT lists set contents, not the publish scope).
    public static func data(for set: SheetSet) -> DataTableData {
        let numberColumn = DataTableColumn(
            name: "Number", width: numberColumnWidth, alignment: .left)
        let titleColumn = DataTableColumn(
            name: "Title", width: titleColumnWidth, alignment: .left)
        let rows = set.allSheetsInOrder.map { sheet in
            DataTableRow(cells: [
                DataTableCell(
                    columnID: numberColumn.id,
                    value: .string(sheet.number),
                    cachedDisplayText: sheet.number),
                DataTableCell(
                    columnID: titleColumn.id,
                    value: .string(sheet.title),
                    cachedDisplayText: sheet.title),
            ])
        }
        return DataTableData(
            columns: [numberColumn, titleColumn],
            rows: rows,
            title: set.name.isEmpty ? nil : set.name,
            rowHeights: Array(repeating: 2.0, count: rows.count),
            headerRowCount: 1)
    }
}

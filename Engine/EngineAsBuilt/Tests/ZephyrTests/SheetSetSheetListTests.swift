import XCTest
import Foundation
@testable import ZephyrCore

/// Step 6: sheet list table content (Number + Title, display order).
@MainActor
final class SheetSetSheetListTests: XCTestCase {

    func testBuildsNumberTitleRowsInDisplayOrder() {
        var set = SheetSet(name: "TI Set")
        set.sheets = [SheetSetSheet(number: "A100", title: "Cover")]
        set.subsets = [SheetSetSubset(name: "Arch", sheets: [
            SheetSetSheet(number: "A201", title: "Plan"),
        ])]
        let data = SheetSetSheetListTable.data(for: set)
        XCTAssertEqual(data.columns.map(\.name), ["Number", "Title"])
        XCTAssertEqual(data.title, "TI Set")
        XCTAssertEqual(data.rows.count, 2)
        XCTAssertEqual(
            DataTableEditor.cellText(data: data, address: DataTableCellAddress(row: 0, column: 0)),
            "A100")
        XCTAssertEqual(
            DataTableEditor.cellText(data: data, address: DataTableCellAddress(row: 0, column: 1)),
            "Cover")
        XCTAssertEqual(
            DataTableEditor.cellText(data: data, address: DataTableCellAddress(row: 1, column: 0)),
            "A201")
        XCTAssertEqual(
            DataTableEditor.cellText(data: data, address: DataTableCellAddress(row: 1, column: 1)),
            "Plan")
    }

    func testEmptySetBuildsHeaderOnlyTable() {
        let data = SheetSetSheetListTable.data(for: SheetSet(name: "Empty"))
        XCTAssertEqual(data.columns.count, 2)
        XCTAssertEqual(data.rows.count, 0)
        XCTAssertEqual(data.title, "Empty")
    }
}

import Foundation

// =========================================================================
// MARK: - DataTableCellValue
// =========================================================================

public enum DataTableCellValue: Hashable, Sendable, Codable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case empty
}

// =========================================================================
// MARK: - DataTableCellAlignment
// =========================================================================

public enum DataTableCellAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    case left
    case center
    case right
}

public enum DataTableCellVerticalAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    case top
    case middle
    case bottom
}

// =========================================================================
// MARK: - DataTableColumn
// =========================================================================

public struct DataTableColumn: Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var width: Double              // world units; 0 = use defaultColumnWidth
    public var alignment: DataTableCellAlignment

    public init(id: UUID = UUID(),
                name: String,
                width: Double = 0,
                alignment: DataTableCellAlignment = .left) {
        self.id = id
        self.name = name
        self.width = width
        self.alignment = alignment
    }
}

// =========================================================================
// MARK: - DataTableCell
// =========================================================================

public struct DataTableCell: Hashable, Sendable, Codable {
    public var columnID: UUID
    public var value: DataTableCellValue
    public var formulaExpression: String?
    public var cachedDisplayText: String?
    public var rowSpan: Int
    public var colSpan: Int
    public var coveredByMerge: Bool
    public var horizontalAlignment: DataTableCellAlignment?
    public var verticalAlignment: DataTableCellVerticalAlignment?
    public var nativeDXFGroups: [DataTableRawDXFGroup]?

    public init(columnID: UUID,
                value: DataTableCellValue = .empty,
                formulaExpression: String? = nil,
                cachedDisplayText: String? = nil,
                rowSpan: Int = 1,
                colSpan: Int = 1,
                coveredByMerge: Bool = false,
                horizontalAlignment: DataTableCellAlignment? = nil,
                verticalAlignment: DataTableCellVerticalAlignment? = nil,
                nativeDXFGroups: [DataTableRawDXFGroup]? = nil) {
        self.columnID = columnID
        self.value = value
        self.formulaExpression = formulaExpression
        self.cachedDisplayText = cachedDisplayText
        self.rowSpan = rowSpan
        self.colSpan = colSpan
        self.coveredByMerge = coveredByMerge
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.nativeDXFGroups = nativeDXFGroups
    }
}

// =========================================================================
// MARK: - DataTableRow
// =========================================================================

public struct DataTableRow: Hashable, Sendable, Codable {
    public let id: UUID
    public var cells: [DataTableCell]

    public init(id: UUID = UUID(), cells: [DataTableCell] = []) {
        self.id = id
        self.cells = cells
    }
}

// =========================================================================
// MARK: - DataTableNativeDXFPayload
// =========================================================================

public struct DataTableRawDXFGroup: Hashable, Sendable, Codable {
    public var code: Int
    public var value: String

    public init(code: Int, value: String) {
        self.code = code
        self.value = value
    }
}

public struct DXFRawRecord: Hashable, Sendable, Codable {
    public var type: String
    public var groups: [DataTableRawDXFGroup]

    public init(type: String, groups: [DataTableRawDXFGroup]) {
        self.type = type
        self.groups = groups
    }
}

public struct DXFPreservedEntity: Hashable, Sendable, Codable {
    public var record: DXFRawRecord
    public var ownerBlockName: String

    public init(record: DXFRawRecord, ownerBlockName: String = "*Model_Space") {
        self.record = record
        self.ownerBlockName = ownerBlockName
    }
}

public struct DXFRoundTripPayload: Hashable, Sendable, Codable {
    public var classes: [DXFRawRecord]
    /// Raw TABLE headers and table-entry records, excluding ENDTAB wrappers.
    public var tables: [DXFRawRecord]
    public var objects: [DXFRawRecord]
    /// Native entities that must survive even when a view/model conversion drops them.
    /// Currently used for ACAD_TABLE records whose binary 310 payload cannot be rebuilt.
    public var nativeEntities: [DXFPreservedEntity]
    /// Raw contents of the ACDSDATA section, excluding SECTION/ENDSEC wrappers.
    public var acdsData: [DataTableRawDXFGroup]

    public init(
        classes: [DXFRawRecord] = [],
        tables: [DXFRawRecord] = [],
        objects: [DXFRawRecord] = [],
        nativeEntities: [DXFPreservedEntity] = [],
        acdsData: [DataTableRawDXFGroup] = []
    ) {
        self.classes = classes
        self.tables = tables
        self.objects = objects
        self.nativeEntities = nativeEntities
        self.acdsData = acdsData
    }

    private enum CodingKeys: String, CodingKey {
        case classes, tables, objects, nativeEntities, acdsData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        classes = try container.decodeIfPresent([DXFRawRecord].self, forKey: .classes) ?? []
        tables = try container.decodeIfPresent([DXFRawRecord].self, forKey: .tables) ?? []
        objects = try container.decodeIfPresent([DXFRawRecord].self, forKey: .objects) ?? []
        nativeEntities = try container.decodeIfPresent(
            [DXFPreservedEntity].self,
            forKey: .nativeEntities) ?? []
        acdsData = try container.decodeIfPresent(
            [DataTableRawDXFGroup].self,
            forKey: .acdsData) ?? []
    }
}

public struct DataTableNativeDXFPayload: Hashable, Sendable, Codable {
    public var rawGroups: [DataTableRawDXFGroup]
    public var blockName: String?
    public var tableStyleHandle: String?
    public var blockRecordHandle: String?
    public var requiredClasses: [DXFRawRecord]?
    public var referencedObjects: [DXFRawRecord]?
    public var isModified: Bool

    public init(rawGroups: [DataTableRawDXFGroup] = [],
                blockName: String? = nil,
                tableStyleHandle: String? = nil,
                blockRecordHandle: String? = nil,
                requiredClasses: [DXFRawRecord]? = nil,
                referencedObjects: [DXFRawRecord]? = nil,
                isModified: Bool = false) {
        self.rawGroups = rawGroups
        self.blockName = blockName
        self.tableStyleHandle = tableStyleHandle
        self.blockRecordHandle = blockRecordHandle
        self.requiredClasses = requiredClasses
        self.referencedObjects = referencedObjects
        self.isModified = isModified
    }
}

// =========================================================================
// MARK: - DataTableData
// =========================================================================

public struct DataTableData: Hashable, Sendable, Codable {
    public var version: Int
    public var columns: [DataTableColumn]
    public var rows: [DataTableRow]
    public var title: String?

    // Layout
    public var rowHeights: [Double]
    public var defaultRowHeight: Double
    public var defaultColumnWidth: Double
    public var headerRowCount: Int
    public var cellMargin: Double
    public var horizontalTextMargin: Double?
    public var verticalTextMargin: Double?

    // Text styling
    public var textHeight: Double
    public var textStyleName: String?
    public var textColor: ColorRGBA?

    // Grid styling
    public var gridColor: ColorRGBA?
    public var gridLineWeight: Double?
    public var headerFillColor: ColorRGBA?
    public var backgroundFillColor: ColorRGBA?
    public var cellAlignment: DataTableCellAlignment

    // Native DXF payload (for raw passthrough on export)
    public var nativeDXFPayload: DataTableNativeDXFPayload?

    // MARK: - Init

    public init(
        version: Int = 1,
        columns: [DataTableColumn] = [],
        rows: [DataTableRow] = [],
        title: String? = nil,
        rowHeights: [Double] = [],
        defaultRowHeight: Double = 2.0,
        defaultColumnWidth: Double = 5.0,
        headerRowCount: Int = 1,
        cellMargin: Double = 0.25,
        horizontalTextMargin: Double? = nil,
        verticalTextMargin: Double? = nil,
        textHeight: Double = 1.5,
        textStyleName: String? = nil,
        textColor: ColorRGBA? = nil,
        gridColor: ColorRGBA? = nil,
        gridLineWeight: Double? = nil,
        headerFillColor: ColorRGBA? = nil,
        backgroundFillColor: ColorRGBA? = nil,
        cellAlignment: DataTableCellAlignment = .left,
        nativeDXFPayload: DataTableNativeDXFPayload? = nil
    ) {
        self.version = version
        self.columns = columns
        self.rows = rows
        self.title = title
        self.rowHeights = rowHeights
        self.defaultRowHeight = defaultRowHeight
        self.defaultColumnWidth = defaultColumnWidth
        self.headerRowCount = headerRowCount
        self.cellMargin = cellMargin
        self.horizontalTextMargin = horizontalTextMargin
        self.verticalTextMargin = verticalTextMargin
        self.textHeight = textHeight
        self.textStyleName = textStyleName
        self.textColor = textColor
        self.gridColor = gridColor
        self.gridLineWeight = gridLineWeight
        self.headerFillColor = headerFillColor
        self.backgroundFillColor = backgroundFillColor
        self.cellAlignment = cellAlignment
        self.nativeDXFPayload = nativeDXFPayload
    }

    // MARK: - Backward-compatible decoding

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        self.columns = try container.decodeIfPresent([DataTableColumn].self, forKey: .columns) ?? []
        self.rows = try container.decodeIfPresent([DataTableRow].self, forKey: .rows) ?? []
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.rowHeights = try container.decodeIfPresent([Double].self, forKey: .rowHeights) ?? []
        self.defaultRowHeight = try container.decodeIfPresent(Double.self, forKey: .defaultRowHeight) ?? 2.0
        self.defaultColumnWidth = try container.decodeIfPresent(Double.self, forKey: .defaultColumnWidth) ?? 5.0
        self.headerRowCount = try container.decodeIfPresent(Int.self, forKey: .headerRowCount) ?? 1
        self.cellMargin = try container.decodeIfPresent(Double.self, forKey: .cellMargin) ?? 0.25
        self.horizontalTextMargin = try container.decodeIfPresent(Double.self, forKey: .horizontalTextMargin)
        self.verticalTextMargin = try container.decodeIfPresent(Double.self, forKey: .verticalTextMargin)
        self.textHeight = try container.decodeIfPresent(Double.self, forKey: .textHeight) ?? 1.5
        self.textStyleName = try container.decodeIfPresent(String.self, forKey: .textStyleName)
        self.textColor = try container.decodeIfPresent(ColorRGBA.self, forKey: .textColor)
        self.gridColor = try container.decodeIfPresent(ColorRGBA.self, forKey: .gridColor)
        self.gridLineWeight = try container.decodeIfPresent(Double.self, forKey: .gridLineWeight)
        self.headerFillColor = try container.decodeIfPresent(ColorRGBA.self, forKey: .headerFillColor)
        self.backgroundFillColor = try container.decodeIfPresent(ColorRGBA.self, forKey: .backgroundFillColor)
        self.cellAlignment = try container.decodeIfPresent(DataTableCellAlignment.self, forKey: .cellAlignment) ?? .left
        self.nativeDXFPayload = try container.decodeIfPresent(DataTableNativeDXFPayload.self, forKey: .nativeDXFPayload)
    }
}
// =========================================================================
// MARK: - Data Table Editing State
// =========================================================================

public struct DataTableCellAddress: Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

public struct DataTableCellRange: Hashable, Sendable {
    public var anchor: DataTableCellAddress
    public var focus: DataTableCellAddress

    public init(anchor: DataTableCellAddress, focus: DataTableCellAddress) {
        self.anchor = anchor
        self.focus = focus
    }

    public init(_ address: DataTableCellAddress) {
        self.anchor = address
        self.focus = address
    }

    public var minRow: Int { min(anchor.row, focus.row) }
    public var maxRow: Int { max(anchor.row, focus.row) }
    public var minColumn: Int { min(anchor.column, focus.column) }
    public var maxColumn: Int { max(anchor.column, focus.column) }
    public var rowCount: Int { maxRow - minRow + 1 }
    public var columnCount: Int { maxColumn - minColumn + 1 }
    public var isSingleCell: Bool { anchor == focus }
}

public enum DataTableEditingMode: Hashable, Sendable {
    case table
    case cell
}

public enum DataTableStylePreset: String, CaseIterable, Hashable, Sendable {
    case standard = "Standard"
    case light = "Light"
    case minimal = "Minimal"
    case alternating = "Alternating"
}

public struct DataTableInsertConfiguration: Hashable, Sendable {
    public var columnCount: Int
    public var dataRowCount: Int
    public var includeTitle: Bool
    public var headerRowCount: Int
    public var title: String
    public var defaultColumnWidth: Double
    public var defaultRowHeight: Double
    public var textHeight: Double
    public var stylePreset: DataTableStylePreset

    public init(
        columnCount: Int = 3,
        dataRowCount: Int = 3,
        includeTitle: Bool = true,
        headerRowCount: Int = 1,
        title: String = "Table",
        defaultColumnWidth: Double = 5.0,
        defaultRowHeight: Double = 2.0,
        textHeight: Double = 1.5,
        stylePreset: DataTableStylePreset = .standard
    ) {
        self.columnCount = columnCount
        self.dataRowCount = dataRowCount
        self.includeTitle = includeTitle
        self.headerRowCount = headerRowCount
        self.title = title
        self.defaultColumnWidth = defaultColumnWidth
        self.defaultRowHeight = defaultRowHeight
        self.textHeight = textHeight
        self.stylePreset = stylePreset
    }
}

import Foundation

public struct DataTableCellRect: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Vector3 {
        Vector3(x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5, z: 0)
    }

    public func union(_ other: DataTableCellRect) -> DataTableCellRect {
        DataTableCellRect(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY))
    }
}

public struct DataTableLayout: Hashable, Sendable {
    public var origin: Vector3
    public var totalWidth: Double
    public var totalHeight: Double
    public var titleHeight: Double
    public var columnEdges: [Double]
    public var rowEdges: [Double]

    public init(
        origin: Vector3,
        totalWidth: Double,
        totalHeight: Double,
        titleHeight: Double,
        columnEdges: [Double],
        rowEdges: [Double]
    ) {
        self.origin = origin
        self.totalWidth = totalWidth
        self.totalHeight = totalHeight
        self.titleHeight = titleHeight
        self.columnEdges = columnEdges
        self.rowEdges = rowEdges
    }

    public var dataTop: Double { origin.y + titleHeight }
    public var tableRect: DataTableCellRect {
        DataTableCellRect(
            minX: origin.x,
            minY: origin.y,
            maxX: origin.x + totalWidth,
            maxY: origin.y + totalHeight)
    }

    public var titleRect: DataTableCellRect? {
        guard titleHeight > 0 else { return nil }
        return DataTableCellRect(
            minX: origin.x,
            minY: origin.y,
            maxX: origin.x + totalWidth,
            maxY: origin.y + titleHeight)
    }
}

public struct DataTableCellHit: Hashable, Sendable {
    public var address: DataTableCellAddress
    public var rect: DataTableCellRect

    public init(address: DataTableCellAddress, rect: DataTableCellRect) {
        self.address = address
        self.rect = rect
    }
}

public enum DataTableBoundaryHit: Hashable, Sendable {
    case column(index: Int)
    case row(index: Int)
}


private struct DataTableGridLineKey: Hashable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var z: Double

    init(_ start: Vector3, _ end: Vector3) {
        if start.x < end.x || start.x == end.x && start.y <= end.y {
            x1 = start.x
            y1 = start.y
            x2 = end.x
            y2 = end.y
        } else {
            x1 = end.x
            y1 = end.y
            x2 = start.x
            y2 = start.y
        }
        z = start.z
    }
}

public enum DataTableTessellator {
    private static let _cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [Int: [CADPrimitive]] = [:]

    public static func invalidateCache() {
        _cacheLock.lock()
        cache.removeAll()
        _cacheLock.unlock()
    }

    public static func generateVisualPrimitives(
        data: DataTableData,
        origin: Vector3,
        transform: Transform3D = .identity
    ) -> [CADPrimitive] {
        var hasher = Hasher()
        data.hash(into: &hasher)
        origin.hash(into: &hasher)
        let contentHash = hasher.finalize()

        _cacheLock.lock()
        let cached = cache[contentHash]
        _cacheLock.unlock()

        let primitives: [CADPrimitive]
        if let cached {
            primitives = cached
        } else {
            primitives = buildPrimitives(data: data, origin: origin)
            _cacheLock.lock()
            cache[contentHash] = primitives
            _cacheLock.unlock()
        }

        if transform.isIdentity {
            return primitives
        }
        return primitives.map { transformPrimitive($0, by: transform) }
    }

    public static func explodeForDXF(
        data: DataTableData,
        origin: Vector3 = .zero,
        transform: Transform3D
    ) -> [CADPrimitive] {
        let visual = buildPrimitives(data: data, origin: origin)
        var result: [CADPrimitive] = []
        for primitive in visual {
            let transformed = transformPrimitive(primitive, by: transform)
            switch transformed {
            case .line, .text:
                result.append(transformed)
            case .fillRect(let origin, let size, let color):
                let p0 = origin
                let p1 = Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)
                let p2 = Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)
                let p3 = Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)
                result.append(.line(start: p0, end: p1, color: color))
                result.append(.line(start: p1, end: p2, color: color))
                result.append(.line(start: p2, end: p3, color: color))
                result.append(.line(start: p3, end: p0, color: color))
            default:
                break
            }
        }
        return result
    }

    public static func layout(data: DataTableData, origin: Vector3) -> DataTableLayout {
        let margin = max(0, data.cellMargin)
        let widths = data.columns.map { columnWidth($0, defaultWidth: data.defaultColumnWidth) }
        let rowCount = max(data.rows.count, data.headerRowCount)
        let heights = rowHeights(data: data, rowCount: rowCount)
        let titleHeight = data.title == nil ? 0 : max(data.defaultRowHeight, data.textHeight) + margin

        var columnEdges: [Double] = [origin.x]
        var x = origin.x
        for (index, width) in widths.enumerated() {
            x += margin + width
            if index == widths.count - 1 {
                x += margin
            }
            columnEdges.append(x)
        }

        var rowEdges: [Double] = [origin.y + titleHeight]
        var y = origin.y + titleHeight
        for (index, height) in heights.enumerated() {
            y += margin + height
            if index == heights.count - 1 {
                y += margin
            }
            rowEdges.append(y)
        }

        let totalWidth = max(0, x - origin.x)
        let totalHeight = max(0, y - origin.y)
        return DataTableLayout(
            origin: origin,
            totalWidth: totalWidth,
            totalHeight: totalHeight,
            titleHeight: titleHeight,
            columnEdges: columnEdges,
            rowEdges: rowEdges)
    }

    public static func computeSize(data: DataTableData) -> (width: Double, height: Double) {
        let value = layout(data: data, origin: .zero)
        return (value.totalWidth, value.totalHeight)
    }

    public static func cellRect(
        data: DataTableData,
        layout: DataTableLayout,
        row: Int,
        column: Int,
        expandMerged: Bool = true
    ) -> DataTableCellRect? {
        guard row >= 0, column >= 0,
              row + 1 < layout.rowEdges.count,
              column + 1 < layout.columnEdges.count else { return nil }

        let anchor = expandMerged
            ? mergeAnchor(data: data, row: row, column: column)
            : DataTableCellAddress(row: row, column: column)
        guard anchor.row >= 0, anchor.column >= 0,
              anchor.row + 1 < layout.rowEdges.count,
              anchor.column + 1 < layout.columnEdges.count else { return nil }

        var rowSpan = 1
        var colSpan = 1
        if expandMerged,
           anchor.row < data.rows.count,
           anchor.column < data.columns.count,
           let cell = cell(data: data, row: anchor.row, column: anchor.column) {
            rowSpan = max(1, cell.rowSpan)
            colSpan = max(1, cell.colSpan)
        }

        let endRow = min(layout.rowEdges.count - 1, anchor.row + rowSpan)
        let endColumn = min(layout.columnEdges.count - 1, anchor.column + colSpan)
        return DataTableCellRect(
            minX: layout.columnEdges[anchor.column],
            minY: layout.rowEdges[anchor.row],
            maxX: layout.columnEdges[endColumn],
            maxY: layout.rowEdges[endRow])
    }

    public static func rangeRect(
        data: DataTableData,
        layout: DataTableLayout,
        range: DataTableCellRange
    ) -> DataTableCellRect? {
        guard let first = cellRect(
            data: data,
            layout: layout,
            row: range.minRow,
            column: range.minColumn,
            expandMerged: false),
              let last = cellRect(
                data: data,
                layout: layout,
                row: range.maxRow,
                column: range.maxColumn,
                expandMerged: false) else { return nil }
        return first.union(last)
    }

    public static func hitTestCell(
        data: DataTableData,
        origin: Vector3,
        localPoint: Vector3
    ) -> DataTableCellHit? {
        let layout = layout(data: data, origin: origin)
        guard localPoint.x >= layout.origin.x,
              localPoint.x <= layout.origin.x + layout.totalWidth,
              localPoint.y >= layout.dataTop,
              localPoint.y <= layout.origin.y + layout.totalHeight else { return nil }

        guard let column = intervalIndex(value: localPoint.x, edges: layout.columnEdges),
              let row = intervalIndex(value: localPoint.y, edges: layout.rowEdges) else { return nil }
        let address = mergeAnchor(data: data, row: row, column: column)
        guard let rect = cellRect(
            data: data,
            layout: layout,
            row: address.row,
            column: address.column,
            expandMerged: true) else { return nil }
        return DataTableCellHit(address: address, rect: rect)
    }

    public static func boundaryHitTest(
        data: DataTableData,
        origin: Vector3,
        localPoint: Vector3,
        toleranceX: Double,
        toleranceY: Double
    ) -> DataTableBoundaryHit? {
        let layout = layout(data: data, origin: origin)
        let minX = layout.origin.x
        let maxX = layout.origin.x + layout.totalWidth
        let minY = layout.dataTop
        let maxY = layout.origin.y + layout.totalHeight
        guard localPoint.x >= minX - toleranceX,
              localPoint.x <= maxX + toleranceX,
              localPoint.y >= minY - toleranceY,
              localPoint.y <= maxY + toleranceY else { return nil }

        var bestDistance = Double.infinity
        var best: DataTableBoundaryHit?

        if layout.columnEdges.count > 1,
           localPoint.y >= minY,
           localPoint.y <= maxY {
            for edgeIndex in 1..<layout.columnEdges.count {
                let distance = abs(localPoint.x - layout.columnEdges[edgeIndex])
                if distance <= toleranceX && distance < bestDistance {
                    bestDistance = distance
                    best = .column(index: edgeIndex - 1)
                }
            }
        }

        if layout.rowEdges.count > 1,
           localPoint.x >= minX,
           localPoint.x <= maxX {
            for edgeIndex in 1..<layout.rowEdges.count {
                let distance = abs(localPoint.y - layout.rowEdges[edgeIndex])
                if distance <= toleranceY && distance < bestDistance {
                    bestDistance = distance
                    best = .row(index: edgeIndex - 1)
                }
            }
        }

        return best
    }

    public static func mergeAnchor(
        data: DataTableData,
        row: Int,
        column: Int
    ) -> DataTableCellAddress {
        guard row >= 0, column >= 0,
              row < data.rows.count,
              column < data.columns.count else {
            return DataTableCellAddress(row: row, column: column)
        }

        if let direct = cell(data: data, row: row, column: column), !direct.coveredByMerge {
            return DataTableCellAddress(row: row, column: column)
        }

        for anchorRow in 0...row {
            for anchorColumn in 0...column {
                guard let candidate = cell(data: data, row: anchorRow, column: anchorColumn),
                      !candidate.coveredByMerge,
                      candidate.rowSpan > 1 || candidate.colSpan > 1 else { continue }
                let maxRow = anchorRow + candidate.rowSpan - 1
                let maxColumn = anchorColumn + candidate.colSpan - 1
                if row >= anchorRow, row <= maxRow,
                   column >= anchorColumn, column <= maxColumn {
                    return DataTableCellAddress(row: anchorRow, column: anchorColumn)
                }
            }
        }
        return DataTableCellAddress(row: row, column: column)
    }

    private static func buildPrimitives(data: DataTableData, origin: Vector3) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        var gridLines: Set<DataTableGridLineKey> = []
        let layout = layout(data: data, origin: origin)
        let gridColor = data.gridColor
        let textColor = data.textColor
        let headerFill = data.headerFillColor
        let alternateFill = data.backgroundFillColor
        let margin = max(0, data.cellMargin)
        let horizontalTextMargin = max(0, data.horizontalTextMargin ?? margin)
        let verticalTextMargin = max(0, data.verticalTextMargin ?? margin)

        if let title = data.title, let titleRect = layout.titleRect {
            if let headerFill, headerFill.a > 0 {
                primitives.append(.fillRect(
                    origin: Vector3(x: titleRect.minX, y: titleRect.minY, z: origin.z),
                    size: Vector3(x: titleRect.width, y: titleRect.height, z: 0),
                    color: headerFill))
            }
            primitives.append(.text(
                position: Vector3(
                    x: titleRect.minX + horizontalTextMargin,
                    y: titleRect.minY + verticalTextMargin,
                    z: origin.z),
                text: title,
                height: data.textHeight,
                rotation: 0,
                style: data.textStyleName,
                alignH: 0,
                alignV: 0,
                mtextWidth: max(0, titleRect.width - horizontalTextMargin * 2),
                color: textColor))
            appendRectLines(
                titleRect,
                z: origin.z,
                color: gridColor,
                seen: &gridLines,
                into: &primitives)
        }

        let rowCount = max(data.rows.count, data.headerRowCount)
        guard rowCount > 0, !data.columns.isEmpty else { return primitives }

        for row in 0..<rowCount {
            for column in 0..<data.columns.count {
                if row < data.rows.count,
                   let cell = cell(data: data, row: row, column: column),
                   cell.coveredByMerge {
                    continue
                }
                guard let rect = cellRect(
                    data: data,
                    layout: layout,
                    row: row,
                    column: column,
                    expandMerged: true) else { continue }

                if row < data.headerRowCount {
                    if let headerFill, headerFill.a > 0 {
                        primitives.append(.fillRect(
                            origin: Vector3(x: rect.minX, y: rect.minY, z: origin.z),
                            size: Vector3(x: rect.width, y: rect.height, z: 0),
                            color: headerFill))
                    }
                } else if row % 2 == 0, let alternateFill, alternateFill.a > 0 {
                    primitives.append(.fillRect(
                        origin: Vector3(x: rect.minX, y: rect.minY, z: origin.z),
                        size: Vector3(x: rect.width, y: rect.height, z: 0),
                        color: alternateFill))
                }

                appendRectLines(
                    rect,
                    z: origin.z,
                    color: gridColor,
                    seen: &gridLines,
                    into: &primitives)

                guard row < data.rows.count,
                      let tableCell = cell(data: data, row: row, column: column) else { continue }
                let value = displayText(data: data, row: row, column: column)
                guard !value.isEmpty else { continue }

                let alignment = tableCell.horizontalAlignment ?? data.columns[column].alignment
                let x: Double
                let alignH: Int
                switch alignment {
                case .left:
                    x = rect.minX + horizontalTextMargin
                    alignH = 0
                case .center:
                    x = (rect.minX + rect.maxX) * 0.5
                    alignH = 1
                case .right:
                    x = rect.maxX - horizontalTextMargin
                    alignH = 2
                }

                let y: Double
                let alignV: Int
                switch tableCell.verticalAlignment {
                case .top:
                    y = rect.minY + verticalTextMargin
                    alignV = 3
                case .middle:
                    y = (rect.minY + rect.maxY) * 0.5
                    alignV = 2
                case .bottom:
                    y = rect.maxY - verticalTextMargin
                    alignV = 1
                case nil:
                    y = rect.minY + margin
                    alignV = 0
                }

                primitives.append(.text(
                    position: Vector3(x: x, y: y, z: origin.z),
                    text: value,
                    height: data.textHeight,
                    rotation: 0,
                    style: data.textStyleName,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: max(0, rect.width - horizontalTextMargin * 2),
                    color: textColor))
            }
        }

        return primitives
    }

    private static func appendRectLines(
        _ rect: DataTableCellRect,
        z: Double,
        color: ColorRGBA?,
        seen: inout Set<DataTableGridLineKey>,
        into primitives: inout [CADPrimitive]
    ) {
        let p0 = Vector3(x: rect.minX, y: rect.minY, z: z)
        let p1 = Vector3(x: rect.maxX, y: rect.minY, z: z)
        let p2 = Vector3(x: rect.maxX, y: rect.maxY, z: z)
        let p3 = Vector3(x: rect.minX, y: rect.maxY, z: z)
        appendLine(start: p0, end: p1, color: color, seen: &seen, into: &primitives)
        appendLine(start: p1, end: p2, color: color, seen: &seen, into: &primitives)
        appendLine(start: p2, end: p3, color: color, seen: &seen, into: &primitives)
        appendLine(start: p3, end: p0, color: color, seen: &seen, into: &primitives)
    }

    private static func appendLine(
        start: Vector3,
        end: Vector3,
        color: ColorRGBA?,
        seen: inout Set<DataTableGridLineKey>,
        into primitives: inout [CADPrimitive]
    ) {
        let key = DataTableGridLineKey(start, end)
        guard seen.insert(key).inserted else { return }
        primitives.append(.line(start: start, end: end, color: color))
    }

    private static func displayText(data: DataTableData, row: Int, column: Int) -> String {
        guard let cell = cell(data: data, row: row, column: column) else { return "" }
        if let cached = cell.cachedDisplayText, !cached.isEmpty { return cached }
        switch cell.value {
        case .string(let value): return value
        case .number(let value): return String(format: "%g", value)
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .empty: return ""
        }
    }

    private static func cell(data: DataTableData, row: Int, column: Int) -> DataTableCell? {
        guard row >= 0, row < data.rows.count,
              column >= 0, column < data.columns.count else { return nil }
        let columnID = data.columns[column].id
        return data.rows[row].cells.first { $0.columnID == columnID }
    }

    private static func columnWidth(_ column: DataTableColumn, defaultWidth: Double) -> Double {
        max(0.001, column.width > 0 ? column.width : defaultWidth)
    }

    public static func rowHeights(data: DataTableData, rowCount: Int) -> [Double] {
        guard rowCount > 0 else { return [] }
        return (0..<rowCount).map { index in
            if index < data.rowHeights.count, data.rowHeights[index] > 0 {
                return data.rowHeights[index]
            }
            return max(0.001, data.defaultRowHeight)
        }
    }

    private static func intervalIndex(value: Double, edges: [Double]) -> Int? {
        guard edges.count >= 2, value >= edges[0], value <= edges[edges.count - 1] else { return nil }
        for index in 0..<(edges.count - 1) {
            if value >= edges[index],
               value < edges[index + 1] || index == edges.count - 2 && value <= edges[index + 1] {
                return index
            }
        }
        return nil
    }

    private static func transformPrimitive(_ primitive: CADPrimitive, by transform: Transform3D) -> CADPrimitive {
        switch primitive {
        case .line(let start, let end, let color):
            return .line(
                start: transform.transformPoint(start),
                end: transform.transformPoint(end),
                color: color)
        case .text(let position, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, let color):
            // Text height rides the transform exactly like geometry: the
            // entity-level text paths (screen `CADPrimitiveGenerator` and
            // PDF `PDFPrimitives`) scale `height` by the Y-basis magnitude
            // of the matrix they render under, so a pre-transformed visual
            // must already carry the scaled height and width — otherwise
            // the glyphs stay local-sized while the cell boxes they sit in
            // are world-sized. Basis vectors (not the `scale`
            // decomposition) so mirror and skew survive, matching the text
            // paths.
            let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
            let localY = Vector3(x: -sin(rotation), y: cos(rotation), z: 0)
            let tPos = transform.transformPoint(position)
            let widthScale = max(
                (transform.transformPoint(position + localX) - tPos).magnitude, 1e-12)
            let heightScale = max(
                (transform.transformPoint(position + localY) - tPos).magnitude, 1e-12)
            return .text(
                position: tPos,
                text: text,
                height: height * heightScale,
                rotation: rotation + transform.rotation,
                style: style,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: mtextWidth.map { $0 * widthScale },
                color: color)
        case .fillRect(let origin, let size, let color):
            return .fillRect(
                origin: transform.transformPoint(origin),
                size: Vector3(
                    x: size.x * transform.scale.x,
                    y: size.y * transform.scale.y,
                    z: size.z * transform.scale.z),
                color: color)
        default:
            return primitive
        }
    }
}

private extension Transform3D {
    var isIdentity: Bool {
        position.x == 0 && position.y == 0 && position.z == 0
        && rotation == 0
        && scale.x == 1 && scale.y == 1 && scale.z == 1
    }
}

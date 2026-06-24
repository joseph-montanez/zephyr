import Foundation

/// Broad-phase spatial index for CAD entities.
///
/// `CADDocument` owns authoritative drawing data; this type owns only the
/// derived uniform-grid representation used to reduce hit-test candidates.
/// Keeping the cache separate gives the document model one less reason to
/// change and makes invalidation rules explicit at the composition boundary.
///
/// The index is intentionally conservative. Queries may return entities that
/// do not intersect the requested shape, so callers must still perform their
/// normal precise geometry test.
final class CADEntitySpatialIndex {
    /// Flattened grid where `cellIndex = row * columnCount + column`.
    private var cells: [[UUID]] = []
    private var columnCount = 0
    private var rowCount = 0
    private var originX = 0.0
    private var originY = 0.0
    private var cellSize = 1_000.0

    /// Whether the cached grid represents the document's current geometry.
    private(set) var isBuilt = false

    /// Marks the derived grid stale without discarding its allocated storage.
    ///
    /// Rebuilding is deferred until the document or a query explicitly asks
    /// for it, avoiding expensive work during a sequence of live mutations.
    func invalidate() {
        isBuilt = false
    }

    /// Rebuilds the grid from entity world-space bounding boxes.
    ///
    /// The sizing heuristic targets roughly sixteen entities per cell and
    /// caps each axis at 2,048 cells to prevent pathological coordinate ranges
    /// from causing excessive memory allocation.
    func rebuild<S: Sequence>(from entities: S) where S.Element == CADEntity {
        let entities = Array(entities)
        guard entities.count > 1 else {
            isBuilt = false
            return
        }

        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        var hasBounds = false

        for entity in entities {
            guard let bounds = entity.worldBoundingBox else { continue }
            minX = Swift.min(minX, bounds.min.x)
            maxX = Swift.max(maxX, bounds.max.x)
            minY = Swift.min(minY, bounds.min.y)
            maxY = Swift.max(maxY, bounds.max.y)
            hasBounds = true
        }

        guard hasBounds else {
            isBuilt = false
            return
        }

        let spanX = maxX - minX
        let spanY = maxY - minY
        let area = spanX * spanY
        let targetCellCount = Double(entities.count) / 16.0
        let largestSpan = Swift.max(spanX, spanY)
        let minimumCellSize = Swift.max(1.0, largestSpan * 1e-5)

        if area > 0, targetCellCount > 1 {
            cellSize = Swift.max(minimumCellSize, sqrt(area / targetCellCount))
        } else {
            cellSize = Swift.max(minimumCellSize, 1_000.0)
        }

        let maximumAxisCellCount = 2_048
        if spanX / cellSize > Double(maximumAxisCellCount) {
            cellSize = spanX / Double(maximumAxisCellCount)
        }
        if spanY / cellSize > Double(maximumAxisCellCount) {
            cellSize = spanY / Double(maximumAxisCellCount)
        }

        columnCount = max(1, Int(spanX / cellSize) + 1)
        rowCount = max(1, Int(spanY / cellSize) + 1)
        originX = minX
        originY = minY
        cells = Array(repeating: [], count: columnCount * rowCount)

        for entity in entities {
            guard let bounds = entity.worldBoundingBox else { continue }
            let firstColumn = max(0, Int((bounds.min.x - originX) / cellSize))
            let firstRow = max(0, Int((bounds.min.y - originY) / cellSize))
            let lastColumn = min(
                columnCount - 1,
                Int((bounds.max.x - originX) / cellSize))
            let lastRow = min(
                rowCount - 1,
                Int((bounds.max.y - originY) / cellSize))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }

            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    cells[row * columnCount + column].append(entity.handle)
                }
            }
        }

        isBuilt = true
    }

    /// Returns broad-phase candidates for a world-space axis-aligned rectangle.
    ///
    /// A one-cell margin keeps entities near cell boundaries discoverable
    /// without duplicating every entity into padded neighboring cells.
    func handles(
        inWorldRectMinX minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double
    ) -> [UUID]? {
        guard isBuilt else { return nil }

        let firstColumn = max(0, Int((minX - originX) / cellSize) - 1)
        let firstRow = max(0, Int((minY - originY) / cellSize) - 1)
        let lastColumn = min(
            columnCount - 1,
            Int((maxX - originX) / cellSize) + 1)
        let lastRow = min(
            rowCount - 1,
            Int((maxY - originY) / cellSize) + 1)
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return [] }

        var seen = Set<UUID>()
        var result: [UUID] = []
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                for handle in cells[row * columnCount + column]
                where seen.insert(handle).inserted {
                    result.append(handle)
                }
            }
        }
        return result
    }

    /// Returns broad-phase candidates encountered by a grid DDA ray traversal.
    ///
    /// - Parameters:
    ///   - origin: World-space ray origin.
    ///   - direction: Ray direction. It is normalized internally.
    ///   - maxDistance: Maximum world-space traversal distance.
    /// - Returns: Deduplicated handles, or `nil` when no valid grid exists.
    func handles(
        alongRayFrom origin: Vector3,
        direction: Vector3,
        maxDistance: Double
    ) -> [UUID]? {
        guard isBuilt else { return nil }

        let directionMagnitude = direction.magnitude
        guard directionMagnitude > 1e-12 else { return nil }
        let dx = direction.x / directionMagnitude
        let dy = direction.y / directionMagnitude
        let fractionalX = (origin.x - originX) / cellSize
        let fractionalY = (origin.y - originY) / cellSize

        var column = Int(floor(fractionalX))
        var row = Int(floor(fractionalY))

        if !contains(column: column, row: row) {
            var entryTime = 0.0
            if dx > 0, column < 0 {
                entryTime = max(entryTime, -fractionalX / dx)
            }
            if dx < 0, column >= columnCount {
                entryTime = max(
                    entryTime,
                    (Double(columnCount) - fractionalX) / dx)
            }
            if dy > 0, row < 0 {
                entryTime = max(entryTime, -fractionalY / dy)
            }
            if dy < 0, row >= rowCount {
                entryTime = max(
                    entryTime,
                    (Double(rowCount) - fractionalY) / dy)
            }

            column = Int(floor(fractionalX + entryTime * dx))
            row = Int(floor(fractionalY + entryTime * dy))
            guard contains(column: column, row: row) else { return [] }
        }

        let columnStep = dx > 0 ? 1 : (dx < 0 ? -1 : 0)
        let rowStep = dy > 0 ? 1 : (dy < 0 ? -1 : 0)
        let columnTimeDelta =
            columnStep == 0 ? Double.infinity : abs(1.0 / dx)
        let rowTimeDelta =
            rowStep == 0 ? Double.infinity : abs(1.0 / dy)

        var nextColumnTime: Double
        if dx > 0 {
            nextColumnTime = (Double(column + 1) - fractionalX) / dx
        } else if dx < 0 {
            nextColumnTime = (Double(column) - fractionalX) / dx
        } else {
            nextColumnTime = .infinity
        }

        var nextRowTime: Double
        if dy > 0 {
            nextRowTime = (Double(row + 1) - fractionalY) / dy
        } else if dy < 0 {
            nextRowTime = (Double(row) - fractionalY) / dy
        } else {
            nextRowTime = .infinity
        }

        var seen = Set<UUID>()
        var result: [UUID] = []
        let maximumTime = maxDistance / directionMagnitude
        var time = 0.0

        while time <= maximumTime, contains(column: column, row: row) {
            for handle in cells[row * columnCount + column]
            where seen.insert(handle).inserted {
                result.append(handle)
            }

            if nextColumnTime < nextRowTime {
                time = nextColumnTime
                nextColumnTime += columnTimeDelta
                column += columnStep
            } else {
                time = nextRowTime
                nextRowTime += rowTimeDelta
                row += rowStep
            }
        }

        return result
    }

    private func contains(column: Int, row: Int) -> Bool {
        column >= 0 && column < columnCount && row >= 0 && row < rowCount
    }
}

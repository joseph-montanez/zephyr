import Foundation

public enum CADArrayKind: UInt8, CaseIterable, Codable, Hashable, Sendable {
    case rectangular = 0
    case polar = 1
    case path = 2
}

public enum CADPathArrayMethod: UInt8, CaseIterable, Codable, Hashable, Sendable {
    case divide = 0
    case measure = 1
}

public struct CADArrayItemIndex: Codable, Hashable, Sendable {
    public var item: Int
    public var row: Int
    public var level: Int

    public init(item: Int, row: Int = 0, level: Int = 0) {
        self.item = item
        self.row = row
        self.level = level
    }
}

public struct CADArrayInstance: Hashable, Sendable {
    public var index: CADArrayItemIndex
    public var transform: Transform3D

    public init(index: CADArrayItemIndex, transform: Transform3D) {
        self.index = index
        self.transform = transform
    }
}

public struct CADArrayData: Codable, Hashable, Sendable {
    public var kind: CADArrayKind

    public var columns: Int
    public var rows: Int
    public var levels: Int
    public var columnSpacing: Double
    public var rowSpacing: Double
    public var levelSpacing: Double
    public var axisAngle: Double
    public var columnElevationIncrement: Double
    public var rowElevationIncrement: Double

    public var itemCount: Int
    public var fillAngle: Double
    public var rotateItems: Bool
    public var centerPoint: Vector3
    public var itemElevationIncrement: Double

    public var pathMethod: CADPathArrayMethod
    public var itemSpacing: Double
    public var alignItems: Bool
    public var zDirection: Bool
    public var reversePath: Bool
    public var pathEntityHandle: UUID?
    public var cachedPath: [Vector3]
    public var pathStartOffset: Double

    public var hiddenItems: Set<CADArrayItemIndex>

    public init(
        kind: CADArrayKind,
        columns: Int = 2,
        rows: Int = 2,
        levels: Int = 1,
        columnSpacing: Double = 10,
        rowSpacing: Double = 10,
        levelSpacing: Double = 0,
        axisAngle: Double = 0,
        columnElevationIncrement: Double = 0,
        rowElevationIncrement: Double = 0,
        itemCount: Int = 6,
        fillAngle: Double = 2 * .pi,
        rotateItems: Bool = true,
        centerPoint: Vector3 = Vector3(x: -10, y: 0, z: 0),
        itemElevationIncrement: Double = 0,
        pathMethod: CADPathArrayMethod = .divide,
        itemSpacing: Double = 10,
        alignItems: Bool = true,
        zDirection: Bool = false,
        reversePath: Bool = false,
        pathEntityHandle: UUID? = nil,
        cachedPath: [Vector3] = [],
        pathStartOffset: Double = 0,
        hiddenItems: Set<CADArrayItemIndex> = []
    ) {
        self.kind = kind
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.levels = max(1, levels)
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.levelSpacing = levelSpacing
        self.axisAngle = axisAngle
        self.columnElevationIncrement = columnElevationIncrement
        self.rowElevationIncrement = rowElevationIncrement
        self.itemCount = max(1, itemCount)
        self.fillAngle = fillAngle
        self.rotateItems = rotateItems
        self.centerPoint = centerPoint
        self.itemElevationIncrement = itemElevationIncrement
        self.pathMethod = pathMethod
        self.itemSpacing = max(abs(itemSpacing), 1e-9)
        self.alignItems = alignItems
        self.zDirection = zDirection
        self.reversePath = reversePath
        self.pathEntityHandle = pathEntityHandle
        self.cachedPath = cachedPath
        self.pathStartOffset = max(0, pathStartOffset)
        self.hiddenItems = hiddenItems
    }

    public static func rectangular(
        columns: Int = 2,
        rows: Int = 2,
        levels: Int = 1,
        columnSpacing: Double = 10,
        rowSpacing: Double = 10,
        levelSpacing: Double = 1,
        axisAngle: Double = 0
    ) -> CADArrayData {
        CADArrayData(
            kind: .rectangular,
            columns: columns,
            rows: rows,
            levels: levels,
            columnSpacing: columnSpacing,
            rowSpacing: rowSpacing,
            levelSpacing: levelSpacing,
            axisAngle: axisAngle)
    }

    public static func polar(
        itemCount: Int = 6,
        fillAngle: Double = 2 * .pi,
        rotateItems: Bool = true,
        centerPoint: Vector3,
        rows: Int = 1,
        rowSpacing: Double = 0,
        levels: Int = 1,
        levelSpacing: Double = 1
    ) -> CADArrayData {
        CADArrayData(
            kind: .polar,
            rows: rows,
            levels: levels,
            rowSpacing: rowSpacing,
            levelSpacing: levelSpacing,
            itemCount: itemCount,
            fillAngle: fillAngle,
            rotateItems: rotateItems,
            centerPoint: centerPoint)
    }

    public static func path(
        method: CADPathArrayMethod = .divide,
        itemCount: Int = 6,
        itemSpacing: Double = 10,
        alignItems: Bool = true,
        pathEntityHandle: UUID? = nil,
        levels: Int = 1,
        levelSpacing: Double = 1,
        cachedPath: [Vector3]
    ) -> CADArrayData {
        CADArrayData(
            kind: .path,
            rows: 1,
            levels: levels,
            levelSpacing: levelSpacing,
            itemCount: itemCount,
            pathMethod: method,
            itemSpacing: itemSpacing,
            alignItems: alignItems,
            pathEntityHandle: pathEntityHandle,
            cachedPath: cachedPath)
    }

    public var visibleInstanceCount: Int {
        evaluatedInstances().count
    }

    public func evaluatedInstances(pathPoints: [Vector3]? = nil) -> [CADArrayInstance] {
        switch kind {
        case .rectangular:
            return rectangularInstances()
        case .polar:
            return polarInstances()
        case .path:
            return pathInstances(points: pathPoints ?? cachedPath)
        }
    }

    public func localBoundingBox(
        source: BoundingBox3D?,
        pathPoints: [Vector3]? = nil
    ) -> BoundingBox3D? {
        guard let source else { return nil }
        let instances = evaluatedInstances(pathPoints: pathPoints)
        guard let first = instances.first else { return nil }
        var result = BoundingBox3D(transforming: source, by: first.transform)
        for instance in instances.dropFirst() {
            let box = BoundingBox3D(transforming: source, by: instance.transform)
            result.min.x = min(result.min.x, box.min.x)
            result.min.y = min(result.min.y, box.min.y)
            result.min.z = min(result.min.z, box.min.z)
            result.max.x = max(result.max.x, box.max.x)
            result.max.y = max(result.max.y, box.max.y)
            result.max.z = max(result.max.z, box.max.z)
        }
        return result
    }

    private func rectangularInstances() -> [CADArrayInstance] {
        let count = max(1, columns) * max(1, rows) * max(1, levels)
        var result: [CADArrayInstance] = []
        result.reserveCapacity(count)
        let c = cos(axisAngle)
        let s = sin(axisAngle)
        let columnVector = Vector3(x: c * columnSpacing, y: s * columnSpacing, z: columnElevationIncrement)
        let rowVector = Vector3(x: -s * rowSpacing, y: c * rowSpacing, z: rowElevationIncrement)

        for level in 0..<max(1, levels) {
            for row in 0..<max(1, rows) {
                for column in 0..<max(1, columns) {
                    let index = CADArrayItemIndex(item: column, row: row, level: level)
                    if hiddenItems.contains(index) { continue }
                    let delta = columnVector * Double(column)
                        + rowVector * Double(row)
                        + Vector3(x: 0, y: 0, z: levelSpacing * Double(level))
                    result.append(CADArrayInstance(
                        index: index,
                        transform: .translated(by: delta)))
                }
            }
        }
        return result
    }

    private func polarInstances() -> [CADArrayInstance] {
        let n = max(1, itemCount)
        let fullCircle = abs(abs(fillAngle) - 2 * .pi) <= 1e-8
        let step: Double
        if n <= 1 {
            step = 0
        } else {
            step = fillAngle / Double(fullCircle ? n : n - 1)
        }

        let radial = Vector3(x: -centerPoint.x, y: -centerPoint.y, z: 0)
        let radialDirection = radial.magnitude > 1e-12
            ? radial.normalized
            : Vector3(x: 1, y: 0, z: 0)
        var result: [CADArrayInstance] = []
        result.reserveCapacity(n * max(1, rows) * max(1, levels))

        for level in 0..<max(1, levels) {
            for row in 0..<max(1, rows) {
                let radialOffset = radialDirection * (Double(row) * rowSpacing)
                for item in 0..<n {
                    let index = CADArrayItemIndex(item: item, row: row, level: level)
                    if hiddenItems.contains(index) { continue }
                    let angle = Double(item) * step
                    let z = Double(level) * levelSpacing + Double(item) * itemElevationIncrement
                    let rotatePosition = Transform3D.translated(by: centerPoint)
                        .multiplying(by: .rotated(by: angle))
                        .multiplying(by: .translated(by: radialOffset))
                        .multiplying(by: .translated(by: Vector3(
                            x: -centerPoint.x,
                            y: -centerPoint.y,
                            z: -centerPoint.z)))
                    var transform = Transform3D.translated(by: Vector3(x: 0, y: 0, z: z))
                        .multiplying(by: rotatePosition)
                    if !rotateItems {
                        let point = rotatePosition.transformPoint(.zero)
                        transform = .translated(by: Vector3(x: point.x, y: point.y, z: point.z + z))
                    }
                    result.append(CADArrayInstance(index: index, transform: transform))
                }
            }
        }
        return result
    }

    private func pathInstances(points input: [Vector3]) -> [CADArrayInstance] {
        var points = normalizedPath(input)
        if reversePath { points.reverse() }
        guard points.count >= 2 else { return [] }

        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + points[i - 1].distance(to: points[i]))
        }
        guard let total = cumulative.last, total > 1e-12 else { return [] }
        let start = min(max(0, pathStartOffset), total)

        let count: Int
        let spacing: Double
        switch pathMethod {
        case .divide:
            count = max(1, itemCount)
            spacing = count <= 1 ? 0 : (total - start) / Double(count - 1)
        case .measure:
            spacing = max(abs(itemSpacing), 1e-9)
            count = max(1, Int(floor((total - start) / spacing)) + 1)
        }

        let firstTangent = pathPointAndTangent(
            at: start,
            points: points,
            cumulative: cumulative).tangent
        let referenceAngle = atan2(firstTangent.y, firstTangent.x)
        var result: [CADArrayInstance] = []
        result.reserveCapacity(count * max(1, rows) * max(1, levels))

        for level in 0..<max(1, levels) {
            for row in 0..<max(1, rows) {
                for item in 0..<count {
                    let index = CADArrayItemIndex(item: item, row: row, level: level)
                    if hiddenItems.contains(index) { continue }
                    let distance = min(total, start + Double(item) * spacing)
                    let sample = pathPointAndTangent(
                        at: distance,
                        points: points,
                        cumulative: cumulative)
                    let tangent = sample.tangent.magnitude > 1e-12
                        ? sample.tangent.normalized
                        : firstTangent.normalized
                    let normal = Vector3(x: -tangent.y, y: tangent.x, z: 0)
                    let position = sample.point
                        + normal * (Double(row) * rowSpacing)
                        + Vector3(x: 0, y: 0, z: Double(level) * levelSpacing)
                    let translation = Transform3D.translated(by: position)
                    let transform: Transform3D
                    if alignItems {
                        let angle = atan2(tangent.y, tangent.x) - referenceAngle
                        transform = translation.multiplying(by: .rotated(by: angle))
                    } else {
                        transform = translation
                    }
                    result.append(CADArrayInstance(index: index, transform: transform))
                }
            }
        }
        return result
    }

    private func normalizedPath(_ input: [Vector3]) -> [Vector3] {
        guard !input.isEmpty else { return [] }
        var result: [Vector3] = [input[0]]
        result.reserveCapacity(input.count)
        for point in input.dropFirst() where point.distance(to: result[result.count - 1]) > 1e-9 {
            result.append(point)
        }
        return result
    }

    private func pathPointAndTangent(
        at distance: Double,
        points: [Vector3],
        cumulative: [Double]
    ) -> (point: Vector3, tangent: Vector3) {
        if distance <= 0 {
            return (points[0], points[1] - points[0])
        }
        if distance >= cumulative[cumulative.count - 1] {
            return (points[points.count - 1], points[points.count - 1] - points[points.count - 2])
        }
        var lower = 0
        var upper = cumulative.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if cumulative[middle] <= distance { lower = middle }
            else { upper = middle }
        }
        let segmentLength = cumulative[upper] - cumulative[lower]
        let t = segmentLength > 1e-12 ? (distance - cumulative[lower]) / segmentLength : 0
        let a = points[lower]
        let b = points[upper]
        return (a + (b - a) * t, b - a)
    }
}

public struct CADArrayDXFPayload: Codable, Sendable {
    public var version: Int
    public var groupID: UUID
    public var containerTransform: [Double]
    public var data: CADArrayData

    public init(groupID: UUID, containerTransform: Transform3D, data: CADArrayData) {
        self.version = 1
        self.groupID = groupID
        self.containerTransform = containerTransform.rawElements
        var compact = data
        if compact.cachedPath.count > CADArrayDXFCodec.maximumPathPointCount {
            compact.cachedPath = CADArrayDXFCodec.downsampledPath(compact.cachedPath)
        }
        self.data = compact
    }

    public var transform: Transform3D? {
        containerTransform.count == 16 ? Transform3D(raw: containerTransform) : nil
    }
}

public enum CADArrayDXFCodec {
    public static let appID = "ZEPHYR_ARRAY"
    public static let marker = "ZARR1"
    public static let maximumPathPointCount = 128

    public static func downsampledPath(_ points: [Vector3]) -> [Vector3] {
        guard points.count > maximumPathPointCount else { return points }
        let last = points.count - 1
        return (0..<maximumPathPointCount).map { index in
            let source = Int((Double(index) * Double(last) / Double(maximumPathPointCount - 1)).rounded())
            return points[min(last, source)]
        }
    }

    public static func encode(_ payload: CADArrayDXFPayload) -> [String] {
        guard let data = try? JSONEncoder().encode(payload) else { return [] }
        let base64 = data.base64EncodedString()
        let chunkSize = 220
        var chunks: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            chunks.append("D:" + String(base64[index..<end]))
            index = end
        }
        return chunks
    }

    public static func decode(_ chunks: [String]) -> CADArrayDXFPayload? {
        let encoded = chunks
            .filter { $0.hasPrefix("D:") }
            .map { String($0.dropFirst(2)) }
            .joined()
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(CADArrayDXFPayload.self, from: data)
    }
}

public enum CADArrayPathResolver {
    public static func points(
        for array: CADArrayData,
        containerTransform: Transform3D,
        document: CADDocument
    ) -> [Vector3] {
        guard let handle = array.pathEntityHandle,
              let entity = document.entity(for: handle),
              let geometry = document.resolvedGeometry(for: entity)
        else { return array.cachedPath }
        return localPoints(
            geometry: geometry,
            pathTransform: entity.transform,
            containerTransform: containerTransform) ?? array.cachedPath
    }

    public static func points(
        for array: CADArrayData,
        containerTransform: Transform3D,
        snapshot: CADDocumentSnapshot
    ) -> [Vector3] {
        guard let handle = array.pathEntityHandle,
              let entity = snapshot.entities[handle]
        else { return array.cachedPath }
        let geometry: [CADPrimitive]?
        if let blockID = entity.blockID {
            geometry = snapshot.blocks[blockID]?.geometry
        } else {
            geometry = entity.localGeometry
        }
        guard let geometry else { return array.cachedPath }
        return localPoints(
            geometry: geometry,
            pathTransform: entity.transform,
            containerTransform: containerTransform) ?? array.cachedPath
    }

    public static func localPoints(
        geometry: [CADPrimitive],
        pathTransform: Transform3D,
        containerTransform: Transform3D
    ) -> [Vector3]? {
        guard let primitive = geometry.first(where: isSupportedPath) else { return nil }
        let local = sampledPoints(from: primitive)
        guard local.count >= 2 else { return nil }
        let inverse = containerTransform.inverse()
        return local.map { inverse.transformPoint(pathTransform.transformPoint($0)) }
    }

    public static func sampledPoints(from primitive: CADPrimitive) -> [Vector3] {
        switch primitive {
        case .line(let start, let end, _):
            return [start, end]
        case .polyline(let path, _):
            return path.tessellatedPoints()
        case .polygon(let points, _):
            guard let first = points.first else { return [] }
            return points + [first]
        case .arc(let center, let radius, let start, let end, _):
            var sweep = end - start
            while sweep <= 0 { sweep += 2 * .pi }
            let segments = max(8, Int(ceil(abs(sweep) / (.pi / 24))))
            return (0...segments).map { i in
                let angle = start + sweep * Double(i) / Double(segments)
                return Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius,
                    z: center.z)
            }
        case .circle(let center, let radius, _):
            let segments = 96
            return (0...segments).map { i in
                let angle = 2 * .pi * Double(i) / Double(segments)
                return Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius,
                    z: center.z)
            }
        case .ellipse(let center, let majorAxis, let ratio, _):
            let minorAxis = Vector3(
                x: -majorAxis.y * ratio,
                y: majorAxis.x * ratio,
                z: majorAxis.z * ratio)
            let segments = 96
            return (0...segments).map { i in
                let angle = 2 * .pi * Double(i) / Double(segments)
                return center + majorAxis * cos(angle) + minorAxis * sin(angle)
            }
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            return NURBSEvaluator.evaluateByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: controlPoints,
                weights: weights,
                segmentsPerSpan: 24)
        default:
            return []
        }
    }

    private static func isSupportedPath(_ primitive: CADPrimitive) -> Bool {
        switch primitive {
        case .line, .polyline, .polygon, .arc, .circle, .ellipse, .spline:
            return true
        default:
            return false
        }
    }
}

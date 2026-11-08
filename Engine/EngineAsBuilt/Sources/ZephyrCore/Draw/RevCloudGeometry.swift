import Foundation

public enum RevCloudDXFCodec {
    public static let appID = "RevcloudProps"

    public static func styleCode(for style: RevCloudStyle) -> Int {
        style == .calligraphy ? 1 : 0
    }

    public static func style(for code: Int) -> RevCloudStyle {
        code == 0 ? .normal : .calligraphy
    }
}

public enum RevCloudGripIndex {
    private static let vertexBase = -100_000

    public static func vertex(_ index: Int) -> Int {
        vertexBase - index
    }

    public static func vertexIndex(from encoded: Int) -> Int? {
        guard encoded <= vertexBase else { return nil }
        return vertexBase - encoded
    }
}

public enum RevCloudGeometry {
    public static let standardBulge = tan(110.0 * Double.pi / 180.0 / 4.0)
    private static let epsilon = 1e-9
    private static let maximumVertices = 20_000
    private static let guideKey = "zephyr.revcloud.guide"
    private static let randomSeedKey = "zephyr.revcloud.randomSeed"
    private static let arcCountKey = "zephyr.revcloud.arcCount"
    private static let varianceKey = "zephyr.revcloud.arcVariance"

    public static func isRevisionCloud(entity: CADEntity, geometry: [CADPrimitive]) -> Bool {
        if case .bool(true)? = entity.xdata["zephyr.revcloud"] { return true }
        guard geometry.count == 1,
              case .polyline(let path, _) = geometry[0],
              path.isClosed,
              path.vertices.count >= 3
        else { return false }
        let bulges = path.vertices.map(\.bulge).filter { abs($0) > 1e-8 }
        guard bulges.count >= max(3, Int(Double(path.vertices.count) * 0.8)) else { return false }
        let sign = bulges[0] >= 0 ? 1.0 : -1.0
        return bulges.allSatisfy { ($0 >= 0 ? 1.0 : -1.0) == sign }
    }

    public static func cloudPath(from entity: CADEntity, document: CADDocument) -> CADPolyline? {
        guard let geometry = document.resolvedGeometry(for: entity) else { return nil }
        for primitive in geometry {
            if case .polyline(let path, _) = primitive, path.isClosed {
                return path
            }
        }
        return nil
    }

    public static func style(of entity: CADEntity, path: CADPolyline) -> RevCloudStyle {
        if case .string(let raw)? = entity.xdata["zephyr.revcloud.style"],
           let style = RevCloudStyle(rawValue: raw) {
            return style
        }
        return path.vertices.contains { $0.startWidth > epsilon || $0.endWidth > epsilon }
            ? .calligraphy : .normal
    }

    public static func guidePoints(of entity: CADEntity, path: CADPolyline) -> [Vector3]? {
        if case .string(let encoded)? = entity.xdata[guideKey] {
            let points = decodeGuide(encoded)
            if points.count >= 3 { return points }
        }
        return inferredRectangularGuide(from: path)
    }

    public static func storeGuide(_ guide: [Vector3], in entity: inout CADEntity) {
        entity.xdata[guideKey] = .string(encodeGuide(cleanGuide(guide, closed: true)))
    }

    public static func randomSeed(
        of entity: CADEntity,
        guide: [Vector3],
        arcCount: Int,
        minimumArcLength: Double,
        maximumArcLength: Double
    ) -> UInt64 {
        if case .int(let value)? = entity.xdata[randomSeedKey], value > 0 {
            return UInt64(value)
        }
        return stableRandomSeed(
            guide: cleanGuide(guide, closed: true),
            closed: true,
            count: arcCount,
            minimumArcLength: minimumArcLength,
            maximumArcLength: maximumArcLength)
    }

    public static func storeGenerationState(
        guide: [Vector3],
        path: CADPolyline,
        variance: Bool,
        minimumArcLength: Double,
        maximumArcLength: Double,
        in entity: inout CADEntity
    ) {
        let cleaned = cleanGuide(guide, closed: true)
        let seed = stableRandomSeed(
            guide: cleaned,
            closed: true,
            count: path.vertices.count,
            minimumArcLength: minimumArcLength,
            maximumArcLength: maximumArcLength)
        storeGripState(
            guide: cleaned,
            randomSeed: seed,
            arcCount: path.vertices.count,
            variance: variance,
            in: &entity)
    }

    public static func storeGripState(
        guide: [Vector3],
        randomSeed: UInt64,
        arcCount: Int,
        variance: Bool,
        in entity: inout CADEntity
    ) {
        storeGuide(guide, in: &entity)
        entity.xdata[randomSeedKey] = .int(Int(randomSeed))
        entity.xdata[arcCountKey] = .int(arcCount)
        entity.xdata[varianceKey] = .bool(variance)
    }

    public static func storedArcCount(of entity: CADEntity, fallback: Int) -> Int {
        if case .int(let value)? = entity.xdata[arcCountKey], value >= 3 {
            return value
        }
        return fallback
    }

    public static func storedVariance(of entity: CADEntity) -> Bool {
        if case .bool(let value)? = entity.xdata[varianceKey] { return value }
        return RevCloudSettings.arcVarianceEnabled
    }

    public static func clearGuideState(in entity: inout CADEntity) {
        entity.xdata.removeValue(forKey: guideKey)
        entity.xdata.removeValue(forKey: randomSeedKey)
        entity.xdata.removeValue(forKey: arcCountKey)
        entity.xdata.removeValue(forKey: varianceKey)
    }

    private static func encodeGuide(_ guide: [Vector3]) -> String {
        guide.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ";")
    }

    private static func decodeGuide(_ encoded: String) -> [Vector3] {
        encoded.split(separator: ";").compactMap { item in
            let parts = item.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  let z = Double(parts[2])
            else { return nil }
            return Vector3(x: x, y: y, z: z)
        }
    }

    private static func inferredRectangularGuide(from path: CADPolyline) -> [Vector3]? {
        let points = path.vertices.map(\.position)
        guard points.count >= 4,
              let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max()
        else { return nil }

        let width = maxX - minX
        let height = maxY - minY
        guard width > epsilon, height > epsilon else { return nil }

        let tolerance = max(width, height) * 1e-6 + epsilon
        let boundaryCount = points.reduce(into: 0) { count, point in
            let distance = min(
                abs(point.x - minX), abs(point.x - maxX),
                abs(point.y - minY), abs(point.y - maxY))
            if distance <= tolerance { count += 1 }
        }
        guard boundaryCount * 10 >= points.count * 9 else { return nil }

        var corners = [
            Vector3(x: minX, y: minY, z: points[0].z),
            Vector3(x: maxX, y: minY, z: points[0].z),
            Vector3(x: maxX, y: maxY, z: points[0].z),
            Vector3(x: minX, y: maxY, z: points[0].z)
        ]
        if signedArea(points) < 0 { corners.reverse() }
        let start = corners.indices.min {
            corners[$0].distance(to: points[0]) < corners[$1].distance(to: points[0])
        } ?? 0
        return corners.indices.map { corners[(start + $0) % corners.count] }
    }

    public static func cleanGuide(_ input: [Vector3], closed: Bool) -> [Vector3] {
        var result: [Vector3] = []
        result.reserveCapacity(input.count)
        for point in input where point.x.isFinite && point.y.isFinite {
            if result.last?.distance(to: point) ?? .infinity > epsilon {
                result.append(point)
            }
        }
        if closed, result.count > 1,
           let first = result.first, let last = result.last,
           first.distance(to: last) <= epsilon {
            result.removeLast()
        }
        return result
    }

    public static func signedArea(_ points: [Vector3]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return area * 0.5
    }

    public static func makeCloud(
        guide input: [Vector3],
        closed: Bool,
        minimumArcLength: Double,
        maximumArcLength: Double,
        variance: Bool,
        style: RevCloudStyle,
        reverse: Bool = false,
        forcedBulgeSign: Double? = nil,
        randomSeed: UInt64? = nil,
        forcedArcCount: Int? = nil
    ) -> CADPolyline? {
        let guide = cleanGuide(input, closed: closed)
        guard guide.count >= (closed ? 3 : 2) else { return nil }

        let minimum = max(minimumArcLength, 1e-8)
        let maximum = min(max(maximumArcLength, minimum), minimum * 3.0)
        let target = (minimum + maximum) * 0.5
        let orientation = signedArea(guide) >= 0 ? 1.0 : -1.0
        var bulgeSign = forcedBulgeSign ?? orientation
        if reverse { bulgeSign *= -1.0 }

        let edgeCount = closed ? guide.count : guide.count - 1
        var edgeLengths: [Double] = []
        edgeLengths.reserveCapacity(edgeCount)
        var totalLength = 0.0
        for edgeIndex in 0..<edgeCount {
            let length = guide[edgeIndex].distance(to: guide[(edgeIndex + 1) % guide.count])
            edgeLengths.append(length)
            totalLength += length
        }
        guard totalLength > epsilon else { return nil }

        let requiredCount = closed ? 3 : 1
        let minimumCount = max(requiredCount, Int(ceil(totalLength / maximum)))
        let maximumCount = max(minimumCount, Int(floor(totalLength / minimum)))
        let desiredCount = max(requiredCount, Int(round(totalLength / target)))
        let naturalCount = min(maximumVertices - (closed ? 0 : 1),
                               min(maximumCount, max(minimumCount, desiredCount)))
        let count = forcedArcCount.map {
            min(maximumVertices - (closed ? 0 : 1), max(requiredCount, $0))
        } ?? naturalCount
        guard count >= (closed ? 3 : 1) else { return nil }

        var weights = Array(repeating: 1.0, count: count)
        if variance, count > 1 {
            var randomState = randomSeed ?? stableRandomSeed(
                guide: guide,
                closed: closed,
                count: count,
                minimumArcLength: minimum,
                maximumArcLength: maximum)
            for index in weights.indices {
                weights[index] = (2.0 / 3.0) + nextStableRandomUnit(&randomState) * (2.0 / 3.0)
            }
        }
        let weightSum = weights.reduce(0, +)

        var vertices: [CADPolylineVertex] = []
        vertices.reserveCapacity(count + (closed ? 0 : 1))
        var distance = 0.0
        var edgeIndex = 0
        var edgeStartDistance = 0.0

        for index in 0..<count {
            while edgeIndex < edgeCount - 1,
                  distance >= edgeStartDistance + edgeLengths[edgeIndex] - epsilon {
                edgeStartDistance += edgeLengths[edgeIndex]
                edgeIndex += 1
            }

            let edgeLength = max(edgeLengths[edgeIndex], epsilon)
            let t = max(0, min(1, (distance - edgeStartDistance) / edgeLength))
            let start = guide[edgeIndex]
            let end = guide[(edgeIndex + 1) % guide.count]
            let point = Vector3(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t,
                z: start.z + (end.z - start.z) * t)
            let chordLength = totalLength * weights[index] / weightSum
            let widths: (Double, Double) = style == .calligraphy
                ? (max(chordLength * 0.025, 1e-9), max(chordLength * 0.16, 1e-9))
                : (0, 0)
            vertices.append(CADPolylineVertex(
                position: point,
                bulge: standardBulge * bulgeSign,
                startWidth: widths.0,
                endWidth: widths.1))
            distance += chordLength
        }

        if !closed, let end = guide.last {
            vertices.append(CADPolylineVertex(position: end))
        }
        guard vertices.count >= (closed ? 3 : 2) else { return nil }
        return CADPolyline(vertices: vertices, isClosed: closed, lineTypeGenerationEnabled: true)
    }

    private static func stableRandomSeed(
        guide: [Vector3],
        closed: Bool,
        count: Int,
        minimumArcLength: Double,
        maximumArcLength: Double
    ) -> UInt64 {
        var state: UInt64 = 0x9E3779B97F4A7C15

        func mix(_ value: UInt64) {
            state ^= value &+ 0x9E3779B97F4A7C15 &+ (state << 6) &+ (state >> 2)
            state &*= 0xBF58476D1CE4E5B9
        }

        for point in guide {
            mix(point.x.bitPattern)
            mix(point.y.bitPattern)
            mix(point.z.bitPattern)
        }
        mix(UInt64(count))
        mix(closed ? 1 : 0)
        mix(minimumArcLength.bitPattern)
        mix(maximumArcLength.bitPattern)
        let safe = state & 0x7FFF_FFFF_FFFF_FFFF
        return safe == 0 ? 0x51B54A32D192ED03 : safe
    }

    private static func nextStableRandomUnit(_ state: inout UInt64) -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992.0
    }

    public static func reversed(_ path: CADPolyline) -> CADPolyline {
        guard path.vertices.count >= 2 else { return path }
        let original = path.vertices
        let count = original.count
        var result: [CADPolylineVertex] = []
        result.reserveCapacity(count)

        for oldIndex in original.indices.reversed() {
            let previous = (oldIndex - 1 + count) % count
            let source = original[previous]
            let isLastOpenVertex = !path.isClosed && oldIndex == 0
            result.append(CADPolylineVertex(
                position: original[oldIndex].position,
                bulge: isLastOpenVertex ? 0 : -source.bulge,
                startWidth: isLastOpenVertex ? 0 : source.endWidth,
                endWidth: isLastOpenVertex ? 0 : source.startWidth))
        }

        var reversed = path
        reversed.vertices = result
        return reversed
    }

    public static func resampleClosedPath(_ input: [Vector3], targetLength: Double) -> [Vector3] {
        let points = cleanGuide(input, closed: true)
        guard points.count >= 3 else { return points }
        var lengths: [Double] = []
        lengths.reserveCapacity(points.count)
        var total = 0.0
        for index in points.indices {
            let length = points[index].distance(to: points[(index + 1) % points.count])
            lengths.append(length)
            total += length
        }
        guard total > epsilon else { return points }

        let count = min(maximumVertices, max(4, Int(round(total / max(targetLength, epsilon)))))
        var result: [Vector3] = []
        result.reserveCapacity(count)
        var edge = 0
        var edgeStartDistance = 0.0

        for sample in 0..<count {
            let distance = total * Double(sample) / Double(count)
            while edge < lengths.count - 1,
                  edgeStartDistance + lengths[edge] < distance {
                edgeStartDistance += lengths[edge]
                edge += 1
            }
            let edgeLength = max(lengths[edge], epsilon)
            let t = (distance - edgeStartDistance) / edgeLength
            let a = points[edge]
            let b = points[(edge + 1) % points.count]
            result.append(Vector3(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t,
                z: a.z + (b.z - a.z) * t))
        }
        return result
    }

    public static func closestVertexIndex(to point: Vector3, in points: [Vector3]) -> Int? {
        guard !points.isEmpty else { return nil }
        return points.indices.min { points[$0].distance(to: point) < points[$1].distance(to: point) }
    }

    public static func distance(to point: Vector3, polyline: [Vector3]) -> Double {
        guard polyline.count >= 2 else { return polyline.first?.distance(to: point) ?? .infinity }
        var best = Double.infinity
        for index in 0..<(polyline.count - 1) {
            best = min(best, distance(point, toSegmentFrom: polyline[index], to: polyline[index + 1]))
        }
        return best
    }

    private static func distance(_ point: Vector3, toSegmentFrom a: Vector3, to b: Vector3) -> Double {
        let ab = b - a
        let denominator = ab.magnitudeSquared
        guard denominator > epsilon else { return point.distance(to: a) }
        let t = max(0, min(1, (point - a).dot(ab) / denominator))
        return point.distance(to: a + ab * t)
    }
}

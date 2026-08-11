import Foundation
import CSDL3
import ImGui
import SwiftSDL

public enum RevCloudCreationMode: Int, Sendable {
    case freehand = 0
    case rectangular = 1
    case polygonal = 2

    var displayName: String {
        switch self {
        case .freehand: return "Freehand"
        case .rectangular: return "Rectangular"
        case .polygonal: return "Polygonal"
        }
    }
}

public enum RevCloudStyle: String, Sendable {
    case normal = "Normal"
    case calligraphy = "Calligraphy"
}

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

public enum RevCloudSettings {
    private static let prefix = "Zephyr.RevCloud."

    private static func double(_ key: String, default defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: prefix + key) != nil else { return defaultValue }
        return UserDefaults.standard.double(forKey: prefix + key)
    }

    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: prefix + key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: prefix + key)
    }

    public static var minimumArcLength: Double {
        get { double("MinimumArcLength", default: 0) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: prefix + "MinimumArcLength") }
    }

    public static var maximumArcLength: Double {
        get { double("MaximumArcLength", default: 0) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: prefix + "MaximumArcLength") }
    }

    public static var approximateArcLength: Double {
        get {
            let explicit = double("ApproximateArcLength", default: 0)
            if explicit > 0 { return explicit }
            let minLength = minimumArcLength
            let maxLength = maximumArcLength
            return minLength > 0 && maxLength > 0 ? (minLength + maxLength) * 0.5 : 0
        }
        set {
            let value = max(0, newValue)
            UserDefaults.standard.set(value, forKey: prefix + "ApproximateArcLength")
            if value > 0 {
                minimumArcLength = value * (2.0 / 3.0)
                maximumArcLength = value * (4.0 / 3.0)
            }
        }
    }

    public static var arcVarianceEnabled: Bool {
        get { bool("ArcVariance", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "ArcVariance") }
    }

    public static var gripsEnabled: Bool {
        get { bool("Grips", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "Grips") }
    }

    public static var deleteSourceObject: Bool {
        get { bool("DeleteSourceObject", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "DeleteSourceObject") }
    }

    public static var creationMode: RevCloudCreationMode {
        get {
            guard UserDefaults.standard.object(forKey: prefix + "CreationMode") != nil else {
                return .rectangular
            }
            return RevCloudCreationMode(
                rawValue: UserDefaults.standard.integer(forKey: prefix + "CreationMode")) ?? .rectangular
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: prefix + "CreationMode") }
    }

    public static var style: RevCloudStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: prefix + "Style") else { return .normal }
            return RevCloudStyle(rawValue: raw) ?? .normal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: prefix + "Style") }
    }

    public static var layerName: String {
        get { UserDefaults.standard.string(forKey: prefix + "Layer") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "Layer") }
    }

    @MainActor
    public static func ensureArcLengths(engine: PhrostEngine) {
        if minimumArcLength > 0, maximumArcLength >= minimumArcLength { return }
        let viewport = engine.camera.worldViewportRect(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        let diagonal = hypot(viewport.maxX - viewport.minX, viewport.maxY - viewport.minY)
        let approximate = max(diagonal * 0.0075, 1e-6)
        minimumArcLength = approximate * (2.0 / 3.0)
        maximumArcLength = approximate * (4.0 / 3.0)
        UserDefaults.standard.set(approximate, forKey: prefix + "ApproximateArcLength")
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

@MainActor
public final class RevCloudCommand: FeatureCommand {
    private struct PendingCommit {
        var entity: CADEntity
        var removeHandles: Set<UUID>
        var updateExisting: Bool
        var message: String
    }

    private struct ModifyContext {
        var entity: CADEntity
        var path: CADPolyline
        var worldPath: CADPolyline
        var worldVertices: [Vector3]
        var style: RevCloudStyle
        var bulgeSign: Double
    }

    private struct ModifyEraseContext {
        var context: ModifyContext
        var startIndex: Int
        var endIndex: Int
        var replacementGuide: [Vector3]
    }

    private enum State {
        case topLevel
        case rectangleSecond(Vector3)
        case polygonal([Vector3])
        case freehand([Vector3])
        case selectingObject
        case arcMinimum
        case arcMaximum(Double)
        case selectingStyle
        case selectingLayer
        case reverse(PendingCommit)
        case modifySelect
        case modifyStart(ModifyContext)
        case modifyDrawing(ModifyContext, Int, [Vector3])
        case modifyErase(ModifyEraseContext)
    }

    private var state: State = .topLevel
    private var currentMouse = Vector3.zero
    private var freehandClosing = false

    public init() {}

    public var isSnappingEnabled: Bool {
        switch state {
        case .freehand: return false
        default: return true
        }
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        RevCloudSettings.ensureArcLengths(engine: engine)
        state = .topLevel
        currentMouse = .zero
        freehandClosing = false
        showTopLevelPrompt(processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .topLevel
        freehandClosing = false
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        switch state {
        case .rectangleSecond(let first): return [first]
        case .polygonal(let points), .freehand(let points): return points
        case .modifyDrawing(_, _, let points): return points
        default: return []
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        let options: [FeatureCommandTextOption]
        switch state {
        case .topLevel:
            options = [
                .init(value: "Arc length", title: "Arc length", aliases: ["A"], description: "Set minimum and maximum arc chord lengths"),
                .init(value: "Object", title: "Object", aliases: ["O"], description: "Convert a closed object into a revision cloud"),
                .init(value: "Rectangular", title: "Rectangular", aliases: ["R"], description: "Create a rectangular revision cloud"),
                .init(value: "Polygonal", title: "Polygonal", aliases: ["P"], description: "Create a polygonal revision cloud"),
                .init(value: "Freehand", title: "Freehand", aliases: ["F"], description: "Draw a freehand revision cloud"),
                .init(value: "Style", title: "Style", aliases: ["S"], description: "Choose Normal or Calligraphy"),
                .init(value: "Modify", title: "Modify", aliases: ["M"], description: "Replace part of an existing revision cloud"),
                .init(value: "Layer", title: "Layer", aliases: ["L"], description: "Set the revision-cloud layer")
            ]
        case .selectingStyle:
            options = [
                .init(value: "Normal", title: "Normal", aliases: ["N"]),
                .init(value: "Calligraphy", title: "Calligraphy", aliases: ["C"])
            ]
        case .reverse:
            options = [
                .init(value: "Yes", title: "Yes", aliases: ["Y"]),
                .init(value: "No", title: "No", aliases: ["N"])
            ]
        default:
            options = []
        }
        return options.filter { $0.matches(input) }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        currentMouse = point

        switch state {
        case .topLevel:
            switch RevCloudSettings.creationMode {
            case .rectangular:
                state = .rectangleSecond(point)
                processor.commandPrompt = "Specify opposite corner:"
            case .polygonal:
                state = .polygonal([point])
                processor.commandPrompt = "Specify next point or [Close] <Enter to finish>:"
            case .freehand:
                state = .freehand([point])
                processor.commandPrompt = "Guide crosshair along cloud path; Enter or return to start to finish."
            }
            return .handled

        case .rectangleSecond(let first):
            let minX = min(first.x, point.x)
            let minY = min(first.y, point.y)
            let maxX = max(first.x, point.x)
            let maxY = max(first.y, point.y)
            guard maxX - minX > 1e-9, maxY - minY > 1e-9 else {
                processor.commandPrompt = "Opposite corner must define a non-zero rectangle."
                return .handled
            }
            let guide = [
                Vector3(x: minX, y: minY, z: 0),
                Vector3(x: maxX, y: minY, z: 0),
                Vector3(x: maxX, y: maxY, z: 0),
                Vector3(x: minX, y: maxY, z: 0)
            ]
            return prepareNewCloud(guide: guide, engine: engine, processor: processor)

        case .polygonal(var points):
            if points.count >= 3,
               let first = points.first,
               first.distance(to: point) <= max(RevCloudSettings.minimumArcLength * 0.5, 1e-6) {
                return prepareNewCloud(guide: points, engine: engine, processor: processor)
            }
            points.append(point)
            state = .polygonal(points)
            processor.commandPrompt = "Specify next point or [Close] <Enter to finish>:"
            return .handled

        case .freehand(let points):
            if points.count >= 3 { return prepareNewCloud(guide: points, engine: engine, processor: processor) }
            processor.commandPrompt = "Move farther before finishing the freehand cloud."
            return .handled

        case .selectingObject:
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: max(3.0 / max(engine.camera.zoom, 1e-9), 1e-6),
                simplifyComplexBlocks: false),
                  let source = engine.document.entity(for: handle),
                  let guide = objectGuide(for: source, document: engine.document)
            else {
                processor.commandPrompt = "Select a circle, ellipse, closed polyline, polygon, rectangle, or closed spline:"
                return .handled
            }
            guard let path = makeCloud(guide: guide, closed: true) else {
                processor.commandPrompt = "Selected object cannot be converted to a revision cloud."
                return .handled
            }
            var entity = makeEntity(path: path, guide: guide, engine: engine)
            entity.xdata["zephyr.revcloud.source"] = .string(source.handle.uuidString)
            let pending = PendingCommit(
                entity: entity,
                removeHandles: RevCloudSettings.deleteSourceObject ? [source.handle] : [],
                updateExisting: false,
                message: "Revision cloud created from object.")
            state = .reverse(pending)
            processor.commandPrompt = "Reverse direction [Yes/No] <No>:"
            return .handled

        case .modifySelect:
            guard let context = modificationContext(at: point, engine: engine) else {
                processor.commandPrompt = "Select a revision cloud polyline:"
                return .handled
            }
            state = .modifyStart(context)
            processor.commandPrompt = "Specify new polyline start point on revision cloud:"
            return .handled

        case .modifyStart(let context):
            guard let index = RevCloudGeometry.closestVertexIndex(to: point, in: context.worldVertices) else {
                return .handled
            }
            let start = context.worldVertices[index]
            state = .modifyDrawing(context, index, [start])
            processor.commandPrompt = "Specify next point; select another cloud vertex to finish replacement:"
            return .handled

        case .modifyDrawing(let context, let startIndex, var guide):
            let threshold = max(RevCloudSettings.minimumArcLength * 0.6, 1e-6)
            if let endIndex = RevCloudGeometry.closestVertexIndex(to: point, in: context.worldVertices),
               endIndex != startIndex,
               context.worldVertices[endIndex].distance(to: point) <= threshold,
               !guide.isEmpty {
                guide.append(context.worldVertices[endIndex])
                state = .modifyErase(ModifyEraseContext(
                    context: context,
                    startIndex: startIndex,
                    endIndex: endIndex,
                    replacementGuide: guide))
                processor.commandPrompt = "Pick side to erase:"
                return .handled
            }
            guide.append(point)
            state = .modifyDrawing(context, startIndex, guide)
            return .handled

        case .modifyErase(let pending):
            guard let updated = buildModifiedEntity(pending, erasePoint: point) else {
                processor.commandPrompt = "Unable to modify revision cloud."
                return .finished
            }
            engine.document.updateEntity(updated)
            engine.cadSelection.select(updated.handle)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt = "Revision cloud modified."
            return .finished

        default:
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouse = Vector3(x: worldX, y: worldY, z: 0)
        guard case .freehand(var points) = state,
              let last = points.last,
              !freehandClosing
        else { return }

        let spacing = max(RevCloudSettings.approximateArcLength, 1e-6)
        let delta = currentMouse - last
        let distance = delta.magnitude
        if distance >= spacing {
            let count = max(1, Int(floor(distance / spacing)))
            for index in 1...count {
                let t = min(1.0, spacing * Double(index) / distance)
                points.append(last + delta * t)
            }
            state = .freehand(points)
        }

        if points.count >= 6,
           let first = points.first,
           currentMouse.distance(to: first) <= spacing * 0.6 {
            freehandClosing = true
            _ = prepareNewCloud(guide: points, engine: engine, processor: processor)
        }
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return handleCommandText("", engine: engine, processor: processor)
        case SDL_SCANCODE_C:
            if case .polygonal(let points) = state, points.count >= 3 {
                return prepareNewCloud(guide: points, engine: engine, processor: processor)
            }
            return .continue
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.replacingOccurrences(of: " ", with: "").uppercased()

        switch state {
        case .topLevel:
            if key.isEmpty || key == "O" || key == "OBJECT" {
                state = .selectingObject
                processor.commandPrompt = "Select object:"
            } else if key == "A" || key == "ARCLENGTH" {
                state = .arcMinimum
                processor.commandPrompt = "Specify minimum arc length <\(formatted(RevCloudSettings.minimumArcLength))>:"
            } else if key == "R" || key == "RECTANGULAR" {
                RevCloudSettings.creationMode = .rectangular
                processor.commandPrompt = "Specify first corner point:"
            } else if key == "P" || key == "POLYGONAL" {
                RevCloudSettings.creationMode = .polygonal
                processor.commandPrompt = "Specify start point:"
            } else if key == "F" || key == "FREEHAND" {
                RevCloudSettings.creationMode = .freehand
                processor.commandPrompt = "Specify start point:"
            } else if key == "S" || key == "STYLE" {
                state = .selectingStyle
                processor.commandPrompt = "Select style [Normal/Calligraphy] <\(RevCloudSettings.style.rawValue)>:"
            } else if key == "M" || key == "MODIFY" {
                state = .modifySelect
                processor.commandPrompt = "Select revision cloud polyline:"
            } else if key == "L" || key == "LAYER" {
                state = .selectingLayer
                let current = RevCloudSettings.layerName.isEmpty ? "Use current" : RevCloudSettings.layerName
                processor.commandPrompt = "Enter revision cloud layer <\(current)>:"
            } else {
                processor.commandPrompt = "Unknown option."
            }
            return .handled

        case .arcMinimum:
            let value = trimmed.isEmpty ? RevCloudSettings.minimumArcLength : Double(trimmed)
            guard let minimum = value, minimum > 0 else {
                processor.commandPrompt = "Minimum arc length must be greater than zero:"
                return .handled
            }
            state = .arcMaximum(minimum)
            processor.commandPrompt = "Specify maximum arc length <\(formatted(RevCloudSettings.maximumArcLength))>:"
            return .handled

        case .arcMaximum(let minimum):
            let value = trimmed.isEmpty ? RevCloudSettings.maximumArcLength : Double(trimmed)
            guard let maximum = value, maximum >= minimum, maximum <= minimum * 3.0 else {
                processor.commandPrompt = "Maximum must be between minimum and three times minimum:"
                return .handled
            }
            RevCloudSettings.minimumArcLength = minimum
            RevCloudSettings.maximumArcLength = maximum
            UserDefaults.standard.set((minimum + maximum) * 0.5, forKey: "Zephyr.RevCloud.ApproximateArcLength")
            state = .topLevel
            showTopLevelPrompt(processor)
            return .handled

        case .selectingStyle:
            if key.isEmpty || key == "N" || key == "NORMAL" {
                RevCloudSettings.style = .normal
            } else if key == "C" || key == "CALLIGRAPHY" {
                RevCloudSettings.style = .calligraphy
            } else {
                processor.commandPrompt = "Select style [Normal/Calligraphy]:"
                return .handled
            }
            state = .topLevel
            showTopLevelPrompt(processor)
            return .handled

        case .selectingLayer:
            if trimmed == "." || key == "CURRENT" || key == "USECURRENT" {
                RevCloudSettings.layerName = ""
            } else if !trimmed.isEmpty {
                guard engine.document.allLayers.contains(where: {
                    $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                }) else {
                    processor.commandPrompt = "Layer not found. Enter an existing layer or . for current:"
                    return .handled
                }
                RevCloudSettings.layerName = trimmed
            }
            state = .topLevel
            showTopLevelPrompt(processor)
            return .handled

        case .polygonal(let points):
            if key == "C" || key == "CLOSE" || key.isEmpty {
                guard points.count >= 3 else {
                    processor.commandPrompt = "At least three points are required."
                    return .handled
                }
                return prepareNewCloud(guide: points, engine: engine, processor: processor)
            }
            return .handled

        case .freehand(let points):
            guard points.count >= 3 else {
                processor.commandPrompt = "Guide the cursor farther before finishing."
                return .handled
            }
            return prepareNewCloud(guide: points, engine: engine, processor: processor)

        case .reverse(var pending):
            if key == "Y" || key == "YES" {
                if case .polyline(let path, let color)? = pending.entity.localGeometry?.first {
                    pending.entity.localGeometry = [.polyline(path: RevCloudGeometry.reversed(path), color: color)]
                }
            } else if !(key.isEmpty || key == "N" || key == "NO") {
                processor.commandPrompt = "Reverse direction [Yes/No] <No>:"
                return .handled
            }
            commit(pending, engine: engine, processor: processor)
            return .finished

        case .modifyDrawing(let context, let startIndex, let guide):
            guard key.isEmpty, !guide.isEmpty,
                  let endIndex = RevCloudGeometry.closestVertexIndex(to: currentMouse, in: context.worldVertices),
                  endIndex != startIndex else { return .handled }
            var replacement = guide
            replacement.append(context.worldVertices[endIndex])
            state = .modifyErase(ModifyEraseContext(
                context: context,
                startIndex: startIndex,
                endIndex: endIndex,
                replacementGuide: replacement))
            processor.commandPrompt = "Pick side to erase:"
            return .handled

        default:
            return .handled
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let guideColor = makeCol32(0, 255, 128, 180)
        let cloudColor = makeCol32(255, 210, 0, 220)

        func draw(_ points: [Vector3], closed: Bool, color: UInt32, thickness: Float) {
            guard points.count >= 2 else { return }
            for index in 0..<(points.count - 1) {
                let a = EngineCameraManager.worldToScreen(worldX: points[index].x, worldY: points[index].y, cam: cam)
                let b = EngineCameraManager.worldToScreen(worldX: points[index + 1].x, worldY: points[index + 1].y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), color, thickness)
            }
            if closed, let first = points.first, let last = points.last {
                let a = EngineCameraManager.worldToScreen(worldX: last.x, worldY: last.y, cam: cam)
                let b = EngineCameraManager.worldToScreen(worldX: first.x, worldY: first.y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), color, thickness)
            }
        }

        switch state {
        case .rectangleSecond(let first):
            let points = [
                first,
                Vector3(x: currentMouse.x, y: first.y, z: 0),
                currentMouse,
                Vector3(x: first.x, y: currentMouse.y, z: 0)
            ]
            draw(points, closed: true, color: guideColor, thickness: 1.5)
            if let preview = makeCloud(guide: points, closed: true) {
                draw(preview.tessellatedPoints(), closed: false, color: cloudColor, thickness: 1.5)
            }

        case .polygonal(let points):
            draw(points + [currentMouse], closed: false, color: guideColor, thickness: 1.5)

        case .freehand(let points):
            draw(points + [currentMouse], closed: false, color: guideColor, thickness: 1.5)

        case .reverse(let pending):
            if case .polyline(let path, _)? = pending.entity.localGeometry?.first {
                draw(path.tessellatedPoints(), closed: false, color: cloudColor, thickness: 2.0)
            }

        case .modifyDrawing(_, _, let points):
            draw(points + [currentMouse], closed: false, color: guideColor, thickness: 2.0)

        default:
            break
        }
    }

    private func showTopLevelPrompt(_ processor: CADCommandProcessor) {
        processor.commandPrompt =
            "Minimum arc length: \(formatted(RevCloudSettings.minimumArcLength))  " +
            "Maximum arc length: \(formatted(RevCloudSettings.maximumArcLength))  " +
            "Style: \(RevCloudSettings.style.rawValue)  Type: \(RevCloudSettings.creationMode.displayName)\n" +
            "Specify first point or [Arc length/Object/Rectangular/Polygonal/Freehand/Style/Modify/Layer] <Object>:"
    }

    private func prepareNewCloud(
        guide: [Vector3], engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let path = makeCloud(guide: guide, closed: true) else {
            processor.commandPrompt = "Unable to create revision cloud from the selected points."
            return .handled
        }
        let pending = PendingCommit(
            entity: makeEntity(path: path, guide: guide, engine: engine),
            removeHandles: [],
            updateExisting: false,
            message: "Revision cloud created.")
        state = .reverse(pending)
        processor.commandPrompt = "Reverse direction [Yes/No] <No>:"
        return .handled
    }

    private func makeCloud(
        guide: [Vector3], closed: Bool,
        forcedBulgeSign: Double? = nil
    ) -> CADPolyline? {
        RevCloudGeometry.makeCloud(
            guide: guide,
            closed: closed,
            minimumArcLength: RevCloudSettings.minimumArcLength,
            maximumArcLength: RevCloudSettings.maximumArcLength,
            variance: RevCloudSettings.arcVarianceEnabled,
            style: RevCloudSettings.style,
            forcedBulgeSign: forcedBulgeSign)
    }

    private func makeEntity(
        path: CADPolyline,
        guide: [Vector3],
        engine: PhrostEngine
    ) -> CADEntity {
        var entity = CADEntity(
            layerID: resolvedLayerID(engine: engine),
            localGeometry: [.polyline(path: path)])
        entity.xdata["zephyr.revcloud"] = .bool(true)
        entity.xdata["zephyr.revcloud.arcLength"] = .double(RevCloudSettings.approximateArcLength)
        entity.xdata["zephyr.revcloud.style"] = .string(RevCloudSettings.style.rawValue)
        entity.xdata["dxf.closed"] = .bool(true)
        RevCloudGeometry.storeGenerationState(
            guide: guide,
            path: path,
            variance: RevCloudSettings.arcVarianceEnabled,
            minimumArcLength: RevCloudSettings.minimumArcLength,
            maximumArcLength: RevCloudSettings.maximumArcLength,
            in: &entity)
        return entity
    }

    private func resolvedLayerID(engine: PhrostEngine) -> UUID {
        let name = RevCloudSettings.layerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty,
           let layer = engine.document.allLayers.first(where: {
               $0.name.caseInsensitiveCompare(name) == .orderedSame
           }) {
            return layer.handle
        }
        return engine.document.activeLayerID ?? engine.document.allLayers.first?.handle ?? UUID()
    }

    private func commit(
        _ pending: PendingCommit, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        if pending.updateExisting {
            engine.document.updateEntity(pending.entity)
        } else if pending.removeHandles.isEmpty {
            engine.document.addEntity(pending.entity)
        } else {
            engine.document.replaceEntities(remove: pending.removeHandles, add: [pending.entity])
        }
        engine.cadSelection.select(pending.entity.handle)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = pending.message
    }

    private func objectGuide(for entity: CADEntity, document: CADDocument) -> [Vector3]? {
        guard entity.arrayData == nil,
              let geometry = document.resolvedGeometry(for: entity),
              geometry.count == 1
        else { return nil }
        let target = max(RevCloudSettings.approximateArcLength, 1e-6)
        let transform = entity.transform

        switch geometry[0] {
        case .rect(let origin, let size, _):
            return [
                transform.transformPoint(origin),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)),
                transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)),
                transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z))
            ]

        case .polygon(let points, _):
            return points.map(transform.transformPoint)

        case .polyline(let path, _):
            guard path.isClosed else { return nil }
            let world = path.tessellatedPoints().map(transform.transformPoint)
            return RevCloudGeometry.resampleClosedPath(world, targetLength: target)

        case .circle(let center, let radius, _):
            let worldCenter = transform.transformPoint(center)
            let xPoint = transform.transformPoint(center + Vector3(x: radius, y: 0, z: 0))
            let yPoint = transform.transformPoint(center + Vector3(x: 0, y: radius, z: 0))
            let axisU = xPoint - worldCenter
            let axisV = yPoint - worldCenter
            let perimeter = Double.pi * (3 * (axisU.magnitude + axisV.magnitude) - sqrt(
                max(0, (3 * axisU.magnitude + axisV.magnitude) * (axisU.magnitude + 3 * axisV.magnitude))))
            let count = min(4096, max(8, Int(round(perimeter / target))))
            return (0..<count).map { index in
                let angle = 2 * Double.pi * Double(index) / Double(count)
                return worldCenter + axisU * cos(angle) + axisV * sin(angle)
            }

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let worldCenter = transform.transformPoint(center)
            let worldMajorEnd = transform.transformPoint(center + majorAxis)
            let localMinor = Vector3(x: -majorAxis.y * minorRatio, y: majorAxis.x * minorRatio, z: majorAxis.z)
            let worldMinorEnd = transform.transformPoint(center + localMinor)
            let axisU = worldMajorEnd - worldCenter
            let axisV = worldMinorEnd - worldCenter
            let a = axisU.magnitude
            let b = axisV.magnitude
            let perimeter = Double.pi * (3 * (a + b) - sqrt(max(0, (3 * a + b) * (a + 3 * b))))
            let count = min(4096, max(8, Int(round(perimeter / target))))
            return (0..<count).map { index in
                let angle = 2 * Double.pi * Double(index) / Double(count)
                return worldCenter + axisU * cos(angle) + axisV * sin(angle)
            }

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            var points = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: controlPoints,
                weights: weights ?? Array(repeating: 1, count: controlPoints.count),
                chordTolerance: max(target * 0.05, 1e-5),
                maxDepth: 10,
                maxSegments: 8192)
            points = points.map(transform.transformPoint)
            guard points.count >= 3,
                  let first = points.first, let last = points.last,
                  first.distance(to: last) <= max(target * 0.5, 1e-5)
            else { return nil }
            return RevCloudGeometry.resampleClosedPath(points, targetLength: target)

        case .penStroke:
            return nil  // pen strokes are open paths, not convertible to revision clouds

        default:
            return nil
        }
    }

    private func modificationContext(at point: Vector3, engine: PhrostEngine) -> ModifyContext? {
        guard let handle = engine.cadSelection.hitTest(
            worldX: point.x, worldY: point.y,
            document: engine.document,
            threshold: max(3.0 / max(engine.camera.zoom, 1e-9), 1e-6),
            simplifyComplexBlocks: false),
              let entity = engine.document.entity(for: handle),
              let geometry = engine.document.resolvedGeometry(for: entity),
              RevCloudGeometry.isRevisionCloud(entity: entity, geometry: geometry),
              let path = RevCloudGeometry.cloudPath(from: entity, document: engine.document)
        else { return nil }

        let worldPath = path.transformed(by: entity.transform)
        let sign = worldPath.vertices.first(where: { abs($0.bulge) > 1e-9 })?.bulge.sign == .minus ? -1.0 : 1.0
        return ModifyContext(
            entity: entity,
            path: path,
            worldPath: worldPath,
            worldVertices: worldPath.vertices.map(\.position),
            style: RevCloudGeometry.style(of: entity, path: path),
            bulgeSign: sign)
    }

    private func buildModifiedEntity(
        _ pending: ModifyEraseContext, erasePoint: Vector3
    ) -> CADEntity? {
        let context = pending.context
        let count = context.worldPath.vertices.count
        guard count >= 3,
              pending.startIndex != pending.endIndex,
              let replacement = RevCloudGeometry.makeCloud(
                guide: pending.replacementGuide,
                closed: false,
                minimumArcLength: RevCloudSettings.minimumArcLength,
                maximumArcLength: RevCloudSettings.maximumArcLength,
                variance: RevCloudSettings.arcVarianceEnabled,
                style: context.style,
                forcedBulgeSign: context.bulgeSign)
        else { return nil }

        func forwardIndices(from start: Int, to end: Int) -> [Int] {
            var result = [start]
            var index = start
            while index != end, result.count <= count {
                index = (index + 1) % count
                result.append(index)
            }
            return result
        }

        func tessellatedChain(_ indices: [Int]) -> [Vector3] {
            guard indices.count >= 2 else { return [] }
            var result: [Vector3] = []
            for pair in 0..<(indices.count - 1) {
                let segment = indices[pair]
                let next = indices[pair + 1]
                guard context.worldPath.endVertexIndex(forSegment: segment) == next else { continue }
                if let arc = context.worldPath.arcParameters(forSegment: segment) {
                    let divisions = max(4, Int(ceil(abs(arc.sweep) * 12)))
                    for step in 0...divisions {
                        let point = context.worldPath.point(onSegment: segment, t: Double(step) / Double(divisions))
                        if result.last?.distance(to: point) ?? .infinity > 1e-9 { result.append(point) }
                    }
                } else {
                    let a = context.worldPath.vertices[segment].position
                    let b = context.worldPath.vertices[next].position
                    if result.last?.distance(to: a) ?? .infinity > 1e-9 { result.append(a) }
                    result.append(b)
                }
            }
            return result
        }

        let chainA = forwardIndices(from: pending.startIndex, to: pending.endIndex)
        let chainB = forwardIndices(from: pending.endIndex, to: pending.startIndex)
        let distanceA = RevCloudGeometry.distance(to: erasePoint, polyline: tessellatedChain(chainA))
        let distanceB = RevCloudGeometry.distance(to: erasePoint, polyline: tessellatedChain(chainB))
        let eraseA = distanceA <= distanceB
        let original = context.worldPath.vertices
        var finalVertices: [CADPolylineVertex]

        if eraseA {
            var replacementVertices = replacement.vertices
            guard !replacementVertices.isEmpty else { return nil }
            replacementVertices[replacementVertices.count - 1] = original[pending.endIndex]
            let retainedIntermediate = chainB.dropFirst().dropLast().map { original[$0] }
            finalVertices = replacementVertices + retainedIntermediate
        } else {
            let retained = chainA.dropLast().map { original[$0] }
            let reversedReplacement = RevCloudGeometry.reversed(replacement)
            finalVertices = retained + reversedReplacement.vertices.dropLast()
        }

        guard finalVertices.count >= 3 else { return nil }
        var updated = context.entity
        updated.transform = .identity
        updated.localGeometry = [.polyline(path: CADPolyline(
            vertices: finalVertices,
            isClosed: true,
            lineTypeGenerationEnabled: true))]
        updated.xdata["zephyr.revcloud"] = .bool(true)
        updated.xdata["zephyr.revcloud.arcLength"] = .double(RevCloudSettings.approximateArcLength)
        updated.xdata["zephyr.revcloud.style"] = .string(context.style.rawValue)
        updated.xdata["dxf.closed"] = .bool(true)
        RevCloudGeometry.clearGuideState(in: &updated)
        return updated
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

@MainActor
public final class RevCloudPropertiesCommand: FeatureCommand {
    private enum State {
        case selecting
        case waitingForLength(Set<UUID>)
    }

    private var state: State = .selecting

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        RevCloudSettings.ensureArcLengths(engine: engine)
        let selected = matchingHandles(engine.cadSelection.selectedHandles, document: engine.document)
        if selected.isEmpty {
            state = .selecting
            processor.commandPrompt = "Select revision cloud:"
        } else {
            state = .waitingForLength(selected)
            processor.commandPrompt = "Specify approximate arc chord length <\(String(format: "%.4f", RevCloudSettings.approximateArcLength))>:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .selecting
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard case .selecting = state,
              let handle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: max(3.0 / max(engine.camera.zoom, 1e-9), 1e-6),
                simplifyComplexBlocks: false),
              !matchingHandles([handle], document: engine.document).isEmpty
        else {
            processor.commandPrompt = "Select revision cloud:"
            return .handled
        }
        state = .waitingForLength([handle])
        processor.commandPrompt = "Specify approximate arc chord length <\(String(format: "%.4f", RevCloudSettings.approximateArcLength))>:"
        return .handled
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            return handleCommandText("", engine: engine, processor: processor)
        }
        return .continue
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard case .waitingForLength(let handles) = state else { return .handled }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? RevCloudSettings.approximateArcLength : Double(trimmed)
        guard let target, target > 0 else {
            processor.commandPrompt = "Arc chord length must be greater than zero:"
            return .handled
        }

        var updated: [CADEntity] = []
        for handle in handles {
            guard var entity = engine.document.entity(for: handle),
                  var localGeometry = entity.localGeometry,
                  let primitiveIndex = localGeometry.firstIndex(where: { primitive in
                      if case .polyline = primitive { return true }
                      return false
                  }),
                  case .polyline(let path, let color) = localGeometry[primitiveIndex]
            else { continue }

            let style = RevCloudGeometry.style(of: entity, path: path)
            let sign = path.vertices.first(where: { abs($0.bulge) > 1e-9 })?.bulge.sign == .minus
                ? -1.0 : 1.0
            let guide = RevCloudGeometry.guidePoints(of: entity, path: path)
                ?? RevCloudGeometry.resampleClosedPath(
                    path.vertices.map(\.position), targetLength: target)
            let variance = RevCloudGeometry.storedVariance(of: entity)
            guard let regenerated = RevCloudGeometry.makeCloud(
                guide: guide,
                closed: true,
                minimumArcLength: target * (2.0 / 3.0),
                maximumArcLength: target * (4.0 / 3.0),
                variance: variance,
                style: style,
                forcedBulgeSign: sign)
            else { continue }

            localGeometry[primitiveIndex] = .polyline(path: regenerated, color: color)
            entity.localGeometry = localGeometry
            entity.xdata["zephyr.revcloud"] = .bool(true)
            entity.xdata["zephyr.revcloud.arcLength"] = .double(target)
            entity.xdata["zephyr.revcloud.style"] = .string(style.rawValue)
            RevCloudGeometry.storeGenerationState(
                guide: guide,
                path: regenerated,
                variance: variance,
                minimumArcLength: target * (2.0 / 3.0),
                maximumArcLength: target * (4.0 / 3.0),
                in: &entity)
            updated.append(entity)
        }

        guard !updated.isEmpty else {
            processor.commandPrompt = "No revision clouds were updated."
            return .finished
        }
        engine.document.replaceEntities(remove: Set(updated.map(\.handle)), add: updated)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Updated \(updated.count) revision cloud(s)."
        return .finished
    }

    private func matchingHandles(_ handles: Set<UUID>, document: CADDocument) -> Set<UUID> {
        Set(handles.filter { handle in
            guard let entity = document.entity(for: handle),
                  let geometry = document.resolvedGeometry(for: entity)
            else { return false }
            return RevCloudGeometry.isRevisionCloud(entity: entity, geometry: geometry)
        })
    }
}

@MainActor
public final class RevCloudVariableCommand: FeatureCommand {
    public enum Variable: Sendable {
        case createMode
        case approximateArcLength
        case minimumArcLength
        case maximumArcLength
        case arcVariance
        case grips
        case layer
        case deleteObject

        var name: String {
            switch self {
            case .createMode: return "REVCLOUDCREATEMODE"
            case .approximateArcLength: return "REVCLOUDAPPROXARCLEN"
            case .minimumArcLength: return "REVCLOUDMINARCLENGTH"
            case .maximumArcLength: return "REVCLOUDMAXARCLENGTH"
            case .arcVariance: return "REVCLOUDARCVARIANCE"
            case .grips: return "REVCLOUDGRIPS"
            case .layer: return "REVCLOUDLAYER"
            case .deleteObject: return "DELOBJ"
            }
        }
    }

    private let variable: Variable

    public init(_ variable: Variable) {
        self.variable = variable
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        RevCloudSettings.ensureArcLengths(engine: engine)
        processor.commandPrompt = "Enter new value for \(variable.name) <\(currentValue)>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .handled }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            return .finished
        }
        return .continue
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .finished }
        let key = value.uppercased()

        switch variable {
        case .createMode:
            let mode: RevCloudCreationMode?
            if let raw = Int(value) { mode = RevCloudCreationMode(rawValue: raw) }
            else if key.hasPrefix("F") { mode = .freehand }
            else if key.hasPrefix("R") { mode = .rectangular }
            else if key.hasPrefix("P") { mode = .polygonal }
            else { mode = nil }
            guard let mode else { return invalid(processor, "Use 0/Freehand, 1/Rectangular, or 2/Polygonal.") }
            RevCloudSettings.creationMode = mode

        case .approximateArcLength:
            guard let number = Double(value), number > 0 else { return invalid(processor, "Value must be greater than zero.") }
            RevCloudSettings.approximateArcLength = number

        case .minimumArcLength:
            guard let number = Double(value), number > 0,
                  RevCloudSettings.maximumArcLength >= number,
                  RevCloudSettings.maximumArcLength <= number * 3
            else { return invalid(processor, "Minimum must be positive and no greater than maximum; maximum cannot exceed three times minimum.") }
            RevCloudSettings.minimumArcLength = number

        case .maximumArcLength:
            guard let number = Double(value),
                  number >= RevCloudSettings.minimumArcLength,
                  number <= RevCloudSettings.minimumArcLength * 3
            else { return invalid(processor, "Maximum must be between minimum and three times minimum.") }
            RevCloudSettings.maximumArcLength = number

        case .arcVariance:
            guard let bool = parseBool(value) else { return invalid(processor, "Use 0/1 or Off/On.") }
            RevCloudSettings.arcVarianceEnabled = bool

        case .grips:
            guard let bool = parseBool(value) else { return invalid(processor, "Use 0/1 or Off/On.") }
            RevCloudSettings.gripsEnabled = bool

        case .layer:
            if value == "." || key == "CURRENT" || key == "USE CURRENT" {
                RevCloudSettings.layerName = ""
            } else {
                guard engine.document.allLayers.contains(where: {
                    $0.name.caseInsensitiveCompare(value) == .orderedSame
                }) else { return invalid(processor, "Layer not found. Use . for current layer.") }
                RevCloudSettings.layerName = value
            }

        case .deleteObject:
            guard let bool = parseBool(value) else { return invalid(processor, "Use 0/1 or Off/On.") }
            RevCloudSettings.deleteSourceObject = bool
        }

        processor.commandPrompt = "\(variable.name) = \(currentValue)"
        return .finished
    }

    private var currentValue: String {
        switch variable {
        case .createMode: return "\(RevCloudSettings.creationMode.rawValue)"
        case .approximateArcLength: return String(format: "%.4f", RevCloudSettings.approximateArcLength)
        case .minimumArcLength: return String(format: "%.4f", RevCloudSettings.minimumArcLength)
        case .maximumArcLength: return String(format: "%.4f", RevCloudSettings.maximumArcLength)
        case .arcVariance: return RevCloudSettings.arcVarianceEnabled ? "1" : "0"
        case .grips: return RevCloudSettings.gripsEnabled ? "1" : "0"
        case .layer: return RevCloudSettings.layerName.isEmpty ? "Use current" : RevCloudSettings.layerName
        case .deleteObject: return RevCloudSettings.deleteSourceObject ? "1" : "0"
        }
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "1", "ON", "YES", "TRUE": return true
        case "0", "OFF", "NO", "FALSE": return false
        default: return nil
        }
    }

    private func invalid(_ processor: CADCommandProcessor, _ message: String) -> CommandResult {
        processor.commandPrompt = "\(message) Enter new value for \(variable.name) <\(currentValue)>:"
        return .handled
    }
}

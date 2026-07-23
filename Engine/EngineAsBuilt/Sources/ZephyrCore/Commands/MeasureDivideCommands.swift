import Foundation
import CSDL3

@MainActor
public final class MeasureDivideCommand: FeatureCommand {
    public enum Operation: Sendable, Equatable {
        case measure
        case divide
    }

    private enum Step {
        case selectObject
        case valueOrBlock
        case blockName
        case blockAlignment
        case blockValue
        case done
    }

    private enum Output {
        case points
        case block(UUID, align: Bool)
    }

    private struct CurvePath {
        let points: [Vector3]
        let cumulative: [Double]
        let totalLength: Double
        let isClosed: Bool

        init?(points rawPoints: [Vector3], isClosed: Bool) {
            guard !rawPoints.isEmpty else { return nil }

            var points: [Vector3] = []
            points.reserveCapacity(rawPoints.count + 1)
            for point in rawPoints where point.x.isFinite && point.y.isFinite && point.z.isFinite {
                if let last = points.last, last.distance(to: point) <= 1e-9 { continue }
                points.append(point)
            }

            guard points.count >= 2 else { return nil }
            if isClosed, let first = points.first, let last = points.last,
               first.distance(to: last) > 1e-9 {
                points.append(first)
            }

            var cumulative = [Double](repeating: 0, count: points.count)
            for index in 1..<points.count {
                cumulative[index] = cumulative[index - 1] + points[index - 1].distance(to: points[index])
            }

            guard let total = cumulative.last, total > 1e-9 else { return nil }
            self.points = points
            self.cumulative = cumulative
            self.totalLength = total
            self.isClosed = isClosed
        }

        func pointAndTangent(at requestedDistance: Double) -> (point: Vector3, tangent: Vector3) {
            var distance = requestedDistance
            if isClosed {
                distance = distance.truncatingRemainder(dividingBy: totalLength)
                if distance < 0 { distance += totalLength }
            } else {
                distance = max(0, min(totalLength, distance))
            }

            if distance <= 1e-12 {
                return (points[0], nonZeroTangent(startingAt: 0, direction: 1))
            }
            if distance >= totalLength - 1e-12 {
                return (points[points.count - 1], nonZeroTangent(startingAt: points.count - 2, direction: -1))
            }

            var lower = 0
            var upper = cumulative.count - 1
            while lower + 1 < upper {
                let middle = (lower + upper) / 2
                if cumulative[middle] <= distance {
                    lower = middle
                } else {
                    upper = middle
                }
            }

            let segmentLength = cumulative[upper] - cumulative[lower]
            guard segmentLength > 1e-12 else {
                return (points[lower], nonZeroTangent(startingAt: lower, direction: 1))
            }
            let t = (distance - cumulative[lower]) / segmentLength
            let start = points[lower]
            let end = points[upper]
            return (start + (end - start) * t, end - start)
        }

        private func nonZeroTangent(startingAt index: Int, direction: Int) -> Vector3 {
            var current = index
            while current >= 0 && current + 1 < points.count {
                let tangent = points[current + 1] - points[current]
                if tangent.magnitudeSquared > 1e-18 {
                    return tangent
                }
                current += direction
            }
            return Vector3(x: 1, y: 0, z: 0)
        }
    }

    private let operation: Operation
    private var step: Step = .selectObject
    private var selectedPath: CurvePath?
    private var selectedBlockID: UUID?
    private var alignBlock = true

    public init(operation: Operation) {
        self.operation = operation
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        reset()
        processor.commandPrompt = selectionPrompt
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        reset()
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard step == .selectObject else { return .handled }

        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: false
        ), let entity = engine.document.entity(for: handle),
           let path = makePath(
            entity: entity,
            selectionPoint: Vector3(x: worldX, y: worldY, z: 0),
            snapAngleDegrees: engine.snap.snapAngle,
            document: engine.document
           ) else {
            processor.commandPrompt = "Select a line, polyline, arc, circle, ellipse, spline, or rectangle"
            return .handled
        }

        selectedPath = path
        engine.cadSelection.select(handle)
        step = .valueOrBlock
        processor.commandPrompt = valueOrBlockPrompt
        return .handled
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch (step, scancode) {
        case (.valueOrBlock, SDL_SCANCODE_B):
            step = .blockName
            processor.commandPrompt = "Enter name of block to insert:"
            return .handled
        case (.blockAlignment, SDL_SCANCODE_Y):
            return acceptBlockAlignment(true, processor: processor)
        case (.blockAlignment, SDL_SCANCODE_N):
            return acceptBlockAlignment(false, processor: processor)
        case (.blockAlignment, SDL_SCANCODE_RETURN),
             (.blockAlignment, SDL_SCANCODE_KP_ENTER):
            return acceptBlockAlignment(true, processor: processor)
        case (_, SDL_SCANCODE_RETURN), (_, SDL_SCANCODE_KP_ENTER):
            return .handled
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch step {
        case .selectObject:
            processor.commandPrompt = selectionPrompt
            return .handled

        case .valueOrBlock:
            if value.caseInsensitiveCompare("B") == .orderedSame ||
                value.caseInsensitiveCompare("BLOCK") == .orderedSame {
                step = .blockName
                processor.commandPrompt = "Enter name of block to insert:"
                return .handled
            }
            return createOutput(from: value, output: .points, engine: engine, processor: processor)

        case .blockName:
            guard !value.isEmpty,
                  let block = engine.document.allBlocks.first(where: {
                      !$0.isInternalTableDisplayBlock && $0.name.caseInsensitiveCompare(value) == .orderedSame
                  }) else {
                processor.commandPrompt = "Block not found. Enter name of block to insert:"
                return .handled
            }
            selectedBlockID = block.handle
            step = .blockAlignment
            processor.commandPrompt = "Align block with object? [Yes/No] <Yes>:"
            return .handled

        case .blockAlignment:
            switch value.lowercased() {
            case "", "y", "yes":
                return acceptBlockAlignment(true, processor: processor)
            case "n", "no":
                return acceptBlockAlignment(false, processor: processor)
            default:
                processor.commandPrompt = "Align block with object? [Yes/No] <Yes>:"
                return .handled
            }

        case .blockValue:
            guard let blockID = selectedBlockID else {
                step = .blockName
                processor.commandPrompt = "Enter name of block to insert:"
                return .handled
            }
            return createOutput(
                from: value,
                output: .block(blockID, align: alignBlock),
                engine: engine,
                processor: processor)

        case .done:
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
    public func getDrawingSnapPoints() -> [Vector3] { [] }

    private var selectionPrompt: String {
        switch operation {
        case .measure: return "Select object to measure"
        case .divide: return "Select object to divide"
        }
    }

    private var valueOrBlockPrompt: String {
        switch operation {
        case .measure: return "Specify length of segment or [Block]:"
        case .divide: return "Enter number of segments or [Block]:"
        }
    }

    private var numericPrompt: String {
        switch operation {
        case .measure: return "Specify length of segment:"
        case .divide: return "Enter number of segments:"
        }
    }

    private func acceptBlockAlignment(
        _ align: Bool,
        processor: CADCommandProcessor
    ) -> CommandResult {
        alignBlock = align
        step = .blockValue
        processor.commandPrompt = numericPrompt
        return .handled
    }

    private func createOutput(
        from text: String,
        output: Output,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard let path = selectedPath else {
            step = .selectObject
            processor.commandPrompt = selectionPrompt
            return .handled
        }

        let distances: [Double]
        switch operation {
        case .measure:
            guard let spacing = Double(text), spacing.isFinite, spacing > 0 else {
                processor.commandPrompt = "Segment length must be greater than zero:"
                return .handled
            }
            let count = Int(floor((path.totalLength - max(1e-9, path.totalLength * 1e-12)) / spacing))
            guard count <= 100_000 else {
                processor.commandPrompt = "Segment length would create more than 100000 objects. Enter a larger length:"
                return .handled
            }
            distances = count > 0 ? (1...count).map { Double($0) * spacing } : []

        case .divide:
            guard let raw = Double(text), raw.isFinite,
                  raw.rounded(.towardZero) == raw,
                  raw >= 2, raw <= 32_767 else {
                processor.commandPrompt = "Number of segments must be an integer from 2 through 32767:"
                return .handled
            }
            let segments = Int(raw)
            distances = (1..<segments).map { path.totalLength * Double($0) / Double(segments) }
        }

        guard !distances.isEmpty else {
            print("[CAD] No points or blocks were created because the interval does not fit on the selected object.")
            step = .done
            return .finished
        }

        guard let layerID = engine.document.activeLayerID ?? engine.document.layersView.first?.handle else {
            processor.commandPrompt = "No active layer is available"
            return .handled
        }

        var entities: [CADEntity] = []
        entities.reserveCapacity(distances.count)
        for distance in distances {
            let sample = path.pointAndTangent(at: distance)
            switch output {
            case .points:
                entities.append(CADEntity(
                    layerID: layerID,
                    localGeometry: [.point(position: sample.point)]
                ))

            case .block(let blockID, let align):
                let rotation = align && sample.tangent.magnitudeSquared > 1e-18
                    ? atan2(sample.tangent.y, sample.tangent.x)
                    : 0
                let transform = Transform3D.translated(by: sample.point)
                    .multiplying(by: Transform3D.rotated(by: rotation))
                entities.append(CADEntity(
                    layerID: layerID,
                    blockID: blockID,
                    transform: transform
                ))
            }
        }

        engine.document.addEntities(entities)
        engine.cadSelection.clearSelection()
        for entity in entities {
            engine.cadSelection.addToSelection(entity.handle)
        }
        engine.tabManager.markActiveDirty()
        print("[CAD] \(operationName) created \(entities.count) \(outputName(output, count: entities.count)).")
        step = .done
        return .finished
    }

    private var operationName: String {
        switch operation {
        case .measure: return "MEASURE"
        case .divide: return "DIVIDE"
        }
    }

    private func outputName(_ output: Output, count: Int) -> String {
        switch output {
        case .points: return count == 1 ? "point" : "points"
        case .block: return count == 1 ? "block reference" : "block references"
        }
    }

    private func reset() {
        step = .selectObject
        selectedPath = nil
        selectedBlockID = nil
        alignBlock = true
    }

    private func makePath(
        entity: CADEntity,
        selectionPoint: Vector3,
        snapAngleDegrees: Double,
        document: CADDocument
    ) -> CurvePath? {
        guard entity.blockID == nil,
              entity.arrayData == nil,
              let geometry = document.resolvedGeometry(for: entity) else { return nil }

        var candidate: (points: [Vector3], closed: Bool, circleCenter: Vector3?)?
        for primitive in geometry {
            guard let sampled = samplePrimitive(primitive) else { continue }
            if candidate != nil { return nil }
            candidate = sampled
        }
        guard var sampled = candidate else { return nil }

        sampled.points = sampled.points.map { entity.transform.transformPoint($0) }
        if let localCenter = sampled.circleCenter {
            let center = entity.transform.transformPoint(localCenter)
            sampled.points = rebaseClosedPoints(
                sampled.points,
                center: center,
                angle: snapAngleDegrees * .pi / 180
            )
        }

        let endpointDistance = sampled.points.first?.distance(to: sampled.points.last ?? .zero)
            ?? Double.infinity
        let inferredClosed = sampled.closed || (sampled.points.count > 2 && endpointDistance <= 1e-8)

        if operation == .measure, !inferredClosed,
           let first = sampled.points.first, let last = sampled.points.last,
           selectionPoint.distance(to: last) < selectionPoint.distance(to: first) {
            sampled.points.reverse()
        }

        return CurvePath(points: sampled.points, isClosed: inferredClosed)
    }

    private func samplePrimitive(
        _ primitive: CADPrimitive
    ) -> (points: [Vector3], closed: Bool, circleCenter: Vector3?)? {
        switch primitive {
        case .line(let start, let end, _):
            return ([start, end], false, nil)

        case .rect(let origin, let size, _):
            let points = [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
                origin
            ]
            return (points, true, nil)

        case .polygon(let points, _):
            guard let first = points.first, points.count >= 2 else { return nil }
            let needsClosingPoint = (points.last?.distance(to: first) ?? 0) > 1e-9
            return (points + (needsClosingPoint ? [first] : []), true, nil)

        case .polyline(let path, _):
            return (path.tessellatedPoints(segmentsPerRadian: 96), path.isClosed, nil)

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            guard radius > 1e-12 else { return nil }
            var sweep = endAngle - startAngle
            while sweep <= 0 { sweep += 2 * .pi }
            let segments = max(32, Int(ceil(abs(sweep) * 128 / .pi)))
            let points = (0...segments).map { index in
                let angle = startAngle + sweep * Double(index) / Double(segments)
                return Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius,
                    z: center.z
                )
            }
            return (points, false, nil)

        case .circle(let center, let radius, _):
            guard radius > 1e-12 else { return nil }
            let segments = 1024
            let points = (0...segments).map { index in
                let angle = 2 * .pi * Double(index) / Double(segments)
                return Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius,
                    z: center.z
                )
            }
            return (points, true, center)

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            guard majorAxis.magnitude > 1e-12, abs(minorRatio) > 1e-12 else { return nil }
            let minorAxis = Vector3(
                x: -majorAxis.y * minorRatio,
                y: majorAxis.x * minorRatio,
                z: majorAxis.z * minorRatio
            )
            let segments = 1024
            let points = (0...segments).map { index in
                let angle = 2 * .pi * Double(index) / Double(segments)
                return center + majorAxis * cos(angle) + minorAxis * sin(angle)
            }
            return (points, true, nil)

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            guard controlPoints.count >= 2 else { return nil }
            let bounds = BoundingBox3D(from: controlPoints)
            let extent = max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)
            let tolerance = max(1e-7, extent * 1e-6)
            var points = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: controlPoints,
                weights: weights,
                chordTolerance: tolerance,
                maxDepth: 14,
                maxSegments: 32_768
            )
            if points.count < 2 {
                points = NURBSEvaluator.evaluateByKnotSpans(
                    degree: degree,
                    knots: knots,
                    controlPoints: controlPoints,
                    weights: weights,
                    segmentsPerSpan: 128
                )
            }
            guard points.count >= 2 else { return nil }
            let endpointDistance = points.first?.distance(to: points.last ?? .zero)
                ?? Double.infinity
            let closed = endpointDistance <= max(1e-8, extent * 1e-8)
            return (points, closed, nil)

        default:
            return nil
        }
    }

    private func rebaseClosedPoints(
        _ points: [Vector3],
        center: Vector3,
        angle: Double
    ) -> [Vector3] {
        guard points.count > 2 else { return points }
        var unique = points
        if let first = unique.first, let last = unique.last, first.distance(to: last) <= 1e-9 {
            unique.removeLast()
        }
        guard !unique.isEmpty else { return points }

        let twoPi = 2 * Double.pi
        func angleDifference(_ lhs: Double, _ rhs: Double) -> Double {
            var difference = (lhs - rhs).truncatingRemainder(dividingBy: twoPi)
            if difference > .pi { difference -= twoPi }
            if difference < -.pi { difference += twoPi }
            return abs(difference)
        }

        let startIndex = unique.indices.min { lhs, rhs in
            let left = unique[lhs] - center
            let right = unique[rhs] - center
            return angleDifference(atan2(left.y, left.x), angle) <
                angleDifference(atan2(right.y, right.x), angle)
        } ?? 0

        var rebased = Array(unique[startIndex...])
        if startIndex > 0 { rebased.append(contentsOf: unique[..<startIndex]) }
        if let first = rebased.first { rebased.append(first) }
        return rebased
    }
}

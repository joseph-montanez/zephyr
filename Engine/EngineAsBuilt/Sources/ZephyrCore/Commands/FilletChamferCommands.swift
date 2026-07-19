import Foundation
import CSDL3
import ImGui
import SwiftSDL

private let cornerTolerance = 1e-8
private let cornerTwoPi = 2.0 * Double.pi

private func cornerNormalizeAngle(_ value: Double) -> Double {
    var result = value.truncatingRemainder(dividingBy: cornerTwoPi)
    if result < 0 { result += cornerTwoPi }
    return result
}

private func cornerSignedAngle(_ value: Double) -> Double {
    var result = value.truncatingRemainder(dividingBy: cornerTwoPi)
    if result <= -.pi { result += cornerTwoPi }
    if result > .pi { result -= cornerTwoPi }
    return result
}

private func cornerVector(_ a: Vector3, _ b: Vector3) -> Vector3 {
    Vector3(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
}

private func cornerPoint(_ origin: Vector3, _ direction: Vector3, _ distance: Double) -> Vector3 {
    Vector3(
        x: origin.x + direction.x * distance,
        y: origin.y + direction.y * distance,
        z: origin.z + direction.z * distance)
}

private func cornerDot(_ a: Vector3, _ b: Vector3) -> Double {
    a.x * b.x + a.y * b.y
}

private func cornerCross(_ a: Vector3, _ b: Vector3) -> Double {
    a.x * b.y - a.y * b.x
}

private func cornerLength(_ value: Vector3) -> Double {
    hypot(value.x, value.y)
}

private func cornerUnit(_ value: Vector3) -> Vector3? {
    let length = cornerLength(value)
    guard length > cornerTolerance else { return nil }
    return Vector3(x: value.x / length, y: value.y / length, z: 0)
}

private func cornerDistanceSquared(_ a: Vector3, _ b: Vector3) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return dx * dx + dy * dy
}

private func cornerProjection(
    of point: Vector3,
    ontoLineAt origin: Vector3,
    direction: Vector3
) -> Vector3 {
    let t = cornerDot(cornerVector(origin, point), direction)
    return cornerPoint(origin, direction, t)
}

private func cornerLineIntersection(
    _ origin1: Vector3,
    _ direction1: Vector3,
    _ origin2: Vector3,
    _ direction2: Vector3
) -> Vector3? {
    let denominator = cornerCross(direction1, direction2)
    guard abs(denominator) > cornerTolerance else { return nil }
    let delta = cornerVector(origin1, origin2)
    let t = cornerCross(delta, direction2) / denominator
    return cornerPoint(origin1, direction1, t)
}

private func cornerLineCircleIntersections(
    lineOrigin: Vector3,
    lineDirection: Vector3,
    circleCenter: Vector3,
    circleRadius: Double
) -> [Vector3] {
    let delta = cornerVector(circleCenter, lineOrigin)
    let b = 2.0 * cornerDot(delta, lineDirection)
    let c = cornerDot(delta, delta) - circleRadius * circleRadius
    let discriminant = b * b - 4.0 * c
    if discriminant < -cornerTolerance { return [] }
    if abs(discriminant) <= cornerTolerance {
        let t = -b * 0.5
        return [cornerPoint(lineOrigin, lineDirection, t)]
    }
    let root = sqrt(max(0, discriminant))
    return [
        cornerPoint(lineOrigin, lineDirection, (-b - root) * 0.5),
        cornerPoint(lineOrigin, lineDirection, (-b + root) * 0.5),
    ]
}

private func cornerCircleCircleIntersections(
    center1: Vector3,
    radius1: Double,
    center2: Vector3,
    radius2: Double
) -> [Vector3] {
    let delta = cornerVector(center1, center2)
    let distance = cornerLength(delta)
    guard distance > cornerTolerance else { return [] }
    guard distance <= radius1 + radius2 + cornerTolerance else { return [] }
    guard distance + min(radius1, radius2) + cornerTolerance >= max(radius1, radius2) else { return [] }
    let a = (radius1 * radius1 - radius2 * radius2 + distance * distance) / (2.0 * distance)
    let hSquared = radius1 * radius1 - a * a
    if hSquared < -cornerTolerance { return [] }
    let unit = Vector3(x: delta.x / distance, y: delta.y / distance, z: 0)
    let base = cornerPoint(center1, unit, a)
    if abs(hSquared) <= cornerTolerance { return [base] }
    let h = sqrt(max(0, hSquared))
    let normal = Vector3(x: -unit.y, y: unit.x, z: 0)
    return [cornerPoint(base, normal, h), cornerPoint(base, normal, -h)]
}

private enum CornerSupport {
    case line(origin: Vector3, direction: Vector3)
    case circle(center: Vector3, radius: Double)
}

private enum CornerPickKind {
    case line(localStart: Vector3, localEnd: Vector3, color: ColorRGBA?)
    case ray(localStart: Vector3, localDirection: Vector3, color: ColorRGBA?)
    case arc(localCenter: Vector3, localRadius: Double, localStart: Double, localEnd: Double, color: ColorRGBA?)
    case circle(localCenter: Vector3, localRadius: Double, color: ColorRGBA?)
    case polyline(path: CADPolyline, segmentIndex: Int, color: ColorRGBA?)
}

private struct CornerPick {
    let handle: UUID
    let primitiveIndex: Int
    let segmentIndex: Int?
    let entity: CADEntity
    let primitive: CADPrimitive
    let kind: CornerPickKind
    let support: CornerSupport
    let pickWorld: Vector3
    let nearestWorld: Vector3


    var isLineLike: Bool {
        let pickKind = kind
        switch pickKind {
        case .line, .ray:
            return true
        case .polyline(let path, let segmentIndex, _):
            return path.arcParameters(forSegment: segmentIndex) == nil
        default:
            return false
        }
    }

    var isCircle: Bool {
        let pickKind = kind
        if case .circle = pickKind { return true }
        return false
    }

    var isCircularLike: Bool {
        let pickSupport = support
        switch pickSupport {
        case .circle: return true
        case .line: return false
        }
    }
}

private enum CornerPicker {
    @MainActor
    static func rawWorldPoint(engine: PhrostEngine) -> Vector3 {
        let (x, y) = engine.camera.screenToWorld(
            screenX: Float(engine.interaction.lastMouseX),
            screenY: Float(engine.interaction.lastMouseY),
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        return Vector3(x: x, y: y, z: 0)
    }

    @MainActor
    static func pick(
        at worldPoint: Vector3,
        engine: PhrostEngine,
        lineOnly: Bool
    ) -> CornerPick? {
        let document = engine.document
        guard let handle = CADHitTesting.hitTest(
            worldX: worldPoint.x,
            worldY: worldPoint.y,
            document: document,
            threshold: 12.0 / engine.camera.zoom,
            simplifyComplexBlocks: false),
              let entity = document.entity(for: handle),
              entity.blockID == nil,
              let geometry = entity.localGeometry
        else { return nil }

        var best: CornerPick?
        var bestDistance = Double.infinity

        for (primitiveIndex, primitive) in geometry.enumerated() {
            switch primitive {
            case .line(let localStart, let localEnd, let color):
                let worldStart = entity.transform.transformPoint(localStart)
                let worldEnd = entity.transform.transformPoint(localEnd)
                guard let direction = cornerUnit(cornerVector(worldStart, worldEnd)) else { continue }
                let nearest = nearestPointOnSegment(worldPoint, worldStart, worldEnd)
                let distance = cornerDistanceSquared(worldPoint, nearest)
                if distance < bestDistance {
                    bestDistance = distance
                    best = CornerPick(
                        handle: handle,
                        primitiveIndex: primitiveIndex,
                        segmentIndex: nil,
                        entity: entity,
                        primitive: primitive,
                        kind: .line(localStart: localStart, localEnd: localEnd, color: color),
                        support: .line(origin: worldStart, direction: direction),
                        pickWorld: worldPoint,
                        nearestWorld: nearest)
                }

            case .ray(let localStart, let localDirection, let color):
                let worldStart = entity.transform.transformPoint(localStart)
                let worldDirectionPoint = entity.transform.transformPoint(localStart + localDirection)
                guard let direction = cornerUnit(cornerVector(worldStart, worldDirectionPoint)) else { continue }
                let projectedDistance = max(0, cornerDot(cornerVector(worldStart, worldPoint), direction))
                let nearest = cornerPoint(worldStart, direction, projectedDistance)
                let distance = cornerDistanceSquared(worldPoint, nearest)
                if distance < bestDistance {
                    bestDistance = distance
                    best = CornerPick(
                        handle: handle,
                        primitiveIndex: primitiveIndex,
                        segmentIndex: nil,
                        entity: entity,
                        primitive: primitive,
                        kind: .ray(localStart: localStart, localDirection: localDirection, color: color),
                        support: .line(origin: worldStart, direction: direction),
                        pickWorld: worldPoint,
                        nearestWorld: nearest)
                }

            case .arc(let localCenter, let localRadius, let localStart, let localEnd, let color):
                guard !lineOnly,
                      let circular = circularWorldGeometry(
                        center: localCenter,
                        radius: localRadius,
                        startAngle: localStart,
                        endAngle: localEnd,
                        transform: entity.transform)
                else { continue }
                let nearest = nearestPointOnSignedArc(
                    worldPoint,
                    center: circular.center,
                    radius: circular.radius,
                    start: circular.start,
                    sweep: circular.sweep)
                let distance = cornerDistanceSquared(worldPoint, nearest)
                if distance < bestDistance {
                    bestDistance = distance
                    best = CornerPick(
                        handle: handle,
                        primitiveIndex: primitiveIndex,
                        segmentIndex: nil,
                        entity: entity,
                        primitive: primitive,
                        kind: .arc(
                            localCenter: localCenter,
                            localRadius: localRadius,
                            localStart: localStart,
                            localEnd: localEnd,
                            color: color),
                        support: .circle(center: circular.center, radius: circular.radius),
                        pickWorld: worldPoint,
                        nearestWorld: nearest)
                }

            case .circle(let localCenter, let localRadius, let color):
                guard !lineOnly,
                      let circular = circularWorldGeometry(
                        center: localCenter,
                        radius: localRadius,
                        startAngle: 0,
                        endAngle: cornerTwoPi,
                        transform: entity.transform)
                else { continue }
                let nearest = CADGeometryMath.nearestPointOnCircle(
                    to: worldPoint,
                    center: circular.center,
                    radius: circular.radius) ?? circular.center
                let distance = cornerDistanceSquared(worldPoint, nearest)
                if distance < bestDistance {
                    bestDistance = distance
                    best = CornerPick(
                        handle: handle,
                        primitiveIndex: primitiveIndex,
                        segmentIndex: nil,
                        entity: entity,
                        primitive: primitive,
                        kind: .circle(localCenter: localCenter, localRadius: localRadius, color: color),
                        support: .circle(center: circular.center, radius: circular.radius),
                        pickWorld: worldPoint,
                        nearestWorld: nearest)
                }

            case .polyline(let path, let color):
                guard path.hatchEdges.isEmpty else { continue }
                let worldPath = path.transformed(by: entity.transform)
                for segmentIndex in 0..<worldPath.segmentCount {
                    let nearest: Vector3
                    if let arc = worldPath.arcParameters(forSegment: segmentIndex) {
                        guard !lineOnly else { continue }
                        nearest = nearestPointOnSignedArc(
                            worldPoint,
                            center: arc.center,
                            radius: arc.radius,
                            start: arc.startAngle,
                            sweep: arc.sweep)
                    } else {
                        let start = worldPath.vertices[segmentIndex].position
                        let end = worldPath.vertices[worldPath.endVertexIndex(forSegment: segmentIndex)].position
                        nearest = nearestPointOnSegment(worldPoint, start, end)
                    }
                    let distance = cornerDistanceSquared(worldPoint, nearest)
                    guard distance < bestDistance else { continue }
                    let support: CornerSupport
                    if let arc = worldPath.arcParameters(forSegment: segmentIndex) {
                        support = .circle(center: arc.center, radius: arc.radius)
                    } else {
                        let start = worldPath.vertices[segmentIndex].position
                        let end = worldPath.vertices[worldPath.endVertexIndex(forSegment: segmentIndex)].position
                        guard let direction = cornerUnit(cornerVector(start, end)) else { continue }
                        support = .line(origin: start, direction: direction)
                    }
                    bestDistance = distance
                    best = CornerPick(
                        handle: handle,
                        primitiveIndex: primitiveIndex,
                        segmentIndex: segmentIndex,
                        entity: entity,
                        primitive: primitive,
                        kind: .polyline(path: path, segmentIndex: segmentIndex, color: color),
                        support: support,
                        pickWorld: worldPoint,
                        nearestWorld: nearest)
                }

            default:
                continue
            }
        }

        return best
    }

    private static func nearestPointOnSegment(
        _ point: Vector3,
        _ start: Vector3,
        _ end: Vector3
    ) -> Vector3 {
        let delta = cornerVector(start, end)
        let lengthSquared = cornerDot(delta, delta)
        guard lengthSquared > cornerTolerance else { return start }
        let t = max(0, min(1, cornerDot(cornerVector(start, point), delta) / lengthSquared))
        return Vector3(
            x: start.x + delta.x * t,
            y: start.y + delta.y * t,
            z: start.z + delta.z * t)
    }

    private static func nearestPointOnSignedArc(
        _ point: Vector3,
        center: Vector3,
        radius: Double,
        start: Double,
        sweep: Double
    ) -> Vector3 {
        let angle = atan2(point.y - center.y, point.x - center.x)
        let progress = signedArcProgress(angle: angle, start: start, sweep: sweep)
        if progress >= -cornerTolerance && progress <= abs(sweep) + cornerTolerance {
            return Vector3(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius,
                z: center.z)
        }
        let startPoint = Vector3(
            x: center.x + cos(start) * radius,
            y: center.y + sin(start) * radius,
            z: center.z)
        let endAngle = start + sweep
        let endPoint = Vector3(
            x: center.x + cos(endAngle) * radius,
            y: center.y + sin(endAngle) * radius,
            z: center.z)
        return cornerDistanceSquared(point, startPoint) <= cornerDistanceSquared(point, endPoint)
            ? startPoint : endPoint
    }

    private static func signedArcProgress(angle: Double, start: Double, sweep: Double) -> Double {
        if sweep >= 0 { return cornerNormalizeAngle(angle - start) }
        return cornerNormalizeAngle(start - angle)
    }

    private static func circularWorldGeometry(
        center: Vector3,
        radius: Double,
        startAngle: Double,
        endAngle: Double,
        transform: Transform3D
    ) -> (center: Vector3, radius: Double, start: Double, sweep: Double)? {
        let worldCenter = transform.transformPoint(center)
        let axisX = cornerVector(
            worldCenter,
            transform.transformPoint(Vector3(x: center.x + radius, y: center.y, z: center.z)))
        let axisY = cornerVector(
            worldCenter,
            transform.transformPoint(Vector3(x: center.x, y: center.y + radius, z: center.z)))
        let radiusX = cornerLength(axisX)
        let radiusY = cornerLength(axisY)
        guard radiusX > cornerTolerance,
              radiusY > cornerTolerance,
              abs(radiusX - radiusY) <= max(radiusX, radiusY) * 1e-6,
              abs(cornerDot(axisX, axisY)) <= radiusX * radiusY * 1e-6
        else { return nil }

        let localSpanRaw = endAngle - startAngle
        let isFullCircle = abs(localSpanRaw) >= cornerTwoPi - cornerTolerance
        var localSpan = localSpanRaw
        if !isFullCircle, localSpan < 0 { localSpan += cornerTwoPi }
        if isFullCircle { localSpan = cornerTwoPi }

        let localStartPoint = Vector3(
            x: center.x + cos(startAngle) * radius,
            y: center.y + sin(startAngle) * radius,
            z: center.z)
        let worldStartPoint = transform.transformPoint(localStartPoint)
        let worldStart = atan2(
            worldStartPoint.y - worldCenter.y,
            worldStartPoint.x - worldCenter.x)
        let orientation = cornerCross(axisX, axisY) >= 0 ? 1.0 : -1.0
        return (
            worldCenter,
            (radiusX + radiusY) * 0.5,
            worldStart,
            localSpan * orientation)
    }
}

private enum CornerOffsetLocus {
    case line(origin: Vector3, direction: Vector3)
    case circle(center: Vector3, radius: Double)
}

private struct CornerFilletSolution {
    let center: Vector3
    let radius: Double
    let tangent1: Vector3
    let tangent2: Vector3
    let arcStart: Double
    let arcEnd: Double
}

private struct CornerChamferSolution {
    let corner: Vector3
    let point1: Vector3
    let point2: Vector3
}

private enum CornerSolver {
    static func fillet(
        first: CornerPick,
        second: CornerPick,
        radius: Double
    ) -> CornerFilletSolution? {
        guard radius > cornerTolerance else { return nil }

        let firstSupport = first.support
        let secondSupport = second.support

        if first.isLineLike, second.isLineLike,
           case .line(let origin1, let direction1) = firstSupport,
           case .line(let origin2, let direction2) = secondSupport,
           abs(cornerCross(direction1, direction2)) <= cornerTolerance {
            return parallelLineFillet(
                first: first,
                second: second,
                origin1: origin1,
                direction1: direction1,
                origin2: origin2,
                direction2: direction2)
        }

        let loci1 = offsetLoci(for: firstSupport, radius: radius)
        let loci2 = offsetLoci(for: secondSupport, radius: radius)
        var best: CornerFilletSolution?
        var bestScore = Double.infinity

        for locus1 in loci1 {
            for locus2 in loci2 {
                for center in intersections(locus1, locus2) {
                    guard let tangent1 = tangentPoint(
                        support: firstSupport,
                        filletCenter: center,
                        filletRadius: radius),
                          let tangent2 = tangentPoint(
                            support: secondSupport,
                            filletCenter: center,
                            filletRadius: radius),
                          cornerDistanceSquared(tangent1, tangent2) > cornerTolerance * cornerTolerance
                    else { continue }

                    let arc = minorArc(center: center, startPoint: tangent1, endPoint: tangent2)
                    var score = cornerDistanceSquared(first.nearestWorld, tangent1)
                        + cornerDistanceSquared(second.nearestWorld, tangent2)
                    score += cornerDistanceSquared(first.pickWorld, tangent1) * 0.1
                    score += cornerDistanceSquared(second.pickWorld, tangent2) * 0.1

                    if score < bestScore {
                        bestScore = score
                        best = CornerFilletSolution(
                            center: center,
                            radius: radius,
                            tangent1: tangent1,
                            tangent2: tangent2,
                            arcStart: arc.start,
                            arcEnd: arc.end)
                    }
                }
            }
        }
        return best
    }

    static func zeroRadiusCorner(first: CornerPick, second: CornerPick) -> Vector3? {
        let candidates = supportIntersections(first.support, second.support)
        return candidates.min {
            cornerDistanceSquared($0, first.nearestWorld) + cornerDistanceSquared($0, second.nearestWorld)
                < cornerDistanceSquared($1, first.nearestWorld) + cornerDistanceSquared($1, second.nearestWorld)
        }
    }

    static func chamfer(
        first: CornerPick,
        second: CornerPick,
        distance1: Double,
        distance2: Double
    ) -> CornerChamferSolution? {
        let firstSupport = first.support
        let secondSupport = second.support

        guard first.isLineLike, second.isLineLike,
              case .line(let origin1, let direction1) = firstSupport,
              case .line(let origin2, let direction2) = secondSupport,
              let intersection = cornerLineIntersection(origin1, direction1, origin2, direction2),
              let retained1 = retainedDirection(selection: first, corner: intersection),
              let retained2 = retainedDirection(selection: second, corner: intersection)
        else { return nil }

        return CornerChamferSolution(
            corner: intersection,
            point1: cornerPoint(intersection, retained1, distance1),
            point2: cornerPoint(intersection, retained2, distance2))
    }

    static func retainedDirection(selection: CornerPick, corner: Vector3) -> Vector3? {
        let pickSupport = selection.support
        let projected = cornerProjection(
            of: selection.nearestWorld,
            ontoLineAt: corner,
            direction: lineDirection(pickSupport))
        var direction = cornerVector(corner, projected)
        if cornerLength(direction) <= cornerTolerance {
            direction = cornerVector(corner, selection.pickWorld)
        }
        return cornerUnit(direction)
    }

    static func lineDirection(_ support: CornerSupport) -> Vector3 {
        if case .line(_, let direction) = support { return direction }
        return Vector3(x: 1, y: 0, z: 0)
    }

    private static func offsetLoci(for support: CornerSupport, radius: Double) -> [CornerOffsetLocus] {
        switch support {
        case .line(let origin, let direction):
            let normal = Vector3(x: -direction.y, y: direction.x, z: 0)
            return [
                .line(origin: cornerPoint(origin, normal, radius), direction: direction),
                .line(origin: cornerPoint(origin, normal, -radius), direction: direction),
            ]
        case .circle(let center, let curveRadius):
            var radii = [curveRadius + radius]
            let inner = abs(curveRadius - radius)
            if inner > cornerTolerance, abs(inner - radii[0]) > cornerTolerance {
                radii.append(inner)
            }
            return radii.map { .circle(center: center, radius: $0) }
        }
    }

    private static func intersections(
        _ first: CornerOffsetLocus,
        _ second: CornerOffsetLocus
    ) -> [Vector3] {
        switch (first, second) {
        case (.line(let origin1, let direction1), .line(let origin2, let direction2)):
            return cornerLineIntersection(origin1, direction1, origin2, direction2).map { [$0] } ?? []
        case (.line(let origin, let direction), .circle(let center, let radius)),
             (.circle(let center, let radius), .line(let origin, let direction)):
            return cornerLineCircleIntersections(
                lineOrigin: origin,
                lineDirection: direction,
                circleCenter: center,
                circleRadius: radius)
        case (.circle(let center1, let radius1), .circle(let center2, let radius2)):
            return cornerCircleCircleIntersections(
                center1: center1,
                radius1: radius1,
                center2: center2,
                radius2: radius2)
        }
    }

    private static func supportIntersections(
        _ first: CornerSupport,
        _ second: CornerSupport
    ) -> [Vector3] {
        switch (first, second) {
        case (.line(let origin1, let direction1), .line(let origin2, let direction2)):
            return cornerLineIntersection(origin1, direction1, origin2, direction2).map { [$0] } ?? []
        case (.line(let origin, let direction), .circle(let center, let radius)),
             (.circle(let center, let radius), .line(let origin, let direction)):
            return cornerLineCircleIntersections(
                lineOrigin: origin,
                lineDirection: direction,
                circleCenter: center,
                circleRadius: radius)
        case (.circle(let center1, let radius1), .circle(let center2, let radius2)):
            return cornerCircleCircleIntersections(
                center1: center1,
                radius1: radius1,
                center2: center2,
                radius2: radius2)
        }
    }

    private static func tangentPoint(
        support: CornerSupport,
        filletCenter: Vector3,
        filletRadius: Double
    ) -> Vector3? {
        switch support {
        case .line(let origin, let direction):
            return cornerProjection(of: filletCenter, ontoLineAt: origin, direction: direction)
        case .circle(let center, let radius):
            let delta = cornerVector(center, filletCenter)
            let distance = cornerLength(delta)
            guard distance > cornerTolerance else { return nil }
            let x = (distance * distance + radius * radius - filletRadius * filletRadius) / (2.0 * distance)
            let unit = Vector3(x: delta.x / distance, y: delta.y / distance, z: 0)
            return cornerPoint(center, unit, x)
        }
    }

    private static func minorArc(
        center: Vector3,
        startPoint: Vector3,
        endPoint: Vector3
    ) -> (start: Double, end: Double) {
        let angle1 = atan2(startPoint.y - center.y, startPoint.x - center.x)
        let angle2 = atan2(endPoint.y - center.y, endPoint.x - center.x)
        let ccw = cornerNormalizeAngle(angle2 - angle1)
        if ccw <= .pi {
            return (angle1, angle1 + ccw)
        }
        return (angle2, angle2 + cornerTwoPi - ccw)
    }

    private static func parallelLineFillet(
        first: CornerPick,
        second: CornerPick,
        origin1: Vector3,
        direction1: Vector3,
        origin2: Vector3,
        direction2: Vector3
    ) -> CornerFilletSolution? {
        let alignment = cornerDot(direction1, direction2) >= 0 ? 1.0 : -1.0
        let direction = direction1
        let normal = Vector3(x: -direction.y, y: direction.x, z: 0)
        let signedSeparation = cornerDot(cornerVector(origin1, origin2), normal)
        let radius = abs(signedSeparation) * 0.5
        guard radius > cornerTolerance else { return nil }

        let parameter1 = cornerDot(cornerVector(origin1, first.nearestWorld), direction)
        let parameter2 = cornerDot(cornerVector(origin2, second.nearestWorld), direction)
        let parameter = (parameter1 + parameter2) * 0.5
        let tangent1 = cornerPoint(origin1, direction, parameter)
        let projectedSecond = cornerProjection(of: tangent1, ontoLineAt: origin2, direction: direction)
        let tangent2 = projectedSecond
        let center = Vector3(
            x: (tangent1.x + tangent2.x) * 0.5,
            y: (tangent1.y + tangent2.y) * 0.5,
            z: (tangent1.z + tangent2.z) * 0.5)

        let keep1 = cornerDot(cornerVector(tangent1, first.nearestWorld), direction)
        let keep2 = cornerDot(cornerVector(tangent2, second.nearestWorld), direction) * alignment
        let preferredBulgeDirection = keep1 + keep2 >= 0 ? -1.0 : 1.0
        let angle1 = atan2(tangent1.y - center.y, tangent1.x - center.x)
        let angle2 = atan2(tangent2.y - center.y, tangent2.x - center.x)
        let ccw = cornerNormalizeAngle(angle2 - angle1)
        let candidate1Mid = angle1 + ccw * 0.5
        let candidate2Sweep = cornerTwoPi - ccw
        let candidate2Mid = angle2 + candidate2Sweep * 0.5
        let radial1 = Vector3(x: cos(candidate1Mid), y: sin(candidate1Mid), z: 0)
        let radial2 = Vector3(x: cos(candidate2Mid), y: sin(candidate2Mid), z: 0)
        let preferred = cornerPoint(Vector3.zero, direction, preferredBulgeDirection)
        let arc: (Double, Double)
        if cornerDot(radial1, preferred) >= cornerDot(radial2, preferred) {
            arc = (angle1, angle1 + ccw)
        } else {
            arc = (angle2, angle2 + candidate2Sweep)
        }
        return CornerFilletSolution(
            center: center,
            radius: radius,
            tangent1: tangent1,
            tangent2: tangent2,
            arcStart: arc.0,
            arcEnd: arc.1)
    }
}

private enum CornerMutation {
    static func trimmedEntity(
        selection: CornerPick,
        to worldPoint: Vector3
    ) -> CADEntity? {
        var entity = selection.entity
        guard var geometry = entity.localGeometry,
              selection.primitiveIndex >= 0,
              selection.primitiveIndex < geometry.count
        else { return nil }

        let inverse = entity.transform.inverse()
        let localPoint = inverse.transformPoint(worldPoint)
        let replacement: CADPrimitive

        let pickKind = selection.kind

        switch pickKind {
        case .line(let localStart, let localEnd, let color):
            let worldStart = entity.transform.transformPoint(localStart)
            let worldEnd = entity.transform.transformPoint(localEnd)
            guard let direction = cornerUnit(cornerVector(worldStart, worldEnd)) else { return nil }
            let trimParameter = cornerDot(cornerVector(worldStart, worldPoint), direction)
            let pickParameter = cornerDot(cornerVector(worldStart, selection.nearestWorld), direction)
            if pickParameter <= trimParameter {
                replacement = .line(start: localStart, end: localPoint, color: color)
            } else {
                replacement = .line(start: localPoint, end: localEnd, color: color)
            }

        case .ray(let localStart, let localDirection, let color):
            let worldStart = entity.transform.transformPoint(localStart)
            let worldDirectionPoint = entity.transform.transformPoint(localStart + localDirection)
            guard let direction = cornerUnit(cornerVector(worldStart, worldDirectionPoint)) else { return nil }
            let trimParameter = cornerDot(cornerVector(worldStart, worldPoint), direction)
            let pickParameter = cornerDot(cornerVector(worldStart, selection.nearestWorld), direction)
            if pickParameter + cornerTolerance >= trimParameter {
                replacement = .ray(start: localPoint, direction: localDirection, color: color)
            } else {
                replacement = .line(start: localStart, end: localPoint, color: color)
            }

        case .arc(let localCenter, let localRadius, let localStart, let localEnd, let color):
            let trimAngle = atan2(localPoint.y - localCenter.y, localPoint.x - localCenter.x)
            let localPick = inverse.transformPoint(selection.nearestWorld)
            let pickAngle = atan2(localPick.y - localCenter.y, localPick.x - localCenter.x)
            var span = localEnd - localStart
            if span < 0 { span += cornerTwoPi }
            let trimProgress = cornerNormalizeAngle(trimAngle - localStart)
            let pickProgress = cornerNormalizeAngle(pickAngle - localStart)

            if trimProgress <= span + cornerTolerance {
                if pickProgress <= trimProgress {
                    replacement = .arc(
                        center: localCenter,
                        radius: localRadius,
                        startAngle: localStart,
                        endAngle: trimAngle,
                        color: color)
                } else {
                    replacement = .arc(
                        center: localCenter,
                        radius: localRadius,
                        startAngle: trimAngle,
                        endAngle: localEnd,
                        color: color)
                }
            } else {
                let localStartPoint = Vector3(
                    x: localCenter.x + cos(localStart) * localRadius,
                    y: localCenter.y + sin(localStart) * localRadius,
                    z: localCenter.z)
                let localEndPoint = Vector3(
                    x: localCenter.x + cos(localEnd) * localRadius,
                    y: localCenter.y + sin(localEnd) * localRadius,
                    z: localCenter.z)
                if cornerDistanceSquared(localPoint, localStartPoint)
                    <= cornerDistanceSquared(localPoint, localEndPoint) {
                    replacement = .arc(
                        center: localCenter,
                        radius: localRadius,
                        startAngle: trimAngle,
                        endAngle: localEnd,
                        color: color)
                } else {
                    replacement = .arc(
                        center: localCenter,
                        radius: localRadius,
                        startAngle: localStart,
                        endAngle: trimAngle,
                        color: color)
                }
            }

        case .circle:
            return entity

        case .polyline(var path, let segmentIndex, let color):
            guard segmentIndex >= 0, segmentIndex < path.segmentCount else { return nil }
            let endIndex = path.endVertexIndex(forSegment: segmentIndex)
            let worldPath = path.transformed(by: entity.transform)

            if let worldArc = worldPath.arcParameters(forSegment: segmentIndex),
               let localArc = path.arcParameters(forSegment: segmentIndex) {
                let worldPickAngle = atan2(
                    selection.nearestWorld.y - worldArc.center.y,
                    selection.nearestWorld.x - worldArc.center.x)
                let worldTrimAngle = atan2(
                    worldPoint.y - worldArc.center.y,
                    worldPoint.x - worldArc.center.x)
                let direction = worldArc.sweep >= 0 ? 1.0 : -1.0
                let pickProgress = direction > 0
                    ? cornerNormalizeAngle(worldPickAngle - worldArc.startAngle)
                    : cornerNormalizeAngle(worldArc.startAngle - worldPickAngle)
                let trimProgress = direction > 0
                    ? cornerNormalizeAngle(worldTrimAngle - worldArc.startAngle)
                    : cornerNormalizeAngle(worldArc.startAngle - worldTrimAngle)

                if pickProgress <= trimProgress {
                    path.vertices[endIndex].position = localPoint
                    let localTrimAngle = atan2(
                        localPoint.y - localArc.center.y,
                        localPoint.x - localArc.center.x)
                    let newSweep = localArc.sweep >= 0
                        ? cornerNormalizeAngle(localTrimAngle - localArc.startAngle)
                        : -cornerNormalizeAngle(localArc.startAngle - localTrimAngle)
                    path.vertices[segmentIndex].bulge = tan(newSweep * 0.25)
                } else {
                    path.vertices[segmentIndex].position = localPoint
                    let localTrimAngle = atan2(
                        localPoint.y - localArc.center.y,
                        localPoint.x - localArc.center.x)
                    let originalEnd = localArc.startAngle + localArc.sweep
                    let newSweep = localArc.sweep >= 0
                        ? cornerNormalizeAngle(originalEnd - localTrimAngle)
                        : -cornerNormalizeAngle(localTrimAngle - originalEnd)
                    path.vertices[segmentIndex].bulge = tan(newSweep * 0.25)
                }
            } else {
                let worldStart = worldPath.vertices[segmentIndex].position
                let worldEnd = worldPath.vertices[endIndex].position
                guard let direction = cornerUnit(cornerVector(worldStart, worldEnd)) else { return nil }
                let trimParameter = cornerDot(cornerVector(worldStart, worldPoint), direction)
                let pickParameter = cornerDot(cornerVector(worldStart, selection.nearestWorld), direction)
                if pickParameter <= trimParameter {
                    path.vertices[endIndex].position = localPoint
                } else {
                    path.vertices[segmentIndex].position = localPoint
                }
            }
            replacement = .polyline(path: path, color: color)
        }

        geometry[selection.primitiveIndex] = replacement
        entity.localGeometry = geometry
        return entity
    }

    static func polylineCorner(
        first: CornerPick,
        second: CornerPick,
        point1: Vector3,
        point2: Vector3,
        filletCenter: Vector3?
    ) -> CADEntity? {
        let firstKind = first.kind
        let secondKind = second.kind
        guard first.handle == second.handle,
              first.primitiveIndex == second.primitiveIndex,
              case .polyline(var path, let segment1, let color) = firstKind,
              case .polyline(_, let segment2, _) = secondKind,
              path.hatchEdges.isEmpty,
              path.arcParameters(forSegment: segment1) == nil,
              path.arcParameters(forSegment: segment2) == nil,
              let sharedVertex = sharedVertexIndex(path: path, segment1: segment1, segment2: segment2)
        else { return nil }

        let count = path.vertices.count
        let previousSegment = (sharedVertex - 1 + count) % count
        let nextSegment = sharedVertex
        guard (path.isClosed || sharedVertex > 0),
              (path.isClosed || sharedVertex < count - 1),
              Set([segment1, segment2]) == Set([previousSegment, nextSegment])
        else { return nil }

        let incomingWorld = segment1 == previousSegment ? point1 : point2
        let outgoingWorld = segment1 == nextSegment ? point1 : point2
        let inverse = first.entity.transform.inverse()
        let incomingLocal = inverse.transformPoint(incomingWorld)
        let outgoingLocal = inverse.transformPoint(outgoingWorld)

        let previousVertex = path.vertices[(sharedVertex - 1 + count) % count]
        let originalCorner = path.vertices[sharedVertex]
        var incomingVertex = CADPolylineVertex(
            position: incomingLocal,
            bulge: 0,
            startWidth: originalCorner.startWidth,
            endWidth: originalCorner.endWidth)
        let outgoingVertex = CADPolylineVertex(
            position: outgoingLocal,
            bulge: 0,
            startWidth: originalCorner.startWidth,
            endWidth: originalCorner.endWidth)

        if let center = filletCenter {
            let startAngle = atan2(incomingWorld.y - center.y, incomingWorld.x - center.x)
            let endAngle = atan2(outgoingWorld.y - center.y, outgoingWorld.x - center.x)
            incomingVertex.bulge = tan(cornerSignedAngle(endAngle - startAngle) * 0.25)
        }

        var vertices: [CADPolylineVertex] = []
        vertices.reserveCapacity(path.vertices.count + 1)
        for index in path.vertices.indices {
            if index == sharedVertex {
                vertices.append(incomingVertex)
                vertices.append(outgoingVertex)
            } else {
                var vertex = path.vertices[index]
                if index == (sharedVertex - 1 + count) % count {
                    vertex.bulge = previousVertex.bulge
                }
                vertices.append(vertex)
            }
        }
        path.vertices = vertices

        var entity = first.entity
        guard var geometry = entity.localGeometry else { return nil }
        geometry[first.primitiveIndex] = .polyline(path: path, color: color)
        entity.localGeometry = geometry
        return entity
    }

    static func filletWholePolyline(
        selection: CornerPick,
        radius: Double
    ) -> CADEntity? {
        let pickKind = selection.kind
        guard case .polyline(let path, _, let color) = pickKind else { return nil }
        return rebuildWholePolyline(
            selection: selection,
            path: path,
            color: color,
            cornerBuilder: { incoming, outgoing, vertex in
                guard radius > cornerTolerance else { return nil }
                return polylineFilletProposal(
                    incoming: incoming,
                    outgoing: outgoing,
                    vertex: vertex,
                    radius: radius)
            })
    }

    static func chamferWholePolyline(
        selection: CornerPick,
        distance1: Double,
        distance2: Double
    ) -> CADEntity? {
        let pickKind = selection.kind
        guard case .polyline(let path, _, let color) = pickKind else { return nil }
        return rebuildWholePolyline(
            selection: selection,
            path: path,
            color: color,
            cornerBuilder: { incoming, outgoing, vertex in
                polylineChamferProposal(
                    incoming: incoming,
                    outgoing: outgoing,
                    vertex: vertex,
                    distance1: distance1,
                    distance2: distance2)
            })
    }

    static func chamferWholePolylineAngle(
        selection: CornerPick,
        distance: Double,
        angleRadians: Double
    ) -> CADEntity? {
        let pickKind = selection.kind
        guard case .polyline(let path, _, let color) = pickKind else { return nil }
        return rebuildWholePolyline(
            selection: selection,
            path: path,
            color: color,
            cornerBuilder: { incoming, outgoing, vertex in
                guard let incomingDirection = cornerUnit(cornerVector(vertex, incoming)),
                      let outgoingDirection = cornerUnit(cornerVector(vertex, outgoing))
                else { return nil }
                let includedAngle = acos(max(-1, min(1, cornerDot(incomingDirection, outgoingDirection))))
                guard angleRadians > cornerTolerance,
                      angleRadians < includedAngle - cornerTolerance,
                      abs(sin(includedAngle - angleRadians)) > cornerTolerance
                else { return nil }
                let secondDistance = distance * sin(angleRadians) / sin(includedAngle - angleRadians)
                return polylineChamferProposal(
                    incoming: incoming,
                    outgoing: outgoing,
                    vertex: vertex,
                    distance1: distance,
                    distance2: secondDistance)
            })
    }

    private struct PolylineCornerProposal {
        let incoming: Vector3
        let outgoing: Vector3
        let bulge: Double
        let incomingParameter: Double
        let outgoingParameter: Double
    }

    private static func rebuildWholePolyline(
        selection: CornerPick,
        path: CADPolyline,
        color: ColorRGBA?,
        cornerBuilder: (Vector3, Vector3, Vector3) -> PolylineCornerProposal?
    ) -> CADEntity? {
        guard path.hatchEdges.isEmpty,
              path.vertices.count >= (path.isClosed ? 3 : 3),
              !path.hasBulges
        else { return nil }

        let worldPath = path.transformed(by: selection.entity.transform)
        let count = worldPath.vertices.count
        let cornerIndices = path.isClosed ? Array(0..<count) : Array(1..<(count - 1))
        var proposals: [Int: PolylineCornerProposal] = [:]

        for vertexIndex in cornerIndices {
            let previousIndex = (vertexIndex - 1 + count) % count
            let nextIndex = (vertexIndex + 1) % count
            let previous = worldPath.vertices[previousIndex].position
            let vertex = worldPath.vertices[vertexIndex].position
            let next = worldPath.vertices[nextIndex].position
            guard let proposal = cornerBuilder(previous, next, vertex) else { return nil }
            proposals[vertexIndex] = proposal
        }
        guard !proposals.isEmpty else { return nil }

        for segmentIndex in 0..<worldPath.segmentCount {
            let startVertex = segmentIndex
            let endVertex = worldPath.endVertexIndex(forSegment: segmentIndex)
            let startCut = proposals[startVertex]?.outgoingParameter ?? 0.0
            let endCut = proposals[endVertex]?.incomingParameter ?? 1.0
            guard startCut <= endCut - cornerTolerance else { return nil }
        }

        let inverse = selection.entity.transform.inverse()
        var rebuilt: [CADPolylineVertex] = []
        rebuilt.reserveCapacity(path.vertices.count + proposals.count)

        if !path.isClosed {
            rebuilt.append(path.vertices[0])
        }

        for vertexIndex in cornerIndices {
            guard let proposal = proposals[vertexIndex] else { continue }
            let original = path.vertices[vertexIndex]
            rebuilt.append(CADPolylineVertex(
                position: inverse.transformPoint(proposal.incoming),
                bulge: proposal.bulge,
                startWidth: original.startWidth,
                endWidth: original.endWidth))
            rebuilt.append(CADPolylineVertex(
                position: inverse.transformPoint(proposal.outgoing),
                bulge: 0,
                startWidth: original.startWidth,
                endWidth: original.endWidth))
        }

        if !path.isClosed {
            rebuilt.append(path.vertices[count - 1])
        }

        var newPath = path
        newPath.vertices = rebuilt
        var entity = selection.entity
        guard var geometry = entity.localGeometry else { return nil }
        geometry[selection.primitiveIndex] = .polyline(path: newPath, color: color)
        entity.localGeometry = geometry
        return entity
    }

    private static func polylineFilletProposal(
        incoming: Vector3,
        outgoing: Vector3,
        vertex: Vector3,
        radius: Double
    ) -> PolylineCornerProposal? {
        guard let incomingDirection = cornerUnit(cornerVector(vertex, incoming)),
              let outgoingDirection = cornerUnit(cornerVector(vertex, outgoing))
        else { return nil }
        let cosine = max(-1.0, min(1.0, cornerDot(incomingDirection, outgoingDirection)))
        let angle = acos(cosine)
        guard angle > 1e-6, angle < .pi - 1e-6 else { return nil }
        let tangentDistance = radius / tan(angle * 0.5)
        let incomingLength = cornerLength(cornerVector(vertex, incoming))
        let outgoingLength = cornerLength(cornerVector(vertex, outgoing))
        guard tangentDistance < incomingLength - cornerTolerance,
              tangentDistance < outgoingLength - cornerTolerance
        else { return nil }

        let incomingPoint = cornerPoint(vertex, incomingDirection, tangentDistance)
        let outgoingPoint = cornerPoint(vertex, outgoingDirection, tangentDistance)
        let bisectorVector = incomingDirection + outgoingDirection
        guard let bisector = cornerUnit(bisectorVector) else { return nil }
        let centerDistance = radius / sin(angle * 0.5)
        let center = cornerPoint(vertex, bisector, centerDistance)
        let startAngle = atan2(incomingPoint.y - center.y, incomingPoint.x - center.x)
        let endAngle = atan2(outgoingPoint.y - center.y, outgoingPoint.x - center.x)
        let bulge = tan(cornerSignedAngle(endAngle - startAngle) * 0.25)
        return PolylineCornerProposal(
            incoming: incomingPoint,
            outgoing: outgoingPoint,
            bulge: bulge,
            incomingParameter: 1.0 - tangentDistance / incomingLength,
            outgoingParameter: tangentDistance / outgoingLength)
    }

    private static func polylineChamferProposal(
        incoming: Vector3,
        outgoing: Vector3,
        vertex: Vector3,
        distance1: Double,
        distance2: Double
    ) -> PolylineCornerProposal? {
        guard let incomingDirection = cornerUnit(cornerVector(vertex, incoming)),
              let outgoingDirection = cornerUnit(cornerVector(vertex, outgoing))
        else { return nil }
        let incomingLength = cornerLength(cornerVector(vertex, incoming))
        let outgoingLength = cornerLength(cornerVector(vertex, outgoing))
        guard distance1 < incomingLength - cornerTolerance,
              distance2 < outgoingLength - cornerTolerance
        else { return nil }
        return PolylineCornerProposal(
            incoming: cornerPoint(vertex, incomingDirection, distance1),
            outgoing: cornerPoint(vertex, outgoingDirection, distance2),
            bulge: 0,
            incomingParameter: 1.0 - distance1 / incomingLength,
            outgoingParameter: distance2 / outgoingLength)
    }

    private static func sharedVertexIndex(
        path: CADPolyline,
        segment1: Int,
        segment2: Int
    ) -> Int? {
        let endpoints1 = Set([segment1, path.endVertexIndex(forSegment: segment1)])
        let endpoints2 = Set([segment2, path.endVertexIndex(forSegment: segment2)])
        return endpoints1.intersection(endpoints2).first
    }
}

private enum CornerCommandApply {
    @MainActor
    static func fillet(
        first: CornerPick,
        second: CornerPick,
        radius: Double,
        trim: Bool,
        engine: PhrostEngine
    ) -> Bool {
        if radius <= cornerTolerance {
            guard let corner = CornerSolver.zeroRadiusCorner(first: first, second: second) else { return false }
            guard trim else { return false }
            return applyTrimmedPair(
                first: first,
                second: second,
                point1: corner,
                point2: corner,
                connector: nil,
                engine: engine)
        }

        guard let solution = CornerSolver.fillet(first: first, second: second, radius: radius) else {
            return false
        }
        let connectorLayer = connectorLayerID(first: first, second: second, engine: engine)
        let connector = CADEntity(
            layerID: connectorLayer,
            localGeometry: [
                .arc(
                    center: solution.center,
                    radius: solution.radius,
                    startAngle: solution.arcStart,
                    endAngle: solution.arcEnd)
            ],
            drawOrder: connectorDrawOrder(first: first, second: second))

        if !trim {
            engine.document.addEntities([connector])
            return true
        }
        return applyTrimmedPair(
            first: first,
            second: second,
            point1: solution.tangent1,
            point2: solution.tangent2,
            connector: connector,
            filletCenter: solution.center,
            engine: engine)
    }

    @MainActor
    static func chamfer(
        first: CornerPick,
        second: CornerPick,
        distance1: Double,
        distance2: Double,
        trim: Bool,
        engine: PhrostEngine
    ) -> Bool {
        guard let solution = CornerSolver.chamfer(
            first: first,
            second: second,
            distance1: distance1,
            distance2: distance2)
        else { return false }

        let connector: CADEntity?
        if distance1 <= cornerTolerance && distance2 <= cornerTolerance {
            connector = nil
        } else {
            connector = CADEntity(
                layerID: connectorLayerID(first: first, second: second, engine: engine),
                localGeometry: [.line(start: solution.point1, end: solution.point2)],
                drawOrder: connectorDrawOrder(first: first, second: second))
        }
        if !trim {
            guard let connector else { return false }
            engine.document.addEntities([connector])
            return true
        }
        return applyTrimmedPair(
            first: first,
            second: second,
            point1: solution.point1,
            point2: solution.point2,
            connector: connector,
            engine: engine)
    }

    @MainActor
    private static func applyTrimmedPair(
        first: CornerPick,
        second: CornerPick,
        point1: Vector3,
        point2: Vector3,
        connector: CADEntity?,
        filletCenter: Vector3? = nil,
        engine: PhrostEngine
    ) -> Bool {
        if first.handle == second.handle,
           first.primitiveIndex == second.primitiveIndex,
           first.segmentIndex != nil,
           second.segmentIndex != nil {
            guard let entity = CornerMutation.polylineCorner(
                first: first,
                second: second,
                point1: point1,
                point2: point2,
                filletCenter: filletCenter)
            else { return false }
            engine.document.replaceEntities(remove: [first.handle], add: [entity])
            return true
        }

        var updated: [UUID: CADEntity] = [:]
        if let firstEntity = CornerMutation.trimmedEntity(selection: first, to: point1) {
            updated[first.handle] = firstEntity
        }
        if first.handle == second.handle {
            guard var sameEntity = updated[first.handle] else { return false }
            var adjustedSecond = second
            adjustedSecond = CornerPick(
                handle: second.handle,
                primitiveIndex: second.primitiveIndex,
                segmentIndex: second.segmentIndex,
                entity: sameEntity,
                primitive: second.primitive,
                kind: second.kind,
                support: second.support,
                pickWorld: second.pickWorld,
                nearestWorld: second.nearestWorld)
            guard let secondEntity = CornerMutation.trimmedEntity(selection: adjustedSecond, to: point2) else {
                return false
            }
            sameEntity = secondEntity
            updated[first.handle] = sameEntity
        } else if let secondEntity = CornerMutation.trimmedEntity(selection: second, to: point2) {
            updated[second.handle] = secondEntity
        }

        var additions = Array(updated.values)
        if let connector { additions.append(connector) }
        guard !additions.isEmpty else { return false }
        engine.document.replaceEntities(remove: Set(updated.keys), add: additions)
        return true
    }

    private static func connectorDrawOrder(first: CornerPick, second: CornerPick) -> Int {
        let value = max(first.entity.drawOrder, second.entity.drawOrder)
        return value == Int.max ? Int.max : value + 1
    }

    @MainActor
    private static func connectorLayerID(
        first: CornerPick,
        second: CornerPick,
        engine: PhrostEngine
    ) -> UUID {
        if first.entity.layerID == second.entity.layerID {
            return first.entity.layerID
        }
        return engine.document.activeLayerID ?? first.entity.layerID
    }
}

@MainActor
public final class FilletCommand: FeatureCommand {
    private enum State {
        case waitingForFirst
        case waitingForSecond(CornerPick)
        case waitingForPolyline
    }

    private enum InputMode: Equatable {
        case none
        case radius
        case trim
    }

    private static var currentRadius = 0.0
    private static var trimEnabled = true

    private var state: State = .waitingForFirst
    private var inputMode: InputMode = .none
    private var multiple = false
    private var operationsInSession = 0
    private var currentMouse = Vector3.zero

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirst
        inputMode = .none
        multiple = false
        operationsInSession = 0
        updatePrompt(processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirst
        inputMode = .none
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let rawPoint = CornerPicker.rawWorldPoint(engine: engine)

        switch state {
        case .waitingForFirst:
            guard let selection = CornerPicker.pick(at: rawPoint, engine: engine, lineOnly: false) else {
                processor.commandPrompt = "Select a line, arc, circle, ray, or polyline segment."
                return .handled
            }
            state = .waitingForSecond(selection)
            processor.commandPrompt = "Select second object or hold Shift for radius 0."
            return .handled

        case .waitingForSecond(let first):
            guard let second = CornerPicker.pick(at: rawPoint, engine: engine, lineOnly: false) else {
                processor.commandPrompt = "Select a valid second object."
                return .handled
            }
            guard first.handle != second.handle
                    || first.primitiveIndex != second.primitiveIndex
                    || first.segmentIndex != second.segmentIndex
            else {
                processor.commandPrompt = "Select a different object or adjacent polyline segment."
                return .handled
            }
            let shiftHeld = engine.io != nil && engine.io.pointee.KeyShift
            let radius = shiftHeld ? 0.0 : Self.currentRadius
            guard CornerCommandApply.fillet(
                first: first,
                second: second,
                radius: radius,
                trim: Self.trimEnabled,
                engine: engine)
            else {
                processor.commandPrompt = "Unable to create fillet with the current radius and selections."
                return .handled
            }
            operationsInSession += 1
            engine.tabManager.markActiveDirty()
            if multiple {
                state = .waitingForFirst
                updatePrompt(processor)
                return .handled
            }
            processor.commandPrompt = "Fillet created."
            return .finished

        case .waitingForPolyline:
            guard let selection = CornerPicker.pick(at: rawPoint, engine: engine, lineOnly: false),
                  selection.segmentIndex != nil,
                  let updated = CornerMutation.filletWholePolyline(
                    selection: selection,
                    radius: Self.currentRadius)
            else {
                processor.commandPrompt = "Select a linear 2D polyline with corners large enough for the radius."
                return .handled
            }
            engine.document.replaceEntities(remove: [selection.handle], add: [updated])
            engine.tabManager.markActiveDirty()
            operationsInSession += 1
            processor.commandPrompt = "Polyline filleted."
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        currentMouse = Vector3(x: worldX, y: worldY, z: 0)
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if inputMode != .none { return .continue }
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        case SDL_SCANCODE_R:
            inputMode = .radius
            openInput(processor, prompt: "Specify fillet radius <\(format(Self.currentRadius))>:")
            return .handled
        case SDL_SCANCODE_T:
            inputMode = .trim
            openInput(processor, prompt: "Enter Trim or No trim <\(Self.trimEnabled ? "Trim" : "No trim")>:")
            return .handled
        case SDL_SCANCODE_M:
            multiple = true
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case SDL_SCANCODE_P:
            state = .waitingForPolyline
            processor.commandPrompt = "Select 2D polyline."
            return .handled
        case SDL_SCANCODE_U:
            guard operationsInSession > 0 else {
                processor.commandPrompt = "Nothing to undo in this FILLET session."
                return .handled
            }
            engine.document.undo()
            operationsInSession -= 1
            state = .waitingForFirst
            updatePrompt(processor)
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
        let upper = value.uppercased()

        switch inputMode {
        case .radius:
            guard let radius = Double(value), radius >= 0 else {
                processor.commandPrompt = "Radius must be zero or greater."
                return .handled
            }
            Self.currentRadius = radius
            inputMode = .none
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case .trim:
            if ["T", "TRIM", "YES", "Y"].contains(upper) {
                Self.trimEnabled = true
            } else if ["N", "NO", "NOTRIM", "NO TRIM"].contains(upper) {
                Self.trimEnabled = false
            } else {
                processor.commandPrompt = "Enter Trim or No trim."
                return .handled
            }
            inputMode = .none
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case .none:
            break
        }

        switch upper {
        case "R", "RADIUS":
            inputMode = .radius
            openInput(processor, prompt: "Specify fillet radius <\(format(Self.currentRadius))>:")
        case "T", "TRIM":
            inputMode = .trim
            openInput(processor, prompt: "Enter Trim or No trim:")
        case "M", "MULTIPLE":
            multiple = true
            state = .waitingForFirst
            updatePrompt(processor)
        case "P", "POLYLINE":
            state = .waitingForPolyline
            processor.commandPrompt = "Select 2D polyline."
        case "U", "UNDO":
            if operationsInSession > 0 {
                engine.document.undo()
                operationsInSession -= 1
            }
            state = .waitingForFirst
            updatePrompt(processor)
        default:
            if let radius = Double(value), radius >= 0 {
                Self.currentRadius = radius
                state = .waitingForFirst
                updatePrompt(processor)
            } else {
                processor.commandPrompt = "FILLET options: Undo, Polyline, Radius, Trim, Multiple."
            }
        }
        return .handled
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForSecond(let first) = state,
              let second = CornerPicker.pick(at: currentMouse, engine: engine, lineOnly: false)
        else { return }

        let shiftHeld = engine.io != nil && engine.io.pointee.KeyShift
        let radius = shiftHeld ? 0.0 : Self.currentRadius
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(0, 255, 128, 220)

        if radius <= cornerTolerance {
            guard let corner = CornerSolver.zeroRadiusCorner(first: first, second: second) else { return }
            let screen = EngineCameraManager.worldToScreen(worldX: corner.x, worldY: corner.y, cam: cam)
            ImDrawListAddCircle(drawList, ImVec2(x: screen.x, y: screen.y), 5, color, 16, 1.5)
            return
        }
        guard let solution = CornerSolver.fillet(first: first, second: second, radius: radius) else { return }
        let sweep = solution.arcEnd - solution.arcStart
        let divisions = max(16, Int(ceil(abs(sweep) * 24.0)))
        var points: [ImVec2] = []
        points.reserveCapacity(divisions + 1)
        for index in 0...divisions {
            let t = Double(index) / Double(divisions)
            let angle = solution.arcStart + sweep * t
            let world = Vector3(
                x: solution.center.x + cos(angle) * solution.radius,
                y: solution.center.y + sin(angle) * solution.radius,
                z: 0)
            let screen = EngineCameraManager.worldToScreen(worldX: world.x, worldY: world.y, cam: cam)
            points.append(ImVec2(x: screen.x, y: screen.y))
        }
        points.withUnsafeBufferPointer { buffer in
            ImDrawListAddPolyline(
                drawList,
                buffer.baseAddress,
                Int32(buffer.count),
                color,
                2.0,
                ImDrawFlags(0))
        }
    }

    private func updatePrompt(_ processor: CADCommandProcessor) {
        processor.commandPrompt = "FILLET: Mode=\(Self.trimEnabled ? "TRIM" : "NO TRIM"), Radius=\(format(Self.currentRadius)). Select first object or [Undo/Polyline/Radius/Trim/Multiple]."
    }

    private func openInput(_ processor: CADCommandProcessor, prompt: String) {
        processor.commandPrompt = prompt
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

@MainActor
public final class ChamferCommand: FeatureCommand {
    private enum State {
        case waitingForFirst
        case waitingForSecond(CornerPick)
        case waitingForPolyline
    }

    private enum Method {
        case distance
        case angle
    }

    private enum InputMode: Equatable {
        case none
        case distance1
        case distance2
        case angleDistance
        case angleValue
        case trim
        case method
    }

    private static var distance1 = 0.0
    private static var distance2 = 0.0
    private static var angleDistance = 0.0
    private static var angleDegrees = 45.0
    private static var method: Method = .distance
    private static var trimEnabled = true

    private var state: State = .waitingForFirst
    private var inputMode: InputMode = .none
    private var multiple = false
    private var operationsInSession = 0
    private var currentMouse = Vector3.zero

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirst
        inputMode = .none
        multiple = false
        operationsInSession = 0
        updatePrompt(processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForFirst
        inputMode = .none
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let rawPoint = CornerPicker.rawWorldPoint(engine: engine)

        switch state {
        case .waitingForFirst:
            guard let selection = CornerPicker.pick(at: rawPoint, engine: engine, lineOnly: true) else {
                processor.commandPrompt = "Select a line, ray, or straight polyline segment."
                return .handled
            }
            state = .waitingForSecond(selection)
            processor.commandPrompt = "Select second line or polyline segment."
            return .handled

        case .waitingForSecond(let first):
            guard let second = CornerPicker.pick(at: rawPoint, engine: engine, lineOnly: true) else {
                processor.commandPrompt = "Select a valid second line or polyline segment."
                return .handled
            }
            guard first.handle != second.handle
                    || first.primitiveIndex != second.primitiveIndex
                    || first.segmentIndex != second.segmentIndex
            else {
                processor.commandPrompt = "Select a different object or adjacent polyline segment."
                return .handled
            }
            guard let distances = effectiveDistances(first: first, second: second),
                  CornerCommandApply.chamfer(
                    first: first,
                    second: second,
                    distance1: distances.0,
                    distance2: distances.1,
                    trim: Self.trimEnabled,
                    engine: engine)
            else {
                processor.commandPrompt = "Unable to create chamfer with the current settings and selections."
                return .handled
            }
            operationsInSession += 1
            engine.tabManager.markActiveDirty()
            if multiple {
                state = .waitingForFirst
                updatePrompt(processor)
                return .handled
            }
            processor.commandPrompt = "Chamfer created."
            return .finished

        case .waitingForPolyline:
            guard let selection = CornerPicker.pick(at: rawPoint, engine: engine, lineOnly: true),
                  selection.segmentIndex != nil
            else {
                processor.commandPrompt = "Select a linear 2D polyline with corners large enough for the chamfer."
                return .handled
            }
            let updated: CADEntity?
            switch Self.method {
            case .distance:
                updated = CornerMutation.chamferWholePolyline(
                    selection: selection,
                    distance1: Self.distance1,
                    distance2: Self.distance2)
            case .angle:
                updated = CornerMutation.chamferWholePolylineAngle(
                    selection: selection,
                    distance: Self.angleDistance,
                    angleRadians: Self.angleDegrees * .pi / 180.0)
            }
            guard let updated else {
                processor.commandPrompt = "Select a linear 2D polyline with corners large enough for the chamfer."
                return .handled
            }
            engine.document.replaceEntities(remove: [selection.handle], add: [updated])
            engine.tabManager.markActiveDirty()
            operationsInSession += 1
            processor.commandPrompt = "Polyline chamfered."
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        currentMouse = Vector3(x: worldX, y: worldY, z: 0)
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if inputMode != .none { return .continue }
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        case SDL_SCANCODE_D:
            inputMode = .distance1
            Self.method = .distance
            openInput(processor, prompt: "Specify first chamfer distance <\(format(Self.distance1))>:")
            return .handled
        case SDL_SCANCODE_A:
            inputMode = .angleDistance
            Self.method = .angle
            openInput(processor, prompt: "Specify chamfer length on first line <\(format(Self.angleDistance))>:")
            return .handled
        case SDL_SCANCODE_T:
            inputMode = .trim
            openInput(processor, prompt: "Enter Trim or No trim <\(Self.trimEnabled ? "Trim" : "No trim")>:")
            return .handled
        case SDL_SCANCODE_E:
            inputMode = .method
            openInput(processor, prompt: "Enter Distance or Angle method:")
            return .handled
        case SDL_SCANCODE_M:
            multiple = true
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case SDL_SCANCODE_P:
            state = .waitingForPolyline
            processor.commandPrompt = "Select 2D polyline."
            return .handled
        case SDL_SCANCODE_U:
            guard operationsInSession > 0 else {
                processor.commandPrompt = "Nothing to undo in this CHAMFER session."
                return .handled
            }
            engine.document.undo()
            operationsInSession -= 1
            state = .waitingForFirst
            updatePrompt(processor)
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
        let upper = value.uppercased()

        switch inputMode {
        case .distance1:
            guard let distance = Double(value), distance >= 0 else {
                processor.commandPrompt = "Distance must be zero or greater."
                return .handled
            }
            Self.distance1 = distance
            inputMode = .distance2
            openInput(processor, prompt: "Specify second chamfer distance <\(format(Self.distance2))>:")
            return .handled
        case .distance2:
            guard let distance = Double(value), distance >= 0 else {
                processor.commandPrompt = "Distance must be zero or greater."
                return .handled
            }
            Self.distance2 = distance
            inputMode = .none
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case .angleDistance:
            guard let distance = Double(value), distance >= 0 else {
                processor.commandPrompt = "Distance must be zero or greater."
                return .handled
            }
            Self.angleDistance = distance
            inputMode = .angleValue
            openInput(processor, prompt: "Specify chamfer angle <\(format(Self.angleDegrees))>:")
            return .handled
        case .angleValue:
            guard let angle = Double(value), angle > 0, angle < 180 else {
                processor.commandPrompt = "Angle must be greater than 0 and less than 180 degrees."
                return .handled
            }
            Self.angleDegrees = angle
            inputMode = .none
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case .trim:
            if ["T", "TRIM", "YES", "Y"].contains(upper) {
                Self.trimEnabled = true
            } else if ["N", "NO", "NOTRIM", "NO TRIM"].contains(upper) {
                Self.trimEnabled = false
            } else {
                processor.commandPrompt = "Enter Trim or No trim."
                return .handled
            }
            inputMode = .none
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case .method:
            if ["D", "DISTANCE"].contains(upper) {
                Self.method = .distance
            } else if ["A", "ANGLE"].contains(upper) {
                Self.method = .angle
            } else {
                processor.commandPrompt = "Enter Distance or Angle."
                return .handled
            }
            inputMode = .none
            state = .waitingForFirst
            updatePrompt(processor)
            return .handled
        case .none:
            break
        }

        switch upper {
        case "D", "DISTANCE":
            Self.method = .distance
            inputMode = .distance1
            openInput(processor, prompt: "Specify first chamfer distance:")
        case "A", "ANGLE":
            Self.method = .angle
            inputMode = .angleDistance
            openInput(processor, prompt: "Specify chamfer length on first line:")
        case "T", "TRIM":
            inputMode = .trim
            openInput(processor, prompt: "Enter Trim or No trim:")
        case "E", "METHOD":
            inputMode = .method
            openInput(processor, prompt: "Enter Distance or Angle method:")
        case "M", "MULTIPLE":
            multiple = true
            state = .waitingForFirst
            updatePrompt(processor)
        case "P", "POLYLINE":
            state = .waitingForPolyline
            processor.commandPrompt = "Select 2D polyline."
        case "U", "UNDO":
            if operationsInSession > 0 {
                engine.document.undo()
                operationsInSession -= 1
            }
            state = .waitingForFirst
            updatePrompt(processor)
        default:
            processor.commandPrompt = "CHAMFER options: Undo, Polyline, Distance, Angle, Trim, Method, Multiple."
        }
        return .handled
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForSecond(let first) = state,
              let second = CornerPicker.pick(at: currentMouse, engine: engine, lineOnly: true),
              let distances = effectiveDistances(first: first, second: second),
              let solution = CornerSolver.chamfer(
                first: first,
                second: second,
                distance1: distances.0,
                distance2: distances.1)
        else { return }

        let start = EngineCameraManager.worldToScreen(
            worldX: solution.point1.x,
            worldY: solution.point1.y,
            cam: cam)
        let end = EngineCameraManager.worldToScreen(
            worldX: solution.point2.x,
            worldY: solution.point2.y,
            cam: cam)
        ImDrawListAddLine(
            igGetForegroundDrawList_ViewportPtr(nil),
            ImVec2(x: start.x, y: start.y),
            ImVec2(x: end.x, y: end.y),
            makeCol32(0, 255, 128, 220),
            2.0)
    }

    private func effectiveDistances(
        first: CornerPick,
        second: CornerPick
    ) -> (Double, Double)? {
        switch Self.method {
        case .distance:
            return (Self.distance1, Self.distance2)
        case .angle:
            let firstSupport = first.support
            let secondSupport = second.support
            guard case .line(let origin1, let direction1) = firstSupport,
                  case .line(let origin2, let direction2) = secondSupport,
                  let corner = cornerLineIntersection(origin1, direction1, origin2, direction2),
                  let retained1 = CornerSolver.retainedDirection(selection: first, corner: corner),
                  let retained2 = CornerSolver.retainedDirection(selection: second, corner: corner)
            else { return nil }
            let includedAngle = acos(max(-1, min(1, cornerDot(retained1, retained2))))
            let angle = Self.angleDegrees * .pi / 180.0
            guard angle > cornerTolerance,
                  angle < includedAngle - cornerTolerance,
                  abs(sin(includedAngle - angle)) > cornerTolerance
            else { return nil }
            let secondDistance = Self.angleDistance * sin(angle) / sin(includedAngle - angle)
            return (Self.angleDistance, secondDistance)
        }
    }

    private func updatePrompt(_ processor: CADCommandProcessor) {
        let mode = Self.trimEnabled ? "TRIM" : "NO TRIM"
        let methodText: String
        switch Self.method {
        case .distance:
            methodText = "Distance1=\(format(Self.distance1)), Distance2=\(format(Self.distance2))"
        case .angle:
            methodText = "Length=\(format(Self.angleDistance)), Angle=\(format(Self.angleDegrees))°"
        }
        processor.commandPrompt = "CHAMFER: Mode=\(mode), Method=\(methodText). Select first line or [Undo/Polyline/Distance/Angle/Trim/Method/Multiple]."
    }

    private func openInput(_ processor: CADCommandProcessor, prompt: String) {
        processor.commandPrompt = prompt
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
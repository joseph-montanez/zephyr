import Foundation

// =========================================================================
// MARK: - DXFHatchGenerator
//
// Generates hatch patterns for DXF HATCH entities.  AutoCAD's predefined
// patterns are not just "a line every N units"; each pattern is a small list
// of hatch definition lines.  Each definition line has:
//   - an angle,
//   - a base point,
//   - an offset to the next parallel line,
//   - optional dash/gap segments.
//
// DXFImporter stores HATCH as CADPrimitive.hatch(boundary, pattern, scale,
// angle).  This file turns those values into clipped CADPrimitive.line/point
// primitives during rendering, PDF export, and other preview paths.
// =========================================================================

public struct DXFHatchPatternLine: Hashable, Sendable {
    public var angleDegrees: Double
    public var base: Vector3
    public var offset: Vector3
    public var dashes: [Double]

    public init(angleDegrees: Double, base: Vector3, offset: Vector3, dashes: [Double] = []) {
        self.angleDegrees = angleDegrees
        self.base = base
        self.offset = offset
        self.dashes = dashes
    }
}

public struct DXFHatchPatternDefinition: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case solid = "SOLID"
        case predefined = "Predefined"
        case userDefined = "UserDefined"
        case custom = "Custom"
    }

    public var name: String
    public var kind: Kind
    public var lines: [DXFHatchPatternLine]

    public init(name: String, kind: Kind, lines: [DXFHatchPatternLine]) {
        self.name = name
        self.kind = kind
        self.lines = lines
    }
}

public enum DXFHatchGenerator {
    public static let maxGeneratedLinesPerPatternDefinition: Double = 4096.0

    public static func adaptiveMinimumSpacing(for polygon: [Vector3]) -> Double {
        guard polygon.count >= 3 else { return 0.0 }
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        for pt in polygon {
            minX = min(minX, pt.x)
            maxX = max(maxX, pt.x)
            minY = min(minY, pt.y)
            maxY = max(maxY, pt.y)
        }
        let dx = maxX - minX
        let dy = maxY - minY
        let diag = sqrt(dx * dx + dy * dy)
        guard diag.isFinite, diag > 0 else { return 0.0 }
        return diag / maxGeneratedLinesPerPatternDefinition
    }

    // MARK: - AutoCAD-style predefined pattern registry

    public static let predefinedPatterns: [String: DXFHatchPatternDefinition] = {
        func v(_ x: Double, _ y: Double) -> Vector3 { Vector3(x: x, y: y, z: 0) }
        func line(_ angle: Double, _ base: Vector3, _ offset: Vector3, _ dashes: [Double] = []) -> DXFHatchPatternLine {
            DXFHatchPatternLine(angleDegrees: angle, base: base, offset: offset, dashes: dashes)
        }

        let defs: [DXFHatchPatternDefinition] = [
            DXFHatchPatternDefinition(
                name: "ANSI31", kind: .predefined,
                lines: [line(45.0, v(0.0, 0.0), v(0.0, 0.125))]
            ),
            DXFHatchPatternDefinition(
                name: "ANSI32", kind: .predefined,
                lines: [
                    line(45.0, v(0.0, 0.0), v(0.0, 0.375)),
                    line(45.0, v(0.176776695, 0.0), v(0.0, 0.375))
                ]
            ),
            DXFHatchPatternDefinition(
                name: "ANSI33", kind: .predefined,
                lines: [line(45.0, v(0.0, 0.0), v(0.0, 0.25), [0.125, -0.0625])]
            ),
            DXFHatchPatternDefinition(
                name: "ANSI34", kind: .predefined,
                lines: [
                    line(45.0, v(0.0, 0.0), v(0.0, 0.75)),
                    line(45.0, v(0.176776695, 0.0), v(0.0, 0.75)),
                    line(45.0, v(0.353553391, 0.0), v(0.0, 0.75)),
                    line(45.0, v(0.530330086, 0.0), v(0.0, 0.75))
                ]
            ),
            DXFHatchPatternDefinition(
                name: "ANSI35", kind: .predefined,
                lines: [line(45.0, v(0.0, 0.0), v(0.0, 0.125), [0.3125, -0.0625, 0.0, -0.0625])]
            ),
            DXFHatchPatternDefinition(
                name: "ANSI36", kind: .predefined,
                lines: [
                    line(45.0, v(0.0, 0.0), v(0.0, 0.125), [0.3125, -0.0625, 0.0, -0.0625]),
                    line(45.0, v(0.176776695, 0.0), v(0.0, 0.125), [0.3125, -0.0625, 0.0, -0.0625])
                ]
            ),
            DXFHatchPatternDefinition(
                name: "ANSI37", kind: .predefined,
                lines: [
                    line(45.0, v(0.0, 0.0), v(0.0, 0.125)),
                    line(135.0, v(0.0, 0.0), v(0.0, 0.125))
                ]
            ),
            DXFHatchPatternDefinition(
                name: "ANSI38", kind: .predefined,
                lines: [
                    line(45.0, v(0.0, 0.0), v(0.0, 0.125)),
                    line(135.0, v(0.0, 0.0), v(0.0, 0.125)),
                    line(45.0, v(0.176776695, 0.0), v(0.0, 0.125)),
                    line(135.0, v(0.176776695, 0.0), v(0.0, 0.125))
                ]
            )
        ]

        var out: [String: DXFHatchPatternDefinition] = [:]
        for def in defs { out[def.name.uppercased()] = def }
        return out
    }()

    public static func patternDefinition(for patternName: String) -> DXFHatchPatternDefinition? {
        let key = patternName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if key.isEmpty || key == "SOLID" {
            return DXFHatchPatternDefinition(name: "SOLID", kind: .solid, lines: [])
        }
        return predefinedPatterns[key]
    }

    public static func patternKindName(for patternName: String) -> String {
        patternDefinition(for: patternName)?.kind.rawValue ?? DXFHatchPatternDefinition.Kind.custom.rawValue
    }

    public static func effectiveSpacing(patternName: String, scale: Double) -> Double {
        let safeScale = max(abs(scale), 1e-9)
        guard let def = patternDefinition(for: patternName), !def.lines.isEmpty else {
            return max(1.0, 10.0 * safeScale)
        }
        var smallest = Double.infinity
        for line in def.lines {
            let perpendicular = abs(line.offset.y)
            if perpendicular > 1e-9 { smallest = min(smallest, perpendicular * safeScale) }
        }
        return smallest.isFinite ? smallest : max(1.0, 10.0 * safeScale)
    }

    // MARK: - Public pattern generation

    public static func generatePatternHatch(
        polygon: [Vector3],
        patternName: String,
        scale: Double,
        angleDegrees: Double,
        minimumSpacing: Double = 0.0
    ) -> [CADPrimitive] {
        guard polygon.count >= 3 else { return [] }

        let key = patternName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if key.isEmpty || key == "SOLID" { return [] }

        let safeScale = max(abs(scale), 1e-9)
        let extraAngle = angleDegrees * .pi / 180.0

        if let definition = predefinedPatterns[key] {
            var out: [CADPrimitive] = []
            for line in definition.lines {
                out.append(contentsOf: generateDefinitionLine(
                    polygon: polygon,
                    definitionLine: line,
                    scale: safeScale,
                    extraAngleRad: extraAngle,
                    minimumSpacing: minimumSpacing
                ))
            }
            return out
        }

        // Unknown/custom pattern fallback.  It is still important to render
        // something usable, so use the pattern angle/scale as a user-defined
        // parallel-line hatch instead of silently dropping the fill.
        let spacing = max(1.0, max(minimumSpacing, 10.0 * safeScale))
        return generateLineHatch(polygon: polygon, spacing: spacing, angleRad: extraAngle)
    }

    public static func generateDotHatch(polygon: [Vector3], spacing: Double) -> [CADPrimitive] {
        guard polygon.count >= 3 else { return [] }
        let spacing = max(abs(spacing), 1e-9)
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        for p in polygon {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }

        var prims: [CADPrimitive] = []
        func hashJitter(_ x: Int, _ y: Int) -> (Double, Double) {
            let h = abs((x &* 12345 &+ y &* 67890) % 1000)
            let jx = Double(h % 10) / 10.0 - 0.5
            let jy = Double((h / 10) % 10) / 10.0 - 0.5
            return (jx, jy)
        }

        var xVal = floor(minX / spacing) * spacing
        while xVal <= maxX {
            var yVal = floor(minY / spacing) * spacing
            while yVal <= maxY {
                let cellX = Int(xVal / spacing)
                let cellY = Int(yVal / spacing)
                let (jx, jy) = hashJitter(cellX, cellY)
                let px = xVal + jx * spacing * 0.4
                let py = yVal + jy * spacing * 0.4
                let pt = Vector3(x: px, y: py, z: 0)
                if pointInPolygon(pt, polygon: polygon) { prims.append(.point(position: pt)) }
                yVal += spacing
            }
            xVal += spacing
        }
        return prims
    }

    public static func generateLineHatch(polygon: [Vector3], spacing: Double, angleRad: Double) -> [CADPrimitive] {
        let definitionLine = DXFHatchPatternLine(
            angleDegrees: angleRad * 180.0 / .pi,
            base: .zero,
            offset: Vector3(x: 0.0, y: max(abs(spacing), 1e-9), z: 0.0),
            dashes: []
        )
        return generateDefinitionLine(
            polygon: polygon,
            definitionLine: definitionLine,
            scale: 1.0,
            extraAngleRad: 0.0,
            minimumSpacing: 0.0
        )
    }

    public static func connectHoles(outer: [Vector3], holes: [[Vector3]]) -> [Vector3] {
        var boundary = outer
        let sortedHoles = holes.sorted { h1, h2 in
            let x1 = h1.reduce(0.0) { $0 + $1.x } / Double(max(h1.count, 1))
            let x2 = h2.reduce(0.0) { $0 + $1.x } / Double(max(h2.count, 1))
            return x1 < x2
        }

        for hole in sortedHoles {
            guard !hole.isEmpty else { continue }
            var minDistance = Double.infinity
            var bestHIdx = 0
            var bestBIdx = 0
            for hIdx in 0..<hole.count {
                let hp = hole[hIdx]
                for bIdx in 0..<boundary.count {
                    let bp = boundary[bIdx]
                    let dist = (hp.x - bp.x) * (hp.x - bp.x) + (hp.y - bp.y) * (hp.y - bp.y) + (hp.z - bp.z) * (hp.z - bp.z)
                    if dist < minDistance {
                        minDistance = dist
                        bestHIdx = hIdx
                        bestBIdx = bIdx
                    }
                }
            }

            var newBoundary: [Vector3] = []
            newBoundary.reserveCapacity(boundary.count + hole.count + 2)
            for i in 0...bestBIdx { newBoundary.append(boundary[i]) }
            for i in 0...hole.count { newBoundary.append(hole[(bestHIdx + i) % hole.count]) }
            newBoundary.append(boundary[bestBIdx])
            if bestBIdx + 1 < boundary.count {
                for i in (bestBIdx + 1)..<boundary.count { newBoundary.append(boundary[i]) }
            }
            boundary = newBoundary
        }
        return boundary
    }

    public static func pointInPolygon(_ p: Vector3, polygon: [Vector3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if ((pi.y > p.y) != (pj.y > p.y)) &&
                (p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: - Definition-line generator

    private static func generateDefinitionLine(
        polygon: [Vector3],
        definitionLine: DXFHatchPatternLine,
        scale: Double,
        extraAngleRad: Double,
        minimumSpacing: Double
    ) -> [CADPrimitive] {
        guard polygon.count >= 3 else { return [] }

        let angleRad = definitionLine.angleDegrees * .pi / 180.0 + extraAngleRad
        let cosA = cos(-angleRad)
        let sinA = sin(-angleRad)
        let cosBack = cos(angleRad)
        let sinBack = sin(angleRad)

        func rotateToLineSpace(_ p: Vector3) -> Vector3 {
            Vector3(x: p.x * cosA - p.y * sinA, y: p.x * sinA + p.y * cosA, z: p.z)
        }
        func rotateBack(_ p: Vector3) -> Vector3 {
            Vector3(x: p.x * cosBack - p.y * sinBack, y: p.x * sinBack + p.y * cosBack, z: p.z)
        }

        let rotatedPoly = polygon.map(rotateToLineSpace)
        let base = Vector3(x: definitionLine.base.x * scale, y: definitionLine.base.y * scale, z: 0)
        let rawSpacing = abs(definitionLine.offset.y * scale)
        let spacing = max(1e-9, max(rawSpacing, minimumSpacing))
        let lineAdvance = definitionLine.offset.x * scale
        let dashes = definitionLine.dashes.map { $0 * scale }

        var minY = Double.infinity
        var maxY = -Double.infinity
        for p in rotatedPoly {
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }

        let startIndex = Int(floor((minY - base.y) / spacing)) - 1
        let endIndex = Int(ceil((maxY - base.y) / spacing)) + 1
        guard startIndex <= endIndex else { return [] }

        var prims: [CADPrimitive] = []
        for lineIndex in startIndex...endIndex {
            let yVal = base.y + Double(lineIndex) * spacing
            var intersections: [Double] = []
            var j = rotatedPoly.count - 1
            for i in 0..<rotatedPoly.count {
                let p1 = rotatedPoly[i]
                let p2 = rotatedPoly[j]
                if (p1.y > yVal && p2.y <= yVal) || (p2.y > yVal && p1.y <= yVal) {
                    if abs(p2.y - p1.y) > 1e-9 {
                        let xVal = p1.x + (yVal - p1.y) * (p2.x - p1.x) / (p2.y - p1.y)
                        intersections.append(xVal)
                    }
                }
                j = i
            }
            intersections.sort()

            let phase = base.x + Double(lineIndex) * lineAdvance
            var k = 0
            while k + 1 < intersections.count {
                appendClippedPatternSegments(
                    x1: intersections[k],
                    x2: intersections[k + 1],
                    y: yVal,
                    dashes: dashes,
                    phase: phase,
                    rotateBack: rotateBack,
                    into: &prims
                )
                k += 2
            }
        }
        return prims
    }

    private static func appendClippedPatternSegments(
        x1: Double,
        x2: Double,
        y: Double,
        dashes: [Double],
        phase: Double,
        rotateBack: (Vector3) -> Vector3,
        into prims: inout [CADPrimitive]
    ) {
        let startX = min(x1, x2)
        let endX = max(x1, x2)
        guard endX - startX > 1e-9 else { return }

        if dashes.isEmpty || dashes.reduce(0.0, { $0 + abs($1) }) <= 1e-9 {
            let p1 = rotateBack(Vector3(x: startX, y: y, z: 0))
            let p2 = rotateBack(Vector3(x: endX, y: y, z: 0))
            prims.append(.line(start: p1, end: p2))
            return
        }

        let period = dashes.reduce(0.0) { $0 + max(abs($1), 1e-9) }
        guard period > 1e-9 else { return }

        var cursor = startX
        var cycleStart = floor((startX - phase) / period) * period + phase
        while cycleStart > startX { cycleStart -= period }

        while cursor < endX - 1e-9 {
            var segmentStart = cycleStart
            for dash in dashes {
                let length = max(abs(dash), 1e-9)
                let segmentEnd = segmentStart + length
                if dash >= 0.0 {
                    let a = max(cursor, segmentStart)
                    let b = min(endX, segmentEnd)
                    if b > a + 1e-9 {
                        if abs(dash) <= 1e-9 {
                            let p = rotateBack(Vector3(x: (a + b) * 0.5, y: y, z: 0))
                            prims.append(.point(position: p))
                        } else {
                            let p1 = rotateBack(Vector3(x: a, y: y, z: 0))
                            let p2 = rotateBack(Vector3(x: b, y: y, z: 0))
                            prims.append(.line(start: p1, end: p2))
                        }
                    }
                }
                segmentStart = segmentEnd
                if segmentStart >= endX { break }
            }
            cycleStart += period
            cursor = max(cursor, min(cycleStart, endX))
        }
    }
}

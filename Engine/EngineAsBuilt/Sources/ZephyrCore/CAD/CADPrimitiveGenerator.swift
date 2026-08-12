import Foundation

// =========================================================================
// MARK: - CADPrimitiveGenerator
//
// Generates rendering primitives from CAD entity descriptions.
// Converts high-level entity types (lines, circles, arcs, polylines,
// splines, hatches, text, etc.) into resolved CADPrimitive arrays that
// the tessellator and vertex builder can consume directly.
//
// This is the main bridge between entity-level CAD data and the
// low-level rendering pipeline.
import SwiftSDL

    public struct TextSpriteSpec: Sendable {
        public let text: String
        public let fontPath: String
        public let fontSize: Float
        public let x: Double
        public let y: Double
        public let z: Double
        public let rotation: Double
        public let height: Double
        public let widthFactor: Double
        public let obliqueAngle: Double
        public let maxWidth: Double?
        public let alignH: Int
        public let alignV: Int
        public let lineSpacingFactor: Double
        public let lineSpacingStyle: Int
        public let color: (UInt8, UInt8, UInt8, UInt8)
        public let backgroundScale: Double?
        public let backgroundColor: (UInt8, UInt8, UInt8, UInt8)?
        public let backgroundUsesViewportColor: Bool
        public let formattedText: FormattedText?

        public init(
            text: String,
            fontPath: String,
            fontSize: Float,
            x: Double,
            y: Double,
            z: Double,
            rotation: Double,
            height: Double,
            widthFactor: Double = 1.0,
            obliqueAngle: Double = 0.0,
            maxWidth: Double?,
            alignH: Int,
            alignV: Int,
            color: (UInt8, UInt8, UInt8, UInt8),
            lineSpacingFactor: Double = 1.0,
            lineSpacingStyle: Int = 1,
            backgroundScale: Double? = nil,
            backgroundColor: (UInt8, UInt8, UInt8, UInt8)? = nil,
            backgroundUsesViewportColor: Bool = false,
            formattedText: FormattedText? = nil
        ) {
            self.text = text
            self.fontPath = fontPath
            self.fontSize = fontSize
            self.x = x
            self.y = y
            self.z = z
            self.rotation = rotation
            self.height = height
            self.widthFactor = widthFactor
            self.obliqueAngle = obliqueAngle
            self.maxWidth = maxWidth
            self.alignH = alignH
            self.alignV = alignV
            self.lineSpacingFactor = lineSpacingFactor
            self.lineSpacingStyle = lineSpacingStyle
            self.color = color
            self.backgroundScale = backgroundScale
            self.backgroundColor = backgroundColor
            self.backgroundUsesViewportColor = backgroundUsesViewportColor
            self.formattedText = formattedText
        }
    }




    /// Lightweight description of a primitive computed in parallel tasks.
    /// All position data is in world-space. Converted to RenderPrimitive in sequential merge.
    public struct PrimitiveSpec: Sendable {
        let type: PrimitiveType
        var points: [SDL_FPoint]
        var rects: [SDL_FRect]
        var corners: [SDL_FPoint]
        let z: Double
        let color: (UInt8, UInt8, UInt8, UInt8)
        let lineWeight: Double
        let geomWidth: Double
        let segmentLineWeights: [Double]
        let isHatchLine: Bool
        let hatchSpacing: Double
        let gradientData: RenderPrimitive.GradientData?
        let usesViewportBackground: Bool

        init(
            type: PrimitiveType,
            points: [SDL_FPoint],
            rects: [SDL_FRect],
            corners: [SDL_FPoint],
            z: Double,
            color: (UInt8, UInt8, UInt8, UInt8),
            lineWeight: Double = 0.0,
            geomWidth: Double = 0.0,
            segmentLineWeights: [Double] = [],
            isHatchLine: Bool = false,
            hatchSpacing: Double = 0.0,
            gradientData: RenderPrimitive.GradientData? = nil,
            usesViewportBackground: Bool = false
        ) {
            self.type = type
            self.points = points
            self.rects = rects
            self.corners = corners
            self.z = z
            self.color = color
            self.lineWeight = lineWeight
            self.geomWidth = geomWidth
            self.segmentLineWeights = segmentLineWeights
            self.isHatchLine = isHatchLine
            self.hatchSpacing = hatchSpacing
            self.gradientData = gradientData
            self.usesViewportBackground = usesViewportBackground
        }

        /// Create RenderPrimitive from spec and add to GeometryManager. Returns the new ID.
        func addTo(
            _ gm: GeometryManager,
            viewportBackground: (UInt8, UInt8, UInt8, UInt8)? = nil
        ) -> SpriteID {
            let effectiveColor = usesViewportBackground
                ? (viewportBackground ?? color)
                : color
            let worldZeroX = gm.renderOrigin.localX(0.0)
            let worldZeroY = gm.renderOrigin.localY(0.0)
            let id: SpriteID
            switch type {
            case .point:
                if let p = points.first {
                    id = gm.addPoint(x: p.x, y: p.y, z: z, color: effectiveColor)
                } else {
                    id = gm.addPoint(x: worldZeroX, y: worldZeroY, z: z, color: effectiveColor)
                }
            case .line:
                if points.count >= 2 {
                    id = gm.addLine(
                        x1: points[0].x, y1: points[0].y,
                        x2: points[1].x, y2: points[1].y,
                        z: z, color: effectiveColor)
                } else {
                    id = gm.addPoint(x: worldZeroX, y: worldZeroY, z: z, color: effectiveColor)
                }
            case .lines:
                id = gm.addLines(points, z: z, color: effectiveColor)
            case .fillRect:
                if !corners.isEmpty {
                    id = gm.addFillCorners(corners, z: z, color: effectiveColor, gradientData: gradientData)
                } else if let r = rects.first {
                    id = gm.addFillRect(
                        x: r.x, y: r.y, w: r.w, h: r.h,
                        z: z, color: effectiveColor)
                } else {
                    id = gm.addPoint(x: worldZeroX, y: worldZeroY, z: z, color: effectiveColor)
                }
            case .fillRects:
                if let r = rects.first {
                    id = gm.addFillRect(
                        x: r.x, y: r.y, w: r.w, h: r.h,
                        z: z, color: effectiveColor)
                } else {
                    id = gm.addPoint(x: worldZeroX, y: worldZeroY, z: z, color: effectiveColor)
                }
            case .rect:
                if !corners.isEmpty {
                    id = gm.addLines(corners, z: z, color: effectiveColor)
                } else if let r = rects.first {
                    id = gm.addRect(
                        x: r.x, y: r.y, w: r.w, h: r.h,
                        z: z, color: effectiveColor)
                } else {
                    id = gm.addPoint(x: worldZeroX, y: worldZeroY, z: z, color: effectiveColor)
                }
            case .points, .rects:
                id = gm.addPoint(x: worldZeroX, y: worldZeroY, z: z, color: effectiveColor)
            }
            if let prim = gm.getPrimitive(id: id) {
                prim.lineWeight = lineWeight
                prim.geomWidth = geomWidth
                prim.segmentLineWeights = segmentLineWeights
                prim.isHatchLine = isHatchLine
                prim.hatchSpacing = hatchSpacing
                prim.usesViewportBackgroundColor = usesViewportBackground
            }
            return id
        }
    }





    /// Lightweight description of an image primitive computed in parallel tasks.
    /// Texture loading happens later in the apply phase (CADRendererBridge).
    public struct ImageSpec: Sendable {
        public let imageName: String
        public let c0: SDL_FPoint  // insertion corner
        public let c1: SDL_FPoint  // insertion + uAxis
        public let c2: SDL_FPoint  // insertion + uAxis + vAxis
        public let c3: SDL_FPoint  // insertion + vAxis
        public let z: Double
        public let tint: (UInt8, UInt8, UInt8, UInt8)?
        public let clipPolygon: [Vector3]?
        public let clipInverted: Bool

        public init(
            imageName: String,
            c0: SDL_FPoint, c1: SDL_FPoint, c2: SDL_FPoint, c3: SDL_FPoint,
            z: Double,
            tint: (UInt8, UInt8, UInt8, UInt8)? = nil,
            clipPolygon: [Vector3]? = nil,
            clipInverted: Bool = false
        ) {
            self.imageName = imageName
            self.c0 = c0; self.c1 = c1; self.c2 = c2; self.c3 = c3
            self.z = z
            self.tint = tint
            self.clipPolygon = clipPolygon
            self.clipInverted = clipInverted
        }
    }




    public typealias EntityResult = (
        handle: UUID,
        specs: [PrimitiveSpec],
        textSprites: [TextSpriteSpec],
        imageSpecs: [ImageSpec],
        clipPolygon: [Vector3]?,
        clipInverted: Bool
    )


public enum CADPrimitiveGenerator {

    private struct PolylinePointKey: Hashable, Comparable {
        let x: UInt64
        let y: UInt64
        let z: UInt64

        init(_ point: Vector3) {
            x = point.x == 0 ? 0 : point.x.bitPattern
            y = point.y == 0 ? 0 : point.y.bitPattern
            z = point.z == 0 ? 0 : point.z.bitPattern
        }

        static func < (lhs: PolylinePointKey, rhs: PolylinePointKey) -> Bool {
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.z < rhs.z
        }
    }

    private struct PolylineSegmentKey: Hashable {
        let first: PolylinePointKey
        let second: PolylinePointKey

        init(_ start: Vector3, _ end: Vector3) {
            let a = PolylinePointKey(start)
            let b = PolylinePointKey(end)
            if b < a {
                first = b
                second = a
            } else {
                first = a
                second = b
            }
        }
    }

    /// Maps a DXF linetype name to a dash pattern in drawing units
    /// (alternating draw/gap lengths, starting with a draw).
    /// Returns nil for continuous/inherited linetypes (no dashing).
    /// Shared by the live render path (computePrimitiveSpecs) and the DXF
    /// importer, which bakes dashes for entities inside block definitions.
    ///
    /// - Parameter name: The linetype name (case-insensitive).
    /// - Parameter linetypePatterns: Document-level patterns from DXF import or EAB load.
    ///   Checked first; falls back to hardcoded heuristics when nil or miss.
    public static func dashPattern(for name: String, linetypePatterns: [String: [Double]]? = nil) -> [Double]? {
        let n = name.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if n == "CONTINUOUS" || n == "SOLID" || n.isEmpty || n == "BYLAYER" || n == "BYBLOCK" {
            return nil
        }
        // Consult document-level linetype table first (exact match from DXF/EAB).
        if let patterns = linetypePatterns, let exact = patterns[n] {
            return exact.isEmpty ? nil : exact
        }
        if n.contains("DASHED") {
            return [10.0, 5.0]
        }
        if n.contains("HIDDEN") {
            return [5.0, 5.0]
        }
        if n.contains("DASHDOT") {
            return [10.0, 5.0, 2.0, 5.0]
        }
        if n.contains("DOT") {
            return [2.0, 5.0]
        }
        if n.contains("CENTER") {
            return [15.0, 5.0, 3.0, 5.0]
        }
        if n.contains("PHANTOM") {
            return [20.0, 5.0, 3.0, 5.0, 3.0, 5.0]
        }
        return [10.0, 5.0] // fallback
    }

    /// Compute PrimitiveSpec(s) for a single CADPrimitive. Pure function (no side effects).
    /// Runs in parallel tasks — must not access shared mutable state.
    public static func computePrimitiveSpecs(
        from primitive: CADPrimitive, transform: Transform3D,
        color: (UInt8, UInt8, UInt8, UInt8), z: Double,
        lineType: String = "CONTINUOUS",
        lineWeight: Double = 0.25,
        lineTypeScale: Double = 1.0,
        geomWidth: Double = 0.0,
        textWidthFactor: Double = 1.0,
        textObliqueAngle: Double = 0.0,
        textStyleFonts: [String: String] = [:],
        linetypePatterns: [String: [Double]] = [:],
        opacityMultiplier: Double = 1.0,
        penStrokeBrushSettings: PenStrokeBrushSettings? = nil,
        penStrokeStabilizationSettings: PenStrokeStabilizationSettings? = nil,
        renderOrigin: CADRenderOrigin = .zero,
        splineTessellationDivisor: Double = 5000.0
    ) -> [PrimitiveSpec] {
        // Extract primitive color override if present
        let primColor: ColorRGBA?
        switch primitive {
        case .point(_, let c): primColor = c
        case .line(_, _, let c): primColor = c
        case .rect(_, _, let c): primColor = c
        case .fillRect(_, _, let c): primColor = c
        case .polygon(_, let c): primColor = c
        case .polyline(_, let c): primColor = c
        case .fillPolygon(_, let c): primColor = c
        case .fillComplexPolygon(_, _, let c): primColor = c
        case .gradient(_, _, _, _, _, _): primColor = nil  // colors come from associated values
        case .circle(_, _, let c): primColor = c
        case .arc(_, _, _, _, let c): primColor = c
        case .spline(_, _, _, _, let c): primColor = c
        case .penStroke(_, _, let c): primColor = c
        case .text(_, _, _, _, _, _, _, _, let c): primColor = c
        case .ellipse(_, _, _, let c): primColor = c
        case .hatch(_, _, _, _, let c, _): primColor = c
        case .hatchPath(_, _, _, _, _, let c, _): primColor = c
        case .ray(_, _, let c): primColor = c
        case .image(_, _, _, _, _, let c): primColor = c
        case .table(_, _, let c): primColor = c
        }
        let clampedOpacity = max(0.0, min(1.0, opacityMultiplier))
        func applyingOpacity(_ value: ColorRGBA) -> (UInt8, UInt8, UInt8, UInt8) {
            let alpha = UInt8(min(255, Double(value.a) * clampedOpacity))
            return (value.r, value.g, value.b, alpha)
        }
        let finalColor = primColor.map(applyingOpacity) ?? color

        let planarScale = (abs(transform.scale.x) + abs(transform.scale.y)) * 0.5
        let geometryScale = planarScale.isFinite && planarScale > 1e-12 ? planarScale : 1.0
        let transformedGeomWidth = geomWidth > 0.0 ? geomWidth * geometryScale : 0.0

        @inline(__always)
        func renderPoint(_ point: Vector3) -> SDL_FPoint {
            SDL_FPoint(
                x: renderOrigin.localX(point.x),
                y: renderOrigin.localY(point.y))
        }

        func makeLineSpec(p1: SDL_FPoint, p2: SDL_FPoint, weight: Double, z: Double, color: (UInt8, UInt8, UInt8, UInt8)) -> PrimitiveSpec {
            return PrimitiveSpec(type: .line, points: [p1, p2], rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: transformedGeomWidth)
        }

        func makePathSpecs(points: [SDL_FPoint], dashPattern: [Double]?, scale: Double, weight: Double, z: Double, color: (UInt8, UInt8, UInt8, UInt8)) -> [PrimitiveSpec] {
            guard points.count >= 2 else { return [] }
            
            if let pattern = dashPattern {
                var pathLength: Double = 0.0
                for i in 0..<(points.count - 1) {
                    let dx = Double(points[i+1].x - points[i].x)
                    let dy = Double(points[i+1].y - points[i].y)
                    pathLength += sqrt(dx*dx + dy*dy)
                }

                let isSigned = pattern.contains { $0 <= 0 }
                let effectiveScale = (scale > 0 ? scale : 1.0) * geometryScale
                let cycleLength: Double = isSigned
                    ? pattern.reduce(0.0) { $0 + abs($1) } * effectiveScale
                    : pattern.reduce(0.0, +) * effectiveScale

                var steps: [(len: Double, draw: Bool)] = []
                if isSigned {
                    let dotLength = max(cycleLength * 0.01, 1e-6)
                    for v in pattern {
                        if v > 0 { steps.append((v * effectiveScale, true)) }
                        else if v < 0 { steps.append((-v * effectiveScale, false)) }
                        else { steps.append((dotLength, true)) }
                    }
                } else {
                    for (idx, v) in pattern.enumerated() {
                        steps.append((v * effectiveScale, idx % 2 == 0))
                    }
                }
                
                // pathLength is already calculated above
                
                // If the dash cycle is extremely small relative to the path length,
                // or if we would generate more than 10000 dash cycles, treat it as solid (continuous).
                if cycleLength > 1e-6 && (pathLength / cycleLength) > 10000.0 {
                    return [PrimitiveSpec(type: .lines, points: points, rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: transformedGeomWidth)]
                }
                
                if steps.isEmpty { return [] }
                
                var dashedPolylines: [[SDL_FPoint]] = []
                var currentDash: [SDL_FPoint] = []
                
                func addSubLine(p1: SDL_FPoint, p2: SDL_FPoint) {
                    if currentDash.isEmpty {
                        currentDash.append(p1)
                    }
                    currentDash.append(p2)
                }
                
                func endDash() {
                    if currentDash.count >= 2 {
                        dashedPolylines.append(currentDash)
                    }
                    currentDash = []
                }
                
                var currentPtIndex = 0
                var segmentStart = points[0]
                var segmentEnd = points[1]
                var dx = Double(segmentEnd.x - segmentStart.x)
                var dy = Double(segmentEnd.y - segmentStart.y)
                var segmentLen = sqrt(dx*dx + dy*dy)
                var segmentUsed: Double = 0.0
                
                var patternIndex = 0
                var drawing = steps[0].draw
                
                while currentPtIndex < points.count - 1 {
                    if segmentLen <= 1e-5 {
                        currentPtIndex += 1
                        if currentPtIndex < points.count - 1 {
                            segmentStart = points[currentPtIndex]
                            segmentEnd = points[currentPtIndex + 1]
                            dx = Double(segmentEnd.x - segmentStart.x)
                            dy = Double(segmentEnd.y - segmentStart.y)
                            segmentLen = sqrt(dx*dx + dy*dy)
                            segmentUsed = 0.0
                        }
                        continue
                    }
                    
                    let step = steps[patternIndex].len
                    let segmentRemaining = segmentLen - segmentUsed
                    
                    if step <= segmentRemaining {
                        let nextUsed = segmentUsed + step
                        let t1 = Float(segmentUsed / segmentLen)
                        let t2 = Float(nextUsed / segmentLen)
                        let p1 = SDL_FPoint(x: segmentStart.x + Float(dx) * t1, y: segmentStart.y + Float(dy) * t1)
                        let p2 = SDL_FPoint(x: segmentStart.x + Float(dx) * t2, y: segmentStart.y + Float(dy) * t2)
                        
                        if drawing { addSubLine(p1: p1, p2: p2) }
                        
                        segmentUsed = nextUsed
                        patternIndex = (patternIndex + 1) % steps.count
                        let nextDrawing = steps[patternIndex].draw
                        if drawing && !nextDrawing { endDash() }
                        drawing = nextDrawing
                    } else {
                        let t1 = Float(segmentUsed / segmentLen)
                        let p1 = SDL_FPoint(x: segmentStart.x + Float(dx) * t1, y: segmentStart.y + Float(dy) * t1)
                        let p2 = segmentEnd
                        
                        if drawing { addSubLine(p1: p1, p2: p2) }
                        
                        var remainingStep = step - segmentRemaining
                        currentPtIndex += 1
                        if currentPtIndex < points.count - 1 {
                            segmentStart = points[currentPtIndex]
                            segmentEnd = points[currentPtIndex + 1]
                            dx = Double(segmentEnd.x - segmentStart.x)
                            dy = Double(segmentEnd.y - segmentStart.y)
                            segmentLen = sqrt(dx*dx + dy*dy)
                            segmentUsed = 0.0
                            
                            while remainingStep > 0 && currentPtIndex < points.count - 1 {
                                if segmentLen <= 1e-5 {
                                    currentPtIndex += 1
                                    if currentPtIndex < points.count - 1 {
                                        segmentStart = points[currentPtIndex]
                                        segmentEnd = points[currentPtIndex + 1]
                                        dx = Double(segmentEnd.x - segmentStart.x)
                                        dy = Double(segmentEnd.y - segmentStart.y)
                                        segmentLen = sqrt(dx*dx + dy*dy)
                                        segmentUsed = 0.0
                                    }
                                    continue
                                }
                                
                                if remainingStep <= segmentLen {
                                    let nextUsed = remainingStep
                                    let t = Float(nextUsed / segmentLen)
                                    let p1_new = segmentStart
                                    let p2_new = SDL_FPoint(x: segmentStart.x + Float(dx) * t, y: segmentStart.y + Float(dy) * t)
                                    
                                    if drawing { addSubLine(p1: p1_new, p2: p2_new) }
                                    
                                    segmentUsed = nextUsed
                                    patternIndex = (patternIndex + 1) % steps.count
                                    let nextDrawing = steps[patternIndex].draw
                                    if drawing && !nextDrawing { endDash() }
                                    drawing = nextDrawing
                                    remainingStep = 0
                                } else {
                                    let p1_new = segmentStart
                                    let p2_new = segmentEnd
                                    
                                    if drawing { addSubLine(p1: p1_new, p2: p2_new) }
                                    
                                    remainingStep -= segmentLen
                                    currentPtIndex += 1
                                    if currentPtIndex < points.count - 1 {
                                        segmentStart = points[currentPtIndex]
                                        segmentEnd = points[currentPtIndex + 1]
                                        dx = Double(segmentEnd.x - segmentStart.x)
                                        dy = Double(segmentEnd.y - segmentStart.y)
                                        segmentLen = sqrt(dx*dx + dy*dy)
                                        segmentUsed = 0.0
                                    }
                                }
                            }
                        } else {
                            break
                        }
                    }
                }
                endDash()
                
                return dashedPolylines.map {
                    PrimitiveSpec(type: .lines, points: $0, rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: transformedGeomWidth)
                }
            }
            
            return [PrimitiveSpec(type: .lines, points: points, rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: transformedGeomWidth)]
        }

        var specs: [PrimitiveSpec] = []
        let dashPattern = CADPrimitiveGenerator.dashPattern(for: lineType, linetypePatterns: linetypePatterns)
        
        switch primitive {
        case .point(let pos, _):
            let wp = transform.transformPoint(pos)
            specs.append(
                PrimitiveSpec(
                    type: .point,
                    points: [renderPoint(wp)],
                    rects: [], corners: [], z: z, color: finalColor))

        case .line(let start, let end, _):
            let ws = transform.transformPoint(start)
            let we = transform.transformPoint(end)
            let pts = [
                renderPoint(ws),
                renderPoint(we),
            ]
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .rect(let origin, let size, _):
            let c1 = transform.transformPoint(origin)
            let c2 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z))
            let c3 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z))
            let c4 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z))
            let pts = [
                renderPoint(c1),
                renderPoint(c2),
                renderPoint(c3),
                renderPoint(c4),
                renderPoint(c1),
            ]
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .fillRect(let origin, let size, _):
            let c1 = transform.transformPoint(origin)
            let c2 = transform.transformPoint(
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z))
            let c3 = transform.transformPoint(
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z))
            let c4 = transform.transformPoint(
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z))
            specs.append(
                PrimitiveSpec(
                    type: .fillRect,
                    points: [], rects: [],
                    corners: [
                        renderPoint(c1),
                        renderPoint(c2),
                        renderPoint(c3),
                        renderPoint(c4),
                    ],
                    z: z, color: finalColor))

        case .polygon(let points, _):
            var wp = points.map { p -> SDL_FPoint in
                let t = transform.transformPoint(p)
                return renderPoint(t)
            }
            if let first = wp.first {
                wp.append(first)
            }
            specs.append(contentsOf: makePathSpecs(points: wp, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .polyline(let path, _):
            if path.isHatchBoundaryCarrier { break }

            let hasVariableWidths = path.vertices.contains {
                $0.startWidth > 1e-12 || $0.endWidth > 1e-12
            }
            if hasVariableWidths {
                for segment in 0..<path.segmentCount {
                    let vertex = path.vertices[segment]
                    let divisions: Int
                    if let arc = path.arcParameters(forSegment: segment) {
                        divisions = Swift.max(4, Int(ceil(abs(arc.sweep) * 12.0)))
                    } else {
                        divisions = 1
                    }
                    for step in 0..<divisions {
                        let t0 = Double(step) / Double(divisions)
                        let t1 = Double(step + 1) / Double(divisions)
                        let p0 = transform.transformPoint(path.point(onSegment: segment, t: t0))
                        let p1 = transform.transformPoint(path.point(onSegment: segment, t: t1))
                        let width0 = vertex.startWidth + (vertex.endWidth - vertex.startWidth) * t0
                        let width1 = vertex.startWidth + (vertex.endWidth - vertex.startWidth) * t1
                        let width = Swift.max(0, (width0 + width1) * 0.5 * geometryScale)
                        specs.append(PrimitiveSpec(
                            type: .line,
                            points: [renderPoint(p0), renderPoint(p1)],
                            rects: [], corners: [], z: z, color: finalColor,
                            lineWeight: lineWeight,
                            geomWidth: width))
                    }
                }
            } else if dashPattern != nil && !path.lineTypeGenerationEnabled {
                var renderedStraightSegments = Set<PolylineSegmentKey>()

                for segment in 0..<path.segmentCount {
                    let startVertex = path.vertices[segment]
                    let endVertex = path.vertices[path.endVertexIndex(forSegment: segment)]

                    if abs(startVertex.bulge) <= 1e-12 {
                        let key = PolylineSegmentKey(startVertex.position, endVertex.position)
                        if !renderedStraightSegments.insert(key).inserted { continue }
                    }

                    let localPoints: [Vector3]
                    if let arc = path.arcParameters(forSegment: segment) {
                        let divisions = Swift.max(4, Int(ceil(abs(arc.sweep) * 12.0)))
                        localPoints = (0...divisions).map { step in
                            path.point(onSegment: segment, t: Double(step) / Double(divisions))
                        }
                    } else {
                        localPoints = [startVertex.position, endVertex.position]
                    }

                    let worldPoints = localPoints.map { point -> SDL_FPoint in
                        let transformed = transform.transformPoint(point)
                        return renderPoint(transformed)
                    }
                    specs.append(contentsOf: makePathSpecs(points: worldPoints, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))
                }
            } else {
                let wp = path.tessellatedPoints().map { p -> SDL_FPoint in
                    let t = transform.transformPoint(p)
                    return renderPoint(t)
                }
                specs.append(contentsOf: makePathSpecs(points: wp, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))
            }

        case .fillPolygon(let points, _):
            let wp = points.map { p -> SDL_FPoint in
                let t = transform.transformPoint(p)
                return renderPoint(t)
            }
            let triangles = CADTessellator.triangulatePolygon(wp)
            specs.append(
                PrimitiveSpec(
                    type: .fillRect,
                    points: [], rects: [], corners: triangles, z: z, color: finalColor))

        case .fillComplexPolygon(let outer, let holes, _):
            let s = CADTessellator.computeMultiLoopFillSpecs(
                outer: outer, holes: holes, transform: transform,
                color: finalColor, z: z, renderOrigin: renderOrigin)
            specs.append(s)

        case .gradient(let outer, let holes, _, let gradAngle, let c1, let c2):
            let gradColor1 = applyingOpacity(c1)
            let gradColor2 = applyingOpacity(c2)
            /* Add block rotation to gradient angle */
            let effectiveAngle = gradAngle + transform.rotation
            let s = CADTessellator.computeGradientFillSpecs(
                outer: outer, holes: holes, transform: transform,
                color1: gradColor1, color2: gradColor2,
                angle: effectiveAngle, z: z,
                renderOrigin: renderOrigin)
            specs.append(contentsOf: s)

        case .circle(let center, let radius, _):
            let segments = 64
            var pts: [SDL_FPoint] = []
            for i in 0...segments {
                let angle = Double(i) * 2.0 * .pi / Double(segments)
                let local = Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius, z: center.z)
                let wp = transform.transformPoint(local)
                pts.append(renderPoint(wp))
            }
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let segments = 32
            // Normalize to a positive CCW sweep (see description in original code)
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * .pi }
            var pts: [SDL_FPoint] = []
            for i in 0...segments {
                let t = Double(i) / Double(segments)
                let angle = startAngle + span * t
                let local = Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius, z: center.z)
                let wp = transform.transformPoint(local)
                pts.append(renderPoint(wp))
            }
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            guard !controlPoints.isEmpty else { break }
            let worldControlPoints = controlPoints.map { transform.transformPoint($0) }
            let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)

            var minPt = worldControlPoints[0]
            var maxPt = worldControlPoints[0]
            for pt in worldControlPoints.dropFirst() {
                minPt.x = min(minPt.x, pt.x); minPt.y = min(minPt.y, pt.y); minPt.z = min(minPt.z, pt.z)
                maxPt.x = max(maxPt.x, pt.x); maxPt.y = max(maxPt.y, pt.y); maxPt.z = max(maxPt.z, pt.z)
            }
            let diag = max((maxPt - minPt).magnitude, 1.0)
            let chordTolerance = max(0.001, diag / splineTessellationDivisor)

            let evaluated = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                degree: degree,
                knots: knots,
                controlPoints: worldControlPoints,
                weights: w,
                chordTolerance: chordTolerance,
                maxDepth: 10,
                maxSegments: 4096)
            guard evaluated.count >= 2 else { break }
            let pts = evaluated.map { renderPoint($0) }
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .penStroke(let vertices, let baseLineWeight, _):
            guard vertices.count >= 2 else { break }
            let brush = penStrokeBrushSettings ?? PenStrokeBrushSettings.defaults(baseLineWeight: baseLineWeight)
            let stabilization = penStrokeStabilizationSettings ?? PenStrokeStabilizationSettings.defaults
            let sourceVertices = vertices.map { vertex in
                PenStrokeVertex(
                    position: transform.transformPoint(vertex.position),
                    pressure: vertex.pressure,
                    xtilt: vertex.xtilt,
                    ytilt: vertex.ytilt,
                    rotation: vertex.rotation)
            }

            var renderVertices = sourceVertices
            if stabilization.useSpline,
               let fit = PenStrokeSplineFitter.fit(vertices: vertices, settings: stabilization),
               fit.controlVertices.count >= 2 {
                let worldControlPoints = fit.controlVertices.map {
                    transform.transformPoint($0.position)
                }
                var minPt = worldControlPoints[0]
                var maxPt = worldControlPoints[0]
                for pt in worldControlPoints.dropFirst() {
                    minPt.x = min(minPt.x, pt.x); minPt.y = min(minPt.y, pt.y); minPt.z = min(minPt.z, pt.z)
                    maxPt.x = max(maxPt.x, pt.x); maxPt.y = max(maxPt.y, pt.y); maxPt.z = max(maxPt.z, pt.z)
                }
                let diag = max((maxPt - minPt).magnitude, 1.0)
                let chordTolerance = max(0.0005, diag / (4000.0 + 8000.0 * stabilization.amount))
                let evaluated = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
                    degree: fit.degree,
                    knots: fit.knots,
                    controlPoints: worldControlPoints,
                    weights: fit.weights,
                    chordTolerance: chordTolerance,
                    maxDepth: 10,
                    maxSegments: 4096)
                if evaluated.count >= 2 {
                    renderVertices = PenStrokeSplineFitter.interpolatedVertices(
                        source: sourceVertices,
                        positions: evaluated)
                }
            }

            let worldPoints = renderVertices.map { renderPoint($0.position) }
            var segmentWeights: [Double] = []
            segmentWeights.reserveCapacity(worldPoints.count - 1)
            for i in 0..<(worldPoints.count - 1) {
                let p0 = worldPoints[i]
                let p1 = worldPoints[i + 1]
                let dx = Double(p1.x - p0.x)
                let dy = Double(p1.y - p0.y)
                let segmentAngle = atan2(dy, dx)
                segmentWeights.append(brush.lineWeight(
                    from: renderVertices[i],
                    to: renderVertices[i + 1],
                    segmentAngle: segmentAngle))
            }
            specs.append(PrimitiveSpec(
                type: .lines,
                points: worldPoints,
                rects: [],
                corners: [],
                z: z,
                color: finalColor,
                lineWeight: segmentWeights.max() ?? baseLineWeight,
                geomWidth: 0.0,
                segmentLineWeights: segmentWeights))
            
        case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, _):
            let fontFile = CADFontManager.resolveTextStyleFont(
                styleName: style,
                textStyleFonts: textStyleFonts)

            let origin = transform.transformPoint(pos)
            let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
            let localY = Vector3(x: -sin(rotation), y: cos(rotation), z: 0)
            let worldX = transform.transformPoint(pos + localX) - origin
            let worldY = transform.transformPoint(pos + localY) - origin

            let finalRotation = atan2(worldX.y, worldX.x)
            let heightScale = max(worldY.magnitude, 1e-12)
            let widthScale = max(worldX.magnitude, 1e-12)
            let finalHeight = height * heightScale
            let finalWidthFactor = max(textWidthFactor, 1e-9)
                * widthScale / heightScale
            let finalMaxWidth = mtextWidth.map { $0 * widthScale }

            var localSpecs: [PrimitiveSpec] = []
            if let font = CADFontManager.getOrLoadSHXFont(filename: fontFile) {
                let textPrims = font.renderText(
                    text,
                    origin: origin,
                    height: finalHeight,
                    rotation: finalRotation,
                    alignH: alignH,
                    alignV: alignV,
                    widthFactor: finalWidthFactor,
                    obliqueAngle: textObliqueAngle,
                    maxWidth: finalMaxWidth
                )
                if textPrims.count > 500 {
                    let preview = text.prefix(40).replacingOccurrences(of: "\n", with: "\\n")
                    print("[PrimGen] SHX text '\(preview)...' → \(textPrims.count) line primitives (h=\(finalHeight))")
                }

                var localZ = z
                for prim in textPrims {
                    let s = computePrimitiveSpecs(
                        from: prim,
                        transform: .identity,
                        color: finalColor,
                        z: localZ,
                        lineType: lineType,
                        lineWeight: lineWeight,
                        lineTypeScale: lineTypeScale,
                        geomWidth: geomWidth,
                        textStyleFonts: textStyleFonts,
                        linetypePatterns: linetypePatterns,
                        renderOrigin: renderOrigin
                    )
                    localSpecs.append(contentsOf: s)
                    localZ += 0.01
                }
            }
            specs.append(contentsOf: localSpecs)



        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let majorLen = majorAxis.magnitude
            let minorLen = majorLen * minorRatio
            guard majorLen > 1e-12, minorLen > 1e-12 else { break }
            let ellipseRotation = atan2(majorAxis.y, majorAxis.x)
            let cosRot = cos(ellipseRotation)
            let sinRot = sin(ellipseRotation)
            let segments = 64
            var pts: [SDL_FPoint] = []
            for i in 0...segments {
                let t = Double(i) * 2.0 * .pi / Double(segments)
                let px = majorLen * cos(t)
                let py = minorLen * sin(t)
                let rx = px * cosRot - py * sinRot + center.x
                let ry = px * sinRot + py * cosRot + center.y
                let local = Vector3(x: rx, y: ry, z: center.z)
                let wp = transform.transformPoint(local)
                pts.append(renderPoint(wp))
            }
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .hatch(let boundary, let pattern, let hatchScale, let hatchAngle, _, let backgroundColor):
            guard boundary.count >= 3 else { break }
            let transformedHatchScale = hatchScale * geometryScale
            let hatchLoops = splitConnectedHatchBoundary(boundary)
            let backgroundZ = z - 0.001
            let foregroundZ = z

            if let bg = backgroundColor {
                let bgColor = applyingOpacity(bg)
                specs.append(CADTessellator.computeMultiLoopFillSpecs(
                    outer: hatchLoops.outer,
                    holes: hatchLoops.holes,
                    transform: transform,
                    color: bgColor,
                    z: backgroundZ,
                    renderOrigin: renderOrigin))
            }
            if pattern.uppercased() == "SOLID" || pattern.isEmpty {
                specs.append(CADTessellator.computeMultiLoopFillSpecs(
                    outer: hatchLoops.outer,
                    holes: hatchLoops.holes,
                    transform: transform,
                    color: finalColor,
                    z: foregroundZ,
                    renderOrigin: renderOrigin))
            } else {
                // Patterned hatch: generate line pattern with zoom-aware adaptive spacing.
                // When zoomed out, scale up spacing so hatch lines don't explode primitive count
                // for features smaller than a pixel.
                // Work in world space.  The previous code generated lines from an
                // already-transformed polygon and then transformed each generated
                // line a second time.  That is harmless only for identity transforms
                // and breaks hatches inside transformed INSERTs.
                let polyPoints = boundary.map { transform.transformPoint($0) }

                let adaptiveMinimumSpacing = DXFHatchGenerator.adaptiveMinimumSpacing(for: polyPoints)
                let nominalSpacing = DXFHatchGenerator.effectiveSpacing(patternName: pattern, scale: transformedHatchScale)
                let spacing = max(nominalSpacing, adaptiveMinimumSpacing)

                let hatchLines = DXFHatchGenerator.generatePatternHatch(
                    polygon: polyPoints,
                    patternName: pattern,
                    scale: transformedHatchScale,
                    angleDegrees: hatchAngle * 180.0 / .pi,
                    minimumSpacing: adaptiveMinimumSpacing
                )

                for hline in hatchLines {
                    switch hline {
                    case .line(let s, let e, _):
                        specs.append(PrimitiveSpec(
                            type: .line,
                            points: [renderPoint(s),
                                     renderPoint(e)],
                            rects: [], corners: [],
                            z: foregroundZ, color: finalColor,
                            lineWeight: 0.0, geomWidth: 0.0,
                            isHatchLine: true,
                            hatchSpacing: spacing))
                    case .point(let p, _):
                        specs.append(PrimitiveSpec(
                            type: .point,
                            points: [renderPoint(p)],
                            rects: [], corners: [],
                            z: foregroundZ, color: finalColor,
                            lineWeight: 0.0, geomWidth: 0.0,
                            isHatchLine: true,
                            hatchSpacing: spacing))
                    default:
                        break
                    }
                }
            }

        case .hatchPath(let boundaryPath, let holePaths, let pattern, let hatchScale, let hatchAngle, _, let backgroundColor):
            let transformedHatchScale = hatchScale * geometryScale
            let outer = cleanLoop(boundaryPath.tessellatedPoints())
            let holes = holePaths.map { cleanLoop($0.tessellatedPoints()) }.filter { $0.count >= 3 }
            guard outer.count >= 3 else { break }
            let backgroundZ = z - 0.001
            let foregroundZ = z

            if let bg = backgroundColor {
                let bgColor = applyingOpacity(bg)
                specs.append(CADTessellator.computeMultiLoopFillSpecs(
                    outer: outer,
                    holes: holes,
                    transform: transform,
                    color: bgColor,
                    z: backgroundZ,
                    renderOrigin: renderOrigin))
            }
            if pattern.uppercased() == "SOLID" || pattern.isEmpty {
                specs.append(CADTessellator.computeMultiLoopFillSpecs(
                    outer: outer,
                    holes: holes,
                    transform: transform,
                    color: finalColor,
                    z: foregroundZ,
                    renderOrigin: renderOrigin))
            } else {
                let transformedOuter = outer.map { transform.transformPoint($0) }
                let transformedHoles = holes.map { $0.map { transform.transformPoint($0) } }
                let patternPolygon = transformedHoles.isEmpty
                    ? transformedOuter
                    : DXFHatchGenerator.connectHoles(outer: transformedOuter, holes: transformedHoles)
                let adaptiveMinimumSpacing = DXFHatchGenerator.adaptiveMinimumSpacing(for: patternPolygon)
                let nominalSpacing = DXFHatchGenerator.effectiveSpacing(patternName: pattern, scale: transformedHatchScale)
                let spacing = max(nominalSpacing, adaptiveMinimumSpacing)

                let hatchLines = DXFHatchGenerator.generatePatternHatch(
                    polygon: patternPolygon,
                    patternName: pattern,
                    scale: transformedHatchScale,
                    angleDegrees: hatchAngle * 180.0 / .pi,
                    minimumSpacing: adaptiveMinimumSpacing
                )

                for hline in hatchLines {
                    switch hline {
                    case .line(let s, let e, _):
                        specs.append(PrimitiveSpec(
                            type: .line,
                            points: [renderPoint(s),
                                     renderPoint(e)],
                            rects: [], corners: [],
                            z: foregroundZ, color: finalColor,
                            lineWeight: 0.0, geomWidth: 0.0,
                            isHatchLine: true,
                            hatchSpacing: spacing))
                    case .point(let p, _):
                        specs.append(PrimitiveSpec(
                            type: .point,
                            points: [renderPoint(p)],
                            rects: [], corners: [],
                            z: foregroundZ, color: finalColor,
                            lineWeight: 0.0, geomWidth: 0.0,
                            isHatchLine: true,
                            hatchSpacing: spacing))
                    default:
                        break
                    }
                }
            }

        case .ray(let start, let direction, _):
            let ws = transform.transformPoint(start)
            _ = transform.transformPoint(Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z))
            // Extend ray in direction to a large distance (100,000 units)
            let dirNorm = direction.magnitude
            guard dirNorm > 1e-12 else { break }
            let unitDir = Vector3(x: direction.x / dirNorm, y: direction.y / dirNorm, z: 0)
            let farEndWorld = Vector3(x: ws.x + unitDir.x * 100_000, y: ws.y + unitDir.y * 100_000, z: ws.z)
            let p1 = renderPoint(ws)
            let p2 = renderPoint(farEndWorld)
            specs.append(makeLineSpec(p1: p1, p2: p2, weight: lineWeight, z: z, color: finalColor))

        case .image:
            // Images are not rendered as geometry primitives.
            // ImageSpec is produced in CADRendererBridge.computeSpecs instead.
            break
        case .table(let data, let origin, _):
            // Generate visual primitives (lines, text, fillRects) from table data.
            // The tessellator builds in local space then applies the entity transform.
            let visualPrims = DataTableTessellator.generateVisualPrimitives(
                data: data, origin: origin, transform: transform)
            for vp in visualPrims {
                specs.append(contentsOf: computePrimitiveSpecs(
                    from: vp, transform: .identity,
                    color: finalColor, z: z,
                    lineType: lineType, lineWeight: lineWeight,
                    lineTypeScale: lineTypeScale, geomWidth: geomWidth,
                    textWidthFactor: textWidthFactor,
                    textStyleFonts: textStyleFonts,
                    linetypePatterns: linetypePatterns,
                    opacityMultiplier: opacityMultiplier,
                    renderOrigin: renderOrigin,
                    splineTessellationDivisor: splineTessellationDivisor))
            }
        }
        return specs
    }


    private static func cleanLoop(_ points: [Vector3]) -> [Vector3] {
        guard !points.isEmpty else { return [] }
        var out: [Vector3] = []
        out.reserveCapacity(points.count)
        for point in points {
            if let last = out.last {
                let dx = point.x - last.x
                let dy = point.y - last.y
                let dz = point.z - last.z
                if dx * dx + dy * dy + dz * dz < 1.0e-12 { continue }
            }
            out.append(point)
        }
        if out.count > 1,
           let first = out.first,
           let last = out.last {
            let dx = first.x - last.x
            let dy = first.y - last.y
            let dz = first.z - last.z
            if dx * dx + dy * dy + dz * dz < 1.0e-12 { out.removeLast() }
        }
        return out
    }

    private static func splitConnectedHatchBoundary(_ boundary: [Vector3]) -> (outer: [Vector3], holes: [[Vector3]]) {
        var points = normalizedLoop(boundary)
        var holes: [[Vector3]] = []

        while points.count >= 7 {
            var foundBridge: (start: Int, close: Int)? = nil

            if points.count > 4 {
                outerLoop: for start in 1..<(points.count - 2) {
                    let minClose = start + 3
                    guard minClose < points.count - 1 else { continue }
                    for close in minClose..<(points.count - 1) {
                        if nearlyEqual(points[start], points[close])
                            && nearlyEqual(points[start - 1], points[close + 1]) {
                            foundBridge = (start, close)
                            break outerLoop
                        }
                    }
                }
            }

            guard let bridge = foundBridge else { break }

            let hole = normalizedLoop(Array(points[bridge.start..<bridge.close]))
            if hole.count >= 3 { holes.append(hole) }
            points.removeSubrange(bridge.start...(bridge.close + 1))
            points = removeConsecutiveDuplicates(points)
        }

        let outer = normalizedLoop(removeConsecutiveDuplicates(points))
        if outer.count >= 3 { return (outer, holes) }
        return (normalizedLoop(boundary), holes)
    }

    private static func normalizedLoop(_ loop: [Vector3]) -> [Vector3] {
        var points = removeConsecutiveDuplicates(loop)
        if points.count > 1, let first = points.first, let last = points.last, nearlyEqual(first, last) {
            points.removeLast()
        }
        return points
    }

    private static func removeConsecutiveDuplicates(_ loop: [Vector3]) -> [Vector3] {
        var result: [Vector3] = []
        for point in loop {
            if let last = result.last, nearlyEqual(last, point) { continue }
            result.append(point)
        }
        return result
    }

    private static func nearlyEqual(_ a: Vector3, _ b: Vector3) -> Bool {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return dx * dx + dy * dy + dz * dz < 1e-12
    }

    /// Compute an ImageSpec from a .image CADPrimitive and entity transform.
    /// Called from CADRendererBridge.computeSpecs during spec aggregation.
    public static func computeImageSpec(
        from primitive: CADPrimitive,
        transform: Transform3D,
        z: Double,
        tint: ColorRGBA?,
        renderOrigin: CADRenderOrigin = .zero
    ) -> ImageSpec? {
        guard case .image(let insertion, let uAxis, let vAxis, let imageName, let clipBoundary, let primTint) = primitive else {
            return nil
        }
        let c0 = transform.transformPoint(insertion)
        let c1 = transform.transformPoint(Vector3(
            x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
        let c2 = transform.transformPoint(Vector3(
            x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
        let c3 = transform.transformPoint(Vector3(
            x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
        let effectiveTint: (UInt8, UInt8, UInt8, UInt8)? = {
            let t = primTint ?? tint
            guard let t = t else { return nil }
            return (t.r, t.g, t.b, t.a)
        }()
        func renderPoint(_ point: Vector3) -> SDL_FPoint {
            SDL_FPoint(
                x: renderOrigin.localX(point.x),
                y: renderOrigin.localY(point.y))
        }
        return ImageSpec(
            imageName: imageName,
            c0: renderPoint(c0),
            c1: renderPoint(c1),
            c2: renderPoint(c2),
            c3: renderPoint(c3),
            z: z,
            tint: effectiveTint,
            clipPolygon: clipBoundary?.map(transform.transformPoint),
            clipInverted: false
        )
    }
}
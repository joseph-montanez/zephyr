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
        public let maxWidth: Double?
        public let alignH: Int
        public let alignV: Int
        public let color: (UInt8, UInt8, UInt8, UInt8)
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
        let isHatchLine: Bool
        let hatchSpacing: Double
        let gradientData: RenderPrimitive.GradientData?

        init(
            type: PrimitiveType,
            points: [SDL_FPoint],
            rects: [SDL_FRect],
            corners: [SDL_FPoint],
            z: Double,
            color: (UInt8, UInt8, UInt8, UInt8),
            lineWeight: Double = 0.0,
            geomWidth: Double = 0.0,
            isHatchLine: Bool = false,
            hatchSpacing: Double = 0.0,
            gradientData: RenderPrimitive.GradientData? = nil
        ) {
            self.type = type
            self.points = points
            self.rects = rects
            self.corners = corners
            self.z = z
            self.color = color
            self.lineWeight = lineWeight
            self.geomWidth = geomWidth
            self.isHatchLine = isHatchLine
            self.hatchSpacing = hatchSpacing
            self.gradientData = gradientData
        }

        /// Create RenderPrimitive from spec and add to GeometryManager. Returns the new ID.
        func addTo(_ gm: GeometryManager) -> SpriteID {
            let id: SpriteID
            switch type {
            case .point:
                if let p = points.first {
                    id = gm.addPoint(x: p.x, y: p.y, z: z, color: color)
                } else {
                    id = gm.addPoint(x: 0, y: 0, z: z, color: color)
                }
            case .line:
                if points.count >= 2 {
                    id = gm.addLine(
                        x1: points[0].x, y1: points[0].y,
                        x2: points[1].x, y2: points[1].y,
                        z: z, color: color)
                } else {
                    id = gm.addPoint(x: 0, y: 0, z: z, color: color)
                }
            case .lines:
                id = gm.addLines(points, z: z, color: color)
            case .fillRect:
                if !corners.isEmpty {
                    id = gm.addFillCorners(corners, z: z, color: color, gradientData: gradientData)
                } else if let r = rects.first {
                    id = gm.addFillRect(
                        x: r.x, y: r.y, w: r.w, h: r.h,
                        z: z, color: color)
                } else {
                    id = gm.addPoint(x: 0, y: 0, z: z, color: color)
                }
            case .fillRects:
                if let r = rects.first {
                    id = gm.addFillRect(
                        x: r.x, y: r.y, w: r.w, h: r.h,
                        z: z, color: color)
                } else {
                    id = gm.addPoint(x: 0, y: 0, z: z, color: color)
                }
            case .rect:
                if !corners.isEmpty {
                    id = gm.addLines(corners, z: z, color: color)
                } else if let r = rects.first {
                    id = gm.addRect(
                        x: r.x, y: r.y, w: r.w, h: r.h,
                        z: z, color: color)
                } else {
                    id = gm.addPoint(x: 0, y: 0, z: z, color: color)
                }
            case .points, .rects:
                id = gm.addPoint(x: 0, y: 0, z: z, color: color)
            }
            if let prim = gm.getPrimitive(id: id) {
                prim.lineWeight = lineWeight
                prim.geomWidth = geomWidth
                prim.isHatchLine = isHatchLine
                prim.hatchSpacing = hatchSpacing
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

        public init(
            imageName: String,
            c0: SDL_FPoint, c1: SDL_FPoint, c2: SDL_FPoint, c3: SDL_FPoint,
            z: Double,
            tint: (UInt8, UInt8, UInt8, UInt8)? = nil
        ) {
            self.imageName = imageName
            self.c0 = c0; self.c1 = c1; self.c2 = c2; self.c3 = c3
            self.z = z
            self.tint = tint
        }
    }




    public typealias EntityResult = (
        handle: UUID,
        specs: [PrimitiveSpec],
        textSprites: [TextSpriteSpec],
        imageSpecs: [ImageSpec]
    )


public enum CADPrimitiveGenerator {

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
            return exact
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
        textStyleFonts: [String: String] = [:],
        linetypePatterns: [String: [Double]] = [:],
        opacityMultiplier: Double = 1.0,
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
        case .text(_, _, _, _, _, _, _, _, let c): primColor = c
        case .ellipse(_, _, _, let c): primColor = c
        case .hatch(_, _, _, _, let c, _): primColor = c
        case .ray(_, _, let c): primColor = c
        case .image(_, _, _, _, _, let c): primColor = c
        }
        let clampedOpacity = max(0.0, min(1.0, opacityMultiplier))
        func applyingOpacity(_ value: ColorRGBA) -> (UInt8, UInt8, UInt8, UInt8) {
            let alpha = UInt8(min(255, Double(value.a) * clampedOpacity))
            return (value.r, value.g, value.b, alpha)
        }
        let finalColor = primColor.map(applyingOpacity) ?? color

        func makeLineSpec(p1: SDL_FPoint, p2: SDL_FPoint, weight: Double, z: Double, color: (UInt8, UInt8, UInt8, UInt8)) -> PrimitiveSpec {
            return PrimitiveSpec(type: .line, points: [p1, p2], rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: geomWidth)
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
                var cycleLength: Double = isSigned
                    ? pattern.reduce(0.0) { $0 + abs($1) } * scale
                    : pattern.reduce(0.0, +) * scale

                // Fallback: If the entity is shorter than one full dash cycle,
                // dynamically scale down the pattern so it looks dashed anyway.
                var effectiveScale = scale
                if cycleLength > 1e-6 && pathLength < cycleLength {
                    // Force it to fit at least 2 cycles
                    let newCycleLength = pathLength / 2.0
                    effectiveScale = scale * (newCycleLength / cycleLength)
                    cycleLength = newCycleLength
                }

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
                    if weight > 0.25 || geomWidth > 0.0 {
                        var specs: [PrimitiveSpec] = []
                        for i in 0..<(points.count - 1) {
                            specs.append(makeLineSpec(p1: points[i], p2: points[i+1], weight: weight, z: z, color: color))
                        }
                        return specs
                    } else {
                        return [PrimitiveSpec(type: .lines, points: points, rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: geomWidth)]
                    }
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
                
                var specs: [PrimitiveSpec] = []
                if weight > 0.25 || geomWidth > 0.0 {
                    for dash in dashedPolylines {
                        for i in 0..<(dash.count - 1) {
                            specs.append(makeLineSpec(p1: dash[i], p2: dash[i+1], weight: weight, z: z, color: color))
                        }
                    }
                } else {
                    for dash in dashedPolylines {
                        specs.append(PrimitiveSpec(type: .lines, points: dash, rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: geomWidth))
                    }
                }
                return specs
            }
            
            if weight > 0.25 || geomWidth > 0.0 {
                var specs: [PrimitiveSpec] = []
                for i in 0..<(points.count - 1) {
                    specs.append(makeLineSpec(p1: points[i], p2: points[i+1], weight: weight, z: z, color: color))
                }
                return specs
            } else {
                return [PrimitiveSpec(type: .lines, points: points, rects: [], corners: [], z: z, color: color, lineWeight: weight, geomWidth: geomWidth)]
            }
        }

        var specs: [PrimitiveSpec] = []
        let dashPattern = CADPrimitiveGenerator.dashPattern(for: lineType, linetypePatterns: linetypePatterns)
        
        switch primitive {
        case .point(let pos, _):
            let wp = transform.transformPoint(pos)
            specs.append(
                PrimitiveSpec(
                    type: .point,
                    points: [SDL_FPoint(x: Float(wp.x), y: Float(wp.y))],
                    rects: [], corners: [], z: z, color: finalColor))

        case .line(let start, let end, _):
            let ws = transform.transformPoint(start)
            let we = transform.transformPoint(end)
            let pts = [
                SDL_FPoint(x: Float(ws.x), y: Float(ws.y)),
                SDL_FPoint(x: Float(we.x), y: Float(we.y)),
            ]
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .rect(let origin, let size, _):
            let c1 = transform.transformPoint(origin)
            let c2 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y, z: origin.z))
            let c3 = transform.transformPoint(Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z))
            let c4 = transform.transformPoint(Vector3(x: origin.x, y: origin.y + size.y, z: origin.z))
            let pts = [
                SDL_FPoint(x: Float(c1.x), y: Float(c1.y)),
                SDL_FPoint(x: Float(c2.x), y: Float(c2.y)),
                SDL_FPoint(x: Float(c3.x), y: Float(c3.y)),
                SDL_FPoint(x: Float(c4.x), y: Float(c4.y)),
                SDL_FPoint(x: Float(c1.x), y: Float(c1.y)),
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
                        SDL_FPoint(x: Float(c1.x), y: Float(c1.y)),
                        SDL_FPoint(x: Float(c2.x), y: Float(c2.y)),
                        SDL_FPoint(x: Float(c3.x), y: Float(c3.y)),
                        SDL_FPoint(x: Float(c4.x), y: Float(c4.y)),
                    ],
                    z: z, color: finalColor))

        case .polygon(let points, _):
            var wp = points.map { p -> SDL_FPoint in
                let t = transform.transformPoint(p)
                return SDL_FPoint(x: Float(t.x), y: Float(t.y))
            }
            if let first = wp.first {
                wp.append(first)
            }
            specs.append(contentsOf: makePathSpecs(points: wp, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .polyline(let path, _):
            let wp = path.tessellatedPoints().map { p -> SDL_FPoint in
                let t = transform.transformPoint(p)
                return SDL_FPoint(x: Float(t.x), y: Float(t.y))
            }
            specs.append(contentsOf: makePathSpecs(points: wp, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .fillPolygon(let points, _):
            let wp = points.map { p -> SDL_FPoint in
                let t = transform.transformPoint(p)
                return SDL_FPoint(x: Float(t.x), y: Float(t.y))
            }
            let triangles = CADTessellator.triangulatePolygon(wp)
            specs.append(
                PrimitiveSpec(
                    type: .fillRect,
                    points: [], rects: [], corners: triangles, z: z, color: finalColor))

        case .fillComplexPolygon(let outer, let holes, _):
            let s = CADTessellator.computeMultiLoopFillSpecs(outer: outer, holes: holes, transform: transform, color: finalColor, z: z)
            specs.append(s)

        case .gradient(let outer, let holes, _, let gradAngle, let c1, let c2):
            let gradColor1 = applyingOpacity(c1)
            let gradColor2 = applyingOpacity(c2)
            /* Add block rotation to gradient angle */
            let effectiveAngle = gradAngle + transform.rotation
            let s = CADTessellator.computeGradientFillSpecs(
                outer: outer, holes: holes, transform: transform,
                color1: gradColor1, color2: gradColor2,
                angle: effectiveAngle, z: z)
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
                pts.append(SDL_FPoint(x: Float(wp.x), y: Float(wp.y)))
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
                pts.append(SDL_FPoint(x: Float(wp.x), y: Float(wp.y)))
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
            let pts = evaluated.map { SDL_FPoint(x: Float($0.x), y: Float($0.y)) }
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))
            
        case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, _):
            let fontFile = style.flatMap { textStyleFonts[$0] } ?? "simplex.shx"

            let origin = transform.transformPoint(pos)
            let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
            let localY = Vector3(x: -sin(rotation), y: cos(rotation), z: 0)
            let worldX = transform.transformPoint(pos + localX) - origin
            let worldY = transform.transformPoint(pos + localY) - origin

            let finalRotation = atan2(worldX.y, worldX.x)
            let heightScale = max(worldY.magnitude, 1e-12)
            let widthScale = max(worldX.magnitude, 1e-12)
            let finalHeight = height * heightScale
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
                        linetypePatterns: linetypePatterns
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
                pts.append(SDL_FPoint(x: Float(wp.x), y: Float(wp.y)))
            }
            specs.append(contentsOf: makePathSpecs(points: pts, dashPattern: dashPattern, scale: lineTypeScale, weight: lineWeight, z: z, color: finalColor))

        case .hatch(let boundary, let pattern, let hatchScale, let hatchAngle, _, let backgroundColor):
            guard boundary.count >= 3 else { break }
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
                    z: backgroundZ))
            }
            if pattern.uppercased() == "SOLID" || pattern.isEmpty {
                specs.append(CADTessellator.computeMultiLoopFillSpecs(
                    outer: hatchLoops.outer,
                    holes: hatchLoops.holes,
                    transform: transform,
                    color: finalColor,
                    z: foregroundZ))
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
                let nominalSpacing = DXFHatchGenerator.effectiveSpacing(patternName: pattern, scale: hatchScale)
                let spacing = max(nominalSpacing, adaptiveMinimumSpacing)

                let hatchLines = DXFHatchGenerator.generatePatternHatch(
                    polygon: polyPoints,
                    patternName: pattern,
                    scale: hatchScale,
                    angleDegrees: hatchAngle * 180.0 / .pi,
                    minimumSpacing: adaptiveMinimumSpacing
                )

                for hline in hatchLines {
                    switch hline {
                    case .line(let s, let e, _):
                        specs.append(PrimitiveSpec(
                            type: .line,
                            points: [SDL_FPoint(x: Float(s.x), y: Float(s.y)),
                                     SDL_FPoint(x: Float(e.x), y: Float(e.y))],
                            rects: [], corners: [],
                            z: foregroundZ, color: finalColor,
                            lineWeight: 0.0, geomWidth: 0.0,
                            isHatchLine: true,
                            hatchSpacing: spacing))
                    case .point(let p, _):
                        specs.append(PrimitiveSpec(
                            type: .point,
                            points: [SDL_FPoint(x: Float(p.x), y: Float(p.y))],
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
            let p1 = SDL_FPoint(x: Float(ws.x), y: Float(ws.y))
            let p2 = SDL_FPoint(x: Float(farEndWorld.x), y: Float(farEndWorld.y))
            specs.append(makeLineSpec(p1: p1, p2: p2, weight: lineWeight, z: z, color: finalColor))

        case .image:
            // Images are not rendered as geometry primitives.
            // ImageSpec is produced in CADRendererBridge.computeSpecs instead.
            break
        }
        return specs
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
        tint: ColorRGBA?
    ) -> ImageSpec? {
        guard case .image(let insertion, let uAxis, let vAxis, let imageName, _, let primTint) = primitive else {
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
        return ImageSpec(
            imageName: imageName,
            c0: SDL_FPoint(x: Float(c0.x), y: Float(c0.y)),
            c1: SDL_FPoint(x: Float(c1.x), y: Float(c1.y)),
            c2: SDL_FPoint(x: Float(c2.x), y: Float(c2.y)),
            c3: SDL_FPoint(x: Float(c3.x), y: Float(c3.y)),
            z: z,
            tint: effectiveTint
        )
    }
}

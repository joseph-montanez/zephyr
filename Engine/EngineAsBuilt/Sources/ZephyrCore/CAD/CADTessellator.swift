import Foundation

// =========================================================================
// MARK: - CADTessellator
//
// Converts CADPrimitives into raw vertex data (tessellation).
// Handles arc/circle/flat-polygon → triangle decomposition for filled
// primitives, and circle/ellipse/arc → line-strip decomposition for
// wireframe rendering.
//
// The tessellator is stateless — all methods are pure functions operating
// on input primitives and producing arrays of vertex data. It is called
// by the CADVertexBufferBuilder during vertex buffer construction.
import SwiftSDL

public enum CADTessellator {

    /// Computes complex nested hatches by automatically grouping topological islands
    internal static func computeMultiLoopFillSpecs(
        outer: [Vector3],
        holes: [[Vector3]],
        transform: Transform3D,
        color: (UInt8, UInt8, UInt8, UInt8),
        z: Double
    ) -> PrimitiveSpec {
        // 1. Helper to clean duplicates and floating-point drift
        func cleanLoop(_ loop: [Vector3]) -> [SDL_FPoint] {
            var pts: [SDL_FPoint] = []
            for v in loop {
                let t = transform.transformPoint(v)
                let pt = SDL_FPoint(x: Float(t.x), y: Float(t.y))
                if let last = pts.last {
                    let dx = pt.x - last.x
                    let dy = pt.y - last.y
                    if (dx*dx + dy*dy) > 1e-6 { pts.append(pt) }
                } else {
                    pts.append(pt)
                }
            }
            if pts.count > 1, let first = pts.first, let last = pts.last {
                let dx = last.x - first.x
                let dy = last.y - first.y
                if (dx*dx + dy*dy) < 1e-6 { pts.removeLast() }
            }
            return pts
        }
        
        // 2. Mathematical helpers for topological grouping
        func signedArea(_ pts: [SDL_FPoint]) -> Float {
            var sum: Float = 0
            for i in 0..<pts.count {
                let p1 = pts[i]
                let p2 = pts[(i + 1) % pts.count]
                sum += (p1.x * p2.y - p2.x * p1.y)
            }
            return sum
        }
        
        func pointInPolygon(_ pt: SDL_FPoint, _ poly: [SDL_FPoint]) -> Bool {
            let ptx = Double(pt.x)
            let pty = Double(pt.y) + 1.2345e-4
            var inside = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let pi_x = Double(poly[i].x)
                let pi_y = Double(poly[i].y)
                let pj_x = Double(poly[j].x)
                let pj_y = Double(poly[j].y)
                if ((pi_y > pty) != (pj_y > pty)) &&
                   (ptx < (pj_x - pi_x) * (pty - pi_y) / (pj_y - pi_y) + pi_x) {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
        
        // 3. Pool all loops together (ignoring what DXF claimed was outer vs hole)
        var allLoops = holes
        if !outer.isEmpty {
            allLoops.insert(outer, at: 0)
        }
        
        let cleanedLoops = allLoops.map { cleanLoop($0) }.filter { $0.count >= 3 }
        guard !cleanedLoops.isEmpty else {
            // Safe fallback to prevent crashes on empty geometry
            return PrimitiveSpec(type: .fillRect, points: [], rects: [], corners: [], z: z, color: color)
        }
        
        // 4. Determine Topography (Outer Islands vs Holes)
        var islandIndices: [Int] = []
        var holeIndices: [Int] = []
        
        for i in 0..<cleanedLoops.count {
            var containerCount = 0
            let testPt = cleanedLoops[i][0]
            
            for j in 0..<cleanedLoops.count {
                if i == j { continue }
                if pointInPolygon(testPt, cleanedLoops[j]) {
                    containerCount += 1
                }
            }
            
            if containerCount % 2 == 0 {
                islandIndices.append(i)
            } else {
                holeIndices.append(i)
            }
        }
        
        // 5. Group Holes with their smallest parent Island
        struct TopologicalIsland {
            let outer: [SDL_FPoint]
            var holes: [[SDL_FPoint]]
        }
        
        var islands = islandIndices.map { TopologicalIsland(outer: cleanedLoops[$0], holes: []) }
        
        for hIdx in holeIndices {
            let holePoly = cleanedLoops[hIdx]
            let pt = holePoly[0]
            
            var bestIslandIdx = -1
            var minOuterArea: Float = Float.infinity
            
            for (idx, islandIdx) in islandIndices.enumerated() {
                let outerPoly = cleanedLoops[islandIdx]
                if pointInPolygon(pt, outerPoly) {
                    let area = abs(signedArea(outerPoly))
                    if area < minOuterArea {
                        minOuterArea = area
                        bestIslandIdx = idx
                    }
                }
            }
            
            if bestIslandIdx != -1 {
                islands[bestIslandIdx].holes.append(holePoly)
            }
        }
        
        // 5.5 Nudge hole vertices that are outside or too close to the island's outer boundary
        for i in 0..<islands.count {
            let outer = islands[i].outer
            guard !outer.isEmpty else { continue }
            
            // Calculate centroid of outer loop
            var sumX: Float = 0
            var sumY: Float = 0
            for pt in outer {
                sumX += pt.x
                sumY += pt.y
            }
            let centroid = SDL_FPoint(x: sumX / Float(outer.count), y: sumY / Float(outer.count))
            
            for hIdx in 0..<islands[i].holes.count {
                var hole = islands[i].holes[hIdx]
                for vIdx in 0..<hole.count {
                    var pt = hole[vIdx]
                    
                    // Check if inside
                    let inside = pointInPolygon(pt, outer)
                    
                    // Check distance to closest edge of outer
                    var minSqDist: Float = Float.infinity
                    for j in 0..<outer.count {
                        let a = outer[j]
                        let b = outer[(j + 1) % outer.count]
                        
                        let vx = b.x - a.x
                        let vy = b.y - a.y
                        let wx = pt.x - a.x
                        let wy = pt.y - a.y
                        
                        let l2 = vx*vx + vy*vy
                        guard l2 > 1e-8 else { continue }
                        var t = (wx*vx + wy*vy) / l2
                        t = max(0, min(1, t))
                        
                        let cx = a.x + t * vx
                        let cy = a.y + t * vy
                        
                        let dx = pt.x - cx
                        let dy = pt.y - cy
                        let sqDist = dx*dx + dy*dy
                        if sqDist < minSqDist {
                            minSqDist = sqDist
                        }
                    }
                    
                    let minDistance = minSqDist == Float.infinity ? 0 : sqrt(minSqDist)
                    if !inside || minDistance < 0.03 {
                        // Nudge towards centroid
                        let dirX = centroid.x - pt.x
                        let dirY = centroid.y - pt.y
                        let dist = sqrt(dirX*dirX + dirY*dirY)
                        if dist > 1e-4 {
                            let nudgeDist: Float = 0.05
                            pt.x += (dirX / dist) * nudgeDist
                            pt.y += (dirY / dist) * nudgeDist
                        }
                    }
                    hole[vIdx] = pt
                }
                islands[i].holes[hIdx] = hole
            }
        }
        
        // 6. Iterate through each isolated Island and run Earcut
        var finalTriangles: [SDL_FPoint] = []
        
        for (_, island) in islands.enumerated() {
            var flatData: [Float] = []
            var earcutHoles: [Int] = []
            
            for pt in island.outer {
                flatData.append(pt.x)
                flatData.append(pt.y)
            }
            
            for hole in island.holes {
                earcutHoles.append(flatData.count / 2)
                for pt in hole {
                    flatData.append(pt.x)
                    flatData.append(pt.y)
                }
            }
            
            let indices = earcut(data: flatData, holeIndices: earcutHoles, dim: 2)
            
            for idx in indices {
                let dataIndex = idx * 2
                finalTriangles.append(SDL_FPoint(x: flatData[dataIndex], y: flatData[dataIndex + 1]))
            }
            

        }
        
        // Return a SINGLE PrimitiveSpec, satisfying your downstream compiler requirements
        return PrimitiveSpec(type: .fillRect, points: [], rects: [], corners: finalTriangles, z: z, color: color)
    }


    /// Tessellate a gradient-filled polygon by triangulating and assigning
    /// per-triangle interpolated colors between color1 and color2 based on
    /// the triangle centroid's position along the gradient angle.
    internal static func computeGradientFillSpecs(
        outer: [Vector3],
        holes: [[Vector3]],
        transform: Transform3D,
        color1: (UInt8, UInt8, UInt8, UInt8),
        color2: (UInt8, UInt8, UInt8, UInt8),
        angle: Double,
        z: Double
    ) -> [PrimitiveSpec] {
        func cleanLoop(_ loop: [Vector3]) -> [SDL_FPoint] {
            var pts: [SDL_FPoint] = []
            for v in loop {
                let t = transform.transformPoint(v)
                let pt = SDL_FPoint(x: Float(t.x), y: Float(t.y))
                if let last = pts.last {
                    let dx = pt.x - last.x
                    let dy = pt.y - last.y
                    if (dx*dx + dy*dy) > 1e-6 { pts.append(pt) }
                } else {
                    pts.append(pt)
                }
            }
            if pts.count > 1, let first = pts.first, let last = pts.last {
                let dx = last.x - first.x
                let dy = last.y - first.y
                if (dx*dx + dy*dy) < 1e-6 { pts.removeLast() }
            }
            return pts
        }

        func signedArea(_ pts: [SDL_FPoint]) -> Float {
            var sum: Float = 0
            for i in 0..<pts.count {
                let p1 = pts[i]
                let p2 = pts[(i + 1) % pts.count]
                sum += (p1.x * p2.y - p2.x * p1.y)
            }
            return sum
        }

        func pointInPolygon(_ pt: SDL_FPoint, _ poly: [SDL_FPoint]) -> Bool {
            let ptx = Double(pt.x)
            let pty = Double(pt.y) + 1.2345e-4
            var inside = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let pi_x = Double(poly[i].x)
                let pi_y = Double(poly[i].y)
                let pj_x = Double(poly[j].x)
                let pj_y = Double(poly[j].y)
                if ((pi_y > pty) != (pj_y > pty)) &&
                   (ptx < (pj_x - pi_x) * (pty - pi_y) / (pj_y - pi_y) + pi_x) {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        var allLoops = holes
        if !outer.isEmpty { allLoops.insert(outer, at: 0) }
        let cleanedLoops = allLoops.map { cleanLoop($0) }.filter { $0.count >= 3 }
        guard !cleanedLoops.isEmpty else { return [] }

        // Determine islands vs holes
        var islandIndices: [Int] = []
        var holeIndices: [Int] = []
        for i in 0..<cleanedLoops.count {
            var containerCount = 0
            let testPt = cleanedLoops[i][0]
            for j in 0..<cleanedLoops.count {
                if i == j { continue }
                if pointInPolygon(testPt, cleanedLoops[j]) { containerCount += 1 }
            }
            if containerCount % 2 == 0 { islandIndices.append(i) }
            else { holeIndices.append(i) }
        }

        struct TopoIsland { let outer: [SDL_FPoint]; var holes: [[SDL_FPoint]] }
        var islands = islandIndices.map { TopoIsland(outer: cleanedLoops[$0], holes: []) }
        for hIdx in holeIndices {
            let holePoly = cleanedLoops[hIdx]
            let pt = holePoly[0]
            var bestIdx = -1
            var minArea: Float = Float.infinity
            for (idx, islandIdx) in islandIndices.enumerated() {
                let outerPoly = cleanedLoops[islandIdx]
                if pointInPolygon(pt, outerPoly) {
                    let area = abs(signedArea(outerPoly))
                    if area < minArea { minArea = area; bestIdx = idx }
                }
            }
            if bestIdx != -1 { islands[bestIdx].holes.append(holePoly) }
        }

        // Build gradient direction vector
        let cosA = cos(-angle)
        let sinA = sin(-angle)

        // Find overall bounding box for normalization
        var allX: [Float] = []
        var allY: [Float] = []
        for island in islands {
            for pt in island.outer {
                allX.append(pt.x); allY.append(pt.y)
            }
        }
        guard let minX = allX.min(), let maxX = allX.max(),
              let minY = allY.min(), let maxY = allY.max() else { return [] }
        let spanX = maxX - minX
        let spanY = maxY - minY
        let diag = max(sqrt(spanX*spanX + spanY*spanY), 1e-6)

        let gradientData = RenderPrimitive.GradientData(
            color1: color1,
            color2: color2,
            angleCos: cosA,
            angleSin: sinA,
            minX: Double(minX),
            minY: Double(minY),
            diag: Double(diag)
        )

        var allSpecs: [PrimitiveSpec] = []

        for island in islands {
            var flatData: [Float] = []
            var holeOffsets: [Int] = []
            for pt in island.outer {
                flatData.append(pt.x); flatData.append(pt.y)
            }
            for hole in island.holes {
                holeOffsets.append(flatData.count / 2)
                for pt in hole {
                    flatData.append(pt.x); flatData.append(pt.y)
                }
            }

            let indices = earcut(data: flatData, holeIndices: holeOffsets, dim: 2)

            // Group indices into triangles, attach gradientData
            for t in stride(from: 0, to: indices.count, by: 3) {
                guard t + 2 < indices.count else { continue }
                let i0 = indices[t] * 2, i1 = indices[t+1] * 2, i2 = indices[t+2] * 2
                let v0 = SDL_FPoint(x: flatData[i0], y: flatData[i0+1])
                let v1 = SDL_FPoint(x: flatData[i1], y: flatData[i1+1])
                let v2 = SDL_FPoint(x: flatData[i2], y: flatData[i2+1])

                allSpecs.append(PrimitiveSpec(
                    type: .fillRect,
                    points: [], rects: [],
                    corners: [v0, v1, v2],
                    z: z, color: color1,
                    gradientData: gradientData))
            }
        }
        return allSpecs
    }


    internal static func pointInRawPolygon(_ p: SDL_FPoint, polygon: [SDL_FPoint]) -> Bool {
        let px = Double(p.x)
        let py = Double(p.y) + 1.2345e-4
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi_x = Double(polygon[i].x)
            let pi_y = Double(polygon[i].y)
            let pj_x = Double(polygon[j].x)
            let pj_y = Double(polygon[j].y)
            if ((pi_y > py) != (pj_y > py)) &&
                (px < (pj_x - pi_x) * (py - pi_y) / (pj_y - pi_y) + pi_x) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }


    public static func triangulatePolygon(_ points: [SDL_FPoint]) -> [SDL_FPoint] {
        guard points.count >= 3 else { return [] }
        if points.count == 3 {
            return points
        }
        if points.count == 4 {
            return [
                points[0], points[1], points[2],
                points[0], points[2], points[3]
            ]
        }
        
        let vertices = points
        var indices = Array(0..<vertices.count)
        var triangles: [SDL_FPoint] = []
        triangles.reserveCapacity((points.count - 2) * 3)
        
        var area: Float = 0.0
        for i in 0..<vertices.count {
            let p1 = vertices[i]
            let p2 = vertices[(i + 1) % vertices.count]
            area += (p1.x * p2.y) - (p2.x * p1.y)
        }
        // Force evaluation matching standard ear clipping winding rules regardless of viewport mirror states
        let isCCW = area >= 0
        
        func isConvex(a: SDL_FPoint, b: SDL_FPoint, c: SDL_FPoint) -> Bool {
            let crossProduct = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            return isCCW ? (crossProduct >= 0) : (crossProduct <= 0)
        }
        
        func pointInTriangle(p: SDL_FPoint, a: SDL_FPoint, b: SDL_FPoint, c: SDL_FPoint) -> Bool {
            let det = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            if abs(det) < 1e-6 { return false }
            let factorA = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / det
            let factorB = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / det
            let factorC = 1.0 - factorA - factorB
            return factorA >= 0.0 && factorB >= 0.0 && factorC >= 0.0
        }
        
        var limit = indices.count * 2
        while indices.count > 3 && limit > 0 {
            var earFound = false
            for i in 0..<indices.count {
                let prevIdx = indices[(i + indices.count - 1) % indices.count]
                let currIdx = indices[i]
                let nextIdx = indices[(i + 1) % indices.count]
                
                let a = vertices[prevIdx]
                let b = vertices[currIdx]
                let c = vertices[nextIdx]
                
                if isConvex(a: a, b: b, c: c) {
                    var pointInside = false
                    for j in 0..<indices.count {
                        let idx = indices[j]
                        if idx == prevIdx || idx == currIdx || idx == nextIdx {
                            continue
                        }
                        if pointInTriangle(p: vertices[idx], a: a, b: b, c: c) {
                            pointInside = true
                            break
                        }
                    }
                    
                    if !pointInside {
                        triangles.append(a)
                        triangles.append(b)
                        triangles.append(c)
                        indices.remove(at: i)
                        earFound = true
                        break
                    }
                }
            }
            
            if !earFound {
                var clipped = false
                for i in 0..<indices.count {
                    let prevIdx = indices[(i + indices.count - 1) % indices.count]
                    let currIdx = indices[i]
                    let nextIdx = indices[(i + 1) % indices.count]
                    let a = vertices[prevIdx]
                    let b = vertices[currIdx]
                    let c = vertices[nextIdx]
                    if isConvex(a: a, b: b, c: c) {
                        triangles.append(a)
                        triangles.append(b)
                        triangles.append(c)
                        indices.remove(at: i)
                        clipped = true
                        break
                    }
                }
                if !clipped {
                    break
                }
            }
            limit -= 1
        }
        
        if indices.count == 3 {
            triangles.append(vertices[indices[0]])
            triangles.append(vertices[indices[1]])
            triangles.append(vertices[indices[2]])
        } else if indices.count > 3 {
            let first = vertices[indices[0]]
            for i in 1..<(indices.count - 1) {
                triangles.append(first)
                triangles.append(vertices[indices[i]])
                triangles.append(vertices[indices[i+1]])
            }
        }
        
        return triangles
    }
}

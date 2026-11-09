import XCTest
@testable import ZephyrCore

/// Step 0 probe: real-file hatch reliability on A_000217.dxf.
/// Kept as durable collateral: fails while interior picks miss or the
/// pile list omits the hatch. Passes when both hold.
@MainActor
final class RealFileHatchProbeTests: XCTestCase {
    private var dxfURL: URL? {
        let p = #"C:\Users\xingo\Downloads\A_000217.dxf"#
        let url = URL(fileURLWithPath: p)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func testProbeHatchInteriorsAndPiles() throws {
        guard let url = dxfURL else {
            throw XCTSkip("A_000217.dxf not present on this machine")
        }
        let doc = CADDocument()
        try doc.importDXF(url: url)
        doc.rebuildEntityGrid()

        var report: [String] = []
        var checked = 0
        var missedHit = 0
        var missedList = 0
        var skippedDegenerate = 0

        for entity in doc.entitiesView {
            if entity.arrayData != nil { continue }
            guard let geom = doc.resolvedGeometry(for: entity) else { continue }
            let fillIndices = geom.indices.filter { isFillLike(geom[$0]) }
            guard !fillIndices.isEmpty else { continue }
            for fi in fillIndices {
                guard let probe = interiorProbe(of: geom[fi], entity: entity) else {
                    skippedDegenerate += 1
                    continue
                }
                checked += 1
                let threshold = 3.0
                let hit = CADHitTesting.hitTest(worldX: probe.x, worldY: probe.y, document: doc, threshold: threshold)
                let list = CADHitTesting.allHitsAt(worldX: probe.x, worldY: probe.y, document: doc, threshold: threshold)
                let inList = list.contains(where: { $0.handle == entity.handle })
                if hit == nil { missedHit += 1 }
                if !inList { missedList += 1 }
                if hit == nil || !inList {
                    let primDesc = primSummary(geom[fi])
                    let wbb = entity.worldBoundingBox.map { "wbb=(\($0.min.x),\($0.min.y))-(\($0.max.x),\($0.max.y))" } ?? "wbb=nil"
                    report.append("MISS entity=\(entity.handle) block=\(entity.blockID.map { doc.block(for: $0)?.name ?? "?" } ?? "loose") prim=\(fi)/\(geom.count)[\(primDesc)] probe=(\(probe.x),\(probe.y)) hit=\(hit.map { "\($0)" } ?? "nil") listCount=\(list.count) \(wbb)")
                    if report.count >= 20 { break }
                }
            }
            if report.count >= 20 { break }
        }
        print("PROBE checked=\(checked) missedHit=\(missedHit) missedList=\(missedList) skippedDegenerate=\(skippedDegenerate)")
        for line in report.prefix(20) { print(line) }
        XCTAssertGreaterThan(checked, 0, "probe found no fill interiors; import path changed")
        XCTAssertEqual(missedHit, 0, "interior picks missed: \(report.prefix(5).joined(separator: " | "))")
        XCTAssertEqual(missedList, 0, "hatch missing from pile list: \(report.prefix(5).joined(separator: " | "))")
    }

    /// Screenshot regression: the DOTS hatch in V21GGL_BOTTOM is backed by
    /// two disjoint associative LWPOLYLINE boundaries (DXF handles C02A04
    /// and C02A05). Sample those *source* boundaries independently of the
    /// imported hatch rings; every source-interior sample must classify as
    /// hatch interior and must pick the INSERT. The earlier centroid probe
    /// could not catch a mis-stitched ring because it sampled points that
    /// were inside by the picker's own even-odd rule.
    func testV21GGLBottomSourceBoundariesAreHatchPickable() throws {
        guard let url = dxfURL else {
            throw XCTSkip("A_000217.dxf not present on this machine")
        }
        let doc = CADDocument()
        try doc.importDXF(url: url)
        doc.rebuildEntityGrid()

        let block = try XCTUnwrap(
            doc.allBlocks.first(where: { $0.name == "V21GGL_BOTTOM" }),
            "V21GGL_BOTTOM block missing after import")
        let inserts = doc.entitiesView.filter { $0.blockID == block.handle }
        XCTAssertEqual(inserts.count, 1, "expected the single screenshot INSERT")
        let insert = try XCTUnwrap(inserts.first)
        let geometry = try XCTUnwrap(doc.resolvedGeometry(for: insert))
        let primitiveXData = doc.primitiveXData(for: insert)

        func dxfHandle(at index: Int) -> String? {
            primitiveXData[index]?["dxf.handle"]?.stringValue
        }

        var sourceRings: [(handle: String, points: [Vector3])] = []
        var hatchRings: [(outer: [Vector3], holes: [[Vector3]])] = []
        for (index, primitive) in geometry.enumerated() {
            let handle = dxfHandle(at: index) ?? "-"
            switch primitive {
            case .polyline(let path, _):
                print("V21 prim \(index) dxf=\(handle) polyline vertices=\(path.vertices.count) closed=\(path.isClosed) edges=\(path.hatchEdges.count) tess=\(path.tessellatedPoints().count)")
                if handle == "C02A04" || handle == "C02A05" {
                    sourceRings.append((handle, path.tessellatedPoints()))
                }
            case .hatchPath(let boundary, let holes, let pattern, _, _, _, _):
                let outer = boundary.tessellatedPoints()
                let holeRings = holes.map { $0.tessellatedPoints() }
                let sourceHandles = boundary.hatchSourceBoundaryHandles
                    .map { String($0, radix: 16).uppercased() }
                    .joined(separator: ",")
                print("V21 prim \(index) dxf=\(handle) hatchPath pattern=\(pattern) outerVertices=\(boundary.vertices.count) outerEdges=\(boundary.hatchEdges.count) outerTess=\(outer.count) holes=\(holes.count) source=\(sourceHandles) area=\(signedArea(outer)) selfIntersections=\(countSelfIntersections(outer))")
                hatchRings.append((outer, holeRings))
            case .hatch(let boundary, let pattern, _, _, _, _):
                print("V21 prim \(index) dxf=\(handle) hatch pattern=\(pattern) points=\(boundary.count) area=\(signedArea(boundary)) selfIntersections=\(countSelfIntersections(boundary))")
                hatchRings.append((boundary, []))
            default:
                print("V21 prim \(index) dxf=\(handle) \(primSummary(primitive))")
            }
        }

        XCTAssertEqual(Set(sourceRings.map(\.handle)), Set(["C02A04", "C02A05"]))
        XCTAssertFalse(hatchRings.isEmpty, "DOTS hatch did not import as a fill ring")

        let sourcePoints = sourceRings.flatMap(\.points)
        let minX = sourcePoints.map(\.x).min() ?? 0
        let maxX = sourcePoints.map(\.x).max() ?? 0
        let minY = sourcePoints.map(\.y).min() ?? 0
        let maxY = sourcePoints.map(\.y).max() ?? 0

        var sourceInsideCount = 0
        var sourceOnlyCount = 0
        var hatchOnlyCount = 0
        var mismatchExamples: [String] = []
        var deepInteriorCandidates: [Vector3] = []

        var localY = minY
        while localY <= maxY {
            var localX = minX
            while localX <= maxX {
                let point = Vector3(x: localX, y: localY, z: 0)
                let inSource = sourceRings.contains { pointInPoly(point, $0.points) }
                let inHatch = hatchRings.contains { ring in
                    pointInPoly(point, ring.outer)
                        && !ring.holes.contains(where: { pointInPoly(point, $0) })
                }
                if inSource {
                    sourceInsideCount += 1
                    let edgeDistance = sourceRings
                        .map { minEdgeDistance(point, $0.points) }
                        .min() ?? 0
                    if edgeDistance > 2.0 {
                        deepInteriorCandidates.append(point)
                    }
                    if !inHatch {
                        sourceOnlyCount += 1
                        if mismatchExamples.count < 12 {
                            let world = insert.transform.transformPoint(point)
                            mismatchExamples.append(
                                "local=(\(point.x),\(point.y)) world=(\(world.x),\(world.y)) edgeDist=\(edgeDistance)")
                        }
                    }
                } else if inHatch {
                    hatchOnlyCount += 1
                }
                localX += 0.5
            }
            localY += 0.5
        }

        print("V21 sourceInside=\(sourceInsideCount) sourceOnly=\(sourceOnlyCount) hatchOnly=\(hatchOnlyCount) deepCandidates=\(deepInteriorCandidates.count)")
        for example in mismatchExamples {
            print("V21 MISMATCH \(example)")
        }

        XCTAssertGreaterThan(sourceInsideCount, 0)
        XCTAssertEqual(
            sourceOnlyCount, 0,
            "source hatch boundary interiors missing from imported hatch rings: \(mismatchExamples.prefix(5).joined(separator: " | "))")

        XCTAssertFalse(deepInteriorCandidates.isEmpty, "no deep source-interior samples")
        let stride = max(1, deepInteriorCandidates.count / 120)
        var pickChecked = 0
        var pickMissed = 0
        var pickExamples: [String] = []
        for index in Swift.stride(from: 0, to: deepInteriorCandidates.count, by: stride) {
            let local = deepInteriorCandidates[index]
            let world = insert.transform.transformPoint(local)
            pickChecked += 1
            let directHit = CADHitTesting.hitEntity(
                insert,
                point: world,
                threshold: 1.0,
                document: doc,
                simplifyComplexBlocks: false,
                geometry: geometry)
            let hits = CADHitTesting.allHitsAt(
                worldX: world.x,
                worldY: world.y,
                document: doc,
                threshold: 1.0,
                simplifyComplexBlocks: false)
            let inList = hits.contains(where: { $0.handle == insert.handle })
            if !directHit || !inList {
                pickMissed += 1
                if pickExamples.count < 12 {
                    pickExamples.append(
                        "local=(\(local.x),\(local.y)) world=(\(world.x),\(world.y)) direct=\(directHit) list=\(hits.map(\.label))")
                }
            }
        }
        print("V21 pickChecked=\(pickChecked) pickMissed=\(pickMissed)")
        for example in pickExamples {
            print("V21 PICKMISS \(example)")
        }
        XCTAssertEqual(pickMissed, 0, "deep DOTS interiors did not pick: \(pickExamples.prefix(5).joined(separator: " | "))")

        // Live-route diagnostic at roughly the screenshot scale: how many
        // deep-interior samples are real piles, and how many of those piles
        // fall inside the grip hit radius once the INSERT is selected?
        // Grip testing runs before Selection Cycling in the mouse-down
        // route, so a pile inside that radius can never open the list.
        let screenshotZoom = 2.25
        let liveThreshold = 6.0 / screenshotZoom
        let insertOrigin = insert.transform.transformPoint(.zero)
        let cam = CameraTransform(
            camX: insertOrigin.x, camY: insertOrigin.y, camZoom: screenshotZoom,
            camSin: 0, camCos: 1, screenCenterX: 960, screenCenterY: 540)
        let grips = CADGripSystem.getAllGrips(
            document: doc, cam: cam, simplifyComplexBlocks: false,
            selectedHandles: [insert.handle], gripObjectLimit: 100)
        var pileHistogram: [Int: Int] = [:]
        var pileCount = 0
        var pilesGripBlocked20 = 0
        var pilesGripBlocked10 = 0
        var pilesGripBlocked5 = 0
        var pileExamples: [String] = []
        let diagnosticStride = max(1, deepInteriorCandidates.count / 240)
        for index in Swift.stride(from: 0, to: deepInteriorCandidates.count, by: diagnosticStride) {
            let local = deepInteriorCandidates[index]
            let world = insert.transform.transformPoint(local)
            let hits = CADHitTesting.allHitsAt(
                worldX: world.x, worldY: world.y, document: doc,
                threshold: liveThreshold, simplifyComplexBlocks: false)
            pileHistogram[hits.count, default: 0] += 1
            guard hits.count >= 2 else { continue }
            pileCount += 1
            let nearestGripPx = grips
                .map { hypot(($0.worldPos.x - world.x) * screenshotZoom, ($0.worldPos.y - world.y) * screenshotZoom) }
                .min() ?? .infinity
            if nearestGripPx < 20 { pilesGripBlocked20 += 1 }
            if nearestGripPx < 10 { pilesGripBlocked10 += 1 }
            if nearestGripPx < 5 { pilesGripBlocked5 += 1 }
            if pileExamples.count < 12 {
                let globalNested = CADHitTesting.nestedHitTest(
                    worldX: world.x, worldY: world.y, document: doc,
                    threshold: liveThreshold)
                let globalNestedDesc: String
                if let globalNested {
                    let nestedHandle = doc.primitiveXData(for: globalNested.entity)[globalNested.primitiveIndex]?["dxf.handle"]?.stringValue ?? "-"
                    let nestedGeom = doc.resolvedGeometry(for: globalNested.entity) ?? []
                    let nestedPrim = nestedGeom.indices.contains(globalNested.primitiveIndex)
                        ? primSummary(nestedGeom[globalNested.primitiveIndex]) : "oob"
                    globalNestedDesc = "entity=\(globalNested.entity.handle) dxf=\(nestedHandle) prim=\(globalNested.primitiveIndex)[\(nestedPrim)] dist=\(globalNested.distanceSquared) isInsert=\(globalNested.entity.handle == insert.handle)"
                } else {
                    globalNestedDesc = "nil"
                }
                var insertBest: (index: Int, dist: Double)? = nil
                for (primIndex, prim) in geometry.enumerated() {
                    guard let d = CADHitTesting.distanceSqToPrimitive(
                        prim, point: world, transform: insert.transform,
                        t2: liveThreshold * liveThreshold) else { continue }
                    if d < (insertBest?.dist ?? .infinity) {
                        insertBest = (primIndex, d)
                    }
                }
                let insertBestDesc: String
                if let insertBest {
                    insertBestDesc = "prim=\(insertBest.index)[\(primSummary(geometry[insertBest.index]))] dist=\(insertBest.dist)"
                } else {
                    insertBestDesc = "nil"
                }
                pileExamples.append(
                    "local=(\(local.x),\(local.y)) world=(\(world.x),\(world.y)) nearestGripPx=\(nearestGripPx) hits=\(hits.map(\.label)) globalNested=\(globalNestedDesc) insertBest=\(insertBestDesc)")
            }
        }
        print("V21 liveRoute grips=\(grips.count) histogram=\(pileHistogram.sorted { $0.key < $1.key }) piles=\(pileCount) blocked20=\(pilesGripBlocked20) blocked10=\(pilesGripBlocked10) blocked5=\(pilesGripBlocked5)")
        let screenshotPile = CADHitTesting.allHitsAt(
            worldX: 662.9310940475119, worldY: -702.055621457754,
            document: doc, threshold: liveThreshold,
            simplifyComplexBlocks: false)
        XCTAssertGreaterThanOrEqual(screenshotPile.count, 2, "screenshot pile regressed: \(screenshotPile.map(\.label))")
        XCTAssertTrue(screenshotPile.contains(where: { $0.handle == insert.handle }))
        XCTAssertTrue(screenshotPile.contains(where: { $0.label.contains("HATCH") }))
        let screenshotNested = CADHitTesting.nestedHit(
            for: insert, worldX: 662.9310940475119, worldY: -702.055621457754,
            document: doc, threshold: liveThreshold)
        let nestedPrim = try XCTUnwrap(screenshotNested.map { geometry[$0.primitiveIndex] })
        if case .hatchPath = nestedPrim {} else {
            XCTFail("per-entity nested pick at screenshot pile should land on the DOTS hatchPath, got \(primSummary(nestedPrim))")
        }
        for example in pileExamples {
            print("V21 PILE \(example)")
        }
    }

    private func isFillLike(_ prim: CADPrimitive) -> Bool {
        switch prim {
        case .hatch, .hatchPath, .fillPolygon, .fillComplexPolygon, .gradient, .fillRect:
            return true
        default:
            return false
        }
    }

    private func primSummary(_ prim: CADPrimitive) -> String {
        switch prim {
        case .hatch(let b, let pattern, _, _, _, _):
            return "hatch:\(pattern) n=\(b.count)"
        case .hatchPath(let boundary, let holes, let pattern, _, _, _, _):
            return "hatchPath:\(pattern) n=\(boundary.tessellatedPoints().count) holes=\(holes.count)"
        case .fillPolygon(let pts, _):
            return "fillPolygon n=\(pts.count)"
        case .fillComplexPolygon(let outer, let holes, _):
            return "fillComplex n=\(outer.count) holes=\(holes.count)"
        case .fillRect:
            return "fillRect"
        case .gradient(let outer, let holes, _, _, _, _):
            return "gradient n=\(outer.count) holes=\(holes.count)"
        default:
            return "other"
        }
    }

    private func interiorProbe(of prim: CADPrimitive, entity: CADEntity) -> Vector3? {
        let t = entity.transform
        switch prim {
        case .hatch(let b, _, _, _, _, _):
            return guaranteedInterior(outer: b.map { t.transformPoint($0) }, holes: [])
        case .hatchPath(let boundary, let holes, _, _, _, _, _):
            let pts = boundary.tessellatedPoints().map { t.transformPoint($0) }
            let holeRings = holes.map { $0.tessellatedPoints().map(t.transformPoint) }
            return guaranteedInterior(outer: pts, holes: holeRings)
        case .fillPolygon(let pts, _):
            return guaranteedInterior(outer: pts.map { t.transformPoint($0) }, holes: [])
        case .fillComplexPolygon(let outer, let holes, _):
            return guaranteedInterior(outer: outer.map { t.transformPoint($0) }, holes: holes.map { $0.map(t.transformPoint) })
        case .fillRect(let origin, let size, _):
            let c = Vector3(x: origin.x + size.x / 2, y: origin.y + size.y / 2, z: 0)
            return t.transformPoint(c)
        case .gradient(let outer, let holes, _, _, _, _):
            return guaranteedInterior(outer: outer.map { t.transformPoint($0) }, holes: holes.map { $0.map(t.transformPoint) })
        default:
            return nil
        }
    }

    private func guaranteedInterior(outer: [Vector3], holes: [[Vector3]]) -> Vector3? {
        guard outer.count >= 3 else { return nil }
        if let c = centroid(outer), pointInPoly(c, outer), !holes.contains(where: { pointInPoly(c, $0) }) {
            return c
        }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for p in outer {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        guard minX.isFinite, maxX > minX, maxY > minY else { return nil }
        for iy in 1..<9 {
            for ix in 1..<9 {
                let q = Vector3(x: minX + (maxX - minX) * Double(ix) / 9.0, y: minY + (maxY - minY) * Double(iy) / 9.0, z: 0)
                if pointInPoly(q, outer), !holes.contains(where: { pointInPoly(q, $0) }) {
                    return q
                }
            }
        }
        return nil
    }

    private func centroid(_ pts: [Vector3]) -> Vector3? {
        guard !pts.isEmpty else { return nil }
        var x = 0.0, y = 0.0
        for p in pts { x += p.x; y += p.y }
        return Vector3(x: x / Double(pts.count), y: y / Double(pts.count), z: 0)
    }

    private func signedArea(_ points: [Vector3]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        return area * 0.5
    }

    private func segmentDistanceSquared(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared <= 1e-24 {
            let px = p.x - a.x
            let py = p.y - a.y
            return px * px + py * py
        }
        let t = max(0.0, min(1.0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        let px = p.x - (a.x + dx * t)
        let py = p.y - (a.y + dy * t)
        return px * px + py * py
    }

    private func minEdgeDistance(_ p: Vector3, _ poly: [Vector3]) -> Double {
        guard poly.count >= 2 else { return .infinity }
        var best = Double.infinity
        for index in poly.indices {
            let d = segmentDistanceSquared(
                p, poly[index], poly[(index + 1) % poly.count])
            if d < best { best = d }
        }
        return sqrt(best)
    }

    private func orientation(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private func segmentsIntersect(
        _ a: Vector3, _ b: Vector3, _ c: Vector3, _ d: Vector3
    ) -> Bool {
        let o1 = orientation(a, b, c)
        let o2 = orientation(a, b, d)
        let o3 = orientation(c, d, a)
        let o4 = orientation(c, d, b)
        return ((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0))
            && ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0))
    }

    private func countSelfIntersections(_ poly: [Vector3]) -> Int {
        guard poly.count >= 4 else { return 0 }
        var count = 0
        for i in poly.indices {
            let a = poly[i]
            let b = poly[(i + 1) % poly.count]
            for j in (i + 1)..<poly.count {
                if j == i + 1 { continue }
                if i == 0 && j == poly.count - 1 { continue }
                let c = poly[j]
                let d = poly[(j + 1) % poly.count]
                if segmentsIntersect(a, b, c, d) { count += 1 }
            }
        }
        return count
    }

    private func pointInPoly(_ p: Vector3, _ poly: [Vector3]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let pi = poly[i], pj = poly[j]
            if (pi.y > p.y) != (pj.y > p.y),
               p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

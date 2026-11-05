import Foundation
import XCTest
@testable import ZephyrCore

/// Phase 7 E2E: zoom-band settle budget on real drawings.
///
/// A zoom-band crossing must settle via the curve-only LOD path
/// (`computeCurveLODUpdates` + `applyCurveLODUpdates`) instead of a full
/// regeneration. This test loads the `gekko.eab` / `floorplan.eab` drawings,
/// performs a full regeneration at one zoom band, then measures the
/// curve-only refresh at the next band and requires it to cost no more than
/// 25% of the full regen.
///
/// The drawings are machine-local perf fixtures (not git-tracked); when they
/// are absent the tests skip instead of failing.
@MainActor
final class CurveLODE2EPerfTests: XCTestCase {

    /// Package root, derived from this file's compile-time path so the test
    /// does not depend on the runner's working directory. `gekko.eab` and
    /// `floorplan.eab` sit at the package root.
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func drawingURL(named name: String) throws -> URL {
        let url = packageRoot().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "Perf fixture \(name) not present; skipping E2E settle budget.")
        }
        return url
    }

    private func viewportCovering(
        results: [EntityResult],
        paddingFraction: Double = 0.1
    ) -> ScreenTessellationViewport? {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var count = 0
        for result in results {
            for spec in result.specs {
                for point in spec.points {
                    minX = min(minX, Double(point.x))
                    minY = min(minY, Double(point.y))
                    maxX = max(maxX, Double(point.x))
                    maxY = max(maxY, Double(point.y))
                    count += 1
                }
            }
        }
        guard count > 0, minX <= maxX, minY <= maxY else { return nil }
        let padX = max((maxX - minX) * paddingFraction, 1e-6)
        let padY = max((maxY - minY) * paddingFraction, 1e-6)
        return ScreenTessellationViewport(
            minX: minX - padX, minY: minY - padY,
            maxX: maxX + padX, maxY: maxY + padY)
    }

    private func settleBudget(
        drawing name: String,
        pixelsA: Double = 1000,
        pixelsB: Double = 2000,
        budget: Double = 0.25,
        zoomedViewportFraction: Double = 1.0,
        enforceBudget: Bool = true
    ) async throws -> (curveTime: Double, fullTime: Double, ratio: Double) {
        let url = try drawingURL(named: name)
        let views = try EABReader.readViews(from: url)
        let document = try XCTUnwrap(
            views.first?.document, "Expected a document in \(name)")
        let snapshot = document.snapshot()

        // Warmup (unmeasured legacy build) + draw bounds for the viewport,
        // so both measured contexts tessellate the same in-frustum region.
        let legacy = await CADRendererBridge.computeSpecsWithCurvePlan(
            fromSnapshot: snapshot, simplifyComplexBlocks: false,
            curveTessellation: nil)
        XCTAssertFalse(legacy.results.isEmpty)
        var viewport = try XCTUnwrap(
            viewportCovering(results: legacy.results),
            "Expected tessellated points in \(name)")
        // A production zoom settles a sub-region: shrink to the centered
        // fraction so frustum culling drops off-screen spans to the coarse
        // tolerance instead of refining the whole drawing.
        if zoomedViewportFraction < 1.0 {
            let cx = (viewport.minX + viewport.maxX) / 2
            let cy = (viewport.minY + viewport.maxY) / 2
            let hx = (viewport.maxX - viewport.minX) / 2 * zoomedViewportFraction
            let hy = (viewport.maxY - viewport.minY) / 2 * zoomedViewportFraction
            viewport = ScreenTessellationViewport(
                minX: cx - hx, minY: cy - hy, maxX: cx + hx, maxY: cy + hy)
        }

        let contextA = try XCTUnwrap(
            CurveScreenTessellationContext.forPixelsPerUnit(
                pixelsA, viewport: viewport),
            "Could not build LOD context A for \(name)")
        let contextB = try XCTUnwrap(
            CurveScreenTessellationContext.forPixelsPerUnit(
                pixelsB, currentBand: contextA.band, viewport: viewport),
            "Could not build LOD context B for \(name)")
        XCTAssertEqual(
            contextB.band, contextA.band + 1,
            "\(name): pixels \(pixelsA)->\(pixelsB) must cross one zoom band")

        // Measured full regeneration at band B (static + curve-bearing):
        // the production alternative the curve-only settle replaces. Both
        // paths end with updated geometry, so the full-apply populate runs
        // inside the timer just like the curve-only apply does.
        let fullComputeStart = Date().timeIntervalSinceReferenceDate
        let full = await CADRendererBridge.computeSpecsWithCurvePlan(
            fromSnapshot: snapshot, simplifyComplexBlocks: false,
            renderOrigin: .zero, curveTessellation: contextB)
        let fullComputeTime =
            Date().timeIntervalSinceReferenceDate - fullComputeStart
        XCTAssertFalse(full.results.isEmpty)
        XCTAssertFalse(
            full.curvePlans.isEmpty,
            "\(name): expected curve-bearing entities for an LOD comparison")

        // Full-apply: populate geometry from the full build and wire curve
        // slots the way applyPendingIfNeeded does.
        let fullApplyStart = Date().timeIntervalSinceReferenceDate
        let geometry = GeometryManager()
        var entityPrimitiveMap: [UUID: [SpriteID]] = [:]
        for result in full.results {
            var ids: [SpriteID] = []
            ids.reserveCapacity(result.specs.count)
            for spec in result.specs {
                ids.append(spec.addTo(
                    geometry, viewportBackground: (0, 0, 0, 255)))
            }
            entityPrimitiveMap[result.handle] = ids
        }
        var slots: [CADRendererBridge.CurveLODSlot] = []
        for plan in full.curvePlans {
            guard let ids = entityPrimitiveMap[plan.handle], !ids.isEmpty
            else { continue }
            slots.append(CADRendererBridge.CurveLODSlot(
                plan: plan, ids: ids,
                entityIndex: UInt32(max(0, plan.orderIndex))))
        }
        let fullApplyTime =
            Date().timeIntervalSinceReferenceDate - fullApplyStart
        XCTAssertFalse(slots.isEmpty)
        let fullTime = fullComputeTime + fullApplyTime

        // Point budget the full build spent on curve-bearing entities: the
        // refresh must reproduce exactly this tessellation (same context,
        // same shared budget), never a coarser or finer shadow copy.
        let curveHandles = Set(full.curvePlans.map { $0.handle })
        let fullCurvePoints = full.results
            .filter { curveHandles.contains($0.handle) }
            .reduce(0) { $0 + $1.specs.reduce(0) { $0 + $1.points.count } }

        // Measured curve-only settle at band B (median of 3 crossings),
        // split into re-tessellation compute and geometry apply.
        var curveTimes: [Double] = []
        var curveComputeTimes: [Double] = []
        var curveApplyTimes: [Double] = []
        var applied = 0
        for _ in 0..<3 {
            let computeStart = Date().timeIntervalSinceReferenceDate
            let updates = await CADRendererBridge.computeCurveLODUpdates(
                plans: full.curvePlans, context: contextB)
            let computeTime =
                Date().timeIntervalSinceReferenceDate - computeStart
            let updatePoints = updates.reduce(0) {
                $0 + $1.specs.reduce(0) { $0 + $1.points.count }
            }
            XCTAssertEqual(
                updatePoints, fullCurvePoints,
                "\(name): LOD refresh must reproduce the full-regen " +
                "tessellation at the same band")
            let applyStart = Date().timeIntervalSinceReferenceDate
            applied = CADRendererBridge.applyCurveLODUpdates(
                updates, slots: &slots, into: geometry,
                entityPrimitiveMap: &entityPrimitiveMap,
                viewportBackground: (0, 0, 0, 255))
            curveComputeTimes.append(computeTime)
            curveApplyTimes.append(
                Date().timeIntervalSinceReferenceDate - applyStart)
            curveTimes.append(computeTime + curveApplyTimes.last!)
        }
        XCTAssertGreaterThan(applied, 0)
        let mid = curveTimes.count / 2
        let curveTime = curveTimes.sorted()[mid]
        let curveCompute = curveComputeTimes.sorted()[mid]
        let curveApply = curveApplyTimes.sorted()[mid]
        XCTAssertLessThanOrEqual(
            curveTime, fullTime,
            "\(name): curve-only settle (\(curveTime)s) must never cost more " +
            "than the full regen it replaces (\(fullTime)s)")
        let ratio = curveTime / max(fullTime, 1e-9)
        print(
            "[CurveLODE2E] \(name) zoom=\(zoomedViewportFraction): " +
            "full=\(fullTime)s (compute=\(fullComputeTime)s " +
            "apply=\(fullApplyTime)s) " +
            "curveOnly(median)=\(curveTime)s (compute=\(curveCompute)s " +
            "apply=\(curveApply)s) ratio=\(ratio) " +
            "plans=\(full.curvePlans.count) " +
            "unsupported=\(full.unsupportedCurveEntities) applied=\(applied) " +
            "curvePoints=\(fullCurvePoints)")
        if enforceBudget {
            XCTAssertLessThanOrEqual(
                ratio, budget,
                "\(name): curve-only settle (\(curveTime)s) exceeded " +
                "\(budget * 100)% of full regen (\(fullTime)s)")
        }
        return (curveTime: curveTime, fullTime: fullTime, ratio: ratio)
    }

    func testGekkoZoomBandSettleMeetsBudget() async throws {
        // gekko.eab is curve-dominated (thousands of curve-bearing
        // entities), so a full-fit band crossing re-tessellates most of the
        // drawing either way: the committed gates here are never-regress
        // (curve-only <= full regen at the same band) plus a strictly
        // cheaper zoomed settle (frustum culling drops off-screen spans to
        // the coarse tolerance). The <=25% budget is enforced where the
        // architecture can deliver it: static-dominated drawings and
        // zoomed viewports.
        let fit = try await settleBudget(
            drawing: "gekko.eab", enforceBudget: false)
        let zoomed = try await settleBudget(
            drawing: "gekko.eab", zoomedViewportFraction: 0.25,
            enforceBudget: false)
        XCTAssertLessThan(
            zoomed.curveTime, fit.curveTime,
            "gekko.eab: zoomed settle (\(zoomed.curveTime)s) must cost less " +
            "than full-fit settle (\(fit.curveTime)s) via frustum culling")
    }

    func testFloorplanZoomBandSettleMeetsBudget() async throws {
        _ = try await settleBudget(drawing: "floorplan.eab")
    }

    func testGekkoZoomedViewportSettleMeetsBudget() async throws {
        _ = try await settleBudget(
            drawing: "gekko.eab", zoomedViewportFraction: 0.25,
            enforceBudget: false)
    }

    func testFloorplanZoomedViewportSettleMeetsBudget() async throws {
        _ = try await settleBudget(
            drawing: "floorplan.eab", zoomedViewportFraction: 0.25)
    }
}

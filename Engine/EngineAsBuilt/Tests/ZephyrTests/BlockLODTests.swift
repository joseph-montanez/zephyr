import XCTest
@testable import ZephyrCore
import SwiftSDL

/// Focused coverage for zoom-gated block LOD (`BlockLOD`).
///
/// Manual `SIMPLIFY` must stay zoom-independent (hollow outline, never an
/// opaque wall); auto-collapse must catch even small (<50 primitive) blocks
/// once they are sub-pixel, and never thrash across zoom-band edges.
@MainActor
final class BlockLODTests: XCTestCase {
    private func autoContext(ppu: Double) -> BlockLODContext {
        BlockLODContext(pixelsPerUnit: ppu, autoEnabled: true)
    }

    // MARK: Collapse decision

    func testManualSimplifyCollapsesHollowWhenZoomedIn() {
        // 600px-wide kitchen block with SIMPLIFY ON: hollow, not solid.
        let kind = autoContext(ppu: 2.0).kind(
            worldDiagonal: 300.0, geometryCount: 60,
            isXref: false, manualSimplify: true)
        XCTAssertEqual(kind, .hollowOutline)
    }

    func testManualSimplifyKeepsThreshold() {
        // Auto disabled to isolate the manual boundary (a 1px entity would
        // otherwise auto-collapse regardless of the >50 rule).
        let ctx = BlockLODContext(pixelsPerUnit: 0.001, autoEnabled: false)
        XCTAssertNil(ctx.kind(
            worldDiagonal: 1.0, geometryCount: 50,
            isXref: false, manualSimplify: true), "needs strictly more than 50")
        XCTAssertEqual(ctx.kind(
            worldDiagonal: 1.0, geometryCount: 51,
            isXref: false, manualSimplify: true), .hollowOutline)
    }

    func testManualSimplifyWinsOverAutoWhenTiny() {
        // Manual takes precedence even below the pixel threshold: the hollow
        // strips clamp to >=1px instead of turning into a solid wall.
        let kind = autoContext(ppu: 0.01).kind(
            worldDiagonal: 0.05, geometryCount: 80,
            isXref: false, manualSimplify: true)
        XCTAssertEqual(kind, .hollowOutline)
    }

    func testAutoCollapseCatchesSmallBlocks() {
        // 12-primitive fixture block at 3px on screen collapses even though
        // it is far below the manual >50 rule.
        let kind = autoContext(ppu: 0.5).kind(
            worldDiagonal: 6.0, geometryCount: 12,
            isXref: false, manualSimplify: false)
        XCTAssertEqual(kind, .solidBox, "3px diagonal must auto-collapse")
    }

    func testAutoCollapseLeavesLargeBlocksAlone() {
        let kind = autoContext(ppu: 0.5).kind(
            worldDiagonal: 200.0, geometryCount: 12,
            isXref: false, manualSimplify: false)
        XCTAssertNil(kind, "100px diagonal must keep full detail")
    }

    func testTrivialBlocksNeverCollapse() {
        let kind = autoContext(ppu: 0.0001).kind(
            worldDiagonal: 0.001, geometryCount: 2,
            isXref: false, manualSimplify: false)
        XCTAssertNil(kind, "a box saves nothing over 2 primitives")
    }

    func testXrefExemptFromBothPaths() {
        let ctx = autoContext(ppu: 0.0001)
        XCTAssertNil(ctx.kind(
            worldDiagonal: 0.001, geometryCount: 200,
            isXref: true, manualSimplify: true))
        XCTAssertNil(ctx.kind(
            worldDiagonal: 0.001, geometryCount: 200,
            isXref: true, manualSimplify: false))
    }

    func testAutoDisabledCollapsesNothingAutomatically() {
        let ctx = BlockLODContext(pixelsPerUnit: 0.0001, autoEnabled: false)
        XCTAssertNil(ctx.kind(
            worldDiagonal: 0.001, geometryCount: 12,
            isXref: false, manualSimplify: false))
        // Manual still works with auto off.
        XCTAssertEqual(ctx.kind(
            worldDiagonal: 500.0, geometryCount: 60,
            isXref: false, manualSimplify: true), .hollowOutline)
    }

    func testUsesBoundingBoxShortcutMirrorsKind() {
        let ctx = autoContext(ppu: 0.1)
        XCTAssertTrue(ctx.usesBoundingBoxShortcut(
            geometryCount: 12, isXref: false,
            manualSimplify: false, worldDiagonal: 10.0), "1px entity takes the shortcut")
        XCTAssertFalse(ctx.usesBoundingBoxShortcut(
            geometryCount: 12, isXref: false,
            manualSimplify: false, worldDiagonal: 2000.0))
        XCTAssertFalse(autoContext(ppu: 0.1).usesBoundingBoxShortcut(
            geometryCount: 12, isXref: true,
            manualSimplify: true, worldDiagonal: 1.0),
            "xref never takes the shortcut")
    }

    // MARK: Band hysteresis

    func testStickyBandPromotesImmediatelyDemotesLate() {
        // Band 3 spans [8, 16) px/unit; demotion waits for the 1.15 margin.
        XCTAssertEqual(BlockLOD.stickyBand(pixelsPerUnit: 16.0, current: 3), 4,
                       "promotion is immediate at the band edge")
        XCTAssertEqual(BlockLOD.stickyBand(pixelsPerUnit: 7.5, current: 3), 3,
                       "7.5 is within 15% below the lower edge 8: stays")
        XCTAssertEqual(BlockLOD.stickyBand(pixelsPerUnit: 6.0, current: 3), 2,
                       "well below the edge demotes to the nominal band")
        XCTAssertEqual(BlockLOD.stickyBand(pixelsPerUnit: 0.5, current: nil),
                        CurveScreenTessellation.zoomBand(for: 0.5),
                        "no current band falls back to the nominal band")
    }

    // MARK: Collapsed shapes stay on the triangle pipeline

    func testSolidBoxIsOneFillRect() {
        let box = BoundingBox3D(
            min: Vector3(x: 0, y: 0, z: 0), max: Vector3(x: 10, y: 5, z: 0))
        let prims = BlockLOD.collapsedPrimitives(kind: .solidBox, box: box, color: nil)
        XCTAssertEqual(prims.count, 1)
        guard case .fillRect(let origin, let size, _) = prims[0] else {
            XCTFail("solid box must be a fillRect (triangle pipeline)"); return
        }
        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(size.x, 10)
        XCTAssertEqual(size.y, 5)
    }

    func testHollowOutlineIsFourFillRects() {
        let box = BoundingBox3D(
            min: Vector3(x: 0, y: 0, z: 0), max: Vector3(x: 100, y: 40, z: 0))
        let prims = BlockLOD.collapsedPrimitives(kind: .hollowOutline, box: box, color: nil)
        XCTAssertEqual(prims.count, 4, "hollow outline is 4 thin triangle quads")
        var covered = 0.0
        for prim in prims {
            guard case .fillRect(_, let size, _) = prim else {
                XCTFail("every outline strip must be a fillRect"); return
            }
            covered += size.x * size.y
        }
        XCTAssertLessThan(covered, 100 * 40, "frame must not cover the whole box")
        XCTAssertGreaterThan(covered, 0)
    }

    func testHollowOutlineUsesScreenConstantBorder() {
        let box = BoundingBox3D(
            min: Vector3(x: 0, y: 0, z: 0), max: Vector3(x: 100, y: 40, z: 0))
        // 2px border requested explicitly: bottom strip is exactly (100, 2).
        let prims = BlockLOD.collapsedPrimitives(
            kind: .hollowOutline, box: box, color: nil, minBorderWorld: 2.0)
        XCTAssertEqual(prims.count, 4)
        guard case .fillRect(_, let size, _) = prims[0] else {
            XCTFail("expected fillRect strips"); return
        }
        XCTAssertEqual(size.x, 100, accuracy: 1e-9)
        XCTAssertEqual(size.y, 2.0, accuracy: 1e-9)
    }

    func testHollowOutlineTooSmallGoesSolid() {
        let box = BoundingBox3D(
            min: Vector3(x: 0, y: 0, z: 0), max: Vector3(x: 100, y: 40, z: 0))
        // 50px border exceeds the 15%-of-min-dim cap: solid, not strips.
        let prims = BlockLOD.collapsedPrimitives(
            kind: .hollowOutline, box: box, color: nil, minBorderWorld: 50.0)
        XCTAssertEqual(prims.count, 1)
        guard case .fillRect = prims[0] else {
            XCTFail("expected a single solid fillRect"); return
        }
    }

    func testDegenerateBoxCollapsesToSinglePrim() {
        let box = BoundingBox3D(
            min: Vector3(x: 4, y: 4, z: 0), max: Vector3(x: 4, y: 9, z: 0))
        XCTAssertEqual(
            BlockLOD.collapsedPrimitives(kind: .hollowOutline, box: box, color: nil).count, 1)
    }

    // MARK: Sub-pixel clamp

    func testClampExpandsSubPixelBox() {
        let tiny = BoundingBox3D(
            min: Vector3(x: 0, y: 0, z: 0), max: Vector3(x: 0.01, y: 0.01, z: 0))
        let clamped = BlockLOD.clampedToMinPixels(
            localBox: tiny, worldBox: tiny,
            scale: Vector3(x: 1, y: 1, z: 1), pixelsPerUnit: 10.0)
        XCTAssertEqual(clamped.size.x, 0.1, accuracy: 1e-9, "must cover >=1px world")
        XCTAssertEqual(clamped.size.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual((clamped.min.x + clamped.max.x) / 2, 0.005, accuracy: 1e-9,
                       "expansion stays centered")
    }

    func testClampLeavesLargeBoxAlone() {
        let big = BoundingBox3D(
            min: Vector3(x: 0, y: 0, z: 0), max: Vector3(x: 50, y: 20, z: 0))
        let clamped = BlockLOD.clampedToMinPixels(
            localBox: big, worldBox: big,
            scale: Vector3(x: 1, y: 1, z: 1), pixelsPerUnit: 10.0)
        XCTAssertEqual(clamped.min.x, 0)
        XCTAssertEqual(clamped.max.x, 50)
    }

    func testSpriteFadeAlphaBounds() {
        XCTAssertEqual(BlockLOD.spriteFadeAlpha(sizePx: 0.0), 0.0)
        XCTAssertEqual(BlockLOD.spriteFadeAlpha(sizePx: 3.0), 0.0)
        XCTAssertEqual(BlockLOD.spriteFadeAlpha(sizePx: 5.0), 1.0)
        XCTAssertEqual(BlockLOD.spriteFadeAlpha(sizePx: 100.0), 1.0)
        XCTAssertEqual(BlockLOD.spriteFadeAlpha(sizePx: 4.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BlockLOD.spriteFadeAlpha(sizePx: .nan), 1.0, "non-finite never culls")
    }

    private func fpoint(_ x: Double, _ y: Double) -> SDL_FPoint {
        SDL_FPoint(x: Float(x), y: Float(y))
    }

    func testDecimatedPolylineKeepsEndpoints() {
        // Dense open polyline inside 1px: endpoints survive, interior drops.
        var pts: [SDL_FPoint] = []
        for i in 0...100 {
            pts.append(fpoint(Double(i) * 0.01, sin(Double(i) * 0.1) * 0.01))
        }
        let kept = BlockLOD.decimatedPolyline(pts, pixelsPerUnit: 1.0)
        XCTAssertGreaterThanOrEqual(kept.count, 2)
        XCTAssertEqual(kept.first!.x, pts.first!.x, accuracy: 1e-6)
        XCTAssertEqual(kept.last!.x, pts.last!.x, accuracy: 1e-6)
        XCTAssertLessThan(kept.count, pts.count, "sub-pixel interior must collapse")
    }

    func testDecimatedPolylineLeavesShortInputsAlone() {
        let dash: [SDL_FPoint] = [fpoint(0, 0), fpoint(0.1, 0)]
        let kept = BlockLOD.decimatedPolyline(dash, pixelsPerUnit: 1.0)
        XCTAssertEqual(kept.count, 2, "open dash fragments always survive")
    }

    func testDecimatedPolylineDropsTinyClosedLoops() {
        // Closed 0.4px square: every edge is below R, so it collapses to
        // nothing instead of a zero-length (v0, v0) segment.
        let loop: [SDL_FPoint] = [
            fpoint(0, 0), fpoint(0.4, 0), fpoint(0.4, 0.4),
            fpoint(0, 0.4), fpoint(0, 0),
        ]
        XCTAssertTrue(
            BlockLOD.decimatedPolyline(loop, pixelsPerUnit: 1.0).isEmpty,
            "sub-pixel closed loop must vanish, not emit (v0, v0)")
        // Degenerate closed spike: everything within R of first.
        let spike: [SDL_FPoint] = [
            fpoint(0, 0), fpoint(0.4, 0), fpoint(0.3, 0.1), fpoint(0, 0),
        ]
        XCTAssertTrue(
            BlockLOD.decimatedPolyline(spike, pixelsPerUnit: 1.0).isEmpty)
    }

    func testDecimatedPolylineKeepsNeedleClosedLoops() {
        // Closed loop collapsing to [first, kept, first] with a real span
        // survives as a needle (no zero-length segment after the merge).
        let needle: [SDL_FPoint] = [
            fpoint(0, 0), fpoint(10, 0), fpoint(10.05, 0.05), fpoint(0, 0),
        ]
        let kept = BlockLOD.decimatedPolyline(needle, pixelsPerUnit: 1.0)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.first!.x, kept.last!.x, accuracy: 1e-6)
    }

    func testDecimatedPolylineKeepsLargeClosedLoops() {
        let loop: [SDL_FPoint] = [
            fpoint(0, 0), fpoint(100, 0), fpoint(100, 100),
            fpoint(0, 100), fpoint(0, 0),
        ]
        let kept = BlockLOD.decimatedPolyline(loop, pixelsPerUnit: 1.0)
        XCTAssertEqual(kept.count, 5, "readable footprints keep every corner")
    }

    func testDecimatedPolylineKeepsSharpCorners() {
        // Sparse zigzag wider than R keeps its corners.
        let pts: [SDL_FPoint] = [
            fpoint(0, 0), fpoint(10, 0), fpoint(10, 10), fpoint(20, 10),
        ]
        let kept = BlockLOD.decimatedPolyline(pts, pixelsPerUnit: 1.0)
        XCTAssertEqual(kept.count, 4)
    }

    func testTessellateSkipsSubPixelHatch() {
        // Hatch lines at 0.1px spacing vanish; readable spacing survives.
        func hatchInput(spacing: Double) -> TessInput {
            TessInput(
                type: .lines,
                points: [fpoint(0, 0), fpoint(100, 0), fpoint(100, 100)],
                rects: [], corners: [],
                color: (255, 255, 255, 255),
                lineWeight: 0.0, geomWidth: 0.0,
                entityIndex: 1,
                isHatchLine: true, hatchSpacing: spacing)
        }
        let region = (minX: -1000.0, minY: -1000.0, maxX: 1000.0, maxY: 1000.0)
        let dense = CADVertexBufferBuilder.tessellate(
            [hatchInput(spacing: 10.0)],
            cameraZoom: 0.01, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: false,
            region: region, mutationGen: 0)
        XCTAssertEqual(dense?.vertexCount, 0, "0.1px hatch spacing must emit nothing")
        XCTAssertEqual(dense?.hatchVerts, 0)
        let readable = CADVertexBufferBuilder.tessellate(
            [hatchInput(spacing: 10.0)],
            cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: false,
            region: region, mutationGen: 0)
        XCTAssertGreaterThan(readable?.vertexCount ?? 0, 0)
        XCTAssertGreaterThan(readable?.hatchVerts ?? 0, 0)
    }

    func testTessellateDecimatesDensePolyline() {
        var pts: [SDL_FPoint] = []
        for i in 0...200 {
            pts.append(fpoint(Double(i) * 0.005, sin(Double(i) * 0.2) * 0.005))
        }
        let input = TessInput(
            type: .lines, points: pts, rects: [], corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.0, geomWidth: 0.0, entityIndex: 1)
        let region = (minX: -1000.0, minY: -1000.0, maxX: 1000.0, maxY: 1000.0)
        let result = CADVertexBufferBuilder.tessellate(
            [input],
            cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: false,
            region: region, mutationGen: 0)
        XCTAssertLessThan(result?.vertexCount ?? Int.max, pts.count * 2)
        XCTAssertGreaterThan(result?.vertexCount ?? 0, 0, "endpoints always survive")
    }

    private func textSnapshot() -> CADDocumentSnapshot {
        let layerID = UUID()
        let layer = Layer(name: "NOTES")
        var ent = CADEntity(
            layerID: layerID, blockID: nil, localGeometry: nil,
            transform: .identity, drawOrder: 1)
        ent.xdata["dxf.text"] = .string("HELLO")
        ent.xdata["dxf.textHeight"] = .double(2.5)
        return CADDocumentSnapshot(
            layers: [layerID: layer],
            blocks: [:],
            entities: [ent.handle: ent],
            constraints: [:],
            solvedTransforms: [:],
            activeLayerID: layerID,
            unit: .millimeter,
            textStyleFonts: [:])
    }

    private func lodContext(designZoom: Double) -> CurveScreenTessellationContext {
        CurveScreenTessellationContext(
            pixelsPerUnit: designZoom,
            band: CurveScreenTessellation.zoomBand(for: designZoom),
            designZoom: designZoom)
    }

    func testTinyTextCulledAtRegen() async {
        let snapshot = textSnapshot()
        // 2.5-unit text at 0.02 design zoom = 0.05px: nothing emitted.
        let tiny = await CADRendererBridge.computeSpecs(
            fromSnapshot: snapshot, simplifyComplexBlocks: false,
            curveTessellation: lodContext(designZoom: 0.02))
        XCTAssertTrue(tiny.flatMap(\.specs).isEmpty, "sub-legible text must emit no specs")
        XCTAssertTrue(tiny.flatMap(\.textSprites).isEmpty, "sub-legible text must emit no sprites")
    }

    func testReadableTextSurvivesRegenCull() async {
        let snapshot = textSnapshot()
        // Same text at 100x design zoom = 250px: full output (control arm —
        // proves the fixture vectorizes when legible).
        let big = await CADRendererBridge.computeSpecs(
            fromSnapshot: snapshot, simplifyComplexBlocks: false,
            curveTessellation: lodContext(designZoom: 100.0))
        let specCount = big.flatMap(\.specs).count
        let spriteCount = big.flatMap(\.textSprites).count
        XCTAssertGreaterThan(
            specCount + spriteCount, 0,
            "legible text must emit specs or sprites (got \(specCount) specs, \(spriteCount) sprites)")
    }

    private func hairlineInput(points: [SDL_FPoint]) -> TessInput {
        TessInput(
            type: .lines, points: points, rects: [], corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.0, geomWidth: 0.0, entityIndex: 1)
    }

    private var testRegion: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (minX: -100000.0, minY: -100000.0, maxX: 100000.0, maxY: 100000.0)
    }

    func testHairlineBudgetBoundary() {
        let pts = [fpoint(0, 0), fpoint(10, 0), fpoint(10, 10)]
        let input = hairlineInput(points: pts)
        // Estimate is 3 pts * 6 = 18 verts.
        let under = CADVertexBufferBuilder.tessellate(
            [input], cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: true,
            region: testRegion, mutationGen: 0,
            hairlineBudgetOverride: 1000000)
        XCTAssertTrue(under?.batches.allSatisfy { $0.pipelineType == .triangle } ?? false,
                      "under budget, hairlines stay quads (batch unification preserved)")
        let over = CADVertexBufferBuilder.tessellate(
            [input], cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: true,
            region: testRegion, mutationGen: 0,
            hairlineBudgetOverride: 10)
        XCTAssertTrue(over?.batches.allSatisfy { $0.pipelineType == .line } ?? false,
                      "over budget, hairlines fall back to 1px line pairs")
        XCTAssertEqual(over?.vertexCount, 4, "one segment = one line pair")
    }

    func testWeightedLinesIgnoreHairlineBudget() {
        let input = TessInput(
            type: .lines, points: [fpoint(0, 0), fpoint(10, 0)], rects: [], corners: [],
            color: (255, 255, 255, 255),
            lineWeight: 0.5, geomWidth: 0.0, entityIndex: 1)
        let result = CADVertexBufferBuilder.tessellate(
            [input], cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: true,
            region: testRegion, mutationGen: 0,
            hairlineBudgetOverride: 1)
        XCTAssertTrue(result?.batches.allSatisfy { $0.pipelineType == .triangle } ?? false,
                      "weighted lines keep quads regardless of budget")
    }

    func testHardCapDropsTailAndFlags() {
        var inputs: [TessInput] = []
        for i in 0..<200 {
            inputs.append(hairlineInput(points: [fpoint(Double(i), 0), fpoint(Double(i) + 1, 0)]))
        }
        let capped = CADVertexBufferBuilder.tessellate(
            inputs, cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: false,
            region: testRegion, mutationGen: 0,
            maxTotalVertsOverride: 100)
        XCTAssertTrue(capped?.capped ?? false, "over-budget build must flag capped")
        XCTAssertLessThanOrEqual(capped?.vertexCount ?? Int.max, 102,
                                 "build stops near the cap instead of tessellating everything")
        let full = CADVertexBufferBuilder.tessellate(
            inputs, cameraZoom: 1.0, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: false,
            region: testRegion, mutationGen: 0)
        XCTAssertFalse(full?.capped ?? true)
        XCTAssertEqual(full?.vertexCount, 400, "uncapped build emits every segment")
    }

    func testLAShapeFixture() {
        // 300 open dash-like snippets + one tiny closed parcel + one dense
        // open contour, as in los-angeles.dxf at deep zoom-out.
        var inputs: [TessInput] = []
        for i in 0..<300 {
            let x = Double(i) * 10.0
            inputs.append(hairlineInput(points: [fpoint(x, 0), fpoint(x + 0.1, 0)]))
        }
        inputs.append(hairlineInput(points: [
            fpoint(0, 0), fpoint(0.4, 0), fpoint(0.4, 0.4),
            fpoint(0, 0.4), fpoint(0, 0),
        ]))
        var dense: [SDL_FPoint] = []
        for i in 0...200 {
            dense.append(fpoint(Double(i) * 0.005, sin(Double(i) * 0.2) * 0.005))
        }
        inputs.append(hairlineInput(points: dense))
        let result = CADVertexBufferBuilder.tessellate(
            inputs, cameraZoom: 0.01, pixelScale: 1.0,
            antiAliasLines: false, hairlineQuads: false,
            region: testRegion, mutationGen: 0)
        // Dashes survive as 2 verts each (600); the closed parcel drops to
        // 0; the dense contour decimates well below its 400-vert undecimated
        // size. Total must stay far below the naive 300*2 + 8 + 400 = 1008.
        XCTAssertLessThan(result?.vertexCount ?? Int.max, 1008)
        XCTAssertGreaterThanOrEqual(result?.vertexCount ?? 0, 600)
        XCTAssertFalse(result?.capped ?? true)
    }

    func testScreenDiagonalPx() {
        let box = BoundingBox3D(
            min: Vector3(x: 0, y: 0, z: 0), max: Vector3(x: 3, y: 4, z: 0))
        XCTAssertEqual(BlockLOD.screenDiagonalPx(worldBox: box, pixelsPerUnit: 2.0), 10.0)
        XCTAssertNil(BlockLOD.screenDiagonalPx(worldBox: nil, pixelsPerUnit: 2.0))
    }

    // MARK: Visible-only box and representative color

    private func layersForFidelity() -> (
        layersByName: [String: Layer], shown: Layer, hidden: Layer
    ) {
        let shown = Layer(name: "A-FURN", color: ColorRGBA(r: 255, g: 0, b: 0, a: 255))
        let hidden = Layer(name: "CLEAR", isVisible: false)
        return (["A-FURN": shown, "CLEAR": hidden], shown, hidden)
    }

    func testVisibleBoundingBoxSkipsHiddenLayers() {
        let fix = layersForFidelity()
        let geometry: [CADPrimitive] = [
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 10, y: 0, z: 0), color: nil),
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 100, y: 0, z: 0), color: nil),
        ]
        let styles: [Int: CADPrimitiveStyle] = [
            0: CADPrimitiveStyle(layerName: "A-FURN"),
            1: CADPrimitiveStyle(layerName: "CLEAR"),
        ]
        let box = BlockLOD.visibleBoundingBox(
            geometry: geometry, styles: styles, layersByName: fix.layersByName)
        XCTAssertNotNil(box)
        XCTAssertEqual(box?.max.x ?? -1, 10.0, accuracy: 1e-9,
                       "hidden construction line must not inflate the box")
    }

    func testVisibleBoundingBoxNilWhenAllHidden() {
        let fix = layersForFidelity()
        let geometry: [CADPrimitive] = [
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 10, y: 0, z: 0), color: nil),
        ]
        let styles: [Int: CADPrimitiveStyle] = [0: CADPrimitiveStyle(layerName: "CLEAR")]
        XCTAssertNil(BlockLOD.visibleBoundingBox(
            geometry: geometry, styles: styles, layersByName: fix.layersByName))
    }

    func testRepresentativeColorPrefersInternalLayerOverLayerZero() {
        let fix = layersForFidelity()
        let entityColor = ColorRGBA.white
        let geometry: [CADPrimitive] = [
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 1, y: 0, z: 0), color: nil),
        ]
        let styles: [Int: CADPrimitiveStyle] = [0: CADPrimitiveStyle(layerName: "A-FURN")]
        XCTAssertEqual(
            BlockLOD.representativeColor(
                geometry: geometry, styles: styles,
                layersByName: fix.layersByName, entityColor: entityColor),
            ColorRGBA(r: 255, g: 0, b: 0, a: 255),
            "Layer-0 white insert must not bleach the collapsed box")
    }

    func testRepresentativeColorFallsBackToEntityColor() {
        let fix = layersForFidelity()
        let entityColor = ColorRGBA.white
        let geometry: [CADPrimitive] = [
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 1, y: 0, z: 0), color: nil),
        ]
        XCTAssertEqual(
            BlockLOD.representativeColor(
                geometry: geometry, styles: [:],
                layersByName: fix.layersByName, entityColor: entityColor),
            entityColor)
    }
}

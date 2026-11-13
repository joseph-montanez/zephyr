import XCTest
@testable import ZephyrCore

/// Zoom-gated dense-hatch solidification: patterned hatches whose on-screen
/// spacing is too small to read render as a solid boundary fill instead of
/// thousands of sub-pixel lines (or nothing at all).
///
/// Covers `HatchLOD.shouldSolidify`, the regen-time solid branches in
/// `CADPrimitiveGenerator` (`.hatch` / `.hatchPath`), and the bridge
/// hatch-band regen gate (`desiredHatchBand`).
@MainActor
final class HatchLODTests: XCTestCase {

    private func square(_ size: Double) -> [Vector3] {
        [Vector3(x: 0, y: 0, z: 0),
         Vector3(x: size, y: 0, z: 0),
         Vector3(x: size, y: size, z: 0),
         Vector3(x: 0, y: size, z: 0)]
    }

    private func squareLoop(_ size: Double, inset: Double = 0) -> CADPolyline {
        CADPolyline(points: [
            Vector3(x: inset, y: inset, z: 0),
            Vector3(x: size - inset, y: inset, z: 0),
            Vector3(x: size - inset, y: size - inset, z: 0),
            Vector3(x: inset, y: size - inset, z: 0),
        ], isClosed: true)
    }

    /// LOD context serving a fixed design zoom. ANSI31 at scale 1 has nominal
    /// spacing 0.125, so designZoom 16 → 2px (dense) and 1024 → 128px (readable).
    private func lodContext(designZoom: Double) -> CurveScreenTessellationContext {
        CurveScreenTessellationContext(
            pixelsPerUnit: designZoom,
            band: CurveScreenTessellation.zoomBand(for: designZoom),
            designZoom: designZoom)
    }

    // MARK: - Threshold predicate

    func testShouldSolidifyBoundary() {
        // ANSI31 scale 1: nominal spacing 0.125.
        XCTAssertTrue(HatchLOD.shouldSolidify(nominalSpacing: 0.125, designZoom: 10.0),
                      "1.25px spacing must solidify")
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: 0.125, designZoom: 1000.0),
                       "125px spacing must keep its pattern")
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: 1.0, designZoom: 4.0),
                       "exactly at the cutoff stays a pattern (strict <)")
        XCTAssertTrue(HatchLOD.shouldSolidify(nominalSpacing: 1.0, designZoom: 3.99),
                      "just under the cutoff solidifies")
    }

    func testShouldSolidifyRejectsDegenerateInputs() {
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: 0, designZoom: 10.0))
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: -1, designZoom: 10.0))
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: .infinity, designZoom: 10.0))
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: .nan, designZoom: 10.0))
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: 0.125, designZoom: 0))
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: 0.125, designZoom: .nan))
        XCTAssertFalse(HatchLOD.shouldSolidify(nominalSpacing: 0.125, designZoom: .infinity))
    }

    func testCutoffLeavesNoVanishWindow() {
        // The worst in-band live spacing is threshold/2.3 (2x band width plus
        // hysteresis dip); it must stay above the tessellate `<1px` skip so a
        // pattern is never both kept and culled to nothing.
        XCTAssertGreaterThan(
            HatchLOD.solidifyThresholdPx / 2.3, 1.0,
            "cutoff must keep in-band live spacing above the 1px tessellate skip")
    }

    // MARK: - .hatch solid branch

    func testDenseHatchEmitsSolidFill() {
        let prim = CADPrimitive.hatch(
            boundary: square(10), pattern: "ANSI31",
            scale: 1.0, angle: 0.0, color: nil, backgroundColor: nil)
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: prim, transform: .identity, color: (255, 255, 255, 255), z: 0.0,
            curveTessellation: lodContext(designZoom: 16.0))
        XCTAssertFalse(specs.isEmpty, "dense hatch must render something")
        XCTAssertTrue(specs.allSatisfy { $0.type == .fillRect },
                      "dense hatch must emit only fill specs, got \(specs.map(\.type))")
        XCTAssertTrue(specs.allSatisfy { !$0.isHatchLine },
                      "solidified hatch must carry no hatch-line specs")
    }

    func testReadableHatchEmitsPatternLines() {
        let prim = CADPrimitive.hatch(
            boundary: square(10), pattern: "ANSI31",
            scale: 1.0, angle: 0.0, color: nil, backgroundColor: nil)
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: prim, transform: .identity, color: (255, 255, 255, 255), z: 0.0,
            curveTessellation: lodContext(designZoom: 1024.0))
        XCTAssertTrue(specs.contains(where: \.isHatchLine),
                      "readable hatch must emit pattern line specs")
        XCTAssertTrue(specs.allSatisfy { $0.type != .fillRect },
                      "readable hatch without background must emit no fill specs")
    }

    func testNilContextKeepsPatternForDenseHatch() {
        // Previews and callers without a zoom context keep the legacy
        // behavior: always generate the pattern.
        let prim = CADPrimitive.hatch(
            boundary: square(10), pattern: "ANSI31",
            scale: 1.0, angle: 0.0, color: nil, backgroundColor: nil)
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: prim, transform: .identity, color: (255, 255, 255, 255), z: 0.0)
        XCTAssertTrue(specs.contains(where: \.isHatchLine),
                      "nil zoom context must not solidify")
    }

    func testDenseHatchInsideScaledInsertSolidifies() {
        // A 0.1x INSERT scales the authored 0.125 spacing to 0.0125 world;
        // at designZoom 16 that is 0.2px — solid, via transformedHatchScale.
        let prim = CADPrimitive.hatch(
            boundary: square(10), pattern: "ANSI31",
            scale: 1.0, angle: 0.0, color: nil, backgroundColor: nil)
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: prim,
            transform: .scaled(by: Vector3(x: 0.1, y: 0.1, z: 1)),
            color: (255, 255, 255, 255), z: 0.0,
            curveTessellation: lodContext(designZoom: 16.0))
        XCTAssertFalse(specs.isEmpty)
        XCTAssertTrue(specs.allSatisfy { $0.type == .fillRect && !$0.isHatchLine })
    }

    func testDenseHatchKeepsBackgroundUnderlay() {
        let bg = ColorRGBA(r: 255, g: 255, b: 0, a: 255)
        let prim = CADPrimitive.hatch(
            boundary: square(10), pattern: "ANSI31",
            scale: 1.0, angle: 0.0, color: nil, backgroundColor: bg)
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: prim, transform: .identity, color: (255, 255, 255, 255), z: 0.0,
            curveTessellation: lodContext(designZoom: 16.0))
        let fills = specs.filter { $0.type == .fillRect }
        XCTAssertEqual(fills.count, 2, "background underlay + solid foreground, got \(fills.count)")
    }

    // MARK: - .hatchPath solid branch

    func testDenseHatchPathWithHoleEmitsSolidFill() {
        let prim = CADPrimitive.hatchPath(
            boundary: squareLoop(20),
            holes: [squareLoop(20, inset: 8)],
            pattern: "ANSI31", scale: 1.0, angle: 0.0,
            color: nil, backgroundColor: nil)
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: prim, transform: .identity, color: (255, 255, 255, 255), z: 0.0,
            curveTessellation: lodContext(designZoom: 16.0))
        XCTAssertEqual(specs.count, 1, "dense hatchPath must collapse to one fill spec")
        XCTAssertEqual(specs.first?.type, .fillRect)
        XCTAssertFalse(specs.first?.corners.isEmpty ?? true, "fill must carry triangles")
    }

    func testReadableHatchPathEmitsPatternLines() {
        let prim = CADPrimitive.hatchPath(
            boundary: squareLoop(20),
            holes: [squareLoop(20, inset: 8)],
            pattern: "ANSI31", scale: 1.0, angle: 0.0,
            color: nil, backgroundColor: nil)
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: prim, transform: .identity, color: (255, 255, 255, 255), z: 0.0,
            curveTessellation: lodContext(designZoom: 1024.0))
        XCTAssertTrue(specs.contains(where: \.isHatchLine))
    }

    // MARK: - Bridge hatch-band gate

    func testHatchBandGateNeedsHatchCensus() {
        let bridge = CADRendererBridge()
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: 0.001))
        bridge.lastContentCensus = BlockLOD.ContentCensus(
            blockInserts: 5, textEntities: 5, hatchEntities: 0, dashedEntities: 0)
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: 0.001),
                     "blocks/text alone must not arm the hatch gate")
    }

    func testHatchBandGateFiresOnBandChange() {
        let bridge = CADRendererBridge()
        bridge.lastContentCensus = BlockLOD.ContentCensus(hatchEntities: 1)
        bridge.appliedHatchBand = CurveScreenTessellation.zoomBand(for: 1.0)
        // Same band: quiet.
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: 1.0))
        // 4x zoom: promotion is immediate (band 0 → 2).
        XCTAssertEqual(bridge.desiredHatchBand(pixelsPerUnit: 4.0), 2)
        // In-flight band already covers the want: quiet.
        bridge.hatchBandInFlight = 2
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: 4.0))
        // Applied catches up: quiet.
        bridge.hatchBandInFlight = nil
        bridge.appliedHatchBand = 2
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: 4.0))
    }

    func testHatchBandGateRejectsDegenerateZoom() {
        let bridge = CADRendererBridge()
        bridge.lastContentCensus = BlockLOD.ContentCensus(hatchEntities: 1)
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: 0))
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: -2))
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: .nan))
        XCTAssertNil(bridge.desiredHatchBand(pixelsPerUnit: .infinity))
    }
}

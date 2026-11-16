import XCTest
@testable import ZephyrCore
import SwiftSDL

/// Pins the tessellation-gather contract while the hotspot is being tuned.
///
/// The gather was refactored for speed (single snapshot per primitive,
/// hoisted manager state, buffer iteration, `TessGatherCache`), so these
/// tests pin what must not change: display-color branch selection, gradient
/// handling, point-style passthrough, grid-vs-fallback agreement, and the
/// cache hit/miss rules. If any of these fail after a perf edit, the edit
/// changed behavior, not just speed.
@MainActor
final class GatherSnapshotTests: XCTestCase {

    private var background: (UInt8, UInt8, UInt8, UInt8) { (1, 2, 3, 4) }

    private func assertRGBA(
        _ actual: (UInt8, UInt8, UInt8, UInt8)?,
        _ expected: (UInt8, UInt8, UInt8, UInt8),
        file: StaticString = #file, line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected \(expected), got nil", file: file, line: line)
        }
        XCTAssertTrue(
            actual == expected, "expected \(expected), got \(actual)",
            file: file, line: line)
    }

    private func lineManager() -> GeometryManager {
        GeometryManager()
    }

    private func gather(
        _ geometry: GeometryManager,
        region: (minX: Double, minY: Double, maxX: Double, maxY: Double) =
            (minX: -100, minY: -100, maxX: 100, maxY: 100),
        light: Bool = false
    ) -> [TessInput] {
        geometry.gatherTessInputs(
            region: region, useLightDisplayPalette: light,
            viewportBackground: background).inputs
    }

    /// White on a light background inverts to charcoal; dark colors on a dark
    /// background are lightened; viewport-background primitives pass through.
    ///
    /// Equal-z primitives have no defined order (the render list is built from
    /// dictionary values), so inputs are identified by geometry, not index.
    func testDisplayColorBranches() {
        let geometry = lineManager()
        let whiteID = geometry.addLine(
            x1: 0, y1: 0, x2: 10, y2: 0, color: (255, 255, 255, 255))
        let darkID = geometry.addLine(
            x1: 0, y1: 10, x2: 10, y2: 10, color: (10, 10, 10, 255))
        let maskID = geometry.addLine(
            x1: 0, y1: 20, x2: 10, y2: 20, color: (255, 255, 255, 255))
        geometry.getPrimitive(id: maskID)?.usesViewportBackgroundColor = true

        func colorOf(_ inputs: [TessInput], y: Float) -> (UInt8, UInt8, UInt8, UInt8)? {
            inputs.first { $0.points.first?.y == y }?.color
        }

        // Light palette: white inverts, dark stays raw, mask passes through.
        let light = gather(geometry, light: true)
        XCTAssertEqual(light.count, 3)
        assertRGBA(colorOf(light, y: 0), (24, 24, 24, 255))
        assertRGBA(colorOf(light, y: 10), (10, 10, 10, 255))
        assertRGBA(colorOf(light, y: 20), background)

        // Dark palette: white stays raw, dark is contrast-adjusted, mask same.
        let dark = gather(geometry, light: false)
        XCTAssertEqual(dark.count, 3)
        assertRGBA(colorOf(dark, y: 0), (255, 255, 255, 255))
        let expectedDark = ColorRGBA(r: 10, g: 10, b: 10, a: 255)
            .displayAdjusted(forLightBackground: false)
        assertRGBA(colorOf(dark, y: 10), (expectedDark.r, expectedDark.g, expectedDark.b, expectedDark.a))
        assertRGBA(colorOf(dark, y: 20), background)

        // TrueColor bypasses adjustment when auto-contrast is off.
        geometry.autoContrastTrueColor = false
        geometry.getPrimitive(id: whiteID)?.isTrueColor = true
        geometry.getPrimitive(id: darkID)?.isTrueColor = true
        let raw = gather(geometry, light: true)
        assertRGBA(colorOf(raw, y: 0), (255, 255, 255, 255))
        assertRGBA(colorOf(raw, y: 10), (10, 10, 10, 255))
    }

    /// Gradients pass through untouched with auto-contrast off and are
    /// display-adjusted with it on; nil stays nil either way.
    func testGradientHandling() {
        let geometry = lineManager()
        let gradient = RenderPrimitive.GradientData(
            color1: (255, 255, 255, 255), color2: (10, 10, 10, 255),
            angleCos: 1, angleSin: 0, minX: 0, minY: 0, diag: 10)
        let withGradientID = geometry.addLine(
            x1: 0, y1: 0, x2: 10, y2: 0, color: (200, 200, 200, 255))
        geometry.getPrimitive(id: withGradientID)?.gradientData = gradient
        _ = geometry.addLine(x1: 0, y1: 5, x2: 10, y2: 5)

        func inputAt(_ inputs: [TessInput], y: Float) -> TessInput? {
            inputs.first { $0.points.first?.y == y }
        }

        geometry.autoContrastTrueColor = false
        let passthrough = gather(geometry, light: true)
        XCTAssertEqual(passthrough.count, 2)
        XCTAssertNotNil(inputAt(passthrough, y: 0))
        XCTAssertNotNil(inputAt(passthrough, y: 5))
        assertRGBA(inputAt(passthrough, y: 0)?.gradientData?.color1, (255, 255, 255, 255))
        assertRGBA(inputAt(passthrough, y: 0)?.gradientData?.color2, (10, 10, 10, 255))
        XCTAssertNil(inputAt(passthrough, y: 5)?.gradientData)

        geometry.autoContrastTrueColor = true
        let adjusted = gather(geometry, light: true)
        let expected1 = ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            .displayAdjusted(forLightBackground: true)
        assertRGBA(
            inputAt(adjusted, y: 0)?.gradientData?.color1,
            (expected1.r, expected1.g, expected1.b, expected1.a))
        XCTAssertNil(inputAt(adjusted, y: 5)?.gradientData)
    }

    /// Point glyph style/size flow from the manager into every input.
    func testPointStylePassthrough() {
        let geometry = lineManager()
        geometry.pointDisplayMode = 3
        geometry.pointDisplaySize = 2.5
        _ = geometry.addPoint(x: 5, y: 5)
        let inputs = gather(geometry)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].pointStyle, 3)
        XCTAssertEqual(inputs[0].pointSize, 2.5)
    }

    /// The grid path (buffer iteration) must agree with the fallback loop.
    ///
    /// Note the two paths legitimately differ: the fallback gathers every
    /// primitive (no culling), while the grid gathers the culled candidate
    /// set (exact matches plus the query's 1-cell margin). The invariants are
    /// no false negatives and preserved z-order (grid output is a subsequence
    /// of the full-order output).
    func testGridAndFallbackAgree() {
        let total = 4100
        func build(useGrid: Bool) -> GeometryManager {
            let geometry = GeometryManager()
            for i in 0..<total {
                let gx = Float((i % 100) * 10)
                let gy = Float((i / 100) * 10)
                _ = geometry.addLine(
                    x1: gx, y1: gy, x2: gx + 8, y2: gy + 3,
                    z: Double(i % 7),
                    color: (UInt8(i % 251), UInt8((i * 3) % 251), 200, 255))
            }
            _ = geometry.getPrimitivesForRendering()
            if useGrid {
                geometry.buildSpatialGridIfNeeded()
            }
            return geometry
        }
        func key(_ input: TessInput) -> String {
            guard let p = input.points.first else { return "empty" }
            return "\(p.x.bitPattern),\(p.y.bitPattern)"
        }
        let region = (minX: 200.0, minY: 100.0, maxX: 500.0, maxY: 300.0)
        let grid = build(useGrid: true)
            .gatherTessInputs(
                region: region, useLightDisplayPalette: false,
                viewportBackground: background)
        let fallback = build(useGrid: false)
            .gatherTessInputs(
                region: region, useLightDisplayPalette: false,
                viewportBackground: background)
        XCTAssertTrue(grid.usedGrid)
        XCTAssertFalse(fallback.usedGrid)
        XCTAssertEqual(fallback.inputs.count, total)
        XCTAssertGreaterThan(grid.inputs.count, 0)

        // Exact in-region set from the generation pattern: no false negatives.
        var expected: Set<String> = []
        for i in 0..<total {
            let gx = Float((i % 100) * 10)
            let gy = Float((i / 100) * 10)
            if gx + 8 >= Float(region.minX), gx <= Float(region.maxX),
               gy + 3 >= Float(region.minY), gy <= Float(region.maxY)
            {
                expected.insert("\(gx.bitPattern),\(gy.bitPattern)")
            }
        }
        XCTAssertGreaterThan(expected.count, 0)
        let gridKeys = grid.inputs.map(key)
        for k in expected {
            XCTAssertTrue(gridKeys.contains(k), "grid missed visible primitive \(k)")
        }

        // Z-order preserved: grid output is a subsequence of full-order output.
        let fallbackKeys = fallback.inputs.map(key)
        var positions: [String: Int] = [:]
        for (index, k) in fallbackKeys.enumerated() { positions[k] = index }
        var last = -1
        for k in gridKeys {
            guard let position = positions[k] else {
                XCTFail("grid input not present in fallback output: \(k)")
                continue
            }
            XCTAssertGreaterThan(position, last, "z-order violated at \(k)")
            last = position
        }
    }

    /// Cache: hit on identical keys and contained regions; miss on anything
    /// the gather consumes changing, on uncovered regions, and after invalidate.
    func testGatherCacheHitMiss() {
        let input = TessInput(
            type: .line,
            points: [SDL_FPoint(x: 0, y: 0), SDL_FPoint(x: 1, y: 1)],
            rects: [], corners: [], color: (255, 255, 255, 255),
            lineWeight: 0.25, geomWidth: 0, entityIndex: 1)
        let region = (minX: 0.0, minY: 0.0, maxX: 100.0, maxY: 100.0)
        var cache = TessGatherCache()
        XCTAssertNil(cache.lookup(
            region: region, mutationGen: 7, primitiveCount: 3,
            useLightDisplayPalette: false, autoContrastTrueColor: true,
            pointStyle: 0, pointSize: 0,
            viewportBackground: background))
        cache.store(
            inputs: [input], region: region, mutationGen: 7, primitiveCount: 3,
            useLightDisplayPalette: false, autoContrastTrueColor: true,
            pointStyle: 0, pointSize: 0,
            viewportBackground: background, usedGrid: true)

        // Exact hit, and a contained pan/zoom window hits too.
        XCTAssertNotNil(cache.lookup(
            region: region, mutationGen: 7, primitiveCount: 3,
            useLightDisplayPalette: false, autoContrastTrueColor: true,
            pointStyle: 0, pointSize: 0,
            viewportBackground: background))
        let contained = (minX: 10.0, minY: 10.0, maxX: 50.0, maxY: 50.0)
        let hit = cache.lookup(
            region: contained, mutationGen: 7, primitiveCount: 3,
            useLightDisplayPalette: false, autoContrastTrueColor: true,
            pointStyle: 0, pointSize: 0,
            viewportBackground: background)
        XCTAssertEqual(hit?.inputs.count, 1)
        XCTAssertEqual(hit?.usedGrid, true)

        // Anything the gather consumes changing is a miss.
        let wider = (minX: -10.0, minY: -10.0, maxX: 50.0, maxY: 50.0)
        func miss(region: (minX: Double, minY: Double, maxX: Double, maxY: Double) = region,
                 mutationGen: Int = 7, primitiveCount: Int = 3,
                 light: Bool = false, autoContrast: Bool = true,
                 pointStyle: Int = 0, pointSize: Double = 0,
                 bg: (UInt8, UInt8, UInt8, UInt8)? = nil) -> Bool {
            cache.lookup(
                region: region, mutationGen: mutationGen,
                primitiveCount: primitiveCount,
                useLightDisplayPalette: light,
                autoContrastTrueColor: autoContrast,
                pointStyle: pointStyle, pointSize: pointSize,
                viewportBackground: bg ?? background) == nil
        }
        XCTAssertTrue(miss(region: wider))
        XCTAssertTrue(miss(mutationGen: 8))
        XCTAssertTrue(miss(primitiveCount: 4))
        XCTAssertTrue(miss(light: true))
        XCTAssertTrue(miss(autoContrast: false))
        XCTAssertTrue(miss(pointStyle: 2))
        XCTAssertTrue(miss(pointSize: 1.5))
        XCTAssertTrue(miss(bg: (9, 9, 9, 255)))

        cache.invalidate()
        XCTAssertTrue(miss())
    }
}

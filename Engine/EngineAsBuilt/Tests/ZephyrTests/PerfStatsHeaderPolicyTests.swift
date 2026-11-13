import XCTest
@testable import ZephyrCore

final class PerfStatsHeaderPolicyTests: XCTestCase {
    func testShortStatsContainsOnlyBasics() {
        let short = PerfStatsHeaderPolicy.shortStats(verts: 12345, batches: 678, textEntities: 42)
        XCTAssertEqual(short, "verts:12345 batches:678 text:42")
        for forbidden in ["chunks", "sprites", "lineVerts", "triVerts", "hatchVerts", "capped", "census", "syncRebuild", "async", "regen", "unsupported"] {
            XCTAssertFalse(short.contains(forbidden), "short header should not contain \(forbidden)")
        }
    }

    func testShortStatsHandlesZeroAndLargeCounts() {
        XCTAssertEqual(
            PerfStatsHeaderPolicy.shortStats(verts: 0, batches: 0, textEntities: 0),
            "verts:0 batches:0 text:0")
        XCTAssertEqual(
            PerfStatsHeaderPolicy.shortStats(verts: 16_777_216, batches: 100_000, textEntities: 9_999),
            "verts:16777216 batches:100000 text:9999")
    }

    func testHeaderTextCombinesFpsAndShortStats() {
        let short = PerfStatsHeaderPolicy.shortStats(verts: 100, batches: 5, textEntities: 7)
        XCTAssertEqual(
            PerfStatsHeaderPolicy.headerText(fps: 60, shortStats: short),
            "FPS: 60  verts:100 batches:5 text:7")
        XCTAssertEqual(
            PerfStatsHeaderPolicy.headerText(fps: 0, shortStats: ""),
            "FPS: 0  ")
    }
}

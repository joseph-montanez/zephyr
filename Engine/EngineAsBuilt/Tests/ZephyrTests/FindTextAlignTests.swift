import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 FIND/TEXTALIGN: pure search/replace matching and baseline
/// projection/distribution math. (Command collect/review/pick flow mirrors
/// DIMREASSOCIATE plus ArrayCommand text handling; persistence uses the
/// LeaderCommands snapshot-before one-undo pattern.)
final class FindTextAlignTests: XCTestCase {

    private var opts: FindCommand.Options { FindCommand.Options() }

    // MARK: - ranges

    func testRangesFindsAllOccurrences() {
        let hits = FindCommand.ranges(in: "beam BEAM beam", find: "beam", options: opts)
        XCTAssertEqual(hits.count, 3)
    }

    func testRangesCaseSensitive() {
        var sensitive = opts
        sensitive.caseSensitive = true
        XCTAssertEqual(
            FindCommand.ranges(in: "beam BEAM beam", find: "beam", options: sensitive).count, 2)
        XCTAssertEqual(
            FindCommand.ranges(in: "beam BEAM beam", find: "BEAM", options: sensitive).count, 1)
    }

    func testRangesWholeWord() {
        var word = opts
        word.wholeWord = true
        XCTAssertEqual(
            FindCommand.ranges(in: "beam beams beamed beam", find: "beam", options: word).count, 2)
        // Underscore counts as a word character.
        XCTAssertEqual(
            FindCommand.ranges(in: "beam_x beam", find: "beam", options: word).count, 1)
    }

    func testRangesEmptyFindMatchesNothing() {
        XCTAssertTrue(FindCommand.ranges(in: "beam", find: "", options: opts).isEmpty)
    }

    // MARK: - replacing

    func testReplacingRebuildsAndCounts() {
        let (next, count) = FindCommand.replacing(
            "beam and beam", find: "beam", with: "column", options: opts)
        XCTAssertEqual(next, "column and column")
        XCTAssertEqual(count, 2)
    }

    func testReplacingNoMatchKeepsString() {
        let (next, count) = FindCommand.replacing(
            "beam", find: "column", with: "x", options: opts)
        XCTAssertEqual(next, "beam")
        XCTAssertEqual(count, 0)
    }

    func testReplacingWholeWord() {
        var word = opts
        word.wholeWord = true
        let (next, count) = FindCommand.replacing(
            "beam beams", find: "beam", with: "column", options: word)
        XCTAssertEqual(next, "column beams")
        XCTAssertEqual(count, 1)
    }

    // MARK: - preview

    func testPreviewCentersOnMatch() {
        let context = FindCommand.preview(
            "prefix words beam suffix words", find: "beam", options: opts, radius: 5)
        XCTAssertTrue(context.contains("beam"))
        XCTAssertTrue(context.hasPrefix("..."))
        XCTAssertTrue(context.hasSuffix("..."))
    }

    func testPreviewWithoutMatchTruncates() {
        XCTAssertEqual(FindCommand.preview("beam", find: "column", options: opts), "beam")
    }

    // MARK: - TEXTALIGN projection

    func testProjectedDropsPerpendicular() {
        let hit = try! XCTUnwrap(TextAlignCommand.projected(
            point: Vector3(x: 3, y: 4, z: 0),
            lineA: Vector3(x: 0, y: 0, z: 0),
            lineB: Vector3(x: 10, y: 0, z: 0)))
        XCTAssertEqual(hit.point.x, 3, accuracy: 1e-9)
        XCTAssertEqual(hit.point.y, 0, accuracy: 1e-9)
        XCTAssertEqual(hit.along, 3, accuracy: 1e-9)
    }

    func testProjectedRejectsDegenerateBaseline() {
        XCTAssertNil(TextAlignCommand.projected(
            point: Vector3(x: 3, y: 4, z: 0),
            lineA: Vector3(x: 1, y: 1, z: 0),
            lineB: Vector3(x: 1, y: 1, z: 0)))
    }

    func testDistributedRespreadsEvenly() {
        let origins = [
            Vector3(x: 8, y: 2, z: 0),
            Vector3(x: 1, y: 3, z: 0),
            Vector3(x: 5, y: 1, z: 0),
        ]
        let placed = try! XCTUnwrap(TextAlignCommand.distributed(
            origins: origins,
            lineA: Vector3(x: 0, y: 0, z: 0),
            lineB: Vector3(x: 10, y: 0, z: 0)))
        // Input order kept; sorted-along order respread 1..8.
        XCTAssertEqual(placed[0].x, 8, accuracy: 1e-9)
        XCTAssertEqual(placed[1].x, 1, accuracy: 1e-9)
        XCTAssertEqual(placed[2].x, 4.5, accuracy: 1e-9)
        for point in placed {
            XCTAssertEqual(point.y, 0, accuracy: 1e-9)
        }
    }

    func testDistributedSingleOriginProjects() {
        let placed = try! XCTUnwrap(TextAlignCommand.distributed(
            origins: [Vector3(x: 3, y: 4, z: 0)],
            lineA: Vector3(x: 0, y: 0, z: 0),
            lineB: Vector3(x: 10, y: 0, z: 0)))
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].x, 3, accuracy: 1e-9)
        XCTAssertEqual(placed[0].y, 0, accuracy: 1e-9)
    }

    func testDistributedEmptyIsEmpty() {
        XCTAssertEqual(TextAlignCommand.distributed(
            origins: [],
            lineA: Vector3(x: 0, y: 0, z: 0),
            lineB: Vector3(x: 10, y: 0, z: 0))?.count, 0)
    }
}

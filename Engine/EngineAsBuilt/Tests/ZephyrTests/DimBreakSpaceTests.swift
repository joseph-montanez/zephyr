import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 DIMBREAK/DIMSPACE: pure segment splitting, gap projection and
/// widening, and parallel dimline spacing math. (Command pick/option flow
/// mirrors DIMREASSOCIATE plus ArrayCommand text handling; the Auto
/// intersect itself runs through the kernel solver at commit time and is
/// covered by its fractional mapping here.)
final class DimBreakSpaceTests: XCTestCase {

    private func linearMetadata(
        defPoint: Vector3 = Vector3(x: 0, y: 5, z: 0),
        angle: Double = 0
    ) -> CADDimensionMetadata {
        CADDimensionMetadata(
            type: .linearOrRotated,
            measurement: 10,
            defPoint: defPoint,
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 5, z: 0),
            rotationAngle: angle)
    }

    // MARK: - splitSegment

    func testSplitNoGapsReturnsWhole() {
        let start = Vector3(x: 0, y: 0, z: 0)
        let end = Vector3(x: 10, y: 0, z: 0)
        let pieces = DimensionPrimitives.splitSegment(start: start, end: end, gaps: [])
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].0.x, 0)
        XCTAssertEqual(pieces[0].1.x, 10)
    }

    func testSplitMiddleGap() {
        let start = Vector3(x: 0, y: 0, z: 0)
        let end = Vector3(x: 10, y: 0, z: 0)
        let pieces = DimensionPrimitives.splitSegment(
            start: start, end: end, gaps: [(0.4, 0.6)])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].0.x, 0, accuracy: 1e-9)
        XCTAssertEqual(pieces[0].1.x, 4, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].0.x, 6, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].1.x, 10, accuracy: 1e-9)
    }

    func testSplitClampsAndMerges() {
        let start = Vector3(x: 0, y: 0, z: 0)
        let end = Vector3(x: 10, y: 0, z: 0)
        // Overhanging, overlapping, reversed, and empty gaps collapse.
        let pieces = DimensionPrimitives.splitSegment(
            start: start, end: end,
            gaps: [(-0.5, 0.2), (0.15, 0.4), (0.6, 0.5), (0.7, 0.7)])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].0.x, 4, accuracy: 1e-9)
        XCTAssertEqual(pieces[0].1.x, 5, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].0.x, 6, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].1.x, 10, accuracy: 1e-9)
    }

    func testSplitFullCoverReturnsEmpty() {
        let start = Vector3(x: 0, y: 0, z: 0)
        let end = Vector3(x: 10, y: 0, z: 0)
        XCTAssertTrue(DimensionPrimitives.splitSegment(
            start: start, end: end, gaps: [(0, 1)]).isEmpty)
    }

    // MARK: - gaps grouping

    func testGapsFilterByLine() {
        let breaks = [
            DimBreak(line: .dimension, t0: 0.7, t1: 0.3),
            DimBreak(line: .firstExtension, t0: 0.1, t1: 0.2),
            DimBreak(line: .dimension, t0: 0.8, t1: 0.9),
        ]
        XCTAssertEqual(breaks[0].t0, 0.3)
        XCTAssertEqual(breaks[0].t1, 0.7)
        let dim = DimensionPrimitives.gaps(for: .dimension, in: breaks)
        XCTAssertEqual(dim.count, 2)
        let ext = DimensionPrimitives.gaps(for: .secondExtension, in: breaks)
        XCTAssertTrue(ext.isEmpty)
    }

    // MARK: - projectedGap

    func testProjectedGapOnSegment() {
        let gap = try! XCTUnwrap(DimBreakCommand.projectedGap(
            segStart: Vector3(x: 0, y: 5, z: 0),
            segEnd: Vector3(x: 10, y: 5, z: 0),
            pointA: Vector3(x: 4, y: 5, z: 0),
            pointB: Vector3(x: 6, y: 5, z: 0),
            margin: 1.25))
        XCTAssertEqual(gap.0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(gap.1, 0.6, accuracy: 1e-9)
    }

    func testProjectedGapMissesFarPoints() {
        XCTAssertNil(DimBreakCommand.projectedGap(
            segStart: Vector3(x: 0, y: 5, z: 0),
            segEnd: Vector3(x: 10, y: 5, z: 0),
            pointA: Vector3(x: 4, y: 9, z: 0),
            pointB: Vector3(x: 6, y: 9, z: 0),
            margin: 1.25))
        XCTAssertNil(DimBreakCommand.projectedGap(
            segStart: Vector3(x: 0, y: 0, z: 0),
            segEnd: Vector3(x: 0, y: 0, z: 0),
            pointA: Vector3(x: 0, y: 0, z: 0),
            pointB: Vector3(x: 1, y: 0, z: 0),
            margin: 1.25))
    }

    // MARK: - manualBreaks

    func testManualBreakHitsDimlineOnly() {
        let style = CADDimensionStyle.default
        let breaks = DimBreakCommand.manualBreaks(
            dimStart: Vector3(x: 0, y: 5, z: 0),
            dimEnd: Vector3(x: 10, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            pointA: Vector3(x: 4, y: 5, z: 0),
            pointB: Vector3(x: 6, y: 5, z: 0),
            style: style, obliqueAngle: nil)
        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].line, .dimension)
        XCTAssertEqual(breaks[0].t0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(breaks[0].t1, 0.6, accuracy: 1e-9)
    }

    func testManualBreakHitsOneExtension() {
        let style = CADDimensionStyle.default
        let breaks = DimBreakCommand.manualBreaks(
            dimStart: Vector3(x: 0, y: 5, z: 0),
            dimEnd: Vector3(x: 10, y: 5, z: 0),
            defPoint2: Vector3(x: 0, y: 0, z: 0),
            defPoint3: Vector3(x: 10, y: 0, z: 0),
            pointA: Vector3(x: 0, y: 1, z: 0),
            pointB: Vector3(x: 0, y: 4, z: 0),
            style: style, obliqueAngle: nil)
        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].line, .firstExtension)
        // Drawn ext line runs (0,0.625)->(0,6.25): fractions of that span.
        XCTAssertEqual(breaks[0].t0, (1 - 0.625) / 5.625, accuracy: 1e-9)
        XCTAssertEqual(breaks[0].t1, (4 - 0.625) / 5.625, accuracy: 1e-9)
    }

    // MARK: - widenedGap

    func testWidenedGapClamps() {
        let gap = try! XCTUnwrap(DimBreakCommand.widenedGap(param: 0.05, halfWidth: 0.1))
        XCTAssertEqual(gap.0, 0, accuracy: 1e-12)
        XCTAssertEqual(gap.1, 0.15, accuracy: 1e-12)
        XCTAssertNil(DimBreakCommand.widenedGap(param: 0.5, halfWidth: 0))
    }

    // MARK: - DIMSPACE

    func testIsParallelModuloPi() {
        XCTAssertTrue(DimSpaceCommand.isParallel(0, .pi))
        XCTAssertTrue(DimSpaceCommand.isParallel(0.1, 0.1 + 2 * .pi))
        XCTAssertFalse(DimSpaceCommand.isParallel(0, 0.5))
    }

    func testSpacedDefPointsEvenOut() {
        let base = linearMetadata(defPoint: Vector3(x: 0, y: 5, z: 0))
        let high = linearMetadata(defPoint: Vector3(x: 0, y: 9, z: 0))
        let higher = linearMetadata(defPoint: Vector3(x: 0, y: 14, z: 0))
        let spaced = try! XCTUnwrap(DimSpaceCommand.spacedDefPoints(
            base: base, others: [high, higher], spacing: 4))
        XCTAssertEqual(spaced[0].y, 9, accuracy: 1e-9)
        XCTAssertEqual(spaced[1].y, 13, accuracy: 1e-9)
    }

    func testSpacedDefPointsAlignAtZero() {
        let base = linearMetadata(defPoint: Vector3(x: 0, y: 5, z: 0))
        let high = linearMetadata(defPoint: Vector3(x: 0, y: 9, z: 0))
        let spaced = try! XCTUnwrap(DimSpaceCommand.spacedDefPoints(
            base: base, others: [high], spacing: 0))
        XCTAssertEqual(spaced[0].y, 5, accuracy: 1e-9)
    }

    func testSpacedDefPointsRejectsSkew() {
        let base = linearMetadata(angle: 0)
        let skew = linearMetadata(angle: 0.5)
        XCTAssertNil(DimSpaceCommand.spacedDefPoints(
            base: base, others: [skew], spacing: 4))
    }

    func testParseSpacing() {
        XCTAssertEqual(DimSpaceCommand.parseSpacing("4"), 4)
        XCTAssertEqual(DimSpaceCommand.parseSpacing("0"), 0)
        XCTAssertNil(DimSpaceCommand.parseSpacing("-1"))
        XCTAssertNil(DimSpaceCommand.parseSpacing("abc"))
        XCTAssertNil(DimSpaceCommand.parseSpacing(""))
    }
}

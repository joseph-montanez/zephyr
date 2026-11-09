import XCTest
@testable import ZephyrCore

/// Focused coverage for MEASUREGEOM Angle mode: the degree math, the arc
/// sweep direction the overlay draws, and the three-click pick flow
/// (exercised through the headless entry point, no SDL engine required).
@MainActor
final class MeasureAngleTests: XCTestCase {

    private var origin: Vector3 { Vector3(x: 0, y: 0, z: 0) }

    // MARK: - Angle math

    func testRightAngleIsNinetyDegrees() {
        XCTAssertEqual(
            MeasureGeomTool.angleDegrees(
                vertex: origin,
                first: Vector3(x: 1, y: 0, z: 0),
                second: Vector3(x: 0, y: 1, z: 0)),
            90.0, accuracy: 1e-9)
    }

    func testAcuteAngle() {
        XCTAssertEqual(
            MeasureGeomTool.angleDegrees(
                vertex: origin,
                first: Vector3(x: 1, y: 0, z: 0),
                second: Vector3(x: 1, y: 1, z: 0)),
            45.0, accuracy: 1e-9)
    }

    func testStraightAngleIs180Degrees() {
        XCTAssertEqual(
            MeasureGeomTool.angleDegrees(
                vertex: origin,
                first: Vector3(x: 1, y: 0, z: 0),
                second: Vector3(x: -1, y: 0, z: 0)),
            180.0, accuracy: 1e-9)
    }

    func testDegenerateLegMeasuresZero() {
        XCTAssertEqual(
            MeasureGeomTool.angleDegrees(
                vertex: origin,
                first: origin,
                second: Vector3(x: 0, y: 1, z: 0)),
            0.0, accuracy: 1e-9)
    }

    // MARK: - Span direction

    func testCounterclockwiseSweepIsPositive() {
        let span = MeasureGeomTool.angleSpan(
            vertex: origin,
            first: Vector3(x: 1, y: 0, z: 0),
            second: Vector3(x: 0, y: 1, z: 0))
        XCTAssertEqual(span.startAngle, 0.0, accuracy: 1e-9)
        XCTAssertEqual(span.sweepAngle, Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(span.angleDegrees, 90.0, accuracy: 1e-9)
    }

    func testClockwiseSweepIsNegative() {
        let span = MeasureGeomTool.angleSpan(
            vertex: origin,
            first: Vector3(x: 1, y: 0, z: 0),
            second: Vector3(x: 0, y: -1, z: 0))
        XCTAssertEqual(span.sweepAngle, -Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(span.angleDegrees, 90.0, accuracy: 1e-9)
    }

    // MARK: - Three-click state machine

    func testThreeClickMeasurementRecordsNinetyDegrees() {
        let tool = MeasureGeomTool()
        let processor = CADCommandProcessor()

        XCTAssertEqual(
            tool.handleAnglePick(worldX: 0, worldY: 0, snapped: nil, processor: processor),
            .continue)
        XCTAssertEqual(processor.commandPrompt, "Angle - pick first angle endpoint")

        // A zero-length first leg is rejected without advancing the flow.
        XCTAssertEqual(
            tool.handleAnglePick(worldX: 0, worldY: 0, snapped: nil, processor: processor),
            .continue)
        XCTAssertEqual(
            processor.commandPrompt,
            "First endpoint matches the vertex - pick a different point")

        XCTAssertEqual(
            tool.handleAnglePick(worldX: 4, worldY: 0, snapped: nil, processor: processor),
            .continue)
        XCTAssertEqual(processor.commandPrompt, "Angle - pick second angle endpoint")

        XCTAssertEqual(
            tool.handleAnglePick(worldX: 0, worldY: 3, snapped: nil, processor: processor),
            .continue)
        XCTAssertEqual(
            processor.commandPrompt,
            "Angle 90\u{00B0} recorded - pick vertex for next (Esc to exit)")
        XCTAssertEqual(tool.angleSpan?.angleDegrees ?? -1, 90.0, accuracy: 1e-9)
    }

    func testSnapPointWinsOverRawCursor() {
        let tool = MeasureGeomTool()
        let processor = CADCommandProcessor()

        _ = tool.handleAnglePick(
            worldX: 999, worldY: 999,
            snapped: Vector3(x: 1, y: 1, z: 0), processor: processor)
        _ = tool.handleAnglePick(
            worldX: 999, worldY: 999,
            snapped: Vector3(x: 2, y: 1, z: 0), processor: processor)
        _ = tool.handleAnglePick(
            worldX: 999, worldY: 999,
            snapped: Vector3(x: 1, y: 2, z: 0), processor: processor)

        XCTAssertEqual(tool.angleSpan?.vertex.x ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tool.angleSpan?.vertex.y ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tool.angleSpan?.angleDegrees ?? -1, 90.0, accuracy: 1e-9)
    }

    // MARK: - Chips

    func testAngleChipIsFoundByKeyword() {
        XCTAssertEqual(
            MeasureGeomTool().commandTextOptions(for: "an").map(\.value),
            ["Angle"])
    }
}

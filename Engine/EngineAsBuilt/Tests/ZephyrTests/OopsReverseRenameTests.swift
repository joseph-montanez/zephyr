import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.2g OOPS + REVERSE + RENAME: erase-restore buffer, direction
/// reversal (with double-reverse involution), and per-type renames with
/// validation, reference rewrites, and single-undo behavior.
@MainActor
final class OopsReverseRenameTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func lineEntity(_ document: CADDocument, x: Double) -> CADEntity {
        CADEntity(
            layerID: zeroID(document),
            localGeometry: [.line(
                start: Vector3(x: x, y: 0, z: 0),
                end: Vector3(x: x + 5, y: 0, z: 0), color: nil)],
            transform: .identity)
    }

    private func seedLines(_ document: CADDocument, count: Int) -> [UUID] {
        (0..<count).map { i in
            let entity = lineEntity(document, x: Double(i) * 10)
            let handle = entity.handle
            document.addEntity(entity)
            return handle
        }
    }

    // MARK: - OOPS

    func testOopsRestoresErasedSet() {
        let document = makeDocument()
        let handles = seedLines(document, count: 3)
        document.removeEntities(handles: Set(handles.prefix(2)))
        XCTAssertNil(document.entity(for: handles[0]))
        let depth = document.undoManager.undoDepth
        XCTAssertEqual(document.oopsRestore(), 2)
        XCTAssertEqual(document.undoManager.undoDepth, depth + 1)
        XCTAssertNotNil(document.entity(for: handles[0]))
        XCTAssertNotNil(document.entity(for: handles[1]))
        // Buffer is consumed: a second OOPS restores nothing, no undo.
        XCTAssertEqual(document.oopsRestore(), 0)
        XCTAssertEqual(document.undoManager.undoDepth, depth + 1)
    }

    func testOopsEmptyBufferPushesNoUndo() {
        let document = makeDocument()
        _ = seedLines(document, count: 1)
        let depth = document.undoManager.undoDepth
        XCTAssertEqual(document.oopsRestore(), 0)
        XCTAssertEqual(document.undoManager.undoDepth, depth)
    }

    func testOopsKeepsLastEraseOnly() {
        let document = makeDocument()
        let handles = seedLines(document, count: 2)
        document.removeEntity(handle: handles[0])
        document.removeEntity(handle: handles[1])
        XCTAssertEqual(document.oopsRestore(), 1)
        XCTAssertNotNil(document.entity(for: handles[1]))
        XCTAssertNil(document.entity(for: handles[0]))
    }

    func testOopsMissDoesNotClearBuffer() {
        let document = makeDocument()
        let handles = seedLines(document, count: 1)
        document.removeEntity(handle: handles[0])
        document.removeEntity(handle: UUID())
        XCTAssertEqual(document.oopsRestore(), 1)
    }

    // MARK: - REVERSE primitives

    func testReverseLine() {
        let start = Vector3(x: 0, y: 0, z: 0)
        let end = Vector3(x: 5, y: 5, z: 0)
        guard case .line(let s, let e, _) = ReverseCommand.reversed(
            .line(start: start, end: end, color: nil)) else {
            return XCTFail("line should reverse")
        }
        XCTAssertEqual(s, end)
        XCTAssertEqual(e, start)
    }

    func testReverseOpenPolylineInvolution() {
        let path = CADPolyline(
            vertices: [
                CADPolylineVertex(
                    position: Vector3(x: 0, y: 0, z: 0),
                    bulge: 0.5, startWidth: 1, endWidth: 2),
                CADPolylineVertex(
                    position: Vector3(x: 5, y: 0, z: 0),
                    bulge: -0.25, startWidth: 2, endWidth: 3),
                CADPolylineVertex(
                    position: Vector3(x: 10, y: 5, z: 0),
                    bulge: 0, startWidth: 0, endWidth: 0),
            ],
            isClosed: false)
        let once = ReverseCommand.reversed(path)
        XCTAssertEqual(once.points, path.points.reversed())
        // First segment of the reversed path is the old last segment
        // flipped: bulge negated, widths swapped.
        XCTAssertEqual(once.vertices[0].bulge, 0.25, accuracy: 1e-12)
        XCTAssertEqual(once.vertices[0].startWidth, 3)
        XCTAssertEqual(once.vertices[0].endWidth, 2)
        let twice = ReverseCommand.reversed(once)
        XCTAssertEqual(twice.points, path.points)
        for (a, b) in zip(twice.vertices, path.vertices) {
            XCTAssertEqual(a.bulge, b.bulge, accuracy: 1e-12)
            XCTAssertEqual(a.startWidth, b.startWidth)
            XCTAssertEqual(a.endWidth, b.endWidth)
        }
    }

    func testReverseClosedPolylineInvolution() {
        let path = CADPolyline(
            vertices: [
                CADPolylineVertex(
                    position: Vector3(x: 0, y: 0, z: 0),
                    bulge: 0.5, startWidth: 1, endWidth: 1),
                CADPolylineVertex(
                    position: Vector3(x: 5, y: 0, z: 0),
                    bulge: 0, startWidth: 1, endWidth: 1),
                CADPolylineVertex(
                    position: Vector3(x: 5, y: 5, z: 0),
                    bulge: 0.25, startWidth: 2, endWidth: 2),
            ],
            isClosed: true)
        let once = ReverseCommand.reversed(path)
        XCTAssertTrue(once.isClosed)
        XCTAssertEqual(once.points.first, path.points.first)
        XCTAssertEqual(
            Array(once.points.dropFirst()), Array(path.points.dropFirst().reversed()))
        let twice = ReverseCommand.reversed(once)
        XCTAssertEqual(twice.points, path.points)
        for (a, b) in zip(twice.vertices, path.vertices) {
            XCTAssertEqual(a.bulge, b.bulge, accuracy: 1e-12)
            XCTAssertEqual(a.startWidth, b.startWidth)
            XCTAssertEqual(a.endWidth, b.endWidth)
        }
    }

    func testReverseSpline() {
        let points = [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 3, y: 4, z: 0),
            Vector3(x: 6, y: 0, z: 0), Vector3(x: 9, y: 4, z: 0),
        ]
        guard case .spline(let pts, let knots, _, let weights, _) =
                ReverseCommand.reversed(.spline(
                    controlPoints: points, knots: [0, 0, 0, 1, 1, 1],
                    degree: 2, weights: [1, 2, 3, 4], color: nil)) else {
            return XCTFail("spline should reverse")
        }
        XCTAssertEqual(pts, points.reversed())
        XCTAssertEqual(weights, [4, 3, 2, 1])
        XCTAssertEqual(knots, [0, 0, 0, 1, 1, 1])
        XCTAssertTrue(zip(knots, knots.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }

    func testReverseSkipsOtherPrimitives() {
        XCTAssertNil(ReverseCommand.reversed(
            .circle(center: Vector3(x: 0, y: 0, z: 0), radius: 1, color: nil)))
        XCTAssertNil(ReverseCommand.reversed(
            .text(position: Vector3(x: 0, y: 0, z: 0), text: "t", height: 1,
                  rotation: 0, style: nil, alignH: 0, alignV: 0,
                  mtextWidth: nil, color: nil)))
    }

    // MARK: - RENAME

    func testRenameLayer() {
        let document = makeDocument()
        document.addLayer(Layer(name: "Walls"))
        let depth = document.undoManager.undoDepth
        XCTAssertNil(document.rename(kind: .layer, from: "walls", to: "Partitions"))
        XCTAssertEqual(document.undoManager.undoDepth, depth + 1)
        XCTAssertNotNil(document.findLayer(named: "Partitions"))
        XCTAssertNil(document.findLayer(named: "Walls"))
        XCTAssertEqual(
            document.rename(kind: .layer, from: "0", to: "Zero"),
            "Layer '0' cannot be renamed.")
    }

    func testRenameBlock() {
        let document = makeDocument()
        document.addBlock(CADBlock(
            handle: UUID(), name: "Chair",
            geometry: [], primitiveStyles: [:], primitiveXData: [:], dxfFlags: 0))
        XCTAssertNil(document.rename(kind: .block, from: "CHAIR", to: "Seat"))
        XCTAssertTrue(document.allBlocks.contains { $0.name == "Seat" })
        document.addBlock(CADBlock(
            handle: UUID(), name: "*D1",
            geometry: [], primitiveStyles: [:], primitiveXData: [:], dxfFlags: 0))
        XCTAssertNotNil(document.rename(kind: .block, from: "*D1", to: "Dyn"))
    }

    func testRenameTextStyleRewritesReferences() throws {
        let document = makeDocument()
        document.textStyles["Notes"] = CADTextStyle(name: "Notes")
        var entity = CADEntity(
            layerID: zeroID(document),
            localGeometry: [.text(
                position: Vector3(x: 0, y: 0, z: 0), text: "t", height: 1,
                rotation: 0, style: "Notes", alignH: 0, alignV: 0,
                mtextWidth: nil, color: nil)],
            transform: .identity)
        entity.xdata["dxf.textStyle"] = .string("Notes")
        let handle = entity.handle
        document.addEntity(entity)
        XCTAssertNil(document.rename(kind: .textStyle, from: "Notes", to: "Remarks"))
        XCTAssertNil(document.textStyles["Notes"])
        XCTAssertNotNil(document.textStyles["Remarks"])
        let stored = try XCTUnwrap(document.entity(for: handle))
        guard case .text(_, _, _, _, let style, _, _, _, _) =
                try XCTUnwrap(stored.localGeometry).first else {
            return XCTFail("expected a text primitive")
        }
        XCTAssertEqual(style, "Remarks")
        XCTAssertEqual(stored.xdata["dxf.textStyle"], .string("Remarks"))
        XCTAssertNotNil(document.rename(kind: .textStyle, from: "Standard", to: "Std"))
    }

    func testRenameDimStyleRepointsMetadata() throws {
        let document = makeDocument()
        var arch = CADDimensionStyle.default
        arch.name = "Arch"
        XCTAssertTrue(document.applyDimensionStyle(arch))
        var entity = CADEntity(
            layerID: zeroID(document), localGeometry: nil, transform: .identity)
        entity.dimensionMetadata = CADDimensionMetadataBox(CADDimensionMetadata(
            styleName: "Arch", type: .linearOrRotated, measurement: 10,
            defPoint: Vector3(x: 0, y: 0, z: 0),
            defPoint2: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 2, z: 0)))
        let handle = entity.handle
        document.addEntity(entity)
        XCTAssertNil(document.rename(kind: .dimstyle, from: "arch", to: "Architectural"))
        XCTAssertNil(document.dimensionStyles["Arch"])
        XCTAssertNotNil(document.dimensionStyles["Architectural"])
        let stored = try XCTUnwrap(document.entity(for: handle))
        XCTAssertEqual(
            stored.dimensionMetadata?.value.styleName, "Architectural")
    }

    func testRenameLeaderAndLinetype() throws {
        let document = makeDocument()
        document.leaderStyles["Callout"] = CADLeaderStyle.standard
        var entity = CADEntity(
            layerID: zeroID(document), localGeometry: nil, transform: .identity)
        entity.leaderData = CADLeaderDataBox(CADLeaderData(
            styleName: "Callout",
            branches: [CADLeaderBranch(vertices: [
                Vector3(x: 0, y: 0, z: 0), Vector3(x: 5, y: 5, z: 0)])],
            contentPosition: Vector3(x: 5, y: 5, z: 0)))
        let leaderHandle = entity.handle
        document.addEntity(entity)
        XCTAssertNil(document.rename(
            kind: .leaderStyle, from: "callout", to: "Tag"))
        XCTAssertNil(document.leaderStyles["Callout"])
        XCTAssertNotNil(document.leaderStyles["Tag"])
        let storedLeader = try XCTUnwrap(document.entity(for: leaderHandle))
        XCTAssertEqual(storedLeader.leaderData?.value.styleName, "Tag")

        document.linetypePatterns["DASHED"] = [1.0, -0.5]
        var lineEntity = lineEntity(document, x: 0)
        lineEntity.xdata["dxf.lineType"] = .string("dashed")
        let lineHandle = lineEntity.handle
        document.addEntity(lineEntity)
        var layer = try XCTUnwrap(document.findLayer(named: "0"))
        layer.lineType = "DASHED"
        document.addLayer(layer)
        XCTAssertNil(document.rename(
            kind: .linetype, from: "dashed", to: "Hidden2"))
        XCTAssertNil(document.linetypePatterns["DASHED"])
        XCTAssertEqual(document.linetypePatterns["Hidden2"], [1.0, -0.5])
        let storedLine = try XCTUnwrap(document.entity(for: lineHandle))
        XCTAssertEqual(storedLine.xdata["dxf.lineType"], .string("Hidden2"))
        XCTAssertEqual(
            try XCTUnwrap(document.findLayer(named: "0")).lineType, "Hidden2")
        XCTAssertNotNil(document.rename(
            kind: .linetype, from: "CONTINUOUS", to: "Solid"))
    }

    func testRenameValidation() {
        let document = makeDocument()
        document.addLayer(Layer(name: "Walls"))
        XCTAssertEqual(
            document.rename(kind: .layer, from: "Nope", to: "X"),
            "Layer 'Nope' not found.")
        XCTAssertEqual(
            document.rename(kind: .layer, from: "Walls", to: "Walls"),
            "Old and new names are the same.")
        XCTAssertEqual(
            document.rename(kind: .layer, from: "Walls", to: "A/B"),
            "Name contains illegal characters (\\ / : ; \" ? * | = ` < >).")
        XCTAssertEqual(
            document.rename(kind: .layer, from: "Walls", to: "0"),
            "A layer named '0' already exists.")
        XCTAssertEqual(CADRename.Kind.match("text style"), .textStyle)
        XCTAssertEqual(CADRename.Kind.match("LAYER"), .layer)
        XCTAssertNil(CADRename.Kind.match("Nope"))
    }
}

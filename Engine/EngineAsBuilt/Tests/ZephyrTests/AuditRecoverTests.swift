import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.2d AUDIT/RECOVER: validation coverage per issue kind, safe fixes,
/// the single-undo batch, and the DXFReader diagnostics RECOVER routes
/// through (version, pair/entity counts, unknown-type count).
@MainActor
final class AuditRecoverTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func textEntity(
        layerID: UUID, style: String?, position: Vector3 = Vector3(x: 0, y: 0, z: 0)
    ) -> CADEntity {
        CADEntity(
            layerID: layerID,
            localGeometry: [.text(
                position: position, text: "hi", height: 2.5,
                rotation: 0, style: style, alignH: 0, alignV: 0,
                mtextWidth: nil, color: nil)],
            transform: .identity)
    }

    // MARK: - clean drawing

    func testCleanDocumentHasNoErrors() {
        let document = makeDocument()
        document.addEntity(textEntity(layerID: zeroID(document), style: "Standard"))
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.errorCount, 0, "clean drawing: \(report.breakdown)")
    }

    // MARK: - missing layer

    func testMissingLayerMovesToZero() {
        let document = makeDocument()
        let seeded = textEntity(layerID: UUID(), style: "Standard")
        let handle = seeded.handle
        document.addEntity(seeded)
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.count(for: .missingLayer), 1)
        let fixed = AuditEngine.applyFixes(report: report, to: document)
        XCTAssertEqual(fixed, 1)
        XCTAssertEqual(try! XCTUnwrap(document.entity(for: handle)).layerID,
                       zeroID(document))
        XCTAssertEqual(AuditEngine.validate(document: document).errorCount, 0)
    }

    // MARK: - dangling block

    func testDanglingBlockRemovesEntity() {
        let document = makeDocument()
        let seeded = CADEntity(
            layerID: zeroID(document), blockID: UUID(),
            localGeometry: nil, transform: .identity)
        let handle = seeded.handle
        document.addEntity(seeded)
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.count(for: .danglingBlock), 1)
        XCTAssertEqual(report.errorCount, 1)
        let fixed = AuditEngine.applyFixes(report: report, to: document)
        XCTAssertEqual(fixed, 1)
        XCTAssertNil(document.entity(for: handle))
    }

    // MARK: - missing dimension style

    func testMissingDimStyleRewritesToStandard() {
        let document = makeDocument()
        let metadata = CADDimensionMetadata(
            styleName: "Ghost", type: .linearOrRotated, measurement: 10,
            defPoint: Vector3(x: 0, y: 0, z: 0),
            defPoint2: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 2, z: 0))
        var entity = CADEntity(
            layerID: zeroID(document), localGeometry: nil, transform: .identity)
        entity.dimensionMetadata = CADDimensionMetadataBox(metadata)
        let handle = entity.handle
        document.addEntity(entity)
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.count(for: .missingDimStyle), 1)
        let fixed = AuditEngine.applyFixes(report: report, to: document)
        XCTAssertEqual(fixed, 1)
        let stored = try! XCTUnwrap(document.entity(for: handle))
        XCTAssertEqual(stored.dimensionMetadata?.value.styleName, "Standard")
        XCTAssertEqual(AuditEngine.validate(document: document).errorCount, 0)
    }

    // MARK: - missing leader style

    func testMissingLeaderStyleRewritesToStandard() {
        let document = makeDocument()
        let branch = CADLeaderBranch(vertices: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 5, y: 5, z: 0)])
        let data = CADLeaderData(
            styleName: "Ghost", branches: [branch],
            contentPosition: Vector3(x: 5, y: 5, z: 0))
        var entity = CADEntity(
            layerID: zeroID(document), localGeometry: nil, transform: .identity)
        entity.leaderData = CADLeaderDataBox(data)
        let handle = entity.handle
        document.addEntity(entity)
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.count(for: .missingLeaderStyle), 1)
        let fixed = AuditEngine.applyFixes(report: report, to: document)
        XCTAssertEqual(fixed, 1)
        let stored = try! XCTUnwrap(document.entity(for: handle))
        XCTAssertEqual(stored.leaderData?.value.styleName, "Standard")
    }

    // MARK: - missing text style

    func testMissingTextStyleRewritesToStandard() {
        let document = makeDocument()
        let seeded = textEntity(layerID: zeroID(document), style: "Ghost")
        let handle = seeded.handle
        document.addEntity(seeded)
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.count(for: .missingTextStyle), 1)
        let fixed = AuditEngine.applyFixes(report: report, to: document)
        XCTAssertEqual(fixed, 1)
        let stored = try! XCTUnwrap(document.entity(for: handle))
        guard case .text(_, _, _, _, let style, _, _, _, _) =
                try! XCTUnwrap(stored.localGeometry).first else {
            return XCTFail("expected a text primitive")
        }
        XCTAssertEqual(style, "Standard")
    }

    func testNilTextStyleIsNotAnError() {
        let document = makeDocument()
        document.addEntity(textEntity(layerID: zeroID(document), style: nil))
        XCTAssertEqual(AuditEngine.validate(document: document).errorCount, 0)
    }

    // MARK: - empty and non-finite geometry

    func testEmptyGeometryRemovesEntity() {
        let document = makeDocument()
        let seeded = CADEntity(
            layerID: zeroID(document), localGeometry: [], transform: .identity)
        let handle = seeded.handle
        document.addEntity(seeded)
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.count(for: .emptyGeometry), 1)
        XCTAssertEqual(AuditEngine.applyFixes(report: report, to: document), 1)
        XCTAssertNil(document.entity(for: handle))
    }

    func testNonFiniteGeometryRemovesEntity() {
        let document = makeDocument()
        let seeded = textEntity(
            layerID: zeroID(document), style: "Standard",
            position: Vector3(x: .nan, y: 0, z: 0))
        let handle = seeded.handle
        document.addEntity(seeded)
        let report = AuditEngine.validate(document: document)
        XCTAssertEqual(report.count(for: .nonFiniteGeometry), 1)
        XCTAssertEqual(AuditEngine.applyFixes(report: report, to: document), 1)
        XCTAssertNil(document.entity(for: handle))
    }

    // MARK: - single undo

    func testFixesPushExactlyOneUndo() {
        let document = makeDocument()
        document.addEntity(textEntity(layerID: UUID(), style: "Ghost"))
        document.addEntity(CADEntity(
            layerID: zeroID(document), localGeometry: [], transform: .identity))
        let report = AuditEngine.validate(document: document)
        // Missing layer + missing text style on one entity, empty geometry
        // on the other.
        XCTAssertEqual(report.errorCount, 3)
        let depth = document.undoManager.undoDepth
        XCTAssertEqual(AuditEngine.applyFixes(report: report, to: document), 2)
        XCTAssertEqual(document.undoManager.undoDepth, depth + 1)
        XCTAssertEqual(AuditEngine.validate(document: document).errorCount, 0)
    }

    // MARK: - reader diagnostics (RECOVER path)

    func testReaderDiagnosticsCountUnknownTypes() throws {
        let dxf = """
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        8
        0
        10
        0.0
        20
        0.0
        11
        10.0
        21
        0.0
        0
        WIPEOUT
        8
        0
        0
        ENDSEC
        0
        EOF
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-diag-\(UUID().uuidString).dxf")
        try dxf.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DXFReader().readFile(at: url.path)
        XCTAssertGreaterThan(reader.pairCount, 0)
        XCTAssertEqual(reader.entities.count, 2)
        XCTAssertEqual(
            reader.entities.filter { $0.eType == .uNKNOWN }.count, 1)
    }
}

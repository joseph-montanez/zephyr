import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.3c block attributes: ATTDEF definitions, per-insert ATTRIB
/// values, ATTSYNC re-application, DXF ATTDEF/ATTRIB/SEQEND round-trip,
/// EAB v22 persistence, and FIND coverage of attribute values.
@MainActor
final class AttributeTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func titleBlock() -> CADBlock {
        CADBlock(
            name: "TAGBLK",
            geometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 10, y: 0, z: 0), color: nil)],
            attributeDefinitions: [
                CADAttributeDefinition(
                    tag: "TITLE", prompt: "Enter title:",
                    defaultValue: "DefaultTitle",
                    position: Vector3(x: 5, y: 2, z: 0),
                    height: 2.5),
                CADAttributeDefinition(
                    tag: "HIDDEN", prompt: "Hidden:",
                    defaultValue: "shh",
                    position: Vector3(x: 5, y: 4, z: 0),
                    height: 2.5, flags: 1),
            ])
    }

    // MARK: - Sync engine

    func testSyncAddsMissingDropsOrphanedPreservesEdits() {
        let defs = titleBlock().attributeDefinitions
        let result = CADAttributeSync.apply(
            definitions: defs,
            to: [
                "TITLE": CADAttributeValue(
                    value: "Edited",
                    position: Vector3(x: 9, y: 9, z: 0)),
                "GONE": CADAttributeValue(value: "orphan"),
            ])
        // Edited value survives, placement override resets to the definition.
        XCTAssertEqual(result["TITLE"]?.value, "Edited")
        XCTAssertNil(result["TITLE"]?.position)
        // Missing tag gains the default (invisible defs sync too).
        XCTAssertEqual(result["HIDDEN"]?.value, "shh")
        // Orphaned tag drops.
        XCTAssertNil(result["GONE"])
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Display synthesis

    func testDisplayResolveShowsValuesSkipsInvisibleAndEmpty() {
        let defs = titleBlock().attributeDefinitions
        let rows = CADAttributeDisplay.resolve(
            definitions: defs,
            values: ["TITLE": CADAttributeValue(value: "AsBuilt")])
        // Invisible HIDDEN never renders; TITLE shows the stored value.
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, "AsBuilt")
        XCTAssertEqual(rows[0].position.x, 5, accuracy: 1e-9)
        XCTAssertEqual(rows[0].position.y, 2, accuracy: 1e-9)
    }

    func testDisplayResolveShowsDefaultsAndOrphans() {
        let defs = titleBlock().attributeDefinitions
        let rows = CADAttributeDisplay.resolve(
            definitions: defs,
            values: [
                "EXTRA": CADAttributeValue(
                    value: "orphan",
                    position: Vector3(x: 1, y: 1, z: 0)),
            ])
        // TITLE falls back to its default; orphan EXTRA renders placed.
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].text, "DefaultTitle")
        XCTAssertEqual(rows[1].text, "orphan")
        XCTAssertEqual(rows[1].position.x, 1, accuracy: 1e-9)
    }

    func testConstantDefinitionAlwaysShowsDefault() {
        let defs = [
            CADAttributeDefinition(
                tag: "REV", defaultValue: "C",
                position: Vector3(x: 1, y: 1, z: 0),
                height: 2.5, flags: 2),
        ]
        let rows = CADAttributeDisplay.resolve(
            definitions: defs,
            values: ["REV": CADAttributeValue(value: "tampered")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, "C")
    }

    // MARK: - Document helpers

    func testAddDefinitionRejectsDuplicatesAndSyncsOnce() throws {
        let document = makeDocument()
        let block = titleBlock()
        document.addBlock(block)
        // Duplicate tag rejected (case-insensitive).
        XCTAssertFalse(document.addAttributeDefinition(
            CADAttributeDefinition(tag: "title"), to: block.handle))
        // New tag accepted.
        XCTAssertTrue(document.addAttributeDefinition(
            CADAttributeDefinition(tag: "SCALE", defaultValue: "1:50"),
            to: block.handle))
        XCTAssertEqual(
            document.block(for: block.handle)?.attributeDefinitions.count, 3)

        var insert = CADEntity(
            layerID: zeroID(document), blockID: block.handle,
            transform: .identity)
        insert.attributeValues = ["TITLE": CADAttributeValue(value: "Kept")]
        document.addEntity(insert)

        let depth = document.undoManager.undoDepth
        XCTAssertEqual(document.syncAttributesForBlock(block.handle), 1)
        // One undo entry for the whole sync.
        XCTAssertEqual(document.undoManager.undoDepth, depth + 1)

        let synced = try XCTUnwrap(document.entity(for: insert.handle))
        XCTAssertEqual(synced.attributeValues["TITLE"]?.value, "Kept")
        XCTAssertEqual(synced.attributeValues["SCALE"]?.value, "1:50")
        XCTAssertEqual(synced.attributeValues["HIDDEN"]?.value, "shh")
    }

    // MARK: - DXF import

    private var attributeDXF: String {
        """
        0
        SECTION
          2
        BLOCKS
          0
        BLOCK
          8
        0
          2
        TAGBLK
         70
        0
         10
        0.0
         20
        0.0
         30
        0.0
          0
        ATTDEF
          8
        0
         10
        5.0
         20
        -2.0
         30
        0.0
         40
        2.5
          1
        DefaultTitle
         50
        0.0
          7
        STANDARD
          2
        TITLE
          3
        Enter title:
         70
        0
          0
        ENDBLK
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        INSERT
          8
        0
          2
        TAGBLK
         10
        100.0
         20
        -50.0
         30
        0.0
         66
        1
          0
        ATTRIB
          8
        0
         10
        105.0
         20
        -52.0
         30
        0.0
         40
        2.5
          1
        AsBuilt
         50
        0.0
          7
        STANDARD
          2
        TITLE
         70
        0
          0
        SEQEND
          0
        ENDSEC
          0
        EOF
        """
    }

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("attr_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    func testDXFImportExtractsDefinitionsAndValues() throws {
        let doc = try importDXFString(attributeDXF)
        let block = try XCTUnwrap(doc.allBlocks.first(where: { $0.name == "TAGBLK" }))
        XCTAssertEqual(block.attributeDefinitions.count, 1)
        let def = try XCTUnwrap(block.attributeDefinitions.first)
        XCTAssertEqual(def.tag, "TITLE")
        XCTAssertEqual(def.prompt, "Enter title:")
        XCTAssertEqual(def.defaultValue, "DefaultTitle")
        XCTAssertEqual(def.position.x, 5, accuracy: 1e-6)
        XCTAssertEqual(def.position.y, 2, accuracy: 1e-6)
        XCTAssertEqual(def.height, 2.5, accuracy: 1e-9)

        // One INSERT; the ATTRIB lives on it, not as standalone text.
        XCTAssertEqual(doc.allEntities.count, 1)
        let insert = try XCTUnwrap(doc.allEntities.first)
        XCTAssertNotNil(insert.blockID)
        XCTAssertEqual(insert.attributeValues["TITLE"]?.value, "AsBuilt")
        // Unmoved ATTRIB stays override-free (ATTSYNC-clean).
        XCTAssertNil(insert.attributeValues["TITLE"]?.position)
    }

    // MARK: - DXF round-trip

    func testDXFExportReimportRoundTrip() throws {
        let document = makeDocument()
        let block = titleBlock()
        document.addBlock(block)
        var insert = CADEntity(
            layerID: zeroID(document), blockID: block.handle,
            transform: .translated(by: Vector3(x: 100, y: 50, z: 0)))
        insert.attributeValues = [
            "TITLE": CADAttributeValue(value: "AsBuilt"),
            // Moved off the definition: the override must survive.
            "HIDDEN": CADAttributeValue(
                value: "moved", position: Vector3(x: 7, y: 3, z: 0)),
        ]
        document.addEntity(insert)

        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("attr_rt_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        try DXFExporter.export(document: document, to: tmpFile)
        let text = try String(contentsOf: tmpFile, encoding: .utf8)
        XCTAssertTrue(text.contains("ATTDEF"))
        XCTAssertTrue(text.contains("ATTRIB"))
        XCTAssertTrue(text.contains("SEQEND"))

        let reopened = CADDocument()
        try reopened.importDXF(url: tmpFile)
        let reopenedBlock = try XCTUnwrap(
            reopened.allBlocks.first(where: { $0.name == "TAGBLK" }))
        XCTAssertEqual(reopenedBlock.attributeDefinitions.count, 2)
        XCTAssertEqual(
            reopenedBlock.attributeDefinitions.first(where: { $0.key == "TITLE" })?.prompt,
            "Enter title:")
        let reopenedInsert = try XCTUnwrap(reopened.allEntities.first)
        XCTAssertEqual(
            reopenedInsert.attributeValues["TITLE"]?.value, "AsBuilt")
        XCTAssertEqual(
            reopenedInsert.attributeValues["HIDDEN"]?.value, "moved")
        let movedPos = try XCTUnwrap(
            reopenedInsert.attributeValues["HIDDEN"]?.position)
        XCTAssertEqual(movedPos.x, 7, accuracy: 1e-4)
        XCTAssertEqual(movedPos.y, 3, accuracy: 1e-4)
    }

    // MARK: - EAB round-trip

    func testEABRoundTripPreservesAttributes() throws {
        let document = makeDocument()
        let block = titleBlock()
        document.addBlock(block)
        var insert = CADEntity(
            layerID: zeroID(document), blockID: block.handle,
            transform: .identity)
        insert.attributeValues = ["TITLE": CADAttributeValue(value: "EABTest")]
        document.addEntity(insert)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("attr_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try EABWriter.write(document: document, to: tempURL)
        let views = try EABReader.readViews(from: tempURL)
        let readDoc = try XCTUnwrap(views.first).document

        let readBlock = try XCTUnwrap(
            readDoc.allBlocks.first(where: { $0.name == "TAGBLK" }))
        XCTAssertEqual(readBlock.attributeDefinitions.count, 2)
        XCTAssertEqual(readBlock.attributeDefinitions[0].tag, "TITLE")
        XCTAssertTrue(readBlock.attributeDefinitions[1].isInvisible)
        let readInsert = try XCTUnwrap(readDoc.allEntities.first)
        XCTAssertEqual(
            readInsert.attributeValues["TITLE"]?.value, "EABTest")
    }

    // MARK: - FIND

    func testFindMatchesAttributeValues() {
        let entity = CADEntity(
            layerID: UUID(), blockID: UUID(),
            attributeValues: [
                "TITLE": CADAttributeValue(value: "Pump P-101"),
                "NOTE": CADAttributeValue(value: "unrelated"),
            ])
        let tags = FindCommand.matchingAttributeTags(
            in: entity, find: "p-101", options: FindCommand.Options())
        XCTAssertEqual(tags, ["TITLE"])
    }
}

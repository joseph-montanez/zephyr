import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.1 DIMSTYLE: named dimension-style table on CADDocument,
/// undoable current-style selection, the LT sysvar subset bound to the
/// current row, raw-value DXF import, and multi-style DXF/EAB round trips.
/// (-DIMSTYLE dispatch itself is thin glue over these helpers, like -LAYER.)
@MainActor
final class DimStyleTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        document.activeLayerID = document.findLayer(named: "0")?.handle
        return document
    }

    private func makeDimensionEntity(
        layerID: UUID, styleName: String = "Standard"
    ) -> CADEntity {
        var entity = CADEntity(layerID: layerID)
        entity.dimensionMetadata = CADDimensionMetadataBox(CADDimensionMetadata(
            styleName: styleName,
            type: .linearOrRotated,
            measurement: 10,
            defPoint: Vector3(x: 0, y: 0, z: 0),
            defPoint2: Vector3(x: 10, y: 0, z: 0),
            textMidpoint: Vector3(x: 5, y: 2, z: 0)))
        return entity
    }

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimstyle_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    // MARK: - Table

    func testStandardStyleGuaranteedOnNewDocument() {
        let doc = makeDocument()
        XCTAssertNotNil(doc.dimensionStyles["Standard"])
        XCTAssertEqual(doc.currentDimensionStyleName, "Standard")
    }

    func testApplyRenameAndDeleteRewriteReferences() throws {
        let doc = makeDocument()
        let layerID = try XCTUnwrap(doc.activeLayerID)

        var arch = CADDimensionStyle.default
        arch.name = "Arch"
        arch.arrowSize = 3.5
        XCTAssertTrue(doc.applyDimensionStyle(arch))
        XCTAssertEqual(doc.dimensionStyle(named: "arch").arrowSize, 3.5)
        doc.addEntities([makeDimensionEntity(layerID: layerID, styleName: "Arch")])

        // Rename re-points the entity.
        arch.name = "ArchRenamed"
        XCTAssertTrue(doc.applyDimensionStyle(arch, replacing: "Arch"))
        XCTAssertNil(doc.dimensionStyles["Arch"])
        let renamed = doc.allEntities.compactMap {
            $0.dimensionMetadata?.value.styleName
        }
        XCTAssertEqual(renamed, ["ArchRenamed"])

        // Delete re-points at Standard and protects Standard itself.
        XCTAssertTrue(doc.deleteDimensionStyle(named: "ArchRenamed"))
        XCTAssertNil(doc.dimensionStyles["ArchRenamed"])
        let afterDelete = doc.allEntities.compactMap {
            $0.dimensionMetadata?.value.styleName
        }
        XCTAssertEqual(afterDelete, ["Standard"])
        XCTAssertFalse(doc.deleteDimensionStyle(named: "Standard"))
        XCTAssertFalse(doc.deleteDimensionStyle(named: "Missing"))
        var blank = CADDimensionStyle.default
        blank.name = "   "
        XCTAssertFalse(doc.applyDimensionStyle(blank))
    }

    func testSetCurrentStyleIsUndoable() {
        let doc = makeDocument()
        var arch = CADDimensionStyle.default
        arch.name = "Arch"
        XCTAssertTrue(doc.applyDimensionStyle(arch))

        XCTAssertTrue(doc.setCurrentDimensionStyle(named: "arch"))
        XCTAssertEqual(doc.currentDimensionStyleName, "Arch")
        XCTAssertFalse(doc.setCurrentDimensionStyle(named: "Missing"))
        // Effective style resolves through the selection.
        XCTAssertEqual(doc.currentDimensionStyle().arrowSize, 2.5)

        doc.undo()
        XCTAssertEqual(doc.currentDimensionStyleName, "Standard")
    }

    func testApplyStyleToSelectedEntities() throws {
        let doc = makeDocument()
        let layerID = try XCTUnwrap(doc.activeLayerID)
        let a = makeDimensionEntity(layerID: layerID)
        let b = makeDimensionEntity(layerID: layerID)
        doc.addEntities([a, b])

        var arch = CADDimensionStyle.default
        arch.name = "Arch"
        XCTAssertTrue(doc.applyDimensionStyle(arch))

        let handles: Set<UUID> = [a.handle]
        XCTAssertEqual(
            doc.applyDimensionStyleToEntities(named: "ARCH", handles: handles), 1)
        XCTAssertEqual(
            doc.entity(for: a.handle)?.dimensionMetadata?.value.styleName, "Arch")
        XCTAssertNil(
            doc.entity(for: a.handle)?.dimensionMetadata?.value.styleOverrides)
        XCTAssertEqual(
            doc.entity(for: b.handle)?.dimensionMetadata?.value.styleName, "Standard")
        XCTAssertNil(
            doc.applyDimensionStyleToEntities(named: "Missing", handles: handles))
    }

    // MARK: - Sysvars

    func testDimensionSysvarsReadAndWriteCurrentRow() {
        let doc = makeDocument()
        let vars = LispVarStore()
        XCTAssertEqual(
            vars.get("DIMASZ", document: doc, activeCommand: nil), .real(2.5))
        XCTAssertEqual(
            vars.get("DIMSCALE", document: doc, activeCommand: nil), .real(1.0))
        XCTAssertEqual(
            vars.get("DIMDEC", document: doc, activeCommand: nil), .int(2))
        XCTAssertEqual(
            vars.get("DIMLUNIT", document: doc, activeCommand: nil), .int(2))

        XCTAssertNil(vars.set("DIMASZ", .real(4), document: doc))
        XCTAssertNil(vars.set("DIMSCALE", .real(2), document: doc))
        XCTAssertNil(vars.set("DIMDEC", .int(4), document: doc))
        XCTAssertNil(vars.set("DIMLUNIT", .int(4), document: doc))
        let row = doc.dimensionStyle(named: "Standard")
        XCTAssertEqual(row.arrowSize, 4)
        XCTAssertEqual(row.overallScale, 2)
        XCTAssertEqual(row.unitsPrecision, 4)
        XCTAssertEqual(row.unitsFormat, .architectural)
        // Effective geometry sees raw x scale.
        XCTAssertEqual(doc.currentDimensionStyle().arrowSize, 8)

        // Validation rejects bad values without touching the row.
        XCTAssertNotNil(vars.set("DIMSCALE", .real(0), document: doc))
        XCTAssertNotNil(vars.set("DIMSCALE", .real(-1), document: doc))
        XCTAssertNotNil(vars.set("DIMASZ", .real(-1), document: doc))
        XCTAssertNotNil(vars.set("DIMDEC", .int(9), document: doc))
        XCTAssertNotNil(vars.set("DIMLUNIT", .int(7), document: doc))
        XCTAssertEqual(
            doc.dimensionStyle(named: "Standard").overallScale, 2)
    }

    // MARK: - scaled()

    func testScaledMultipliesRawFieldsOnce() {
        var style = CADDimensionStyle.default
        style.overallScale = 2
        style.arrowSize = 2.5
        style.textOffset = 0.625
        let scaled = style.scaled()
        XCTAssertEqual(scaled.arrowSize, 5.0)
        XCTAssertEqual(scaled.textHeight, 5.0)
        XCTAssertEqual(scaled.textOffset, 1.25)
        XCTAssertEqual(scaled.overallScale, 1.0)
        XCTAssertEqual(scaled.scaled().arrowSize, 5.0)
        XCTAssertEqual(CADDimensionStyle.default.scaled().arrowSize, 2.5)
    }

    // MARK: - DXF import/export

    private var twoStyleDXF: String {
        """
          0
        SECTION
          2
        HEADER
          9
        $ACADVER
          1
        AC1024
          0
        ENDSEC
          0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        DIMSTYLE
          5
        8
        330
        0
        100
        AcDbSymbolTable
        100
        AcDbDimStyleTable
         70
        2
         71
        0
          0
        DIMSTYLE
        105
        9
        330
        8
        100
        AcDbSymbolTableRecord
        100
        AcDbDimStyleTableRecord
          2
        Standard
         70
        0
         40
        1.0
         41
        2.5
        140
        2.5
        147
        0.625
        271
        2
        277
        2
          0
        DIMSTYLE
        105
        A
        330
        8
        100
        AcDbSymbolTableRecord
        100
        AcDbDimStyleTableRecord
          2
        Big
         70
        0
         40
        2.0
         41
        3.0
         42
        1.0
         44
        2.0
          3
        P<>S
        140
        4.0
        147
        1.0
        271
        3
        277
        4
          0
        ENDTAB
          0
        ENDSEC
          0
        SECTION
          2
        ENTITIES
          0
        ENDSEC
          0
        EOF
        """
    }

    func testDXFImportStoresRawValuesWithScale() throws {
        let doc = try importDXFString(twoStyleDXF)
        XCTAssertEqual(Set(doc.dimensionStyles.keys), ["Standard", "Big"])
        let big = doc.dimensionStyle(named: "Big")
        XCTAssertEqual(big.name, "Big")
        XCTAssertEqual(big.overallScale, 2.0)
        XCTAssertEqual(big.arrowSize, 3.0)
        XCTAssertEqual(big.extensionLineOffset, 1.0)
        XCTAssertEqual(big.textHeight, 4.0)
        XCTAssertEqual(big.unitsPrecision, 3)
        XCTAssertEqual(big.unitsFormat, .architectural)
        XCTAssertEqual(big.dimensionPrefix, "P")
        XCTAssertEqual(big.dimensionSuffix, "S")
        // Effective (scaled) values match the old baked fold.
        XCTAssertEqual(big.scaled().arrowSize, 6.0)
        XCTAssertEqual(big.scaled().textHeight, 8.0)
        let std = doc.dimensionStyle(named: "Standard")
        XCTAssertEqual(std.overallScale, 1.0)
        XCTAssertEqual(std.arrowSize, 2.5)
    }

    func testDXFEditExportRoundTripPreservesStyles() throws {
        let doc = try importDXFString(twoStyleDXF)
        // Edit: retune Big through the sysvar path, add a third style.
        let vars = LispVarStore()
        XCTAssertTrue(doc.setCurrentDimensionStyle(named: "Big"))
        XCTAssertNil(vars.set("DIMASZ", .real(5), document: doc))
        var third = CADDimensionStyle.default
        third.name = "Third"
        third.overallScale = 0.5
        third.unitsFormat = .fractional
        XCTAssertTrue(doc.applyDimensionStyle(third))

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimstyle_rt_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFExporter.export(document: doc, to: outURL)

        let fresh = CADDocument()
        try fresh.importDXF(url: outURL)
        XCTAssertEqual(
            Set(fresh.dimensionStyles.keys), ["Standard", "Big", "Third"])
        let big = fresh.dimensionStyle(named: "Big")
        XCTAssertEqual(big.overallScale, 2.0)
        XCTAssertEqual(big.arrowSize, 5.0)
        XCTAssertEqual(big.dimensionPrefix, "P")
        XCTAssertEqual(big.dimensionSuffix, "S")
        let thirdOut = fresh.dimensionStyle(named: "Third")
        XCTAssertEqual(thirdOut.overallScale, 0.5)
        XCTAssertEqual(thirdOut.unitsFormat, .fractional)
    }

    // MARK: - Codable

    func testCodableToleratesArchivesBeforeNameAndScale() throws {
        let legacyJSON = """
        {"arrowSize":2.5,"textHeight":2.5,"textOffset":0.625,\
        "extensionLineOffset":0.625,"extensionLineExtend":1.25,\
        "dimLineOffset":3.75,"tickSize":0.0,"unitsFormat":2,\
        "unitsPrecision":2,"angleFormat":0,"anglePrecision":0,\
        "suppressFirstExtension":false,"suppressSecondExtension":false,\
        "suppressFirstDimLine":false,"suppressSecondDimLine":false,\
        "textBackgroundUsesViewportColor":true}
        """
        let decoded = try JSONDecoder().decode(
            CADDimensionStyle.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.name, "Standard")
        XCTAssertEqual(decoded.overallScale, 1.0)
        XCTAssertEqual(decoded.arrowSize, 2.5)

        var style = CADDimensionStyle.default
        style.name = "Arch"
        style.overallScale = 2
        let round = try JSONDecoder().decode(
            CADDimensionStyle.self,
            from: try JSONEncoder().encode(style))
        XCTAssertEqual(round.name, "Arch")
        XCTAssertEqual(round.overallScale, 2)
    }
}

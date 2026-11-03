import XCTest
@testable import ZephyrCore

/// Phase 1 layer-parity regressions: canonical fields (frozen/locked/
/// freeze-in-new-viewport/description/reconciled/transparency 0-90/fixed
/// lineweight/color intent/plot-style name), backward-compatible aliases,
/// the transactional mutation service (case-insensitive lookup,
/// active-layer guards, cross-view propagation), EAB v23 coverage with
/// legacy defaults, and complete DXF group-code handling.
@MainActor
final class LayerParityPhase1Tests: XCTestCase {

    private func docWithLayers(_ names: String...) -> CADDocument {
        let doc = CADDocument()
        for name in names { doc.addLayer(Layer(name: name)) }
        return doc
    }

    private func handle(_ doc: CADDocument, _ name: String) -> UUID {
        try! XCTUnwrap(doc.findLayer(named: name)).handle
    }

    // MARK: - Canonical fields and defaults

    func testCanonicalDefaults() {
        let layer = Layer(name: "Walls")
        XCTAssertTrue(layer.isVisible)
        XCTAssertTrue(layer.isOn)
        XCTAssertFalse(layer.isOff)
        XCTAssertTrue(layer.isEffectivelyVisible)
        XCTAssertFalse(layer.isFrozen)
        XCTAssertFalse(layer.freezeInNewViewports)
        XCTAssertFalse(layer.isLocked)
        XCTAssertEqual(layer.layerDescription, "")
        XCTAssertTrue(layer.isReconciled)
        XCTAssertEqual(layer.transparency, 0)
        XCTAssertEqual(layer.opacity, 1.0, accuracy: 1e-12)
        XCTAssertEqual(layer.lineWeight, 0.25, accuracy: 1e-12)
        XCTAssertEqual(layer.plotStyleName, "Normal")
        XCTAssertNil(layer.plotStyleHandle)
        XCTAssertEqual(layer.colorSource, .aci(7))
        XCTAssertEqual(layer.dxfStateBits, 0)
    }

    func testTransparencyClampAndOpacityAlias() {
        var layer = Layer(name: "A", transparency: 120)
        XCTAssertEqual(layer.transparency, 90, "transparency clamps to the 0...90 cap")
        layer.opacity = 0.3
        XCTAssertEqual(layer.transparency, 70)
        XCTAssertEqual(layer.opacity, 0.3, accuracy: 1e-9)
        layer.opacity = 0.0
        XCTAssertEqual(layer.transparency, 90, "opacity below 0.1 saturates at the 90 cap")
        layer.opacity = 1.0
        XCTAssertEqual(layer.transparency, 0)
    }

    func testFixedLineweightSnapping() {
        XCTAssertEqual(Layer.nearestFixedLineWeight(0.27), 0.25, accuracy: 1e-12)
        XCTAssertEqual(Layer.nearestFixedLineWeight(0.28), 0.30, accuracy: 1e-12)
        XCTAssertEqual(Layer.nearestFixedLineWeight(2.5), 2.11, accuracy: 1e-12)
        XCTAssertEqual(Layer(name: "A", lineWeight: 0.27).lineWeight, 0.25, accuracy: 1e-12)
        let doc = docWithLayers("A")
        doc.setLayerLineWeight(handle(doc, "A"), lineWeight: 0.28)
        XCTAssertEqual(doc.layer(for: handle(doc, "A"))!.lineWeight, 0.30, accuracy: 1e-12)
    }

    func testFrozenHidesViaPrimitiveVisibility() {
        var frozen = Layer(name: "F", isFrozen: true)
        XCTAssertFalse(frozen.isEffectivelyVisible)
        let byName = [frozen.name.uppercased(): frozen]
        XCTAssertFalse(CADPrimitiveVisibility.isVisible(
            style: CADPrimitiveStyle(layerName: "F"), layersByName: byName))
        frozen.isFrozen = false
        XCTAssertTrue(frozen.isEffectivelyVisible)
    }

    func testColorIntentInference() {
        XCTAssertEqual(Layer(name: "A", color: .white).colorSource, .aci(7))
        XCTAssertEqual(Layer(name: "B", color: .green).colorSource, .aci(3))
        XCTAssertEqual(
            Layer(name: "C", color: ColorRGBA(r: 10, g: 20, b: 30)).colorSource, .trueColor)
        XCTAssertEqual(
            Layer(name: "D", color: .red, colorSource: .colorBook(name: "PANTONE 185 C")).colorSource,
            .colorBook(name: "PANTONE 185 C"))
        XCTAssertEqual(Layer(name: "E", color: .red, colorSource: .aci(1)).colorSource, .aci(1))
    }

    // MARK: - Case-insensitive lookup

    func testCaseInsensitiveLookup() {
        let doc = docWithLayers("Walls")
        XCTAssertNotNil(doc.findLayer(named: "walls"))
        XCTAssertNotNil(doc.findLayer(named: " WALLS "))
        XCTAssertNil(doc.findLayer(named: ""))
        XCTAssertNil(doc.findLayer(named: "Doors"))
        XCTAssertNotEqual(doc.uniqueLayerName(base: "walls"), "Walls")
    }

    // MARK: - Transactional service: validation and guards

    func testActiveLayerGuardsLeaveStateUntouched() {
        let doc = docWithLayers("Current", "Walls")
        doc.activeLayerID = handle(doc, "Current")
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth

        let off = service.setVisible(in: doc, named: "current", visible: false)
        guard case .failure(let offError) = off else {
            return XCTFail("turning off the current layer must be refused")
        }
        XCTAssertEqual(offError, .activeLayerGuard("Cannot turn off the current layer 'Current'."))
        XCTAssertTrue(doc.layer(for: handle(doc, "Current"))!.isVisible)

        let freeze = service.setFrozen(in: doc, named: "CURRENT", frozen: true)
        guard case .failure(let freezeError) = freeze else {
            return XCTFail("freezing the current layer must be refused")
        }
        XCTAssertEqual(freezeError, .activeLayerGuard("Cannot freeze the current layer 'Current'."))
        XCTAssertFalse(doc.layer(for: handle(doc, "Current"))!.isFrozen)

        guard case .failure(let delError) = service.deleteLayer(in: doc, named: "Current") else {
            return XCTFail("deleting the current layer must be refused")
        }
        XCTAssertEqual(
            delError,
            .activeLayerGuard("Layer 'Current' is current and cannot be deleted."))

        guard case .failure(let zeroError) = service.deleteLayer(in: doc, named: "0") else {
            return XCTFail("deleting an unknown layer must be refused")
        }
        XCTAssertEqual(zeroError, .unknownLayer("0"))
        XCTAssertEqual(doc.undoManager.undoDepth, depth, "refused mutations push no undo")
        doc.addLayer(Layer(name: "0"))
        guard case .failure(let zeroProtected) = service.deleteLayer(in: doc, named: "0") else {
            return XCTFail("deleting layer 0 must be refused")
        }
        XCTAssertEqual(zeroProtected, .protectedLayer("Layer '0' cannot be deleted."))
        guard case .failure(let zeroRename) = service.renameLayer(in: doc, from: "0", to: "Zero") else {
            return XCTFail("renaming layer 0 must be refused")
        }
        XCTAssertEqual(zeroRename, .protectedLayer("Layer '0' cannot be renamed."))
    }

    func testRenameAndCreateValidation() {
        let doc = docWithLayers("A", "B")
        let service = LayerTransactionService()
        guard case .failure(let dup) = service.renameLayer(in: doc, from: "a", to: "B") else {
            return XCTFail("case-insensitive duplicate rename must be refused")
        }
        XCTAssertEqual(dup, .duplicateName("B"))
        guard case .failure(let blank) = service.createLayer(in: doc, name: "  ") else {
            return XCTFail("blank names must be refused")
        }
        XCTAssertEqual(blank, .blankName)
        guard case .failure(let clash) = service.createLayer(in: doc, name: "a") else {
            return XCTFail("case-insensitive duplicate create must be refused")
        }
        XCTAssertEqual(clash, .duplicateName("A"))
        guard case .failure(let bad) = service.setTransparency(in: doc, named: "A", transparency: 91) else {
            return XCTFail("transparency above 90 must be refused")
        }
        XCTAssertEqual(bad, .invalidValue("Transparency 91 is out of range 0...90."))
        guard case .failure(let unknown) = service.setLocked(in: doc, named: "Nope", locked: true) else {
            return XCTFail("unknown layers must be refused")
        }
        XCTAssertEqual(unknown, .unknownLayer("Nope"))
    }

    func testSuccessfulMutationIsSingleUndo() {
        let doc = docWithLayers("Walls")
        let service = LayerTransactionService()
        let depth = doc.undoManager.undoDepth
        let result = service.setTransparency(in: doc, named: "WALLS", transparency: 45)
        guard case .success(let outcome) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(outcome.layer.transparency, 45)
        XCTAssertEqual(outcome.propagatedToSiblings, 0)
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        doc.undo()
        XCTAssertEqual(doc.layer(for: handle(doc, "Walls"))!.transparency, 0)
    }

    // MARK: - Cross-view propagation

    func testServicePropagatesToSiblingsWithoutDirtying() {
        let layerID = UUID()
        let primary = CADDocument()
        primary.importLayersBlocksEntities(
            layers: [Layer(handle: layerID, name: "Walls", color: .white)],
            blocks: [], entities: [])
        let sibling = CADDocument()
        sibling.importLayersBlocksEntities(
            layers: [Layer(handle: layerID, name: "Walls", color: .white)],
            blocks: [], entities: [])
        let service = LayerTransactionService()
        let siblingRevision = sibling.editRevision
        let siblingDepth = sibling.undoManager.undoDepth

        let result = service.setColor(
            in: primary, siblings: [sibling], named: "walls", color: .yellow)
        guard case .success(let outcome) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(outcome.propagatedToSiblings, 1)
        XCTAssertEqual(sibling.layer(for: layerID)?.color, .yellow)
        XCTAssertEqual(sibling.editRevision, siblingRevision, "propagation is render-only")
        XCTAssertEqual(sibling.undoManager.undoDepth, siblingDepth, "propagation pushes no undo")
    }

    // MARK: - EAB v23 coverage

    func testEABv23RoundTripPreservesParityFields() throws {
        let doc = CADDocument()
        let rich = Layer(
            name: "Struc",
            isVisible: false,
            isFrozen: true,
            freezeInNewViewports: true,
            isLocked: true,
            layerDescription: "Structural framing",
            isReconciled: false,
            transparency: 45,
            lineWeight: 0.5,
            color: ColorRGBA(r: 10, g: 20, b: 30),
            colorSource: .colorBook(name: "PANTONE 185 C"),
            lineType: "DASHED",
            isPlottable: false,
            plotStyleHandle: "1A",
            plotStyleName: "Conceptual")
        doc.importLayersBlocksEntities(layers: [rich], blocks: [], entities: [])
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try EABWriter.write(document: doc, to: tempURL)
        let views = try EABReader.readViews(from: tempURL)
        let readDoc = try XCTUnwrap(views.first).document
        let back = try XCTUnwrap(readDoc.allLayers.first(where: { $0.name == "Struc" }))
        XCTAssertEqual(back.isVisible, false)
        XCTAssertEqual(back.isFrozen, true)
        XCTAssertEqual(back.freezeInNewViewports, true)
        XCTAssertEqual(back.isLocked, true)
        XCTAssertEqual(back.layerDescription, "Structural framing")
        XCTAssertEqual(back.isReconciled, false)
        XCTAssertEqual(back.transparency, 45)
        XCTAssertEqual(back.opacity, 0.55, accuracy: 1e-9)
        XCTAssertEqual(back.lineWeight, 0.5, accuracy: 1e-12)
        XCTAssertEqual(back.colorSource, .colorBook(name: "PANTONE 185 C"))
        XCTAssertEqual(back.plotStyleName, "Conceptual")
        XCTAssertEqual(back.plotStyleHandle, "1A")
        XCTAssertEqual(back.lineType, "DASHED")
        XCTAssertEqual(back.isPlottable, false)
    }

    func testEABv22PayloadReadsLegacyDefaults() throws {
        let handle = UUID()
        let w = BinaryWriter()
        w.writeUInt32(1)
        w.writeUUID(handle)
        w.writeString("Legacy")
        w.writeUInt8(0x00) // off
        w.writeFloat32(0.5)
        let white = UInt32(255) << 24 | UInt32(255) << 16 | UInt32(255) << 8 | UInt32(255)
        w.writeUInt32(white)
        w.writeFloat64(0.7) // legacy opacity -> 30% transparency
        w.writeString("DASHED")
        w.writeUInt8(0x01) // plottable, no plot-style handle
        let layers = try EABReader.parseLayers(BinaryReader(data: w.build()), version: 22)
        XCTAssertEqual(layers.count, 1)
        let back = try XCTUnwrap(layers.first)
        XCTAssertEqual(back.handle, handle)
        XCTAssertFalse(back.isVisible)
        XCTAssertFalse(back.isFrozen)
        XCTAssertFalse(back.freezeInNewViewports)
        XCTAssertFalse(back.isLocked)
        XCTAssertEqual(back.layerDescription, "")
        XCTAssertTrue(back.isReconciled, "pre-v23 files default to reconciled")
        XCTAssertEqual(back.transparency, 30)
        XCTAssertEqual(back.colorSource, .aci(7))
        XCTAssertEqual(back.plotStyleName, "Normal")
        XCTAssertNil(back.plotStyleHandle)
        XCTAssertEqual(back.lineType, "DASHED")
        XCTAssertTrue(back.isPlottable)
    }

    // MARK: - DXF group-code handling

    private func importDXFString(_ dxf: String) throws -> CADDocument {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_\(UUID().uuidString).dxf")
        try dxf.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        let doc = CADDocument()
        try doc.importDXF(url: tmpFile)
        return doc
    }

    func testDXFLayerGroupCodesImport() throws {
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
          0
        LAYER
          2
        Struc
         70
        5
         62
        3
          3
        Structural framing
          6
        DASHED
        290
        0
        370
        50
        390
        1A
        440
        33554662
        1001
        AcCmTransparency
        1071
        33554662
        1001
        ZEPHYR_COLORBOOK
        1000
        PANTONE 185 C
          0
        ENDTAB
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let layer = try XCTUnwrap(doc.allLayers.first(where: { $0.name == "Struc" }))
        XCTAssertTrue(layer.isFrozen, "group 70 bit 1")
        XCTAssertFalse(layer.freezeInNewViewports, "group 70 bit 2 clear")
        XCTAssertTrue(layer.isLocked, "group 70 bit 4")
        XCTAssertEqual(layer.layerDescription, "Structural framing", "group 3")
        XCTAssertTrue(layer.isVisible, "positive 62 stays on")
        XCTAssertEqual(layer.color, ColorRGBA(r: 0, g: 255, b: 0), "ACI 3")
        XCTAssertEqual(layer.colorSource, .colorBook(name: "PANTONE 185 C"), "book XDATA wins")
        XCTAssertEqual(layer.transparency, 10, "alpha 230 -> 10% transparent")
        XCTAssertEqual(layer.lineWeight, 0.5, accuracy: 1e-12, "group 370")
        XCTAssertEqual(layer.lineType, "DASHED", "group 6")
        XCTAssertFalse(layer.isPlottable, "group 290")
        XCTAssertEqual(layer.plotStyleHandle, "1A", "group 390 preserved")
        XCTAssertEqual(layer.plotStyleName, "Normal", "DXF carries no plot-style name")
        XCTAssertTrue(layer.isReconciled, "imports default to reconciled")
    }

    func testDXFTrueColorAndOffStateImport() throws {
        let dxf = """
        0
        SECTION
          2
        TABLES
          0
        TABLE
          2
        LAYER
          0
        LAYER
          2
        TrueOff
         70
        0
         62
        -1
        420
        11259375
          0
        ENDTAB
          0
        ENDSEC
          0
        EOF
        """
        let doc = try importDXFString(dxf)
        let layer = try XCTUnwrap(doc.allLayers.first(where: { $0.name == "TrueOff" }))
        XCTAssertFalse(layer.isVisible, "negative 62 means off")
        XCTAssertEqual(layer.color, ColorRGBA(r: 171, g: 205, b: 239), "group 420 wins")
        XCTAssertEqual(layer.colorSource, .trueColor)
        XCTAssertEqual(layer.transparency, 0)
    }

    func testDXFLayerRoundTripThroughWriter() throws {
        let doc = CADDocument()
        doc.importLayersBlocksEntities(
            layers: [Layer(
                name: "Struc",
                isFrozen: true,
                isLocked: true,
                layerDescription: "Structural framing",
                transparency: 10,
                lineWeight: 0.5,
                color: ColorRGBA(r: 0, g: 255, b: 0),
                colorSource: .colorBook(name: "PANTONE 185 C"),
                lineType: "DASHED",
                isPlottable: false,
                plotStyleName: "Conceptual")],
            blocks: [], entities: [])
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try DXFWriterBridge.export(document: doc, to: tempURL)
        let back = CADDocument()
        try back.importDXF(url: tempURL)
        let layer = try XCTUnwrap(back.allLayers.first(where: { $0.name == "Struc" }))
        XCTAssertTrue(layer.isFrozen, "70 bit 1 round-trips")
        XCTAssertTrue(layer.isLocked, "70 bit 4 round-trips")
        XCTAssertEqual(layer.layerDescription, "Structural framing", "group 3 round-trips")
        XCTAssertEqual(layer.transparency, 10, "440 round-trips")
        XCTAssertEqual(layer.lineWeight, 0.5, accuracy: 1e-12, "370 round-trips")
        XCTAssertEqual(layer.lineType, "DASHED")
        XCTAssertFalse(layer.isPlottable)
        XCTAssertEqual(layer.colorSource, .colorBook(name: "PANTONE 185 C"), "book XDATA round-trips")
        XCTAssertEqual(layer.color, ColorRGBA(r: 0, g: 255, b: 0))
        XCTAssertNotNil(layer.plotStyleHandle, "390 handle preserved")
    }
}

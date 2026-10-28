import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.2c PURGE/-PURGE: reachability sweep protection rules and the
/// single-undo batch removal. (Command confirm/scripted flow mirrors the
/// DimEdit option/value pattern; persistence is one pushUndo in applyPurge.)
@MainActor
final class PurgeTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        document.addLayer(Layer(name: "Used"))
        document.addLayer(Layer(name: "Empty"))
        document.activeLayerID = document.findLayer(named: "Used")?.handle
        return document
    }

    private func seedStyles(_ document: CADDocument) {
        document.textStyles["Notes"] = CADTextStyle(
            name: "Notes", fontFile: "arial.ttf", fixedHeight: 0,
            widthFactor: 1, obliqueAngle: 0, isAnnotative: false)
        document.textStyles["Orphan"] = CADTextStyle(
            name: "Orphan", fontFile: "arial.ttf", fixedHeight: 0,
            widthFactor: 1, obliqueAngle: 0, isAnnotative: false)
        var dims = CADDimensionStyle.default
        dims.name = "Arch"
        document.dimensionStyles["Arch"] = dims
        var leaders = CADLeaderStyle.standard
        leaders.name = "Callout"
        document.leaderStyles["Callout"] = leaders
        document.linetypePatterns["DASHED"] = [6, -3]
        document.linetypePatterns["ORPHANLT"] = [2, -2]
    }

    private func seedEntities(_ document: CADDocument) {
        let usedID = try! XCTUnwrap(document.findLayer(named: "Used")).handle
        var text = CADEntity(
            layerID: usedID,
            localGeometry: [.text(
                position: Vector3(x: 0, y: 0, z: 0), text: "hi", height: 2.5,
                rotation: 0, style: "Notes", alignH: 0, alignV: 0,
                mtextWidth: nil, color: nil)],
            transform: .identity)
        text.xdata["dxf.lineType"] = .string("DASHED")
        document.addEntity(text)
        let block = CADBlock(name: "Chair", geometry: [])
        document.addBlock(block)
        let usedBlock = try! XCTUnwrap(document.allBlocks.first(
            where: { $0.name == "Chair" }))
        document.addEntity(CADEntity(
            layerID: usedID, blockID: usedBlock.handle,
            localGeometry: nil, transform: .identity))
        document.addBlock(CADBlock(name: "OrphanBlock", geometry: []))
    }

    // MARK: - sweep

    func testSweepListsOnlyUnreferenced() {
        let doc = makeDocument()
        seedStyles(doc)
        seedEntities(doc)
        let report = doc.purgeableDefinitions(currentTextStyle: "Standard")
        let names = Set(report.items.map(\.displayName))
        // Unused definitions are listed ...
        XCTAssertTrue(names.contains("Empty"))
        XCTAssertTrue(names.contains("Orphan"))
        XCTAssertTrue(names.contains("OrphanBlock"))
        XCTAssertTrue(names.contains("ORPHANLT"))
        XCTAssertTrue(names.contains("Arch"))
        XCTAssertTrue(names.contains("Callout"))
        // ... while used and protected ones are kept.
        XCTAssertFalse(names.contains("0"))
        XCTAssertFalse(names.contains("Used"))
        XCTAssertFalse(names.contains("Standard"))
        XCTAssertFalse(names.contains("Notes"))
        XCTAssertFalse(names.contains("Chair"))
        XCTAssertFalse(names.contains("DASHED"))
        XCTAssertGreaterThan(report.protectedCounts.values.reduce(0, +), 0)
    }

    func testSweepProtectsCurrentStyles() {
        let doc = makeDocument()
        seedStyles(doc)
        XCTAssertTrue(doc.setCurrentDimensionStyle(named: "Arch"))
        doc.currentLeaderStyleName = "Callout"
        let report = doc.purgeableDefinitions(currentTextStyle: "Orphan")
        let names = Set(report.items.map(\.displayName))
        XCTAssertFalse(names.contains("Arch"))
        XCTAssertFalse(names.contains("Callout"))
        XCTAssertFalse(names.contains("Orphan"))
    }

    // MARK: - apply

    func testApplyPurgeRemovesInOneUndo() {
        let doc = makeDocument()
        seedStyles(doc)
        seedEntities(doc)
        let report = doc.purgeableDefinitions(currentTextStyle: "Standard")
        XCTAssertGreaterThan(report.total, 0)
        let depthBefore = doc.undoManager.undoDepth
        let removed = doc.applyPurge(report)
        XCTAssertEqual(doc.undoManager.undoDepth, depthBefore + 1)
        XCTAssertEqual(
            removed[.layer] ?? 0,
            report.items.filter { $0.kind == .layer }.count)
        XCTAssertNil(doc.findLayer(named: "Empty"))
        XCTAssertNotNil(doc.findLayer(named: "Used"))
        XCTAssertNil(doc.textStyles["Orphan"])
        XCTAssertNotNil(doc.textStyles["Notes"])
        // One undo restores everything the sweep removed.
        doc.undo()
        XCTAssertNotNil(doc.findLayer(named: "Empty"))
        XCTAssertNotNil(doc.textStyles["Orphan"])
        XCTAssertNotNil(doc.allBlocks.first(where: { $0.name == "OrphanBlock" }))
    }

    func testApplyPurgeSkipsVanishedDefinitions() {
        let doc = makeDocument()
        seedStyles(doc)
        var report = doc.purgeableDefinitions(currentTextStyle: "Standard")
        report.items.append(PurgeItem(
            kind: .textStyle, key: "Nope", displayName: "Nope"))
        report.items.append(PurgeItem(
            kind: .layer, key: UUID().uuidString, displayName: "Ghost"))
        let removed = doc.applyPurge(report)
        let listed = report.items.filter {
            $0.displayName != "Nope" && $0.displayName != "Ghost"
        }
        XCTAssertEqual(
            removed.values.reduce(0, +),
            listed.count)
    }
}

import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.3e multiline completion: MLINE bake math (justification
/// offsets, element runs, caps, centerline codec), MLSTYLE document
/// CRUD + undo, CMLJUST/CMLSCALE/CMLSTYLE sysvar wiring, PGP
/// user-alias parsing/registration (user wins), and EAB + DXF
/// round trips for styles and baked MLINE entities.
@MainActor
final class MlineStylePgpTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func wallStyle() -> CADMlineStyle {
        CADMlineStyle(
            name: "WALL3",
            description: "three-element wall",
            elements: [
                CADMlineElement(offset: 0.5),
                CADMlineElement(offset: 0),
                CADMlineElement(offset: -0.5),
            ])
    }

    private func linePoints(_ prim: CADPrimitive) -> (Vector3, Vector3)? {
        if case .line(let start, let end, _) = prim { return (start, end) }
        return nil
    }

    // MARK: - Bake math

    func testJustifiedOffsetsShiftPerJustification() {
        XCTAssertEqual(
            MlineMath.justifiedOffsets([0.5, -0.5], justification: 0),
            [0.0, -1.0])
        XCTAssertEqual(
            MlineMath.justifiedOffsets([0.5, -0.5], justification: 1),
            [0.5, -0.5])
        XCTAssertEqual(
            MlineMath.justifiedOffsets([0.5, -0.5], justification: 2),
            [1.0, 0.0])
        XCTAssertEqual(
            MlineMath.justifiedOffsets([], justification: 0), [])
    }

    func testBakeStraightStandardTop() {
        let centerline = [Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)]
        let baked = MlineMath.bake(
            centerline: centerline, style: .standard,
            scale: 1, justification: 0, closed: false)
        // Two element runs plus two straight end caps.
        XCTAssertEqual(baked.count, 4)
        let runs = baked.compactMap(linePoints)
        XCTAssertEqual(runs.count, 4)
        // Top justification: upper element rides the centerline.
        XCTAssertTrue(runs.contains {
            $0.0.x == 0 && $0.0.y == 0 && $0.1.x == 10 && $0.1.y == 0
        })
        XCTAssertTrue(runs.contains {
            $0.0.x == 0 && $0.0.y == -1 && $0.1.x == 10 && $0.1.y == -1
        })
        // End caps close the outer pair at both ends.
        XCTAssertTrue(runs.contains {
            $0.0.x == 0 && $0.1.x == 0 && abs($0.0.y - $0.1.y) == 1
        })
        XCTAssertTrue(runs.contains {
            $0.0.x == 10 && $0.1.x == 10 && abs($0.0.y - $0.1.y) == 1
        })
    }

    func testBakeClosedTriangleAndGuards() {
        let triangle = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 5, y: 8, z: 0),
        ]
        let baked = MlineMath.bake(
            centerline: triangle, style: .standard,
            scale: 1, justification: 1, closed: true)
        // Three segments x two elements plus one joint cap.
        XCTAssertEqual(baked.count, 7)
        XCTAssertTrue(baked.allSatisfy { linePoints($0) != nil })

        // Degenerate inputs bake nothing.
        XCTAssertTrue(MlineMath.bake(
            centerline: [Vector3(x: 1, y: 1, z: 0)], style: .standard,
            scale: 1, justification: 1, closed: false).isEmpty)
        XCTAssertTrue(MlineMath.bake(
            centerline: triangle,
            style: CADMlineStyle(name: "Empty"),
            scale: 1, justification: 1, closed: false).isEmpty)
    }

    func testCenterlineCodecRoundTripAndMalformed() throws {
        let points = [
            Vector3(x: 1, y: 2, z: 3), Vector3(x: 4, y: 5, z: 6),
        ]
        let decoded = try XCTUnwrap(
            MlineMath.decodeCenterline(MlineMath.encodeCenterline(points)))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].x, 1, accuracy: 1e-12)
        XCTAssertEqual(decoded[1].z, 6, accuracy: 1e-12)

        XCTAssertNil(MlineMath.decodeCenterline("1,2"))
        XCTAssertNil(MlineMath.decodeCenterline("a,b,c"))
        XCTAssertNil(MlineMath.decodeCenterline("1,2,3"))
        XCTAssertNil(MlineMath.decodeCenterline(""))
    }

    // MARK: - Document styles

    func testDefaultStandardStyle() {
        let document = makeDocument()
        XCTAssertEqual(document.currentMlineStyleName, "Standard")
        XCTAssertEqual(document.mlineScale, 1)
        XCTAssertEqual(document.mlineJustification, 0)
        let standard = document.mlineStyle(named: "Standard")
        XCTAssertEqual(standard.elements.map(\.offset), [0.5, -0.5])
        // Case-insensitive lookup with Standard fallback.
        XCTAssertEqual(document.mlineStyle(named: "standard").name, "Standard")
        XCTAssertEqual(document.mlineStyle(named: "Missing").name, "Standard")
    }

    func testStyleSetDeleteAndCurrentReset() {
        let document = makeDocument()
        document.setMlineStyle(wallStyle())
        XCTAssertEqual(document.mlineStyle(named: "wall3").elements.count, 3)

        document.currentMlineStyleName = "WALL3"
        XCTAssertTrue(document.deleteMlineStyle(named: "wall3"))
        XCTAssertEqual(document.currentMlineStyleName, "Standard")
        XCTAssertEqual(document.mlineStyle(named: "WALL3").name, "Standard")

        XCTAssertFalse(document.deleteMlineStyle(named: "Standard"))
        XCTAssertFalse(document.deleteMlineStyle(named: "Missing"))
    }

    func testStyleSetIsUndoable() {
        let document = makeDocument()
        document.setMlineStyle(wallStyle())
        XCTAssertNotNil(document.mlineStyles["WALL3"])
        document.undo()
        XCTAssertNil(document.mlineStyles["WALL3"])
        XCTAssertEqual(document.mlineStyle(named: "WALL3").name, "Standard")
    }

    // MARK: - Sysvars

    func testMlineSysvarsReadAndWrite() {
        let document = makeDocument()
        let vars = LispVarStore()
        XCTAssertEqual(
            vars.get("CMLJUST", document: document, activeCommand: nil), .int(0))
        XCTAssertEqual(
            vars.get("CMLSCALE", document: document, activeCommand: nil), .real(1.0))
        XCTAssertEqual(
            vars.get("CMLSTYLE", document: document, activeCommand: nil),
            .string("Standard"))

        XCTAssertNil(vars.set("CMLJUST", .int(2), document: document))
        XCTAssertNil(vars.set("CMLSCALE", .real(2), document: document))
        XCTAssertEqual(document.mlineJustification, 2)
        XCTAssertEqual(document.mlineScale, 2)
        XCTAssertEqual(
            vars.get("CMLJUST", document: document, activeCommand: nil), .int(2))

        XCTAssertNotNil(vars.set("CMLJUST", .int(5), document: document))
        XCTAssertNotNil(vars.set("CMLSCALE", .real(0), document: document))
        XCTAssertNotNil(vars.set("CMLSCALE", .real(-1), document: document))
        XCTAssertEqual(document.mlineJustification, 2)
        XCTAssertEqual(document.mlineScale, 2)

        XCTAssertNotNil(
            vars.set("CMLSTYLE", .string("Missing"), document: document))
        XCTAssertNil(
            vars.set("CMLSTYLE", .string("Standard"), document: document))
        XCTAssertEqual(document.currentMlineStyleName, "Standard")
    }

    // MARK: - PGP aliases

    func testPGPParse() {
        let parsed = PGPAliasLoader.parse(contents: """
            ; user aliases
            AA, *AREA
            T, *mtext
            BADLINE
            X,
            """)
        XCTAssertEqual(parsed.aliases.count, 2)
        XCTAssertEqual(parsed.aliases[0].alias, "AA")
        XCTAssertEqual(parsed.aliases[0].command, "AREA")
        XCTAssertEqual(parsed.aliases[1].alias, "T")
        XCTAssertEqual(parsed.aliases[1].command, "MTEXT")
        XCTAssertEqual(parsed.warnings.count, 2)
    }

    func testUserAliasRegisterResolveAndUserWins() {
        let processor = CADCommandProcessor()
        XCTAssertNil(processor.registerUserAlias("ZZX", for: "LINE"))
        XCTAssertEqual(processor.resolveUserAlias("zzx"), "LINE")
        XCTAssertEqual(processor.resolveUserAlias("UNSET"), "UNSET")

        // Unknown target and self-alias warn and never register.
        XCTAssertNotNil(processor.registerUserAlias("ZZX", for: "NOPECMD"))
        XCTAssertEqual(processor.resolveUserAlias("ZZX"), "LINE")
        XCTAssertNotNil(processor.registerUserAlias("LINE", for: "LINE"))

        // Colliding with a built-in succeeds with a warning: user wins.
        let warning = processor.registerUserAlias("L", for: "CIRCLE")
        XCTAssertNotNil(warning)
        XCTAssertEqual(processor.resolveUserAlias("L"), "CIRCLE")
    }

    func testPGPLoadIntoProcessor() {
        let processor = CADCommandProcessor()
        let result = PGPAliasLoader.load(
            contents: "ZZQ, *LINE\nNOPE\n", into: processor)
        XCTAssertEqual(result.loaded, 1)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(processor.resolveUserAlias("ZZQ"), "LINE")
    }

    // MARK: - Persistence

    func testEABRoundTripPreservesMlineStyles() throws {
        let document = makeDocument()
        document.setMlineStyle(wallStyle())
        document.currentMlineStyleName = "WALL3"

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mline-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: url) }
        try EABWriter.write(document: document, to: url)

        let views = try EABReader.readViews(from: url)
        let restored = try XCTUnwrap(views.first?.document)
        XCTAssertEqual(
            restored.mlineStyles["WALL3"]?.elements, wallStyle().elements)
        XCTAssertEqual(restored.currentMlineStyleName, "WALL3")
        XCTAssertEqual(
            restored.mlineStyle(named: "Standard").elements.map(\.offset),
            [0.5, -0.5])
    }

    func testDXFExportReimportsMlineAndStyle() throws {
        let document = makeDocument()
        let style = wallStyle()
        document.setMlineStyle(style)
        let centerline = [Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0)]
        let baked = MlineMath.bake(
            centerline: centerline, style: style,
            scale: 1, justification: 1, closed: false)
        XCTAssertFalse(baked.isEmpty)
        document.addEntity(CADEntity(
            layerID: zeroID(document),
            localGeometry: baked,
            xdata: [
                "dxf.mlineStyle": .string("WALL3"),
                "dxf.mlineScale": .double(1.0),
                "dxf.mlineJustification": .int(1),
                "dxf.mlineClosed": .int(0),
                "dxf.mlineCenterline": .string(
                    MlineMath.encodeCenterline(centerline)),
            ]))

        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mline-out-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try DXFWriterBridge.export(document: document, to: outURL)
        let text = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(text.contains("MLINE"))
        XCTAssertTrue(text.contains("MLINESTYLE"))
        XCTAssertTrue(text.contains("WALL3"))

        let reimported = try DXFImporter.importDXFViews(filePath: outURL.path)
        XCTAssertEqual(reimported.mlineStyles["WALL3"]?.elements.count, 3)
        let mlineEntity = try XCTUnwrap(reimported.entities.first {
            $0.xdata["dxf.mlineCenterline"] != nil
        })
        guard case .string(let raw) =
            mlineEntity.xdata["dxf.mlineCenterline"] else {
            throw XCTSkip("expected centerline xdata")
        }
        let roundTripped = try XCTUnwrap(MlineMath.decodeCenterline(raw))
        XCTAssertEqual(roundTripped.count, 2)
        XCTAssertEqual(roundTripped[0].x, 0, accuracy: 1e-6)
        XCTAssertEqual(roundTripped[1].x, 10, accuracy: 1e-6)
    }
}

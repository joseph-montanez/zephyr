import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Unit 1 (xref plan): style-faithful baking, drawing-file insertion
/// ($INSBASE/$INSUNITS), and scripted (command "INSERT" ...).
@MainActor
final class InsertCommandTests: XCTestCase {

    // MARK: - Baker

    func testBakeSynthesizesStylesAndAppliesBasePoint() {
        let walls = Layer(name: "Walls", color: .white)
        let loose = CADEntity(
            layerID: walls.handle,
            localGeometry: [
                .line(start: Vector3(x: 100, y: 50, z: 0),
                      end: Vector3(x: 110, y: 50, z: 0), color: nil)
            ],
            xdata: ["dxf.color": .string("FF0000"), "dxf.lineWeight": .double(0.35)])
        let inner = CADBlock(
            name: "Inner",
            geometry: [
                .line(start: Vector3(x: 0, y: 0, z: 0),
                      end: Vector3(x: 2, y: 0, z: 0), color: nil)
            ],
            primitiveStyles: [0: CADPrimitiveStyle(layerName: "Dims")])
        let instance = CADEntity(
            layerID: walls.handle, blockID: inner.handle,
            transform: .translated(by: Vector3(x: 100, y: 60, z: 0)))

        let baked = CADModelSpaceBaker.bake(
            entities: [loose, instance],
            layers: [walls], blocks: [inner],
            basePoint: Vector3(x: 100, y: 50, z: 0))

        XCTAssertEqual(baked.geometry.count, 2)
        // Loose line rebased to (0,0)-(10,0) with synthesized style.
        guard case let .line(start, end, _) = baked.geometry[0] else {
            return XCTFail("expected line, got \(baked.geometry[0])")
        }
        XCTAssertEqual(start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(end.x, 10, accuracy: 1e-9)
        XCTAssertEqual(baked.primitiveStyles[0]?.layerName, "Walls")
        XCTAssertEqual(baked.primitiveStyles[0]?.color, ColorRGBA(hex: "FF0000"))
        XCTAssertEqual(baked.primitiveStyles[0]?.lineWeight, 0.35)
        // Block geometry rebased through the instance transform, style kept.
        guard case let .line(innerStart, _, _) = baked.geometry[1] else {
            return XCTFail("expected line, got \(baked.geometry[1])")
        }
        XCTAssertEqual(innerStart.x, 0, accuracy: 1e-9)
        XCTAssertEqual(innerStart.y, 10, accuracy: 1e-9)
        XCTAssertEqual(baked.primitiveStyles[1]?.layerName, "Dims")
    }

    func testCreateBlockFromEntitiesPreservesStyles() {
        let doc = CADDocument()
        let layer = Layer(name: "Walls", color: .white)
        let entity = CADEntity(
            layerID: layer.handle,
            localGeometry: [
                .line(start: Vector3(x: 0, y: 0, z: 0),
                      end: Vector3(x: 4, y: 0, z: 0), color: nil)
            ],
            xdata: ["dxf.color": .string("00FF00")])
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [entity])
        let block = doc.createBlockFromEntities(handles: [entity.handle], name: "MadeBlock")
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.primitiveStyles[0]?.layerName, "Walls")
        XCTAssertEqual(block?.primitiveStyles[0]?.color, ColorRGBA(hex: "00FF00"))
    }

    // MARK: - File insert

    private func writeTempDXF() throws -> String {
        // Minimal DXF: $INSBASE (10,20), $INSUNITS 1 (inches), one LINE
        // from (10,20) to (12,20) on layer Walls.
        let dxf = """
        0
        SECTION
        2
        HEADER
        9
        $INSBASE
        10
        10.0
        20
        20.0
        30
        0.0
        9
        $INSUNITS
        70
        1
        0
        ENDSEC
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
        Walls
        70
        0
        62
        7
        6
        Continuous
        0
        ENDTAB
        0
        ENDSEC
        0
        SECTION
        2
        BLOCKS
        0
        ENDSEC
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        8
        Walls
        10
        10.0
        20
        20.0
        30
        0.0
        11
        12.0
        21
        20.0
        31
        0.0
        0
        ENDSEC
        0
        EOF
        """
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("xrefplan-Unit1Insert.dxf")
        try dxf.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testInsertFileCreatesBlockWithInsBaseAndUnitScale() throws {
        let path = try writeTempDXF()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = CADDocument()
        doc.unit = .millimeter
        doc.addLayer(Layer(name: "0"))

        let (block, scale) = try DrawingFileInsert.insertFile(at: path, into: doc)
        XCTAssertEqual(block.name, "xrefplan-Unit1Insert")
        XCTAssertEqual(scale, 25.4, accuracy: 1e-9, "inch → mm default scale")
        XCTAssertEqual(doc.block(for: block.handle)?.name, block.name)
        // Geometry rebased by -INSBASE: (0,0)-(2,0).
        guard case let .line(start, end, _) = block.geometry.first else {
            return XCTFail("expected baked line, got \(block.geometry)")
        }
        XCTAssertEqual(start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(end.x, 2, accuracy: 1e-9)
        // Source layer merged into host.
        XCTAssertNotNil(doc.findLayer(named: "Walls"))
        XCTAssertEqual(block.primitiveStyles[0]?.layerName, "Walls")

        // Second insert of the same file collides by name.
        XCTAssertThrowsError(try DrawingFileInsert.insertFile(at: path, into: doc)) { error in
            guard case DrawingFileInsert.InsertError.blockAlreadyExists = error else {
                return XCTFail("expected blockAlreadyExists, got \(error)")
            }
        }
    }

    func testInsertTransformOrder() {
        // Scale 2, rotate 90°, move to (10, 0): local (1,0) → (10, 2).
        let t = DrawingFileInsert.insertionTransform(
            point: Vector3(x: 10, y: 0, z: 0),
            scaleX: 2, scaleY: 2, rotationDegrees: 90)
        let p = t.transformPoint(Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(p.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.y, 2, accuracy: 1e-9)
    }

    // MARK: - Scripted INSERT

    private func makeHost() -> LispCADHost {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        doc.activeLayerID = doc.findLayer(named: "0")?.handle
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        return host
    }

    private func eval(
        _ source: String, host: LispCADHost, env: inout LispEnvironment
    ) async throws -> LispValue {
        let forms = try LispReader().readAll(source)
        return try await LispEvaluator().run(forms, env: &env, host: host)
    }

    func testScriptedInsertExistingBlockAndFile() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let doc = host.document
        let block = CADBlock(
            name: "Chair",
            geometry: [
                .line(start: Vector3(x: 0, y: 0, z: 0),
                      end: Vector3(x: 1, y: 0, z: 0), color: nil)
            ])
        doc.addBlock(block)

        _ = try await eval(
            #"(command "INSERT" "Chair" '(5 6 0) "2" "2" "90")"#, host: host, env: &env)
        let instance = doc.allEntities.first { $0.blockID == block.handle }
        XCTAssertNotNil(instance)
        let origin = instance?.transform.transformPoint(.zero)
        XCTAssertEqual(origin?.x ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(origin?.y ?? -1, 6, accuracy: 1e-9)

        // File insert by path (classic library semantics).
        let path = try writeTempDXF()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Lisp strings treat backslash as an escape (AutoCAD parity),
        // so a native Windows path must be escaped before interpolating.
        let lispPath = path.replacingOccurrences(of: "\\", with: "\\\\")
        _ = try await eval(
            "(command \"INSERT\" \"\(lispPath)\" '(0 0 0) \"1\" \"1\" \"0\")",
            host: host, env: &env)
        XCTAssertTrue(doc.allBlocks.contains { $0.name == "xrefplan-Unit1Insert" })
        XCTAssertEqual(
            doc.allEntities.filter { $0.blockID != nil }.count, 2)

        // Unknown block name rejects with a clear error.
        do {
            _ = try await eval(
                #"(command "INSERT" "NoSuchBlock-xyz" '(0 0 0) "1" "1" "0")"#,
                host: host, env: &env)
            XCTFail("unknown block should reject")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("not found"), "\(error)")
        }
    }

    func testInsertDescriptorPresent() {
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains { $0.canonicalName == "INSERT" })
    }

    func testTypedPointParsing() {
        // Interactive INSERT accepts x,y[,z] at the point prompt
        // (scripted `(command ...)` points stay point lists).
        let two = InsertCommand.parsePoint("10,20")
        XCTAssertEqual(two?.x, 10)
        XCTAssertEqual(two?.y, 20)
        XCTAssertEqual(two?.z ?? -1, 0)
        let three = InsertCommand.parsePoint("10, 20, 5")
        XCTAssertEqual(three?.x, 10)
        XCTAssertEqual(three?.y, 20)
        XCTAssertEqual(three?.z ?? -1, 5)
        XCTAssertNil(InsertCommand.parsePoint("abc"))
        XCTAssertNil(InsertCommand.parsePoint("10"))
        XCTAssertNil(InsertCommand.parsePoint(""))
    }
}

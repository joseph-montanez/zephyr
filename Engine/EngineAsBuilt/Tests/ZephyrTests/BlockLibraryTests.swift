import XCTest
@testable import ZephyrCore

/// Block library plan, Step 0: rebase-at-import.
///
/// Every CADBlock is stored (0,0)-based: the DXF BLOCK base offset is baked
/// out of the definition at import, and INSERT transforms carry no base
/// compensation. These tests pin that contract, including rotation and
/// ATTDEF placement.
@MainActor
final class BlockLibraryTests: XCTestCase {

    /// DXF with BLOCK "Door" based at (5,20,0), one LINE (5,20)-(7,20),
    /// one plain INSERT at (10,20), one rotated INSERT at (30,20,90deg).
    private func doorDXF() -> String {
        """
        0
        SECTION
        2
        HEADER
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
        0
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
        BLOCK
        8
        0
        2
        Door
        70
        0
        10
        5.0
        20
        20.0
        30
        0.0
        0
        LINE
        8
        0
        10
        5.0
        20
        20.0
        30
        0.0
        11
        7.0
        21
        20.0
        31
        0.0
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
        Door
        10
        10.0
        20
        20.0
        30
        0.0
        41
        1.0
        42
        1.0
        43
        1.0
        50
        0.0
        0
        INSERT
        8
        0
        2
        Door
        10
        30.0
        20
        20.0
        30
        0.0
        41
        1.0
        42
        1.0
        43
        1.0
        50
        90.0
        0
        ENDSEC
        0
        EOF
        """
    }

    private func importDoor() throws -> CADDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-door-\(UUID().uuidString).dxf")
        try doorDXF().write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = CADDocument()
        try doc.importDXF(url: url)
        return doc
    }

    func testNonZeroBlockBaseRebasesGeometry() throws {
        let doc = try importDoor()
        guard let door = doc.allBlocks.first(where: { $0.name == "Door" }) else {
            return XCTFail("Door block missing")
        }
        guard case let .line(start, end, _) = door.geometry.first else {
            return XCTFail("expected baked line, got \(door.geometry)")
        }
        XCTAssertEqual(start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(end.x, 2, accuracy: 1e-9)
        XCTAssertEqual(end.y, 0, accuracy: 1e-9)
    }

    func testNonZeroBlockBaseKeepsPlainInsertPlacement() throws {
        let doc = try importDoor()
        guard let door = doc.allBlocks.first(where: { $0.name == "Door" }) else {
            return XCTFail("Door block missing")
        }
        let instances = doc.allEntities.filter { $0.blockID == door.handle }
        XCTAssertEqual(instances.count, 2)
        // Plain INSERT at DXF (10,20) -> CAD (10,-20); block end (2,0) -> (12,-20).
        let plain = instances.min { lhs, rhs in
            lhs.transform.transformPoint(.zero).x < rhs.transform.transformPoint(.zero).x
        }!
        let origin = plain.transform.transformPoint(.zero)
        XCTAssertEqual(origin.x, 10, accuracy: 1e-9)
        XCTAssertEqual(origin.y, -20, accuracy: 1e-9)
        let tip = plain.transform.transformPoint(Vector3(x: 2, y: 0, z: 0))
        XCTAssertEqual(tip.x, 12, accuracy: 1e-9)
        XCTAssertEqual(tip.y, -20, accuracy: 1e-9)
    }

    func testNonZeroBlockBaseWithRotation() throws {
        let doc = try importDoor()
        guard let door = doc.allBlocks.first(where: { $0.name == "Door" }) else {
            return XCTFail("Door block missing")
        }
        let instances = doc.allEntities.filter { $0.blockID == door.handle }
        let rotated = instances.max { lhs, rhs in
            lhs.transform.transformPoint(.zero).x < rhs.transform.transformPoint(.zero).x
        }!
        // DXF 90deg CCW imports as CAD -90deg: block-local (2,0) -> (0,-2),
        // plus insertion CAD (30,-20) -> (30,-22).
        let tip = rotated.transform.transformPoint(Vector3(x: 2, y: 0, z: 0))
        XCTAssertEqual(tip.x, 30, accuracy: 1e-9)
        XCTAssertEqual(tip.y, -22, accuracy: 1e-9)
    }

    func testAttdefPositionRebased() throws {
        let dxf = """
        0
        SECTION
        2
        HEADER
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
        0
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
        BLOCK
        8
        0
        2
        Tag
        70
        0
        10
        5.0
        20
        20.0
        30
        0.0
        0
        ATTDEF
        8
        0
        10
        6.0
        20
        20.0
        30
        0.0
        40
        2.5
        1
        Default
        2
        TAG1
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
        ENDSEC
        0
        EOF
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-tag-\(UUID().uuidString).dxf")
        try dxf.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = CADDocument()
        try doc.importDXF(url: url)
        guard let tag = doc.allBlocks.first(where: { $0.name == "Tag" }) else {
            return XCTFail("Tag block missing")
        }
        guard let def = tag.attributeDefinitions.first(where: { $0.key == "TAG1" }) else {
            return XCTFail("TAG1 definition missing: \(tag.attributeDefinitions)")
        }
        XCTAssertEqual(def.position.x, 1, accuracy: 1e-9)
        XCTAssertEqual(def.position.y, 0, accuracy: 1e-9)
    }

    // MARK: - Step 1: insertability predicate

    func testPredicateAcceptsPlainBlock() {
        let plain = CADBlock(name: "Door", geometry: [])
        XCTAssertTrue(BlockLibraryPolicy.isUserInsertable(plain))
    }

    func testPredicateRejectsInternalAndXrefNames() {
        for name in ["*Model_Space", "*Paper_Space", "*U12", "*D3", "*T4", "Plan|Wall"] {
            XCTAssertFalse(
                BlockLibraryPolicy.isUserInsertable(CADBlock(name: name, geometry: [])),
                "\(name) must not be insertable")
        }
        var xref = CADBlock(name: "SitePlan", geometry: [])
        xref.xrefDescriptor = CADXrefDescriptor(savedPath: "site.dwg")
        XCTAssertFalse(BlockLibraryPolicy.isUserInsertable(xref))
    }

    // MARK: - Step 1: palette commands and sysvars

    func testPaletteDescriptorsPresent() {
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains { $0.canonicalName == "BLOCKSPALETTE" })
        XCTAssertTrue(
            CommandDescriptor.allCommands.contains { $0.canonicalName == "BLOCKSPALETTECLOSE" })
    }

    func testBlockLibrarySysvarDefaults() {
        let vars = LispVarStore()
        let doc = CADDocument()
        XCTAssertEqual(
            vars.get("ATTREQ", document: doc, activeCommand: nil), .int(0))
        XCTAssertEqual(
            vars.get("BLOCKSLIBRARYPATH", document: doc, activeCommand: nil), .string(""))
    }

    // MARK: - Steps 2-3: BlockPreview

    func testPreviewKeepsBlockLocalFrameAndAspect() {
        // 100x5 beam offset from the origin: no normalization, no squaring.
        let beam = CADBlock(
            name: "Beam",
            geometry: [
                .line(start: Vector3(x: 5, y: 5, z: 0),
                      end: Vector3(x: 105, y: 5, z: 0), color: nil),
                .line(start: Vector3(x: 105, y: 5, z: 0),
                      end: Vector3(x: 105, y: 10, z: 0), color: nil),
            ])
        let preview = BlockPreview.build(geometry: beam.geometry)
        XCTAssertFalse(preview.isEmpty)
        XCTAssertEqual(preview.boundsMin.x, 5, accuracy: 1e-5)
        XCTAssertEqual(preview.boundsMin.y, 5, accuracy: 1e-5)
        XCTAssertEqual(preview.width, 100, accuracy: 1e-4)
        XCTAssertEqual(preview.height, 5, accuracy: 1e-4)
    }

    func testPreviewFlattensCircleAndCapsSegments() {
        let many = (0..<2000).map { i in
            CADPrimitive.line(
                start: Vector3(x: Double(i), y: 0, z: 0),
                end: Vector3(x: Double(i) + 1, y: 0, z: 0), color: nil)
        }
        let capped = BlockPreview.build(geometry: many)
        XCTAssertLessThanOrEqual(capped.segments.count, 400)
        XCTAssertFalse(capped.isEmpty)

        let circle = CADBlock(
            name: "Wheel",
            geometry: [.circle(center: .zero, radius: 2, color: nil)])
        let wheel = BlockPreview.build(geometry: circle.geometry)
        XCTAssertEqual(wheel.segments.count, 48)
        XCTAssertEqual(wheel.width, 4, accuracy: 1e-4)
    }

    func testPreviewSkipsTextAndEmpty() {
        let text = CADBlock(
            name: "Note",
            geometry: [.text(position: .zero, text: "hi", height: 2.5,
                              rotation: 0, style: nil, alignH: 0, alignV: 0,
                              mtextWidth: nil, color: nil)])
        XCTAssertTrue(BlockPreview.build(geometry: text.geometry).isEmpty)
        XCTAssertTrue(BlockPreview.build(geometry: []).isEmpty)
    }

    // MARK: - Steps 2-3: container clone

    private func inchChairBundle() -> DrawingFileInsert.ContainerBundle {
        let chair = CADBlock(
            name: "Chair",
            geometry: [.line(start: Vector3(x: 0, y: 0, z: 0),
                              end: Vector3(x: 1, y: 0, z: 0), color: nil)],
            attributeDefinitions: [CADAttributeDefinition(
                tag: "SIZE", defaultValue: "M",
                position: Vector3(x: 0, y: 1, z: 0), height: 2.5)])
        return DrawingFileInsert.ContainerBundle(blocks: [chair], sourceUnit: .inch)
    }

    private func millimeterHost() -> CADDocument {
        let doc = CADDocument()
        doc.unit = .millimeter
        doc.addLayer(Layer(name: "0"))
        return doc
    }

    func testCloneBlockBakesUnitScaleOnce() throws {
        let doc = millimeterHost()
        let (block, scale) = try DrawingFileInsert.cloneBlock(
            named: "chair", from: inchChairBundle(), into: doc)
        XCTAssertEqual(scale, 1.0, accuracy: 1e-12)
        XCTAssertEqual(block.name, "Chair")
        // Inch geometry baked x25.4 into the resident definition.
        guard case let .line(start, end, _) = block.geometry.first else {
            return XCTFail("expected line, got \(block.geometry)")
        }
        XCTAssertEqual(end.x, 25.4, accuracy: 1e-9)
        XCTAssertEqual(start.x, 0, accuracy: 1e-12)
        // Attribute placement follows the bake.
        XCTAssertEqual(block.attributeDefinitions.first?.position.y ?? -1, 25.4, accuracy: 1e-9)
        XCTAssertEqual(block.attributeDefinitions.first?.height ?? -1, 2.5 * 25.4, accuracy: 1e-9)
    }

    func testCloneUseExistingKeepsResident() throws {
        let doc = millimeterHost()
        let resident = CADBlock(
            name: "Chair",
            geometry: [.line(start: .zero, end: Vector3(x: 9, y: 0, z: 0), color: nil)])
        doc.addBlock(resident)
        let (block, scale) = try DrawingFileInsert.cloneBlock(
            named: "CHAIR", from: inchChairBundle(), into: doc,
            policy: .useExisting)
        XCTAssertEqual(block.handle, resident.handle)
        XCTAssertEqual(scale, 1.0, accuracy: 1e-12)
        XCTAssertEqual(doc.allBlocks.filter { $0.name == "Chair" }.count, 1)
    }

    func testCloneImportAsCopySuffixes() throws {
        let doc = millimeterHost()
        doc.addBlock(CADBlock(name: "Chair", geometry: []))
        let first = try DrawingFileInsert.cloneBlock(
            named: "Chair", from: inchChairBundle(), into: doc,
            policy: .importAsCopy)
        XCTAssertEqual(first.block.name, "Chair_1")
        let second = try DrawingFileInsert.cloneBlock(
            named: "Chair", from: inchChairBundle(), into: doc,
            policy: .importAsCopy)
        XCTAssertEqual(second.block.name, "Chair_2")
    }

    func testCloneMissingBlockThrows() {
        let doc = millimeterHost()
        XCTAssertThrowsError(try DrawingFileInsert.cloneBlock(
            named: "Nope", from: inchChairBundle(), into: doc)) { error in
            guard case DrawingFileInsert.InsertError.importFailed(let message) = error else {
                return XCTFail("expected importFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("Nope"), message)
        }
    }

    func testLoadContainerBundleListsDXFBlocks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-bundle-\(UUID().uuidString).dxf")
        try doorDXF().write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try DrawingFileInsert.loadContainerBundle(fromFile: url.path)
        XCTAssertTrue(bundle.blocks.contains { $0.name == "Door" })
    }

    // MARK: - Steps 2-3: library service

    private func makeLibraryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try doorDXF().write(
            to: folder.appendingPathComponent("door.dxf"), atomically: true, encoding: .utf8)
        _ = FileManager.default.createFile(
            atPath: folder.appendingPathComponent("plan.dwg").path, contents: Data())
        _ = FileManager.default.createFile(
            atPath: folder.appendingPathComponent("notes.txt").path, contents: Data())
        return folder
    }

    func testScanFolderListsSupportedFilesOnly() throws {
        let folder = try makeLibraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entries = BlockLibraryService.scanFolder(at: folder)
        XCTAssertEqual(entries.map(\.displayName).sorted(), ["door", "plan"])
        XCTAssertEqual(entries.first?.ext, "dxf")
    }

    func testRequestParseDXFContainer() async throws {
        let folder = try makeLibraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let row = BlockLibraryService.scanFolder(at: folder).first(
            where: { $0.ext == "dxf" })
        else { return XCTFail("door.dxf missing from scan") }
        let parsed = try await BlockLibraryService.requestParse(entry: row)
        XCTAssertNil(parsed.error)
        guard let blocks = parsed.containerBlocks else {
            return XCTFail("container blocks not filled")
        }
        guard let door = blocks.first(where: { $0.blockName == "Door" }) else {
            return XCTFail("Door missing: \(blocks.map(\.blockName))")
        }
        XCTAssertFalse(door.preview?.isEmpty ?? true)
        XCTAssertFalse(parsed.rootPreview?.isEmpty ?? true)
    }

    func testRequestParseMissingThrowsFileNotFound() async {
        let missing = BlockLibraryService.FileEntry(
            path: "/nonexistent/door.dxf", displayName: "door",
            modified: .distantPast, size: 0)
        do {
            _ = try await BlockLibraryService.requestParse(entry: missing)
            XCTFail("expected throw")
        } catch let error as DrawingFileInsert.InsertError {
            guard case .fileNotFound = error else {
                return XCTFail("expected fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testResolveLocalURLRejectsUnsupported() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-note-\(UUID().uuidString).txt")
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await BlockLibraryService.resolveBundle(sourcePath: url.path)
            XCTFail("expected throw")
        } catch let error as DrawingFileInsert.InsertError {
            guard case .unsupportedFile = error else {
                return XCTFail("expected unsupportedFile, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEABContainerEndToEnd() async throws {
        let doc = try importDoor()
        // View-archive format.
        let viewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-view-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: viewURL) }
        try EABWriter.write(document: doc, to: viewURL)
        let viewBundle = try DrawingFileInsert.loadContainerBundle(fromFile: viewURL.path)
        XCTAssertTrue(viewBundle.blocks.contains { $0.name == "Door" })
        // Snapshot format.
        let snapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-snap-\(UUID().uuidString).eab")
        defer { try? FileManager.default.removeItem(at: snapURL) }
        try EABWriter.write(
            snapshots: [doc.buildSaveSnapshot(
                viewName: "Model", viewKind: .model, cameraState: .default)],
            to: snapURL)
        let snapBundle = try DrawingFileInsert.loadContainerBundle(fromFile: snapURL.path)
        XCTAssertTrue(snapBundle.blocks.contains { $0.name == "Door" })

        let host = millimeterHost()
        let (clone, scale) = try DrawingFileInsert.cloneBlock(
            named: "door", from: snapBundle, into: host)
        XCTAssertEqual(clone.name, "Door")
        XCTAssertEqual(scale, 1.0, accuracy: 1e-12)
        XCTAssertFalse(clone.geometry.isEmpty)
    }

    // MARK: - Step 5: persistence

    func testLibraryRefPersistenceRoundTrip() throws {
        var settings = UserSettings.default
        settings.blockRecent = [
            BlockLibraryRef(kind: .container, path: "/lib/a.dxf", block: "Door")]
        settings.blockFavorites = [BlockLibraryRef(kind: .file, path: "/lib/b.dxf")]
        settings.blockLibraryFolders = ["/lib"]
        settings.blockInsertExplode = true
        settings.blockInsertRepeat = true
        settings.blockInsertPromptAttributes = true
        let back = try JSONDecoder().decode(
            UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.blockRecent.first?.block, "Door")
        XCTAssertEqual(back.blockRecent.first?.path, "/lib/a.dxf")
        XCTAssertEqual(back.blockFavorites.count, 1)
        XCTAssertEqual(back.blockLibraryFolders, ["/lib"])
        XCTAssertTrue(back.blockInsertExplode)
        XCTAssertTrue(back.blockInsertRepeat)
        XCTAssertTrue(back.blockInsertPromptAttributes)
    }

    func testOldSettingsFileLoadsWithBlockDefaults() throws {
        let back = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(back.blockRecent.isEmpty)
        XCTAssertTrue(back.blockFavorites.isEmpty)
        XCTAssertTrue(back.blockLibraryFolders.isEmpty)
        XCTAssertFalse(back.blockInsertExplode)
        XCTAssertFalse(back.blockInsertRepeat)
        XCTAssertFalse(back.blockInsertPromptAttributes)
    }

    func testRecordRecentDedupesAndCaps() {
        var recent: [BlockLibraryRef] = []
        for i in 0..<60 {
            BlockLibraryPolicy.recordRecent(
                BlockLibraryRef(kind: .file, path: "/lib/\(i).dxf"), into: &recent)
        }
        XCTAssertEqual(recent.count, 50)
        XCTAssertEqual(recent.first?.path, "/lib/59.dxf")
        // Re-insert moves to front without growing.
        BlockLibraryPolicy.recordRecent(
            BlockLibraryRef(kind: .file, path: "/lib/0.dxf"), into: &recent)
        XCTAssertEqual(recent.first?.path, "/lib/0.dxf")
        XCTAssertEqual(recent.count, 50)
        // Same path, different kind/block stays distinct.
        BlockLibraryPolicy.recordRecent(
            BlockLibraryRef(kind: .container, path: "/lib/0.dxf", block: "Door"),
            into: &recent)
        XCTAssertTrue(recent.contains {
            $0.kind == .file && $0.path == "/lib/0.dxf" && $0.block == nil
        })
        XCTAssertTrue(recent.contains {
            $0.kind == .container && $0.path == "/lib/0.dxf" && $0.block == "Door"
        })
    }

    // MARK: - Step 4: single-undo commit group

    func testCommitGroupUndoesInOneStep() throws {
        let doc = millimeterHost()
        let depth = doc.undoManager.undoDepth
        doc.undoManager.beginUndoGroup()
        let (block, _) = try DrawingFileInsert.cloneBlock(
            named: "Chair", from: inchChairBundle(), into: doc)
        var entity = CADEntity(
            layerID: doc.allLayers.first!.handle,
            blockID: block.handle, transform: .identity)
        entity.attributeValues = CADAttributeSync.apply(
            definitions: block.attributeDefinitions, to: [:])
        doc.addEntity(entity)
        _ = doc.explodeEntities(handles: [entity.handle])
        doc.undoManager.endUndoGroup()
        XCTAssertEqual(doc.undoManager.undoDepth, depth + 1)
        // Exploded line plus the SIZE attribute as text.
        XCTAssertEqual(doc.allEntities.count, 2)
        doc.undo()
        XCTAssertTrue(doc.allEntities.isEmpty)
        XCTAssertFalse(doc.allBlocks.contains { $0.name == "Chair" })
    }
}


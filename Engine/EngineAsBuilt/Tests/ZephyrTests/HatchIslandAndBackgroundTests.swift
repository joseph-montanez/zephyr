import XCTest
import ImGui
@testable import ZephyrCore

final class HatchIslandAndBackgroundTests: XCTestCase {

    func testHatchRibbonSettingsIslandStyleDefaultAndCustom() {
        let defaultSettings = HatchRibbonUI.Settings(
            fillType: 0,
            patternName: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            primaryColor: nil,
            backgroundColor: nil,
            secondaryColor: nil,
            selectionMode: 0,
            showModeSection: true
        )
        XCTAssertEqual(defaultSettings.islandStyle, 0)

        var outerSettings = defaultSettings
        outerSettings.islandStyle = 1
        XCTAssertEqual(outerSettings.islandStyle, 1)

        var ignoreSettings = defaultSettings
        ignoreSettings.islandStyle = 2
        XCTAssertEqual(ignoreSettings.islandStyle, 2)
    }

    func testClassifyLoopsNormalStyleAlternatesIslands() {
        // Outer loop A: 0..100
        let loopA = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 100, y: 0, z: 0),
            Vector3(x: 100, y: 100, z: 0),
            Vector3(x: 0, y: 100, z: 0)
        ]
        // Island loop B: 20..80 (inside A)
        let loopB = [
            Vector3(x: 20, y: 20, z: 0),
            Vector3(x: 80, y: 20, z: 0),
            Vector3(x: 80, y: 80, z: 0),
            Vector3(x: 20, y: 80, z: 0)
        ]
        // Island loop C: 40..60 (inside B)
        let loopC = [
            Vector3(x: 40, y: 40, z: 0),
            Vector3(x: 60, y: 40, z: 0),
            Vector3(x: 60, y: 60, z: 0),
            Vector3(x: 40, y: 60, z: 0)
        ]

        let regions = CADBoundaryDetector.classifyLoops([loopA, loopB, loopC], islandStyle: 0)
        // In Normal style:
        // Region 1: Outer loop A with hole loop B
        // Region 2: Outer loop C with 0 holes (nested island hatched)
        XCTAssertEqual(regions.count, 2)

        let region1 = regions.first(where: { $0.outer.count == 4 && $0.holes.count == 1 })
        XCTAssertNotNil(region1)
        XCTAssertEqual(region1?.holes.count, 1)

        let region2 = regions.first(where: { $0.outer.count == 4 && $0.holes.isEmpty })
        XCTAssertNotNil(region2)
    }

    func testClassifyLoopsOuterStyleOnlyHatchesOuterToFirstIsland() {
        let loopA = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 100, y: 0, z: 0),
            Vector3(x: 100, y: 100, z: 0),
            Vector3(x: 0, y: 100, z: 0)
        ]
        let loopB = [
            Vector3(x: 20, y: 20, z: 0),
            Vector3(x: 80, y: 20, z: 0),
            Vector3(x: 80, y: 80, z: 0),
            Vector3(x: 20, y: 80, z: 0)
        ]
        let loopC = [
            Vector3(x: 40, y: 40, z: 0),
            Vector3(x: 60, y: 40, z: 0),
            Vector3(x: 60, y: 60, z: 0),
            Vector3(x: 40, y: 60, z: 0)
        ]

        let regions = CADBoundaryDetector.classifyLoops([loopA, loopB, loopC], islandStyle: 1)
        // In Outer style:
        // Only 1 region: Outer loop A with hole loop B. Inner island C is NOT hatched.
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].holes.count, 1)
    }

    func testClassifyLoopsIgnoreStyleHatchesEntireOuterIgnoringIslands() {
        let loopA = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 100, y: 0, z: 0),
            Vector3(x: 100, y: 100, z: 0),
            Vector3(x: 0, y: 100, z: 0)
        ]
        let loopB = [
            Vector3(x: 20, y: 20, z: 0),
            Vector3(x: 80, y: 20, z: 0),
            Vector3(x: 80, y: 80, z: 0),
            Vector3(x: 20, y: 80, z: 0)
        ]
        let loopC = [
            Vector3(x: 40, y: 40, z: 0),
            Vector3(x: 60, y: 40, z: 0),
            Vector3(x: 60, y: 60, z: 0),
            Vector3(x: 40, y: 60, z: 0)
        ]

        let regions = CADBoundaryDetector.classifyLoops([loopA, loopB, loopC], islandStyle: 2)
        // In Ignore style:
        // 1 region: Outer loop A with 0 holes. All islands B and C are ignored.
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].holes.count, 0)
    }

    func testHatchPathBackgroundColorPreservation() {
        let outer = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 50, y: 0, z: 0),
            Vector3(x: 50, y: 50, z: 0),
            Vector3(x: 0, y: 50, z: 0)
        ], isClosed: true)

        let yellowBg = ColorRGBA(r: 255, g: 255, b: 0, a: 255)
        let hatchPrimWithBg = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: ColorRGBA(r: 0, g: 0, b: 0, a: 255),
            backgroundColor: yellowBg
        )

        guard case .hatchPath(_, _, _, _, _, _, let bg) = hatchPrimWithBg else {
            XCTFail("Expected hatchPath primitive")
            return
        }
        XCTAssertEqual(bg, yellowBg)

        // Verify removing background color
        let hatchPrimNoBg = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: ColorRGBA(r: 0, g: 0, b: 0, a: 255),
            backgroundColor: nil
        )

        guard case .hatchPath(_, _, _, _, _, _, let bgNone) = hatchPrimNoBg else {
            XCTFail("Expected hatchPath primitive")
            return
        }
        XCTAssertNil(bgNone)
    }

    func testHatchPrimitiveGeneratorEmitsFillSpecOnlyWhenBackgroundColorPresent() {
        let outer = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 100, y: 0, z: 0),
            Vector3(x: 100, y: 100, z: 0),
            Vector3(x: 0, y: 100, z: 0)
        ], isClosed: true)

        let yellowBg = ColorRGBA(r: 255, g: 255, b: 0, a: 255)
        let primWithBg = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: ColorRGBA(r: 0, g: 0, b: 0, a: 255),
            backgroundColor: yellowBg
        )

        let specsWithBg = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: primWithBg,
            transform: .identity,
            color: (0, 0, 0, 255),
            z: 0.0)

        // When backgroundColor is set, CADTessellator.computeMultiLoopFillSpecs generates a .fillRect spec
        let fillSpecsWithBg = specsWithBg.filter { $0.type == .fillRect }
        XCTAssertEqual(fillSpecsWithBg.count, 1, "Expected 1 background fill spec when background color is present")

        let primNoBg = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: ColorRGBA(r: 0, g: 0, b: 0, a: 255),
            backgroundColor: nil
        )

        let specsNoBg = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: primNoBg,
            transform: .identity,
            color: (0, 0, 0, 255),
            z: 0.0)

        let fillSpecsNoBg = specsNoBg.filter { $0.type == .fillRect }
        XCTAssertEqual(fillSpecsNoBg.count, 0, "Expected 0 background fill specs when background color is nil")
        XCTAssertEqual(specsNoBg.count, specsWithBg.count - 1, "Unchecking background color must reduce specs by exactly 1")
    }

    @MainActor
    func testHatchCommandInitFromEntityWithAndWithoutBackground() {
        let outer = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 50, y: 0, z: 0),
            Vector3(x: 50, y: 50, z: 0),
            Vector3(x: 0, y: 50, z: 0)
        ], isClosed: true)
        let yellowBg = ColorRGBA(r: 255, g: 255, b: 0, a: 255)
        let prim = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI32",
            scale: 2.5,
            angle: 0.785,
            color: ColorRGBA(r: 10, g: 20, b: 30, a: 255),
            backgroundColor: yellowBg
        )
        var entity = CADEntity(layerID: UUID(), localGeometry: [prim])
        entity.xdata["zephyr.hatchBackgroundColor"] = .string("#FFFF00FF")
        entity.xdata["dxf.hatchStyle"] = .int(2)

        let cmd = HatchCommand()
        cmd.initFromEntity(entity)

        XCTAssertEqual(cmd.currentFillType, 0)
        XCTAssertEqual(cmd.currentPatternName, "ANSI32")
        XCTAssertEqual(cmd.currentBackgroundColor, yellowBg)
        XCTAssertEqual(cmd.currentIslandStyle, 2)

        // Now test entity where background color was unchecked / removed
        let primNoBg = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: nil,
            backgroundColor: nil
        )
        var entityNoBg = CADEntity(layerID: UUID(), localGeometry: [primNoBg])
        entityNoBg.xdata["dxf.hatchStyle"] = .int(1)

        let cmd2 = HatchCommand()
        cmd2.initFromEntity(entityNoBg)

        XCTAssertEqual(cmd2.currentFillType, 0)
        XCTAssertEqual(cmd2.currentPatternName, "ANSI31")
        XCTAssertNil(cmd2.currentBackgroundColor)
        XCTAssertEqual(cmd2.currentIslandStyle, 1)
    }

    func testHatchPatternColorUpdatePersistsThroughDocumentAndUndo() {
        let doc = CADDocument()
        let layerID = doc.allLayers.first?.handle ?? UUID()
        let outer = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0), Vector3(x: 10, y: 0, z: 0),
            Vector3(x: 10, y: 10, z: 0), Vector3(x: 0, y: 10, z: 0),
        ], isClosed: true)
        let red = ColorRGBA(r: 255, g: 90, b: 90, a: 255)
        let blue = ColorRGBA(r: 60, g: 140, b: 255, a: 255)
        let entity = CADEntity(layerID: layerID, localGeometry: [
            .hatchPath(boundary: outer, holes: [], pattern: "ANSI31",
                       scale: 1.0, angle: 0.0, color: red, backgroundColor: nil),
        ])
        doc.addEntity(entity)
        // Simulate what the hatch UI does after a preset swatch click:
        // rebuild the hatch primitive with the newly selected color.
        var updated = entity
        updated.localGeometry = [
            .hatchPath(boundary: outer, holes: [], pattern: "ANSI31",
                       scale: 1.0, angle: 0.0, color: blue, backgroundColor: nil),
        ]
        doc.updateEntity(updated)
        guard let stored = doc.entity(for: entity.handle)?.localGeometry?.first,
              case .hatchPath(_, _, _, _, _, let storedColor, _) = stored else {
            XCTFail("expected stored hatchPath primitive")
            return
        }
        XCTAssertEqual(storedColor, blue)
        doc.undo()
        guard let restored = doc.entity(for: entity.handle)?.localGeometry?.first,
              case .hatchPath(_, _, _, _, _, let restoredColor, _) = restored else {
            XCTFail("expected restored hatchPath primitive")
            return
        }
        XCTAssertEqual(restoredColor, red)
    }

    @MainActor
    func testHatchSwatchRowButtonPatternRegistersClicks() {
        let ctx = ImGuiCreateContext(nil)!
        defer { ImGuiDestroyContext(ctx) }
        let io = ImGuiGetIO()!
        io.pointee.DisplaySize = ImVec2(x: 1920, y: 1080)
        io.pointee.DeltaTime = 1.0 / 60.0
        _ = ImFontAtlas_AddFontDefault(io.pointee.Fonts, nil)
        igImFontAtlasBuildMain(io.pointee.Fonts)

        var selected: ColorRGBA? = nil
        let red = ColorRGBA(r: 255, g: 90, b: 90, a: 255)
        let blue = ColorRGBA(r: 60, g: 140, b: 255, a: 255)
        let presets = [red, blue]
        var clickedIndex: Int? = nil

        func runFrame() {
            ImGuiNewFrame()
            XCTAssertTrue(igBegin("##HatchCardProbe", nil, 0))
            let size = ImVec2(x: 24, y: 24)
            for (i, col) in presets.enumerated() {
                if i > 0 { ImGuiSameLine(0, 4) }
                let colU32 = makeCol32(col.r, col.g, col.b, 255)
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), colU32)
                ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), colU32)
                ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), colU32)
                if igButton("##c1_\(i)", size) {
                    selected = col
                    clickedIndex = i
                }
                ImGuiPopStyleColor(3)
            }
            ImGuiEnd()
            ImGuiRender()
        }

        // Baseline frame so the window and items get rects.
        runFrame()
        XCTAssertNil(selected)

        // Click the center of the second swatch: find its rect first.
        ImGuiNewFrame()
        XCTAssertTrue(igBegin("##HatchCardProbe", nil, 0))
        let size = ImVec2(x: 24, y: 24)
        for (i, col) in presets.enumerated() {
            if i > 0 { ImGuiSameLine(0, 4) }
            let colU32 = makeCol32(col.r, col.g, col.b, 255)
            ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), colU32)
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), colU32)
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), colU32)
            _ = igButton("##c1_\(i)", size)
            ImGuiPopStyleColor(3)
            if i == 1 {
                let rMin = igGetItemRectMin()
                let rMax = igGetItemRectMax()
                io.pointee.MousePos = ImVec2(x: (rMin.x + rMax.x) * 0.5, y: (rMin.y + rMax.y) * 0.5)
            }
        }
        ImGuiEnd()
        ImGuiRender()

        // Press and release on the second swatch.
        io.pointee.MouseDown.0 = true
        runFrame()
        io.pointee.MouseDown.0 = false
        runFrame()

        XCTAssertEqual(clickedIndex, 1)
        XCTAssertEqual(selected, blue)
    }

    func testHatchPatternColorSelectionRegistersAsSettingsChange() {
        var settings = HatchRibbonUI.Settings(
            fillType: 0,
            patternName: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            primaryColor: nil,
            backgroundColor: nil,
            secondaryColor: nil,
            selectionMode: 0,
            showModeSection: true
        )
        let oldSettings = settings
        // Simulate clicking a preset swatch in the "Pattern color" row.
        settings.primaryColor = ColorRGBA(r: 255, g: 90, b: 90, a: 255)
        XCTAssertNotEqual(settings, oldSettings)
        XCTAssertEqual(settings.primaryColor, ColorRGBA(r: 255, g: 90, b: 90, a: 255))
    }

    @MainActor
    func testHatchRibbonLastUsedBackgroundColorPreservation() {
        HatchRibbonUI.lastUsedBackgroundColor = ColorRGBA(r: 40, g: 220, b: 240, a: 255)
        XCTAssertEqual(HatchRibbonUI.lastUsedBackgroundColor, ColorRGBA(r: 40, g: 220, b: 240, a: 255))
    }

    func testHatchEntityUpdateWithUndoAndRedo() {
        let doc = CADDocument()
        let layerID = doc.allLayers.first?.handle ?? UUID()
        let outer = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 50, y: 0, z: 0),
            Vector3(x: 50, y: 50, z: 0),
            Vector3(x: 0, y: 50, z: 0)
        ], isClosed: true)
        let prim1 = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: nil,
            backgroundColor: nil
        )
        var entity = CADEntity(layerID: layerID, localGeometry: [prim1])
        entity.xdata["dxf.hatchPatternName"] = .string("ANSI31")
        entity.xdata["dxf.hatchScale"] = .double(1.0)
        entity.xdata["dxf.hatchAngle"] = .double(0.0)
        entity.xdata["dxf.hatchAssociative"] = .bool(true)
        doc.addEntity(entity)

        XCTAssertEqual(doc.undoManager.undoDepth, 1)

        // 1. Perform discrete update (e.g. changing pattern to ANSI32 and angle to 0.785)
        var updated = entity
        let prim2 = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI32",
            scale: 2.0,
            angle: 0.785,
            color: nil,
            backgroundColor: nil
        )
        updated.localGeometry = [prim2]
        updated.xdata["dxf.hatchPatternName"] = .string("ANSI32")
        updated.xdata["dxf.hatchScale"] = .double(2.0)
        updated.xdata["dxf.hatchAngle"] = .double(0.785)
        doc.updateEntity(updated)

        XCTAssertEqual(doc.undoManager.undoDepth, 2)
        XCTAssertEqual(doc.entity(for: entity.handle)?.xdata["dxf.hatchPatternName"], .string("ANSI32"))

        // 2. Undo discrete update
        doc.undo()
        XCTAssertEqual(doc.undoManager.undoDepth, 1)
        XCTAssertEqual(doc.entity(for: entity.handle)?.xdata["dxf.hatchPatternName"], .string("ANSI31"))
        XCTAssertEqual(doc.entity(for: entity.handle)?.xdata["dxf.hatchAngle"], .double(0.0))

        // 3. Redo discrete update
        doc.redo()
        XCTAssertEqual(doc.undoManager.undoDepth, 2)
        XCTAssertEqual(doc.entity(for: entity.handle)?.xdata["dxf.hatchPatternName"], .string("ANSI32"))
        XCTAssertEqual(doc.entity(for: entity.handle)?.xdata["dxf.hatchAngle"], .double(0.785))
    }

    func testHatchContinuousDragUndoCoalescing() {
        let doc = CADDocument()
        let layerID = doc.allLayers.first?.handle ?? UUID()
        let outer = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 50, y: 0, z: 0),
            Vector3(x: 50, y: 50, z: 0),
            Vector3(x: 0, y: 50, z: 0)
        ], isClosed: true)
        let initialPrim = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: nil,
            backgroundColor: nil
        )
        var entity = CADEntity(layerID: layerID, localGeometry: [initialPrim])
        entity.xdata["dxf.hatchAngle"] = .double(0.0)
        doc.addEntity(entity)

        let initialDepth = doc.undoManager.undoDepth
        XCTAssertEqual(initialDepth, 1)

        // Continuous drag begins: capture pre-drag snapshot
        let preDragSnapshot = doc.snapshot()

        // 10 intermediate frames of live updates while user drags angle slider
        for i in 1...10 {
            let angle = Double(i) * 0.1
            var liveEntity = entity
            liveEntity.xdata["dxf.hatchAngle"] = .double(angle)
            doc.updateEntityLive(liveEntity)
            // Undo stack MUST NOT be flooded with intermediate frames
            XCTAssertEqual(doc.undoManager.undoDepth, 1)
        }

        // Drag finishes: push pre-drag snapshot
        doc.pushUndo(preDragSnapshot)
        XCTAssertEqual(doc.undoManager.undoDepth, 2, "Exactly one undo entry must be created for the entire drag")

        // Undo restores initial pre-drag state
        doc.undo()
        XCTAssertEqual(doc.entity(for: entity.handle)?.xdata["dxf.hatchAngle"], .double(0.0))

        // Redo restores final dragged state
        doc.redo()
        XCTAssertEqual(doc.entity(for: entity.handle)?.xdata["dxf.hatchAngle"], .double(1.0))
    }

    @MainActor
    func testHatchCommandAssociativeAndSettingsSynchronization() {
        let outer = CADPolyline(points: [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 50, y: 0, z: 0),
            Vector3(x: 50, y: 50, z: 0),
            Vector3(x: 0, y: 50, z: 0)
        ], isClosed: true)
        let prim = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI31",
            scale: 1.0,
            angle: 0.0,
            color: nil,
            backgroundColor: nil
        )
        var entity = CADEntity(layerID: UUID(), localGeometry: [prim])
        entity.xdata["dxf.hatchAssociative"] = .bool(true)
        entity.xdata["dxf.hatchPatternName"] = .string("ANSI31")

        let cmd = HatchCommand()
        cmd.initFromEntity(entity)
        XCTAssertEqual(cmd.currentPatternName, "ANSI31")

        // Mutating entity and resyncing upon undo
        let prim33 = CADPrimitive.hatchPath(
            boundary: outer,
            holes: [],
            pattern: "ANSI33",
            scale: 1.0,
            angle: 0.0,
            color: nil,
            backgroundColor: nil
        )
        var updatedEntity = entity
        updatedEntity.localGeometry = [prim33]
        updatedEntity.xdata["zephyr.hatchPatternKey"] = .string("ANSI33")
        updatedEntity.xdata["dxf.hatchPatternName"] = .string("ANSI33")
        cmd.initFromEntity(updatedEntity)
        XCTAssertEqual(cmd.currentPatternName, "ANSI33")

        // Resync back to original (as happens when undo restores original entity)
        cmd.initFromEntity(entity)
        XCTAssertEqual(cmd.currentPatternName, "ANSI31")
    }
}

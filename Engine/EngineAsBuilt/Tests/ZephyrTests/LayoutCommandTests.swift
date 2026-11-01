import XCTest
@testable import ZephyrCore

@MainActor
final class LayoutCommandTests: XCTestCase {

    private func makeDocument(layerName: String) -> CADDocument {
        let doc = CADDocument()
        let layer = Layer(
            handle: UUID(), name: layerName, isVisible: true,
            lineWeight: 0.25, color: .white, lineType: "CONTINUOUS")
        doc.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])
        return doc
    }

    private func makeManager() -> TabManager {
        let modelDoc = makeDocument(layerName: "ModelLayer")
        let sheetDoc = makeDocument(layerName: "SheetLayer")
        let manager = TabManager()
        manager.addTab(DocumentTab(
            document: modelDoc,
            displayName: "LayoutTests",
            drawingViews: [
                DrawingView(name: "Model", kind: .model, document: modelDoc),
                DrawingView(name: "Layout1", kind: .sheet, document: sheetDoc),
            ]))
        return manager
    }

    func testLayoutDescriptorBareEnterAndAliases() {
        let desc = CommandDescriptor.allCommands.first { $0.canonicalName == "LAYOUT" }
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.bareEnterExecutes, true)
        XCTAssertEqual(desc?.aliases, ["SHEET", "LO", "-LAYOUT"])

        let processor = CADCommandProcessor()
        for alias in ["LAYOUT", "LO", "SHEET", "-LAYOUT"] {
            let matches = processor.matchCommands(input: alias).map(\.descriptor.canonicalName)
            XCTAssertTrue(matches.contains("LAYOUT"), "'\(alias)' should match LAYOUT")
        }
    }

    func testInteractiveNewLayoutWithCustomName() {
        let manager = makeManager()
        let processor = CADCommandProcessor()
        let cmd = LayoutCommand()

        cmd.start(tabManager: manager, processor: processor)
        XCTAssertTrue(processor.commandLineActive)
        XCTAssertEqual(processor.commandPrompt, LayoutCommand.optionPrompt)
        XCTAssertEqual(cmd.phase, .option)
        XCTAssertEqual(
            cmd.commandTextOptions(for: "").map(\.value),
            ["C", "D", "N", "T", "R", "SA", "S", "?"])

        // Step 1: Type "n" + Enter
        let step1 = cmd.handleCommandText("n", tabManager: manager, processor: processor)
        XCTAssertEqual(step1, .consumed)
        XCTAssertTrue(processor.commandLineActive)
        XCTAssertEqual(cmd.phase, .newName(defaultName: "Layout2"))
        XCTAssertEqual(processor.commandPrompt, "Enter new Layout name <Layout2>:")
        // Free-form name entry must not offer option autocomplete
        XCTAssertTrue(cmd.commandTextOptions(for: "Floor").isEmpty)

        // Step 2: Type custom layout name + Enter
        var zoomed = false
        let step2 = cmd.handleCommandText(
            "FloorPlan",
            tabManager: manager,
            processor: processor,
            onZoomExtents: { zoomed = true })
        XCTAssertEqual(step2, .finished)
        XCTAssertFalse(processor.commandLineActive)
        XCTAssertTrue(zoomed)
        XCTAssertEqual(manager.activeViewName, "FloorPlan")
        XCTAssertTrue(manager.paperLayoutNames.contains("FloorPlan"))
    }

    func testInteractiveNewLayoutBareEnterUsesDefaultName() {
        let manager = makeManager()
        let processor = CADCommandProcessor()
        let cmd = LayoutCommand()

        cmd.start(tabManager: manager, processor: processor)
        _ = cmd.handleCommandText("N", tabManager: manager, processor: processor)
        XCTAssertEqual(cmd.phase, .newName(defaultName: "Layout2"))

        // Bare Enter accepts <Layout2>
        let result = cmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(result, .finished)
        XCTAssertEqual(manager.activeViewName, "Layout2")
        XCTAssertEqual(manager.paperLayoutNames, ["Layout1", "Layout2"])
    }

    func testInteractiveNewLayoutDuplicateOrInvalidNameRePrompts() {
        let manager = makeManager()
        let processor = CADCommandProcessor()
        let cmd = LayoutCommand()

        cmd.start(tabManager: manager, processor: processor)
        _ = cmd.handleCommandText("n", tabManager: manager, processor: processor)

        // Duplicate name stays in .newName
        let dupResult = cmd.handleCommandText("Layout1", tabManager: manager, processor: processor)
        XCTAssertEqual(dupResult, .consumed)
        XCTAssertEqual(cmd.phase, .newName(defaultName: "Layout2"))
        XCTAssertTrue(processor.commandLineActive)

        // Reserved character stays in .newName
        let badResult = cmd.handleCommandText("Bad/Name", tabManager: manager, processor: processor)
        XCTAssertEqual(badResult, .consumed)
        XCTAssertEqual(cmd.phase, .newName(defaultName: "Layout2"))
        XCTAssertTrue(processor.commandLineActive)

        // Valid name finishes
        let okResult = cmd.handleCommandText("ValidSheet", tabManager: manager, processor: processor)
        XCTAssertEqual(okResult, .finished)
        XCTAssertEqual(manager.activeViewName, "ValidSheet")
    }

    func testInteractiveSetOptionAndBareEnterDefault() {
        let manager = makeManager()
        let processor = CADCommandProcessor()
        let cmd = LayoutCommand()

        XCTAssertEqual(manager.activeViewName, "Model")
        cmd.start(tabManager: manager, processor: processor)

        // Bare Enter at option prompt chooses <set>
        let step1 = cmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(step1, .consumed)
        XCTAssertEqual(cmd.phase, .setName(defaultName: "Layout1"))
        XCTAssertEqual(processor.commandPrompt, "Enter layout to make current <Layout1>:")
        XCTAssertEqual(cmd.commandTextOptions(for: "").map(\.value), ["Layout1"])

        // Bare Enter at set prompt activates default <Layout1>
        let step2 = cmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(step2, .finished)
        XCTAssertEqual(manager.activeViewName, "Layout1")
    }

    func testInteractiveCopyOptionWithDefaults() {
        let manager = makeManager()
        let processor = CADCommandProcessor()
        let cmd = LayoutCommand()

        cmd.start(tabManager: manager, processor: processor)
        let step1 = cmd.handleCommandText("c", tabManager: manager, processor: processor)
        XCTAssertEqual(step1, .consumed)
        XCTAssertEqual(cmd.phase, .copySource(defaultSource: "Layout1"))
        XCTAssertEqual(processor.commandPrompt, "Enter layout to copy <Layout1>:")

        // Bare Enter accepts source <Layout1>
        let step2 = cmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(step2, .consumed)
        XCTAssertEqual(cmd.phase, .copyDest(sourceName: "Layout1", defaultDest: "Layout1 (2)"))
        XCTAssertEqual(processor.commandPrompt, "Enter layout name for copy <Layout1 (2)>:")

        // Bare Enter accepts destination <Layout1 (2)>
        let step3 = cmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(step3, .finished)
        XCTAssertEqual(manager.activeViewName, "Layout1 (2)")
        XCTAssertEqual(manager.paperLayoutNames, ["Layout1", "Layout1 (2)"])
    }

    func testInteractiveRenameAndDeleteOptions() {
        let manager = makeManager()
        XCTAssertTrue(manager.createLayout(named: "Layout2"))
        let processor = CADCommandProcessor()

        // Rename Layout2 -> SheetB
        let renameCmd = LayoutCommand()
        renameCmd.start(tabManager: manager, processor: processor)
        _ = renameCmd.handleCommandText("r", tabManager: manager, processor: processor)
        XCTAssertEqual(renameCmd.phase, .renameSource(defaultSource: "Layout2"))
        _ = renameCmd.handleCommandText("", tabManager: manager, processor: processor)
        XCTAssertEqual(renameCmd.phase, .renameDest(oldName: "Layout2"))
        let renameFinish = renameCmd.handleCommandText("SheetB", tabManager: manager, processor: processor)
        XCTAssertEqual(renameFinish, .finished)
        XCTAssertEqual(manager.paperLayoutNames, ["Layout1", "SheetB"])

        // Delete SheetB (after verifying Model is guarded)
        let deleteCmd = LayoutCommand()
        deleteCmd.start(tabManager: manager, processor: processor)
        _ = deleteCmd.handleCommandText("d", tabManager: manager, processor: processor)
        let modelGuard = deleteCmd.handleCommandText("Model", tabManager: manager, processor: processor)
        XCTAssertEqual(modelGuard, .consumed)
        let deleteFinish = deleteCmd.handleCommandText("SheetB", tabManager: manager, processor: processor)
        XCTAssertEqual(deleteFinish, .finished)
        XCTAssertEqual(manager.paperLayoutNames, ["Layout1"])
    }

    func testQuestionMarkSaveAsAndTemplateStayInOptionPhase() {
        let manager = makeManager()
        let processor = CADCommandProcessor()
        let cmd = LayoutCommand()

        cmd.start(tabManager: manager, processor: processor)
        for keyword in ["?", "sa", "t"] {
            let result = cmd.handleCommandText(keyword, tabManager: manager, processor: processor)
            XCTAssertEqual(result, .consumed, "Keyword '\(keyword)' should stay in option phase")
            XCTAssertEqual(cmd.phase, .option)
            XCTAssertTrue(processor.commandLineActive)
        }
    }

    func testInlineSingleShotCommands() {
        let manager = makeManager()
        let processor = CADCommandProcessor()

        let createCmd = LayoutCommand()
        createCmd.start(tabManager: manager, processor: processor)
        XCTAssertEqual(
            createCmd.handleCommandText("N InlineSheet", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.activeViewName, "InlineSheet")

        let copyCmd = LayoutCommand()
        copyCmd.start(tabManager: manager, processor: processor)
        XCTAssertEqual(
            copyCmd.handleCommandText("COPY InlineSheet InlineCopy", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.activeViewName, "InlineCopy")

        let renameCmd = LayoutCommand()
        renameCmd.start(tabManager: manager, processor: processor)
        XCTAssertEqual(
            renameCmd.handleCommandText("RENAME InlineCopy RenamedCopy", tabManager: manager, processor: processor),
            .finished)
        XCTAssertTrue(manager.paperLayoutNames.contains("RenamedCopy"))

        let setCmd = LayoutCommand()
        setCmd.start(tabManager: manager, processor: processor)
        XCTAssertEqual(
            setCmd.handleCommandText("SET InlineSheet", tabManager: manager, processor: processor),
            .finished)
        XCTAssertEqual(manager.activeViewName, "InlineSheet")

        let deleteCmd = LayoutCommand()
        deleteCmd.start(tabManager: manager, processor: processor)
        XCTAssertEqual(
            deleteCmd.handleCommandText("DELETE RenamedCopy", tabManager: manager, processor: processor),
            .finished)
        XCTAssertFalse(manager.paperLayoutNames.contains("RenamedCopy"))
    }
}

import XCTest

@testable import ZephyrCore

// Focused coverage for executable UCS and PLAN commands:
// discoverability, option parsing, frame math, previous-UCS stack,
// three-point acceptance rules, and PLAN rotation mapping.

@MainActor
final class UCSCommandTests: XCTestCase {

    private func makeProcessor() -> CADCommandProcessor {
        CADCommandProcessor()
    }

    private func makeDocument() -> CADDocument {
        CADDocument()
    }

    // MARK: - Discoverability

    func testUCSAndPlanAreDiscoverableByTyping() {
        let processor = makeProcessor()
        XCTAssertEqual(
            processor.matchCommands(input: "UCS").first?.descriptor.canonicalName,
            "UCS")
        XCTAssertEqual(
            processor.matchCommands(input: "PLAN").first?.descriptor.canonicalName,
            "PLAN")
    }

    func testUCSDescriptorDocumentsPlanarOptions() {
        let processor = makeProcessor()
        let match = processor.matchCommands(input: "UCS").first
        XCTAssertEqual(match?.descriptor.canonicalName, "UCS")
        XCTAssertTrue(match?.descriptor.syntax.contains("Prev") ?? false)
    }

    func testBareCommandsOpenPromptedSessions() {
        // Space == Enter: a bare one-shot command opens its prompted session
        // (one token per submit) instead of waiting for same-line arguments.
        let processor = makeProcessor()
        processor.executeCommand("UNDO")
        XCTAssertEqual(processor.pendingPromptCommand, "UNDO")
        XCTAssertTrue(processor.commandLineActive)
        processor.executeCommand("")
        XCTAssertNil(processor.pendingPromptCommand)
        processor.executeCommand("LAYERSORT")
        XCTAssertEqual(processor.pendingPromptCommand, "LAYERSORT")
        XCTAssertTrue(processor.commandLineActive)
        // UCS/PLAN descriptors stay discoverable with their option syntax.
        XCTAssertTrue(
            processor.matchCommands(input: "UCS").first?.descriptor.syntax.contains("Prev") ?? false)
        XCTAssertEqual(
            processor.matchCommands(input: "PLAN").first?.descriptor.canonicalName, "PLAN")
    }

    func testUCSInteractiveOptionChain() {
        // The exact submit sequence the command line now sends for the
        // AutoCAD flow: UCS -> Enter, z -> Enter, 45 -> Enter.
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "Z", document: document, cameraRotation: 0, processor: processor),
            .continue)
        XCTAssertEqual(command.phase, .zAngle)
        XCTAssertEqual(
            command.handleCommandText(
                "45", document: document, cameraRotation: 0, processor: processor),
            .finished)
        XCTAssertEqual(
            document.ucsState.definition.angle,
            2 * Double.pi - Double.pi / 4, accuracy: 1e-12)
    }

    func testPlanInteractiveOptionChain() {
        // PLAN -> Enter (prompt) -> Enter (accept <Current>) levels the view.
        let processor = makeProcessor()
        let command = PlanCommand()
        var applied: Double?
        var zoomed = false
        XCTAssertEqual(
            command.handleCommandText(
                "",
                ucsAngle: Double.pi / 6,
                pushViewState: {},
                applyRotation: { applied = $0 },
                zoomToExtents: { zoomed = true },
                processor: processor),
            .finished)
        XCTAssertEqual(applied ?? -1, Double.pi / 6, accuracy: 1e-12)
        XCTAssertTrue(zoomed)
    }

    func testPlanDescriptorOffersCurrentAsDefault() {
        let processor = makeProcessor()
        let match = processor.matchCommands(input: "PLAN").first
        XCTAssertEqual(match?.descriptor.canonicalName, "PLAN")
        XCTAssertTrue(match?.descriptor.syntax.contains("<Current>") ?? false)
    }

    // MARK: - UCS option flow (headless, no SDL engine)

    func testBareUCSInvocationShowsOptionsPrompt() {
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(command.phase, .options)
        XCTAssertTrue(processor.commandLineActive)
        XCTAssertTrue(processor.commandPrompt?.contains("Prev") ?? false)
    }

    func testBareEnterDefaultsToWorld() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "", document: document, cameraRotation: 1.0, processor: processor),
            .finished)
        XCTAssertEqual(document.ucsState.definition.angle, 0, accuracy: 1e-12)
        XCTAssertEqual(document.ucsState.name, "*WORLD*")
    }

    func testUCSZRotatesFromCurrentFrameAsDelta() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "Z 30", document: document, cameraRotation: 0, processor: processor),
            .finished)
        // AutoCAD LT parity: this engine stores world Y pointing down the
        // screen, so a typed visual +30 deg CCW rotation is canonical -30 deg.
        XCTAssertEqual(
            document.ucsState.definition.angle,
            2 * Double.pi - Double.pi / 6, accuracy: 1e-12)
        XCTAssertEqual(document.ucsState.name, "UNNAMED")
        XCTAssertEqual(document.ucsState.previous.count, 1)
    }

    func testUCSZPositiveMatchesAutoCADPlanDirection() {
        // UCS Z 45 must put the UCS X axis up-right on screen (like LT),
        // and PLAN (rotation = ucsAngle) must level it screen-horizontal.
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "Z 45", document: document, cameraRotation: 0, processor: processor),
            .finished)
        let angle = document.ucsState.definition.angle
        XCTAssertEqual(angle, 2 * Double.pi - Double.pi / 4, accuracy: 1e-12)
        // Up-right on a Y-down screen: negative world Y.
        XCTAssertLessThan(document.ucsState.definition.xAxis.y, 0)
        // PLAN levels the frame: worldToScreen maps origin and origin+X
        // to the same screen Y with the endpoint to the right.
        let rotation = angle
        let cam = CameraTransform(
            camX: 0, camY: 0, camZoom: 1,
            camSin: sin(-rotation), camCos: cos(-rotation),
            screenCenterX: 400, screenCenterY: 300)
        let origin = document.ucsState.definition.origin
        let xAxis = document.ucsState.definition.xAxis
        let s0 = EngineCameraManager.worldToScreen(worldX: origin.x, worldY: origin.y, cam: cam)
        let s1 = EngineCameraManager.worldToScreen(
            worldX: origin.x + xAxis.x, worldY: origin.y + xAxis.y, cam: cam)
        XCTAssertEqual(Double(s1.y), Double(s0.y), accuracy: 1e-5)
        XCTAssertGreaterThan(s1.x, s0.x)
    }

    func testUCSZIgnoresBaseAndAppliesDirection() {
        // Deltas never take ANGBASE; ANGDIR=clockwise negates.
        XCTAssertEqual(
            UCSCommand.parseOption("Z -45")?.remainder,
            "-45")
    }

    func testUCSInvalidOptionReprompts() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "BANANA", document: document, cameraRotation: 0, processor: processor),
            .continue)
        XCTAssertEqual(command.phase, .options)
        XCTAssertEqual(document.ucsState.definition, .identity)
    }

    func testUCSOriginMovesFrameInline() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "ORIGIN 10,20", document: document, cameraRotation: 0, processor: processor),
            .finished)
        XCTAssertEqual(document.ucsState.definition.origin.x, 10, accuracy: 1e-9)
        XCTAssertEqual(document.ucsState.definition.origin.y, 20, accuracy: 1e-9)
        XCTAssertEqual(document.ucsState.definition.angle, 0, accuracy: 1e-12)
    }

    func testUCSPreviousRestoresFrame() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        _ = command.handleCommandText(
            "Z 30", document: document, cameraRotation: 0, processor: processor)
        _ = command.handleCommandText(
            "WORLD", document: document, cameraRotation: 0, processor: processor)
        XCTAssertEqual(document.ucsState.name, "*WORLD*")
        _ = command.handleCommandText(
            "PREV", document: document, cameraRotation: 0, processor: processor)
        XCTAssertEqual(
            document.ucsState.definition.angle,
            2 * Double.pi - Double.pi / 6, accuracy: 1e-12)
    }

    func testUCSPreviousStackIsBounded() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        for index in 0..<12 {
            _ = command.handleCommandText(
                "Z \(index)", document: document, cameraRotation: 0, processor: processor)
        }
        XCTAssertEqual(document.ucsState.previous.count, UCSViewState.maxPreviousDepth)
    }

    func testUCSViewAdoptsCameraRotation() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "VIEW", document: document, cameraRotation: 0.5, processor: processor),
            .finished)
        XCTAssertEqual(document.ucsState.definition.angle, 0.5, accuracy: 1e-12)
        // View keeps the current origin.
        XCTAssertEqual(document.ucsState.definition.origin.x, 0, accuracy: 1e-12)
    }

    // MARK: - Three-point flow (mouse picks are WCS)

    func testThreePointMouseFlowBuildsFrame() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "3", document: document, cameraRotation: 0, processor: processor),
            .continue)
        XCTAssertEqual(
            command.handleMouseClick(
                worldX: 10, worldY: 20, document: document, processor: processor),
            .continue)
        XCTAssertEqual(
            processor.commandPrompt,
            "Specify point on positive portion of X-axis:")
        XCTAssertEqual(
            command.handleMouseClick(
                worldX: 30, worldY: 20, document: document, processor: processor),
            .continue)
        XCTAssertEqual(
            processor.commandPrompt,
            "Specify point on positive-Y portion of the UCS XY plane:")
        XCTAssertEqual(
            command.handleMouseClick(
                worldX: 10, worldY: 40, document: document, processor: processor),
            .finished)
        XCTAssertEqual(document.ucsState.definition.origin.x, 10, accuracy: 1e-9)
        XCTAssertEqual(document.ucsState.definition.origin.y, 20, accuracy: 1e-9)
        XCTAssertEqual(document.ucsState.definition.angle, 0, accuracy: 1e-12)
    }

    func testThreePointRejectsNegativeSidePick() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        _ = command.handleCommandText(
            "3", document: document, cameraRotation: 0, processor: processor)
        _ = command.handleMouseClick(
            worldX: 0, worldY: 0, document: document, processor: processor)
        _ = command.handleMouseClick(
            worldX: 10, worldY: 0, document: document, processor: processor)
        // Below the X axis: rejected, still waiting for a Y-side point.
        XCTAssertEqual(
            command.handleMouseClick(
                worldX: 5, worldY: -5, document: document, processor: processor),
            .continue)
        XCTAssertEqual(document.ucsState.definition, .identity)
        XCTAssertTrue(processor.commandPrompt?.hasPrefix("Point must be on positive-Y side") ?? false)
    }

    // MARK: - PLAN

    func testPlanSelectionMapping() {
        XCTAssertEqual(PlanCommand.selection(for: ""), .current)
        XCTAssertEqual(PlanCommand.selection(for: "PLAN"), .current)
        XCTAssertEqual(PlanCommand.selection(for: "PLAN CURRENT"), .current)
        XCTAssertEqual(PlanCommand.selection(for: "WORLD"), .world)
        XCTAssertEqual(PlanCommand.selection(for: "PLAN W"), .world)
        XCTAssertEqual(PlanCommand.selection(for: "UCS"), .namedUnsupported)
        XCTAssertEqual(PlanCommand.selection(for: "BANANA"), .invalid)
    }

    func testPlanCurrentUsesUCSAngle() {
        let processor = makeProcessor()
        let command = PlanCommand()
        var pushed = false
        var applied: Double?
        var zoomed = false
        XCTAssertEqual(
            command.handleCommandText(
                "CURRENT",
                ucsAngle: Double.pi / 6,
                pushViewState: { pushed = true },
                applyRotation: { applied = $0 },
                zoomToExtents: { zoomed = true },
                processor: processor),
            .finished)
        XCTAssertTrue(pushed)
        XCTAssertEqual(applied ?? -1, Double.pi / 6, accuracy: 1e-12)
        XCTAssertTrue(zoomed)
    }

    func testPlanWorldResetsRotation() {
        let processor = makeProcessor()
        let command = PlanCommand()
        var applied: Double?
        XCTAssertEqual(
            command.handleCommandText(
                "PLAN WORLD",
                ucsAngle: Double.pi / 6,
                pushViewState: {},
                applyRotation: { applied = $0 },
                zoomToExtents: {},
                processor: processor),
            .finished)
        XCTAssertEqual(applied ?? -1, 0, accuracy: 1e-12)
    }

    func testBareEnterDefaultsPerPrompt() {
        XCTAssertEqual(UCSCommand.defaultInput(for: .options), "")
        XCTAssertEqual(UCSCommand.defaultInput(for: .origin), "0,0,0")
        XCTAssertEqual(UCSCommand.defaultInput(for: .threePointOrigin), "")
        XCTAssertEqual(UCSCommand.defaultInput(for: .zAngle), "0")
    }

    func testBareEnterAcceptsOriginDefault() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "ORIGIN", document: document, cameraRotation: 0, processor: processor),
            .continue)
        XCTAssertEqual(
            command.handleCommandText(
                "", document: document, cameraRotation: 0, processor: processor),
            .finished)
        XCTAssertEqual(document.ucsState.name, "UNNAMED")
    }

    func testBareEnterAcceptsZeroRotation() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "Z", document: document, cameraRotation: 0, processor: processor),
            .continue)
        XCTAssertEqual(
            command.handleCommandText(
                "", document: document, cameraRotation: 0, processor: processor),
            .finished)
        XCTAssertEqual(document.ucsState.definition.angle, 0, accuracy: 1e-12)
    }

    func testBareEnterStillRequiresThreePointPicks() {
        let document = makeDocument()
        let processor = makeProcessor()
        let command = UCSCommand()
        command.start(processor: processor)
        XCTAssertEqual(
            command.handleCommandText(
                "3", document: document, cameraRotation: 0, processor: processor),
            .continue)
        XCTAssertEqual(
            command.handleCommandText(
                "", document: document, cameraRotation: 0, processor: processor),
            .continue)
        XCTAssertEqual(document.ucsState.definition, .identity)
    }

    func testPlanNamedUCSReportsUnsupported() {
        let processor = makeProcessor()
        let command = PlanCommand()
        var applied = false
        XCTAssertEqual(
            command.handleCommandText(
                "UCS",
                ucsAngle: 0,
                pushViewState: {},
                applyRotation: { _ in applied = true },
                zoomToExtents: {},
                processor: processor),
            .finished)
        XCTAssertFalse(applied)
    }

    // MARK: - Dispatch safety without an engine

    func testUCSAndPlanDispatchWithoutEngine() {
        let processor = makeProcessor()
        processor.executeCommand("UCS")
        XCTAssertNil(processor.commandPrompt)
        processor.executeCommand("PLAN")
        XCTAssertNil(processor.commandPrompt)
        processor.executeCommand("UCS Z 30")
        XCTAssertNil(processor.commandPrompt)
        processor.executeCommand("PLAN WORLD")
        XCTAssertNil(processor.commandPrompt)
    }
}

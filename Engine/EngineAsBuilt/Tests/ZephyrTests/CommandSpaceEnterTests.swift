import XCTest
@testable import ZephyrCore

/// Space == Enter contract: one token per submit, prompted sessions for
/// arguments, replay for pasted/programmatic multi-token input, and the
/// THEME sub-command. All flows here run headless (no engine); engine-only
/// completion paths degrade to a clean clear.
@MainActor
final class CommandSpaceEnterTests: XCTestCase {

    private func makeProcessor() -> CADCommandProcessor {
        CADCommandProcessor()
    }

    // MARK: - Replay tokenization

    func testReplaySplitsTokensQuoteAware() {
        XCTAssertEqual(
            CADCommandProcessor.splitSheetSetArgs(#"NEWSHEETSET "TI Set" C:\s\m.dst"#),
            ["NEWSHEETSET", "TI Set", #"C:\s\m.dst"#])
        XCTAssertEqual(
            CADCommandProcessor.splitSheetSetArgs("UCS Z 45"),
            ["UCS", "Z", "45"])
        XCTAssertEqual(CADCommandProcessor.splitSheetSetArgs("  "), [])
    }

    func testMultiTokenReplayReachesPromptedSession() {
        // "LAYERSORT COLOR DESC" replays as three submits: bare opens the
        // pending session, COLOR answers the key prompt, DESC the direction.
        let saved = LayerSortSettings.load()
        defer { saved.save() }
        LayerSortSettings(key: .name, ascending: true).save()

        let processor = makeProcessor()
        processor.executeCommand("LAYERSORT COLOR DESC")
        XCTAssertEqual(
            LayerSortSettings.load(),
            LayerSortSettings(key: .color, ascending: false))
        XCTAssertNil(processor.pendingPromptCommand)
        // Repeat-last stores the command name only, never the arguments.
        XCTAssertEqual(processor.lastExecutedCommand, "LAYERSORT")
    }

    func testQuotedReplayPreservesBlanks() {
        // A quoted multi-blank operand survives replay as one submit and
        // lands whole in the pending session.
        let processor = makeProcessor()
        processor.executeCommand(#"NEWSHEETSET "TI Set""#)
        XCTAssertEqual(processor.pendingPromptCommand, "NEWSHEETSET")
        XCTAssertEqual(processor.pendingPromptCollected, ["TI Set"])
    }

    // MARK: - Bare commands open sessions

    func testBareOneShotsOpenPendingSessions() {
        for (bare, canonical) in [
            ("UNDO", "UNDO"), ("U", "UNDO"), ("REDO", "REDO"),
            ("RIBBONMODE", "RIBBONMODE"), ("VPRESIZE", "VPRESIZE"),
            ("VPORTS", "VPORTS"), ("DXFVERSION", "DXFVERSION"),
            ("LANGUAGE", "LANGUAGE"), ("SNAPANG", "SNAPANG"),
            ("POLARANG", "POLARANG"), ("SPLINETESS", "SPLINETESS"),
            ("SET-BACKGROUND", "SET-BACKGROUND"), ("AUTOCONTRAST", "AUTOCONTRAST"),
            ("SIMPLIFY", "SIMPLIFY"), ("SIMPLIFYPOLY", "SIMPLIFYPOLY"),
            ("LASSO", "LASSO"), ("SETUISCALE", "SETUISCALE"),
            ("UNITS", "UNITS"), ("SETTINGSGRIPMAX", "SETTINGSGRIPMAX"),
            ("SETTINGSGRIPOBJECTMAX", "SETTINGSGRIPOBJECTMAX"),
            ("SELECTIONPREVIEWLIMIT", "SELECTIONPREVIEWLIMIT"),
            ("LAYFRZ", "LAYFRZ"), ("LAYDEL", "LAYDEL"),
            ("LAYWALK", "LAYWALK"), ("COPYTOLAYER", "COPYTOLAYER"),
            ("VPLAYER", "VPLAYER"), ("MVIEW", "MVIEW"), ("VIEW", "VIEW"),
            ("-LAYER", "-LAYER"), ("LAYERSTATE", "LAYERSTATE"),
            ("-DIMSTYLE", "-DIMSTYLE"), ("LAYMRG", "LAYMRG"),
            ("GRIDSPACING", "GRIDSPACING"), ("GRIDORIGIN", "GRIDORIGIN"),
            ("-HATCH", "-HATCH"), ("SCALELISTEDIT", "SCALELISTEDIT"),
            ("OPENSHEETSET", "OPENSHEETSET"), ("NEWSHEETSET", "NEWSHEETSET"),
            ("-PUBLISHSET", "-PUBLISHSET"), ("-TRANSMITSET", "-TRANSMITSET"),
            ("+PUBLISH", "+PUBLISH"), ("-EXPORTPDF", "-EXPORTPDF"),
        ] {
            let processor = makeProcessor()
            processor.executeCommand(bare)
            XCTAssertEqual(
                processor.pendingPromptCommand, canonical,
                "bare \(bare) must open a pending session")
            XCTAssertTrue(processor.commandLineActive)
        }
    }

    func testNamePromptsKeepSpaceLiteral() {
        // `.line` prompts accept blanks: Space must not submit.
        let processor = makeProcessor()
        processor.executeCommand("LAYFRZ")
        XCTAssertEqual(processor.promptInputKind, .line)
        processor.executeCommand("BLOCK")
        // BLOCK with no selection clears (nothing to name); the prompt kind
        // resets with the command.
        XCTAssertEqual(processor.promptInputKind, .token)
    }

    func testPendingEmptyAcceptsDefault() {
        // Bare UNDO + bare Enter performs one step (legacy bare behaviour)
        // and finishes the session.
        let processor = makeProcessor()
        processor.executeCommand("UNDO")
        XCTAssertEqual(processor.pendingPromptCommand, "UNDO")
        processor.executeCommand("")
        XCTAssertNil(processor.pendingPromptCommand)
        XCTAssertFalse(processor.commandLineActive)
    }

    func testThrottleOfUnknownPendingArg() {
        // An invalid LAYERSORT key leaves settings unchanged and finishes.
        let saved = LayerSortSettings.load()
        defer { saved.save() }
        LayerSortSettings(key: .name, ascending: true).save()

        let processor = makeProcessor()
        processor.executeCommand("LAYERSORT BOGUS")
        XCTAssertEqual(LayerSortSettings.load(), LayerSortSettings(key: .name, ascending: true))
        XCTAssertNil(processor.pendingPromptCommand)
    }

    // MARK: - THEME sub-command

    func testThemeResolve() {
        XCTAssertEqual(ThemeCommand.resolve(""), .useDefault)
        XCTAssertEqual(ThemeCommand.resolve("?"), .list)
        XCTAssertEqual(ThemeCommand.resolve("NEXT"), .next)
        XCTAssertEqual(ThemeCommand.resolve("n"), .next)
        XCTAssertEqual(ThemeCommand.resolve("LIGHT"), .named("LIGHT"))
        XCTAssertEqual(ThemeCommand.resolve("light"), .named("LIGHT"))
        XCTAssertEqual(ThemeCommand.resolve("mocha"), .named("MOCHA"))
        // Unique prefix resolves; shared prefix is ambiguous.
        XCTAssertEqual(ThemeCommand.resolve("MOCH"), .named("MOCHA"))
        if case .ambiguous(let shorts) = ThemeCommand.resolve("L") {
            XCTAssertTrue(shorts.contains("LIGHT"))
            XCTAssertTrue(shorts.contains("LATTE"))
        } else {
            XCTFail("expected 'L' to be ambiguous")
        }
        XCTAssertEqual(ThemeCommand.resolve("NOPE"), .unknown("NOPE"))
    }

    func testThemeHeadlessFlow() {
        let processor = makeProcessor()
        let command = ThemeCommand()
        var current = "DARK"
        let apply: (String) -> Bool = {
            current = $0
            return true
        }
        // Bare submit accepts the default unchanged.
        XCTAssertEqual(
            command.handleCommandText(
                "", currentThemeName: current, applyThemeNamed: apply,
                appliedThemeName: { current }, cycleTheme: { "LIGHT" },
                processor: processor),
            .finished)
        XCTAssertEqual(current, "DARK")
        // A theme name applies it.
        XCTAssertEqual(
            command.handleCommandText(
                "LIGHT", currentThemeName: current, applyThemeNamed: apply,
                appliedThemeName: { current }, cycleTheme: { current },
                processor: processor),
            .finished)
        XCTAssertEqual(current, "LIGHT")
        // NEXT cycles.
        XCTAssertEqual(
            command.handleCommandText(
                "NEXT", currentThemeName: current, applyThemeNamed: apply,
                appliedThemeName: { current }, cycleTheme: { "LATTE" },
                processor: processor),
            .finished)
        // Unknown and ambiguous re-prompt instead of clearing.
        XCTAssertEqual(
            command.handleCommandText(
                "NOPE", currentThemeName: current, applyThemeNamed: apply,
                appliedThemeName: { current }, cycleTheme: { current },
                processor: processor),
            .continue)
        XCTAssertEqual(
            command.handleCommandText(
                "L", currentThemeName: current, applyThemeNamed: apply,
                appliedThemeName: { current }, cycleTheme: { current },
                processor: processor),
            .continue)
        XCTAssertEqual(current, "LIGHT")
    }

    func testEmptyBufferEnterTakesHighlightedOption() {
        let options = [
            FeatureCommandTextOption(value: "DARK", title: "Dark", aliases: [], description: ""),
            FeatureCommandTextOption(value: "LIGHT", title: "Light", aliases: [], description: ""),
        ]
        // Arrows + Enter with nothing typed submits the highlight.
        XCTAssertEqual(
            CADCommandProcessor.featureSubmitText(buffer: "", options: options, selectedIndex: 1),
            "LIGHT")
        XCTAssertEqual(
            CADCommandProcessor.featureSubmitText(buffer: "", options: options, selectedIndex: 0),
            "DARK")
        // No options, or a stale index: the buffer goes through untouched.
        XCTAssertEqual(
            CADCommandProcessor.featureSubmitText(buffer: "", options: [], selectedIndex: 0),
            "")
        XCTAssertEqual(
            CADCommandProcessor.featureSubmitText(buffer: "", options: options, selectedIndex: 9),
            "")
        // Typed text always wins, so numbers and custom strings survive.
        XCTAssertEqual(
            CADCommandProcessor.featureSubmitText(buffer: "MOCH", options: options, selectedIndex: 1),
            "MOCH")
        XCTAssertEqual(
            CADCommandProcessor.featureSubmitText(buffer: "45", options: options, selectedIndex: 0),
            "45")
    }

    func testThemePromptTextListsOptions() {
        let text = ThemeCommand.promptText(currentName: "Dark")
        XCTAssertTrue(text.contains("LIGHT"))
        XCTAssertTrue(text.uppercased().contains("NEXT"))
        XCTAssertTrue(text.contains("<DARK>"))
        XCTAssertTrue(ThemeCommand.listLine().contains("Latte"))
    }

    // MARK: - No spaced names (parity invariant)

    func testNoCommandNameOrAliasContainsSpace() {
        for desc in CommandDescriptor.allCommands {
            for match in desc.allMatches {
                XCTAssertFalse(
                    match.contains(where: { $0.isWhitespace }),
                    "\(desc.canonicalName) has a spaced match '\(match)'")
            }
        }
    }

    func testSpacedAliasIsRejected() {
        let processor = makeProcessor()
        let warning = processor.registerUserAlias("MY CMD", for: "LINE")
        XCTAssertNotNil(warning)
        XCTAssertEqual(processor.resolveUserAlias("MY CMD"), "MY CMD")
    }

    func testPgpLoaderSkipsSpacedAlias() {
        let (aliases, warnings) = PGPAliasLoader.parse(contents: "ZZ QQ,LINE")
        XCTAssertTrue(aliases.isEmpty)
        XCTAssertEqual(warnings.count, 1)
        let (ok, _) = PGPAliasLoader.parse(contents: "ZZ,LINE")
        XCTAssertEqual(ok.count, 1)
    }
}

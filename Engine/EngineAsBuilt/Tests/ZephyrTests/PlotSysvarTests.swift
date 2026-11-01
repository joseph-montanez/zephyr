import XCTest
@testable import ZephyrCore
@testable import ZephyrLisp

/// Phase 2 step 11: plot sysvars (`PLOTOFFSET`, `PAPERUPDATE`, `PLOTROTMODE`,
/// `PLOTTRANSPARENCYOVERRIDE`, `PSTYLEMODE`, `CMDDIA`) + persistence.
final class PlotSysvarTests: XCTestCase {

    @MainActor
    private func makeHost() -> (LispCADHost, LispEnvironment) {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.output = { _ in }
        return (host, LispEnvironment())
    }

    @MainActor
    private func eval(_ source: String, host: LispCADHost, env: inout LispEnvironment) async throws -> LispValue {
        let forms = try LispReader().readAll(source)
        return try await LispEvaluator().run(forms, env: &env, host: host)
    }

    // MARK: - Defaults and validation

    @MainActor
    func testPlotRegistryDefaultsAndValidation() async throws {
        let (host, _) = makeHost()
        var env = LispEnvironment()
        let vOffset0 = try await self.eval(#"(getvar "PLOTOFFSET")"#, host: host, env: &env)
        let vUpdate0 = try await self.eval(#"(getvar "PAPERUPDATE")"#, host: host, env: &env)
        let vRot0 = try await self.eval(#"(getvar "PLOTROTMODE")"#, host: host, env: &env)
        let vTrans0 = try await self.eval(#"(getvar "PLOTTRANSPARENCYOVERRIDE")"#, host: host, env: &env)
        let vCmd = try await self.eval(#"(getvar "CMDDIA")"#, host: host, env: &env)
        let vPstyle = try await self.eval(#"(getvar "PSTYLEMODE")"#, host: host, env: &env)
        XCTAssertEqual(vOffset0, .int(0))
        XCTAssertEqual(vUpdate0, .int(0))
        XCTAssertEqual(vRot0, .int(1))
        XCTAssertEqual(vTrans0, .int(1))
        XCTAssertEqual(vCmd, .int(1))
        XCTAssertEqual(vPstyle, .int(1))

        _ = try await self.eval(#"(setvar "PLOTOFFSET" 1)"#, host: host, env: &env)
        let vOffset1 = try await self.eval(#"(getvar "PLOTOFFSET")"#, host: host, env: &env)
        XCTAssertEqual(vOffset1, .int(1))
        _ = try await self.eval(#"(setvar "PAPERUPDATE" 1)"#, host: host, env: &env)
        let vUpdate1 = try await self.eval(#"(getvar "PAPERUPDATE")"#, host: host, env: &env)
        XCTAssertEqual(vUpdate1, .int(1))
        _ = try await self.eval(#"(setvar "PLOTROTMODE" 2)"#, host: host, env: &env)
        let vRot2 = try await self.eval(#"(getvar "PLOTROTMODE")"#, host: host, env: &env)
        XCTAssertEqual(vRot2, .int(2))
        _ = try await self.eval(#"(setvar "PLOTTRANSPARENCYOVERRIDE" 0)"#, host: host, env: &env)
        let vTrans0b = try await self.eval(#"(getvar "PLOTTRANSPARENCYOVERRIDE")"#, host: host, env: &env)
        XCTAssertEqual(vTrans0b, .int(0))

        // Out-of-range writes are rejected; values stick.
        _ = try? await self.eval(#"(setvar "PLOTOFFSET" 5)"#, host: host, env: &env)
        let vOffsetStuck = try await self.eval(#"(getvar "PLOTOFFSET")"#, host: host, env: &env)
        XCTAssertEqual(vOffsetStuck, .int(1))
        _ = try? await self.eval(#"(setvar "PLOTTRANSPARENCYOVERRIDE" 9)"#, host: host, env: &env)
        let vTransStuck = try await self.eval(#"(getvar "PLOTTRANSPARENCYOVERRIDE")"#, host: host, env: &env)
        XCTAssertEqual(vTransStuck, .int(0))
        // PSTYLEMODE is read-only.
        _ = try? await self.eval(#"(setvar "PSTYLEMODE" 0)"#, host: host, env: &env)
        let vPstyleStuck = try await self.eval(#"(getvar "PSTYLEMODE")"#, host: host, env: &env)
        XCTAssertEqual(vPstyleStuck, .int(1))
    }

    // MARK: - PSTYLEMODE follows the document

    @MainActor
    func testPstyleModeRoundTripsSnapshot() async throws {
        let doc = CADDocument()
        XCTAssertEqual(doc.pstyleMode, 1)
        doc.pstyleMode = 0
        let snap = doc.snapshot()
        XCTAssertEqual(snap.pstyleMode, 0)
        let doc2 = CADDocument()
        doc2.restore(from: snap)
        XCTAssertEqual(doc2.pstyleMode, 0)
        // setvar rejects writes (read-only).
        let (host, _) = makeHost()
        var env = LispEnvironment()
        host.document.pstyleMode = 0
        let pstyle = try await eval(#"(getvar "PSTYLEMODE")"#, host: host, env: &env)
        XCTAssertEqual(pstyle, .int(0))
    }

    // MARK: - AutoLISP surface (step 29)

    @MainActor
    func testCommandSurfaceSafeHeadless() async throws {
        // `(command ...)` never routes through the interactive registry: the
        // audited scripted dispatcher fails closed on interactive-only
        // commands (tab-scoped setups, modal dialogs, OS folders). They must
        // reject loudly, never crash, headless or not.
        let (host, _) = makeHost()
        var env = LispEnvironment()
        for name in ["PAGESETUP", "PLOT", "PREVIEW", "PSETUPIN",
                       "-PAGESETUP", "-PLOT", "-PSETUPIN",
                       "SCALELISTEDIT", "STYLESMANAGER", "PLOTTERMANAGER"] {
            do {
                _ = try await eval(#"(command "\#(name)")"#, host: host, env: &env)
                XCTFail("\(name) should reject from Lisp (interactive-only)")
            } catch {
                XCTAssertTrue("\(error)".contains("not supported from Lisp"), name)
            }
        }
        // getvar coverage for the plot sysvars (LispTableTests style).
        let vars = ["PLOTOFFSET", "PAPERUPDATE", "PLOTROTMODE",
                      "PLOTTRANSPARENCYOVERRIDE", "PSTYLEMODE", "CMDDIA"]
        for name in vars {
            let value = try await eval(#"(getvar "\#(name)")"#, host: host, env: &env)
            if case .int = value { } else {
                XCTFail("\(name) should be an int, got \(value)")
            }
        }
    }

    // MARK: - UserSettings persistence

    func testPlotRegistryPersistsInUserSettings() throws {
        var settings = UserSettings.default
        settings.plotOffset = 1
        settings.paperUpdate = 1
        settings.plotRotMode = 2
        settings.plotTransparencyOverride = 0
        settings.displayPageSetupForNewLayouts = true
        let data = try JSONEncoder().encode(settings)
        let reloaded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertEqual(reloaded.plotOffset, 1)
        XCTAssertEqual(reloaded.paperUpdate, 1)
        XCTAssertEqual(reloaded.plotRotMode, 2)
        XCTAssertEqual(reloaded.plotTransparencyOverride, 0)
        XCTAssertTrue(reloaded.displayPageSetupForNewLayouts)
        // Old files without the keys still decode.
        let legacy = try JSONDecoder().decode(
            UserSettings.self,
            from: #"{"isDarkTheme":true}"#.data(using: .utf8)!)
        XCTAssertEqual(legacy.plotOffset, 0)
        XCTAssertEqual(legacy.plotRotMode, 1)
        XCTAssertEqual(legacy.plotTransparencyOverride, 1)
        XCTAssertFalse(legacy.displayPageSetupForNewLayouts)
    }

    // MARK: - Registry snapshot helpers

    func testPlotRegistrySnapshotRoundTrip() {
        let vars = LispVarStore()
        vars.applyPlotRegistry(offset: 1, update: 1, rotMode: 2, transparency: 0)
        let snap = vars.plotRegistrySnapshot()
        XCTAssertEqual(snap.0, 1)
        XCTAssertEqual(snap.1, 1)
        XCTAssertEqual(snap.2, 2)
        XCTAssertEqual(snap.3, 0)
        // Out-of-range seeds clamp to defaults.
        vars.applyPlotRegistry(offset: 9, update: 9, rotMode: 9, transparency: 9)
        let clamped = vars.plotRegistrySnapshot()
        XCTAssertEqual(clamped.0, 0)
        XCTAssertEqual(clamped.1, 0)
        XCTAssertEqual(clamped.2, 1)
        XCTAssertEqual(clamped.3, 1)
    }
}

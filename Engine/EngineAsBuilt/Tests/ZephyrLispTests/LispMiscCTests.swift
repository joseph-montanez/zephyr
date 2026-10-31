import XCTest
@testable import ZephyrLisp

/// Wave-C portable miscellany.
final class LispMiscCTests: XCTestCase {

    override func tearDown() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("ZephyrLispCfg.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testCfgRoundTrip() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let missing = try await evalString(
            "(getcfg \"AppData/Nope\")", env: &env, host: host)
        XCTAssertEqual(missing, .nilValue)
        let set = try await evalString(
            "(setcfg \"AppData/Flag\" \"On\")", env: &env, host: host)
        XCTAssertEqual(set, .string("On"))
        let got = try await evalString(
            "(getcfg \"AppData/Flag\")", env: &env, host: host)
        XCTAssertEqual(got, .string("On"))
        _ = host
    }

    func testGetcnameAndMem() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let name = try await evalString("(getcname \"_LINE\")", env: &env, host: host)
        XCTAssertEqual(name, .string("LINE"))
        let plain = try await evalString("(getcname \"CIRCLE\")", env: &env, host: host)
        XCTAssertEqual(plain, .string("CIRCLE"))
        let result = try await evalString("(mem)", env: &env, host: host)
        XCTAssertEqual(result, .nilValue)
        XCTAssertTrue(host.output.contains("physical memory:"), host.output)
        _ = host
    }

    func testFunhelpAndToggles() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let first = try await evalString(
            "(setfunhelp \"C:TEST\" \"a.chm\" \"T1\")", env: &env, host: host)
        XCTAssertEqual(first, .nilValue)
        let second = try await evalString(
            "(setfunhelp \"C:TEST\" \"a.chm\" \"T2\")", env: &env, host: host)
        XCTAssertEqual(second, .string("T1"))
        XCTAssertEqual(env.funHelp["C:TEST"]?.topic, "T2")
        let disabled = try await evalString(
            "(acdimenableupdate nil)", env: &env, host: host)
        XCTAssertEqual(disabled, .nilValue)
        XCTAssertFalse(env.dimUpdateEnabled)
        let versioned = try await evalString(
            "(initcommandversion 2)", env: &env, host: host)
        XCTAssertEqual(versioned, .t)
        XCTAssertEqual(env.commandVersion, 2)
        _ = host
    }

    func testLayerpAndScales() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let enabled = try await evalString("(acet-layerp-mode T)", env: &env, host: host)
        XCTAssertEqual(enabled, .t)
        let marked = try await evalString("(acet-layerp-mark T)", env: &env, host: host)
        XCTAssertEqual(marked, .t)
        XCTAssertEqual(env.layerpDepth, 1)
        let unmarked = try await evalString("(acet-layerp-mark nil)", env: &env, host: host)
        XCTAssertEqual(unmarked, .t)
        XCTAssertEqual(env.layerpDepth, 0)
        let toPs = try await evalString("(acet-ms-to-ps 10.0)", env: &env, host: host)
        XCTAssertEqual(toPs, .real(10.0))
        let toMs = try await evalString("(acet-ps-to-ms 1.5)", env: &env, host: host)
        XCTAssertEqual(toMs, .real(1.5))
        _ = try await evalString("(initdia 1)", env: &env, host: host)
        XCTAssertEqual(env.initDiaFlag, 1)
        _ = host
    }

    func testHelpReturnsNil() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let helped = try await evalString(
            "(help \"f.chm\" \"T\")", env: &env, host: host)
        XCTAssertEqual(helped, .nilValue)
        let dlg = try await evalString(
            "(acad_helpdlg \"f.chm\" \"T\")", env: &env, host: host)
        XCTAssertEqual(dlg, .nilValue)
        _ = host
    }

    func testStartappTrueReturnsPid() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        // NB: the launched program must terminate on its own. A bare
        // interactive shell (e.g. plain "cmd.exe") never exits and hangs
        // the runner, so launch with an immediate-exit command instead.
        #if os(Windows)
            let launched = try await evalString(
                "(startapp \"cmd.exe\" \"/c exit\")", env: &env, host: host)
        #else
            let launched = try await evalString(
                "(startapp \"/bin/true\")", env: &env, host: host)
        #endif
        guard case let .int(pid) = launched else {
            return XCTFail("startapp should return a pid, got \(launched)")
        }
        XCTAssertGreaterThan(pid, 0)
        let failed = try await evalString(
            "(startapp \"/no/such/program-zephyr\")", env: &env, host: host)
        #if os(Windows)
            XCTAssertEqual(failed, .nilValue)
        #else
            // /bin/sh itself launches even when the target is missing
            // (exec fails inside the child); a pid is still returned.
            guard case let .int(childPid) = failed else {
                return XCTFail("expected pid, got \(failed)")
            }
            XCTAssertGreaterThan(childPid, 0)
        #endif
        _ = host
    }
}

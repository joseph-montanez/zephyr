import XCTest
@testable import ZephyrLisp

final class LispBuiltinLogicTests: XCTestCase {
    func testEq() async throws {
        try await assertEval("(eq 1 1)", .symbol("T"))
        try await assertEval("(eq 1 1.0)", .nilValue)
        try await assertEval("(eq 'a 'a)", .symbol("T"))
        try await assertEval("(eq \"a\" \"a\")", .symbol("T"))
        try await assertEval("(eq nil nil)", .symbol("T"))
        // Value semantics: structurally equal values are eq (step 4e oracle
        // pins aliased lists T; distinct-but-equal is indistinguishable).
        try await assertEval("(eq '(1) '(1))", .symbol("T"))
    }

    func testEqual() async throws {
        try await assertEval("(equal 1 1.0)", .symbol("T"))
        try await assertEval("(equal '(1 (2)) '(1 (2)))", .symbol("T"))
        try await assertEval("(equal 1.0 1.05 0.1)", .symbol("T"))
        try await assertEval("(equal 1.0 1.5 0.1)", .nilValue)
        try await assertEval("(equal \"a\" \"b\")", .nilValue)
    }

    func testPredicates() async throws {
        try await assertEval("(not nil)", .symbol("T"))
        try await assertEval("(not 0)", .nilValue)
        try await assertEval("(atom 'a)", .symbol("T"))
        try await assertEval("(atom nil)", .symbol("T"))
        try await assertEval("(atom '(1))", .nilValue)
        try await assertEval("(listp '(1))", .symbol("T"))
        try await assertEval("(listp nil)", .symbol("T"))
        try await assertEval("(listp 1)", .nilValue)
        try await assertEval("(null nil)", .symbol("T"))
        try await assertEval("(null 0)", .nilValue)
        try await assertEval("(vl-symbolp 'a)", .symbol("T"))
        try await assertEval("(vl-symbolp 1)", .nilValue)
    }

    func testType() async throws {
        try await assertEval("(type 1)", .symbol("INT"))
        try await assertEval("(type 1.5)", .symbol("REAL"))
        try await assertEval("(type \"s\")", .symbol("STR"))
        try await assertEval("(type 's)", .symbol("SYM"))
        try await assertEval("(type '(1))", .symbol("LIST"))
        try await assertEval("(type nil)", .symbol("LIST"))
    }

    func testBoundp() async throws {
        try await assertEval("(boundp 'pi)", .symbol("T"))
        try await assertEval("(boundp 'neverboundanywhere)", .nilValue)
        try await assertEval("(progn (setq boundme nil) (boundp 'boundme))", .symbol("T"))
    }

    func testDisplayBuiltins() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let princResult = try await evalString("(princ \"hi\")", env: &env, host: host)
        XCTAssertEqual(princResult, .string("hi"))
        XCTAssertEqual(host.output, "hi")
        _ = try await evalString("(prin1 \"hi\")", env: &env, host: host)
        XCTAssertEqual(host.output, "hi\"hi\"")
        _ = try await evalString("(prompt \"p\")", env: &env, host: host)
        XCTAssertTrue(host.output.hasSuffix("p"))
        _ = try await evalString("(terpri)", env: &env, host: host)
        XCTAssertTrue(host.output.hasSuffix("p\n"))
        let printResult = try await evalString("(print 42)", env: &env, host: host)
        XCTAssertEqual(printResult, .int(42))
        XCTAssertTrue(host.output.hasSuffix("\n42 "))
        let quiet = try await evalString("(princ)", env: &env, host: host)
        XCTAssertEqual(quiet, .nilValue)
    }

    func testVer() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let result = try await evalString("(ver)", env: &env, host: host)
        guard case let .string(text) = result else {
            return XCTFail("ver should return a string")
        }
        XCTAssertTrue(text.hasPrefix("ZephyrLisp"), text)
    }

    func testReadBuiltin() async throws {
        try await assertEval("(car (read \"(1 2)\"))", .int(1))
        try await assertEval("(read \"\")", .nilValue)
    }

    func testAtomsFamilyAndSymbols() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        _ = try await evalString("(setq zzfamtest 1)", env: &env, host: host)
        let family = try await evalString("(atoms-family 0)", env: &env, host: host)
        guard let names = family.properList else {
            return XCTFail("atoms-family should return a list")
        }
        XCTAssertTrue(names.contains(.symbol("ZZFAMTEST")))
        XCTAssertTrue(names.contains(.symbol("PI")))
        try await assertEval("(vl-symbol-name 'abc)", .string("ABC"))
        try await assertEval("(vl-symbol-value 'pi)", .real(Double.pi))
        try await assertEval("(vl-symbol-value 'neverboundanywhere)", .nilValue)
    }

    func testVarsAndInitget() async throws {
        var env = LispEnvironment()
        let host = ScriptedLispHost()
        let osmode = try await evalString("(getvar \"OSMODE\")", env: &env, host: host)
        XCTAssertEqual(osmode, .int(0))
        _ = try await evalString("(setvar \"OSMODE\" 7)", env: &env, host: host)
        XCTAssertEqual(host.vars["OSMODE"], .int(7))
        await assertEvalThrows("(getvar \"NOSUCHVAR\")", .hostError("unknown system variable: NOSUCHVAR"))
        _ = try await evalString("(initget 7 \"Yes No\")", env: &env, host: host)
        XCTAssertEqual(env.pendingInitget.bits, 7)
        // Keywords keep their defined spelling; matching is case-insensitive.
        XCTAssertEqual(env.pendingInitget.keywords, ["Yes", "No"])
    }
}

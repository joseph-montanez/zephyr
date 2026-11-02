import XCTest
@testable import ZephyrLisp

final class LispBuiltinStringTests: XCTestCase {
    func testCoreStrings() async throws {
        try await assertEval("(strcat \"a\" \"b\" \"c\")", .string("abc"))
        try await assertEval("(strcat)", .string(""))
        try await assertEval("(strlen \"hello\")", .int(5))
        try await assertEval("(substr \"hello\" 2 3)", .string("ell"))
        try await assertEval("(substr \"hello\" 2)", .string("ello"))
        try await assertEval("(substr \"hello\" 0)", .string("hello"))
        try await assertEval("(substr \"hello\" 9)", .string(""))
        try await assertEval("(strcase \"aBc\")", .string("ABC"))
        try await assertEval("(strcase \"aBc\" t)", .string("abc"))
        try await assertEval("(ascii \"ABC\")", .int(65))
        try await assertEval("(ascii \"\")", .int(0))
        try await assertEval("(chr 65)", .string("A"))
        try await assertEval("(itoa 42)", .string("42"))
        try await assertEval("(atoi \"12ab\")", .int(12))
        try await assertEval("(atoi \"ab\")", .int(0))
        try await assertEval("(atof \"3.5x\")", .real(3.5))
        try await assertEval("(atof \"x\")", .real(0.0))
        try await assertEval("(atof \"1e400\")", .real(Double.greatestFiniteMagnitude))
        try await assertEval("(atof \"-1e400\")", .real(-Double.greatestFiniteMagnitude))
        try await assertEval("(atof \"1e-400\")", .real(0.0))
        try await assertEval(
            "(acad_strlsort '(\"b\" \"a\"))", LispValue(stringList: ["a", "b"]))
    }

    func testWcmatch() async throws {
        try await assertEval("(wcmatch \"drawing1\" \"*.dwg\")", .nilValue)
        try await assertEval("(wcmatch \"a.dwg\" \"*.dwg\")", .symbol("T"))
        try await assertEval("(wcmatch \"ABC\" \"a*\")", .symbol("T")) // insensitive
        try await assertEval("(wcmatch \"a1\" \"a#\")", .symbol("T"))
        try await assertEval("(wcmatch \"ab\" \"a#\")", .nilValue)
        try await assertEval("(wcmatch \"ab\" \"a@\")", .symbol("T"))
        try await assertEval("(wcmatch \"a-\" \"a.\")", .symbol("T"))
        try await assertEval("(wcmatch \"a1\" \"a?\")", .symbol("T"))
        try await assertEval("(wcmatch \"abc\" \"a*,x*\")", .symbol("T"))
        try await assertEval("(wcmatch \"abc\" \"~a*\")", .nilValue)
        try await assertEval("(wcmatch \"b5\" \"[a-c][0-9]\")", .symbol("T"))
        try await assertEval("(wcmatch \"d5\" \"[a-c][0-9]\")", .nilValue)
        try await assertEval("(wcmatch \"d5\" \"[~a-c][0-9]\")", .symbol("T"))
    }

    func testVlStringUtilities() async throws {
        try await assertEval(
            "(vl-string->list \"AB\")", LispValue(list: [.int(65), .int(66)]))
        try await assertEval("(vl-string-elt \"AB\" 1)", .int(66))
        try await assertEval("(vl-string-elt \"AB\" 5)", .nilValue)
        try await assertEval("(vl-string-position 66 \"ABC\")", .int(1))
        try await assertEval("(vl-string-position 90 \"ABC\")", .nilValue)
        try await assertEval("(vl-string-search \"BC\" \"ABC\")", .int(1))
        try await assertEval("(vl-string-search \"bc\" \"ABC\")", .nilValue) // sensitive
        try await assertEval("(vl-string-subst \"X\" \"B\" \"ABC\")", .string("AXC"))
        try await assertEval("(vl-string-subst \"X\" \"Z\" \"ABC\")", .string("ABC"))
        try await assertEval("(vl-string-trim \" \" \"  hi  \")", .string("hi"))
        try await assertEval("(vl-string-left-trim \" \" \"  hi  \")", .string("hi  "))
        try await assertEval("(vl-string-right-trim \" \" \"  hi  \")", .string("  hi"))
        try await assertEval("(vl-string-mismatch \"abc\" \"abd\")", .int(2))
        try await assertEval("(vl-string-mismatch \"abc\" \"abc\")", .symbol("T"))
        try await assertEval("(vl-string-translate \"ab\" \"XY\" \"aabbcc\")", .string("XXYYcc"))
        try await assertEval("(vl-prin1-to-string \"a\")", .string("\"a\""))
        try await assertEval("(vl-princ-to-string \"a\")", .string("a"))
        try await assertEval("(vl-prin1-to-string '(1))", .string("(1)"))
    }

    func testSnvalid() async throws {
        try await assertEval("(snvalid \"LAYER1\")", .symbol("T"))
        try await assertEval("(snvalid \"1LAYER\")", .nilValue)
        try await assertEval("(snvalid \"\")", .nilValue)
        try await assertEval("(snvalid \"my-layer_$\")", .symbol("T"))
    }
}

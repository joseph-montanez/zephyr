import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Wave-B symbol tables + layouts + ssnamex, headless through LispCADHost.
@MainActor
final class LispTableTests: XCTestCase {

    private func makeHost() -> LispCADHost {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        doc.addLayer(Layer(name: "WALLS"))
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

    private func assoc(_ code: Int, _ list: LispValue) -> LispValue? {
        guard let items = list.properList else { return nil }
        for item in items {
            if case let .cons(head, tail) = item,
               case let .int(c) = head, c == code
            {
                return tail
            }
        }
        return nil
    }

    func testTblsearchLayer() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let found = try await eval(#"(tblsearch "LAYER" "WALLS")"#, host: host, env: &env)
        XCTAssertEqual(assoc(0, found), .string("LAYER"))
        XCTAssertEqual(assoc(2, found), .string("WALLS"))
        XCTAssertNotNil(assoc(62, found))
        XCTAssertEqual(assoc(6, found), .string("CONTINUOUS"))
        let missing = try await eval(#"(tblsearch "LAYER" "NOPE")"#, host: host, env: &env)
        XCTAssertEqual(missing, .nilValue)
    }

    func testTblnextIteratesAndRewinds() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let first = try await eval(#"(tblnext "LAYER" T)"#, host: host, env: &env)
        XCTAssertEqual(assoc(2, first), .string("0"))
        let second = try await eval(#"(tblnext "LAYER")"#, host: host, env: &env)
        XCTAssertEqual(assoc(2, second), .string("WALLS"))
        let done = try await eval(#"(tblnext "LAYER")"#, host: host, env: &env)
        XCTAssertEqual(done, .nilValue)
        // setnext parks the cursor after the found entry.
        _ = try await eval(#"(tblsearch "LAYER" "0" T)"#, host: host, env: &env)
        let after = try await eval(#"(tblnext "LAYER")"#, host: host, env: &env)
        XCTAssertEqual(assoc(2, after), .string("WALLS"))
    }

    func testTblnextStyleAndLtype() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let style = try await eval(#"(tblnext "STYLE" T)"#, host: host, env: &env)
        XCTAssertEqual(assoc(0, style), .string("STYLE"))
        XCTAssertEqual(assoc(2, style), .string("Standard"))
        let ltype = try await eval(#"(tblsearch "LTYPE" "CONTINUOUS")"#, host: host, env: &env)
        XCTAssertEqual(assoc(0, ltype), .string("LTYPE"))
    }

    func testAppidTableFromRegapp() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval("(regapp \"MY_APP\")", host: host, env: &env)
        let found = try await eval(#"(tblsearch "APPID" "MY_APP")"#, host: host, env: &env)
        XCTAssertEqual(assoc(0, found), .string("APPID"))
        XCTAssertEqual(assoc(2, found), .string("MY_APP"))
        let first = try await eval(#"(tblnext "APPID" T)"#, host: host, env: &env)
        XCTAssertEqual(assoc(2, first), .string("MY_APP"))
    }

    func testTblobjnameIsNil() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let result = try await eval(#"(tblobjname "LAYER" "0")"#, host: host, env: &env)
        XCTAssertEqual(result, .nilValue)
    }

    /// (layoutlist) lists paper layouts only (AutoCAD shape). The old
    /// ["Model"] expectation encoded the single-space stub; a headless
    /// single-document host has no paper layouts, so the result is nil.
    func testLayoutlist() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let layouts = try await eval("(layoutlist)", host: host, env: &env)
        XCTAssertEqual(layouts, .nilValue)
        XCTAssertEqual(layouts.properList, [])
    }

    func testLayoutlistReturnsCapturedPaperLayouts() async throws {
        let host = makeHost()
        host.captureMainThreadState(
            selectedHandles: [], activeCommand: nil,
            space: DrawingSpaceState(
                tileMode: 0, currentViewportID: 1,
                currentLayoutName: "Layout1",
                paperLayoutNames: ["Layout1", "Layout2"]))
        var env = LispEnvironment()
        let layouts = try await eval("(layoutlist)", host: host, env: &env)
        XCTAssertEqual(layouts.properList, [.string("Layout1"), .string("Layout2")])
    }

    func testSpaceSysvarsDefaultToModel() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let tile = try await eval(#"(getvar "TILEMODE")"#, host: host, env: &env)
        XCTAssertEqual(tile, .int(1))
        let cvport = try await eval(#"(getvar "CVPORT")"#, host: host, env: &env)
        XCTAssertEqual(cvport, .int(2))
        let ctab = try await eval(#"(getvar "CTAB")"#, host: host, env: &env)
        XCTAssertEqual(ctab, .string("Model"))
        let cspace = try await eval(#"(getvar "CSPACE")"#, host: host, env: &env)
        XCTAssertEqual(cspace, .string("Model"))
    }

    func testSpaceSysvarsReflectPaperSpaceAndTileModeIsReadOnly() async throws {
        let host = makeHost()
        host.captureMainThreadState(
            selectedHandles: [], activeCommand: nil,
            space: DrawingSpaceState(
                tileMode: 0, currentViewportID: 1,
                currentLayoutName: "Layout1",
                paperLayoutNames: ["Layout1"]))
        var env = LispEnvironment()
        let tile = try await eval(#"(getvar "TILEMODE")"#, host: host, env: &env)
        XCTAssertEqual(tile, .int(0))
        let cvport = try await eval(#"(getvar "CVPORT")"#, host: host, env: &env)
        XCTAssertEqual(cvport, .int(1))
        let ctab = try await eval(#"(getvar "CTAB")"#, host: host, env: &env)
        XCTAssertEqual(ctab, .string("Layout1"))
        XCTAssertNotNil(host.vars.set("TILEMODE", .int(1), document: host.document))
        _ = try await eval(#"(setvar "TILEMODE" 1)"#, host: host, env: &env)
        let after = try await eval(#"(getvar "TILEMODE")"#, host: host, env: &env)
        XCTAssertEqual(after, .int(0))
    }

    func testUnknownTableThrows() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        do {
            _ = try await eval(#"(tblnext "BOGUS")"#, host: host, env: &env)
            XCTFail("unknown table should throw")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("BOGUS"), "\(error)")
        }
    }

    func testSsnamexShape() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(entmake '((0 . "LINE") (10 0 0 0) (11 1 0 0)))"#,
            host: host, env: &env)
        _ = try await eval(#"(setq S (ssget "_X"))"#, host: host, env: &env)
        let extended = try await eval("(ssnamex S 0)", host: host, env: &env)
        guard let outer = extended.properList, outer.count == 1,
              let inner = outer[0].properList, inner.count == 1,
              case .entityName = inner[0]
        else {
            return XCTFail("ssnamex shape is ((ename)), got \(extended)")
        }
        let oob = try await eval("(ssnamex S 9)", host: host, env: &env)
        XCTAssertEqual(oob, .nilValue)
    }
}

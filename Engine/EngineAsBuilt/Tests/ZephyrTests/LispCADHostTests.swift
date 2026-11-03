import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Step-3 CAD host tests: entity adapter, selection sets, system variables,
/// and the scripted (command ...) dispatcher — all headless through the
/// real evaluator + LispCADHost + CADDocument.
@MainActor
final class LispCADHostTests: XCTestCase {

    private func makeHost() -> LispCADHost {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
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

    private func assertEval(
        _ source: String, _ expected: LispValue,
        host: LispCADHost, env: inout LispEnvironment,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await eval(source, host: host, env: &env)
        XCTAssertEqual(actual, expected, "eval: \(source)", file: file, line: line)
    }

    /// Mirrors the driver's frame poll: applies the host's pending
    /// pickfirst write to the live selection manager.
    private func drainSelection(_ host: LispCADHost) {
        if let pending = host.takePendingSelectionApply() {
            host.selection.selectedHandles = pending
        }
    }

    /// assoc lookup on an entget-style list. Returns the cdr value.
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

    // MARK: - entmake / entget

    func testEntmakeLineRoundTrip() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let made = try await eval(
            #"(entmake '((0 . "LINE") (10 1 2 0) (11 3 4 0)))"#,
            host: host, env: &env)
        guard case let .entityName(handle) = made else {
            return XCTFail("entmake should return an entity name, got \(made)")
        }
        XCTAssertEqual(host.document.allEntities.count, 1)
        var env2 = LispEnvironment()
        env2.globals["E"] = made
        let fetched = try await eval("(entget E)", host: host, env: &env2)
        XCTAssertEqual(assoc(0, fetched), .string("LINE"))
        XCTAssertEqual(assoc(8, fetched), .string("0"))
        XCTAssertEqual(assoc(5, fetched), .string(handle))
        XCTAssertEqual(assoc(10, fetched)?.asPoint, [1, 2, 0])
        XCTAssertEqual(assoc(11, fetched)?.asPoint, [3, 4, 0])
        XCTAssertEqual(assoc(62, fetched), .int(256))
    }

    func testEntmakeRespectsLayerAndColor() async throws {
        let host = makeHost()
        host.document.addLayer(Layer(name: "WALLS"))
        var env = LispEnvironment()
        let made = try await eval(
            #"(entmake '((0 . "CIRCLE") (8 . "WALLS") (10 5 5 0) (40 . 2.5) (62 . 1)))"#,
            host: host, env: &env)
        guard case let .entityName(handle) = made else {
            return XCTFail("expected entity name, got \(made)")
        }
        let entity = host.document.entity(forHandleName: handle)
        XCTAssertEqual(entity?.layerID, host.document.findLayer(named: "WALLS")?.handle)
        var env2 = LispEnvironment()
        env2.globals["E"] = made
        let fetched = try await eval("(entget E)", host: host, env: &env2)
        XCTAssertEqual(assoc(0, fetched), .string("CIRCLE"))
        XCTAssertEqual(assoc(62, fetched), .int(1))
        XCTAssertEqual(assoc(40, fetched)?.asDouble, 2.5)
    }

    func testEntmakeUnknownLayerFails() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        do {
            _ = try await eval(
                #"(entmake '((0 . "LINE") (8 . "NOPE") (10 0 0 0) (11 1 1 0)))"#,
                host: host, env: &env)
            XCTFail("unknown layer should fail")
        } catch let error as LispError {
            XCTAssertTrue(
                "\(error)".contains("NOPE"),
                "error names the layer: \(error)")
        }
    }

    func testEntmakeArcDegreesRoundTrip() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        let made = try await eval(
            #"(entmake '((0 . "ARC") (10 0 0 0) (40 . 10) (50 . 0) (51 . 90)))"#,
            host: host, env: &env)
        var env2 = LispEnvironment()
        env2.globals["E"] = made
        let fetched = try await eval("(entget E)", host: host, env: &env2)
        XCTAssertEqual(assoc(50, fetched)?.asDouble ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(assoc(51, fetched)?.asDouble ?? -1, 90, accuracy: 1e-9)
    }

    func testEntmodUpdatesColorAndGeometry() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(setq E (entmake '((0 . "LINE") (10 0 0 0) (11 1 0 0))))"#,
            host: host, env: &env)
        _ = try await eval(
            #"(entmod (subst '(62 . 3) (assoc 62 (entget E)) (entget E)))"#,
            host: host, env: &env)
        let fetched = try await eval("(entget E)", host: host, env: &env)
        XCTAssertEqual(assoc(62, fetched), .int(3))
        XCTAssertEqual(host.document.allEntities.count, 1)
        XCTAssertEqual(host.document.undoManager.undoDepth, 3, "layer setup + entmake + entmod")
    }

    func testEntdelTogglesErase() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(setq E (entmake '((0 . "POINT") (10 7 8 0))))"#,
            host: host, env: &env)
        _ = try await eval("(entdel E)", host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 0)
        _ = try await eval("(entdel E)", host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 1, "second entdel restores")
    }

    func testEntlastNextHandent() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        try await assertEval("(entlast)", .nilValue, host: host, env: &env)
        _ = try await eval(
            #"(setq A (entmake '((0 . "POINT") (10 0 0 0))))"#,
            host: host, env: &env)
        _ = try await eval(
            #"(setq B (entmake '((0 . "POINT") (10 1 1 0))))"#,
            host: host, env: &env)
        let last = try await eval("(entlast)", host: host, env: &env)
        let b = try await eval("B", host: host, env: &env)
        XCTAssertEqual(last, b)
        // handent round-trips through the group-5 handle string.
        let viaHandle = try await eval(
            #"(handent (cdr (assoc 5 (entget A))))"#, host: host, env: &env)
        let a = try await eval("A", host: host, env: &env)
        XCTAssertEqual(viaHandle, a)
        // entnext walks the full database from nil.
        var seen: Set<String> = []
        var cursor = try await eval("(entnext)", host: host, env: &env)
        env.globals["CURSOR"] = cursor
        while case let .entityName(h) = cursor {
            seen.insert(h)
            cursor = try await eval("(entnext CURSOR)", host: host, env: &env)
            env.globals["CURSOR"] = cursor
        }
        XCTAssertEqual(seen.count, 2)
    }

    // MARK: - Selection sets

    private func seedTwoLines(host: LispCADHost) async throws {
        var env = LispEnvironment()
        _ = try await eval(
            #"(entmake '((0 . "LINE") (10 0 0 0) (11 1 0 0) (62 . 1)))"#,
            host: host, env: &env)
        _ = try await eval(
            #"(entmake '((0 . "CIRCLE") (10 10 10 0) (40 . 2) (62 . 3)))"#,
            host: host, env: &env)
    }

    private func setLength(_ value: LispValue, host: LispCADHost) async throws -> Int? {
        guard case let .selectionSet(id) = value else { return nil }
        return try await host.ssLength(id)
    }

    func testSsgetXWithFilters() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        var env = LispEnvironment()
        let all = try await eval(#"(ssget "_X")"#, host: host, env: &env)
        do {
            let length1 = try await setLength(all, host: host)
            XCTAssertEqual(length1, 2)
        }
        let lines = try await eval(#"(ssget "_X" '((0 . "LINE")))"#, host: host, env: &env)
        do {
            let length2 = try await setLength(lines, host: host)
            XCTAssertEqual(length2, 1)
        }
        let red = try await eval(#"(ssget "_X" '((62 . 1)))"#, host: host, env: &env)
        do {
            let length3 = try await setLength(red, host: host)
            XCTAssertEqual(length3, 1)
        }
        try await assertEval(
            #"(ssget "_X" '((0 . "TEXT")))"#, .nilValue, host: host, env: &env)
    }

    func testSsgetWindowAndCrossing() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        var env = LispEnvironment()
        let win = try await eval(#"(ssget "_W" '(0 0 0) '(2 2 0))"#, host: host, env: &env)
        do {
            let length4 = try await setLength(win, host: host)
            XCTAssertEqual(length4, 1)
        }
        let cross = try await eval(#"(ssget "_C" '(0 0 0) '(20 20 0))"#, host: host, env: &env)
        do {
            let length5 = try await setLength(cross, host: host)
            XCTAssertEqual(length5, 2)
        }
        try await assertEval(
            #"(ssget "_W" '(50 50 0) '(60 60 0))"#, .nilValue, host: host, env: &env)
    }

    func testSsgetLastAndPrevious() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        var env = LispEnvironment()
        let last = try await eval(#"(ssget "_L")"#, host: host, env: &env)
        do {
            let length6 = try await setLength(last, host: host)
            XCTAssertEqual(length6, 1)
        }
        // Consume a selection via COPY so _P has content.
        _ = try await eval(
            #"(command "_.COPY" (ssget "_L") "" '(0 0 0) '(1 1 0))"#,
            host: host, env: &env)
        let prev = try await eval(#"(ssget "_P")"#, host: host, env: &env)
        let prevLength = try await setLength(prev, host: host)
        XCTAssertNotNil(prevLength)
        XCTAssertGreaterThanOrEqual(prevLength ?? 0, 1)
    }

    func testSsAddDelLengthNameMemb() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        var env = LispEnvironment()
        _ = try await eval(#"(setq S (ssget "_X"))"#, host: host, env: &env)
        try await assertEval("(sslength S)", .int(2), host: host, env: &env)
        let first = try await eval("(ssname S 0)", host: host, env: &env)
        guard case .entityName = first else {
            return XCTFail("ssname should return an entity, got \(first)")
        }
        try await assertEval("(ssname S 9)", .nilValue, host: host, env: &env)
        env.globals["FIRST"] = first
        let memb = try await eval("(ssmemb FIRST S)", host: host, env: &env)
        XCTAssertEqual(memb, first)
        _ = try await eval("(ssdel FIRST S)", host: host, env: &env)
        try await assertEval("(sslength S)", .int(1), host: host, env: &env)
        // Fresh empty set from ssadd, then add back.
        _ = try await eval("(setq TSET (ssadd))", host: host, env: &env)
        try await assertEval("(sslength TSET)", .int(0), host: host, env: &env)
        _ = try await eval("(ssadd FIRST TSET)", host: host, env: &env)
        try await assertEval("(sslength TSET)", .int(1), host: host, env: &env)
    }

    func testSsGetFirstAndSetFirst() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        var env = LispEnvironment()
        try await assertEval("(ssgetfirst)", .nilValue, host: host, env: &env)
        _ = try await eval(#"(sssetfirst (ssget "_X"))"#, host: host, env: &env)
        drainSelection(host)
        XCTAssertEqual(host.selection.selectedHandles.count, 2)
        let first = try await eval("(ssgetfirst)", host: host, env: &env)
        guard let pair = first.properList, pair.count == 2 else {
            return XCTFail("ssgetfirst returns (gripset pickset), got \(first)")
        }
        XCTAssertEqual(pair.count, 2)
        _ = try await eval("(sssetfirst nil nil)", host: host, env: &env)
        drainSelection(host)
        XCTAssertEqual(host.selection.selectedHandles.count, 0)
        try await assertEval("(ssgetfirst)", .nilValue, host: host, env: &env)
        // Two-arg form highlights the SECOND set (corpus idiom).
        _ = try await eval("(sssetfirst nil (ssget \"_X\"))", host: host, env: &env)
        drainSelection(host)
        XCTAssertEqual(host.selection.selectedHandles.count, 2)
    }

    func testSelectCommandAndMillisecs() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        var env = LispEnvironment()
        _ = try await eval(
            #"(vl-cmdf "_.SELECT" (ssget "_X") "")"#, host: host, env: &env)
        drainSelection(host)
        XCTAssertEqual(host.selection.selectedHandles.count, 2)
        XCTAssertEqual(host.previousSelection.count, 2)
        let depthBefore = host.document.undoManager.undoDepth
        _ = try await eval(
            #"(command "_.SELECT" (ssget "_X") "")"#, host: host, env: &env)
        XCTAssertEqual(
            host.document.undoManager.undoDepth, depthBefore,
            "SELECT pushes no undo")
        let millis = try await eval(#"(getvar "MILLISECS")"#, host: host, env: &env)
        guard case let .int(ms) = millis, ms > 0 else {
            return XCTFail("MILLISECS should be a positive int, got \(millis)")
        }
    }

    func testPickSelectionHeadless() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        let anyEntity = try XCTUnwrap(host.document.allEntities.first)
        let target = anyEntity.handle.uuidString
        let task = Task { try await host.ssGetInteractive(mode: "PICK", points: [], filter: nil) }
        for _ in 0..<1000 where !host.broker.hasPending { await Task.yield() }
        XCTAssertTrue(host.broker.hasPending)
        host.broker.offer(.entity(handle: target, point: [0, 0]))
        host.broker.offer(.entity(handle: nil, point: nil)) // Enter ends pick.
        let id = try await task.value
        let unwrapped = try XCTUnwrap(id)
        let length = try await host.ssLength(unwrapped)
        XCTAssertEqual(length, 1)
        let named = try await host.ssName(unwrapped, index: 0)
        XCTAssertEqual(named, .entityName(target))
    }

    // MARK: - System variables

    func testVarsLiveReadonlyAndMemory() async throws {
        let host = makeHost()
        host.document.addLayer(Layer(name: "WALLS"))
        var env = LispEnvironment()
        try await assertEval(#"(getvar "CLAYER")"#, .string("0"), host: host, env: &env)
        _ = try await eval(#"(setvar "CLAYER" "WALLS")"#, host: host, env: &env)
        XCTAssertEqual(
            host.document.activeLayerID,
            host.document.findLayer(named: "WALLS")?.handle)
        try await assertEval(#"(getvar "UNDOCTL")"#, .int(0), host: host, env: &env)
        host.document.undoManager.beginUndoGroup()
        try await assertEval(#"(getvar "UNDOCTL")"#, .int(1), host: host, env: &env)
        host.document.undoManager.endUndoGroup()
        // Memory variable round-trip.
        _ = try await eval(#"(setvar "LTSCALE" 2.5)"#, host: host, env: &env)
        try await assertEval(#"(getvar "LTSCALE")"#, .real(2.5), host: host, env: &env)
        // Read-only rejects.
        do {
            try host.setSystemVarChecked("ACADVER", .string("x"))
            XCTFail("ACADVER is read-only")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("read-only"), "\(error)")
        }
        // Unknown layer rejects.
        do {
            try host.setSystemVarChecked("CLAYER", .string("NOPE"))
            XCTFail("unknown layer should reject")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("NOPE"), "\(error)")
        }
    }

    // MARK: - Scripted (command ...) dispatcher

    func testCommandCreatesGeometryWithPerCallUndo() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(command "_.LINE" '(0 0 0) '(10 0 0) "")"#, host: host, env: &env)
        _ = try await eval(
            #"(command "_.CIRCLE" '(5 5 0) 2.0)"#, host: host, env: &env)
        _ = try await eval(
            #"(command "_.PLINE" '(0 0 0) '(1 0 0) '(1 1 0) "_C")"#,
            host: host, env: &env)
        _ = try await eval(
            #"(command "_.ARC" "_C" '(0 0 0) '(10 0 0) '(0 10 0))"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 4)
        XCTAssertEqual(
            host.document.undoManager.undoDepth, 5,
            "one undo entry per scripted call + layer setup")
        host.document.undo()
        XCTAssertEqual(host.document.allEntities.count, 3)
    }

    func testCommandModifyVerbs() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(command "_.LINE" '(0 0 0) '(4 0 0) "")"#, host: host, env: &env)
        // COPY _L by (10,0).
        _ = try await eval(
            #"(command "_.COPY" "_L" "" '(0 0 0) '(10 0 0))"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 2)
        _ = try await eval(
            #"(command "_.ROTATE" (ssget "_X") "" '(0 0 0) 90.0)"#,
            host: host, env: &env)
        _ = try await eval(
            #"(command "_.MOVE" (ssget "_X") "" '(0 0 0) '(-10 0 0))"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 2)
        // ERASE one via window: after ROTATE 90 about origin + MOVE (-10,0),
        // the original (0,0)-(4,0) line sits at (-10,0)-(-10,4).
        _ = try await eval(
            #"(command "_.ERASE" "_W" '(-11 -1 0) '(-9 5 0) "")"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 1)
    }

    func testCommandUndoGrouping() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(command "_.UNDO" "_BEGIN")"#, host: host, env: &env)
        _ = try await eval(
            #"(command "_.LINE" '(0 0 0) '(1 0 0) "")"#, host: host, env: &env)
        _ = try await eval(
            #"(command "_.LINE" '(2 0 0) '(3 0 0) "")"#, host: host, env: &env)
        XCTAssertEqual(host.document.undoManager.undoDepth, 1, "group open (layer setup only)")
        _ = try await eval(#"(command "_.UNDO" "_END")"#, host: host, env: &env)
        XCTAssertEqual(host.document.undoManager.undoDepth, 2, "group coalesced")
        host.document.undo()
        XCTAssertEqual(host.document.allEntities.count, 0)
    }

    func testCommandRejectsInteractive() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        for name in ["PLOT", "SAVE", "PASTECLIP", "DDEDIT", "ZOOM"] {
            do {
                _ = try await eval(#"(command " _.\#(name) ")"#, host: host, env: &env)
                XCTFail("\(name) should reject from (command)")
            } catch let error as LispError {
                XCTAssertTrue(
                    "\(error)".contains(name),
                    "\(name): error names the offender: \(error)")
            }
        }
        // PAUSE splices interactive input: rejected.
        do {
            _ = try await eval(
                #"(command "_.LINE" pause '(1 0 0) "")"#, host: host, env: &env)
            XCTFail("PAUSE should reject")
        } catch let error as LispError {
            XCTAssertTrue("\(error)".contains("PAUSE"), "\(error)")
        }
        // Transparent invocation: rejected.
        do {
            _ = try await eval(#"(command "'_.ZOOM")""#, host: host, env: &env)
            XCTFail("transparent should reject")
        } catch {
            // Any LispError is correct (hostError naming transparency).
        }
    }

    func testDispositionApprovedList() {
        // Pinned audit: adding a scripted command requires updating this
        // list AND its implementation + tests. Anything unlisted rejects.
        XCTAssertEqual(
            LispScriptedCommands.scripted,
            ["LINE", "CIRCLE", "PLINE", "ARC",
             "COPY", "ROTATE", "MOVE", "ERASE", "SELECT",
             "UNDO", "U", "REDRAW", "REGEN", "INSERT", "-INSERT", "-ATTACH",
             "RECTANG", "RECTANGLE", "CHPROP", "CHANGE", "-HATCH", "HATCH", "TEXT", "-TEXT", "DTEXT", "AUTOCONTRAST",
             "-LAYER", "-LA", "LAYERSTATE", "-LAYERSTATE", "LAYERP"])
        XCTAssertEqual(
            LispScriptedCommands.disposition(for: "_.LINE"), .scripted)
        XCTAssertEqual(
            LispScriptedCommands.disposition(for: "PLOT"), .interactiveReject)
        XCTAssertEqual(
            LispScriptedCommands.disposition(for: "PUBLISH"), .interactiveReject)
        XCTAssertEqual(
            LispScriptedCommands.disposition(for: "_.PUBLISH"), .interactiveReject)
        XCTAssertEqual(
            LispScriptedCommands.disposition(for: "'_.ZOOM"), .interactiveReject)
    }

    // MARK: - Input paths

    func testRequestPointNumberEscape() async throws {
        let host = makeHost()
        // getdist-style: bare number answers.
        let numberTask = Task {
            try await host.requestPointOrNumber(prompt: "Dist:", base: [0, 0])
        }
        for _ in 0..<1000 where !host.broker.hasPending { await Task.yield() }
        host.broker.offer(.point([7.5]))
        let number = try await numberTask.value
        XCTAssertEqual(number, .number(7.5))
        // getpoint-style: bare number re-prompts, then a point answers.
        let pointTask = Task { try await host.requestPoint(prompt: "Pt:", base: nil) }
        for _ in 0..<1000 where !host.broker.hasPending { await Task.yield() }
        host.broker.offer(.point([7.5]))
        for _ in 0..<1000 where !host.broker.hasPending { await Task.yield() }
        host.broker.offer(.point([3, 4]))
        let point = try await pointTask.value
        XCTAssertEqual(point, [3, 4])
    }

    func testGrreadAndNentselPassive() async throws {
        let host = makeHost()
        try await seedTwoLines(host: host)
        // grread delivers the queued device event.
        let grTask = Task { try await host.readDeviceEvent() }
        for _ in 0..<1000 where !host.broker.hasPending { await Task.yield() }
        host.broker.offer(.device(LispEntityAdapter.lispList([.int(3), .real(1), .real(2)])))
        let event = try await grTask.value
        XCTAssertEqual(event.properList?.first, .int(3))
        // nentselp: nil when nothing picked, entsel-shaped when picked.
        let passiveEmpty = try await host.nentselPassive(at: nil)
        XCTAssertNil(passiveEmpty)
        var env = LispEnvironment()
        _ = try await eval(#"(sssetfirst (ssget "_X"))"#, host: host, env: &env)
        let passive = try await host.nentselPassive(at: nil)
        XCTAssertNotNil(passive)
        if case let .entityName(h) = passive?.properList?.first {
            XCTAssertNotNil(UUID(uuidString: h))
        } else {
            XCTFail("nentselp first element is an ename, got \(String(describing: passive))")
        }
    }

    func testCommandRectang() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(command "_.RECTANG" '(0 0 0) '(10 20 0))"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 1)
        guard let ent = host.document.allEntities.first,
              let prim = ent.localGeometry?.first else {
            return XCTFail("RECTANG should create an entity with geometry")
        }
        guard case let .polyline(path, _) = prim else {
            return XCTFail("RECTANG should create a polyline primitive")
        }
        XCTAssertTrue(path.isClosed)
        XCTAssertEqual(path.vertices.count, 4)
    }

    func testCommandChprop() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(command "_.LINE" '(0 0 0) '(10 0 0) "")"#, host: host, env: &env)
        _ = try await eval(#"(command "_.CHPROP" "_L" "" "_C" "1" "")"#, host: host, env: &env)
        guard let ent = host.document.allEntities.first,
              let prim = ent.localGeometry?.first else {
            return XCTFail("entity should exist with geometry")
        }
        guard case let .line(_, _, color) = prim else {
            return XCTFail("primitive should be line")
        }
        XCTAssertEqual(color, ColorRGBA.red)
    }

    func testCommandPlineAndArcEnhanced() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(command "_.PLINE" '(0 0 0) "_W" 0.5 0.5 '(5 0 0) "_A" '(5 5 0) "_L" '(0 5 0) "_C")"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 1)

        _ = try await eval(
            #"(command "_.ARC" '(0 0 0) "_E" '(10 0 0) "_R" 5.0)"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 2)
    }

    func testCommandText() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(command "_.TEXT" '(0 0 0) 2.5 0.0 "Hello World")"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 1)
        guard let ent = host.document.allEntities.first,
              let prim = ent.localGeometry?.first else {
            return XCTFail("TEXT should create an entity with geometry")
        }
        guard case let .text(_, text, height, _, _, _, _, _, _) = prim else {
            return XCTFail("primitive should be .text")
        }
        XCTAssertEqual(text, "Hello World")
        XCTAssertEqual(height, 2.5)
    }

    func testCommandHatch() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(command "_.RECTANG" '(0 0 0) '(10 10 0))"#,
            host: host, env: &env)
        _ = try await eval(
            #"(command "_.-HATCH" "_P" "SOLID" "_CO" "T" "255,0,0" "" "_L" "")"#,
            host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 2)
        guard let prim = host.lastCreated.flatMap({ host.document.entity(for: $0) })?.localGeometry?.first else {
            return XCTFail("HATCH should create an entity with geometry")
        }
        guard case let .fillPolygon(pts, _) = prim else {
            return XCTFail("HATCH should create a fillPolygon primitive, got \(prim)")
        }
        XCTAssertEqual(pts.count, 4)
    }

    func testMultiCallPline() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(command "_PLINE")"#, host: host, env: &env)
        _ = try await eval(#"(command '(0 0 0))"#, host: host, env: &env)
        _ = try await eval(#"(command '(10 0 0))"#, host: host, env: &env)
        _ = try await eval(#"(command '(10 10 0))"#, host: host, env: &env)
        _ = try await eval(#"(command "_C")"#, host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 1)
        guard let ent = host.document.allEntities.first,
              let prim = ent.localGeometry?.first,
              case let .polyline(path, _) = prim else {
            return XCTFail("expected closed polyline")
        }
        XCTAssertTrue(path.isClosed)
        XCTAssertEqual(path.vertices.count, 3)
    }

    func testMultiCallLineWithBareCommandClose() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(command "_LINE")"#, host: host, env: &env)
        _ = try await eval(#"(command '(0 0 0))"#, host: host, env: &env)
        _ = try await eval(#"(command '(10 0 0))"#, host: host, env: &env)
        _ = try await eval(#"(command)"#, host: host, env: &env)
        XCTAssertEqual(host.document.allEntities.count, 1)
        guard let ent = host.document.allEntities.first,
              let prim = ent.localGeometry?.first,
              case .line = prim else {
            return XCTFail("expected line")
        }
    }

    func testCommandHatchGradientsAndEntmake() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(setq r1 (progn (command "_.RECTANG" '(0 0 0) '(10 10 0)) (entlast)))"#,
            host: host, env: &env)

        // 1. Pattern-name style (_P "GR_LINEAR" and _P "LINEAR")
        _ = try await eval(
            #"(command "_-HATCH" "_P" "GR_LINEAR" "_CO" "T" "22,53,77" "T" "11,25,37" "_Angle" "45" "" r1 "")"#,
            host: host, env: &env)
        guard let g1 = host.lastCreated.flatMap({ host.document.entity(for: $0) })?.localGeometry?.first,
              case let .gradient(_, _, name1, angle1, c1_1, c1_2) = g1 else {
            return XCTFail("expected gradient primitive from _P GR_LINEAR")
        }
        XCTAssertEqual(name1, "LINEAR")
        XCTAssertEqual(angle1, 45.0 * .pi / 180.0, accuracy: 1e-6)
        XCTAssertEqual(c1_1, ColorRGBA(r: 22, g: 53, b: 77, a: 255))
        XCTAssertEqual(c1_2, ColorRGBA(r: 11, g: 25, b: 37, a: 255))

        // 2. Main-prompt _G option
        _ = try await eval(
            #"(command "_-HATCH" "_G" "LINEAR" "_CO" "T" "45,107,152" "T" "22,53,77" "_A" 30 "" r1 "")"#,
            host: host, env: &env)
        guard let g2 = host.lastCreated.flatMap({ host.document.entity(for: $0) })?.localGeometry?.first,
              case let .gradient(_, _, name2, angle2, c2_1, c2_2) = g2 else {
            return XCTFail("expected gradient primitive from _G LINEAR")
        }
        XCTAssertEqual(name2, "LINEAR")
        XCTAssertEqual(angle2, 30.0 * .pi / 180.0, accuracy: 1e-6)
        XCTAssertEqual(c2_1, ColorRGBA(r: 45, g: 107, b: 152, a: 255))
        XCTAssertEqual(c2_2, ColorRGBA(r: 22, g: 53, b: 77, a: 255))

        // 3. System variables (GFNAME / GFCLR1 / GFCLR2 / GFANG)
        _ = try await eval(#"(setvar "GFNAME" 1)"#, host: host, env: &env)
        _ = try await eval(#"(setvar "GFCLR1" "RGB:250,186,3")"#, host: host, env: &env)
        _ = try await eval(#"(setvar "GFCLR2" "RGB:22,53,77")"#, host: host, env: &env)
        _ = try await eval(#"(setvar "GFANG" 60.0)"#, host: host, env: &env)
        _ = try await eval(#"(command "_-HATCH" "" r1 "")"#, host: host, env: &env)
        guard let g3 = host.lastCreated.flatMap({ host.document.entity(for: $0) })?.localGeometry?.first,
              case let .gradient(_, _, name3, angle3, c3_1, c3_2) = g3 else {
            return XCTFail("expected gradient primitive from GF* sysvars")
        }
        XCTAssertEqual(name3, "LINEAR")
        XCTAssertEqual(angle3, 60.0 * .pi / 180.0, accuracy: 1e-6)
        XCTAssertEqual(c3_1, ColorRGBA(r: 250, g: 186, b: 3, a: 255))
        XCTAssertEqual(c3_2, ColorRGBA(r: 22, g: 53, b: 77, a: 255))

        // 4. DXF entmake with 450/460/470/421 codes
        _ = try await eval(
            #"(entmake '((0 . "HATCH") (2 . "SOLID") (70 . 1) (10 0 0 0) (10 10 0 0) (10 10 10 0) (450 . 1) (452 . 0) (460 . 0.785398) (470 . "LINEAR") (421 . 1455437) (421 . 727333)))"#,
            host: host, env: &env)
        guard let g4 = host.lastCreated.flatMap({ host.document.entity(for: $0) })?.localGeometry?.first,
              case let .gradient(outer4, _, name4, angle4, c4_1, c4_2) = g4 else {
            return XCTFail("expected gradient primitive from entmake HATCH")
        }
        XCTAssertEqual(outer4.count, 3)
        XCTAssertEqual(name4, "LINEAR")
        XCTAssertEqual(angle4, 0.785398, accuracy: 1e-6)
        XCTAssertEqual(c4_1, ColorRGBA(r: 22, g: 53, b: 77, a: 255))
        XCTAssertEqual(c4_2, ColorRGBA(r: 11, g: 25, b: 37, a: 255))
    }

    func testChpropLinetypeAndScale() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(command "_.LINE" '(0 0 0) '(10 0 0) "")"#, host: host, env: &env)
        _ = try await eval(#"(command "_.CHPROP" "_L" "" "_LT" "DASHED" "_S" 5.0 "_LW" 0.35 "")"#, host: host, env: &env)
        guard let ent = host.document.allEntities.first else {
            return XCTFail("entity should exist")
        }
        XCTAssertEqual(ent.xdata["dxf.lineType"], .string("DASHED"))
        XCTAssertEqual(ent.xdata["dxf.lineTypeScale"], .double(5.0))
        XCTAssertEqual(ent.xdata["dxf.lineWeight"], .double(0.35))
    }

    func testCeltypeAndLtscale() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(#"(setvar "CELTYPE" "DASHED")"#, host: host, env: &env)
        _ = try await eval(#"(setvar "CELTSCALE" 2.5)"#, host: host, env: &env)
        _ = try await eval(#"(setvar "LTSCALE" 5.0)"#, host: host, env: &env)

        let ltScaleVal = try await eval(#"(getvar "LTSCALE")"#, host: host, env: &env)
        XCTAssertEqual(ltScaleVal.asDouble, 5.0)
        XCTAssertEqual(host.document.globalLineTypeScale, 5.0)

        _ = try await eval(#"(command "_.LINE" '(0 0 0) '(20 0 0) "")"#, host: host, env: &env)
        guard let ent = host.document.allEntities.first else {
            return XCTFail("entity should exist")
        }
        XCTAssertEqual(ent.xdata["dxf.lineType"], .string("DASHED"))
        XCTAssertEqual(ent.xdata["dxf.lineTypeScale"], .double(2.5))
    }

    func testAutoContrastToggle() async throws {
        let host = makeHost()
        var env = LispEnvironment()

        // Default is ON (1)
        XCTAssertTrue(host.document.autoContrastTrueColor)
        let defVal = try await eval(#"(getvar "AUTOCONTRAST")"#, host: host, env: &env)
        XCTAssertEqual(defVal, .int(1))

        // Turn OFF via setvar
        _ = try await eval(#"(setvar "AUTOCONTRAST" 0)"#, host: host, env: &env)
        XCTAssertFalse(host.document.autoContrastTrueColor)
        let offVal = try await eval(#"(getvar "AUTOCONTRAST")"#, host: host, env: &env)
        XCTAssertEqual(offVal, .int(0))

        // Turn ON via command
        _ = try await eval(#"(command "_.AUTOCONTRAST" "ON")"#, host: host, env: &env)
        XCTAssertTrue(host.document.autoContrastTrueColor)

        // Toggle via command with empty enter
        _ = try await eval(#"(command "_.AUTOCONTRAST" "")"#, host: host, env: &env)
        XCTAssertFalse(host.document.autoContrastTrueColor)
    }

    func testEntmakeOverridesRoundTrip() async throws {
        let host = makeHost()
        var env = LispEnvironment()
        _ = try await eval(
            #"(entmake '((0 . "LINE") (10 0 0 0) (11 10 0 0) (6 . "HIDDEN") (48 . 3.0) (370 . 50) (420 . 1059649)))"#,
            host: host, env: &env)
        guard let handle = host.lastCreated, let ent = host.document.entity(for: handle) else {
            return XCTFail("entity should exist from entmake")
        }
        XCTAssertEqual(ent.xdata["dxf.lineType"], .string("HIDDEN"))
        XCTAssertEqual(ent.xdata["dxf.lineTypeScale"], .double(3.0))
        XCTAssertEqual(ent.xdata["dxf.lineWeight"], .double(0.5))
        XCTAssertEqual(ent.xdata["dxf.color24"], .int(1059649))

        let lt = try await eval(#"(cdr (assoc 6 (entget (entlast))))"#, host: host, env: &env)
        let s = try await eval(#"(cdr (assoc 48 (entget (entlast))))"#, host: host, env: &env)
        let c24 = try await eval(#"(cdr (assoc 420 (entget (entlast))))"#, host: host, env: &env)
        XCTAssertEqual(lt, .string("HIDDEN"))
        XCTAssertEqual(s.asDouble, 3.0)
        XCTAssertEqual(c24, .int(1059649))
    }
}

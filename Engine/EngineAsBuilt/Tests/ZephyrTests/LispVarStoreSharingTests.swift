import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// D7: the app has ONE system-variable store. Memory sysvars written by one
/// AutoLISP run must be visible to the next run (and to the ribbon's
/// per-frame predicates), matching AutoCAD.
@MainActor
final class LispVarStoreSharingTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        document.activeLayerID = document.findLayer(named: "0")?.handle
        return document
    }

    private func evaluate(
        _ source: String,
        document: CADDocument,
        vars: LispVarStore
    ) async throws -> LispValue {
        let host = LispCADHost(
            document: document,
            selection: CADSelectionManager(),
            vars: vars)
        host.output = { _ in }
        let forms = try LispReader().readAll(source)
        var env = LispEnvironment()
        return try await LispEvaluator().run(forms, env: &env, host: host)
    }

    func testSetvarSurvivesAcrossRunsOnASharedStore() async throws {
        let document = makeDocument()
        let vars = LispVarStore()

        _ = try await evaluate(
            "(setvar \"GRIDMODE\" 3)", document: document, vars: vars)
        let readBack = try await evaluate(
            "(getvar \"GRIDMODE\")", document: document, vars: vars)

        XCTAssertEqual(readBack, .int(3))
    }

    func testFreshStoresAreIsolated() async throws {
        let document = makeDocument()
        let first = LispVarStore()
        _ = try await evaluate(
            "(setvar \"GRIDMODE\" 3)", document: document, vars: first)

        // A second, independent store still reports the default.
        let second = LispVarStore()
        let readBack = try await evaluate(
            "(getvar \"GRIDMODE\")", document: document, vars: second)
        XCTAssertEqual(readBack, .int(0))
    }

    func testLispCommandHostsShareTheProcessorStore() {
        let processor = CADCommandProcessor()
        let document = makeDocument()
        let host = LispCommand.makeHost(
            document: document,
            selection: CADSelectionManager(),
            processor: processor,
            broker: LispInputBroker())

        XCTAssertTrue(
            host.vars === processor.lispVars,
            "every run must use the processor's app-wide sysvar store")
    }

    func testTwoLispCommandHostsSeeEachOthersSetvar() async throws {
        let processor = CADCommandProcessor()
        let document = makeDocument()

        let first = LispCommand.makeHost(
            document: document,
            selection: CADSelectionManager(),
            processor: processor,
            broker: LispInputBroker())
        first.output = { _ in }
        var env = LispEnvironment()
        _ = try await LispEvaluator().run(
            try LispReader().readAll("(setvar \"GRIDMODE\" 1)"),
            env: &env, host: first)

        let second = LispCommand.makeHost(
            document: document,
            selection: CADSelectionManager(),
            processor: processor,
            broker: LispInputBroker())
        second.output = { _ in }
        let readBack = try await LispEvaluator().run(
            try LispReader().readAll("(getvar \"GRIDMODE\")"),
            env: &env, host: second)

        XCTAssertEqual(readBack, .int(1))
    }

    func testSharedStoreIsReadableFromTheUIPath() throws {
        // The ribbon reads sysvars off the main thread each frame: the store
        // must answer without an evaluator or a host.
        let processor = CADCommandProcessor()
        let document = makeDocument()
        _ = processor.lispVars.set(
            "GRIDMODE", .int(1), document: document)
        XCTAssertEqual(
            processor.lispVars.get(
                "GRIDMODE", document: document, activeCommand: nil),
            .int(1))
    }
}

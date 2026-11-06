import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Threading contract for in-app Lisp evaluation: the eval task runs
/// detached and the SDL loop never pumps the main dispatch queue, so
/// NOTHING on the eval path may hop to MainActor (such a hop stalls
/// forever — the "Lisp running…" hang). These pin the hop-free seams:
/// cross-thread broker settle/cancel, selection snapshot + main-thread
/// drain, and the CMDNAMES snapshot.
@MainActor
final class LispThreadingTests: XCTestCase {

    // MARK: - Broker across threads

    func testBrokerRequestSettlesAcrossThreads() async throws {
        let broker = LispInputBroker()
        let waiter = Task.detached { try await broker.request(.point(prompt: "Pick:")) }
        await waitForPending(broker)
        broker.offer(.point([1, 2]))
        let event = try await waiter.value
        XCTAssertEqual(event, .point([1, 2]))
        XCTAssertEqual(broker.settleCount, 1)
    }

    func testBrokerCancelSettlesAcrossThreads() async throws {
        let broker = LispInputBroker()
        let waiter = Task.detached { try await broker.request(.line(prompt: "Text:", allowSpaces: false)) }
        await waitForPending(broker)
        broker.cancelPending()
        do {
            _ = try await waiter.value
            XCTFail("cancelled request should throw")
        } catch let error as LispError {
            XCTAssertEqual(error, .userCancel)
        }
    }

    /// Lets the detached waiter reach suspension (best-effort; the tests
    /// pass either way since early offers queue and drain).
    private func waitForPending(_ broker: LispInputBroker) async {
        for _ in 0..<1000 {
            if broker.hasPending { return }
            await Task.yield()
        }
    }

    // MARK: - Selection snapshot + drain

    func testSelectionSnapshotAndDrain() async throws {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        doc.activeLayerID = doc.findLayer(named: "0")?.handle
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        for x in [0.0, 5.0] {
            let forms = try LispReader().readAll(
                "((0 . \"POINT\") (10 \(x) 0 0))")
            _ = try await host.entMake(try XCTUnwrap(forms.first))
        }
        let handles = Set(doc.allEntities.map(\.handle))
        XCTAssertEqual(handles.count, 2)

        // Reads see the frozen pickfirst snapshot, not live state.
        host.captureMainThreadState(
            selectedHandles: [handles.first!], activeCommand: nil)
        let first = try await host.ssGetFirst()
        XCTAssertNotEqual(first, .nilValue)

        // Writes update the snapshot immediately and enqueue one drain.
        let all = try await host.ssGet(filter: nil)
        _ = try await host.ssSetFirst(all)
        XCTAssertEqual(host.takePendingSelectionApply(), handles)
        XCTAssertNil(host.takePendingSelectionApply())
    }

    // MARK: - CMDNAMES snapshot

    func testCmdNamesSnapshot() async throws {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        let host = LispCADHost(
            document: doc,
            selection: CADSelectionManager(),
            processor: CADCommandProcessor())
        host.captureMainThreadState(selectedHandles: [], activeCommand: "MOVE")
        let move = await host.getSystemVar("CMDNAMES")
        XCTAssertEqual(move, .string("MOVE"))
        host.captureMainThreadState(selectedHandles: [], activeCommand: nil)
        let none = await host.getSystemVar("CMDNAMES")
        XCTAssertEqual(none, .string(""))
    }
}

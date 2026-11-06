import XCTest
@testable import ZephyrLisp

/// Exactly-once invariant matrix for the input broker. Tests are plain
/// async (never @MainActor: the Windows XCTest shim cannot cast isolated
/// test methods); every broker call hops with await.
final class LispBrokerTests: XCTestCase {
    func testRequestOfferValue() async throws {
        let broker = await LispInputBroker()
        async let answer = broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
        await broker.offer(.line("hi"))
        let event = try await answer
        XCTAssertEqual(event, .line("hi"))
        let settles = await broker.settleCount
        XCTAssertEqual(settles, 1)
        let pending = await broker.hasPending
        XCTAssertFalse(pending)
    }

    func testOfferBeforeRequestDrains() async throws {
        let broker = await LispInputBroker()
        // grread pattern: events arrive before anyone awaits.
        await broker.offer(.device(LispValue(list: [.int(3)])))
        let queued = await broker.queuedCount
        XCTAssertEqual(queued, 1)
        let event = try await broker.requestCancellable(.device)
        XCTAssertEqual(event, .device(LispValue(list: [.int(3)])))
        let settles = await broker.settleCount
        XCTAssertEqual(settles, 1)
    }

    func testMismatchedOfferIsStale() async throws {
        let broker = await LispInputBroker()
        async let answer = broker.requestCancellable(.point(prompt: "p"))
        // Wait until the request is provably suspended (no queue shortcut).
        for _ in 0..<10_000 {
            if await broker.hasPending { break }
            await Task.yield()
        }
        let suspended = await broker.hasPending
        XCTAssertTrue(suspended)
        await broker.offer(.line("wrong kind"))
        let stale = await broker.staleCount
        XCTAssertEqual(stale, 1)
        let pending = await broker.hasPending
        XCTAssertTrue(pending, "mismatched offer must not settle")
        await broker.offer(.point([1, 2]))
        let event = try await answer
        XCTAssertEqual(event, .point([1, 2]))
        let settles = await broker.settleCount
        XCTAssertEqual(settles, 1)
    }

    func testCancelPendingThrowsUserCancel() async throws {
        let broker = await LispInputBroker()
        async let answer = broker.requestCancellable(.entity(prompt: "p"))
        // Wait until the request is provably suspended, then cancel it.
        var suspended = false
        for _ in 0..<10_000 {
            if await broker.hasPending {
                suspended = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(suspended, "request never suspended")
        await broker.cancelPending()
        do {
            _ = try await answer
            XCTFail("expected cancel")
        } catch let error as LispError {
            XCTAssertEqual(error, .userCancel)
        }
        let settles = await broker.settleCount
        XCTAssertEqual(settles, 1)
    }

    func testIdleCancelArmsNextRequest() async throws {
        let broker = await LispInputBroker()
        // Cancel with nothing outstanding arms the flag (a cancel racing
        // request startup wins): the next request throws without suspending.
        await broker.cancelPending()
        do {
            _ = try await broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
            XCTFail("expected cancel")
        } catch let error as LispError {
            XCTAssertEqual(error, .userCancel)
        }
        let pending = await broker.hasPending
        XCTAssertFalse(pending)
    }

    func testTaskCancelSettlesOnce() async throws {
        let broker = await LispInputBroker()
        let task = Task {
            try await broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
        }
        // Wait until the request is provably suspended, then cancel it.
        var suspended = false
        for _ in 0..<10_000 {
            if await broker.hasPending {
                suspended = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(suspended, "request never suspended")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancel")
        } catch let error as LispError {
            XCTAssertEqual(error, .userCancel)
        }
        let settles = await broker.settleCount
        XCTAssertEqual(settles, 1)
        let pending = await broker.hasPending
        XCTAssertFalse(pending)
    }

    func testPostSettleOfferIgnored() async throws {
        let broker = await LispInputBroker()
        async let answer = broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
        await broker.offer(.line("first"))
        _ = try await answer
        // Slot is idle now: the late offer queues (harmless), never resumes.
        await broker.offer(.line("late"))
        let settles = await broker.settleCount
        XCTAssertEqual(settles, 1)
        let queued = await broker.queuedCount
        XCTAssertEqual(queued, 1)
    }

    func testQueueBound() async throws {
        let broker = await LispInputBroker()
        for _ in 0..<(LispInputBroker.queueBound + 10) {
            await broker.offer(.line("x"))
        }
        let queued = await broker.queuedCount
        XCTAssertEqual(queued, LispInputBroker.queueBound)
    }

    func testSpamFuzzSettlesExactlyOnce() async throws {
        let broker = await LispInputBroker()
        async let answer = broker.requestCancellable(.point(prompt: "p"))
        // Wait until the request is provably suspended: without the wait,
        // offers race request startup and the winner is timing-dependent.
        var suspended = false
        for _ in 0..<10_000 {
            if await broker.hasPending {
                suspended = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(suspended, "request never suspended")
        // 200 rapid offers of mixed kinds; only point offers can settle,
        // and only the first of those.
        for index in 0..<200 {
            if index % 3 == 0 {
                await broker.offer(.line("noise"))
            } else {
                await broker.offer(.point([Double(index)]))
            }
        }
        let event = try await answer
        // First point offer wins (index 1).
        XCTAssertEqual(event, .point([1.0]))
        let settles = await broker.settleCount
        XCTAssertEqual(settles, 1)
        let pending = await broker.hasPending
        XCTAssertFalse(pending)
    }

    func testDrainQueueDisarms() async throws {
        let broker = await LispInputBroker()
        await broker.offer(.line("stale"))
        await broker.drainQueue()
        let queued = await broker.queuedCount
        XCTAssertEqual(queued, 0)
    }
}

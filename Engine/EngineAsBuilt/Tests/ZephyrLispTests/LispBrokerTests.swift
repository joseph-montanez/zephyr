import XCTest
@testable import ZephyrLisp

/// Exactly-once invariant matrix for the input broker. Tests are plain
/// async (never @MainActor: the Windows XCTest shim cannot cast isolated
/// test methods); every broker call hops with await.
final class LispBrokerTests: XCTestCase {
    func testRequestOfferValue() async throws {
        let broker = LispInputBroker()
        async let answer = broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
        broker.offer(.line("hi"))
        let event = try await answer
        XCTAssertEqual(event, .line("hi"))
        let settles = broker.settleCount
        XCTAssertEqual(settles, 1)
        let pending = broker.hasPending
        XCTAssertFalse(pending)
    }

    func testOfferBeforeRequestDrains() async throws {
        let broker = LispInputBroker()
        // grread pattern: events arrive before anyone awaits.
        broker.offer(.device(LispValue(list: [.int(3)])))
        let queued = broker.queuedCount
        XCTAssertEqual(queued, 1)
        let event = try await broker.requestCancellable(.device)
        XCTAssertEqual(event, .device(LispValue(list: [.int(3)])))
        let settles = broker.settleCount
        XCTAssertEqual(settles, 1)
    }

    func testMismatchedOfferIsStale() async throws {
        let broker = LispInputBroker()
        async let answer = broker.requestCancellable(.point(prompt: "p"))
        // Wait until the request is provably suspended (no queue shortcut).
        for _ in 0..<10_000 {
            if broker.hasPending { break }
            await Task.yield()
        }
        let suspended = broker.hasPending
        XCTAssertTrue(suspended)
        broker.offer(.line("wrong kind"))
        let stale = broker.staleCount
        XCTAssertEqual(stale, 1)
        let pending = broker.hasPending
        XCTAssertTrue(pending, "mismatched offer must not settle")
        broker.offer(.point([1, 2]))
        let event = try await answer
        XCTAssertEqual(event, .point([1, 2]))
        let settles = broker.settleCount
        XCTAssertEqual(settles, 1)
    }

    func testCancelPendingThrowsUserCancel() async throws {
        let broker = LispInputBroker()
        async let answer = broker.requestCancellable(.entity(prompt: "p"))
        // Wait until the request is provably suspended, then cancel it.
        var suspended = false
        for _ in 0..<10_000 {
            if broker.hasPending {
                suspended = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(suspended, "request never suspended")
        broker.cancelPending()
        do {
            _ = try await answer
            XCTFail("expected cancel")
        } catch let error as LispError {
            XCTAssertEqual(error, .userCancel)
        }
        let settles = broker.settleCount
        XCTAssertEqual(settles, 1)
    }

    func testIdleCancelArmsNextRequest() async throws {
        let broker = LispInputBroker()
        // Cancel with nothing outstanding arms the flag (a cancel racing
        // request startup wins): the next request throws without suspending.
        broker.cancelPending()
        do {
            _ = try await broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
            XCTFail("expected cancel")
        } catch let error as LispError {
            XCTAssertEqual(error, .userCancel)
        }
        let pending = broker.hasPending
        XCTAssertFalse(pending)
    }

    func testTaskCancelSettlesOnce() async throws {
        let broker = LispInputBroker()
        let task = Task {
            try await broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
        }
        // Wait until the request is provably suspended, then cancel it.
        var suspended = false
        for _ in 0..<10_000 {
            if broker.hasPending {
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
        let settles = broker.settleCount
        XCTAssertEqual(settles, 1)
        let pending = broker.hasPending
        XCTAssertFalse(pending)
    }

    func testPostSettleOfferIgnored() async throws {
        let broker = LispInputBroker()
        async let answer = broker.requestCancellable(.line(prompt: "p", allowSpaces: false))
        broker.offer(.line("first"))
        _ = try await answer
        // Slot is idle now: the late offer queues (harmless), never resumes.
        broker.offer(.line("late"))
        let settles = broker.settleCount
        XCTAssertEqual(settles, 1)
        let queued = broker.queuedCount
        XCTAssertEqual(queued, 1)
    }

    func testQueueBound() async throws {
        let broker = LispInputBroker()
        for _ in 0..<(LispInputBroker.queueBound + 10) {
            broker.offer(.line("x"))
        }
        let queued = broker.queuedCount
        XCTAssertEqual(queued, LispInputBroker.queueBound)
    }

    func testSpamFuzzSettlesExactlyOnce() async throws {
        let broker = LispInputBroker()
        async let answer = broker.requestCancellable(.point(prompt: "p"))
        // Wait until the request is provably suspended: without the wait,
        // offers race request startup and the winner is timing-dependent.
        var suspended = false
        for _ in 0..<10_000 {
            if broker.hasPending {
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
                broker.offer(.line("noise"))
            } else {
                broker.offer(.point([Double(index)]))
            }
        }
        let event = try await answer
        // First point offer wins (index 1).
        XCTAssertEqual(event, .point([1.0]))
        let settles = broker.settleCount
        XCTAssertEqual(settles, 1)
        let pending = broker.hasPending
        XCTAssertFalse(pending)
    }

    func testDrainQueueDisarms() async throws {
        let broker = LispInputBroker()
        broker.offer(.line("stale"))
        broker.drainQueue()
        let queued = broker.queuedCount
        XCTAssertEqual(queued, 0)
    }
}


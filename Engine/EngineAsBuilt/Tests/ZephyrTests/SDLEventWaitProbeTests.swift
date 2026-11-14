import XCTest
import CSDL3

/// Probe: does `SDL_WaitEventTimeout(nil, …)` — used as the engine's idle
/// wait — consume the event that wakes it? A pushed MOUSE_BUTTON_DOWN must
/// still be pollable afterwards.
final class SDLEventWaitProbeTests: XCTestCase {

    func testWaitEventTimeoutNilDoesNotConsumeButtonDown() {
        XCTAssertTrue(SDL_InitSubSystem(SDL_INIT_EVENTS))
        defer { SDL_QuitSubSystem(SDL_INIT_EVENTS) }

        var down = SDL_Event()
        down.type = UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue)
        down.button.windowID = 3
        down.button.button = 1
        down.button.x = 50
        down.button.y = 60
        XCTAssertTrue(SDL_PushEvent(&down))

        XCTAssertTrue(SDL_WaitEventTimeout(nil, 1))

        var out = SDL_Event()
        XCTAssertTrue(SDL_PollEvent(&out),
                      "MOUSE_BUTTON_DOWN vanished after SDL_WaitEventTimeout(nil, 1)")
        XCTAssertEqual(out.type, UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue))
        XCTAssertEqual(out.button.windowID, 3)
        XCTAssertEqual(out.button.x, 50)
    }

    /// Corroborates the lazy-loop wake cadence the predicate rests on:
    /// with an empty queue the wait must return false within a bounded
    /// time (the loop re-evaluates its predicate every iteration).
    func testWaitEventTimeoutNilTimesOutOnEmptyQueue() {
        XCTAssertTrue(SDL_InitSubSystem(SDL_INIT_EVENTS))
        defer { SDL_QuitSubSystem(SDL_INIT_EVENTS) }

        // Drain any residue from a prior probe.
        var out = SDL_Event()
        while SDL_PollEvent(&out) {}

        let started = Date()
        let woke = SDL_WaitEventTimeout(nil, 16)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(woke, "empty-queue wait must time out, not report an event")
        XCTAssertLessThan(elapsed, 1.0, "idle wait must stay bounded (loop cadence)")
    }
}

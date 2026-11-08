import Foundation

// LispInputBroker: exactly-once suspension bridge for interactive input.
//
// The evaluator awaits request() on a background task; main-thread UI event
// handlers answer with offer(). At most one request is outstanding per
// broker (Lisp evaluation is single-threaded). A bounded FIFO holds events
// that arrive early (notably for grread, which drains the queue first).
//
// Threading: this type is UNISOLATED (deliberately not @MainActor). The
// app's hand-rolled SDL loop never pumps the main dispatch queue, so a
// background task awaiting a MainActor hop would stall forever. All state
// serializes on one NSLock instead; continuations resume on whatever
// thread settles them (offer/cancel run on main, request runs on pool).
//
// Leak-proofing by construction:
// - Every settle path takes-and-nils the slot FIRST (under the lock),
//   then resumes outside the lock. Double-resume and stale-resume are
//   impossible; stale offers are ignored and counted.
// - The reservation/fill protocol closes the gap between token allocation
//   (which cannot hold the lock across suspension) and continuation
//   storage: gap arrivals queue and are re-drained at fill time, and a
//   gap cancel takes the reservation so the fill fails fast. No lost
//   wakeups in either direction.
// - The continuation never escapes this type: value, cancel, and
//   task-cancel all funnel through the same take-then-resume choke point.
// - Checked continuations trap on misuse in debug builds, turning any
//   future protocol violation into a loud test failure.

/// One interactive input transaction.
public final class LispInputBroker: @unchecked Sendable {
    /// What the evaluator is waiting for.
    public enum RequestKind: Sendable, Equatable {
        case point(prompt: String)
        case line(prompt: String, allowSpaces: Bool)
        case entity(prompt: String)
        case device
    }

    /// One answered input. Mismatched kinds never settle a request.
    public enum Event: Sendable, Equatable {
        case point([Double]?)
        case line(String?)
        case entity(handle: String?, point: [Double]?)
        case device(LispValue)
    }

    public nonisolated static let queueBound = 64

    private let lock = NSLock()
    private var generation = 0
    /// Reserved request slot. The continuation starts nil: reservation
    /// happens before suspension (the lock cannot span the await), and the
    /// continuation body fills it — re-draining gap arrivals first.
    private var slot: (token: Int, kind: RequestKind,
        continuation: CheckedContinuation<Event, Error>?)?
    /// Armed by task cancellation; consumed by the next request() pre-check.
    /// The arm/check/store sequence runs under the lock: cancellation is
    /// never lost and never double-fires.
    private var cancelArmed = false

    private var queue: [Event] = []

    // MARK: - Test hooks (counters only; no behavior)

    /// Successful settles (exactly one per completed request).
    private var _settleCount = 0
    /// Offers ignored as stale or mismatched.
    private var _staleCount = 0
    public var settleCount: Int { lock.withLock { _settleCount } }
    public var staleCount: Int { lock.withLock { _staleCount } }
    public var queuedCount: Int { lock.withLock { queue.count } }
    public var hasPending: Bool { lock.withLock { slot != nil } }
    /// The outstanding request kind, if any. The CAD driver uses this to
    /// offer exactly one matching event per UI gesture (offering several
    /// would queue the losers as stale input after the first settles).
    public var pendingKind: RequestKind? { lock.withLock { slot?.kind } }

    /// Fires on wait-state transitions: non-nil when evaluation parks for
    /// input, nil when the wait settles. Set by drivers (e.g. the MCP
    /// server) that must react the instant evaluation blocks instead of
    /// polling. Invoked outside the lock on the settling thread.
    public var waitObserver: (@Sendable (RequestKind?) -> Void)? {
        get { lock.withLock { _waitObserver } }
        set { lock.withLock { _waitObserver = newValue } }
    }
    private var _waitObserver: (@Sendable (RequestKind?) -> Void)?

    private func notifyWait(_ kind: RequestKind?) {
        let observer = lock.withLock { _waitObserver }
        observer?(kind)
    }

    public init() {}

    // MARK: - Await side (evaluator, via the host)

    private enum RequestStart {
        case cancel
        case drained(Event)
        case suspend(Int)
    }

    /// Suspends until a matching event arrives. Throws .userCancel on
    /// cancellation (explicit cancel, task cancel, or cancel event).
    public func request(_ kind: RequestKind) async throws -> Event {
        let start: RequestStart = lock.withLock {
            if cancelArmed {
                cancelArmed = false
                return .cancel
            }
            // Drain the first queued match before suspending (grread pattern).
            if let index = queue.firstIndex(where: { matches($0, kind: kind) }) {
                let event = queue.remove(at: index)
                _settleCount += 1
                return .drained(event)
            }
            generation += 1
            let token = generation
            precondition(slot == nil, "LispInputBroker supports one outstanding request")
            slot = (token, kind, nil)
            return .suspend(token)
        }
        switch start {
        case .cancel:
            throw LispError.userCancel
        case .drained(let event):
            return event
        case .suspend(let token):
            return try await withCheckedThrowingContinuation { continuation in
                self.fill(token: token, kind: kind, continuation: continuation)
            }
        }
    }

    private enum Fill {
        case filled
        case drained(Event)
        case cancelled
    }

    /// Stores the fresh continuation, re-draining events that arrived in
    /// the reservation gap and failing fast if a gap cancel took the slot.
    private func fill(
        token: Int, kind: RequestKind,
        continuation: CheckedContinuation<Event, Error>
    ) {
        let fill: Fill = lock.withLock {
            guard let current = slot, current.token == token else {
                return .cancelled
            }
            if let index = queue.firstIndex(where: { matches($0, kind: kind) }) {
                let event = queue.remove(at: index)
                slot = nil
                _settleCount += 1
                return .drained(event)
            }
            slot = (token: current.token, kind: current.kind, continuation: continuation)
            return .filled
        }
        switch fill {
        case .filled:
            notifyWait(kind)
        case .drained(let event):
            notifyWait(nil)
            continuation.resume(returning: event)
        case .cancelled:
            notifyWait(nil)
            continuation.resume(throwing: LispError.userCancel)
        }
    }

    /// Cancels the pending request (Esc path). Settles the live slot when
    /// one is outstanding; when idle, arms the flag so the NEXT request
    /// throws instead of suspending — a cancel racing request startup wins
    /// either way, exactly once. `drainQueue()` disarms (phase boundaries).
    public func cancelPending() {
        // Take-before-resume: only the live slot settles, exactly once.
        // A nil-continuation reservation taken here just drops: the fill
        // sees the missing slot and fails fast — no lost wakeup.
        let continuation: CheckedContinuation<Event, Error>? = lock.withLock {
            guard let current = slot else {
                cancelArmed = true
                return nil
            }
            slot = nil
            _settleCount += 1
            return current.continuation
        }
        if continuation != nil { notifyWait(nil) }
        continuation?.resume(throwing: LispError.userCancel)
    }

    // MARK: - Offer side (UI event handlers)

    /// Offers one event: settles a matching pending request, else queues
    /// (bounded, drop-oldest). Never blocks, never throws.
    public func offer(_ event: Event) {
        let continuation: CheckedContinuation<Event, Error>? = lock.withLock {
            guard let current = slot else {
                appendBounded(event)
                return nil
            }
            guard let cont = current.continuation else {
                // Reservation not yet filled: matching events queue for the
                // fill-time re-drain; mismatches drop as stale.
                if matches(event, kind: current.kind) {
                    appendBounded(event)
                } else {
                    _staleCount += 1
                }
                return nil
            }
            guard matches(event, kind: current.kind) else {
                _staleCount += 1
                return nil
            }
            slot = nil
            _settleCount += 1
            return cont
        }
        notifyWait(nil)
        continuation?.resume(returning: event)
    }

    /// Clears queued events and disarms cancellation (command boundaries).
    /// Pending requests are untouched.
    public func drainQueue() {
        lock.withLock {
            queue.removeAll()
            cancelArmed = false
        }
    }

    // MARK: - Choke point

    private func appendBounded(_ event: Event) {
        queue.append(event)
        if queue.count > Self.queueBound {
            queue.removeFirst(queue.count - Self.queueBound)
        }
    }

    private func matches(_ event: Event, kind: RequestKind) -> Bool {
        switch (event, kind) {
        case (.point, .point), (.line, .line),
            (.entity, .entity), (.device, .device):
            return true
        default:
            return false
        }
    }
}

// MARK: - Task-cancellation adapter (host-side helper)

extension LispInputBroker {
    /// request() that also settles on Swift task cancellation: the
    /// cancellation handler funnels through cancelPending(), preserving
    /// exactly-once even when the awaiting task is cancelled first.
    /// Runs fully inline (no actor hop — see the threading note above).
    public func requestCancellable(_ kind: RequestKind) async throws -> Event {
        if Task.isCancelled { throw LispError.userCancel }
        return try await withTaskCancellationHandler {
            try await request(kind)
        } onCancel: {
            self.armCancel()
        }
    }

    private func armCancel() {
        lock.withLock { cancelArmed = true }
        cancelPending()
    }
}

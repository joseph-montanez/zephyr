import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - MCPEval
//
// MCP-side AutoLISP driving. Mirrors LispCommand's launch/run/complete path
// (same host construction, same session check-in, same undo auto-close) but
// with an MCP-owned completion box and a completion-or-waiting race shared
// by eval_lisp and provide_input: whichever resolves first — the eval task
// storing its outcome, or the broker parking on a new input request — wins
// the turn. No timeouts, no slow-command misclassification.
// =========================================================================

/// Outcome of one evaluation, mirroring LispCommand.Outcome.
enum MCPEvalOutcome: Sendable {
    case value(String)
    case error(String)
    case cancelled
}

/// One single-flight evaluation owned by the MCP server.
final class MCPEvalSession: @unchecked Sendable {
    let broker = LispInputBroker()
    private let cond = NSCondition()
    private var box: (outcome: MCPEvalOutcome, env: LispEnvironment)?
    private var waitingKind: LispInputBroker.RequestKind?
    private var outputChunks: [String] = []
    /// Set on the frame thread during setup; read for prompts.
    var host: LispCADHost?
    var evalTask: Task<Void, Never>?

    enum Turn {
        case completed
        case waiting(LispInputBroker.RequestKind)
    }

    func appendOutput(_ text: String) {
        cond.lock()
        outputChunks.append(text)
        cond.unlock()
    }

    func takeOutput() -> String {
        cond.lock()
        defer { cond.unlock() }
        let out = outputChunks.joined()
        outputChunks.removeAll()
        return out
    }

    func noteWait(_ kind: LispInputBroker.RequestKind?) {
        cond.lock()
        if kind != nil { waitingKind = kind }
        cond.broadcast()
        cond.unlock()
    }

    func noteDone(outcome: MCPEvalOutcome, env: LispEnvironment) {
        cond.lock()
        box = (outcome, env)
        cond.broadcast()
        cond.unlock()
    }

    /// The shared race: completion wins over waiting; waiting wins over
    /// blocking. Called by eval_lisp after launch and by provide_input
    /// after every offer (a satisfied prompt usually parks on the next one).
    func takeTurn() -> Turn {
        cond.lock()
        defer { cond.unlock() }
        while true {
            if box != nil { return .completed }
            if let kind = waitingKind { return .waiting(kind) }
            cond.wait()
        }
    }

    /// Clears the stale wait flag after an offer settles the broker
    /// (the settle fires observer(nil), which takeTurn ignores by design).
    func clearWait() {
        cond.lock()
        waitingKind = nil
        cond.unlock()
    }

    func takeBox() -> (outcome: MCPEvalOutcome, env: LispEnvironment)? {
        cond.lock()
        defer { cond.unlock() }
        defer { box = nil }
        return box
    }
}

// MARK: - Evaluation body (detached task, no MainActor hop)

enum MCPEvalDriver {
    /// Mirrors LispCommand.runDetached for expression evaluation.
    static func runEval(
        source: String, host: LispCADHost, env: LispEnvironment
    ) async -> (MCPEvalOutcome, LispEnvironment) {
        var env = env
        do {
            let forms = try LispReader().readAll(source)
            let result = try await LispEvaluator().run(forms, env: &env, host: host)
            return (.value(result.prin1String), env)
        } catch let error as LispError {
            if case .userCancel = error { return (.cancelled, env) }
            return (.error("\(error)"), env)
        } catch is CancellationError {
            return (.cancelled, env)
        } catch {
            return (.error("\(error)"), env)
        }
    }

    /// Mirrors LispCommand.runDetached for .load (file text evaluated).
    static func runLoad(
        fileText: String, host: LispCADHost, env: LispEnvironment
    ) async -> (MCPEvalOutcome, LispEnvironment) {
        await runEval(source: fileText, host: host, env: env)
    }

    /// Scripted native command: (command "NAME" args...). Argument words
    /// tokenize exactly like .scr lines (points, numbers, strings).
    static func runNativeCommand(
        name: String, argLine: String, host: LispCADHost
    ) async throws -> LispValue {
        try await host.runCommand(
            [.string(name)] + mcpParseScriptLine(argLine))
    }
}

// MARK: - Local mirrors of MainActor-isolated LispCommand parsers

/// Tokenizes one script line. Mirrors LispCommand.parseScriptLine exactly
/// (kept local: that helper is MainActor-isolated, and MCP input mapping
/// runs on socket threads that must never hop).
func mcpParseScriptLine(_ line: String) -> [LispValue] {
    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { token in
        let word = String(token)
        if word.contains(","),
           let coords = mcpParsePointText(word, base: nil),
           coords.count >= 2
        {
            return LispValue(list: coords.map(LispValue.real))
        }
        if let int = Int(word) { return .int(int) }
        if let double = Double(word) { return .real(double) }
        return .string(word)
    }
}

/// Parses typed point text. Mirrors LispCommand.parsePointText exactly
/// (kept local for the same isolation reason as mcpParseScriptLine).
func mcpParsePointText(_ text: String, base: [Double]?) -> [Double]? {
    var cleaned = text.trimmingCharacters(in: .whitespaces)
    var relative = false
    if cleaned.hasPrefix("@") {
        relative = true
        cleaned = String(cleaned.dropFirst())
    }
    let parts = cleaned
        .replacingOccurrences(of: ",", with: " ")
        .split(whereSeparator: { $0 == " " || $0 == "\t" })
        .compactMap { Double(String($0)) }
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    let tokens = cleaned
        .replacingOccurrences(of: ",", with: " ")
        .split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard tokens.count == parts.count else { return nil }
    if parts.count == 1, !relative { return parts }
    guard parts.count >= 2 else { return nil }
    if relative {
        guard let base, base.count >= 2 else { return nil }
        let x = base[0] + parts[0], y = base[1] + parts[1]
        if parts.count > 2 || base.count > 2 {
            return [x, y, (base.count > 2 ? base[2] : 0) + (parts.count > 2 ? parts[2] : 0)]
        }
        return [x, y]
    }
    return parts.count == 2 ? [parts[0], parts[1]] : parts
}

// MARK: - Input mapping (mirrors LispCommand.handleCommandText)

/// Maps a provide_input call onto one broker offer. Returns nil on success
/// or a human-readable error when the text cannot satisfy the pending kind.
func mcpOfferInput(
    text: String, point: [Double]?,
    host: LispCADHost
) -> String? {
    switch host.broker.pendingKind {
    case .line:
        host.broker.offer(.line(text.isEmpty ? nil : text))
        return nil
    case .point:
        if let pt = point, (2...3).contains(pt.count), pt.allSatisfy({ $0.isFinite }) {
            host.broker.offer(.point(pt))
            return nil
        }
        if text.isEmpty {
            host.broker.offer(.point(nil))
            return nil
        }
        if let coords = mcpParsePointText(text, base: host.pendingBase) {
            host.broker.offer(.point(coords))
            return nil
        }
        return "Invalid point. Send \"X,Y\" text or a [x, y] point."
    case .entity:
        if let pt = point, (2...3).contains(pt.count) {
            // Aperture pick mirroring LispCommand.pickEntity: smallest live
            // bounding box containing the point, else a miss (host re-prompts).
            if let hit = mcpPickEntity(host.document, x: pt[0], y: pt[1]) {
                host.broker.offer(.entity(handle: hit.handle, point: [pt[0], pt[1]]))
            } else {
                host.broker.offer(.entity(handle: nil, point: [pt[0], pt[1]]))
            }
            return nil
        }
        if text.isEmpty {
            host.broker.offer(.entity(handle: nil, point: nil))
            return nil
        }
        return "Entity waits take a [x, y] point or empty text for none."
    case .device:
        if let pt = point, pt.count >= 2 {
            host.broker.offer(.device(LispValue(list: [
                .int(3), .real(pt[0]), .real(pt[1]),
            ])))
            return nil
        }
        guard let scalar = text.unicodeScalars.first else {
            return "grread waits take one character of text or a [x, y] point."
        }
        host.broker.offer(.device(LispValue(list: [
            .int(2), .int(Int(scalar.value)),
        ])))
        return nil
    case nil:
        return "Evaluation is computing, not waiting for input."
    }
}

/// Bounding-box aperture pick: smallest-area live bounding box containing
/// the point. Mirrors LispCommand.pickEntity for headless callers.
func mcpPickEntity(
    _ document: CADDocument, x: Double, y: Double
) -> (handle: String, point: [Double])? {
    var best: (handle: String, area: Double)?
    for entity in document.allEntities {
        guard let box = entity.worldBoundingBox,
              x >= box.min.x, x <= box.max.x,
              y >= box.min.y, y <= box.max.y
        else { continue }
        let area = (box.max.x - box.min.x) * (box.max.y - box.min.y)
        if best == nil || area < best!.area {
            best = (entity.handle.uuidString, area)
        }
    }
    guard let best else { return nil }
    return (best.handle, [x, y])
}

/// JSON-friendly description of a pending input request.
func mcpDescribeWait(
    _ kind: LispInputBroker.RequestKind, prompt: String
) -> [String: Any] {
    switch kind {
    case let .point(prompt_):
        return ["input": "point", "prompt": prompt.isEmpty ? prompt_ : prompt]
    case let .line(prompt_, allowSpaces):
        return ["input": "text", "prompt": prompt.isEmpty ? prompt_ : prompt,
                "allowSpaces": allowSpaces]
    case let .entity(prompt_):
        return ["input": "entity", "prompt": prompt.isEmpty ? prompt_ : prompt]
    case .device:
        return ["input": "grread", "prompt": prompt]
    }
}

import Foundation
import Dispatch

// =========================================================================
// MARK: - MCPServer
//
// In-process MCP server for the live app. Owns a localhost HTTP listener
// (POST /mcp carrying JSON-RPC, GET /health) and a single AI session:
// pinned frustum, reference overlay, at most one live evaluation.
//
// Threading contract (the engine is @MainActor behind an unpumped SDL
// loop, so background threads can never hop to it):
//   - The socket threads do pure compute + synchronization only.
//   - ALL engine touches run on the loop thread inside drainFrame(), which
//     the app calls from its updateBlock every frame (rendered or not).
//   - Lisp evaluation itself runs on a detached task exactly like
//     LispCommand; only setup/finish run on the frame.
//   - LispInputBroker.offer is unisolated: provide_input never needs a frame.
// =========================================================================

enum MCPError: Error, Sendable {
    case frameTimeout
    case notRunning
    case busy(String)
    case noSession
    case badParams(String)
    case toolFailed(String)
}

/// Internal: the task queue is shared with the tool implementation file.
final class MCPFrameTask: @unchecked Sendable {
    var run: (@MainActor () -> Void)?
    let sema = DispatchSemaphore(value: 0)
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}

private final class MCPBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Loaded reference floor plan with its world-space mapping.
struct MCPReference: Sendable {
    var image: MCPPngImage
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
}

public final class MCPServer: @unchecked Sendable {
    public static let shared = MCPServer()

    /// Internal (not private): the tool implementation file shares it.
    let lock = NSLock()
    /// Weak engine ref, assigned on MainActor at startup, touched only on
    /// the loop thread inside drainFrame().
    nonisolated(unsafe) weak var engine: PhrostEngine?
    var listener: MCPTCPListener?
    var running = false

    // MARK: Session state (socket-thread confined behind lock)

    var tasks: [MCPFrameTask] = []
    var _frustum: MCPFrustum?
    var _reference: MCPReference?
    var _thumbW = 800
    var _thumbH = 600
    var _showGrid = true
    var _overlayOpacity = 0.35
    var _session: MCPEvalSession?

    // MARK: Startup (MainActor: called from ZephyrApp.main)

    @MainActor
    public func attachAndStart(port: Int, engine: PhrostEngine) throws {
        lock.withLock {
            self.engine = engine
        }
        let listener = try MCPTCPListener(port: UInt16(port & 0xFFFF))
        lock.withLock {
            self.listener = listener
            running = true
        }
        print("[MCP] listening on 127.0.0.1:\(port) (POST /mcp)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    // MARK: Frame bridge (loop thread only)

    /// Drains queued frame tasks. Called from the engine's updateBlock —
    /// runs every loop iteration, rendered frames or idle.
    public func drainFrame() {
        var pending: [MCPFrameTask] = []
        var hasSession = false
        lock.withLock {
            pending = tasks
            tasks.removeAll()
            hasSession = _session != nil
        }
        guard !pending.isEmpty || hasSession else { return }
        // The loop thread IS the main thread: assumeIsolated is the
        // sanctioned escape hatch for hand-rolled main loops.
        MainActor.assumeIsolated {
            for task in pending {
                task.run?()
                task.sema.signal()
            }
            drainSelectionApply()
        }
    }

    /// submitFrame runs a closure on the loop thread and blocks the caller
    /// for the result. Socket threads only — never the main thread.
    /// Unconstrained T (JSON dicts are not Sendable): the semaphore join
    /// is the memory barrier, and values never see concurrent mutation.
    func submitFrame<T>(
        _ work: @escaping @MainActor () -> T, timeout: TimeInterval = 10
    ) throws -> T {
        precondition(
            !Thread.isMainThread, "MCP frame tasks must not run on the main thread")
        let box = MCPBox<T>()
        let task = MCPFrameTask({ box.value = work() })
        lock.withLock { tasks.append(task) }
        guard task.sema.wait(timeout: .now() + timeout) == .success else {
            throw MCPError.frameTimeout
        }
        return box.value!
    }

    /// Mirrors LispCommand.renderOverlay's selection drain for the MCP host.
    /// MainActor: reads the loop-thread engine state set at attach time.
    @MainActor
    private func drainSelectionApply() {
        guard let session = lock.withLock({ _session }),
              let host = session.host,
              let engine = engine,
              let pending = host.takePendingSelectionApply()
        else { return }
        engine.cadSelection.selectedHandles = pending
    }

    // MARK: Accept loop (background thread)

    private func acceptLoop() {
        while true {
            let alive: Bool = lock.withLock { running }
            guard alive else { return }
            do {
                guard let listener = lock.withLock({ listener }) else { return }
                let conn = try listener.acceptConnection()
                Thread.detachNewThread { [weak self] in
                    self?.handleConnection(conn)
                }
            } catch {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func handleConnection(_ conn: MCPTCPConnection) {
        defer { conn.close() }
        do {
            let request = try readHTTPRequest(conn)
            let (status, body): (Int, Data)
            if request.method == "GET", request.path == "/health" {
                body = try JSONSerialization.data(
                    withJSONObject: ["status": "ok"], options: [])
                status = 200
            } else if request.method == "POST", request.path == "/mcp" {
                body = handleJSONRPC(request.body)
                status = 200
            } else {
                body = try JSONSerialization.data(
                    withJSONObject: ["error": "not found"], options: [])
                status = 404
            }
            try writeHTTPResponse(conn, status: status, body: body)
        } catch {
            try? writeHTTPResponse(
                conn, status: 400,
                body: Data("{\"error\":\"bad request\"}".utf8))
        }
    }

    private struct HTTPRequest {
        var method: String
        var path: String
        var body: Data
    }

    private func readHTTPRequest(_ conn: MCPTCPConnection) throws -> HTTPRequest {
        var head = Data()
        while head.count < 65_536 {
            let chunk = try conn.readExactly(1)
            head.append(chunk)
            if head.count >= 4,
               head.suffix(4).elementsEqual([13, 10, 13, 10])
            {
                break
            }
        }
        guard let headText = String(data: head, encoding: .utf8) else {
            throw MCPError.badParams("unreadable headers")
        }
        let lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { throw MCPError.badParams("request line") }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2,
               kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard contentLength >= 0, contentLength <= 8_000_000 else {
            throw MCPSocketError.tooLarge
        }
        let body = contentLength > 0 ? try conn.readExactly(contentLength) : Data()
        return HTTPRequest(
            method: String(requestLine[0]), path: String(requestLine[1]), body: body)
    }

    private func writeHTTPResponse(
        _ conn: MCPTCPConnection, status: Int, body: Data
    ) throws {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        try conn.write(Data(head.utf8) + body)
    }

    // MARK: JSON-RPC

    private func handleJSONRPC(_ body: Data) -> Data {
        var id: Any = NSNull()
        do {
            guard let msg = try JSONSerialization.jsonObject(
                with: body, options: []) as? [String: Any]
            else { throw MCPError.badParams("not an object") }
            id = msg["id"] ?? NSNull()
            guard let method = msg["method"] as? String else {
                throw MCPError.badParams("missing method")
            }
            let params = msg["params"] as? [String: Any] ?? [:]
            let result = try dispatch(method: method, params: params)
            return rpcSuccess(id: id, result: result)
        } catch let err as MCPError {
            return rpcFailure(id: id, code: -32602, message: mcpMessage(err))
        } catch {
            return rpcFailure(id: id, code: -32603, message: "\(error)")
        }
    }

    private func mcpMessage(_ err: MCPError) -> String {
        switch err {
        case .frameTimeout: return "engine frame did not respond (timeout)"
        case .notRunning: return "evaluation already running; cancel_eval first"
        case let .busy(m): return m
        case .noSession: return "no active evaluation"
        case let .badParams(m): return m
        case let .toolFailed(m): return m
        }
    }

    private func rpcSuccess(id: Any, result: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": result,
        ], options: [])) ?? Data("{\"jsonrpc\":\"2.0\",\"result\":null}".utf8)
    }

    private func rpcFailure(id: Any, code: Int, message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": code, "message": message],
        ], options: [])) ?? Data("{\"jsonrpc\":\"2.0\",\"error\":{}}".utf8)
    }

    // MARK: Dispatch

    private func dispatch(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            return ["protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "zephyr-mcp", "version": "1.0.0"]]
        case "notifications/initialized":
            return [:] as [String: Any]
        case "ping":
            return [:] as [String: Any]
        case "tools/list":
            return ["tools": MCPToolDefs.list]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPError.badParams("tools/call needs a name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            return try callTool(name: name, args: args)
        default:
            throw MCPError.badParams("unknown method \(method)")
        }
    }

    // Tool implementations live in MCPServer+Tools (same module) except the
    // frame-side primitives below, which must run on the loop thread.
}

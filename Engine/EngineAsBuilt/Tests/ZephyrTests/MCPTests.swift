import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Headless MCP tests: broker wait transitions, frustum math, rasterizer,
/// PNG round-trip, tool-arg validation, and input mapping. No engine, no
/// window, no GPU — safe on every CI runner.
@MainActor
final class MCPTests: XCTestCase {

    // MARK: - Broker wait observer

    func testObserverFiresOnParkAndSettle() async throws {
        let broker = LispInputBroker()
        let seenBox = MCPTestBox<[LispInputBroker.RequestKind?]>([])
        broker.waitObserver = { kind in
            seenBox.withLock { $0.append(kind) }
        }
        let task = Task {
            try await broker.request(.point(prompt: "Pick:"))
        }
        while !broker.hasPending { await Task.yield() }
        broker.offer(.point([1, 2]))
        let event = try await task.value
        XCTAssertEqual(event, .point([1, 2]))
        let seen = seenBox.value
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0], .point(prompt: "Pick:"))
        XCTAssertNil(seen[1])
    }

    func testObserverFiresNilOnCancel() async {
        let broker = LispInputBroker()
        let seenBox = MCPTestBox<[LispInputBroker.RequestKind?]>([])
        broker.waitObserver = { kind in seenBox.withLock { $0.append(kind) } }
        let task = Task {
            try? await broker.request(.line(prompt: "Text:", allowSpaces: false))
        }
        while !broker.hasPending { await Task.yield() }
        broker.cancelPending()
        _ = await task.value
        let seen = seenBox.value
        XCTAssertEqual(seen.count, 2)
        XCTAssertNil(seen.last ?? .device)
    }

    // MARK: - Helpers

    // MARK: - Frustum math

    func testAspectExpandGrowsSmallerAxis() {
        let f = MCPFrustum(minX: 0, minY: 0, maxX: 1000, maxY: 500)
        let out = MCPThumbMath.aspectExpand(frustum: f, aspect: 800.0 / 600.0)
        XCTAssertEqual(out.width / out.height, 800.0 / 600.0, accuracy: 1e-9)
        XCTAssertEqual((out.minX + out.maxX) / 2, 500, accuracy: 1e-9)
        XCTAssertEqual((out.minY + out.maxY) / 2, 250, accuracy: 1e-9)
    }

    func testFitScaleCentersAndPreservesAspect() {
        let f = MCPFrustum(minX: 0, minY: 0, maxX: 200, maxY: 100)
        let plot = MCPThumbMath.plotRect(imageW: 800, imageH: 600)
        let (s, ox, oy) = MCPThumbMath.fitScale(frustum: f, plot: plot)
        // Fit by width: used height centers vertically in the plot rect.
        XCTAssertEqual(s, Double(plot.w) / 200.0, accuracy: 1e-9)
        let (x0, y0) = MCPThumbMath.worldToPixel(
            wx: 0, wy: 0, scale: s, ox: ox, oy: oy)
        let (x1, y1) = MCPThumbMath.worldToPixel(
            wx: 200, wy: 100, scale: s, ox: ox, oy: oy)
        XCTAssertEqual(x0, Double(plot.x), accuracy: 1e-9)
        XCTAssertEqual(x1, Double(plot.x + plot.w), accuracy: 1e-9)
        // Y-down presentation (matches the app window): rows grow with
        // world Y, so world minY sits at the content top.
        XCTAssertGreaterThan(y0, Double(plot.y))
        XCTAssertGreaterThan(y1, y0)
    }

    func testNiceStepAndTickLabels() {
        XCTAssertEqual(MCPThumbMath.niceStep(0.9), 1.0, accuracy: 1e-12)
        XCTAssertEqual(MCPThumbMath.niceStep(3.0), 2.0, accuracy: 1e-12)
        XCTAssertEqual(MCPThumbMath.niceStep(300.0), 200.0, accuracy: 1e-9)
        XCTAssertEqual(MCPThumbMath.tickLabel(12.0), "12")
        XCTAssertEqual(MCPThumbMath.tickLabel(-3.5), "-3.5")
        XCTAssertEqual(MCPThumbMath.tickLabel(0.125), "0.125")
    }

    // MARK: - Rasterizer

    func testLineAndPointDrawPixels() {
        let raster = MCPRaster(width: 32, height: 32, bg: (0, 0, 0, 255))
        raster.drawLine(x0: 2, y0: 2, x1: 10, y1: 2,
                        r: 1, g: 0, b: 0, a: 1)
        raster.drawPoint(x: 20, y: 20, r: 0, g: 1, b: 0, a: 1)
        let px = raster.bytes
        XCTAssertEqual(px[(2 * 32 + 6) * 4], 255) // red line midpoint
        XCTAssertEqual(px[(20 * 32 + 20) * 4 + 1], 255) // green point
        XCTAssertEqual(px[0], 0) // untouched background
    }

    func testTriangleFillAndChecksumStability() {
        let v0 = CADVertex(x: 0, y: 0, r: 1, g: 0, b: 0, a: 1)
        let v1 = CADVertex(x: 10, y: 0, r: 0, g: 1, b: 0, a: 1)
        let v2 = CADVertex(x: 0, y: 10, r: 0, g: 0, b: 1, a: 1)
        let result = VertexBuildResult(
            vertices: [v0, v1, v2],
            batches: [CADDrawBatch(pipelineType: .triangle,
                                   firstVertex: 0, vertexCount: 3)],
            vertexCount: 3, regionMinX: 0, regionMinY: 0,
            regionMaxX: 10, regionMaxY: 10, builtZoom: 1, mutationGen: 0)
        let (sums, count) = MCPChecksum.batches(result)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(sums.count, 1)
        XCTAssertEqual(sums[0].pipeline, "triangle")
        // Deterministic across calls.
        let again = MCPChecksum.batches(result).checksums[0].fnv
        XCTAssertEqual(sums[0].fnv, again)
        // A moved vertex changes the hash.
        let v0b = CADVertex(x: 5, y: 0, r: 1, g: 0, b: 0, a: 1)
        let result2 = VertexBuildResult(
            vertices: [v0b, v1, v2],
            batches: [CADDrawBatch(pipelineType: .triangle,
                                   firstVertex: 0, vertexCount: 3)],
            vertexCount: 3, regionMinX: 0, regionMinY: 0,
            regionMaxX: 10, regionMaxY: 10, builtZoom: 1, mutationGen: 0)
        XCTAssertNotEqual(
            MCPChecksum.batches(result2).checksums[0].fnv, sums[0].fnv)
    }

    // MARK: - PNG round-trip (encoder -> decoder)

    func testPngEncodeDecodeRoundTrip() throws {
        var rgba = [UInt8](repeating: 0, count: 4 * 3 * 4)
        for i in 0..<12 {
            rgba[i * 4] = UInt8(i * 20)
            rgba[i * 4 + 1] = UInt8(255 - i * 10)
            rgba[i * 4 + 2] = 128
            rgba[i * 4 + 3] = i % 2 == 0 ? 255 : 128
        }
        let data: Data? = rgba.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.flatMap {
                PNGEncoder.encode(rgba: $0, width: 4, height: 3)
            }
        }
        let decoded = try MCPPngDecoder.decode(data ?? Data())
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 3)
        XCTAssertEqual(decoded.rgba, rgba)
    }

    func testPngDecoderRejectsGarbage() {
        XCTAssertThrowsError(
            try MCPPngDecoder.decode(Data("hello".utf8)))
    }

    func testWrapResultProducesContentBlocks() throws {
        let wrapped = mcpWrapResult(["status": "completed", "n": 3])
            as? [String: Any]
        let content = wrapped?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 1)
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("completed"))
        // Thumbnail-style payloads already carrying content pass through.
        let passthrough: [String: Any] = ["content": [
            ["type": "text", "text": "hi"]]]
        let kept = mcpWrapResult(passthrough) as? [String: Any]
        XCTAssertEqual(
            (kept?["content"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Tool-arg validation

    func testParseBoundsAcceptsAndRejects() throws {
        let good: [String: Any] = ["min_x": 0.0, "min_y": 0.0,
                                   "max_x": 10.0, "max_y": 5.0]
        let f = try MCPToolDefs.parseBounds(good)
        XCTAssertEqual(f.width, 10)
        XCTAssertThrowsError(try MCPToolDefs.parseBounds(
            ["min_x": 10.0, "min_y": 0.0, "max_x": 5.0, "max_y": 5.0]))
        XCTAssertThrowsError(try MCPToolDefs.parseBounds(
            ["min_x": 0.0, "min_y": 0.0, "max_x": 5.0]))
        XCTAssertFalse(MCPToolDefs.hasBounds(["min_x": 1.0]))
        XCTAssertTrue(MCPToolDefs.hasBounds(
            ["min_x": 1.0, "min_y": 1.0, "max_x": 2.0, "max_y": 2.0]))
    }

    func testParseScriptLineMapping() {
        let vals = mcpParseScriptLine("10,20 5 L")
        XCTAssertEqual(vals.count, 3)
        XCTAssertEqual(vals[0], LispValue(list: [.real(10), .real(20)]))
        XCTAssertEqual(vals[1], .int(5))
        XCTAssertEqual(vals[2], .string("L"))
    }

    // MARK: - Eval session race primitives

    func testSessionTurnPrefersCompletion() {
        let session = MCPEvalSession()
        session.noteWait(.point(prompt: "Pick:"))
        session.noteDone(outcome: .value("42"), env: LispEnvironment())
        if case .completed = session.takeTurn() { /* pass */ }
        else { XCTFail("completion must win over waiting") }
    }

    func testSessionTurnReportsWaiting() {
        let session = MCPEvalSession()
        session.noteWait(.point(prompt: "Pick:"))
        if case let .waiting(kind) = session.takeTurn() {
            XCTAssertEqual(kind, .point(prompt: "Pick:"))
        } else {
            XCTFail("expected waiting")
        }
    }

    // MARK: - Input mapping

    private func makeHost() -> LispCADHost {
        let doc = CADDocument()
        doc.addLayer(Layer(name: "0"))
        return LispCADHost(document: doc,
                           selection: CADSelectionManager(),
                           processor: CADCommandProcessor())
    }

    func testOfferLineAndPointText() async {
        let host = makeHost()
        // Line kind.
        let lineTask = Task { try await host.broker.request(
            .line(prompt: "Text:", allowSpaces: false)) }
        while !host.broker.hasPending { await Task.yield() }
        XCTAssertNil(mcpOfferInput(text: "hi", point: nil, host: host))
        let lineEvent = try? await lineTask.value
        XCTAssertEqual(lineEvent, .line("hi"))
        // Point kind via text.
        let pointTask = Task { try await host.broker.request(
            .point(prompt: "Pick:")) }
        while !host.broker.hasPending { await Task.yield() }
        XCTAssertNil(mcpOfferInput(text: "10,20", point: nil, host: host))
        let pointEvent = try? await pointTask.value
        XCTAssertEqual(pointEvent, .point([10, 20]))
        // Bad point text is rejected without settling.
        let pointTask2 = Task { try await host.broker.request(
            .point(prompt: "Pick:")) }
        while !host.broker.hasPending { await Task.yield() }
        XCTAssertNotNil(mcpOfferInput(text: "abc", point: nil, host: host))
        XCTAssertTrue(host.broker.hasPending)
        host.broker.cancelPending()
        _ = try? await pointTask2.value
    }
}

// MARK: - Sendable test box

/// Lock-guarded box so @Sendable test closures can record observations.
final class MCPTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.withLock { storage } }
    func withLock(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}

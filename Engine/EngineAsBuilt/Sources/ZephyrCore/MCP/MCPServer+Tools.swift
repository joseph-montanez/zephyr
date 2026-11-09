import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - MCPServer+Tools
//
// Tool definitions (tools/list) and implementations (tools/call).
// Frame-side primitives run on the loop thread via submitFrame; pure
// compute (tessellation, raster, PNG) runs on the socket thread.
// =========================================================================

// MARK: - Tool catalog

enum MCPToolDefs {
    /// Computed (not stored): [[String: Any]] is not Sendable, and Swift 6
    /// rejects it as a static let.
    static var list: [[String: Any]] { [
        ["name": "eval_lisp",
         "description": "Evaluate AutoLISP code against the live drawing. Returns completed result or waiting_for_input when the code parks on getpoint/getstring/entsel.",
         "inputSchema": ["type": "object",
                         "properties": ["code": ["type": "string"]],
                         "required": ["code"]]],
        ["name": "load_lsp",
         "description": "Load an AutoLISP (.lsp) file from the app machine and evaluate it in the shared session.",
         "inputSchema": ["type": "object",
                         "properties": ["path": ["type": "string"]],
                         "required": ["path"]]],
        ["name": "run_command",
         "description": "Run a scripted native command, e.g. {\"name\": \"LINE\", \"args\": \"10,20 30,40\"}. Args tokenize like .scr lines.",
         "inputSchema": ["type": "object",
                         "properties": ["name": ["type": "string"],
                                        "args": ["type": "string"]],
                         "required": ["name"]]],
        ["name": "provide_input",
         "description": "Answer a waiting input request. Text for strings/Enter, [x, y] point for getpoint/entity picks.",
         "inputSchema": ["type": "object",
                         "properties": ["text": ["type": "string"],
                                        "point": ["type": "array",
                                                  "items": ["type": "number"]]]]],
        ["name": "cancel_eval",
         "description": "Cancel the running evaluation (like Esc).",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "doc_summary",
         "description": "Live drawing summary: entity/layer counts, world bounding box, active layer.",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "batch_summary",
         "description": "Exact render batches (pipeline, counts, FNV checksums) for the pinned frustum. Cheap mutation check.",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "set_camera_bounds",
         "description": "Pin the vision frustum to world bounds. Mapping always preserves aspect (fit-center).",
         "inputSchema": ["type": "object",
                         "properties": ["min_x": ["type": "number"],
                                        "min_y": ["type": "number"],
                                        "max_x": ["type": "number"],
                                        "max_y": ["type": "number"]],
                         "required": ["min_x", "min_y", "max_x", "max_y"]]],
        ["name": "zoom_extents",
         "description": "Point the pinned frustum at the drawing extents (recovery/inspection; not auto-called).",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "thumbnail",
         "description": "Deterministic CPU raster of the pinned frustum with grid ticks, optional reference overlay, and batch checksums. Y-down presentation, matching the app window.",
         "inputSchema": ["type": "object",
                         "properties": [
                             "width": ["type": "integer"],
                             "height": ["type": "integer"],
                             "show_grid": ["type": "boolean"],
                             "overlay_opacity": ["type": "number"],
                             "min_x": ["type": "number"],
                             "min_y": ["type": "number"],
                             "max_x": ["type": "number"],
                             "max_y": ["type": "number"],
                         ]]],
        ["name": "load_reference",
         "description": "Load a reference floor-plan PNG for overlay. Explicit world bounds win; default maps pixels 1:1 at the origin.",
         "inputSchema": ["type": "object",
                         "properties": ["path": ["type": "string"],
                                        "min_x": ["type": "number"],
                                        "min_y": ["type": "number"],
                                        "max_x": ["type": "number"],
                                        "max_y": ["type": "number"],
                                        "opacity": ["type": "number"]],
                         "required": ["path"]]],
    ] }

    /// Validated world bounds from tool args. Throws badParams on any
    /// non-finite or inverted bound (shared by set_camera_bounds/thumbnail).
    static func parseBounds(_ args: [String: Any]) throws -> MCPFrustum {
        func num(_ key: String) throws -> Double {
            guard let v = args[key] as? Double, v.isFinite else {
                throw MCPError.badParams("thumbnail bounds need finite \(key)")
            }
            return v
        }
        let f = MCPFrustum(minX: try num("min_x"), minY: try num("min_y"),
                           maxX: try num("max_x"), maxY: try num("max_y"))
        guard f.isValid else { throw MCPError.badParams("inverted or empty bounds") }
        return f
    }

    static func hasBounds(_ args: [String: Any]) -> Bool {
        ["min_x", "min_y", "max_x", "max_y"].allSatisfy { args[$0] is Double }
    }
}

// MARK: - Frame-side gathered state (Sendable handoff)

struct MCPGathered: Sendable {
    var inputs: [TessInput]
    var bg: (UInt8, UInt8, UInt8, UInt8)
    var useLight: Bool
    var aa: Bool
    var hairline: Bool
    var fresh: Bool
}

// MARK: - Tool dispatch

/// Wraps a tool payload in MCP content blocks. The spec renders
/// `result.content`, so a bare dict displays as blank (protocol success,
/// nothing to show). Thumbnail already returns content — pass through.
func mcpWrapResult(_ payload: Any) -> Any {
    if let dict = payload as? [String: Any], dict["content"] != nil {
        return dict
    }
    let text = (try? String(
        data: JSONSerialization.data(withJSONObject: payload, options: []),
        encoding: .utf8)) ?? "{}"
    return ["content": [["type": "text", "text": text]]] as [String: Any]
}

extension MCPServer {
    func callTool(name: String, args: [String: Any]) throws -> Any {
        try mcpWrapResult(callToolPayload(name: name, args: args))
    }

    private func callToolPayload(name: String, args: [String: Any]) throws -> Any {
        switch name {
        case "eval_lisp":
            guard let code = args["code"] as? String, !code.isEmpty else {
                throw MCPError.badParams("eval_lisp needs a code string")
            }
            return try beginEval(kind: .eval(code))
        case "load_lsp":
            guard let path = args["path"] as? String, !path.isEmpty else {
                throw MCPError.badParams("load_lsp needs a path")
            }
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw MCPError.toolFailed("cannot read \(path): \(error)")
            }
            return try beginEval(kind: .loadText(text))
        case "run_command":
            guard let cmd = args["name"] as? String, !cmd.isEmpty else {
                throw MCPError.badParams("run_command needs a name")
            }
            let argLine = args["args"] as? String ?? ""
            return try beginEval(kind: .native(cmd, argLine))
        case "provide_input":
            return try provideInput(args: args)
        case "cancel_eval":
            return try cancelEval()
        case "doc_summary":
            return try docSummary()
        case "batch_summary":
            return try batchSummary()
        case "set_camera_bounds":
            let f = try MCPToolDefs.parseBounds(args)
            lock.withLock { _frustum = f }
            return ["frustum": frustumDict(f),
                    "note": "mapping fit-centers into the plot rect; aspect preserved"] as [String: Any]
        case "zoom_extents":
            return try zoomExtents()
        case "thumbnail":
            return try thumbnail(args: args)
        case "load_reference":
            return try loadReference(args: args)
        default:
            throw MCPError.badParams("unknown tool \(name)")
        }
    }

    // MARK: Eval lifecycle

    private enum EvalKind {
        case eval(String)
        case loadText(String)
        case native(String, String)
    }

    private enum BeginResult: Sendable {
        case ready(MCPEvalSession)
        case busy
        case noEngine
    }

    /// Starts one evaluation and runs the shared completion-or-waiting race.
    private func beginEval(kind: EvalKind) throws -> Any {
        if lock.withLock({ _session }) != nil {
            throw MCPError.notRunning
        }
        let begun = try submitFrame({ [weak self] () -> BeginResult in
            guard let self, let engine = self.engine else {
                return .noEngine
            }
            let processor = engine.commandProcessor
            guard processor.lispInvocationDepth == 0 else {
                return .busy
            }
            let broker = LispInputBroker()
            broker.drainQueue()
            let host = LispCADHost(
                document: engine.document,
                selection: engine.cadSelection,
                processor: processor,
                broker: broker,
                vars: processor.lispVars)
            host.captureMainThreadState(
                selectedHandles: engine.cadSelection.selectedHandles,
                activeCommand: processor.activeCommand,
                space: engine.tabManager.spaceState)
            let session = MCPEvalSession()
            session.host = host
            host.output = { [weak session] text in session?.appendOutput(text) }
            broker.waitObserver = { [weak session] requestKind in
                session?.noteWait(requestKind)
            }
            processor.lispInvocationDepth = 1
            let envCopy = processor.lispSession
            self.lock.withLock { self._session = session }
            session.evalTask = Task.detached(priority: .userInitiated) {
                let outcome: MCPEvalOutcome
                let updated: LispEnvironment
                switch kind {
                case let .eval(source), let .loadText(source):
                    (outcome, updated) = await MCPEvalDriver.runEval(
                        source: source, host: host, env: envCopy)
                case let .native(name, argLine):
                    do {
                        let v = try await MCPEvalDriver.runNativeCommand(
                            name: name, argLine: argLine, host: host)
                        (outcome, updated) = (.value(v.prin1String), envCopy)
                    } catch let error as LispError {
                        if case .userCancel = error {
                            (outcome, updated) = (.cancelled, envCopy)
                        } else {
                            (outcome, updated) = (.error("\(error)"), envCopy)
                        }
                    } catch is CancellationError {
                        (outcome, updated) = (.cancelled, envCopy)
                    } catch {
                        (outcome, updated) = (.error("\(error)"), envCopy)
                    }
                }
                session.noteDone(outcome: outcome, env: updated)
            }
            return BeginResult.ready(session)
        } as @MainActor () -> BeginResult)
        switch begun {
        case .noEngine:
            throw MCPError.toolFailed("engine gone")
        case .busy:
            throw MCPError.busy(
                "a Lisp run already owns the session (ribbon or command line)")
        case .ready:
            break
        }
        return try settleTurn()
    }

    /// Runs takeTurn for the live session and finishes or reports waiting.
    /// Shared by eval_lisp/load_lsp/run_command (after launch) and
    /// provide_input (after every offer): a satisfied prompt usually parks
    /// on the next one, so both paths await the identical race.
    private func settleTurn() throws -> Any {
        guard let session = lock.withLock({ _session }) else {
            throw MCPError.noSession
        }
        switch session.takeTurn() {
        case .completed:
            return try finishEval(session: session)
        case let .waiting(kind):
            let prompt = session.host?.currentPrompt ?? ""
            return ["status": "waiting_for_input",
                    "wait": mcpDescribeWait(kind, prompt: prompt),
                    "output": session.takeOutput()] as [String: Any]
        }
    }

    /// Frame-side finish: session check-in, C: advertisement, undo
    /// auto-close, selection drain, depth reset. Mirrors LispCommand.complete
    /// minus the command-line UI.
    private func finishEval(session: MCPEvalSession) throws -> Any {
        let payload: [String: Any] = try submitFrame({ [weak self] in
            guard let self, let engine = self.engine else {
                return ["status": "error", "error": "engine gone"] as [String: Any]
            }
            guard let done = session.takeBox() else {
                return ["status": "error",
                        "error": "eval finished without outcome"] as [String: Any]
            }
            let processor = engine.commandProcessor
            processor.lispSession = done.env
            for name in done.env.functions.keys where name.hasPrefix("C:") {
                let bare = String(name.dropFirst(2))
                if !CommandDescriptor.allCommands.contains(where: {
                    $0.canonicalName == bare
                }) {
                    CommandDescriptor.allCommands.append(CommandDescriptor(
                        canonicalName: bare, category: .lisp,
                        description: "AutoLISP routine (c:\(bare.lowercased()))"))
                }
            }
            let depth = engine.document.undoManager.undoGroupDepth
            if depth > 0 {
                while engine.document.undoManager.undoGroupDepth > 0 {
                    engine.document.undoManager.endUndoGroup()
                }
                session.appendOutput(
                    "Warning: \(depth) unbalanced UNDO group(s) auto-closed.\n")
            }
            if let pending = session.host?.takePendingSelectionApply() {
                engine.cadSelection.selectedHandles = pending
            }
            processor.lispInvocationDepth = 0
            self.lock.withLock {
                if self._session === session { self._session = nil }
            }
            var out: [String: Any] = [
                "status": "completed", "output": session.takeOutput(),
            ]
            switch done.outcome {
            case let .value(text): out["result"] = text
            case let .error(message): out["error"] = message
            case .cancelled: out["cancelled"] = true
            }
            return out
        } as @MainActor () -> [String: Any])
        return payload
    }

    private func provideInput(args: [String: Any]) throws -> Any {
        guard let session = lock.withLock({ _session }),
              let host = session.host
        else { throw MCPError.noSession }
        // No offer while nothing pends: the wait may have settled via the
        // live UI meanwhile (typed text, mouse pick). Re-race instead of
        // queueing a stale event into the next prompt.
        guard host.broker.pendingKind != nil else {
            session.clearWait()
            return try settleTurn()
        }
        let text = args["text"] as? String ?? ""
        var point: [Double]?
        if let raw = args["point"] as? [Double], (2...3).contains(raw.count) {
            point = raw
        } else if let raw = args["point"] as? [NSNumber], (2...3).contains(raw.count) {
            point = raw.map { $0.doubleValue }
        }
        if let err = mcpOfferInput(text: text, point: point, host: host) {
            return ["status": "waiting_for_input", "error": err,
                    "output": session.takeOutput()] as [String: Any]
        }
        session.clearWait()
        return try settleTurn()
    }

    private func cancelEval() throws -> Any {
        guard let session = lock.withLock({ _session }) else {
            throw MCPError.noSession
        }
        session.evalTask?.cancel()
        session.broker.cancelPending()
        try submitFrame({ [weak self] in
            guard let self, let engine = self.engine else { return }
            engine.document.undoManager.discardOpenUndoGroups()
            session.host?.pendingCommandArgs.removeAll()
            engine.commandProcessor.lispInvocationDepth = 0
            self.lock.withLock {
                if self._session === session { self._session = nil }
            }
        } as @MainActor () -> Void)
        return ["status": "cancelled"] as [String: Any]
    }

    // MARK: Summaries

    private func docSummary() throws -> Any {
        try submitFrame({ [weak self] () -> [String: Any] in
            guard let self, let engine = self.engine else {
                return ["error": "engine gone"]
            }
            let doc = engine.document
            var bbox: Any = NSNull()
            if let bb = doc.renderableWorldBoundingBox() {
                bbox = ["min": [bb.min.x, bb.min.y, bb.min.z],
                        "max": [bb.max.x, bb.max.y, bb.max.z]]
            }
            let activeID = doc.activeLayerID
            let activeName = doc.allLayers.first(where: {
                $0.handle == activeID
            })?.name ?? ""
            return ["entities": doc.allEntities.count,
                    "layers": doc.allLayers.count,
                    "bbox": bbox,
                    "activeLayer": activeName,
                    "needsRegeneration": doc.needsRegeneration,
                    "renderRevision": Int(doc.renderRevision)] as [String: Any]
        } as @MainActor () -> [String: Any])
    }

    // MARK: Camera + thumbnails

    private func currentThumbSize() -> (Int, Int) {
        lock.withLock { (_thumbW, _thumbH) }
    }

    private func zoomExtents() throws -> Any {
        let (w, h) = currentThumbSize()
        guard let box = try submitFrame({ [weak self] () -> BoundingBox3D? in
            guard let self, let engine = self.engine else { return nil }
            return engine.document.renderableWorldBoundingBox()
        } as @MainActor () -> BoundingBox3D?) else {
            throw MCPError.toolFailed("drawing is empty (no extents)")
        }
        var f = MCPFrustum(minX: box.min.x, minY: box.min.y,
                           maxX: box.max.x, maxY: box.max.y)
        f = MCPThumbMath.aspectExpand(frustum: f, aspect: Double(w) / Double(h))
        lock.withLock { _frustum = f }
        return ["frustum": frustumDict(f)] as [String: Any]
    }

    /// Resolves the working frustum: call args win, then pinned, then live
    /// extents, then a default box. Always stores the resolution so the
    /// vision loop stays aligned.
    private func resolveFrustum(
        args: [String: Any], w: Int, h: Int
    ) throws -> MCPFrustum {
        if MCPToolDefs.hasBounds(args) {
            let f = try MCPToolDefs.parseBounds(args)
            lock.withLock { _frustum = f }
            return f
        }
        if let f = lock.withLock({ _frustum }) { return f }
        if let box = try submitFrame({ [weak self] () -> BoundingBox3D? in
            guard let self, let engine = self.engine else { return nil }
            return engine.document.renderableWorldBoundingBox()
        } as @MainActor () -> BoundingBox3D?) {
            let f = MCPThumbMath.aspectExpand(
                frustum: MCPFrustum(minX: box.min.x, minY: box.min.y,
                                    maxX: box.max.x, maxY: box.max.y),
                aspect: Double(w) / Double(h))
            lock.withLock { _frustum = f }
            return f
        }
        let f = MCPFrustum(minX: 0, minY: 0, maxX: 100, maxY: 100)
        lock.withLock { _frustum = f }
        return f
    }

    private func frustumDict(_ f: MCPFrustum) -> [String: Double] {
        ["min_x": f.minX, "min_y": f.minY, "max_x": f.maxX, "max_y": f.maxY]
    }

    private func gatherFresh(region: MCPFrustum) throws -> MCPGathered {
        var gathered = try submitFrame(gatherTask(region: region))
        var tries = 0
        while !gathered.fresh, tries < 60 {
            Thread.sleep(forTimeInterval: 0.032)
            gathered = try submitFrame(gatherTask(region: region))
            tries += 1
        }
        return gathered
    }

    private func gatherTask(region: MCPFrustum) -> @MainActor () -> MCPGathered {
        { [weak self] in
            guard let self, let engine = self.engine,
                  let renderer = engine.renderer
            else {
                return MCPGathered(inputs: [], bg: (0, 0, 0, 255),
                                   useLight: false, aa: false,
                                   hairline: false, fresh: false)
            }
            let actx = engine.tabManager.activeTab.map {
                renderer.tabCtx(for: $0.id)
            } ?? renderer.primaryCtx
            let fresh = !engine.document.needsRegeneration
                && actx.regenInFlight == nil
                && actx.vbInFlightToken == nil
            let useLight = engine.ui.isViewportBackgroundLight
            let inputs = renderer.gatherTessInputs(
                region: (minX: region.minX, minY: region.minY,
                         maxX: region.maxX, maxY: region.maxY),
                from: actx.geometry, into: actx,
                useLightDisplayPalette: useLight,
                viewportBackground: renderer.bgTuple(engine.ui.backgroundColor))
            return MCPGathered(
                inputs: inputs,
                bg: renderer.bgTuple(engine.ui.backgroundColor),
                useLight: useLight, aa: renderer.antiAliasLines,
                hairline: renderer.usesTriangleHairlines, fresh: fresh)
        }
    }

    private func batchSummary() throws -> Any {
        let (w, h) = currentThumbSize()
        var frustum = lock.withLock { _frustum }
        if frustum == nil {
            frustum = try resolveFrustum(args: [:], w: w, h: h)
        }
        let gathered = try gatherFresh(region: frustum!)
        let result = CADVertexBufferBuilder.tessellate(
            gathered.inputs, cameraZoom: 1, pixelScale: 1,
            antiAliasLines: gathered.aa, hairlineQuads: gathered.hairline,
            region: (minX: frustum!.minX, minY: frustum!.minY,
                     maxX: frustum!.maxX, maxY: frustum!.maxY),
            mutationGen: 0)
        let (checksums, count) = result.map(MCPChecksum.batches)
            ?? ([], 0)
        return ["frustum": frustumDict(frustum!),
                "fresh": gathered.fresh,
                "vertexCount": count,
                "batches": checksums.map(batchDict)] as [String: Any]
    }

    private func batchDict(_ b: MCPBatchChecksum) -> [String: Any] {
        // JSON rejects NaN/Inf: sanitize once at the boundary.
        let weight = b.lineWeight.isFinite ? b.lineWeight : 0
        return ["pipeline": b.pipeline, "firstVertex": Int(b.firstVertex),
                "vertexCount": Int(b.vertexCount), "lineWeight": weight,
                "fnv": String(format: "%016llx", b.fnv)]
    }

    private func thumbnail(args: [String: Any]) throws -> Any {
        var (w, h) = currentThumbSize()
        if let nw = args["width"] as? Int, (64...2048).contains(nw) { w = nw }
        if let nh = args["height"] as? Int, (64...2048).contains(nh) { h = nh }
        if let nw = args["width"] as? Double, (64...2048).contains(Int(nw)) {
            w = Int(nw)
        }
        if let nh = args["height"] as? Double, (64...2048).contains(Int(nh)) {
            h = Int(nh)
        }
        lock.withLock { _thumbW = w; _thumbH = h }
        let showGrid = (args["show_grid"] as? Bool)
            ?? lock.withLock({ _showGrid })
        let overlayOpacity = (args["overlay_opacity"] as? Double)
            ?? lock.withLock({ _overlayOpacity })
        let reference = lock.withLock { _reference }

        let frustum = try resolveFrustum(args: args, w: w, h: h)
        let plot = MCPThumbMath.plotRect(imageW: w, imageH: h)
        let (scale, ox, oy) = MCPThumbMath.fitScale(frustum: frustum, plot: plot)

        let gathered = try gatherFresh(region: frustum)
        guard let result = CADVertexBufferBuilder.tessellate(
            gathered.inputs, cameraZoom: scale, pixelScale: 1,
            antiAliasLines: gathered.aa, hairlineQuads: gathered.hairline,
            region: (minX: frustum.minX, minY: frustum.minY,
                     maxX: frustum.maxX, maxY: frustum.maxY),
            mutationGen: 0)
        else {
            throw MCPError.toolFailed("tessellation cancelled")
        }

        let raster = MCPRaster(width: w, height: h, bg: gathered.bg)
        if let ref = reference, overlayOpacity > 0 {
            raster.compositeOverlay(
                image: ref.image, worldMinX: ref.minX, worldMinY: ref.minY,
                worldMaxX: ref.maxX, worldMaxY: ref.maxY,
                scale: scale, ox: ox, oy: oy, opacity: overlayOpacity)
        }
        drawBatches(result: result, raster: raster,
                    scale: scale, ox: ox, oy: oy)
        if showGrid {
            let light = gathered.useLight
            raster.drawGrid(
                frustum: frustum, plot: plot, scale: scale, ox: ox, oy: oy,
                label: light ? (40, 40, 40, 255) : (200, 200, 200, 255),
                minor: light ? (0, 0, 0, 22) : (255, 255, 255, 22),
                major: light ? (0, 0, 0, 48) : (255, 255, 255, 48))
        }

        let bytes = raster.bytes
        let png: Data? = bytes.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.flatMap {
                PNGEncoder.encode(rgba: $0, width: w, height: h)
            }
        }
        guard let png else { throw MCPError.toolFailed("PNG encode failed") }
        let (checksums, count) = MCPChecksum.batches(result)
        let summary: [String: Any] = [
            "frustum": frustumDict(frustum),
            "plot": ["x": plot.x, "y": plot.y, "w": plot.w, "h": plot.h],
            "pixelsPerUnit": scale,
            "fresh": gathered.fresh,
            "vertexCount": count,
            "batches": checksums.map(batchDict),
            "referenceOverlay": reference != nil && overlayOpacity > 0,
        ]
        let summaryText = (try? String(
            data: JSONSerialization.data(withJSONObject: summary, options: []),
            encoding: .utf8)) ?? "{}"
        return ["content": [
            ["type": "text", "text": summaryText],
            ["type": "image", "data": png.base64EncodedString(),
             "mimeType": "image/png"],
        ]] as [String: Any]
    }

    private func drawBatches(
        result: VertexBuildResult, raster: MCPRaster,
        scale: Double, ox: Double, oy: Double
    ) {
        func pt(_ v: CADVertex) -> (Double, Double)? {
            guard Double(v.x).isFinite, Double(v.y).isFinite else { return nil }
            return MCPThumbMath.worldToPixel(
                wx: Double(v.x), wy: Double(v.y),
                scale: scale, ox: ox, oy: oy)
        }
        for batch in result.batches where !batch.isPanProxy {
            let start = Int(batch.firstVertex)
            let end = min(start + Int(batch.vertexCount), result.vertices.count)
            guard start < end else { continue }
            switch batch.pipelineType {
            case .line:
                var i = start
                while i + 1 < end {
                    if let a = pt(result.vertices[i]),
                       let b = pt(result.vertices[i + 1])
                    {
                        let c = result.vertices[i]
                        raster.drawLine(x0: a.0, y0: a.1, x1: b.0, y1: b.1,
                                        r: c.r, g: c.g, b: c.b, a: c.a)
                    }
                    i += 2
                }
            case .point:
                for i in start..<end {
                    if let p = pt(result.vertices[i]) {
                        let c = result.vertices[i]
                        raster.drawPoint(x: p.0, y: p.1,
                                         r: c.r, g: c.g, b: c.b, a: c.a)
                    }
                }
            case .triangle, .aaLine:
                var i = start
                while i + 2 < end {
                    let v0 = result.vertices[i]
                    let v1 = result.vertices[i + 1]
                    let v2 = result.vertices[i + 2]
                    if let a = pt(v0), let b = pt(v1), let c = pt(v2) {
                        raster.fillTriangle((a.0, a.1, v0), (b.0, b.1, v1),
                                            (c.0, c.1, v2))
                    }
                    i += 3
                }
            }
        }
    }

    // MARK: Reference images

    private func loadReference(args: [String: Any]) throws -> Any {
        guard let path = args["path"] as? String, !path.isEmpty else {
            throw MCPError.badParams("load_reference needs a path")
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw MCPError.toolFailed("cannot read \(path): \(error)")
        }
        let image: MCPPngImage
        do {
            image = try MCPPngDecoder.decode(data)
        } catch let err as MCPPngError {
            throw MCPError.toolFailed("reference PNG rejected: \(mcpPngMessage(err))")
        }
        var minX = 0.0, minY = 0.0
        var maxX = Double(image.width), maxY = Double(image.height)
        if let v = args["min_x"] as? Double, v.isFinite { minX = v }
        if let v = args["min_y"] as? Double, v.isFinite { minY = v }
        if let v = args["max_x"] as? Double, v.isFinite { maxX = v }
        if let v = args["max_y"] as? Double, v.isFinite { maxY = v }
        guard maxX > minX, maxY > minY else {
            throw MCPError.badParams("reference world bounds inverted")
        }
        if let op = args["opacity"] as? Double, op >= 0, op <= 1 {
            lock.withLock { _overlayOpacity = op }
        }
        let ref = MCPReference(image: image, minX: minX, minY: minY,
                               maxX: maxX, maxY: maxY)
        lock.withLock { _reference = ref }
        // Turn-1 init: point the pinned frustum at the reference bounds
        // (aspect-expanded to the thumbnail) when no camera is set yet.
        let (w, h) = currentThumbSize()
        var frustumNote = "kept"
        if lock.withLock({ _frustum }) == nil {
            let f = MCPThumbMath.aspectExpand(
                frustum: MCPFrustum(minX: minX, minY: minY,
                                    maxX: maxX, maxY: maxY),
                aspect: Double(w) / Double(h))
            lock.withLock { _frustum = f }
            frustumNote = "auto-set"
        }
        return ["width": image.width, "height": image.height,
                "worldRect": ["min_x": minX, "min_y": minY,
                              "max_x": maxX, "max_y": maxY],
                "frustum": frustumNote] as [String: Any]
    }

    private func mcpPngMessage(_ err: MCPPngError) -> String {
        switch err {
        case .truncated: return "truncated file"
        case .badSignature: return "not a PNG"
        case let .unsupported(m): return "unsupported \(m) (need 8-bit RGB/RGBA, non-interlaced)"
        case .inflateFailed: return "deflate error"
        case let .tooLarge(n): return "\(n) pixels exceeds the cap"
        }
    }
}

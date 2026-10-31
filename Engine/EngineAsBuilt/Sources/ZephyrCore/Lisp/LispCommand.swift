import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrLisp

// =========================================================================
// MARK: - Lisp Command Driver (LOAD / EVAL / SCRIPT)
// =========================================================================
//
// `LispCommand` is the interactive driver for AutoLISP: a FeatureCommand
// that runs one evaluation task and feeds it UI events through the
// `LispInputBroker`. Nothing here blocks a thread for input — the eval task
// suspends on broker requests and resumes from the existing event handlers.
//
// Threading: the eval task NEVER hops to MainActor — the hand-rolled SDL
// loop never pumps the main dispatch queue, so such a hop stalls forever.
// Completion arrives via a locked box polled each frame; selection writes
// drain the same way; input flows through the lock-based broker. The host
// touches only hop-free state (document, snapshots, locks).
//
// Lifecycle:
// * start: refuses nested runs (depth guard), claims invocation depth 1,
//   builds the CAD host, freezes main-thread snapshots, and either launches
//   immediately (source preset or argument already delivered), arms the
//   native file picker for the event phase (LOAD/SCRIPT with no preset),
//   or prompts for the expression (EVAL).
// * Evaluation runs in a detached task (off MainActor). Completion, Esc
//   cancel, and errors all funnel through cancel(), which is idempotent:
//   cancel task, cancel pending broker request, discard open undo groups,
//   release invocation depth.
// * Normal completion additionally auto-closes unbalanced UNDO groups with
//   a warning before releasing (fail-open toward the coalescing asked for).
//
// Input routing (handleCommandText / mouse / keys) offers EXACTLY ONE event
// per gesture, chosen by the broker's pending kind: offering several would
// queue the losers as stale input once the first settles the slot.
// Clicks and keys also queue for future grread when nothing pends; motion
// never queues (flood protection) and only settles live grread waits.

@MainActor
public final class LispCommand: FeatureCommand {
    /// Which entry point spawned this driver.
    public enum Mode: Sendable {
        /// LOAD: read a .lsp file and evaluate its forms.
        case load
        /// EVAL: evaluate the argument as one expression string.
        case eval
        /// SCRIPT: run a .scr command script through the scripted commands.
        case script
        /// CALL: evaluate the argument (a `(C:NAME)` form) against the
        /// persistent session, for processor `c:` dispatch.
        case call
    }

    private let mode: Mode
    private var presetSource: String?
    private var launched = false
    private var tornDown = false
    /// Bare LOAD/SCRIPT with no preset: the native picker opens from the
    /// loop's event phase on the first frame (see renderOverlay).
    private var pickerPending = false
    private var evalTask: Task<Void, Never>?
    /// Completion handoff: the eval task stores here (no MainActor hop —
    /// the unpumped SDL loop would stall it); renderOverlay takes and
    /// completes on the main thread.
    private var completionBox: CompletionBox?
    private var host: LispCADHost?
    private weak var engineRef: PhrostEngine?
    private weak var processorRef: CADCommandProcessor?
    private var lastMouseWorld: (x: Double, y: Double)?
    private var lastPromptShown: String?

    /// - Parameter source: preset path/expression (tests, and programmatic
    ///   launch). When nil, start() prompts and handleCommandText launches.
    public init(mode: Mode, source: String? = nil) {
        self.mode = mode
        self.presetSource = source
    }

    /// Whether the background evaluator is actively computing and not waiting for input.
    public var isActivelyEvaluating: Bool {
        guard launched, !tornDown, let host else { return false }
        return !host.broker.hasPending
    }

    // MARK: - FeatureCommand

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        engineRef = engine
        processorRef = processor
        if processor.lispInvocationDepth > 0 {
            print("[Lisp] Nested Lisp routines are not allowed.")
            processor.finishFeatureCommand(engine: engine)
            return
        }
        processor.lispInvocationDepth = 1
        let broker = LispInputBroker()
        broker.drainQueue()
        let newHost = Self.makeHost(
            document: engine.document,
            selection: engine.cadSelection,
            processor: processor,
            broker: broker)
        newHost.captureMainThreadState(
            selectedHandles: engine.cadSelection.selectedHandles,
            activeCommand: processor.activeCommand,
            space: engine.tabManager.spaceState)
        host = newHost
        if let preset = presetSource {
            presetSource = nil
            print("[Lisp] start \(mode) (preset \(preset.count) chars)")
            launch(argument: preset)
        } else if Self.openFilter(for: mode) != nil {
            // Armed here, opened from the loop's event phase on the first
            // frame (SDL_ShowOpenFileDialog fails silently mid-render). The
            // deferral also lets a typed "LOAD <path>" argument launch
            // first, so no stray picker flashes over a path launch.
            pickerPending = true
            processor.commandPrompt = "Select a file…"
        } else if mode == .call {
            processor.commandPrompt = "Enter function call to run:"
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandSelectionIndex = 0
        } else {
            processor.commandPrompt = "Enter expression to EVAL:"
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandSelectionIndex = 0
        }
    }

    /// Builds the evaluation host for one run. Always shares the processor's
    /// app-wide sysvar store so `(setvar …)` survives across LOAD/EVAL runs
    /// (AutoCAD parity) and is readable by the ribbon's live-state predicates.
    static func makeHost(
        document: CADDocument,
        selection: CADSelectionManager,
        processor: CADCommandProcessor,
        broker: LispInputBroker
    ) -> LispCADHost {
        LispCADHost(
            document: document,
            selection: selection,
            processor: processor,
            broker: broker,
            vars: processor.lispVars)
    }

    /// Native file-picker filter for the file-taking modes (nil = EVAL
    /// and CALL, which take an expression string instead of a path).
    static func openFilter(for mode: Mode) -> NativeFileDialog.Filter? {
        switch mode {
        case .load:
            NativeFileDialog.Filter(
                label: "AutoLISP files (*.lsp, *.mnl)",
                extensions: ["lsp", "mnl"])
        case .script:
            NativeFileDialog.Filter(
                label: "Script files (*.scr)", extensions: ["scr"])
        case .eval, .call:
            nil
        }
    }

    /// Open the native file picker: launch on pick, end quietly on cancel.
    /// Runs in the loop's event phase (never mid-render). The completion
    /// re-checks tornDown/launched — Esc (or typed text) may have settled
    /// the command while the dialog was open.
    private func showFilePicker(
        engine: PhrostEngine,
        processor: CADCommandProcessor,
        filter: NativeFileDialog.Filter
    ) {
        NativeFileDialog.showOpenDialog(window: engine.dialogParentWindow, filters: [filter]) {
            [weak self, weak processor] urls in
            guard let self, let processor,
                  !self.tornDown, !self.launched
            else {
                print("[Lisp] picker result ignored (settled while open)")
                return
            }
            guard let url = urls.first else {
                print("[Lisp] picker cancelled")
                if let engine = self.engineRef {
                    processor.finishFeatureCommand(engine: engine)
                }
                return
            }
            print("[Lisp] picked \(url.path)")
            self.launch(argument: url.path)
        }
    }

    public func cancel(engine _: PhrostEngine, processor: CADCommandProcessor) {
        guard !tornDown else { return }
        tornDown = true
        pickerPending = false
        _ = completionBox?.take()
        completionBox = nil
        evalTask?.cancel()
        evalTask = nil
        host?.broker.cancelPending()
        host?.pendingCommandArgs.removeAll()
        if let doc = engineRef?.document {
            doc.undoManager.discardOpenUndoGroups()
        }
        if processor.commandLineActive {
            processor.commandLineActive = false
            processor.commandBuffer = ""
        }
        processor.lispInvocationDepth = 0
        host = nil
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor _: CADCommandProcessor
    ) -> CommandResult {
        guard launched, let host else { return .continue }
        lastMouseWorld = (worldX, worldY)
        switch host.broker.pendingKind {
        case .point:
            host.broker.offer(.point([worldX, worldY]))
        case .entity:
            if let (handle, _) = pickEntity(atX: worldX, y: worldY, engine: engine) {
                host.broker.offer(.entity(handle: handle, point: [worldX, worldY]))
            } else {
                // Miss (point, no handle): the host re-prompts.
                host.broker.offer(.entity(handle: nil, point: [worldX, worldY]))
            }
        case .device:
            host.broker.offer(grreadClick(worldX: worldX, worldY: worldY))
        case .line, nil:
            // Clicks queue for future grread when nothing (or text) pends.
            if host.broker.pendingKind == nil {
                host.broker.offer(grreadClick(worldX: worldX, worldY: worldY))
            }
        }
        return .handled
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine _: PhrostEngine, processor _: CADCommandProcessor
    ) {
        lastMouseWorld = (worldX, worldY)
        // Motion only settles live grread waits; it never queues.
        if host?.broker.pendingKind == .device {
            host?.broker.offer(.device(LispValue(list: [
                .int(5), .real(worldX), .real(worldY),
            ])))
        }
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            if let host {
                switch host.broker.pendingKind {
                case .line, .point, .entity:
                    _ = handleCommandText("", engine: engine, processor: processor)
                    return .handled
                default:
                    break
                }
            }
        }
        if host?.broker.pendingKind == .device {
            host?.broker.offer(.device(LispValue(list: [.int(2), .int(Int(scancode.rawValue))])))
            return .continue
        }
        if !processor.commandLineActive, let host, let kind = host.broker.pendingKind {
            switch kind {
            case .point, .line:
                if let char = scancodeToChar(scancode) {
                    processor.commandLineActive = true
                    processor.commandBuffer = String(char)
                    processor.commandSelectionIndex = 0
                    return .handled
                }
            default:
                break
            }
        }
        return .continue
    }

    private func scancodeToChar(_ sc: SDL_Scancode) -> Character? {
        if sc.rawValue >= SDL_SCANCODE_A.rawValue && sc.rawValue <= SDL_SCANCODE_Z.rawValue {
            let ascii = UInt8(0x61 + (sc.rawValue - SDL_SCANCODE_A.rawValue))
            return Character(UnicodeScalar(ascii))
        }
        if sc.rawValue >= SDL_SCANCODE_1.rawValue && sc.rawValue <= SDL_SCANCODE_9.rawValue {
            let ascii = UInt8(0x31 + (sc.rawValue - SDL_SCANCODE_1.rawValue))
            return Character(UnicodeScalar(ascii))
        }
        if sc == SDL_SCANCODE_0 || sc == SDL_SCANCODE_KP_0 { return "0" }
        if sc == SDL_SCANCODE_KP_1 { return "1" }
        if sc == SDL_SCANCODE_KP_2 { return "2" }
        if sc == SDL_SCANCODE_KP_3 { return "3" }
        if sc == SDL_SCANCODE_KP_4 { return "4" }
        if sc == SDL_SCANCODE_KP_5 { return "5" }
        if sc == SDL_SCANCODE_KP_6 { return "6" }
        if sc == SDL_SCANCODE_KP_7 { return "7" }
        if sc == SDL_SCANCODE_KP_8 { return "8" }
        if sc == SDL_SCANCODE_KP_9 { return "9" }
        if sc == SDL_SCANCODE_PERIOD || sc == SDL_SCANCODE_KP_PERIOD { return "." }
        if sc == SDL_SCANCODE_COMMA { return "," }
        if sc == SDL_SCANCODE_MINUS || sc == SDL_SCANCODE_KP_MINUS { return "-" }
        return nil
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        if pickerPending, !launched, !tornDown {
            pickerPending = false
            // SDL_ShowOpenFileDialog fails silently mid-render: hand the open
            // to the loop's event phase via pendingDialogRequest (same as
            // PDFImport). Re-checked there — Esc or typed text may settle
            // the command before the deferred open runs.
            engine.pendingDialogRequest = { [weak self, weak engine] in
                guard let self, let engine,
                      !self.tornDown, !self.launched,
                      let filter = Self.openFilter(for: self.mode),
                      let processor = self.processorRef
                else { return }
                self.showFilePicker(
                    engine: engine, processor: processor, filter: filter)
            }
        }
        // Main-thread drains, every frame while running: selection writes
        // first (an eval may set pickfirst and finish in the same instant),
        // then completion.
        if launched, !tornDown, let host {
            if let pending = host.takePendingSelectionApply() {
                engine.cadSelection.selectedHandles = pending
            }
            if let box = completionBox, let done = box.take() {
                completionBox = nil
                if let processor = processorRef {
                    complete(
                        outcome: done.outcome, environment: done.environment,
                        engine: engine, processor: processor)
                    return
                }
            }
        }
        guard launched, let host, let processor = processorRef else { return }
        // Mirror the host's live prompt into the command line.
        if host.currentPrompt != lastPromptShown {
            lastPromptShown = host.currentPrompt
            processor.commandPrompt = host.currentPrompt.isEmpty
                ? "Lisp running… (Esc cancels)"
                : host.currentPrompt
        }
        if case .line = host.broker.pendingKind {
            if !processor.commandLineActive {
                processor.commandLineActive = true
                processor.commandBuffer = ""
                processor.commandSelectionIndex = 0
            }
        }
        // Rubber band from the base point to the cursor during point waits.
        if case .point = host.broker.pendingKind,
           let base = host.pendingBase, base.count >= 2,
           let mouse = lastMouseWorld
        {
            let drawList = igGetForegroundDrawList_ViewportPtr(nil)
            let a = EngineCameraManager.worldToScreen(worldX: base[0], worldY: base[1], cam: cam)
            let b = EngineCameraManager.worldToScreen(worldX: mouse.x, worldY: mouse.y, cam: cam)
            let col = makeCol32(0, 200, 255, 200)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), col, 1.5)
        }
        _ = engine
    }

    public func handleCommandText(
        _ text: String, engine _: PhrostEngine, processor _: CADCommandProcessor
    ) -> CommandResult {
        guard let host else { return .continue }
        if !launched {
            launch(argument: text)
            return .continue
        }
        // Route typed text by the outstanding request kind.
        switch host.broker.pendingKind {
        case .line:
            host.broker.offer(.line(text.isEmpty ? nil : text))
        case .point:
            if text.isEmpty {
                host.broker.offer(.point(nil))
            } else if let coords = LispCommand.parsePointText(
                text, base: host.pendingBase)
            {
                host.broker.offer(.point(coords))
            } else {
                host.output("Invalid point. Type X,Y or pick with the mouse.\n")
            }
        case .entity:
            if text.isEmpty {
                host.broker.offer(.entity(handle: nil, point: nil))
            } else {
                host.output("Select an entity with the mouse (or Enter for none).\n")
            }
        case .device:
            // Feed grread the first typed character (rest is dropped).
            if let scalar = text.unicodeScalars.first {
                host.broker.offer(.device(LispValue(list: [
                    .int(2), .int(Int(scalar.value)),
                ])))
            }
        case nil:
            break // Script is computing; stray text is ignored.
        }
        return .continue
    }

    // MARK: - Launch + completion

    private func launch(argument: String) {
        guard !launched, let host,
              engineRef != nil, let processor = processorRef
        else { return }
        launched = true
        pickerPending = false
        processor.commandPrompt = "Lisp running… (Esc cancels)"
        print("[Lisp] launch \(mode)")
        let mode = mode
        let hostRef = host
        let session = processor.lispSession
        let box = CompletionBox()
        completionBox = box
        // No MainActor hop on the way out: the unpumped SDL loop would
        // stall it. The task stores into the box; the frame poll completes.
        evalTask = Task.detached(priority: .userInitiated) {
            let (outcome, updated) = await LispCommand.runDetached(
                mode: mode, argument: argument, host: hostRef,
                environment: session)
            box.store(outcome: outcome, environment: updated)
        }
    }

    private enum Outcome {
        case value(LispValue)
        case error(String)
        case cancelled
    }

    /// Single-shot completion handoff from the eval task to the frame poll.
    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (outcome: Outcome, environment: LispEnvironment)?

        func store(outcome: Outcome, environment: LispEnvironment) {
            lock.withLock { value = (outcome, environment) }
        }

        func take() -> (outcome: Outcome, environment: LispEnvironment)? {
            lock.withLock {
                defer { value = nil }
                return value
            }
        }
    }
    /// Off-actor evaluation body. Only Sendable captures (mode, argument,
    /// host, environment); nothing inside hops to MainActor. The environment
    /// is checked back out so defuns and globals persist in the processor
    /// session across runs.
    private static func runDetached(
        mode: Mode, argument: String, host: LispCADHost,
        environment: LispEnvironment
    ) async -> (Outcome, LispEnvironment) {
        var env = environment
        do {
            switch mode {
            case .load:
                let source = try readTextFile(argument: argument, what: "LOAD")
                print("[Lisp] read \(source.count) chars from \(argument)")
                let forms = try LispReader().readAll(source)
                print("[Lisp] parsed \(forms.count) form(s)")
                let result = try await LispEvaluator().run(forms, env: &env, host: host)
                print("[Lisp] eval done: \(result.prin1String)")
                return (.value(result), env)
            case .eval, .call:
                let forms = try LispReader().readAll(argument)
                let result = try await LispEvaluator().run(forms, env: &env, host: host)
                print("[Lisp] eval done: \(result.prin1String)")
                return (.value(result), env)
            case .script:
                try await runScriptFile(argument: argument, host: host)
                return (.value(.nilValue), env)
            }
        } catch let error as LispError {
            if case .userCancel = error { return (.cancelled, env) }
            return (.error("\(error)"), env)
        } catch is CancellationError {
            return (.cancelled, env)
        } catch {
            return (.error("\(error)"), env)
        }
    }

    private func complete(
        outcome: Outcome, environment: LispEnvironment,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Check the session back in first: forms evaluated before a cancel
        // keep their defuns and globals, like AutoCAD.
        print("[Lisp] complete \(outcome)")
        processor.lispSession = environment
        // Advertise newly loaded routines in command autocomplete.
        for name in environment.functions.keys where name.hasPrefix("C:") {
            let bare = String(name.dropFirst(2))
            if !CommandDescriptor.allCommands.contains(where: {
                $0.canonicalName == bare
            }) {
                CommandDescriptor.allCommands.append(CommandDescriptor(
                    canonicalName: bare,
                    category: .lisp,
                    description: "AutoLISP routine (c:\(bare.lowercased()))"))
            }
        }
        guard !tornDown, let host else { return }
        tornDown = true
        _ = completionBox?.take()
        completionBox = nil
        switch outcome {
        case let .value(result):
            if !result.isNil {
                host.output("\(result.prin1String)\n")
            }
        case let .error(message):
            // *error* already ran inside the evaluator when defined.
            host.output("Error: \(message)\n")
        case .cancelled:
            host.output("*Cancel*\n")
        }
        // Unbalanced Begin at script end auto-closes with a warning
        // (documented default; AutoCAD's behavior here is undocumented).
        let depth = engine.document.undoManager.undoGroupDepth
        if depth > 0 {
            while engine.document.undoManager.undoGroupDepth > 0 {
                engine.document.undoManager.endUndoGroup()
            }
            host.output(
                "Warning: \(depth) unbalanced UNDO group(s) auto-closed.\n")
        }
        if processor.commandLineActive {
            processor.commandLineActive = false
            processor.commandBuffer = ""
        }
        evalTask = nil
        processor.lispInvocationDepth = 0
        self.host = nil
        processor.finishFeatureCommand(engine: engine)
    }

    // MARK: - File + script helpers

    private static func readTextFile(argument: String, what: String) throws -> String {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !trimmed.isEmpty else {
            throw LispError.hostError("\(what): missing file path")
        }
        let url = URL(fileURLWithPath: trimmed)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LispError.hostError("\(what): cannot read \"\(trimmed)\"")
        }
    }

    /// Runs a .scr command script: lines naming a scripted command start a
    /// new call; following lines accumulate as that call's arguments until
    /// the next command line. Blank lines append "" (Enter). Tokens parse
    /// as points (X,Y[,Z]), numbers, or strings.
    ///
    /// Limitation: a bare word argument that exactly matches a scripted
    /// command name starts a new call instead. Only the 12 audited names
    /// can collide; quoted strings never do (only bare words are tested).
    static func runScriptFile(argument: String, host: LispCADHost) async throws {
        let text = try readTextFile(argument: argument, what: "SCRIPT")
        var pendingName: String?
        var pendingArgs: [LispValue] = []
        var lineNumber = 0
        func flush() async throws {
            guard let name = pendingName else { return }
            pendingName = nil
            let args = pendingArgs
            pendingArgs = []
            do {
                _ = try await host.runCommand([.string(name)] + args)
            } catch let error as LispError {
                throw LispError.hostError("SCRIPT line \(lineNumber): \(error)")
            }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                pendingArgs.append(.string(""))
                continue
            }
            if line.hasPrefix(";") { continue } // Comment.
            if isScriptCommandLine(line) {
                try await flush()
                pendingName = line
                pendingArgs = []
                continue
            }
            if pendingName == nil {
                throw LispError.hostError(
                    "SCRIPT line \(lineNumber): expected a command, got \"\(line)\"")
            }
            pendingArgs += parseScriptLine(line)
        }
        try await flush()
    }

    private static func isScriptCommandLine(_ line: String) -> Bool {
        // Bare single words only (no spaces, no commas, no quotes).
        guard !line.contains(where: { $0 == " " || $0 == "," || $0 == "\"" }) else {
            return false
        }
        return LispScriptedCommands.disposition(for: line) == .scripted
    }

    /// Tokenizes one script line: whitespace-separated tokens; X,Y[,Z]
    /// becomes a point, numeric tokens become numbers, the rest strings.
    static func parseScriptLine(_ line: String) -> [LispValue] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { token in
            let word = String(token)
            if word.contains(","),
               let coords = parsePointText(word, base: nil),
               coords.count >= 2
            {
                return LispValue(list: coords.map(LispValue.real))
            }
            if let int = Int(word) { return .int(int) }
            if let double = Double(word) { return .real(double) }
            return .string(word)
        }
    }

    // MARK: - Picking + parsing

    /// Bounding-box entity pick (v1 aperture picking): smallest-area live
    /// bounding box containing the click, or nil on a miss.
    private func pickEntity(
        atX x: Double, y: Double, engine: PhrostEngine
    ) -> (handle: String, point: [Double])? {
        var best: (handle: String, area: Double)?
        for entity in engine.document.allEntities {
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

    private func grreadClick(worldX: Double, worldY: Double) -> LispInputBroker.Event {
        .device(LispValue(list: [.int(3), .real(worldX), .real(worldY)]))
    }

    /// Parses typed point text: "X,Y[,Z]", "X Y Z", "@X,Y" (relative to
    /// base), or a bare number (single-element answer for the
    /// getdist/getangle escape; getpoint re-prompts on those).
    static func parsePointText(_ text: String, base: [Double]?) -> [Double]? {
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
        // Reject partial parses ("10,abc" must not become [10]).
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
}

// MARK: - Descriptors + registration

/// Autocomplete descriptors for the Lisp entry points.
public enum LispDescriptors {
    public static let load = CommandDescriptor(
        canonicalName: "LOAD",
        aliases: [],
        category: .lisp,
        syntax: "<file>",
        description: "Load and evaluate an AutoLISP (.lsp) file (opens a file picker)",
        bareEnterExecutes: true)
    public static let eval = CommandDescriptor(
        canonicalName: "EVAL",
        aliases: [],
        category: .lisp,
        syntax: "<expression>",
        description: "Evaluate an AutoLISP expression string")
    public static let script = CommandDescriptor(
        canonicalName: "SCRIPT",
        aliases: ["SCR"],
        category: .lisp,
        syntax: "<file>",
        description: "Run a command script (.scr) file (opens a file picker)",
        bareEnterExecutes: true)
}

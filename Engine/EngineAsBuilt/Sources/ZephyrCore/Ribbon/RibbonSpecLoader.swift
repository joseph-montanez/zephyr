import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Ribbon spec loader
// =========================================================================
//
// Loads the AutoLISP ribbon definition without blocking the render loop.
//
// Threading model (identical to `LispCommand`, and for the same reason — the
// hand-rolled SDL loop never pumps the main dispatch queue, so a MainActor
// hop from evaluation stalls forever):
//   * the file is read on the main thread;
//   * evaluation runs on a DETACHED task holding only Sendable values;
//   * the outcome is handed back through a lock box that `poll()` drains
//     once per frame.
//
// Single-flight: a load claims `processor.lispInvocationDepth` for its
// duration, so it can never interleave with LOAD/EVAL/`c:` runs (both touch
// the document). Requests that arrive while anything else is running are
// queued, not dropped.
//
// The definition is evaluated against a COPY of the persistent LISP session,
// so it may call helpers the user already loaded, but its own `defun`s are
// discarded — the prelude is re-prepended on every load, and a definition
// file has no business mutating the user's session.
//
// Failure policy: the last good model stays live and the error is reported.

@MainActor
public final class RibbonSpecLoader {

    // MARK: - Status

    public enum Status: Sendable, Equatable {
        /// Nothing attempted yet (fallback model is live).
        case idle
        case loading
        case loaded
        case failed
    }

    // MARK: - State

    /// The live model. Never empty: starts as the built-in fallback.
    public private(set) var spec: RibbonSpec = RibbonFallbackSpec.make()
    public private(set) var status: Status = .idle
    /// Non-fatal problems from the last successful parse (dropped commands,
    /// unknown icons, empty panels).
    public private(set) var warnings: [String] = []
    /// Message from the last failure, kept until the next successful load.
    public private(set) var errorMessage: String?
    /// Definition file actually used by the last attempt.
    public private(set) var sourcePath: String?

    /// Command-line sink (set by the app to route into the command history).
    public var output: (String) -> Void = { text in
        print(text, terminator: "")
    }

    /// Re-evaluate the file when its modification date changes (checked at
    /// most once a second). Disable to make reloads strictly manual.
    public var autoReloadEnabled = true

    /// Give up on a definition that blocks for input: a file that prompts can
    /// never finish on its own, and it holds the single-flight slot.
    public var loadTimeout: TimeInterval = 5

    /// Where the definition is read from. Overridable so tests (and future
    /// per-project definitions) can point somewhere else.
    public var definitionURLProvider: () -> URL? = {
        RibbonSpecLoader.resolvedDefinitionURL()
    }

    // MARK: - Dependencies

    private let processor: CADCommandProcessor?
    /// Documents change on tab switch, so they are resolved per load rather
    /// than cached.
    private let documentProvider: () -> CADDocument
    private let selectionProvider: () -> CADSelectionManager

    // MARK: - In-flight state

    private var task: Task<Void, Never>?
    private var completion: RibbonLoadCompletionBox?
    private var activeHost: LispCADHost?
    private var activeBuffer: RibbonLoadOutputBuffer?
    private var loadStartedAt: Date?
    private var pendingReloadReason: String?
    private var lastKnownMTime: Date?
    private var lastMTimeCheck: Date = .distantPast

    // MARK: - Init

    public init(
        processor: CADCommandProcessor?,
        documentProvider: @escaping () -> CADDocument,
        selectionProvider: @escaping () -> CADSelectionManager
    ) {
        self.processor = processor
        self.documentProvider = documentProvider
        self.selectionProvider = selectionProvider
    }

    public var isLoading: Bool { task != nil }

    /// Check-only peek for the lazy loop's wake predicate. True when a
    /// finished load (or a queued reload) is waiting for `poll()` to run
    /// on a later frame. Callers must not treat this as a reason to spin:
    /// a hanging load (timeout path) still needs some other wake to drain.
    public var hasPendingWork: Bool {
        completion?.hasPendingResult() == true || pendingReloadReason != nil
    }

    // MARK: - Definition file resolution

    /// `<appSupport>/Zephyr/lisp/ribbon.lsp` — the user-editable definition.
    public static func userFileURL() -> URL? {
        UserSettings.appSupportDirectory()?
            .appendingPathComponent("lisp", isDirectory: true)
            .appendingPathComponent("ribbon.lsp")
    }

    /// `<exe>/lisp/ribbon.lsp` — the definition shipped next to `Fonts/`.
    public static func bundledFileURL() -> URL? {
        let executableDirectory = Bundle.main.executableURL?
            .deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return executableDirectory
            .appendingPathComponent("lisp", isDirectory: true)
            .appendingPathComponent("ribbon.lsp")
    }

    /// User file first, then the bundled default. Pure overload for tests.
    public static func resolvedDefinitionURL(
        userFile: URL?,
        bundled: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let userFile, fileManager.fileExists(atPath: userFile.path) {
            return userFile
        }
        if let bundled, fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    public static func resolvedDefinitionURL(
        fileManager: FileManager = .default
    ) -> URL? {
        resolvedDefinitionURL(
            userFile: userFileURL(),
            bundled: bundledFileURL(),
            fileManager: fileManager)
    }

    /// Copies a bundled definition to `target` unless one already exists.
    /// The user copy is never overwritten: it is the file they edit.
    @discardableResult
    public static func seed(
        from bundled: URL,
        to target: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        if fileManager.fileExists(atPath: target.path) { return target }
        guard fileManager.fileExists(atPath: bundled.path) else { return nil }
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileManager.copyItem(at: bundled, to: target)
            print("[Ribbon] seeded \(target.path) from \(bundled.path)")
            return target
        } catch {
            print("[Ribbon] could not seed \(target.path): \(error)")
            return nil
        }
    }

    /// No-op: user definitions are only loaded if placed manually by the user,
    /// preventing stale user copies from shadowing app updates.
    @discardableResult
    public static func seedUserDefinitionIfNeeded(
        fileManager: FileManager = .default,
        bundled: URL? = nil
    ) -> URL? {
        return nil
    }

    // MARK: - Reload

    /// Asks for a reload. When a LISP run or feature command is in flight the
    /// request is queued and retried from `poll()`.
    public func requestReload(reason: String) {
        guard !isLoading else {
            pendingReloadReason = reason
            return
        }
        guard let processor else {
            reportFailure(
                "ribbon support is unavailable (no command processor)",
                path: nil)
            return
        }
        guard processor.lispInvocationDepth == 0,
              processor.activeFeatureCommand == nil
        else {
            pendingReloadReason = reason
            return
        }
        guard let url = definitionURLProvider() else {
            reportFailure(
                "no ribbon definition found (looked for "
                    + "\(Self.userFileURL()?.path ?? "?") and "
                    + "\(Self.bundledFileURL()?.path ?? "?"))",
                path: nil)
            return
        }
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            reportFailure("cannot read \(url.path): \(error)", path: url.path)
            return
        }
        beginLoad(source: source, path: url.path)
    }

    /// Manual reload entry point (the `RIBBONRELOAD` command / ⟳ button).
    public func reload() {
        requestReload(reason: "manual")
    }

    /// Starts an evaluation for `source`. Internal so tests can load an
    /// inline definition without touching the filesystem.
    internal func beginLoad(source: String, path: String) {
        guard let processor, !isLoading else { return }
        guard processor.lispInvocationDepth == 0,
              processor.activeFeatureCommand == nil
        else {
            // Inline loads (tests) are not replayable; a queued retry only
            // makes sense for `requestReload`, which has already stored its
            // reason before reaching here.
            return
        }

        let document = documentProvider()
        let selection = selectionProvider()
        let host = LispCommand.makeHost(
            document: document,
            selection: selection,
            processor: processor,
            broker: LispInputBroker())
        let buffer = RibbonLoadOutputBuffer()
        host.output = { text in buffer.append(text) }
        host.captureMainThreadState(
            selectedHandles: selection.selectedHandles,
            activeCommand: processor.activeCommand)

        // A copy: helpers the user already defined are callable, but nothing
        // this file defines leaks into the session.
        let environment = processor.lispSession
        let source = RibbonPrelude.source + "\n" + source

        let box = RibbonLoadCompletionBox()
        completion = box
        activeHost = host
        activeBuffer = buffer
        loadStartedAt = Date()
        sourcePath = path
        status = .loading
        processor.lispInvocationDepth = 1

        task = Task.detached(priority: .userInitiated) {
            let outcome = await RibbonLoadEvaluator.evaluate(
                source: source, host: host, environment: environment)
            box.store(outcome)
        }
    }

    // MARK: - Per-frame pump

    /// Drains definition output and the finished-load result. Call once per
    /// frame (cheap when nothing is in flight).
    public func poll() {
        flushOutput()
        timeoutIfNeeded()

        if let outcome = completion?.take() {
            completion = nil
            finish(
                outcome,
                path: sourcePath,
                processor: processor,
                document: documentProvider())
        }

        if !isLoading, let reason = pendingReloadReason {
            pendingReloadReason = nil
            requestReload(reason: reason)
        }

        autoReloadIfFileChanged()
    }

    // MARK: - Completion

    private func finish(
        _ outcome: RibbonLoadOutcome,
        path: String?,
        processor: CADCommandProcessor?,
        document: CADDocument
    ) {
        endFlight(processor: processor, document: document)

        if let message = outcome.errorMessage {
            reportFailure("evaluation failed: \(message)", path: path)
            return
        }
        guard let value = outcome.value else {
            reportFailure("evaluation produced no value", path: path)
            return
        }

        let catalog = processor?.ribbonCommandCatalog
            ?? RibbonCommandCatalog.fromCurrentApp()
        do {
            let parsed = try RibbonSpecParser.parse(value, catalog: catalog)
            spec = parsed.spec
            warnings = parsed.warnings
            errorMessage = nil
            status = .loaded
            for warning in parsed.warnings {
                output("[Ribbon] \(warning)\n")
            }
            output(
                "[Ribbon] loaded \(parsed.spec.tabs.count) tab(s), "
                    + "\(parsed.spec.menus.count) menu(s) from "
                    + "\(path ?? "<unknown>")\n")
        } catch {
            reportFailure(
                "\(error)",
                path: path)
        }
    }

    /// Releases the single-flight slot and any state the evaluation left.
    private func endFlight(
        processor: CADCommandProcessor?, document: CADDocument
    ) {
        task = nil
        activeHost = nil
        activeBuffer = nil
        loadStartedAt = nil
        completion = nil
        processor?.lispInvocationDepth = 0
        // A definition file has no business leaving open undo groups: that
        // would fold the user's next edit into the load.
        if document.undoManager.undoGroupDepth > 0 {
            document.undoManager.discardOpenUndoGroups()
        }
    }

    private func reportFailure(_ message: String, path: String?) {
        errorMessage = message
        status = .failed
        sourcePath = path
        output("[Ribbon] \(message) — keeping the previous definition\n")
    }

    private func timeoutIfNeeded() {
        guard let started = loadStartedAt, isLoading else { return }
        guard Date().timeIntervalSince(started) > loadTimeout else { return }
        // A definition that prompts (getpoint &c.) can never finish on its
        // own; reclaim the slot rather than freezing every command.
        activeHost?.broker.cancelPending()
        task?.cancel()
        reportFailure(
            "definition did not finish within \(Int(loadTimeout))s "
                + "(a definition file must not ask for input)",
            path: sourcePath)
        endFlight(
            processor: processor,
            document: documentProvider())
    }

    // MARK: - Output + auto reload

    private func flushOutput() {
        guard let buffer = activeBuffer else { return }
        let text = buffer.drain()
        if !text.isEmpty { output(text) }
    }

    internal func autoReloadIfFileChanged(now: Date = Date()) {
        guard autoReloadEnabled, !isLoading else { return }
        guard now.timeIntervalSince(lastMTimeCheck) >= 1 else { return }
        lastMTimeCheck = now

        guard let url = definitionURLProvider() else { return }
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard let modified else { return }
        if let last = lastKnownMTime {
            if modified > last {
                lastKnownMTime = modified
                requestReload(reason: "file changed")
            }
        } else {
            // First observation after a load (or a failure): baseline only.
            lastKnownMTime = modified
        }
    }

    /// Records the current file timestamp, so an auto-reload does not fire
    /// immediately after a manual load.
    public func baselineFileTimestamp() {
        guard let url = definitionURLProvider() else { return }
        lastKnownMTime = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        lastMTimeCheck = Date()
    }

    // MARK: - Test helpers

    /// Waits for the in-flight load to finish, pumping `poll()` like the
    /// render loop does.
    internal func waitForLoad(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isLoading, Date() < deadline {
            poll()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        poll()
    }
}

// =========================================================================
// MARK: - Off-actor load machinery
// =========================================================================
//
// File scope on purpose: everything below runs on the detached evaluation
// task, and nested types would inherit `@MainActor` from `RibbonSpecLoader`
// (a hop the unpumped SDL loop never services).

/// Outcome of one definition evaluation, crossed back to the UI thread as
/// plain Sendable data.
struct RibbonLoadOutcome: Sendable {
    var value: LispValue?
    var errorMessage: String?
}

enum RibbonLoadEvaluator {
    /// Evaluates the definition file and then CALLS `(zephyr-ribbon)` — the
    /// file only has to define it, which is what a user expects when editing
    /// a definition ("no stray call at the bottom of the file").
    static func evaluate(
        source: String, host: LispCADHost, environment: LispEnvironment
    ) async -> RibbonLoadOutcome {
        do {
            var env = environment
            let forms = try LispReader().readAll(
                source, sourceName: "ribbon.lsp")
            _ = try await LispEvaluator().run(forms, env: &env, host: host)

            guard env.functions["ZEPHYR-RIBBON"] != nil else {
                return RibbonLoadOutcome(
                    value: nil,
                    errorMessage: "zephyr-ribbon is not defined; the file must "
                        + "define (defun zephyr-ribbon () ...)")
            }
            let call = try LispReader().readAll("(zephyr-ribbon)")
            let value = try await LispEvaluator().run(
                call, env: &env, host: host)
            return RibbonLoadOutcome(value: value, errorMessage: nil)
        } catch let error as RibbonSpecError {
            return RibbonLoadOutcome(
                value: nil, errorMessage: error.message)
        } catch {
            return RibbonLoadOutcome(value: nil, errorMessage: "\(error)")
        }
    }
}

/// Lock box for the completed evaluation (the eval task never hops to
/// MainActor; `poll()` picks the value up).
final class RibbonLoadCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RibbonLoadOutcome?

    func store(_ outcome: RibbonLoadOutcome) {
        lock.withLock { value = outcome }
    }

    func hasPendingResult() -> Bool {
        lock.withLock { value != nil }
    }

    func take() -> RibbonLoadOutcome? {
        lock.withLock {
            defer { value = nil }
            return value
        }
    }
}

/// Thread-safe sink for the evaluator's `princ` output.
final class RibbonLoadOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.withLock { text += chunk }
    }

    func drain() -> String {
        lock.withLock {
            defer { text = "" }
            return text
        }
    }
}

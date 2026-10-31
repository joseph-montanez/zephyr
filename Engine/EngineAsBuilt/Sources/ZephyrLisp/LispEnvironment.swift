// LispEnvironment: dynamic-scope bindings for one evaluation.
//
// Lookup order is innermost locals frame first, then globals. setq updates
// the nearest existing binding and otherwise defines a global. Function
// definitions (defun) live in a separate map from variables, matching
// AutoLISP (one symbol can name both a variable and a function).

/// A user-defined function: parameters, / locals, and body forms.
public struct LispFunction: Sendable {
    public let params: [String]
    public let locals: [String]
    public let body: [LispValue]
    /// Source form for defun-q-list-ref (nil for plain defun).
    public let quotedForm: LispValue?

    public init(params: [String], locals: [String], body: [LispValue], quotedForm: LispValue? = nil) {
        self.params = params
        self.locals = locals
        self.body = body
        self.quotedForm = quotedForm
    }
}

/// Dynamic-scope evaluation state. Passed inout through the async evaluator
/// (single eval task per command, so the borrow never interleaves).
public struct LispEnvironment: Sendable {
    /// Global variable bindings. Preloaded with pi, T, and the error-mode
    /// flags (the engine always uses stack-based routing, which these flags
    /// select; assigning them is accepted but currently advisory).
    public var globals: [String: LispValue] = [
        "PI": .real(Double.pi),
        "T": .symbol("T"),
        // Self-evaluating PAUSE: the (command ... pause ...) idiom arrives
        // at the scripted dispatcher as a symbol, which rejects it with a
        // clear PAUSE error instead of a mysterious nil. (setq can shadow.)
        "PAUSE": .symbol("PAUSE"),
        "*POP-ERROR-MODE*": .nilValue,
        "*PUSH-ERROR-USING-COMMAND*": .symbol("T"),
        "*PUSH-ERROR-USING-STACK*": .symbol("T"),
    ]
    /// Locals stack, innermost last. Each defun call pushes one frame.
    public var localsStack: [[String: LispValue]] = []
    /// User function definitions by uppercase name.
    public var functions: [String: LispFunction] = [:]
    /// Pending initget control for the next get* call (bits + keyword list).
    public var pendingInitget: LispInitget = LispInitget()
    /// Blackboard (vl-bb-ref / vl-bb-set) namespace.
    public var blackboard: [String: LispValue] = [:]
    /// Doc-scoped exports (vl-doc-export / vl-doc-import). Single-doc
    /// host: identity store until Tier 2 multi-document arrives.
    public var docScope: [String: LispValue] = [:]
    /// Drawing-modified counter for acad-push/pop-dbmod. Session-owned
    /// (starts at 0); no DBMOD sysvar exists yet for the CAD host to
    /// update, so scripts see a stable counter they can push and pop.
    public var dbmod: Int = 0
    /// Saved dbmod values (acad-push-dbmod stack).
    public var dbmodStack: [Int] = []
    /// Command version constraint (initcommandversion). No versioned
    /// commands exist yet; stored for scripts to probe.
    public var commandVersion: Int = 0
    /// Help registrations (setfunhelp): uppercase command -> help entry.
    public var funHelp: [String: LispFunHelp] = [:]
    /// Dimension auto-update toggle (acdimenableupdate). Default on.
    public var dimUpdateEnabled: Bool = true
    /// Express layer-previous tracking (acet-layerp-mode / -mark).
    /// Underpinning only: no LAYERP command consumes it yet.
    public var layerpMode: Bool = false
    public var layerpDepth: Int = 0
    /// Next-command dialog flag (initdia). Scripted (command) targets
    /// have no dialogs, so this is stored, not consumed.
    public var initDiaFlag: Int = 0
    /// Named layer snapshots (layerstate-*), keyed by uppercase name.
    /// Only on/off is captured until the Layer model grows frozen,
    /// locked, color, and linetype state.
    public var layerStates: [String: LispLayerState] = [:]
    /// Most recently restored snapshot (layerstate-getlastrestored).
    public var lastRestoredLayerState: String?
    /// Custom *error* handler mode stack (*push-error-using-command* /
    /// *push-error-using-stack* / *pop-error-mode*). Frames record how
    /// the active handler runs; the interpreter consults nothing yet —
    /// single-namespace hosts have one handler — but the push/pop
    /// contract is real.
    public var errorModeStack: [String] = []
    /// Trace flags (trace / untrace).
    public var tracedFunctions: Set<String> = []
    /// *error* reentrancy guard (run() refuses past 5 nested handlers).
    public var errorHandlerDepth: Int = 0
    /// Autoload registry: uppercase command name -> file path.
    public var autoloadStubs: [String: String] = [:]
    /// Autoload regress guard: names currently being loaded.
    public var autoloadInProgress: Set<String> = []
    /// Open text files by descriptor id (open/close/read-char/...).
    /// Read-mode files are fully buffered at open; writes go through to
    /// disk on every call. Single eval task owns this; no sharing.
    public var openFiles: [Int: LispOpenFile] = [:]
    /// Next file descriptor id (monotonic; never recycled).
    public var nextFileID: Int = 1
    /// Named dictionaries (dictadd/dictsearch/...): dict name -> key -> value.
    /// Session-local underpinning (per-drawing dictionaries land with xdata);
    /// NAMEDOBJDICT is pre-seeded. All names uppercased.
    public var dictionaries: [String: [String: LispValue]] = ["NAMEDOBJDICT": [:]]
    /// dictnext iteration cursors by dictionary name.
    public var dictCursors: [String: Int] = [:]
    /// Registered application ids (regapp), uppercased.
    public var appIDs: Set<String> = []
    /// Advisory node-space counters (alloc/expand). Swift manages memory;
    /// these exist so scripts that size their workspace keep working.
    public var allocNodes: Int = 10_000
    public var expandSegments: Int = 1

    public init() {}

    /// Innermost-first variable lookup.
    public func lookup(_ name: String) -> LispValue? {
        for frame in localsStack.reversed() {
            if let value = frame[name] { return value }
        }
        return globals[name]
    }

    /// setq semantics: update the nearest existing binding, else define a global.
    /// Returns the assigned value. T and NIL are protected.
    public mutating func assign(_ name: String, _ value: LispValue) throws -> LispValue {
        guard name != "T", name != "NIL" else {
            throw LispError.protectedSymbol(name)
        }
        for index in localsStack.indices.reversed() {
            if localsStack[index][name] != nil {
                localsStack[index][name] = value
                return value
            }
        }
        globals[name] = value
        return value
    }

    /// Pushes one call frame with params bound and locals pre-bound to nil.
    /// Returns nothing; callers must pop with defer.
    public mutating func pushFrame(params: [String], args: [LispValue], locals: [String]) {
        var frame: [String: LispValue] = [:]
        for local in locals { frame[local] = .nilValue }
        for (param, arg) in zip(params, args) { frame[param] = arg }
        localsStack.append(frame)
    }

    public mutating func popFrame() {
        _ = localsStack.popLast()
    }
}

/// One open text file (see LispBuiltinsFile).
public struct LispOpenFile: Sendable {
    /// Resolved path (as given; relative paths resolve against the CWD).
    public var path: String
    /// Lowercased open mode: "r", "w", or "a".
    public var mode: String
    /// Read mode: full buffered content as characters. Write modes: empty.
    public var chars: [Character]
    /// Next character index for read-char/read-line.
    public var offset: Int

    public init(path: String, mode: String, chars: [Character] = [], offset: Int = 0) {
        self.path = path
        self.mode = mode
        self.chars = chars
        self.offset = offset
    }

    public var atEOF: Bool { offset >= chars.count }
}

/// initget control state: bit flags plus the keyword string.
public struct LispInitget: Sendable {
    /// Bit flags (1=no-null, 2=no-zero, 4=no-negative, ...).
    public var bits: Int = 0
    /// Allowed keywords, in defined spelling (matching is case-insensitive).
    public var keywords: [String] = []

    public init(bits: Int = 0, keywords: [String] = []) {
        self.bits = bits
        self.keywords = keywords
    }

    public var isEmpty: Bool { bits == 0 && keywords.isEmpty }
}

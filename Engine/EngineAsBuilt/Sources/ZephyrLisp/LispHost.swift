// LispHost: the effect surface between the pure evaluator and the world.
//
// Everything the evaluator cannot compute from values alone goes through
// here: display output, user input (suspending as needed), system variables,
// command invocation, entity/selection stores, and file dialogs. Three
// implementations exist across the plan: a CLI host (ZephyrBench REPL),
// scripted test hosts (ZephyrLispTests), and the MainActor CAD host
// (step 3). Entity/selection/file methods carry default implementations
// that report a clean error, so hosts adopt incrementally.

/// Display + input + drawing services for the evaluator. Sendable: values
/// cross isolation as data; hosts serialize internally as needed.
/// Point-prompt answer: picked coordinates or a typed bare number.
public enum LispPointInput: Sendable, Equatable {
    case point([Double])
    case number(Double)
}

public protocol LispHost: Sendable {
    // MARK: - Display

    /// princ/prompt/print/terpri output sink (no added newline).
    func write(_ text: String) async
    /// Alert dialog; falls back to write when headless.
    func alert(_ text: String) async

    // MARK: - Line input (getstring/getreal/getint/getdist/getangle/...)

    /// Reads one input line. Returns nil on empty input (bare Enter).
    /// Throws .userCancel on Esc. Callers parse + re-prompt.
    func requestLine(prompt: String) async throws -> String?
    /// `getstring T` variant: spaces are literal input terminated by Enter
    /// only. Hosts without a Space-submits UI may ignore the flag.
    func requestLineAllowingSpaces(prompt: String, allowSpaces: Bool) async throws -> String?

    // MARK: - Geometric input

    /// Point pick: 2-3 coordinates, or nil on empty input. Throws .userCancel.
    /// Hosts loop internally until the input parses, is empty, or cancels.
    func requestPoint(prompt: String, base: [Double]?) async throws -> [Double]?
    /// Point or bare-number pick (getdist/getangle/getorient typed-number
    /// escape). Default wraps requestPoint (no number escape); hosts with
    /// text input override to parse both.
    func requestPointOrNumber(prompt: String, base: [Double]?) async throws -> LispPointInput?
    /// Entity pick: handle + pick point, or nil on empty input.
    /// Throws .userCancel. Hosts re-prompt internally on misses.
    func requestEntity(prompt: String) async throws -> (handle: String, point: [Double])?
    /// One raw device event for grread.
    func readDeviceEvent() async throws -> LispValue
    /// Passive nested selection: nentsel-shaped data for the pickfirst
    /// entity, or nil when nothing is picked. Never prompts.
    func nentselPassive(at point: [Double]?) async throws -> LispValue?

    // MARK: - System variables

    func getSystemVar(_ name: String) async -> LispValue?
    func setSystemVar(_ name: String, _ value: LispValue) async

    // MARK: - Commands (step 3 binds the real processor)

    /// Runs one (command ...) call. Default: clean unsupported error.
    func runCommand(_ args: [LispValue]) async throws -> LispValue
    /// (command-s ...) variant. Default: forwards to runCommand.
    func runCommandS(_ args: [LispValue]) async throws -> LispValue

    // MARK: - Entity store (step 3 binds CADDocument)

    func entGet(_ handle: String) async throws -> LispValue
    func entMod(_ dxfList: LispValue) async throws -> LispValue
    func entMake(_ dxfList: LispValue) async throws -> LispValue
    func entMakeX(_ dxfList: LispValue) async throws -> LispValue
    func entDel(_ handle: String) async throws -> LispValue
    func entLast() async throws -> LispValue
    func entNext(_ handle: String?) async throws -> LispValue
    func handEnt(_ handle: String) async throws -> LispValue
    func entUpd(_ handle: String) async throws -> LispValue

    // MARK: - Minimal ActiveX (step-3 vla underpinning)

    /// World bounding box for vla-getboundingbox. Default: clean error.
    func vlaBoundingBox(_ handle: String) async throws -> (min: [Double], max: [Double])

    // MARK: - Symbol tables (step 4 binds CADDocument)

    /// Next entry assoc list (tblnext), or nil at iteration end.
    /// rewind restarts from the first entry. Unknown tables throw.
    func tableNext(_ table: String, rewind: Bool) async throws -> LispValue?
    /// Named entry assoc list (tblsearch), or nil when absent. setNext
    /// parks the tblnext cursor after the entry. Unknown tables throw.
    func tableSearch(_ table: String, name: String, setNext: Bool) async throws -> LispValue?
    /// Layout names (layoutlist). Default: Model only.
    func layoutNames() async -> [String]
    /// Extended selection data (ssnamex): nested ((ename)) shape.
    func ssNameX(_ set: Int, index: Int) async throws -> LispValue

    // MARK: - Properties + transforms (step 4 binds CADDocument)

    /// Property read (getpropertyvalue). Index selects into list
    /// properties (COORDINATES). Unknown property throws.
    func propertyValue(_ handle: String, property: String, index: Int?) async throws -> LispValue
    /// Property write (setpropertyvalue). Read-only/unknown throws.
    func setPropertyValue(
        _ handle: String, property: String, value: LispValue
    ) async throws -> LispValue
    /// Read-only probe (ispropertyreadonly). Unknown property throws.
    func isPropertyReadOnly(_ handle: String, property: String) async throws -> Bool
    /// Property dump (dumpallproperties): prints + returns T.
    func dumpProperties(_ handle: String) async throws
    /// Text bounds (textbox) from an entget-style list: ((min)(max))
    /// world points, or nil for non-TEXT.
    func textBox(_ dxfList: LispValue) async throws -> LispValue?
    /// Coordinate transform (trans): 0 = WCS, 1 = UCS (= WCS here),
    /// ename = entity frame. disp treats the point as a direction.
    func transPoint(
        _ point: [Double], from: LispValue, to: LispValue, disp: Bool
    ) async throws -> [Double]
    /// Remaining xdata budget for an entity (xdroom).
    func xdataRoom(_ handle: String) async throws -> Int
    /// Undo group marks (vla-startundomark/vla-endundomark).
    /// Default no-op; the CAD host opens/closes an undo group.
    func beginUndoMark() async
    func endUndoMark() async

    // MARK: - Selection sets (step 3 binds CADSelectionManager)

    /// All-matching selection, or nil when nothing matches (AutoCAD
    /// (ssget "_X") returns nil on empty).
    func ssGet(filter: LispValue?) async throws -> Int?
    /// Interactive pick (modes PICK/P/C/W/F/CP/WP/L/I + points + filter),
    /// or nil when the result is empty.
    func ssGetInteractive(mode: String, points: [[Double]], filter: LispValue?) async throws -> Int?
    func ssAdd(_ handle: String?, set: Int?) async throws -> Int
    func ssDel(_ handle: String, set: Int) async throws -> LispValue
    func ssLength(_ set: Int) async throws -> Int
    func ssName(_ set: Int, index: Int) async throws -> LispValue
    func ssMemb(_ handle: String, set: Int) async throws -> LispValue
    func ssGetFirst() async throws -> LispValue
    func ssSetFirst(_ set: Int?) async throws -> LispValue

    // MARK: - Transient graphics + views (step 4d; CAD binds osnap only)

    /// Transient vector (grdraw). Default ignores; a future transient
    /// layer renders it. Points are 2-3 doubles.
    func grDraw(from: [Double], to: [Double], color: Int, highlight: Bool) async
    /// Transient vector batch (grvecs): (color, from, to) triples with
    /// an optional 4x4 row-major transform. Default ignores.
    func grVecs(
        _ vectors: [(color: Int, from: [Double], to: [Double])],
        transform: [[Double]]?
    ) async
    /// Clears transient vectors (grclear). Default ignores.
    func grClear() async
    /// Status/menu-cell text (grtext). Default ignores.
    func grText(box: Int, text: String, highlight: Bool) async
    /// Entity redraw/highlight (redraw modes 1-4); nil handle redraws
    /// the viewport. Default ignores (continuous renderer).
    func redraw(handle: String?, mode: Int) async
    /// Named view restore (setview); viewport index is accepted and
    /// ignored (single viewport). Default false (no named views).
    func setView(name: String, viewport: Int?) async -> Bool
    /// Object snap (osnap): modes are canonical uppercase names
    /// (END, MID, CEN, QUA, INS, NEA). Returns the snapped 3D point
    /// or nil when nothing is within threshold. Default nil.
    func osnap(point: [Double], modes: [String]) async -> [Double]?

    // MARK: - Layers (step 4d binds CADDocument)

    /// All layer names (layerstate snapshots). Default [].
    func layerNames() async -> [String]
    /// Layer on/off; nil for unknown layers. Default nil.
    func layerIsOn(_ name: String) async -> Bool?
    /// Sets layer on/off; false for unknown layers. Default false.
    func setLayerIsOn(_ name: String, on: Bool) async -> Bool
    func layerIsFrozen(_ name: String) async -> Bool?
    func setLayerFrozen(_ name: String, frozen: Bool) async -> Bool
    func layerIsLocked(_ name: String) async -> Bool?
    func setLayerLocked(_ name: String, locked: Bool) async -> Bool
    func layerMake(_ name: String) async -> Bool
    func layerDelete(_ name: String) async -> Bool
    func layerMerge(from sources: [String], into target: String) async -> Bool
    func layerHistoryDepth() async -> Int

    // MARK: - File + color dialogs (step 4d underpinnings)

    /// File dialog (getfiled); flags/extension filtering is host-
    /// specific. Nil means cancel/unavailable. Default nil.
    func requestFile(
        title: String, defaultPath: String, extensions: String, flags: Int
    ) async -> String?
    /// Modal color picker (acad_colordlg) -> ACI 0-256. Nil means
    /// cancel/unavailable. Default nil.
    func requestColor(default defaultACI: Int, allowByLayer: Bool) async -> Int?
    /// Modal true-color picker (acad_truecolordlg) -> ((62 . aci)) or
    /// ((420 . rgb)). Nil means cancel/unavailable. Default nil.
    func requestTrueColor(defaultACI: Int?, allowByLayer: Bool) async -> LispValue?
}

// MARK: - Incremental-adoption defaults

extension LispHost {
    public func alert(_ text: String) async {
        await write(text)
    }

    /// Hosts without a Space-submits command line (REPL, scripted tests)
    /// read whole lines either way; the `getstring` builtin itself still
    /// truncates non-T input at the first space.
    public func requestLineAllowingSpaces(prompt: String, allowSpaces: Bool) async throws -> String? {
        _ = allowSpaces
        return try await requestLine(prompt: prompt)
    }

    public func requestPointOrNumber(prompt: String, base: [Double]?) async throws -> LispPointInput? {
        guard let coords = try await requestPoint(prompt: prompt, base: base) else { return nil }
        return .point(coords)
    }

    public func nentselPassive(at point: [Double]?) async throws -> LispValue? {
        _ = point
        throw LispError.noActiveDrawing("nentselp")
    }

    public func runCommand(_ args: [LispValue]) async throws -> LispValue {
        _ = args
        throw LispError.hostError("(command ...) needs a command host")
    }

    public func runCommandS(_ args: [LispValue]) async throws -> LispValue {
        try await runCommand(args)
    }

    public func entGet(_ handle: String) async throws -> LispValue {
        throw LispError.noActiveDrawing("entget \(handle)")
    }

    public func entMod(_ dxfList: LispValue) async throws -> LispValue {
        _ = dxfList
        throw LispError.noActiveDrawing("entmod")
    }

    public func entMake(_ dxfList: LispValue) async throws -> LispValue {
        _ = dxfList
        throw LispError.noActiveDrawing("entmake")
    }

    public func entMakeX(_ dxfList: LispValue) async throws -> LispValue {
        _ = dxfList
        throw LispError.noActiveDrawing("entmakex")
    }

    public func entDel(_ handle: String) async throws -> LispValue {
        throw LispError.noActiveDrawing("entdel \(handle)")
    }

    public func entLast() async throws -> LispValue {
        throw LispError.noActiveDrawing("entlast")
    }

    public func entNext(_ handle: String?) async throws -> LispValue {
        _ = handle
        throw LispError.noActiveDrawing("entnext")
    }

    public func handEnt(_ handle: String) async throws -> LispValue {
        throw LispError.noActiveDrawing("handent \(handle)")
    }

    public func entUpd(_ handle: String) async throws -> LispValue {
        throw LispError.noActiveDrawing("entupd \(handle)")
    }

    public func vlaBoundingBox(_ handle: String) async throws -> (min: [Double], max: [Double]) {
        throw LispError.noActiveDrawing("vla-getboundingbox \(handle)")
    }

    public func tableNext(_ table: String, rewind: Bool) async throws -> LispValue? {
        _ = rewind
        throw LispError.noActiveDrawing("tblnext \(table)")
    }

    public func tableSearch(_ table: String, name: String, setNext: Bool) async throws -> LispValue? {
        _ = name
        _ = setNext
        throw LispError.noActiveDrawing("tblsearch \(table)")
    }

    public func layoutNames() async -> [String] {
        ["Model"]
    }

    public func ssNameX(_ set: Int, index: Int) async throws -> LispValue {
        _ = set
        _ = index
        throw LispError.noActiveDrawing("ssnamex")
    }

    public func propertyValue(
        _ handle: String, property: String, index: Int?
    ) async throws -> LispValue {
        _ = handle
        _ = property
        _ = index
        throw LispError.noActiveDrawing("getpropertyvalue")
    }

    public func setPropertyValue(
        _ handle: String, property: String, value: LispValue
    ) async throws -> LispValue {
        _ = handle
        _ = property
        _ = value
        throw LispError.noActiveDrawing("setpropertyvalue")
    }

    public func isPropertyReadOnly(_ handle: String, property: String) async throws -> Bool {
        _ = handle
        _ = property
        throw LispError.noActiveDrawing("ispropertyreadonly")
    }

    public func dumpProperties(_ handle: String) async throws {
        throw LispError.noActiveDrawing("dumpallproperties \(handle)")
    }

    public func textBox(_ dxfList: LispValue) async throws -> LispValue? {
        _ = dxfList
        throw LispError.noActiveDrawing("textbox")
    }

    public func transPoint(
        _ point: [Double], from: LispValue, to: LispValue, disp: Bool
    ) async throws -> [Double] {
        _ = point
        _ = from
        _ = to
        _ = disp
        throw LispError.noActiveDrawing("trans")
    }

    public func xdataRoom(_ handle: String) async throws -> Int {
        throw LispError.noActiveDrawing("xdroom \(handle)")
    }

    public func beginUndoMark() async {}
    public func endUndoMark() async {}

    public func ssGet(filter: LispValue?) async throws -> Int? {
        _ = filter
        throw LispError.noActiveDrawing("ssget")
    }

    public func ssGetInteractive(mode: String, points: [[Double]], filter: LispValue?) async throws -> Int? {
        _ = points
        _ = filter
        throw LispError.noActiveDrawing("ssget \(mode)")
    }

    public func ssAdd(_ handle: String?, set: Int?) async throws -> Int {
        _ = handle
        _ = set
        throw LispError.noActiveDrawing("ssadd")
    }

    public func ssDel(_ handle: String, set: Int) async throws -> LispValue {
        _ = handle
        _ = set
        throw LispError.noActiveDrawing("ssdel")
    }

    public func ssLength(_ set: Int) async throws -> Int {
        _ = set
        throw LispError.noActiveDrawing("sslength")
    }

    public func ssName(_ set: Int, index: Int) async throws -> LispValue {
        _ = set
        _ = index
        throw LispError.noActiveDrawing("ssname")
    }

    public func ssMemb(_ handle: String, set: Int) async throws -> LispValue {
        _ = handle
        _ = set
        throw LispError.noActiveDrawing("ssmemb")
    }

    public func ssGetFirst() async throws -> LispValue {
        throw LispError.noActiveDrawing("ssgetfirst")
    }

    public func ssSetFirst(_ set: Int?) async throws -> LispValue {
        _ = set
        throw LispError.noActiveDrawing("sssetfirst")
    }

    public func grDraw(from: [Double], to: [Double], color: Int, highlight: Bool) async {
        _ = (from, to, color, highlight)
    }

    public func grVecs(
        _ vectors: [(color: Int, from: [Double], to: [Double])],
        transform: [[Double]]?
    ) async {
        _ = (vectors, transform)
    }

    public func grClear() async {}

    public func grText(box: Int, text: String, highlight: Bool) async {
        _ = (box, text, highlight)
    }

    public func redraw(handle: String?, mode: Int) async {
        _ = (handle, mode)
    }

    public func setView(name: String, viewport: Int?) async -> Bool {
        _ = (name, viewport)
        return false
    }

    public func osnap(point: [Double], modes: [String]) async -> [Double]? {
        _ = (point, modes)
        return nil
    }

    public func layerNames() async -> [String] { [] }
    public func layerIsFrozen(_ name: String) async -> Bool? { nil }
    public func setLayerFrozen(_ name: String, frozen: Bool) async -> Bool { false }
    public func layerIsLocked(_ name: String) async -> Bool? { nil }
    public func setLayerLocked(_ name: String, locked: Bool) async -> Bool { false }
    public func layerMake(_ name: String) async -> Bool { false }
    public func layerDelete(_ name: String) async -> Bool { false }
    public func layerMerge(from sources: [String], into target: String) async -> Bool { false }
    public func layerHistoryDepth() async -> Int { 0 }

    public func layerIsOn(_ name: String) async -> Bool? {
        _ = name
        return nil
    }

    public func setLayerIsOn(_ name: String, on: Bool) async -> Bool {
        _ = (name, on)
        return false
    }

    public func requestFile(
        title: String, defaultPath: String, extensions: String, flags: Int
    ) async -> String? {
        _ = (title, defaultPath, extensions, flags)
        return nil
    }

    public func requestColor(default defaultACI: Int, allowByLayer: Bool) async -> Int? {
        _ = (defaultACI, allowByLayer)
        return nil
    }

    public func requestTrueColor(defaultACI: Int?, allowByLayer: Bool) async -> LispValue? {
        _ = (defaultACI, allowByLayer)
        return nil
    }
}

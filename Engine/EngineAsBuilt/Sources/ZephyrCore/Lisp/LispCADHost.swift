import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Lisp CAD Host (LispHost over CADDocument + broker)
// =========================================================================
//
// The step-3 host binding: the evaluator's effect surface implemented
// against a live `CADDocument`, `CADSelectionManager`, and the suspending
// `LispInputBroker`. Constructible headless (document + selection +
// broker) for tests and the corpus runner, or fronted by `LispCommand`
// inside the running app.
//
// Conventions shared with the driver (`LispCommand`):
// * Prompts: every request records `currentPrompt` (+ `pendingBase` for
//   points) so the driver can render the command prompt and rubber bands.
// * Typed coordinates arrive as `.point` events: 2-3 numbers = point,
//   exactly 1 number = typed bare number (getdist/getangle escape).
// * Entity misses arrive as `.entity(handle: nil, point: <click>)` and
//   re-prompt; `.entity(handle: nil, point: nil)` is empty input (Enter).
// * Selection sets live in `selectionSets` keyed by small integers;
//   ids recycle never (monotonic) so stale ids fail closed.

/// Threading: UNISOLATED by design. The evaluator runs on a background
/// task and the app's SDL loop never pumps the main dispatch queue, so any
/// MainActor hop from evaluation stalls forever. Everything this host
/// touches from evaluation is therefore hop-free: the document (established
/// off-main posture, same as regen tasks), the lock-based broker and var
/// store, and snapshots — never the live selection manager or processor.
/// Cross-thread state (prompt mirror, selection snapshot/apply) serializes
/// on `stateLock`; selection writes drain to the real manager on the main
/// thread via the driver's frame poll.
final class LispCADHost: LispHost, @unchecked Sendable {
    let document: CADDocument
    let selection: CADSelectionManager
    let processor: CADCommandProcessor?
    let broker: LispInputBroker
    let vars: LispVarStore
    /// Output sink. Must be thread-safe: invoked from the eval task.
    /// (Today print; a future command-line history wire-up must lock.)
    var output: (String) -> Void = { print($0, terminator: "") }

    private let stateLock = NSLock()

    // MARK: - Session state (eval-task confined)

    /// Most recently created entity (entlast / _L).
    var lastCreated: UUID?
    /// Incomplete scripted command buffered across multiple (command ...) calls.
    var pendingCommandArgs: [LispValue] = []
    /// Most recent non-empty consumed selection (_P).
    var previousSelection: Set<UUID> = []
    /// UNDO Mark position (single mark; Back returns to it).
    var undoMark: Int?
    /// entdel toggle stash: erased-but-restorable entities.
    var erased: [UUID: CADEntity] = [:]
    private var selectionSets: [Int: [UUID]] = [:]
    private var nextSelectionID = 1

    // MARK: - Prompt mirror (for the driver's overlay)

    private var _currentPrompt: String = ""
    private var _pendingBase: [Double]?
    var currentPrompt: String { stateLock.withLock { _currentPrompt } }
    var pendingBase: [Double]? { stateLock.withLock { _pendingBase } }
    private func setPrompt(_ prompt: String, base: [Double]?) {
        stateLock.withLock {
            _currentPrompt = prompt
            _pendingBase = base
        }
    }

    // MARK: - Main-thread snapshots (captured by the driver on start)

    /// Pickfirst selection frozen at command start (_I, ssgetfirst reads).
    private var _impliedSelection: Set<UUID> = []
    /// Legacy active command name for CMDNAMES (empty under feature commands).
    var activeCommandSnapshot: String?
    /// Pending pickfirst write for the driver's frame drain (sssetfirst).
    private var _pendingSelectionApply: Set<UUID>?
    private var _hasPendingSelectionApply = false

    /// Freeze main-thread state for the run. Called on main before launch;
    /// the eval task then touches only the snapshots, never live actors.
    func captureMainThreadState(selectedHandles: Set<UUID>, activeCommand: String?) {
        stateLock.withLock {
            _impliedSelection = selectedHandles
            _pendingSelectionApply = nil
            _hasPendingSelectionApply = false
        }
        activeCommandSnapshot = activeCommand
    }

    /// Current pickfirst view for this run (snapshot + in-run updates).
    func impliedHandles() -> Set<UUID> {
        stateLock.withLock { _impliedSelection }
    }

    /// Set pickfirst now (in-run reads see it) and enqueue the real
    /// selection-manager write for the driver's main-thread frame drain.
    func setPickfirst(_ handles: Set<UUID>) {
        stateLock.withLock {
            _impliedSelection = handles
            _pendingSelectionApply = handles
            _hasPendingSelectionApply = true
        }
    }

    /// Take the pending pickfirst write, if any. Called on main each frame.
    func takePendingSelectionApply() -> Set<UUID>? {
        stateLock.withLock {
            guard _hasPendingSelectionApply else { return nil }
            _hasPendingSelectionApply = false
            return _pendingSelectionApply
        }
    }

    init(
        document: CADDocument,
        selection: CADSelectionManager,
        processor: CADCommandProcessor? = nil,
        broker: LispInputBroker = LispInputBroker(),
        vars: LispVarStore = LispVarStore()
    ) {
        self.document = document
        self.selection = selection
        self.processor = processor
        self.broker = broker
        self.vars = vars
    }

    // MARK: - Display

    func write(_ text: String) async {
        output(text)
    }

    func alert(_ text: String) async {
        output("ALERT: \(text)\n")
    }

    // MARK: - Line input

    func requestLine(prompt: String) async throws -> String? {
        setPrompt(prompt, base: nil)
        let event = try await broker.requestCancellable(.line(prompt: prompt))
        guard case let .line(text) = event else { return nil }
        return text
    }

    // MARK: - Geometric input

    func requestPoint(prompt: String, base: [Double]?) async throws -> [Double]? {
        while true {
            setPrompt(prompt, base: base)
            let event = try await broker.requestCancellable(.point(prompt: prompt))
            guard case let .point(answer) = event else { continue }
            guard let coords = answer else { return nil } // Bare Enter.
            if coords.count == 1 {
                await write("Requires a point.\n")
                continue // Bare number: invalid for getpoint, re-prompt.
            }
            return Array(coords.prefix(3))
        }
    }

    func requestPointOrNumber(
        prompt: String, base: [Double]?
    ) async throws -> LispPointInput? {
        while true {
            setPrompt(prompt, base: base)
            let event = try await broker.requestCancellable(.point(prompt: prompt))
            guard case let .point(answer) = event else { continue }
            guard let coords = answer else { return nil }
            if coords.count == 1 { return .number(coords[0]) }
            return .point(Array(coords.prefix(3)))
        }
    }

    func requestEntity(prompt: String) async throws -> (handle: String, point: [Double])? {
        while true {
            setPrompt(prompt, base: nil)
            let event = try await broker.requestCancellable(.entity(prompt: prompt))
            guard case let .entity(handle, point) = event else { continue }
            if let handle {
                if document.entity(forHandleName: handle) != nil {
                    return (handle, point ?? [0, 0, 0])
                }
                await write("That entity no longer exists.\n")
                continue
            }
            if point != nil {
                await write("No entity found there.\n") // Miss: re-prompt.
                continue
            }
            return nil // Bare Enter.
        }
    }

    func readDeviceEvent() async throws -> LispValue {
        setPrompt("", base: nil)
        let event = try await broker.requestCancellable(.device)
        guard case let .device(value) = event else {
            throw LispError.hostError("grread: internal device-event mismatch")
        }
        return value
    }

    func nentselPassive(at point: [Double]?) async throws -> LispValue? {
        _ = point
        // Passive: first pickfirst entity + its center. Nested-block paths
        // do not exist in the flat entity store, so the result is
        // entsel-shaped (ename + pick point).
        guard let handle = impliedHandles().sorted(by: { $0.uuidString < $1.uuidString }).first,
              let entity = document.entity(for: handle)
        else { return nil }
        let center = entityCenter(entity) ?? Vector3(x: 0, y: 0, z: 0)
        return LispEntityAdapter.lispList([
            LispEntityAdapter.entityName(for: handle),
            LispEntityAdapter.pointValue(center),
        ])
    }

    // MARK: - System variables

    func getSystemVar(_ name: String) async -> LispValue? {
        vars.get(name, document: document, activeCommand: activeCommandSnapshot)
    }

    func setSystemVar(_ name: String, _ value: LispValue) async {
        // setvar validates existence first; a rejection message here would
        // have nowhere to go, so rejections are programmer errors. The
        // driver-facing validation lives in LispVarStore.set.
        if name == "LASTPOINT" || vars.get(name, document: document, activeCommand: activeCommandSnapshot) != nil {
            _ = vars.set(name, value, document: document)
        }
    }

    /// Throwing setvar used by tests and the driver (protocol method above
    /// cannot throw, so validation surfaces here).
    func setSystemVarChecked(_ name: String, _ value: LispValue) throws {
        if vars.get(name, document: document, activeCommand: activeCommandSnapshot) == nil, name != "LASTPOINT" {
            throw LispError.hostError("unknown system variable: \(name)")
        }
        if let message = vars.set(name, value, document: document) {
            throw LispError.hostError(message)
        }
    }

    // MARK: - Commands

    func runCommand(_ args: [LispValue]) async throws -> LispValue {
        try await LispScriptedCommands.run(args: args, host: self, isCommandS: false)
    }

    func runCommandS(_ args: [LispValue]) async throws -> LispValue {
        try await LispScriptedCommands.run(args: args, host: self, isCommandS: true)
    }

    // MARK: - Entity store

    private func entity(forEname name: String, operation: String) throws -> CADEntity {
        guard let uuid = LispEntityAdapter.handle(fromEname: name),
              let entity = document.entity(for: uuid)
        else {
            throw LispError.hostError("\(operation): invalid entity name")
        }
        return entity
    }

    func entGet(_ handle: String) async throws -> LispValue {
        let entity = try entity(forEname: handle, operation: "entget")
        return LispEntityAdapter.entGetAssoc(entity: entity, document: document)
    }

    func entMod(_ dxfList: LispValue) async throws -> LispValue {
        let assoc = try LispEntityAdapter.parseAssoc(dxfList, name: "entmod")
        guard case let .entityName(handle) = assoc.first(-1),
              let uuid = LispEntityAdapter.handle(fromEname: handle),
              document.entity(for: uuid) != nil
        else {
            throw LispError.hostError("entmod: missing or invalid (-1 . entity) group")
        }
        let replacement = try LispEntityAdapter.makeEntity(
            from: assoc, document: document, name: "entmod", keepHandle: uuid)
        document.replaceEntity(replacement)
        return dxfList
    }

    func entMake(_ dxfList: LispValue) async throws -> LispValue {
        let assoc = try LispEntityAdapter.parseAssoc(dxfList, name: "entmake")
        let entity = try LispEntityAdapter.makeEntity(from: assoc, document: document, name: "entmake")
        document.addEntity(entity)
        lastCreated = entity.handle
        return LispEntityAdapter.entityName(for: entity.handle)
    }

    func entMakeX(_ dxfList: LispValue) async throws -> LispValue {
        // Accepted approximation: entmakex creates database-resident
        // entities like entmake (non-database entities are not modeled).
        try await entMake(dxfList)
    }

    func entDel(_ handle: String) async throws -> LispValue {
        guard let uuid = LispEntityAdapter.handle(fromEname: handle) else {
            throw LispError.hostError("entdel: invalid entity name")
        }
        if document.entity(for: uuid) != nil {
            erased[uuid] = document.entity(for: uuid)
            document.removeEntity(handle: uuid)
            return .nilValue
        }
        if let stashed = erased.removeValue(forKey: uuid) {
            document.addEntity(stashed)
            lastCreated = uuid
            return .nilValue
        }
        throw LispError.hostError("entdel: invalid entity name")
    }

    func entLast() async throws -> LispValue {
        if let last = lastCreated, document.entity(for: last) != nil {
            return LispEntityAdapter.entityName(for: last)
        }
        // Fall back to database order when nothing was created yet.
        if let last = document.allEntities.map(\.handle).sorted(by: { $0.uuidString < $1.uuidString }).last {
            lastCreated = last
            return LispEntityAdapter.entityName(for: last)
        }
        return .nilValue
    }

    func entNext(_ handle: String?) async throws -> LispValue {
        let ordered = document.allEntities.map(\.handle)
            .sorted(by: { $0.uuidString < $1.uuidString })
        guard let handle else {
            guard let first = ordered.first else { return .nilValue }
            return LispEntityAdapter.entityName(for: first)
        }
        guard let uuid = LispEntityAdapter.handle(fromEname: handle),
              let index = ordered.firstIndex(of: uuid),
              index + 1 < ordered.count
        else { return .nilValue }
        return LispEntityAdapter.entityName(for: ordered[index + 1])
    }

    func handEnt(_ handle: String) async throws -> LispValue {
        guard let uuid = LispEntityAdapter.handle(fromEname: handle),
              document.entity(for: uuid) != nil
        else { return .nilValue }
        return LispEntityAdapter.entityName(for: uuid)
    }

    func entUpd(_ handle: String) async throws -> LispValue {
        _ = try entity(forEname: handle, operation: "entupd")
        document.markEdited(regenerate: false)
        return .t
    }

    func vlaBoundingBox(_ handle: String) async throws -> (min: [Double], max: [Double]) {
        let entity = try entity(forEname: handle, operation: "vla-getboundingbox")
        guard let box = entity.worldBoundingBox else {
            throw LispError.hostError("vla-getboundingbox: entity has no bounding box")
        }
        return (
            min: [box.min.x, box.min.y, box.min.z],
            max: [box.max.x, box.max.y, box.max.z])
    }

    // MARK: - Symbol tables

    /// tblnext iteration cursors by table name.
    private var tableCursors: [String: Int] = [:]

    /// Tables served from the drawing (APPID is session-local in the env).
    private static let servedTables: Set<String> = ["LAYER", "LTYPE", "STYLE", "BLOCK"]

    private func tableEntries(_ table: String) throws -> [(name: String, list: LispValue)] {
        switch table {
        case "LAYER":
            return document.allLayers
                .sorted { $0.name.uppercased() < $1.name.uppercased() }
                .map { ($0.name, layerEntry($0)) }
        case "LTYPE":
            var names = Set(document.allLayers.map { $0.lineType.uppercased() })
            names.insert("CONTINUOUS")
            return names.sorted().map { ($0, ltypeEntry($0)) }
        case "STYLE":
            return document.textStyles.values
                .sorted { $0.name.uppercased() < $1.name.uppercased() }
                .map { ($0.name, styleEntry($0)) }
        case "BLOCK":
            return document.allBlocks
                .sorted { $0.name.uppercased() < $1.name.uppercased() }
                .map { ($0.name, blockEntry($0)) }
        default:
            throw LispError.hostError("unknown table \"\(table)\"")
        }
    }

    private func layerEntry(_ layer: Layer) -> LispValue {
        // Group 62 is negative when the layer is off (AutoCAD convention).
        var aci = Int(DXFColorTable.rgbaToACI(layer.color))
        if aci == 0 { aci = 7 }
        if !layer.isVisible { aci = -aci }
        return LispEntityAdapter.lispList([
            LispEntityAdapter.dotted(.int(0), .string("LAYER")),
            LispEntityAdapter.dotted(.int(2), .string(layer.name)),
            LispEntityAdapter.dotted(.int(70), .int(0)),
            LispEntityAdapter.dotted(.int(62), .int(aci)),
            LispEntityAdapter.dotted(.int(6), .string(layer.lineType)),
            LispEntityAdapter.dotted(.int(370), .int(Int(layer.lineWeight * 100))),
        ])
    }

    private func ltypeEntry(_ name: String) -> LispValue {
        LispEntityAdapter.lispList([
            LispEntityAdapter.dotted(.int(0), .string("LTYPE")),
            LispEntityAdapter.dotted(.int(2), .string(name)),
            LispEntityAdapter.dotted(.int(70), .int(0)),
            LispEntityAdapter.dotted(.int(3), .string(name == "CONTINUOUS" ? "Solid line" : "")),
            LispEntityAdapter.dotted(.int(72), .int(65)),
            LispEntityAdapter.dotted(.int(73), .int(0)),
            LispEntityAdapter.dotted(.int(40), .real(0)),
        ])
    }

    private func styleEntry(_ style: CADTextStyle) -> LispValue {
        LispEntityAdapter.lispList([
            LispEntityAdapter.dotted(.int(0), .string("STYLE")),
            LispEntityAdapter.dotted(.int(2), .string(style.name)),
            LispEntityAdapter.dotted(.int(70), .int(0)),
            LispEntityAdapter.dotted(.int(40), .real(style.fixedHeight)),
            LispEntityAdapter.dotted(.int(41), .real(style.widthFactor)),
            LispEntityAdapter.dotted(.int(50), .real(style.obliqueAngle)),
            LispEntityAdapter.dotted(.int(71), .int(0)),
            LispEntityAdapter.dotted(.int(42), .real(1)),
            LispEntityAdapter.dotted(.int(3), .string(style.fontFile)),
            LispEntityAdapter.dotted(.int(4), .string("")),
        ])
    }

    private func blockEntry(_ block: CADBlock) -> LispValue {
        var groups: [LispValue] = [
            LispEntityAdapter.dotted(.int(0), .string("BLOCK")),
            LispEntityAdapter.dotted(.int(2), .string(block.name)),
            LispEntityAdapter.dotted(.int(70), .int(block.effectiveDXFFlags)),
            // Blocks carry no base point in this model: origin.
            LispEntityAdapter.dotted(
                .int(10),
                LispEntityAdapter.pointValue(Vector3(x: 0, y: 0, z: 0))),
        ]
        if let descriptor = block.xrefDescriptor {
            groups.append(LispEntityAdapter.dotted(.int(1), .string(descriptor.savedPath)))
        }
        return LispEntityAdapter.lispList(groups)
    }

    func tableNext(_ table: String, rewind: Bool) async throws -> LispValue? {
        let upper = table.uppercased()
        guard Self.servedTables.contains(upper) else {
            throw LispError.hostError("unknown table \"\(table)\"")
        }
        let entries = try tableEntries(upper)
        var cursor = tableCursors[upper] ?? 0
        if rewind { cursor = 0 }
        guard cursor < entries.count else {
            tableCursors[upper] = 0
            return nil
        }
        tableCursors[upper] = cursor + 1
        return entries[cursor].list
    }

    func tableSearch(_ table: String, name: String, setNext: Bool) async throws -> LispValue? {
        let upper = table.uppercased()
        guard Self.servedTables.contains(upper) else {
            throw LispError.hostError("unknown table \"\(table)\"")
        }
        let entries = try tableEntries(upper)
        guard let index = entries.firstIndex(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) else {
            return nil
        }
        if setNext {
            tableCursors[upper] = index + 1
        }
        return entries[index].list
    }

    func layoutNames() async -> [String] {
        ["Model"] // Single-space model: no paper-space layouts exist.
    }

    func ssNameX(_ set: Int, index: Int) async throws -> LispValue {
        // Degenerate shape ((ename)): no subentity or pick-point data
        // exists in the flat entity store.
        let named = try await ssName(set, index: index)
        guard case .entityName = named else { return .nilValue }
        return LispEntityAdapter.lispList([LispEntityAdapter.lispList([named])])
    }

    func beginUndoMark() async {
        document.undoManager.beginUndoGroup()
    }

    func endUndoMark() async {
        _ = document.undoManager.endUndoGroup()
    }

    // MARK: - Step 4d: osnap + layers

    /// Object snap over discrete anchor points with broad-phase AABB
    /// rejection, mirroring SnapEngine tiers 1-2. Kind filter: END =
    /// vertex, MID = midpoint, CEN = center, QUA = quadrant, INS =
    /// insertion point; NEA accepts the nearest anchor of any kind
    /// (engine-computed on-curve points are out of scope: the script
    /// path has no tessellation context). Threshold matches the
    /// SnapEngine default (12 world units).
    func osnap(point: [Double], modes: [String]) async -> [Double]? {
        guard point.count >= 2 else { return nil }
        let threshold = 12.0
        let cursorX = point[0]
        let cursorY = point[1]
        let acceptAny = modes.contains("NEA")
        var best: (x: Double, y: Double, z: Double)?
        var bestDist = threshold
        for entity in document.allEntities {
            if let box = entity.worldBoundingBox {
                let minX = min(box.min.x, box.max.x) - threshold
                let maxX = max(box.min.x, box.max.x) + threshold
                let minY = min(box.min.y, box.max.y) - threshold
                let maxY = max(box.min.y, box.max.y) + threshold
                guard cursorX >= minX, cursorX <= maxX,
                      cursorY >= minY, cursorY <= maxY else {
                    continue
                }
            }
            for anchor in entity.anchorPoints {
                if !acceptAny, !Self.osnapAnchorMatches(anchor, modes: modes) {
                    continue
                }
                let world = anchor.worldPosition(transform: entity.transform)
                let dx = world.x - cursorX
                let dy = world.y - cursorY
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist < bestDist {
                    bestDist = dist
                    best = (world.x, world.y, world.z)
                }
            }
        }
        guard let best else { return nil }
        return [best.x, best.y, best.z]
    }

    private static func osnapAnchorMatches(_ anchor: AnchorPoint, modes: [String]) -> Bool {
        switch anchor {
        case .vertex:
            return modes.contains("END")
        case .midpoint:
            return modes.contains("MID")
        case .center:
            return modes.contains("CEN")
        case .quadrant:
            return modes.contains("QUA")
        case .insertionPoint:
            return modes.contains("INS")
        case .nearest:
            return modes.contains("NEA")
        case .intersection:
            return modes.contains("INT")
        }
    }

    func layerNames() async -> [String] {
        document.allLayers.map(\.name)
    }

    func layerIsOn(_ name: String) async -> Bool? {
        document.allLayers.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.isVisible
    }

    func setLayerIsOn(_ name: String, on: Bool) async -> Bool {
        guard let layer = document.allLayers.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            return false
        }
        document.setLayerVisible(layer.handle, visible: on)
        return true
    }

    func xdataRoom(_ handle: String) async throws -> Int {
        guard let uuid = LispEntityAdapter.handle(fromEname: handle),
              let entity = document.entity(for: uuid)
        else {
            throw LispError.hostError("xdroom: invalid entity name")
        }
        var used = 0
        for (appid, value) in entity.xdata {
            used += 8 + appid.utf8.count + 1 // 1001 group + app name.
            switch value {
            case let .string(s): used += 8 + s.utf8.count + 1
            case .double, .int: used += 16
            case .bool: used += 9
            case .date: used += 16
            }
        }
        return max(0, EnvBuiltins.xdataBudget - used)
    }

    // MARK: - Selection sets

    /// All entities, filtered. Returns nil when nothing matches (AutoCAD
    /// (ssget "_X") returns nil on empty).
    func ssGet(filter: LispValue?) async throws -> Int? {
        let predicate = try makeFilter(filter)
        let matches = document.allEntities
            .filter { predicate($0) }
            .map(\.handle)
            .sorted(by: { $0.uuidString < $1.uuidString })
        guard !matches.isEmpty else { return nil }
        return storeSelection(matches)
    }

    func ssGetInteractive(mode: String, points: [[Double]], filter: LispValue?) async throws -> Int? {
        let predicate = try makeFilter(filter)
        switch mode.uppercased() {
        case "PICK":
            return try await pickSelection(filter: predicate)
        case "P", "_P": // Previous selection.
            let matches = previousSelection.filter { document.entity(for: $0) != nil }
                .filter { predicate(document.entity(for: $0)!) }
            guard !matches.isEmpty else { return nil }
            return storeSelection(matches.sorted(by: { $0.uuidString < $1.uuidString }))
        case "L", "_L": // Last created entity.
            guard let last = lastCreated,
                  let entity = document.entity(for: last),
                  predicate(entity)
            else { return nil }
            return storeSelection([last])
        case "I", "_I": // Implied (pickfirst) selection.
            let matches = impliedHandles()
                .filter { document.entity(for: $0) != nil }
                .filter { predicate(document.entity(for: $0)!) }
            guard !matches.isEmpty else { return nil }
            return storeSelection(matches.sorted(by: { $0.uuidString < $1.uuidString }))
        case "C", "_C", "W", "_W":
            guard points.count >= 2 else {
                throw LispError.hostError("ssget \(mode): needs two corner points")
            }
            let style: CADSelectionManager.RectSelectStyle =
                mode.uppercased().hasSuffix("W") ? .window : .crossing
            let matches = handlesInRectPoints(points[0], points[1], style: style)
                .filter { predicate(document.entity(for: $0)!) }
            guard !matches.isEmpty else { return nil }
            return storeSelection(matches.sorted(by: { $0.uuidString < $1.uuidString }))
        case "F", "_F": // Fence: bbox intersects any segment.
            guard points.count >= 2 else {
                throw LispError.hostError("ssget \(mode): needs at least two points")
            }
            let matches = document.allEntities.filter { entity in
                guard predicate(entity), let box = entity.worldBoundingBox else { return false }
                for index in 0..<(points.count - 1) {
                    if segmentIntersectsBox(points[index], points[index + 1], box) {
                        return true
                    }
                }
                return false
            }.map(\.handle)
            guard !matches.isEmpty else { return nil }
            return storeSelection(matches.sorted(by: { $0.uuidString < $1.uuidString }))
        case "CP", "_CP", "WP", "_WP": // Crossing/window polygon.
            guard points.count >= 2 else {
                throw LispError.hostError("ssget \(mode): needs at least two points")
            }
            let crossing = mode.uppercased().hasPrefix("C")
            let matches = document.allEntities.filter { entity in
                guard predicate(entity), let box = entity.worldBoundingBox else { return false }
                return crossing
                    ? polygonCrossesBox(points, box)
                    : polygonContainsBox(points, box)
            }.map(\.handle)
            guard !matches.isEmpty else { return nil }
            return storeSelection(matches.sorted(by: { $0.uuidString < $1.uuidString }))
        default:
            throw LispError.hostError("ssget: unsupported selection mode \"\(mode)\"")
        }
    }

    /// Interactive pick loop: entities until bare Enter. Empty result is nil;
    /// Esc throws userCancel.
    private func pickSelection(filter predicate: @escaping (CADEntity) -> Bool) async throws -> Int? {
        var picked: [UUID] = []
        while true {
            setPrompt("Select objects:", base: nil)
            let event = try await broker.requestCancellable(.entity(prompt: "Select objects:"))
            guard case let .entity(handle, point) = event else { continue }
            if let handle, let uuid = LispEntityAdapter.handle(fromEname: handle) {
                if let entity = document.entity(for: uuid), predicate(entity),
                   !picked.contains(uuid)
                {
                    picked.append(uuid)
                }
                continue
            }
            if point != nil { continue } // Miss: keep picking.
            break // Bare Enter: finish.
        }
        guard !picked.isEmpty else { return nil }
        previousSelection = Set(picked)
        return storeSelection(picked)
    }

    func ssAdd(_ handle: String?, set: Int?) async throws -> Int {
        if let set, selectionSets[set] == nil {
            throw LispError.hostError("ssadd: invalid selection set")
        }
        let id = set ?? storeSelection([])
        guard let handle else { return id }
        guard let uuid = LispEntityAdapter.handle(fromEname: handle),
              document.entity(for: uuid) != nil
        else {
            throw LispError.hostError("ssadd: invalid entity name")
        }
        if !(selectionSets[id]?.contains(uuid) ?? false) {
            selectionSets[id]?.append(uuid)
        }
        return id
    }

    func ssDel(_ handle: String, set: Int) async throws -> LispValue {
        guard var members = selectionSets[set] else {
            throw LispError.hostError("ssdel: invalid selection set")
        }
        guard let uuid = LispEntityAdapter.handle(fromEname: handle),
              let index = members.firstIndex(of: uuid)
        else {
            throw LispError.hostError("ssdel: entity is not in the set")
        }
        members.remove(at: index)
        selectionSets[set] = members
        return .selectionSet(set)
    }

    func ssLength(_ set: Int) async throws -> Int {
        guard let members = selectionSets[set] else {
            throw LispError.hostError("sslength: invalid selection set")
        }
        // Drop deleted entities lazily (AutoCAD sets hold dying enames
        // until referenced; length counts live members).
        let live = members.filter { document.entity(for: $0) != nil }
        selectionSets[set] = live
        return live.count
    }

    func ssName(_ set: Int, index: Int) async throws -> LispValue {
        guard let members = selectionSets[set] else {
            throw LispError.hostError("ssname: invalid selection set")
        }
        let live = members.filter { document.entity(for: $0) != nil }
        selectionSets[set] = live
        guard index >= 0, index < live.count else { return .nilValue }
        return LispEntityAdapter.entityName(for: live[index])
    }

    func ssMemb(_ handle: String, set: Int) async throws -> LispValue {
        guard let members = selectionSets[set] else {
            throw LispError.hostError("ssmemb: invalid selection set")
        }
        guard let uuid = LispEntityAdapter.handle(fromEname: handle),
              members.contains(uuid),
              document.entity(for: uuid) != nil
        else { return .nilValue }
        return LispEntityAdapter.entityName(for: uuid)
    }

    func ssGetFirst() async throws -> LispValue {
        let live = impliedHandles()
            .filter { document.entity(for: $0) != nil }
            .sorted(by: { $0.uuidString < $1.uuidString })
        guard !live.isEmpty else { return .nilValue }
        // Grip and pick sets are identical here (no grip distinction).
        let id = storeSelection(live)
        return LispEntityAdapter.lispList([.selectionSet(id), .selectionSet(id)])
    }

    func ssSetFirst(_ set: Int?) async throws -> LispValue {
        guard let set else {
            setPickfirst([])
            return .nilValue
        }
        guard let members = selectionSets[set] else {
            throw LispError.hostError("sssetfirst: invalid selection set")
        }
        setPickfirst(Set(members.filter { document.entity(for: $0) != nil }))
        return .nilValue
    }

    // MARK: - Filter

    /// Compiles an ssget DXF filter (nil = match all). Supports type (0),
    /// layer (8), color (62), handle (5), and -4 group operators
    /// (<AND, OR, NOT, <NOT...NOT>). Anything else fails closed.
    func makeFilter(_ filter: LispValue?) throws -> (CADEntity) -> Bool {
        guard let filter else { return { _ in true } }
        guard let items = filter.properList else {
            throw LispError.typeMismatch(
                name: "ssget", expected: "filter list", got: filter)
        }
        var parsed: [(Int, LispValue)] = []
        for item in items {
            guard case let .cons(head, tail) = item,
                  case let .int(code) = head
            else {
                throw LispError.typeMismatch(
                    name: "ssget", expected: "dotted filter pair", got: item)
            }
            parsed.append((code, tail))
        }
        let tests = try parsed.map { try filterTest(code: $0.0, value: $0.1) }
        // Implicit AND across top-level tests; explicit -4 groups nest.
        return { [document] entity in tests.allSatisfy { $0(entity, document) } }
    }

    private func filterTest(
        code: Int, value: LispValue
    ) throws -> (CADEntity, CADDocument) -> Bool {
        switch code {
        case 0:
            guard case let .string(type) = value else {
                throw LispError.hostError("ssget: (0 . type) filter needs a string")
            }
            let wanted = type.uppercased()
            return { entity, document in
                LispEntityAdapter.dxfTypeName(entity: entity, document: document)
                    .uppercased() == wanted
            }
        case 8:
            guard case let .string(layer) = value else {
                throw LispError.hostError("ssget: (8 . layer) filter needs a string")
            }
            return { entity, document in
                LispEntityAdapter.layerName(entity: entity, document: document) == layer
            }
        case 62:
            guard let aci = value.asDouble else {
                throw LispError.hostError("ssget: (62 . color) filter needs a number")
            }
            return { entity, _ in LispEntityAdapter.entityACI(entity: entity) == Int(aci) }
        case 5:
            guard case let .string(handle) = value else {
                throw LispError.hostError("ssget: (5 . handle) filter needs a string")
            }
            return { entity, _ in entity.handle.uuidString == handle }
        case -4:
            guard case let .string(op) = value else {
                throw LispError.hostError("ssget: (-4 . operator) filter needs a string")
            }
            throw LispError.hostError(
                "ssget: (-4 . \"\(op)\") groups are not supported from Lisp yet")
        default:
            throw LispError.hostError(
                "ssget: filter group \(code) is not supported from Lisp yet")
        }
    }

    // MARK: - Dispatcher services

    func selectionHandles(id: Int) -> Set<UUID> {
        Set(selectionSets[id] ?? [])
    }

    func handlesInRect(
        _ a: Vector3, _ b: Vector3, style: CADSelectionManager.RectSelectStyle
    ) -> Set<UUID> {
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        return CADRectSelect.handlesInRect(
            worldX: minX, worldY: minY,
            worldW: max(a.x, b.x) - minX, worldH: max(a.y, b.y) - minY,
            document: document, style: style)
    }

    func undoOnce() {
        document.undo()
    }

    func undoTimes(_ count: Int) {
        for _ in 0..<max(0, count) { document.undo() }
    }

    func undoBack() {
        guard let mark = undoMark else { return }
        let current = document.snapshot()
        if let restored = document.undoManager.backToUndoMark(mark, currentSnapshot: current) {
            document.restore(from: restored)
        }
    }

    // MARK: - Private helpers

    private func storeSelection(_ members: [UUID]) -> Int {
        let id = nextSelectionID
        nextSelectionID += 1
        selectionSets[id] = members
        return id
    }

    private func entityCenter(_ entity: CADEntity) -> Vector3? {
        guard let box = entity.worldBoundingBox else { return nil }
        return Vector3(
            x: (box.min.x + box.max.x) / 2,
            y: (box.min.y + box.max.y) / 2,
            z: (box.min.z + box.max.z) / 2)
    }

    private func handlesInRectPoints(
        _ a: [Double], _ b: [Double], style: CADSelectionManager.RectSelectStyle
    ) -> Set<UUID> {
        handlesInRect(
            Vector3(x: a[0], y: a[1], z: 0),
            Vector3(x: b[0], y: b[1], z: 0),
            style: style)
    }

    /// Segment vs world bbox (2D slab test).
    private func segmentIntersectsBox(
        _ p: [Double], _ q: [Double], _ box: BoundingBox3D
    ) -> Bool {
        let x1 = min(p[0], q[0]), x2 = max(p[0], q[0])
        let y1 = min(p[1], q[1]), y2 = max(p[1], q[1])
        // Fast reject on bbox overlap of segment bounds vs box.
        if x2 < box.min.x || x1 > box.max.x || y2 < box.min.y || y1 > box.max.y {
            return false
        }
        // Endpoint inside → intersect.
        if pointInBox(p, box) || pointInBox(q, box) { return true }
        // Otherwise test against the four box edges.
        let corners = [
            (box.min.x, box.min.y), (box.max.x, box.min.y),
            (box.max.x, box.max.y), (box.min.x, box.max.y),
        ]
        for index in 0..<4 {
            let a = corners[index], b = corners[(index + 1) % 4]
            if segmentsCross(p[0], p[1], q[0], q[1], a.0, a.1, b.0, b.1) {
                return true
            }
        }
        return false
    }

    private func pointInBox(_ p: [Double], _ box: BoundingBox3D) -> Bool {
        p[0] >= box.min.x && p[0] <= box.max.x
            && p[1] >= box.min.y && p[1] <= box.max.y
    }

    private func segmentsCross(
        _ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double,
        _ p3x: Double, _ p3y: Double, _ p4x: Double, _ p4y: Double
    ) -> Bool {
        let d = (p2x - p1x) * (p4y - p3y) - (p2y - p1y) * (p4x - p3x)
        guard abs(d) > 1e-12 else { return false }
        let t = ((p3x - p1x) * (p4y - p3y) - (p3y - p1y) * (p4x - p3x)) / d
        let u = ((p3x - p1x) * (p2y - p1y) - (p3y - p1y) * (p2x - p1x)) / d
        return t >= 0 && t <= 1 && u >= 0 && u <= 1
    }

    /// Crossing polygon: any box corner inside, or any polygon edge
    /// crossing any box edge.
    private func polygonCrossesBox(_ polygon: [[Double]], _ box: BoundingBox3D) -> Bool {
        let corners = [
            [box.min.x, box.min.y], [box.max.x, box.min.y],
            [box.max.x, box.max.y], [box.min.x, box.max.y],
        ]
        if corners.contains(where: { pointInPolygon($0, polygon) }) { return true }
        if polygon.contains(where: { pointInBox($0, box) }) { return true }
        for index in 0..<polygon.count {
            let p = polygon[index], q = polygon[(index + 1) % polygon.count]
            if segmentIntersectsBox(p, q, box) { return true }
        }
        return false
    }

    /// Window polygon: all four box corners inside.
    private func polygonContainsBox(_ polygon: [[Double]], _ box: BoundingBox3D) -> Bool {
        [
            [box.min.x, box.min.y], [box.max.x, box.min.y],
            [box.max.x, box.max.y], [box.min.x, box.max.y],
        ].allSatisfy { pointInPolygon($0, polygon) }
    }

    private func pointInPolygon(_ point: [Double], _ polygon: [[Double]]) -> Bool {
        var inside = false
        var index = 0, next = polygon.count - 1
        while index < polygon.count {
            let xi = polygon[index][0], yi = polygon[index][1]
            let xj = polygon[next][0], yj = polygon[next][1]
            if (yi > point[1]) != (yj > point[1]),
               point[0] < (xj - xi) * (point[1] - yi) / (yj - yi) + xi
            {
                inside.toggle()
            }
            next = index
            index += 1
        }
        return inside
    }
}

// MARK: - Handle lookup helper

extension CADDocument {
    /// Entity for a Lisp ename/handle string (UUID text), or nil.
    func entity(forHandleName name: String) -> CADEntity? {
        guard let uuid = UUID(uuidString: name) else { return nil }
        return entity(for: uuid)
    }
}

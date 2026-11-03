import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Scripted Command Dispatcher ((command ...) / (command-s ...))
// =========================================================================
//
// `(command ...)` NEVER routes through the interactive `executeCommand`
// (see LispInvocationContext.swift). Instead this dispatcher implements an
// audited subset of commands directly against the document, selection, and
// variable store. Every command here:
//
// * consumes only already-evaluated arguments (points, strings, numbers,
//   entity names, selection sets) and never requests input;
// * performs exactly ONE undo push per call (single-mutator rule), so one
//   scripted call is one undo entry, matching AutoCAD;
// * fails closed on anything outside its audited surface, naming the
//   offending command, keyword, or token.
//
// Token conventions (AutoCAD-compatible):
// * `_.NAME` / `_NAME` prefixes are stripped (global command/keyword form).
// * `""` terminates the current argument sequence (Enter).
// * Osnap overrides (`_non`, `_end`, ...) are skipped: scripted geometry
//   uses exact coordinates, so overrides are vacuous.
// * `PAUSE` (user input spliced into the sequence) is rejected: nothing in
//   the Lisp path may block for input outside the broker.
// * `'`-prefixed transparent commands are rejected (interactive-only).
// * `_L` = most recently created entity, `_P` = previous selection set.

// UNISOLATED by design (see LispCADHost): runs on the eval task, which
// cannot hop to MainActor under the unpumped SDL loop.
enum LispScriptedCommands {

    /// Audited scripted set. Everything else is `.interactiveReject`.
    /// This table is pinned by LispReentrancyTests' approved-list test:
    /// add a name here only with its implementation + test below.
    static let scripted: Set<String> = [
        "LINE", "CIRCLE", "PLINE", "ARC",
        "COPY", "ROTATE", "MOVE", "ERASE", "SELECT",
        "-LAYER", "-LA", "LAYERSTATE", "-LAYERSTATE", "LAYERP",
        "UNDO", "U", "REDRAW", "REGEN", "INSERT", "-INSERT", "-ATTACH",
        "RECTANG", "RECTANGLE", "CHPROP", "CHANGE", "-HATCH", "HATCH", "TEXT", "-TEXT", "DTEXT", "AUTOCONTRAST",
    ]

    static func disposition(for name: String) -> LispCommandDisposition {
        scripted.contains(canonicalName(name)) ? .scripted : .interactiveReject
    }

    /// Strips `_.`/`_` prefixes and uppercases. Returns nil for transparent
    /// (`'...`) invocations, which are always interactive.
    static func canonicalName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if name.hasPrefix("'") { return name } // Transparent: never scripted.
        if name.hasPrefix("_.") { name = String(name.dropFirst(2)) }
        else if name.hasPrefix("_") { name = String(name.dropFirst(1)) }
        return name
    }

    /// Known osnap-override keywords (skipped as vacuous in scripted calls).
    static let snapOverrides: Set<String> = [
        "NON", "END", "MID", "CEN", "INT", "APP", "EXT", "INS", "PER",
        "TAN", "QUA", "PAR", "NOD", "NEA", "GCE",
    ]

    // MARK: - Entry

    private static func isTerminatingToken(_ value: LispValue) -> Bool {
        switch value {
        case .string(let s):
            let c = canonicalName(s)
            return c == "" || c == "C" || c == "CLOSE"
        case .symbol(let s):
            let u = s.uppercased()
            return u == "C" || u == "CLOSE"
        default:
            return false
        }
    }

    private static func isIncompleteCommand(_ args: [LispValue]) -> Bool {
        guard let first = args.first, case let .string(rawName) = first else { return false }
        let name = canonicalName(rawName)
        guard name == "PLINE" || name == "LINE" else { return false }
        guard let last = args.dropFirst().last else { return true }
        return !isTerminatingToken(last)
    }

    private static func isCommandComplete(_ args: [LispValue]) -> Bool {
        guard let first = args.first, case let .string(rawName) = first else { return true }
        let name = canonicalName(rawName)
        if name == "PLINE" || name == "LINE" {
            guard let last = args.dropFirst().last else { return false }
            return isTerminatingToken(last)
        }
        return true
    }

    static func run(
        args: [LispValue], host: LispCADHost, isCommandS: Bool = false
    ) async throws -> LispValue {
        for token in args {
            let isPause: Bool = switch token {
            case let .string(s): canonicalName(s) == "PAUSE"
            case let .symbol(s): s.uppercased() == "PAUSE"
            default: false
            }
            if isPause {
                throw LispError.hostError(
                    "command: PAUSE (interactive input) is not supported from Lisp")
            }
        }

        if isCommandS {
            return try await executeSingle(args: args, host: host)
        }

        if !host.pendingCommandArgs.isEmpty {
            if let first = args.first, case let .string(raw) = first,
               scripted.contains(canonicalName(raw)) {
                let prev = host.pendingCommandArgs
                host.pendingCommandArgs = []
                _ = try? await executeSingle(args: prev + [.string("")], host: host)
            } else if args.isEmpty {
                host.pendingCommandArgs.append(.string(""))
                if isCommandComplete(host.pendingCommandArgs) {
                    let full = host.pendingCommandArgs
                    host.pendingCommandArgs = []
                    return try await executeSingle(args: full, host: host)
                }
                return .nilValue
            } else {
                host.pendingCommandArgs.append(contentsOf: args)
                if isCommandComplete(host.pendingCommandArgs) {
                    let full = host.pendingCommandArgs
                    host.pendingCommandArgs = []
                    return try await executeSingle(args: full, host: host)
                }
                return .nilValue
            }
        }

        if args.isEmpty { return .nilValue } // (command) alone: no-op.

        if isIncompleteCommand(args) {
            host.pendingCommandArgs = args
            return .nilValue
        }

        return try await executeSingle(args: args, host: host)
    }

    private static func executeSingle(args: [LispValue], host: LispCADHost) async throws -> LispValue {
        guard let first = args.first else { return .nilValue }
        guard case let .string(rawName) = first else {
            throw LispError.typeMismatch(
                name: "command", expected: "command name string", got: first)
        }
        if rawName.trimmingCharacters(in: .whitespaces).hasPrefix("'") {
            throw LispError.hostError(
                "command: transparent invocation '\(rawName)' is not supported from Lisp")
        }
        let name = canonicalName(rawName)
        var operands = Array(args.dropFirst())
        switch name {
        case "LINE": try await runLine(&operands, host: host)
        case "CIRCLE": try await runCircle(&operands, host: host)
        case "PLINE": try await runPline(&operands, host: host)
        case "ARC": try await runArc(&operands, host: host)
        case "RECTANG", "RECTANGLE": try await runRectang(&operands, host: host)
        case "CHPROP", "CHANGE": try runChprop(&operands, host: host)
        case "-HATCH", "HATCH": try await runHatch(&operands, host: host)
        case "TEXT", "-TEXT", "DTEXT": try await runText(&operands, host: host)
        case "AUTOCONTRAST": runAutoContrast(&operands, host: host)
        case "COPY": try await runCopy(&operands, host: host)
        case "ROTATE": try runRotate(&operands, host: host)
        case "MOVE": try runMove(&operands, host: host)
        case "ERASE": try runErase(&operands, host: host)
        case "SELECT": try runSelect(&operands, host: host)
        case "INSERT", "-INSERT": try await runInsert(&operands, host: host)
        case "-ATTACH": try runAttach(&operands, host: host)
        case "UNDO": try await runUndo(&operands, host: host)
        case "U": host.undoOnce()
        case "-LAYER", "-LA": try runDashLayer(&operands, host: host)
        case "LAYERSTATE", "-LAYERSTATE": try runLayerStateScripted(&operands, host: host)
        case "LAYERP": runLayerPreviousScripted(host: host)
        case "REDRAW": host.document.markEdited(regenerate: false)
        case "REGEN": host.document.markEdited(regenerate: true)
        default:
            throw LispError.hostError(
                "command: \"\(rawName)\" is not supported from Lisp " +
                    "(interactive-only or not yet audited)")
        }
        return .nilValue
    }

    // MARK: - Operand cursor

    /// Consumes and returns the next string keyword (uppercased,
    /// prefix-stripped), or nil when the next operand is not a string.
    /// `""` (Enter) is consumed and reported as `.enter`.
    ///
    /// When `skippingSnaps`, osnap overrides (`_non`, `_end`, ...) are
    /// consumed and skipped as vacuous — valid only in point/selection
    /// positions. Pass false where a real keyword collides with a snap
    /// name: UNDO's END would otherwise be eaten as the ENDpoint override.
    enum Keyword { case enter, word(String) }

    static func takeKeyword(
        _ operands: inout [LispValue], skippingSnaps: Bool = true
    ) -> Keyword? {
        while let first = operands.first {
            guard case let .string(raw) = first else { return nil }
            operands.removeFirst()
            if raw == "" { return .enter }
            let word = canonicalName(raw)
            if skippingSnaps, snapOverrides.contains(word) { continue }
            return .word(word)
        }
        return nil
    }

    /// Skips vacuous osnap overrides (`_non`, ...) preceding a value.
    static func skipSnaps(_ operands: inout [LispValue]) {
        while let first = operands.first,
              case let .string(raw) = first,
              snapOverrides.contains(canonicalName(raw))
        {
            operands.removeFirst()
        }
    }

    /// Consumes the next point operand (2-3 numbers). Throws on mismatch.
    /// Throws on a keyword where a point is required, naming it.
    static func takePoint(
        _ operands: inout [LispValue], command: String, what: String
    ) throws -> Vector3 {
        skipSnaps(&operands)
        guard let first = operands.first else {
            throw LispError.hostError("command: \(command) needs \(what)")
        }
        if case let .string(raw) = first {
            if raw == "" {
                throw LispError.hostError("command: \(command) needs \(what) (got Enter)")
            }
            throw LispError.hostError(
                "command: \(command) needs \(what) (got keyword \"\(raw)\")")
        }
        guard let coords = first.asPoint, coords.count >= 2 else {
            throw LispError.typeMismatch(
                name: "command", expected: "\(command) \(what) (point)", got: first)
        }
        operands.removeFirst()
        return Vector3(
            x: coords[0], y: coords[1],
            z: coords.count > 2 ? coords[2] : 0)
    }

    static func takeNumber(
        _ operands: inout [LispValue], command: String, what: String
    ) throws -> Double {
        skipSnaps(&operands)
        guard let first = operands.first, let value = first.asDouble else {
            throw LispError.hostError("command: \(command) needs \(what)")
        }
        operands.removeFirst()
        return value
    }

    /// Consumes a selection sequence: entity names, selection sets, _L, _P,
    /// W/C windows (each followed by two corner points), ALL — terminated
    /// by `""` (Enter) or end of operands. Records the result as the
    /// previous selection when non-empty.
    static func takeSelection(
        _ operands: inout [LispValue], command: String, host: LispCADHost
    ) throws -> Set<UUID> {
        var out = Set<UUID>()
        var explicitEnd = false
        while let first = operands.first {
            switch first {
            case let .entityName(handle):
                operands.removeFirst()
                if let uuid = UUID(uuidString: handle),
                   host.document.entity(for: uuid) != nil
                {
                    out.insert(uuid)
                }
            case let .selectionSet(id):
                operands.removeFirst()
                out.formUnion(host.selectionHandles(id: id))
            case let .string(raw):
                operands.removeFirst()
                if raw == "" { explicitEnd = true; break }
                switch canonicalName(raw) {
                case "L", "LAST":
                    if let last = host.lastCreated ?? host.document.allEntities.last?.handle { out.insert(last) }
                case "P", "PREVIOUS":
                    out.formUnion(host.previousSelection)
                case "ALL":
                    out.formUnion(host.document.allEntities.map(\.handle))
                case "W", "C":
                    let style: CADSelectionManager.RectSelectStyle =
                        canonicalName(raw) == "W" ? .window : .crossing
                    let a = try takePoint(&operands, command: command, what: "first corner")
                    let b = try takePoint(&operands, command: command, what: "other corner")
                    out.formUnion(host.handlesInRect(a, b, style: style))
                case let word where snapOverrides.contains(word):
                    continue // Vacuous inside selection sequences too.
                default:
                    throw LispError.hostError(
                        "command: \(command) got unexpected selection keyword \"\(raw)\"")
                }
            default:
                throw LispError.typeMismatch(
                    name: "command",
                    expected: "\(command) selection (entity, set, _L, _P, window, or Enter)",
                    got: first)
            }
            if explicitEnd { break }
        }
        if !out.isEmpty { host.previousSelection = out }
        return out
    }

    // MARK: - Draw commands (one addEntities batch = one undo entry)

    private static func activeLayerID(_ host: LispCADHost) throws -> UUID {
        if let id = host.document.activeLayerID { return id }
        if let first = host.document.allLayers.first { return first.handle }
        throw LispError.hostError("command: drawing has no layers")
    }

    private static func currentColor(_ host: LispCADHost) async -> ColorRGBA? {
        guard let value = await host.getSystemVar("CECOLOR") else { return nil }
        switch value {
        case .int(let aci):
            if (1...255).contains(aci) {
                return DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
            }
        case .string(let s), .symbol(let s):
            let canon = canonicalName(s)
            if canon == "BYLAYER" || canon == "BYBLOCK" {
                return nil
            }
            if let aci = Int(s), (1...255).contains(aci) {
                return DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
            }
            if let tc = parseTrueColor(s) {
                return tc
            }
        default:
            break
        }
        return nil // BYLAYER / BYBLOCK.
    }

    private static func addPrimitives(
        _ prims: [CADPrimitive], host: LispCADHost
    ) async throws {
        guard !prims.isEmpty else { return }
        let layerID = try activeLayerID(host)
        var xdata: [String: XDataValue] = [:]
        if case let .string(celtype)? = await host.getSystemVar("CELTYPE") {
            let canon = canonicalName(celtype)
            if canon != "BYLAYER" && !canon.isEmpty {
                xdata["dxf.lineType"] = .string(canon)
            }
        }
        if let celtscale = (await host.getSystemVar("CELTSCALE"))?.asDouble, celtscale > 0, abs(celtscale - 1.0) > 1e-9 {
            xdata["dxf.lineTypeScale"] = .double(celtscale)
        }
        if let celweight = (await host.getSystemVar("CELWEIGHT"))?.asDouble, celweight >= 0 {
            xdata["dxf.lineWeight"] = .double(celweight)
        }
        let entities = prims.map { prim in
            var ent = CADEntity(layerID: layerID, localGeometry: [prim])
            if !xdata.isEmpty {
                ent.xdata = xdata
            }
            return ent
        }
        host.document.addEntities(entities)
        host.lastCreated = entities.last?.handle
    }

    private static func runLine(_ operands: inout [LispValue], host: LispCADHost) async throws {
        var points: [Vector3] = []
        var closed = false
        var done = false
        while !operands.isEmpty, !done {
            if let keyword = takeKeyword(&operands) {
                switch keyword {
                case .enter: done = true
                case .word("C"):
                    closed = points.count > 2
                    // "C" closes AND ends the sequence in AutoCAD.
                    done = true
                case .word(let word):
                    throw LispError.hostError(
                        "command: LINE does not support keyword \"\(word)\"")
                }
                continue
            }
            points.append(try takePoint(&operands, command: "LINE", what: "a point"))
        }
        guard points.count >= 2 else {
            throw LispError.hostError("command: LINE needs at least two points")
        }
        let color = await currentColor(host)
        var prims: [CADPrimitive] = []
        for index in 0..<(points.count - 1) {
            prims.append(.line(start: points[index], end: points[index + 1], color: color))
        }
        if closed, let first = points.first, let last = points.last {
            prims.append(.line(start: last, end: first, color: color))
        }
        try await addPrimitives(prims, host: host)
    }

    private static func runCircle(_ operands: inout [LispValue], host: LispCADHost) async throws {
        var center: Vector3?
        var radius: Double?
        if let keyword = takeKeyword(&operands) {
            switch keyword {
            case .word("2P"):
                let a = try takePoint(&operands, command: "CIRCLE", what: "first diameter point")
                let b = try takePoint(&operands, command: "CIRCLE", what: "second diameter point")
                center = Vector3(
                    x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: (a.z + b.z) / 2)
                radius = distance3(a, b) / 2
            case .word("3P"):
                let a = try takePoint(&operands, command: "CIRCLE", what: "first point")
                let b = try takePoint(&operands, command: "CIRCLE", what: "second point")
                let c = try takePoint(&operands, command: "CIRCLE", what: "third point")
                guard let solved = circumcenter(a, b, c) else {
                    throw LispError.hostError("command: CIRCLE 3P points are collinear")
                }
                center = solved.center
                radius = solved.radius
            case .word(let word):
                throw LispError.hostError(
                    "command: CIRCLE does not support keyword \"\(word)\"")
            case .enter:
                throw LispError.hostError("command: CIRCLE needs a center point")
            }
        } else {
            center = try takePoint(&operands, command: "CIRCLE", what: "a center point")
            if let keyword = takeKeyword(&operands) {
                switch keyword {
                case .word("D"):
                    let diameter = try takeNumber(&operands, command: "CIRCLE", what: "a diameter")
                    radius = diameter / 2
                case .word(let word):
                    throw LispError.hostError(
                        "command: CIRCLE does not support keyword \"\(word)\"")
                case .enter:
                    throw LispError.hostError("command: CIRCLE needs a radius")
                }
            } else {
                radius = try takeNumber(&operands, command: "CIRCLE", what: "a radius")
            }
        }
        guard let center, let radius, radius > 0 else {
            throw LispError.hostError("command: CIRCLE needs a positive radius")
        }
        try await addPrimitives(
            [.circle(center: center, radius: radius, color: await currentColor(host))],
            host: host)
    }

    static func takeNumberOrNumericString(
        _ operands: inout [LispValue], command: String, what: String
    ) throws -> Double {
        skipSnaps(&operands)
        guard let first = operands.first else {
            throw LispError.hostError("command: \(command) needs \(what)")
        }
        if let value = first.asDouble {
            operands.removeFirst()
            return value
        }
        if case let .string(raw) = first, let value = Double(raw.trimmingCharacters(in: .whitespaces)) {
            operands.removeFirst()
            return value
        }
        throw LispError.hostError("command: \(command) needs \(what)")
    }

    static func takeStringOperand(_ operands: inout [LispValue]) -> String? {
        guard let first = operands.first else { return nil }
        operands.removeFirst()
        switch first {
        case .string(let s): return s
        case .symbol(let s): return s
        case .int(let i): return "\(i)"
        case .real(let r): return "\(r)"
        default: return nil
        }
    }

    static let knownGradientNames: Set<String> = [
        "LINEAR", "CYLINDER", "INVCYLINDER", "SPHERICAL",
        "HEMISPHERICAL", "CURVED", "INVCURVED", "INVSPHERICAL", "INVHEMISPHERICAL",
    ]

    static let gradientIndexToName: [Int: String] = [
        1: "LINEAR",
        2: "CYLINDER",
        3: "INVCYLINDER",
        4: "SPHERICAL",
        5: "HEMISPHERICAL",
        6: "CURVED",
        7: "INVCURVED",
        8: "INVSPHERICAL",
        9: "INVHEMISPHERICAL",
    ]

    static func normalizedGradientName(_ raw: String) -> String? {
        var name = canonicalName(raw)
        if let idx = Int(name), let mapped = gradientIndexToName[idx] {
            return mapped
        }
        if name.hasPrefix("GRADIENT_") {
            name = String(name.dropFirst("GRADIENT_".count))
        } else if name.hasPrefix("GR_") {
            name = String(name.dropFirst("GR_".count))
        }
        switch name {
        case "CYLINDRICAL": return "CYLINDER"
        case "INVCYLINDRICAL": return "INVCYLINDER"
        case "GRADIENT", "GRAD": return "LINEAR"
        default:
            if knownGradientNames.contains(name) {
                return name
            }
            let upper = canonicalName(raw)
            if upper.hasPrefix("GR_") || upper.hasPrefix("GRAD") {
                return name.isEmpty ? "LINEAR" : name
            }
            return nil
        }
    }

    static func parseTrueColor(_ text: String) -> ColorRGBA? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.uppercased().hasPrefix("RGB:") {
            cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3,
              let r = Int(parts[0]),
              let g = Int(parts[1]),
              let b = Int(parts[2]) else { return nil }
        let clamp = { (v: Int) -> UInt8 in UInt8(max(0, min(255, v))) }
        return ColorRGBA(r: clamp(r), g: clamp(g), b: clamp(b), a: 255)
    }

    static func parseColorOperand(_ operands: inout [LispValue]) throws -> ColorRGBA? {
        if let kw = takeKeyword(&operands) {
            switch kw {
            case .word("T"), .word("TRUECOLOR"):
                if let str = takeStringOperand(&operands) {
                    return parseTrueColor(str)
                }
                return nil
            case .word("BYLAYER"): return nil
            case .word("BYBLOCK"): return nil
            case .word(let word):
                if word.contains(",") || word.hasPrefix("RGB:") {
                    return parseTrueColor(word)
                }
                if let aci = Int(word), (1...255).contains(aci) {
                    return DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
                }
                return nil
            case .enter: return nil
            }
        }
        if let first = operands.first {
            switch first {
            case .int(let aci):
                operands.removeFirst()
                if (1...255).contains(aci) {
                    return DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
                }
            case .string(let str), .symbol(let str):
                operands.removeFirst()
                if str.contains(",") || str.uppercased().hasPrefix("RGB:") {
                    return parseTrueColor(str)
                }
                if let aci = Int(str), (1...255).contains(aci) {
                    return DXFColorTable.aciToRGBA(Int32(aci), color24: -1)
                }
            default:
                break
            }
        }
        return nil
    }

    static func parseOptionalColorOperand(_ operands: inout [LispValue]) -> ColorRGBA? {
        guard let first = operands.first else { return nil }
        switch first {
        case .string(let raw), .symbol(let raw):
            let word = canonicalName(raw)
            if word == "T" || word == "TRUECOLOR" {
                operands.removeFirst()
                guard let str = takeStringOperand(&operands) else { return nil }
                return parseTrueColor(str)
            }
            if word == "C2" || word == "BG" || word == "BACKGROUND" {
                operands.removeFirst()
                return try? parseColorOperand(&operands)
            }
            if raw.contains(",") || word.hasPrefix("RGB:") {
                operands.removeFirst()
                return parseTrueColor(raw)
            }
            return nil
        default:
            return nil
        }
    }

    private static func extractBoundaryVertices(entity: CADEntity) -> [Vector3] {
        guard let first = entity.localGeometry?.first else { return [] }
        let t = entity.transform
        switch first {
        case .polyline(let path, _):
            return path.vertices.map { t.transformPoint($0.position) }
        case .polygon(let pts, _), .fillPolygon(let pts, _):
            return pts.map { t.transformPoint($0) }
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            return [
                origin,
                Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                Vector3(x: origin.x, y: origin.y + size.y, z: origin.z),
            ].map { t.transformPoint($0) }
        case .hatch(let boundary, _, _, _, _, _):
            return boundary.map { t.transformPoint($0) }
        case .hatchPath(let boundary, _, _, _, _, _, _):
            return boundary.vertices.map { t.transformPoint($0.position) }
        default:
            return []
        }
    }

    private static func runRectang(_ operands: inout [LispValue], host: LispCADHost) async throws {
        let p1 = try takePoint(&operands, command: "RECTANG", what: "first corner")
        let p2 = try takePoint(&operands, command: "RECTANG", what: "other corner")
        _ = takeKeyword(&operands)
        let vertices = [
            CADPolylineVertex(position: Vector3(x: p1.x, y: p1.y, z: p1.z)),
            CADPolylineVertex(position: Vector3(x: p2.x, y: p1.y, z: p1.z)),
            CADPolylineVertex(position: Vector3(x: p2.x, y: p2.y, z: p2.z)),
            CADPolylineVertex(position: Vector3(x: p1.x, y: p2.y, z: p2.z)),
        ]
        let poly = CADPolyline(vertices: vertices, isClosed: true)
        try await addPrimitives(
            [.polyline(path: poly, color: await currentColor(host))],
            host: host)
    }

    private static func runPline(_ operands: inout [LispValue], host: LispCADHost) async throws {
        var vertices: [CADPolylineVertex] = []
        var closed = false
        var done = false
        var currentStartWidth = 0.0
        var currentEndWidth = 0.0
        var isArcMode = false

        while !operands.isEmpty, !done {
            if let keyword = takeKeyword(&operands) {
                switch keyword {
                case .enter: done = true
                case .word("C"):
                    closed = true
                    done = true
                case .word("W"):
                    currentStartWidth = try takeNumberOrNumericString(&operands, command: "PLINE", what: "start width")
                    currentEndWidth = try takeNumberOrNumericString(&operands, command: "PLINE", what: "end width")
                case .word("H"):
                    currentStartWidth = (try takeNumberOrNumericString(&operands, command: "PLINE", what: "start half-width")) * 2
                    currentEndWidth = (try takeNumberOrNumericString(&operands, command: "PLINE", what: "end half-width")) * 2
                case .word("A"):
                    isArcMode = true
                case .word("L"):
                    isArcMode = false
                case .word(let word):
                    throw LispError.hostError(
                        "command: PLINE does not support keyword \"\(word)\"")
                }
                if operands.isEmpty { break }
                continue
            }
            let point = try takePoint(&operands, command: "PLINE", what: "a vertex")
            if isArcMode, !vertices.isEmpty {
                let prev = vertices[vertices.count - 1].position
                let dx = point.x - prev.x, dy = point.y - prev.y
                let chordAngle = atan2(dy, dx)
                let prevDirAngle: Double
                if vertices.count >= 2 {
                    let p0 = vertices[vertices.count - 2].position
                    prevDirAngle = atan2(prev.y - p0.y, prev.x - p0.x)
                } else {
                    prevDirAngle = chordAngle
                }
                var alpha = chordAngle - prevDirAngle
                while alpha > Double.pi { alpha -= 2 * Double.pi }
                while alpha < -Double.pi { alpha += 2 * Double.pi }
                vertices[vertices.count - 1].bulge = tan(alpha / 2)
            }
            vertices.append(CADPolylineVertex(
                position: point, bulge: 0, startWidth: currentStartWidth, endWidth: currentEndWidth))
        }
        guard vertices.count >= 2 else {
            throw LispError.hostError("command: PLINE needs at least two vertices")
        }
        try await addPrimitives(
            [.polyline(
                path: CADPolyline(vertices: vertices, isClosed: closed),
                color: await currentColor(host))],
            host: host)
    }

    private static func runArc(_ operands: inout [LispValue], host: LispCADHost) async throws {
        // Forms: 3-point (p1 p2 p3), C center start end, or start E end R radius.
        if let keyword = takeKeyword(&operands) {
            switch keyword {
            case .word("C"):
                let center = try takePoint(&operands, command: "ARC", what: "a center point")
                let start = try takePoint(&operands, command: "ARC", what: "a start point")
                let end = try takePoint(&operands, command: "ARC", what: "an end point")
                let radius = distance3(center, start)
                guard radius > 0 else {
                    throw LispError.hostError("command: ARC center and start coincide")
                }
                _ = takeKeyword(&operands)
                try await addPrimitives(
                    [.arc(
                        center: center, radius: radius,
                        startAngle: atan2(start.y - center.y, start.x - center.x),
                        endAngle: atan2(end.y - center.y, end.x - center.x),
                        color: await currentColor(host))],
                    host: host)
                return
            case .word(let word):
                throw LispError.hostError(
                    "command: ARC does not support keyword \"\(word)\"")
            case .enter:
                throw LispError.hostError("command: ARC needs points")
            }
        }
        let a = try takePoint(&operands, command: "ARC", what: "a start point")
        if let keyword = takeKeyword(&operands) {
            switch keyword {
            case .word("E"):
                let end = try takePoint(&operands, command: "ARC", what: "an end point")
                if let opt = takeKeyword(&operands), case .word("R") = opt {
                    let r = try takeNumberOrNumericString(&operands, command: "ARC", what: "a radius")
                    let d = distance3(a, end)
                    guard d > 1e-9 else {
                        throw LispError.hostError("command: ARC start and end points coincide")
                    }
                    let radius = max(abs(r), d / 2)
                    let mid = Vector3(x: (a.x + end.x) / 2, y: (a.y + end.y) / 2, z: (a.z + end.z) / 2)
                    let h = max(0, radius * radius - (d / 2) * (d / 2)).squareRoot()
                    let ux = (end.x - a.x) / d
                    let uy = (end.y - a.y) / d
                    let nx = -uy
                    let ny = ux
                    let center = Vector3(x: mid.x + h * nx, y: mid.y + h * ny, z: mid.z)
                    _ = takeKeyword(&operands)
                    try await addPrimitives(
                        [.arc(
                            center: center, radius: radius,
                            startAngle: atan2(a.y - center.y, a.x - center.x),
                            endAngle: atan2(end.y - center.y, end.x - center.x),
                            color: await currentColor(host))],
                        host: host)
                    return
                }
                throw LispError.hostError("command: ARC End requires Radius (_R)")
            default:
                break
            }
        }
        let b = try takePoint(&operands, command: "ARC", what: "a second point")
        let c = try takePoint(&operands, command: "ARC", what: "an end point")
        guard let solved = circumcenter(a, b, c) else {
            throw LispError.hostError("command: ARC points are collinear")
        }
        _ = takeKeyword(&operands)
        try await addPrimitives(
            [.arc(
                center: solved.center, radius: solved.radius,
                startAngle: atan2(a.y - solved.center.y, a.x - solved.center.x),
                endAngle: atan2(c.y - solved.center.y, c.x - solved.center.x),
                color: await currentColor(host))],
            host: host)
    }

    private static func runChprop(_ operands: inout [LispValue], host: LispCADHost) throws {
        let targets = try takeSelection(&operands, command: "CHPROP", host: host)
        guard !targets.isEmpty else { return }
        var done = false
        while !operands.isEmpty, !done {
            guard let kw = takeKeyword(&operands) else {
                operands.removeFirst()
                continue
            }
            switch kw {
            case .enter:
                done = true
            case .word("C"), .word("COLOR"):
                let color = try parseColorOperand(&operands)
                let isTC = color.map { !DXFColorTable.isACI($0) } ?? false
                for handle in targets {
                    if var entity = host.document.entity(for: handle) {
                        entity = LispEntityAdapter.withPrimitiveColor(entity, color)
                        if let color {
                            if isTC {
                                let rgb = (Int(color.r) << 16) | (Int(color.g) << 8) | Int(color.b)
                                entity.xdata["dxf.color24"] = .int(rgb)
                                entity.xdata["dxf.isTrueColor"] = .int(1)
                                entity.xdata.removeValue(forKey: "dxf.colorIndex")
                            } else {
                                entity.xdata["dxf.colorIndex"] = .int(Int(DXFColorTable.rgbaToACI(color)))
                                entity.xdata.removeValue(forKey: "dxf.color24")
                                entity.xdata.removeValue(forKey: "dxf.isTrueColor")
                            }
                        } else {
                            entity.xdata.removeValue(forKey: "dxf.color")
                            entity.xdata.removeValue(forKey: "dxf.color24")
                            entity.xdata.removeValue(forKey: "dxf.colorIndex")
                            entity.xdata.removeValue(forKey: "dxf.isTrueColor")
                        }
                        host.document.replaceEntity(entity)
                    }
                }
            case .word("LA"), .word("LAYER"):
                if let layerName = takeStringOperand(&operands),
                   let layer = host.document.findLayer(named: layerName) {
                    for handle in targets {
                        if var entity = host.document.entity(for: handle) {
                            entity.layerID = layer.handle
                            host.document.replaceEntity(entity)
                        }
                    }
                }
            case .word("LT"), .word("LTYPE"):
                if let ltName = takeStringOperand(&operands) {
                    let canonicalLT = canonicalName(ltName)
                    for handle in targets {
                        if var entity = host.document.entity(for: handle) {
                            if canonicalLT == "BYLAYER" || canonicalLT.isEmpty {
                                entity.xdata.removeValue(forKey: "dxf.lineType")
                            } else {
                                entity.xdata["dxf.lineType"] = .string(canonicalLT)
                            }
                            host.document.replaceEntity(entity)
                        }
                    }
                }
            case .word("S"), .word("LSCALE"), .word("LTSCALE"):
                if let scale = try? takeNumberOrNumericString(&operands, command: "CHPROP", what: "linetypescale") {
                    for handle in targets {
                        if var entity = host.document.entity(for: handle) {
                            entity.xdata["dxf.lineTypeScale"] = .double(scale)
                            host.document.replaceEntity(entity)
                        }
                    }
                }
            case .word("LW"), .word("LWEIGHT"):
                if let lw = try? takeNumberOrNumericString(&operands, command: "CHPROP", what: "lineweight") {
                    for handle in targets {
                        if var entity = host.document.entity(for: handle) {
                            if lw < 0 {
                                entity.xdata.removeValue(forKey: "dxf.lineWeight")
                            } else {
                                entity.xdata["dxf.lineWeight"] = .double(lw)
                            }
                            host.document.replaceEntity(entity)
                        }
                    }
                }
            default:
                break
            }
        }
    }

    /// Scripted `-LAYER` (command-line layer verbs). Each verb mutates
    /// exactly one layer through `LayerTransactionService` (single undo,
    /// same guards as the interactive `-LAYER`). Unknown verbs, unknown
    /// layers, and refused guards throw a clean error.
    private static func runDashLayer(_ operands: inout [LispValue], host: LispCADHost) throws {
        let service = LayerTransactionService()
        let doc = host.document
        func needLayer(_ verb: String) throws -> String {
            guard let name = takeStringOperand(&operands),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LispError.hostError("command: -LAYER \(verb) needs a layer name")
            }
            return name
        }
        func apply(_ result: Result<LayerTransactionService.Outcome, LayerEditError>, _ verb: String) throws {
            if case .failure(let error) = result {
                throw LispError.hostError("command: -LAYER \(verb): \(error.description)")
            }
        }
        guard let kw = takeKeyword(&operands) else {
            throw LispError.hostError(
                "command: -LAYER needs an option (Make/Set/New/Rename/Delete/On/Off/Color/Freeze/Thaw/Lock/Unlock/Plot/NoPlot/Transparency/Description/Reconcile/State)")
        }
        switch kw {
        case .enter:
            return
        case .word("M"), .word("MAKE"):
            let name = try needLayer("Make")
            if case .failure(let error) = service.createLayer(in: doc, name: name) {
                throw LispError.hostError("command: -LAYER Make: \(error.description)")
            }
            if case .failure(let error) = service.setCurrentLayer(in: doc, named: name) {
                throw LispError.hostError("command: -LAYER Make: \(error.description)")
            }
        case .word("S"), .word("SET"):
            try apply(service.setCurrentLayer(in: doc, named: needLayer("Set")), "Set")
        case .word("N"), .word("NEW"):
            let name = try needLayer("New")
            if case .failure(let error) = service.createLayer(in: doc, name: name) {
                throw LispError.hostError("command: -LAYER New: \(error.description)")
            }
        case .word("R"), .word("RENAME"):
            let old = try needLayer("Rename")
            let new = try needLayer("Rename")
            try apply(service.renameLayer(in: doc, from: old, to: new), "Rename")
        case .word("DEL"), .word("DELETE"):
            let name = try needLayer("Delete")
            if case .failure(let error) = service.deleteLayer(in: doc, named: name) {
                throw LispError.hostError("command: -LAYER Delete: \(error.description)")
            }
        case .word("ON"):
            try apply(service.setVisible(in: doc, named: needLayer("On"), visible: true), "On")
        case .word("OFF"):
            try apply(service.setVisible(in: doc, named: needLayer("Off"), visible: false), "Off")
        case .word("C"), .word("COLOR"):
            skipSnaps(&operands)
            var aci: Int? = nil
            var rgb: ColorRGBA? = nil
            if case .int(let i) = operands.first {
                operands.removeFirst()
                aci = i
            } else if let text = takeStringOperand(&operands) {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.contains(",") {
                    guard let tc = parseTrueColor(cleaned) else {
                        throw LispError.hostError("command: -LAYER Color needs ACI 1-255 or R,G,B")
                    }
                    rgb = tc
                } else if let i = Int(cleaned) {
                    aci = i
                }
            }
            let name = try needLayer("Color")
            if let aci, (1...255).contains(aci) {
                try apply(service.setColor(
                    in: doc, named: name,
                    color: DXFColorTable.aciToRGBA(Int32(aci), color24: -1),
                    source: .aci(aci)), "Color")
            } else if let rgb {
                try apply(service.setColor(
                    in: doc, named: name, color: rgb, source: .trueColor), "Color")
            } else {
                throw LispError.hostError("command: -LAYER Color needs ACI 1-255 or R,G,B")
            }
        case .word("FRZ"), .word("FREEZE"):
            try apply(service.setFrozen(in: doc, named: needLayer("Freeze"), frozen: true), "Freeze")
        case .word("THW"), .word("THAW"):
            try apply(service.setFrozen(in: doc, named: needLayer("Thaw"), frozen: false), "Thaw")
        case .word("LCK"), .word("LOCK"):
            try apply(service.setLocked(in: doc, named: needLayer("Lock"), locked: true), "Lock")
        case .word("ULK"), .word("UNLOCK"):
            try apply(service.setLocked(in: doc, named: needLayer("Unlock"), locked: false), "Unlock")
        case .word("P"), .word("PLOT"):
            try apply(service.setPlottable(in: doc, named: needLayer("Plot"), plottable: true), "Plot")
        case .word("NP"), .word("NOPLOT"):
            try apply(service.setPlottable(in: doc, named: needLayer("NoPlot"), plottable: false), "NoPlot")
        case .word("T"), .word("TRANS"), .word("TRANSPARENCY"):
            let pct = Int(try takeNumberOrNumericString(&operands, command: "-LAYER", what: "transparency 0-90"))
            let name = try needLayer("Transparency")
            if case .failure(let error) = service.setTransparency(in: doc, named: name, transparency: pct) {
                throw LispError.hostError("command: -LAYER Transparency: \(error.description)")
            }
        case .word("DESCR"), .word("DESCRIPTION"):
            let name = try needLayer("Description")
            let text = takeStringOperand(&operands) ?? ""
            if case .failure(let error) = service.setDescription(in: doc, named: name, description: text) {
                throw LispError.hostError("command: -LAYER Description: \(error.description)")
            }
        case .word("REC"), .word("RECONCILE"):
            let name = try needLayer("Reconcile")
            if name == "*" {
                _ = service.reconcileAllLayers(in: doc)
            } else if case .failure(let error) = service.setReconciled(in: doc, named: name, reconciled: true) {
                throw LispError.hostError("command: -LAYER Reconcile: \(error.description)")
            }
        case .word("ST"), .word("STATE"):
            try runLayerStateScripted(&operands, host: host)
        default:
            throw LispError.hostError("command: -LAYER option is not supported from Lisp")
        }
    }

    /// Scripted `LAYERSTATE` (and `-LAYER State`): Save/Restore/Delete/
    /// Rename/List over document layer states, one undo per call.
    /// Export/Import need the file dialog and stay interactive-only.
    private static func runLayerStateScripted(_ operands: inout [LispValue], host: LispCADHost) throws {
        let service = LayerTransactionService()
        let doc = host.document
        guard let kw = takeKeyword(&operands) else {
            throw LispError.hostError("command: LAYERSTATE needs Save/Restore/Delete/Rename/List")
        }
        switch kw {
        case .enter:
            return
        case .word("SAVE"), .word("S"):
            guard let name = takeStringOperand(&operands), !name.isEmpty else {
                throw LispError.hostError("command: LAYERSTATE Save needs a name")
            }
            if case .failure(let error) = service.saveLayerState(in: doc, name: name) {
                throw LispError.hostError("command: LAYERSTATE Save: \(error.description)")
            }
        case .word("RESTORE"), .word("R"):
            guard let name = takeStringOperand(&operands), !name.isEmpty else {
                throw LispError.hostError("command: LAYERSTATE Restore needs a name")
            }
            if case .failure(let error) = service.restoreLayerState(in: doc, named: name) {
                throw LispError.hostError("command: LAYERSTATE Restore: \(error.description)")
            }
        case .word("DELETE"), .word("D"):
            guard let name = takeStringOperand(&operands), !name.isEmpty else {
                throw LispError.hostError("command: LAYERSTATE Delete needs a name")
            }
            if case .failure(let error) = service.deleteLayerState(in: doc, named: name) {
                throw LispError.hostError("command: LAYERSTATE Delete: \(error.description)")
            }
        case .word("RENAME"):
            guard let old = takeStringOperand(&operands), !old.isEmpty,
                  let new = takeStringOperand(&operands), !new.isEmpty else {
                throw LispError.hostError("command: LAYERSTATE Rename needs <old> <new>")
            }
            if case .failure(let error) = service.renameLayerState(in: doc, from: old, to: new) {
                throw LispError.hostError("command: LAYERSTATE Rename: \(error.description)")
            }
        case .word("LIST"), .word("LS"):
            return // Scripted calls return no text; states persist on the document.
        default:
            throw LispError.hostError("command: LAYERSTATE option is not supported from Lisp (no file import/export)")
        }
    }

    /// Scripted `LAYERP`: restore previous layer settings. Empty history
    /// is a silent no-op, matching ERASE-without-selection.
    private static func runLayerPreviousScripted(host: LispCADHost) {
        _ = LayerTransactionService().restoreLayerPrevious(in: host.document)
    }

    private static func runAutoContrast(_ operands: inout [LispValue], host: LispCADHost) {
        var enabled: Bool?
        if let kw = takeKeyword(&operands) {
            switch kw {
            case .word("ON"), .word("1"): enabled = true
            case .word("OFF"), .word("0"): enabled = false
            case .enter: enabled = !host.document.autoContrastTrueColor
            default: break
            }
        } else if let first = operands.first {
            operands.removeFirst()
            switch first {
            case .int(let i): enabled = (i != 0)
            case .string(let s), .symbol(let s):
                let upper = s.uppercased()
                if upper == "ON" || upper == "1" { enabled = true }
                else if upper == "OFF" || upper == "0" { enabled = false }
            default: break
            }
        } else {
            enabled = !host.document.autoContrastTrueColor
        }
        if let enabled {
            host.document.autoContrastTrueColor = enabled
            host.document.markNeedsRegeneration()
        }
    }

    private static let hatchOptionKeywords: Set<String> = [
        "P", "PATTERN", "G", "GRADIENT", "CO", "COLOR",
        "C2", "BG", "BACKGROUND", "A", "ANGLE", "S", "SCALE",
    ]

    private static func gradientStopsJSON(_ first: ColorRGBA, _ second: ColorRGBA) -> String {
        let rgb1 = (Int(first.r) << 16) | (Int(first.g) << 8) | Int(first.b)
        let rgb2 = (Int(second.r) << 16) | (Int(second.g) << 8) | Int(second.b)
        return "[{\"aci\":0,\"position\":0,\"rgb\":\(rgb1)},{\"aci\":0,\"position\":1,\"rgb\":\(rgb2)}]"
    }

    private static func runHatch(_ operands: inout [LispValue], host: LispCADHost) async throws {
        var pattern = "SOLID"
        var isGradient = false
        var color1: ColorRGBA?
        var color2: ColorRGBA?
        var angle = 0.0
        var scale = 1.0
        var doneOptions = false

        // Consult HP* / GF* system variables as initial defaults if configured via (setvar ...)
        if case let .string(hpName)? = await host.getSystemVar("HPNAME"), !hpName.isEmpty {
            if let grad = normalizedGradientName(hpName) {
                isGradient = true
                pattern = grad
            } else {
                pattern = canonicalName(hpName)
            }
        }
        if let hpScale = (await host.getSystemVar("HPSCALE"))?.asDouble, hpScale > 0 {
            scale = hpScale
        }
        if let hpAng = (await host.getSystemVar("HPANG"))?.asDouble, hpAng != 0 {
            angle = hpAng
        }
        if let gfVal = await host.getSystemVar("GFNAME") {
            switch gfVal {
            case .int(let idx) where idx > 0:
                if let grad = gradientIndexToName[idx] {
                    isGradient = true
                    pattern = grad
                }
            case .string(let s) where !s.isEmpty:
                if let grad = normalizedGradientName(s) {
                    isGradient = true
                    pattern = grad
                }
            default:
                break
            }
        }
        if case let .string(c1Str)? = await host.getSystemVar("GFCLR1"), !c1Str.isEmpty {
            color1 = parseTrueColor(c1Str) ?? Int(c1Str).flatMap {
                (1...255).contains($0) ? DXFColorTable.aciToRGBA(Int32($0), color24: -1) : nil
            }
        }
        if case let .string(c2Str)? = await host.getSystemVar("GFCLR2"), !c2Str.isEmpty {
            color2 = parseTrueColor(c2Str) ?? Int(c2Str).flatMap {
                (1...255).contains($0) ? DXFColorTable.aciToRGBA(Int32($0), color24: -1) : nil
            }
        }
        if let gfAng = (await host.getSystemVar("GFANG"))?.asDouble, gfAng != 0 {
            angle = gfAng
        }

        while !operands.isEmpty, !doneOptions {
            guard let kw = takeKeyword(&operands) else { break }
            switch kw {
            case .enter:
                if let next = operands.first,
                   case let .string(nextRaw) = next,
                   hatchOptionKeywords.contains(canonicalName(nextRaw))
                {
                    // "" closed a sub-prompt (e.g. _CO); continue reading -HATCH options.
                    continue
                }
                doneOptions = true
            case .word("P"), .word("PATTERN"):
                if let name = takeStringOperand(&operands) {
                    if let grad = normalizedGradientName(name) {
                        isGradient = true
                        pattern = grad
                    } else {
                        isGradient = false
                        pattern = canonicalName(name)
                    }
                }
            case .word("G"), .word("GRADIENT"):
                isGradient = true
                if pattern == "SOLID" { pattern = "LINEAR" }
                if let first = operands.first {
                    switch first {
                    case .string(let s), .symbol(let s):
                        let word = canonicalName(s)
                        if !word.isEmpty, !hatchOptionKeywords.contains(word),
                           let grad = normalizedGradientName(s)
                        {
                            operands.removeFirst()
                            pattern = grad
                        }
                    case .int(let i):
                        if let grad = gradientIndexToName[i] {
                            operands.removeFirst()
                            pattern = grad
                        }
                    default:
                        break
                    }
                }
                if let c = parseOptionalColorOperand(&operands) {
                    if color1 == nil {
                        color1 = c
                        if let c2 = parseOptionalColorOperand(&operands) { color2 = c2 }
                    } else if color2 == nil {
                        color2 = c
                    }
                }
            case .word("CO"), .word("COLOR"):
                color1 = try parseColorOperand(&operands)
                if let c2 = parseOptionalColorOperand(&operands) {
                    color2 = c2
                }
            case .word("C2"), .word("BG"), .word("BACKGROUND"):
                color2 = try parseColorOperand(&operands)
            case .word("A"), .word("ANGLE"):
                angle = (try? takeNumberOrNumericString(&operands, command: "-HATCH", what: "angle")) ?? 0.0
            case .word("S"), .word("SCALE"):
                scale = (try? takeNumberOrNumericString(&operands, command: "-HATCH", what: "scale")) ?? 1.0
            default:
                break
            }
        }

        let targets = try takeSelection(&operands, command: "-HATCH", host: host)
        guard !targets.isEmpty else {
            throw LispError.hostError("command: -HATCH requires a boundary object")
        }
        _ = takeKeyword(&operands)

        let layerID = try activeLayerID(host)
        var entities: [CADEntity] = []
        let defaultHatchColor = await currentColor(host)
        let useGradient = isGradient || normalizedGradientName(pattern) != nil
        let gradName = normalizedGradientName(pattern) ?? "LINEAR"
        let angleRad = angle * Double.pi / 180

        for handle in targets.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entity = host.document.entity(for: handle) else { continue }
            let boundary = extractBoundaryVertices(entity: entity)
            guard boundary.count >= 3 else { continue }
            let hatchColor = color1 ?? defaultHatchColor
            if useGradient {
                let c1 = color1 ?? ColorRGBA.white
                let c2 = color2 ?? ColorRGBA.black
                let prim = CADPrimitive.gradient(
                    outer: boundary, holes: [], gradientName: gradName,
                    angle: angleRad, color1: c1, color2: c2)
                var newEntity = CADEntity(layerID: layerID, localGeometry: [prim])
                newEntity.xdata["dxf.hatchIsGradient"] = .bool(true)
                newEntity.xdata["dxf.hatchGradientName"] = .string(gradName)
                newEntity.xdata["dxf.hatchGradientAngle"] = .double(angleRad)
                newEntity.xdata["dxf.hatchGradientSingleColor"] = .bool(false)
                newEntity.xdata["dxf.hatchGradientTint"] = .double(0.0)
                newEntity.xdata["dxf.hatchGradientStops"] = .string(gradientStopsJSON(c1, c2))
                entities.append(newEntity)
            } else if pattern == "SOLID" {
                let prim = CADPrimitive.fillPolygon(points: boundary, color: hatchColor)
                entities.append(CADEntity(layerID: layerID, localGeometry: [prim]))
            } else {
                let prim = CADPrimitive.hatch(
                    boundary: boundary, pattern: pattern, scale: scale,
                    angle: angleRad, color: hatchColor)
                entities.append(CADEntity(layerID: layerID, localGeometry: [prim]))
            }
        }
        guard !entities.isEmpty else { return }
        host.document.addEntities(entities)
        host.lastCreated = entities.last?.handle
    }

    private static func runText(_ operands: inout [LispValue], host: LispCADHost) async throws {
        var alignH = 0
        var alignV = 0
        if let keyword = takeKeyword(&operands) {
            switch keyword {
            case .word("J"):
                if let jOpt = takeKeyword(&operands), case .word(let jCode) = jOpt {
                    switch jCode {
                    case "L", "LEFT": alignH = 0; alignV = 0
                    case "C", "CENTER": alignH = 1; alignV = 0
                    case "R", "RIGHT": alignH = 2; alignV = 0
                    case "M", "MIDDLE": alignH = 1; alignV = 2
                    case "TL": alignH = 0; alignV = 1
                    case "TC": alignH = 1; alignV = 1
                    case "TR": alignH = 2; alignV = 1
                    case "ML": alignH = 0; alignV = 2
                    case "MC": alignH = 1; alignV = 2
                    case "MR": alignH = 2; alignV = 2
                    case "BL": alignH = 0; alignV = 0
                    case "BC": alignH = 1; alignV = 0
                    case "BR": alignH = 2; alignV = 0
                    default: break
                    }
                }
            default:
                break
            }
        }
        let pos = try takePoint(&operands, command: "TEXT", what: "an insertion point")
        let height = try takeNumberOrNumericString(&operands, command: "TEXT", what: "height")
        let rotation = try takeNumberOrNumericString(&operands, command: "TEXT", what: "rotation angle")
        let textVal: String
        if let first = operands.first {
            operands.removeFirst()
            switch first {
            case .string(let s): textVal = s
            case .int(let i): textVal = "\(i)"
            case .real(let r): textVal = "\(r)"
            default: textVal = "\(first.prin1String)"
            }
        } else {
            textVal = ""
        }
        _ = takeKeyword(&operands)
        let layerID = try activeLayerID(host)
        let styleVal = await host.getSystemVar("TEXTSTYLE")
        let style: String
        if case let .string(s)? = styleVal { style = s } else { style = "Standard" }
        let entity = CADEntity(
            layerID: layerID,
            localGeometry: [
                .text(
                    position: pos,
                    text: textVal,
                    height: height,
                    rotation: rotation * Double.pi / 180,
                    style: style,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: nil,
                    color: await currentColor(host))
            ])
        host.document.addEntities([entity])
        host.lastCreated = entity.handle
    }

    // MARK: - Modify commands (single-mutator rule: one call, one undo entry)

    /// `(command "INSERT" name-or-path point [xscale [yscale [rotation]]])`
    /// — classic file-insert semantics: a name that resolves to an
    /// existing .dxf/.dwg file imports it as a new block definition.
    /// Scales/rotation accept numbers or numeric strings ("1"), "" or a
    /// missing operand takes the default (unit scale / X / 0 degrees).
    private static func runInsert(_ operands: inout [LispValue], host: LispCADHost) async throws {
        guard let first = operands.first, case let .string(rawName) = first, !rawName.isEmpty else {
            throw LispError.hostError("command: INSERT needs a block name or drawing file path")
        }
        operands.removeFirst()
        let document = host.document
        let blockID: UUID
        var defaultScale = 1.0
        if let existing = document.allBlocks.first(where: {
            $0.name.caseInsensitiveCompare(rawName) == .orderedSame && !$0.name.hasPrefix("*")
        }) {
            blockID = existing.handle
        } else {
            // Drawing-file insert: try the name as a path, then with
            // drawing extensions appended (AutoCAD's library lookup).
            let candidates = [rawName, rawName + ".dwg", rawName + ".dxf"]
            guard let path = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0)
            }) else {
                throw LispError.hostError(
                    "command: INSERT block \"\(rawName)\" not found (and no such drawing file)")
            }
            do {
                let (block, scale) = try DrawingFileInsert.insertFile(at: path, into: document)
                blockID = block.handle
                defaultScale = scale
            } catch let error as DrawingFileInsert.InsertError {
                throw LispError.hostError("command: INSERT \(error)")
            }
        }
        let point = try takePoint(&operands, command: "INSERT", what: "insertion point")
        func takeScale(_ fallback: Double) -> Double {
            skipSnaps(&operands)
            guard let next = operands.first else { return fallback }
            if let value = next.asDouble { operands.removeFirst(); return value }
            if case let .string(raw) = next {
                operands.removeFirst()
                return Double(raw) ?? fallback
            }
            return fallback
        }
        let scaleX = takeScale(defaultScale)
        let scaleY = takeScale(scaleX)
        let rotation = takeScale(0)
        let entity = CADEntity(
            layerID: try activeLayerID(host),
            blockID: blockID,
            transform: DrawingFileInsert.insertionTransform(
                point: point, scaleX: scaleX, scaleY: scaleY,
                rotationDegrees: rotation))
        document.addEntities([entity])
        host.lastCreated = entity.handle
    }


    /// `(command "-ATTACH" path [page] point [scale [rotation]])`
    /// for images and PDFs: creates (or reuses) a referenced-media
    /// definition, loads it synchronously, and places one instance.
    /// Drawings reject here — use INSERT (embed) or interactive XATTACH.
    private static func runAttach(_ operands: inout [LispValue], host: LispCADHost) throws {
        guard let first = operands.first, case let .string(rawPath) = first, !rawPath.isEmpty else {
            throw LispError.hostError("command: -ATTACH needs a file path")
        }
        operands.removeFirst()
        let document = host.document
        guard FileManager.default.fileExists(atPath: rawPath) else {
            throw LispError.hostError("command: -ATTACH file \"\(rawPath)\" not found")
        }
        let ext = (rawPath as NSString).pathExtension.lowercased()
        if ext == "dwg" || ext == "dxf" {
            throw LispError.hostError(
                "command: -ATTACH of drawings is interactive-only (XATTACH); use INSERT to embed")
        }
        let store: MediaReferenceStore
        if let existing = document.mediaRuntimeStore {
            store = existing
        } else {
            store = MediaReferenceStore()
            document.mediaRuntimeStore = store
        }
        let pathType = XrefSysvars.refPathType
        let saved = XrefManager.savedPath(
            forFileAt: rawPath, pathType: pathType, hostFolder: nil)

        let name: String
        let kind: MediaReferenceKind
        var pageNumber = 1
        var naturalWidth: Double
        var naturalHeight: Double
        if ext == "pdf" {
            kind = .pdf
            if let next = operands.first, let page = next.asDouble {
                operands.removeFirst()
                pageNumber = max(1, Int(page))
            }
            if let existing = document.pdfDefinitions.values.first(where: {
                $0.savedPath == saved && $0.pageNumber == pageNumber
            }) {
                name = existing.name
            } else {
                name = MediaManager.definitionName(forFileAt: rawPath, in: document)
                document.pdfDefinitions[name] = CADPdfDefinition(
                    name: name, savedPath: saved, pageNumber: pageNumber)
            }
            naturalWidth = CADPdfUnderlayParams.placeholderPageWidth
            naturalHeight = CADPdfUnderlayParams.placeholderPageHeight
        } else if CADImageAsset.supportedExtensions.contains(ext) {
            kind = .image
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: rawPath)),
                  let dims = MediaLoader.imageDimensions(of: data) else {
                throw LispError.hostError("command: -ATTACH could not decode image \"\(rawPath)\"")
            }
            if let existing = document.imageDefinitions.values.first(where: { $0.savedPath == saved }) {
                name = existing.name
            } else {
                name = MediaManager.definitionName(forFileAt: rawPath, in: document)
                document.imageDefinitions[name] = CADImageDefinition(
                    name: name, savedPath: saved,
                    pixelWidth: dims.width, pixelHeight: dims.height)
            }
            naturalWidth = Double(dims.width)
            naturalHeight = Double(dims.height)
        } else {
            throw LispError.hostError(
                "command: -ATTACH unsupported file type .\(ext) (images and PDFs only)")
        }
        store.ensureEntry(kind: kind, name: name, savedPath: saved, pageNumber: pageNumber)
        let outcome = MediaLoader.performLoad(
            kind: kind, name: name, savedPath: saved, pageNumber: pageNumber,
            hostFolder: nil, fallbackFolder: nil, searchPaths: store.searchPaths)
        MediaLoader.apply(outcome, name: name, store: store, documents: [document])
        if kind == .pdf, let w = outcome.pageWidthPoints, let h = outcome.pageHeightPoints {
            naturalWidth = w
            naturalHeight = h
        }

        let point = try takePoint(&operands, command: "-ATTACH", what: "insertion point")
        func takeScale(_ fallback: Double) -> Double {
            skipSnaps(&operands)
            guard let next = operands.first else { return fallback }
            if let value = next.asDouble { operands.removeFirst(); return value }
            if case let .string(raw) = next {
                operands.removeFirst()
                return Double(raw) ?? fallback
            }
            return fallback
        }
        let scale = takeScale(1)
        let rotation = takeScale(0)
        let entity = MediaManager.makeInstance(
            name: name, kind: kind,
            naturalWidth: naturalWidth, naturalHeight: naturalHeight,
            center: point, scale: scale <= 0 ? 1 : scale,
            rotationDegrees: rotation,
            layerID: try activeLayerID(host))
        document.addEntities([entity])
        host.lastCreated = entity.handle
    }

    private static func runCopy(_ operands: inout [LispValue], host: LispCADHost) async throws {
        let targets = try takeSelection(&operands, command: "COPY", host: host)
        guard !targets.isEmpty else {
            throw LispError.hostError("command: COPY requires a selection")
        }
        var multiple = false
        if let keyword = takeKeyword(&operands) {
            switch keyword {
            case .word("M"): multiple = true
            case .word(let word):
                throw LispError.hostError(
                    "command: COPY does not support keyword \"\(word)\"")
            case .enter:
                throw LispError.hostError("command: COPY needs a base point")
            }
        }
        let base = try takePoint(&operands, command: "COPY", what: "a base point")
        var displacements: [Vector3] = []
        while !operands.isEmpty {
            if let keyword = takeKeyword(&operands) {
                if case .word(let word) = keyword {
                    throw LispError.hostError(
                        "command: COPY does not support keyword \"\(word)\"")
                }
                break // Enter ends the displacement list.
            }
            let second = try takePoint(&operands, command: "COPY", what: "a displacement")
            displacements.append(Vector3(
                x: second.x - base.x, y: second.y - base.y, z: second.z - base.z))
            if !multiple { break }
        }
        guard !displacements.isEmpty else {
            throw LispError.hostError("command: COPY needs a displacement")
        }
        var copies: [CADEntity] = []
        for handle in targets.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entity = host.document.entity(for: handle) else { continue }
            for displacement in displacements {
                var transform = entity.transform
                transform.position = Vector3(
                    x: transform.position.x + displacement.x,
                    y: transform.position.y + displacement.y,
                    z: transform.position.z + displacement.z)
                copies.append(CADEntity(
                    layerID: entity.layerID,
                    blockID: entity.blockID,
                    localGeometry: entity.localGeometry,
                    dimensionMetadata: entity.dimensionMetadata,
                    leaderData: entity.leaderData,
                    arrayData: entity.arrayData,
                    transform: transform,
                    xdata: entity.xdata))
            }
        }
        host.document.addEntities(copies)
        host.lastCreated = copies.last?.handle
    }

    private static func runRotate(_ operands: inout [LispValue], host: LispCADHost) throws {
        let targets = try takeSelection(&operands, command: "ROTATE", host: host)
        guard !targets.isEmpty else {
            throw LispError.hostError("command: ROTATE requires a selection")
        }
        if let keyword = takeKeyword(&operands), case .word(let word) = keyword {
            throw LispError.hostError(
                "command: ROTATE does not support keyword \"\(word)\" (reference angles are interactive-only)")
        }
        let base = try takePoint(&operands, command: "ROTATE", what: "a base point")
        let degrees = try takeNumber(&operands, command: "ROTATE", what: "a rotation angle in degrees")
        host.document.rotateEntities(
            handles: targets, around: base,
            angleDeltaRadians: degrees * Double.pi / 180)
    }

    private static func runMove(_ operands: inout [LispValue], host: LispCADHost) throws {
        let targets = try takeSelection(&operands, command: "MOVE", host: host)
        guard !targets.isEmpty else {
            throw LispError.hostError("command: MOVE requires a selection")
        }
        let base = try takePoint(&operands, command: "MOVE", what: "a base point")
        let second = try takePoint(&operands, command: "MOVE", what: "a displacement")
        host.document.moveEntities(
            handles: targets,
            by: Vector3(
                x: second.x - base.x, y: second.y - base.y, z: second.z - base.z))
    }

    private static func runErase(_ operands: inout [LispValue], host: LispCADHost) throws {
        let targets = try takeSelection(&operands, command: "ERASE", host: host)
        guard !targets.isEmpty else { return } // ERASE of nothing: silent no-op.
        host.document.removeEntities(handles: targets)
    }

    /// SELECT makes a selection current (pickfirst + previous): the
    /// scripted (vl-cmdf "_.SELECT" ss "") idiom. Pushes no undo.
    private static func runSelect(_ operands: inout [LispValue], host: LispCADHost) throws {
        let targets = try takeSelection(&operands, command: "SELECT", host: host)
        host.previousSelection = targets
        host.setPickfirst(targets)
    }

    // MARK: - UNDO / U

    private static func runUndo(_ operands: inout [LispValue], host: LispCADHost) async throws {
        // Numeric form first: (command "_.UNDO" 3) undoes N commands.
        if let first = operands.first, first.asDouble != nil {
            operands.removeFirst()
            host.undoTimes(Int(first.asDouble!))
            return
        }
        // No snap-skipping: UNDO END collides with the ENDpoint override.
        guard let keyword = takeKeyword(&operands, skippingSnaps: false) else {
            // Bare (command "_.UNDO") with no option: single undo, like U.
            host.undoOnce()
            return
        }
        switch keyword {
        case .word("BEGIN"), .word("BE"), .word("G"):
            host.document.undoManager.beginUndoGroup()
        case .word("END"):
            if !host.document.undoManager.endUndoGroup() {
                await host.write("No group to end.\n")
            }
        case .word("MARK"):
            host.undoMark = host.document.undoManager.markUndo()
        case .word("BACK"):
            host.undoBack()
        case .word("AUTO"):
            throw LispError.hostError("command: UNDO Auto is not supported from Lisp")
        case .word("CONTROL"):
            throw LispError.hostError("command: UNDO Control is not supported from Lisp")
        case .word(let word):
            throw LispError.hostError(
                "command: UNDO does not support option \"\(word)\"")
        case .enter:
            host.undoOnce()
        }
    }

    // MARK: - Geometry helpers

    private static func distance3(_ a: Vector3, _ b: Vector3) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// Circumcenter of three 2D points (z carried from a), or nil when
    /// collinear. Standard perpendicular-bisector solve.
    private static func circumcenter(
        _ a: Vector3, _ b: Vector3, _ c: Vector3
    ) -> (center: Vector3, radius: Double)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-12 else { return nil }
        let a2 = a.x * a.x + a.y * a.y
        let b2 = b.x * b.x + b.y * b.y
        let c2 = c.x * c.x + c.y * c.y
        let cx = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let cy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        let center = Vector3(x: cx, y: cy, z: a.z)
        return (center, distance3(center, a))
    }
}

// HostBuiltins: Wave-A builtins that touch the host.
//
// Input parsing and initget enforcement live here (shared by all hosts);
// hosts only move text/coordinates/events. Entity, selection, and command
// builtins validate arguments and forward to the host, whose step-2
// defaults report clean errors until step 3 binds the CAD host.
import Foundation

enum HostBuiltins {
    static let table: [String: LispBuiltin] = [
        "GETVAR": getvar,
        "SETVAR": setvar,
        "INITGET": initget,
        "GETPOINT": getpoint,
        "GETREAL": getReal,
        "GETINT": getInt,
        "GETSTRING": getstring,
        "GETKWORD": getkword,
        "GETDIST": getdist,
        "GETANGLE": getangle,
        "GETORIENT": getorient,
        "GETCORNER": getcorner,
        "ENTSEL": entsel,
        "NENTSEL": nentsel,
        "NENTSELP": nentselp,
        "GRREAD": grread,
        "COMMAND": command,
        "COMMAND-S": commandS,
        "VL-CMDF": vlCmdf,
        "ENTGET": entget,
        "ENTMOD": entmod,
        "ENTMAKE": entmake,
        "ENTMAKEX": entmakex,
        "ENTDEL": entdel,
        "ENTLAST": entlast,
        "ENTNEXT": entnext,
        "HANDENT": handent,
        "ENTUPD": entupd,
        "SSGET": ssget,
        "SSADD": ssadd,
        "SSDEL": ssdel,
        "SSLENGTH": sslength,
        "SSNAME": ssname,
        "SSMEMB": ssmemb,
        "SSGETFIRST": ssgetfirst,
        "SSSETFIRST": sssetfirst,
    ]

    // MARK: - System variables

    private static func getvar(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("getvar", args, 1)
        let name = try BuiltinArgs.string("getvar", args[0]).uppercased()
        guard let value = await host.getSystemVar(name) else {
            throw LispError.hostError("unknown system variable: \(name)")
        }
        return value
    }

    private static func setvar(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("setvar", args, 2)
        let name = try BuiltinArgs.string("setvar", args[0]).uppercased()
        guard await host.getSystemVar(name) != nil else {
            throw LispError.hostError("unknown system variable: \(name)")
        }
        await host.setSystemVar(name, args[1])
        return args[1]
    }

    private static func initget(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("initget", args, min: 0, max: 2)
        // (initget) | (initget bits) | (initget "kws") | (initget bits "kws").
        var bits = 0
        var keywords: [String] = []
        switch args.count {
        case 0:
            break
        case 1:
            switch args[0] {
            case let .int(v): bits = v
            case let .string(s): keywords = splitKeywords(s)
            default:
                throw LispError.typeMismatch(name: "initget", expected: "integer or keyword string", got: args[0])
            }
        default:
            bits = try BuiltinArgs.int("initget", args[0])
            keywords = splitKeywords(try BuiltinArgs.string("initget", args[1]))
        }
        env.pendingInitget = LispInitget(bits: bits, keywords: keywords)
        return .nilValue
    }

    private static func splitKeywords(_ text: String) -> [String] {
        text.split(separator: " ").map { String($0) }
    }

    /// Takes and clears the pending initget (each get* consumes it).
    static func takeInitget(_ env: inout LispEnvironment) -> LispInitget {
        let current = env.pendingInitget
        env.pendingInitget = LispInitget()
        return current
    }

    // MARK: - Text input (getreal/getint/getstring/getkword)

    private static func getReal(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("getreal", args, min: 0, max: 1)
        let prompt = args.first.flatMap(promptText) ?? ""
        let control = takeInitget(&env)
        while true {
            guard let line = try await host.requestLine(prompt: prompt) else {
                if control.bits & 1 != 0 { continue } // Null input not allowed.
                return .nilValue
            }
            guard let value = LispInputParsing.parseReal(line) else {
                await host.write("Requires a numeric value.\n")
                continue
            }
            if control.bits & 2 != 0, value == 0 {
                await host.write("Zero not allowed.\n")
                continue
            }
            if control.bits & 4 != 0, value < 0 {
                await host.write("Negative value not allowed.\n")
                continue
            }
            return .real(value)
        }
    }

    private static func getInt(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("getint", args, min: 0, max: 1)
        let prompt = args.first.flatMap(promptText) ?? ""
        let control = takeInitget(&env)
        while true {
            guard let line = try await host.requestLine(prompt: prompt) else {
                if control.bits & 1 != 0 { continue }
                return .nilValue
            }
            guard let value = LispInputParsing.parseInt(line) else {
                await host.write("Requires an integer value.\n")
                continue
            }
            if control.bits & 2 != 0, value == 0 {
                await host.write("Zero not allowed.\n")
                continue
            }
            if control.bits & 4 != 0, value < 0 {
                await host.write("Negative value not allowed.\n")
                continue
            }
            return .int(value)
        }
    }

    private static func getstring(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("getstring", args, min: 0, max: 2)
        // (getstring [allowSpaces] [prompt]) or (getstring [prompt]).
        var allowSpaces = false
        var prompt = ""
        for arg in args {
            if case let .string(text) = arg { prompt = text } else { allowSpaces = arg.isTrue }
        }
        let line: String?
        if allowSpaces {
            line = try await host.requestLineAllowingSpaces(prompt: prompt, allowSpaces: true)
        } else {
            line = try await host.requestLine(prompt: prompt)
        }
        guard let line else {
            return .string("")
        }
        if allowSpaces { return .string(line) }
        // Without T, input stops at the first space.
        if let space = line.firstIndex(of: " ") { return .string(String(line[..<space])) }
        return .string(line)
    }

    private static func getkword(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("getkword", args, min: 0, max: 1)
        let prompt = args.first.flatMap(promptText) ?? ""
        let control = takeInitget(&env)
        while true {
            guard let line = try await host.requestLine(prompt: prompt) else {
                if control.bits & 1 != 0 { continue }
                return .nilValue
            }
            let typed = line.trimmingCharacters(in: .whitespaces).uppercased()
            if typed.isEmpty {
                if control.bits & 1 != 0 { continue }
                return .nilValue
            }
            // Without initget keywords, any text is accepted as-is.
            guard !control.keywords.isEmpty else { return .string(line) }
            let matches = control.keywords.filter { $0.uppercased().hasPrefix(typed) }
            if matches.count == 1 { return .string(matches[0]) }
            await host.write("Invalid keyword. Options: \(control.keywords.joined(separator: "/"))\n")
        }
    }

    private static func promptText(_ value: LispValue) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }

    // MARK: - Geometric input

    private static func getpoint(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("getpoint", args, min: 0, max: 2)
        var base: [Double]?
        var prompt = ""
        for arg in args {
            if let coords = arg.asPoint { base = coords } else if case let .string(text) = arg {
                prompt = text
            } else {
                throw LispError.typeMismatch(name: "getpoint", expected: "point or prompt", got: arg)
            }
        }
        let control = takeInitget(&env)
        while true {
            guard let coords = try await host.requestPoint(prompt: prompt, base: base) else {
                if control.bits & 1 != 0 { continue }
                return .nilValue
            }
            return LispValue(list: coords.map(LispValue.real))
        }
    }

    private static func getdist(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("getdist", args, min: 0, max: 2)
        var base: [Double]?
        var prompt = ""
        for arg in args {
            if let coords = arg.asPoint { base = coords } else if case let .string(text) = arg {
                prompt = text
            } else {
                throw LispError.typeMismatch(name: "getdist", expected: "point or prompt", got: arg)
            }
        }
        let control = takeInitget(&env)
        func check(_ value: Double, host: any LispHost) async -> LispValue? {
            if control.bits & 2 != 0, value == 0 {
                await host.write("Zero not allowed.\n")
                return nil
            }
            if control.bits & 4 != 0, value < 0 {
                await host.write("Negative value not allowed.\n")
                return nil
            }
            return .real(value)
        }
        // With a base point: one pick (or a typed number).
        if let base {
            while true {
                guard let answer = try await host.requestPointOrNumber(prompt: prompt, base: base) else {
                    if control.bits & 1 != 0 { continue }
                    return .nilValue
                }
                switch answer {
                case let .number(value):
                    if let checked = await check(value, host: host) { return checked }
                case let .point(coords):
                    var sum = 0.0
                    for index in 0..<max(base.count, coords.count) {
                        let a = index < base.count ? base[index] : 0
                        let b = index < coords.count ? coords[index] : 0
                        sum += (a - b) * (a - b)
                    }
                    if let checked = await check(sum.squareRoot(), host: host) { return checked }
                }
            }
        }
        // Without a base: two picks (a typed number at either is the answer).
        while true {
            guard let first = try await host.requestPointOrNumber(prompt: prompt, base: nil) else {
                if control.bits & 1 != 0 { continue }
                return .nilValue
            }
            switch first {
            case let .number(value):
                if let checked = await check(value, host: host) { return checked }
            case let .point(firstCoords):
                guard let second = try await host.requestPointOrNumber(prompt: prompt, base: firstCoords) else {
                    if control.bits & 1 != 0 { continue }
                    return .nilValue
                }
                switch second {
                case let .number(value):
                    if let checked = await check(value, host: host) { return checked }
                case let .point(secondCoords):
                    var sum = 0.0
                    for index in 0..<max(firstCoords.count, secondCoords.count) {
                        let a = index < firstCoords.count ? firstCoords[index] : 0
                        let b = index < secondCoords.count ? secondCoords[index] : 0
                        sum += (a - b) * (a - b)
                    }
                    if let checked = await check(sum.squareRoot(), host: host) { return checked }
                }
            }
        }
    }

    private static func getangle(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try await getangleImpl(name: "getangle", oriented: false, args: args, env: &env, host: host)
    }

    private static func getorient(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try await getangleImpl(name: "getorient", oriented: true, args: args, env: &env, host: host)
    }

    /// Shared getangle/getorient: two picks (or base + pick, or typed number).
    /// getorient applies ANGBASE/ANGDIR; getangle returns raw 0..2pi radians.
    private static func getangleImpl(
        name: String, oriented: Bool, args: [LispValue],
        env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range(name, args, min: 0, max: 2)
        var base: [Double]?
        var prompt = ""
        for arg in args {
            if let coords = arg.asPoint { base = coords } else if case let .string(text) = arg {
                prompt = text
            } else {
                throw LispError.typeMismatch(name: name, expected: "point or prompt", got: arg)
            }
        }
        let control = takeInitget(&env)
        var origin = base
        if origin == nil {
            // First pick establishes the base (a typed number answers directly).
            while true {
                guard let first = try await host.requestPointOrNumber(prompt: prompt, base: nil) else {
                    if control.bits & 1 != 0 { continue }
                    return .nilValue
                }
                switch first {
                case let .number(value): return .real(value)
                case let .point(coords): origin = coords
                }
                if origin != nil { break }
            }
        }
        while true {
            guard let answer = try await host.requestPointOrNumber(prompt: prompt, base: origin) else {
                if control.bits & 1 != 0 { continue }
                return .nilValue
            }
            switch answer {
            case let .number(value): return .real(value)
            case let .point(coords):
                let from = origin!
                var radians = atan2(coords[1] - from[1], coords[0] - from[0])
                if radians < 0 { radians += 2 * Double.pi }
                if oriented {
                    let baseAngle = await ConvertBuiltins.realVar(host, "ANGBASE", default: 0)
                    let clockwise = await ConvertBuiltins.intVar(host, "ANGDIR", default: 0) == 1
                    radians = clockwise ? baseAngle - radians : radians - baseAngle
                    radians.formTruncatingRemainder(dividingBy: 2 * Double.pi)
                    if radians < 0 { radians += 2 * Double.pi }
                }
                return .real(radians)
            }
        }
    }

    private static func getcorner(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("getcorner", args, min: 0, max: 2)
        var base: [Double]?
        var prompt = ""
        for arg in args {
            if let coords = arg.asPoint { base = coords } else if case let .string(text) = arg {
                prompt = text
            } else {
                throw LispError.typeMismatch(name: "getcorner", expected: "point or prompt", got: arg)
            }
        }
        let control = takeInitget(&env)
        while true {
            guard let coords = try await host.requestPoint(prompt: prompt, base: base) else {
                if control.bits & 1 != 0 { continue }
                return .nilValue
            }
            return LispValue(list: coords.map(LispValue.real))
        }
    }

    private static func entsel(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("entsel", args, min: 0, max: 1)
        let prompt = args.first.flatMap(promptText) ?? ""
        _ = takeInitget(&env) // Keywords at pick prompts: accepted gap (step 3).
        guard let pick = try await host.requestEntity(prompt: prompt) else { return .nilValue }
        return LispValue(list: [
            .entityName(pick.handle),
            LispValue(list: pick.point.map(LispValue.real)),
        ])
    }

    private static func nentsel(
        _: LispEvaluator, args: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        // Nested-block detail lands with the CAD host (step 3); the
        // non-nested shape is identical to entsel.
        try await entsel(LispEvaluator(), args: args, env: &env, host: host)
    }

    private static func nentselp(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        // Passive: inspects pickfirst state, never prompts. Real data lands
        // with the CAD host (step 3).
        try BuiltinArgs.range("nentselp", args, min: 0, max: 1)
        let point = args.first.flatMap { $0.asPoint }
        return try await host.nentselPassive(at: point) ?? .nilValue
    }

    private static func grread(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("grread", args, min: 0, max: 3)
        return try await host.readDeviceEvent()
    }

    // MARK: - Commands (reentrancy guard + audit land in step 3)

    private static func command(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        _ = try await host.runCommand(args)
        return .nilValue
    }

    private static func commandS(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        _ = try await host.runCommandS(args)
        return .nilValue
    }

    private static func vlCmdf(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        _ = try await host.runCommand(args)
        return .t
    }

    // MARK: - Entity forwarding

    private static func entityHandle(_ name: String, _ value: LispValue) throws -> String {
        guard case let .entityName(handle) = value else {
            throw LispError.typeMismatch(name: name, expected: "entity name", got: value)
        }
        return handle
    }

    private static func entget(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("entget", args, min: 1, max: 2)
        // Application-id filtering (xdata) lands with the CAD host.
        return try await host.entGet(entityHandle("entget", args[0]))
    }

    private static func entmod(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("entmod", args, 1)
        _ = try BuiltinArgs.properList("entmod", args[0])
        return try await host.entMod(args[0])
    }

    private static func entmake(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("entmake", args, 1)
        _ = try BuiltinArgs.properList("entmake", args[0])
        return try await host.entMake(args[0])
    }

    private static func entmakex(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("entmakex", args, 1)
        _ = try BuiltinArgs.properList("entmakex", args[0])
        return try await host.entMakeX(args[0])
    }

    private static func entdel(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("entdel", args, 1)
        return try await host.entDel(entityHandle("entdel", args[0]))
    }

    private static func entlast(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("entlast", args, 0)
        return try await host.entLast()
    }

    private static func entnext(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("entnext", args, min: 0, max: 1)
        if args.isEmpty { return try await host.entNext(nil) }
        return try await host.entNext(entityHandle("entnext", args[0]))
    }

    private static func handent(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("handent", args, 1)
        return try await host.handEnt(try BuiltinArgs.string("handent", args[0]))
    }

    private static func entupd(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("entupd", args, 1)
        return try await host.entUpd(entityHandle("entupd", args[0]))
    }

    // MARK: - Selection forwarding

    /// Selection modes that need interactive picking (step-3 host).
    static let interactiveModes: Set<String> = [
        "C", "_C", "W", "_W", "F", "_F", "CP", "_CP", "WP", "_WP",
        "P", "_P", "L", "_L", "I", "_I",
    ]

    private static func ssget(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        // (ssget) | (ssget filter) | (ssget mode ...) | (ssget "_X" filter)
        // | (ssget "prompt" ...). Empty results are nil, like AutoCAD.
        if args.isEmpty {
            guard let id = try await host.ssGetInteractive(mode: "PICK", points: [], filter: nil) else {
                return .nilValue
            }
            return .selectionSet(id)
        }
        if case let .string(mode) = args[0] {
            let upper = mode.uppercased()
            if upper == "X" || upper == "_X" {
                try BuiltinArgs.range("ssget", args, min: 1, max: 2)
                let filter = args.count == 2 ? args[1] : nil
                if let filter { _ = try BuiltinArgs.properList("ssget", filter) }
                guard let id = try await host.ssGet(filter: filter) else {
                    return .nilValue
                }
                return .selectionSet(id)
            }
            // Mode + points + optional filter.
            var points: [[Double]] = []
            var filter: LispValue?
            for arg in args.dropFirst() {
                if let coords = arg.asPoint {
                    points.append(coords)
                } else if filter == nil, arg.properList != nil {
                    filter = arg
                } else {
                    throw LispError.typeMismatch(name: "ssget", expected: "point or filter list", got: arg)
                }
            }
            if !interactiveModes.contains(upper) {
                // A non-mode string is a prompt: display it, then pick.
                // Prompt + two points = window pick; prompt alone = PICK.
                await host.write(mode)
                if points.isEmpty, filter == nil {
                    guard let id = try await host.ssGetInteractive(
                        mode: "PICK", points: [], filter: nil)
                    else {
                        return .nilValue
                    }
                    return .selectionSet(id)
                }
                guard points.count == 2 else {
                    throw LispError.hostError(
                        "ssget: a prompt string takes zero or two corner points")
                }
                guard let id = try await host.ssGetInteractive(
                    mode: "W", points: points, filter: filter)
                else {
                    return .nilValue
                }
                return .selectionSet(id)
            }
            guard let id = try await host.ssGetInteractive(
                mode: upper, points: points, filter: filter)
            else {
                return .nilValue
            }
            return .selectionSet(id)
        }
        // Bare filter list: implied window pick (interactive host).
        try BuiltinArgs.exactly("ssget", args, 1)
        _ = try BuiltinArgs.properList("ssget", args[0])
        guard let id = try await host.ssGetInteractive(mode: "PICK", points: [], filter: args[0]) else {
            return .nilValue
        }
        return .selectionSet(id)
    }

    private static func selectionId(_ name: String, _ value: LispValue) throws -> Int {
        guard case let .selectionSet(id) = value else {
            throw LispError.typeMismatch(name: name, expected: "selection set", got: value)
        }
        return id
    }

    private static func ssadd(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("ssadd", args, min: 0, max: 2)
        var handle: String?
        var set: Int?
        if !args.isEmpty { handle = try entityHandle("ssadd", args[0]) }
        if args.count == 2 { set = try selectionId("ssadd", args[1]) }
        return .selectionSet(try await host.ssAdd(handle, set: set))
    }

    private static func ssdel(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("ssdel", args, 2)
        return try await host.ssDel(
            entityHandle("ssdel", args[0]), set: selectionId("ssdel", args[1]))
    }

    private static func sslength(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("sslength", args, 1)
        return .int(try await host.ssLength(selectionId("sslength", args[0])))
    }

    private static func ssname(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("ssname", args, 2)
        return try await host.ssName(
            selectionId("ssname", args[0]), index: BuiltinArgs.int("ssname", args[1]))
    }

    private static func ssmemb(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("ssmemb", args, 2)
        return try await host.ssMemb(
            entityHandle("ssmemb", args[0]), set: selectionId("ssmemb", args[1]))
    }

    private static func ssgetfirst(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        // Undocumented args ignored (selection cycling state lives in the host).
        _ = args
        return try await host.ssGetFirst()
    }

    private static func sssetfirst(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        // (sssetfirst gripset pickset): the SECOND set is the pickfirst
        // highlight; (sssetfirst nil nil) clears. Single-arg form is a
        // lenient extension (highlight that set).
        try BuiltinArgs.range("sssetfirst", args, min: 0, max: 2)
        if args.isEmpty { return try await host.ssSetFirst(nil) }
        if args.count == 2 {
            if args[1].isNil { return try await host.ssSetFirst(nil) }
            return try await host.ssSetFirst(selectionId("sssetfirst", args[1]))
        }
        if args[0].isNil { return try await host.ssSetFirst(nil) }
        return try await host.ssSetFirst(selectionId("sssetfirst", args[0]))
    }
}

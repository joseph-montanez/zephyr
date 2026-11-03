// LayerBuiltins: Phase-5 document layer verbs (freeze/thaw/lock/unlock,
// make/delete/merge, on/off probes, history depth).
//
// Unlike the session-local layerstate-* family in
// LispBuiltinsLayerState.swift, these mutate the drawing through the host
// and honor the transactional guards: freezing the current layer,
// deleting layer 0, or naming an unknown layer all fail as nil with no
// state change. Viewport freeze details live behind VPLAYER (command and
// host map), not in this family.

enum LayerBuiltins {
    static let table: [String: LispBuiltin] = [
        "LAYER-MAKE": layerMake,
        "LAYER-DELETE": layerDelete,
        "LAYER-MERGE": layerMerge,
        "LAYER-FREEZE": layerFreeze,
        "LAYER-THAW": layerThaw,
        "LAYER-LOCK": layerLock,
        "LAYER-UNLOCK": layerUnlock,
        "LAYER-ON": layerOn,
        "LAYER-OFF": layerOff,
        "LAYER-FROZENP": layerFrozenP,
        "LAYER-LOCKEDP": layerLockedP,
        "LAYER-ONP": layerOnP,
        "LAYER-NAMES": layerNames,
        "LAYER-HISTORY-DEPTH": layerHistoryDepth,
    ]

    private static func layerMake(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-make", args, 1)
        let name = try BuiltinArgs.string("layer-make", args[0])
        return await host.layerMake(name) ? .t : .nilValue
    }

    private static func layerDelete(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-delete", args, 1)
        let name = try BuiltinArgs.string("layer-delete", args[0])
        return await host.layerDelete(name) ? .t : .nilValue
    }

    private static func layerMerge(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-merge", args, 2)
        let target = try BuiltinArgs.string("layer-merge", args[0])
        let items = try BuiltinArgs.properList("layer-merge", args[1])
        let sources = try items.map { try BuiltinArgs.string("layer-merge", $0) }
        return await host.layerMerge(from: sources, into: target) ? .t : .nilValue
    }

    private static func layerFreeze(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-freeze", args, 1)
        let name = try BuiltinArgs.string("layer-freeze", args[0])
        return await host.setLayerFrozen(name, frozen: true) ? .t : .nilValue
    }

    private static func layerThaw(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-thaw", args, 1)
        let name = try BuiltinArgs.string("layer-thaw", args[0])
        return await host.setLayerFrozen(name, frozen: false) ? .t : .nilValue
    }

    private static func layerLock(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-lock", args, 1)
        let name = try BuiltinArgs.string("layer-lock", args[0])
        return await host.setLayerLocked(name, locked: true) ? .t : .nilValue
    }

    private static func layerUnlock(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-unlock", args, 1)
        let name = try BuiltinArgs.string("layer-unlock", args[0])
        return await host.setLayerLocked(name, locked: false) ? .t : .nilValue
    }

    private static func layerOn(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-on", args, 1)
        let name = try BuiltinArgs.string("layer-on", args[0])
        return await host.setLayerIsOn(name, on: true) ? .t : .nilValue
    }

    private static func layerOff(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-off", args, 1)
        let name = try BuiltinArgs.string("layer-off", args[0])
        return await host.setLayerIsOn(name, on: false) ? .t : .nilValue
    }

    private static func layerFrozenP(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-frozenp", args, 1)
        let name = try BuiltinArgs.string("layer-frozenp", args[0])
        guard let frozen = await host.layerIsFrozen(name) else { return .nilValue }
        return frozen ? .t : .nilValue
    }

    private static func layerLockedP(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-lockedp", args, 1)
        let name = try BuiltinArgs.string("layer-lockedp", args[0])
        guard let locked = await host.layerIsLocked(name) else { return .nilValue }
        return locked ? .t : .nilValue
    }

    private static func layerOnP(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-onp", args, 1)
        let name = try BuiltinArgs.string("layer-onp", args[0])
        guard let on = await host.layerIsOn(name) else { return .nilValue }
        return on ? .t : .nilValue
    }

    private static func layerNames(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-names", args, 0)
        let names = await host.layerNames()
        guard !names.isEmpty else { return .nilValue }
        return LispValue(stringList: names.sorted())
    }

    private static func layerHistoryDepth(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("layer-history-depth", args, 0)
        return .int(await host.layerHistoryDepth())
    }
}

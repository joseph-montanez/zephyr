import FieldDraftScriptCore
import FieldDraftScriptRuntime
import Foundation

// MARK: - In-memory native host (example only, not in any build target)
//
// What "the engine supports it" means for native FDScript: every call in
// room_native.fdscript lands here as typed FDValues. No DXF group codes,
// no cons lists, no Lisp reader, no emitted text. A production host would
// implement this same FDHost protocol against the live CADDocument
// (create real entities, suspend on getpoint, query the selection set)
// instead of the arrays below.
//
// Covered ops: point/px/py, line/circle/arc/text, polar, getLocation,
// + - * / (binary + unary), == != < <= > >=, strcat, rtos, length,
// ssget (via `selection`), getpoint/entsel (via `ifLet`), princ,
// setvar/getvar. Anything else throws unknownFunction.

final class InMemoryNativeHost: FDHost, @unchecked Sendable {
    struct NativeEntity {
        var handle: String
        var kind: String
        var points: [FDValue]
        var numbers: [Double]
        var text: String
    }

    var entities: [NativeEntity] = []
    var sysvars: [String: FDValue] = [:]
    var output: [String] = []
    var pickedOrigin: FDValue = .point(x: 0, y: 0, z: 0)
    private var nextHandle = 1

    // MARK: - FDHost

    func call(_ name: String, _ args: [FDValue], env: inout FDEnvironment) async throws -> FDValue {
        switch name {
        case "point": return try makePoint(args)
        case "px": return try .number(asPoint(take(args, 0, name), 0, name).0)
        case "py": return try .number(asPoint(take(args, 0, name), 0, name).1)
        case "line":
            guard args.count == 2 else { throw FDRuntimeError.typeMismatch("line needs 2 points") }
            _ = try asPoint(args[0], 0, name); _ = try asPoint(args[1], 1, name)
            return mint("line", points: [args[0], args[1]])
        case "circle":
            guard args.count == 2 else { throw FDRuntimeError.typeMismatch("circle needs center + radius") }
            _ = try asPoint(args[0], 0, name)
            return mint("circle", points: [args[0]], numbers: [try asNumber(args[1], 1, name)])
        case "arc":
            guard args.count == 4 else { throw FDRuntimeError.typeMismatch("arc needs center + radius + start + end") }
            _ = try asPoint(args[0], 0, name)
            return mint("arc", points: [args[0]], numbers: [
                try asNumber(args[1], 1, name),
                try asNumber(args[2], 2, name),
                try asNumber(args[3], 3, name),
            ])
        case "text":
            guard args.count == 3 else { throw FDRuntimeError.typeMismatch("text needs point + height + string") }
            _ = try asPoint(args[0], 0, name)
            return mint("text", points: [args[0]],
                        numbers: [try asNumber(args[1], 1, name)],
                        text: try asString(args[2], 2, name))
        case "polar":
            guard args.count == 3 else { throw FDRuntimeError.typeMismatch("polar needs point + degrees + dist") }
            let (x, y, z) = try asPoint(args[0], 0, name)
            let rad = try asNumber(args[1], 1, name) * .pi / 180
            let d = try asNumber(args[2], 2, name)
            return .point(x: x + d * cos(rad), y: y + d * sin(rad), z: z)
        case "getLocation":
            guard args.count == 1, case let .entity(h) = args[0],
                  let e = entities.first(where: { $0.handle == h }),
                  let first = e.points.first
            else { return .nilValue }
            return first
        case "+", "-", "*", "/": return try arithmetic(name, args)
        case "==": return .bool(args.count == 2 && args[0] == args[1])
        case "!=": return .bool(args.count == 2 && args[0] != args[1])
        case "<", "<=", ">", ">=": return try comparison(name, args)
        case "strcat":
            return try .string(args.map { v in
                guard case let .string(s) = v else {
                    throw FDRuntimeError.typeMismatch("strcat needs strings, got \(describe(v))")
                }
                return s
            }.joined())
        case "rtos":
            guard args.count == 1 else { throw FDRuntimeError.typeMismatch("rtos needs 1 number") }
            return .string(pretty(try asNumber(args[0], 0, name)))
        case "length":
            guard args.count == 1, case let .list(items) = args[0] else {
                throw FDRuntimeError.typeMismatch("length needs a list")
            }
            return .number(Double(items.count))
        case "ssget":
            // Native selection: first-class entity handles, not a pick set.
            return .list(entities.map { .entity($0.handle) })
        case "getpoint": return pickedOrigin
        case "entsel": return entities.first.map { .entity($0.handle) } ?? .nilValue
        case "princ":
            guard let first = args.first else { return .nilValue }
            output.append(describe(first))
            return first
        case "setvar":
            guard args.count == 2, case let .string(key) = args[0] else {
                throw FDRuntimeError.typeMismatch("setvar needs a name + value")
            }
            sysvars[key] = args[1]
            return args[1]
        case "getvar":
            guard args.count == 1, case let .string(key) = args[0] else {
                throw FDRuntimeError.typeMismatch("getvar needs a name")
            }
            return sysvars[key] ?? .nilValue
        default: throw FDRuntimeError.unknownFunction(name)
        }
    }

    // MARK: - Helpers

    private func mint(_ kind: String, points: [FDValue] = [], numbers: [Double] = [], text: String = "") -> FDValue {
        let h = "H\(nextHandle)"; nextHandle += 1
        entities.append(NativeEntity(handle: h, kind: kind, points: points, numbers: numbers, text: text))
        return .entity(h)
    }

    private func arithmetic(_ name: String, _ args: [FDValue]) throws -> FDValue {
        if args.count == 1, name == "-" { return .number(-(try asNumber(args[0], 0, name))) }
        guard args.count == 2 else { throw FDRuntimeError.typeMismatch("\(name) needs 2 numbers") }
        let l = try asNumber(args[0], 0, name), r = try asNumber(args[1], 1, name)
        switch name {
        case "+": return .number(l + r)
        case "-": return .number(l - r)
        case "*": return .number(l * r)
        case "/":
            guard r != 0 else { throw FDRuntimeError.divisionByZero }
            return .number(l / r)
        default: throw FDRuntimeError.unknownFunction(name)
        }
    }

    private func comparison(_ name: String, _ args: [FDValue]) throws -> FDValue {
        guard args.count == 2 else { throw FDRuntimeError.typeMismatch("\(name) needs 2 numbers") }
        let l = try asNumber(args[0], 0, name), r = try asNumber(args[1], 1, name)
        switch name {
        case "<": return .bool(l < r)
        case "<=": return .bool(l <= r)
        case ">": return .bool(l > r)
        case ">=": return .bool(l >= r)
        default: throw FDRuntimeError.unknownFunction(name)
        }
    }

    private func asNumber(_ v: FDValue, _ i: Int, _ what: String) throws -> Double {
        guard case let .number(n) = v else {
            throw FDRuntimeError.typeMismatch("\(what) arg \(i) needs a number, got \(describe(v))")
        }
        return n
    }

    private func makePoint(_ args: [FDValue]) throws -> FDValue {
        guard args.count == 3 else { throw FDRuntimeError.typeMismatch("point needs x, y, z") }
        return .point(x: try asNumber(args[0], 0, "point"),
                      y: try asNumber(args[1], 1, "point"),
                      z: try asNumber(args[2], 2, "point"))
    }

    private func take(_ args: [FDValue], _ i: Int, _ what: String) throws -> FDValue {
        guard args.indices.contains(i) else { throw FDRuntimeError.typeMismatch("\(what) needs arg \(i)") }
        return args[i]
    }

    private func asPoint(_ v: FDValue, _ i: Int, _ what: String) throws -> (Double, Double, Double) {
        guard case let .point(x, y, z) = v else {
            throw FDRuntimeError.typeMismatch("\(what) arg \(i) needs a point")
        }
        return (x, y, z)
    }

    private func asString(_ v: FDValue, _ i: Int, _ what: String) throws -> String {
        guard case let .string(s) = v else {
            throw FDRuntimeError.typeMismatch("\(what) arg \(i) needs a string, got \(describe(v))")
        }
        return s
    }

    private func pretty(_ n: Double) -> String {
        n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
    }

    func describe(_ v: FDValue) -> String {
        switch v {
        case .nilValue: return "nil"
        case let .bool(b): return b ? "T" : "nil"
        case let .number(n): return pretty(n)
        case let .string(s): return s
        case let .point(x, y, z): return "(\(pretty(x)),\(pretty(y)),\(pretty(z)))"
        case let .list(items): return "(\(items.map(describe).joined(separator: " ")))"
        case let .entity(h): return "<\(h)>"
        }
    }
}

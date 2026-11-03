// LispEvaluator: async tree-walking evaluator with dynamic scope.
//
// Evaluation is async throughout so effect builtins (input, commands) can
// suspend; pure code runs straight through with no suspension cost beyond
// the call itself. Unbound symbols evaluate to nil (AutoLISP); unbound
// function calls are errors. Recursion deeper than maxDepth throws
// .stackOverflow instead of crashing the host stack.
import Foundation

/// One builtin: evaluated args in, value out. Receives the evaluator for
/// eval/apply recursion, the environment for binding forms, and the host
/// for effects. Throws LispError (and only LispError) on failure.
public typealias LispBuiltin = @Sendable (
    LispEvaluator, [LispValue], inout LispEnvironment, any LispHost
) async throws -> LispValue

/// The evaluator. Stateless apart from configuration: all dynamic state
/// lives in the inout environment.
public struct LispEvaluator: Sendable {
    public let maxDepth: Int

    public init(maxDepth: Int = 1000) {
        self.maxDepth = maxDepth
    }

    // MARK: - Builtin table (single source for dispatch + coverage)

    public static let builtins: [String: LispBuiltin] = MathBuiltins.table
        .merging(ListBuiltins.table) { first, _ in first }
        .merging(StringBuiltins.table) { first, _ in first }
        .merging(LogicBuiltins.table) { first, _ in first }
        .merging(ConvertBuiltins.table) { first, _ in first }
        .merging(SystemBuiltins.table) { first, _ in first }
        .merging(HostBuiltins.table) { first, _ in first }
        .merging(VlaBuiltins.table) { first, _ in first }
        .merging(FileBuiltins.table) { first, _ in first }
        .merging(DictBuiltins.table) { first, _ in first }
        .merging(TableBuiltins.table) { first, _ in first }
        .merging(PropBuiltins.table) { first, _ in first }
        .merging(EnvBuiltins.table) { first, _ in first }
        .merging(VlFileBuiltins.table) { first, _ in first }
        .merging(VlRegistryBuiltins.table) { first, _ in first }
        .merging(VlSessionBuiltins.table) { first, _ in first }
        .merging(StubBuiltins.table) { first, _ in first }
        .merging(MiscCBuiltins.table) { first, _ in first }
        .merging(GraphicsBuiltins.table) { first, _ in first }
        .merging(DialogBuiltins.table) { first, _ in first }
        .merging(LayerStateBuiltins.table) { first, _ in first }
        .merging(LayerBuiltins.table) { first, _ in first }

    public static func knows(_ name: String) -> Bool {
        builtins[name] != nil
    }

    // MARK: - Top level

    /// Evaluates forms in order with *error* routing. Returns the last value.
    /// Non-fatal errors run *error* (when defined) and are swallowed;
    /// userCancel and quitRequested always propagate to the driver, as do
    /// errors with no *error* defined.
    public func run(
        _ forms: [LispValue], env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        var last: LispValue = .nilValue
        do {
            for form in forms {
                last = try await eval(form, env: &env, host: host, depth: 0)
            }
            return last
        } catch let error as LispError {
            if case .quitRequested = error { throw error }
            if case let .exitWithValue(value) = error { return value }
            if env.functions["*ERROR*"] != nil {
                guard env.errorHandlerDepth < 5 else {
                    throw LispError.errorHandlerFailed("recursive *error* invocation")
                }
                env.errorHandlerDepth += 1
                defer { env.errorHandlerDepth -= 1 }
                do {
                    _ = try await callFunction(
                        env.functions["*ERROR*"]!, args: [.string(error.description)],
                        env: &env, host: host, depth: 0)
                } catch let inner as LispError {
                    throw LispError.errorHandlerFailed(inner.description)
                }
                if case .userCancel = error { throw error }
                return .nilValue
            }
            throw error
        }
    }

    // MARK: - Eval / apply

    public func eval(
        _ form: LispValue, env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        switch form {
        case .nilValue, .int, .real, .string, .entityName, .selectionSet, .errorObject, .vlaObject:
            return form
        case let .symbol(name):
            // Unbound symbols are nil (boundp tests definedness).
            return env.lookup(name) ?? .nilValue
        case .cons:
            guard depth < maxDepth else { throw LispError.stackOverflow }
            return try await evalCall(form, env: &env, host: host, depth: depth)
        }
    }

    private func evalCall(
        _ form: LispValue, env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard case let .cons(head, tail) = form, let rawArgs = tail.properList else {
            throw LispError.typeMismatch(name: "eval", expected: "proper list", got: form)
        }
        switch head {
        case let .symbol(name):
            if let special = specialForm(name) {
                return try await special(self, rawArgs, &env, host, depth)
            }
            let args = try await evalArgs(rawArgs, env: &env, host: host, depth: depth)
            return try await applySymbol(name, args: args, env: &env, host: host, depth: depth)
        case .cons:
            // Direct lambda application: ((lambda (x) ...) args).
            let args = try await evalArgs(rawArgs, env: &env, host: host, depth: depth)
            return try await applyValue(head, args: args, env: &env, host: host, depth: depth)
        default:
            throw LispError.typeMismatch(name: "eval", expected: "function name", got: head)
        }
    }

    private func evalArgs(
        _ rawArgs: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> [LispValue] {
        var out: [LispValue] = []
        out.reserveCapacity(rawArgs.count)
        for raw in rawArgs {
            out.append(try await eval(raw, env: &env, host: host, depth: depth + 1))
        }
        return out
    }

    /// Applies a function designator (symbol, lambda list, or quoted name)
    /// to already-evaluated args. Shared by eval, apply, and mapcar.
    public func applyValue(
        _ fn: LispValue, args: [LispValue], env: inout LispEnvironment,
        host: any LispHost, depth: Int
    ) async throws -> LispValue {
        switch fn {
        case let .symbol(name):
            return try await applySymbol(name, args: args, env: &env, host: host, depth: depth)
        case .cons:
            guard let items = fn.properList, items.count >= 2,
                case .symbol("LAMBDA") = items[0],
                let params = items[1].properList
            else {
                throw LispError.typeMismatch(name: "apply", expected: "function designator", got: fn)
            }
            let paramNames = try paramNames(params, context: "lambda")
            return try await callBody(
                params: paramNames, locals: [], body: Array(items.dropFirst(2)),
                args: args, env: &env, host: host, depth: depth)
        default:
            throw LispError.typeMismatch(name: "apply", expected: "function designator", got: fn)
        }
    }

    private func applySymbol(
        _ name: String, args: [LispValue], env: inout LispEnvironment,
        host: any LispHost, depth: Int
    ) async throws -> LispValue {
        if let builtin = Self.builtins[name] {
            return try await builtin(self, args, &env, host)
        }
        if let fn = env.functions[name] {
            return try await callTracedFunction(
                name, fn: fn, args: args, env: &env, host: host, depth: depth)
        }
        // Autoload: load the registered file once, then retry (regress-guarded).
        if let path = env.autoloadStubs[name], !env.autoloadInProgress.contains(name) {
            env.autoloadInProgress.insert(name)
            defer { env.autoloadInProgress.remove(name) }
            do {
                _ = try await load(path: path, env: &env, host: host)
            } catch {
                throw LispError.unboundFunction(name)
            }
            if let fn = env.functions[name] {
                return try await callTracedFunction(
                    name, fn: fn, args: args, env: &env, host: host, depth: depth)
            }
        }
        throw LispError.unboundFunction(name)
    }

    /// User-function call with trace/untrace support: traced names print
    /// entry arguments and the result via the host output sink.
    private func callTracedFunction(
        _ name: String, fn: LispFunction, args: [LispValue], env: inout LispEnvironment,
        host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard env.tracedFunctions.contains(name) else {
            return try await callFunction(fn, args: args, env: &env, host: host, depth: depth)
        }
        let shown = args.map(\.displayString).joined(separator: " ")
        await host.write("Entering \(name) \(shown)\n")
        let result = try await callFunction(fn, args: args, env: &env, host: host, depth: depth)
        await host.write("Result of \(name): \(result.displayString)\n")
        return result
    }

    func callFunction(
        _ fn: LispFunction, args: [LispValue], env: inout LispEnvironment,
        host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard depth < maxDepth else { throw LispError.stackOverflow }
        guard args.count == fn.params.count else {
            throw LispError.arity(name: "function", expected: "\(fn.params.count)", got: args.count)
        }
        return try await callBody(
            params: fn.params, locals: fn.locals, body: fn.body,
            args: args, env: &env, host: host, depth: depth)
    }

    private func callBody(
        params: [String], locals: [String], body: [LispValue], args: [LispValue],
        env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        env.pushFrame(params: params, args: args, locals: locals)
        defer { env.popFrame() }
        var last: LispValue = .nilValue
        for form in body {
            last = try await eval(form, env: &env, host: host, depth: depth + 1)
        }
        return last
    }

    // MARK: - Special forms (unevaluated args)

    private typealias SpecialForm =
        @Sendable (LispEvaluator, [LispValue], inout LispEnvironment, any LispHost, Int) async throws -> LispValue

    private func specialForm(_ name: String) -> SpecialForm? {
        switch name {
        case "QUOTE": return { eval, args, env, _, _ in try eval.specialQuote(args) }
        case "IF": return { eval, args, env, host, depth in try await eval.specialIf(args, env: &env, host: host, depth: depth) }
        case "COND": return { eval, args, env, host, depth in try await eval.specialCond(args, env: &env, host: host, depth: depth) }
        case "WHILE": return { eval, args, env, host, depth in try await eval.specialWhile(args, env: &env, host: host, depth: depth) }
        case "REPEAT": return { eval, args, env, host, depth in try await eval.specialRepeat(args, env: &env, host: host, depth: depth) }
        case "FOREACH": return { eval, args, env, host, depth in try await eval.specialForeach(args, env: &env, host: host, depth: depth) }
        case "PROGN": return { eval, args, env, host, depth in try await eval.specialProgn(args, env: &env, host: host, depth: depth) }
        case "SETQ": return { eval, args, env, host, depth in try await eval.specialSetq(args, env: &env, host: host, depth: depth) }
        case "SET": return { eval, args, env, host, depth in try await eval.specialSet(args, env: &env, host: host, depth: depth) }
        case "DEFUN": return { eval, args, env, _, _ in try eval.specialDefun(args, quoted: false, env: &env) }
        case "DEFUN-Q": return { eval, args, env, _, _ in try eval.specialDefun(args, quoted: true, env: &env) }
        case "LAMBDA": return { _, args, _, _, _ in .cons(head: .symbol("LAMBDA"), tail: LispValue(list: args)) }
        case "AND": return { eval, args, env, host, depth in try await eval.specialAnd(args, env: &env, host: host, depth: depth) }
        case "OR": return { eval, args, env, host, depth in try await eval.specialOr(args, env: &env, host: host, depth: depth) }
        default: return nil
        }
    }

    private func specialQuote(_ args: [LispValue]) throws -> LispValue {
        guard args.count == 1 else {
            throw LispError.arity(name: "quote", expected: "1", got: args.count)
        }
        return args[0]
    }

    private func specialIf(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard args.count == 2 || args.count == 3 else {
            throw LispError.arity(name: "if", expected: "2 or 3", got: args.count)
        }
        let test = try await eval(args[0], env: &env, host: host, depth: depth + 1)
        if test.isTrue {
            return try await eval(args[1], env: &env, host: host, depth: depth + 1)
        }
        if args.count == 3 {
            return try await eval(args[2], env: &env, host: host, depth: depth + 1)
        }
        return .nilValue
    }

    private func specialCond(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        for clause in args {
            guard let items = clause.properList, !items.isEmpty else {
                throw LispError.typeMismatch(name: "cond", expected: "non-empty clause", got: clause)
            }
            let test = try await eval(items[0], env: &env, host: host, depth: depth + 1)
            if test.isTrue {
                // Test-only clause yields the test value.
                if items.count == 1 { return test }
                var last: LispValue = .nilValue
                for form in items.dropFirst() {
                    last = try await eval(form, env: &env, host: host, depth: depth + 1)
                }
                return last
            }
        }
        return .nilValue
    }

    private func specialWhile(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard !args.isEmpty else {
            throw LispError.arity(name: "while", expected: "1 or more", got: 0)
        }
        var last: LispValue = .nilValue
        while try await eval(args[0], env: &env, host: host, depth: depth + 1).isTrue {
            for form in args.dropFirst() {
                last = try await eval(form, env: &env, host: host, depth: depth + 1)
            }
        }
        return last
    }

    private func specialRepeat(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard !args.isEmpty else {
            throw LispError.arity(name: "repeat", expected: "1 or more", got: 0)
        }
        let count = try await eval(args[0], env: &env, host: host, depth: depth + 1)
        let times: Int = {
            switch count {
            case let .int(v): return max(0, v)
            case let .real(v): return max(0, Int(v))
            default: return 0
            }
        }()
        var last: LispValue = .nilValue
        for _ in 0..<times {
            for form in args.dropFirst() {
                last = try await eval(form, env: &env, host: host, depth: depth + 1)
            }
        }
        return last
    }

    private func specialForeach(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard args.count >= 2, case let .symbol(name) = args[0] else {
            throw LispError.arity(name: "foreach", expected: "(symbol list body...)", got: args.count)
        }
        let listValue = try await eval(args[1], env: &env, host: host, depth: depth + 1)
        guard let items = listValue.properList else {
            throw LispError.typeMismatch(name: "foreach", expected: "list", got: listValue)
        }
        var last: LispValue = .nilValue
        for item in items {
            env.pushFrame(params: [name], args: [item], locals: [])
            for form in args.dropFirst(2) {
                last = try await eval(form, env: &env, host: host, depth: depth + 1)
            }
            env.popFrame()
        }
        return last
    }

    private func specialProgn(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        var last: LispValue = .nilValue
        for form in args {
            last = try await eval(form, env: &env, host: host, depth: depth + 1)
        }
        return last
    }

    private func specialSetq(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard !args.isEmpty, args.count % 2 == 0 else {
            throw LispError.arity(name: "setq", expected: "even", got: args.count)
        }
        var last: LispValue = .nilValue
        var index = 0
        while index < args.count {
            if args[index].isNil {
                throw LispError.protectedSymbol("NIL")
            }
            guard case let .symbol(name) = args[index] else {
                throw LispError.typeMismatch(name: "setq", expected: "symbol", got: args[index])
            }
            let value = try await eval(args[index + 1], env: &env, host: host, depth: depth + 1)
            last = try env.assign(name, value)
            index += 2
        }
        return last
    }

    private func specialSet(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        guard args.count == 2 else {
            throw LispError.arity(name: "set", expected: "2", got: args.count)
        }
        let nameValue = try await eval(args[0], env: &env, host: host, depth: depth + 1)
        if nameValue.isNil {
            throw LispError.protectedSymbol("NIL")
        }
        guard case let .symbol(name) = nameValue else {
            throw LispError.typeMismatch(name: "set", expected: "symbol", got: nameValue)
        }
        let value = try await eval(args[1], env: &env, host: host, depth: depth + 1)
        return try env.assign(name, value)
    }

    private func specialDefun(_ args: [LispValue], quoted: Bool, env: inout LispEnvironment) throws -> LispValue {
        guard args.count >= 2, case let .symbol(name) = args[0],
            let arglist = args[1].properList
        else {
            throw LispError.arity(name: quoted ? "defun-q" : "defun", expected: "(name (args) body...)", got: args.count)
        }
        var params: [String] = []
        var locals: [String] = []
        var seenSlash = false
        for item in arglist {
            guard case let .symbol(param) = item else {
                throw LispError.typeMismatch(name: "defun", expected: "parameter symbol", got: item)
            }
            if param == "/" {
                seenSlash = true
                continue
            }
            if seenSlash { locals.append(param) } else { params.append(param) }
        }
        let body = Array(args.dropFirst(2))
        let quotedForm: LispValue? = quoted
            ? LispValue(list: [.symbol(name), args[1]] + body) : nil
        env.functions[name] = LispFunction(params: params, locals: locals, body: body, quotedForm: quotedForm)
        return .symbol(name)
    }

    private func specialAnd(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        var last: LispValue = .t
        for form in args {
            last = try await eval(form, env: &env, host: host, depth: depth + 1)
            if !last.isTrue { return .nilValue }
        }
        return last
    }

    private func specialOr(
        _ args: [LispValue], env: inout LispEnvironment, host: any LispHost, depth: Int
    ) async throws -> LispValue {
        for form in args {
            let value = try await eval(form, env: &env, host: host, depth: depth + 1)
            if value.isTrue { return value }
        }
        return .nilValue
    }

    // MARK: - Shared builtin helpers

    func paramNames(_ params: [LispValue], context: String) throws -> [String] {
        var out: [String] = []
        for param in params {
            guard case let .symbol(name) = param else {
                throw LispError.typeMismatch(name: context, expected: "parameter symbol", got: param)
            }
            out.append(name)
        }
        return out
    }

    /// load: reads a file, evaluates every form, returns the file path.
    /// Appends .lsp when the path has no extension.
    public func load(
        path: String, env: inout LispEnvironment, host: any LispHost
    ) async throws -> LispValue {
        var candidates = [path]
        if !path.contains(".") { candidates.append(path + ".lsp") }
        var source: String?
        var resolved = path
        for candidate in candidates {
            if let text = try? String(contentsOfFile: candidate, encoding: .utf8) {
                source = text
                resolved = candidate
                break
            }
        }
        guard let source else {
            throw LispError.hostError("cannot open file: \(path)")
        }
        let forms = try LispReader().readAll(source)
        _ = try await run(forms, env: &env, host: host)
        return .string(resolved)
    }
}

// StringBuiltins: string construction, inspection, and vl-string utilities.
//
// Substrings are 1-based with clamped bounds; strcase uppercases by default
// and lowercases with a non-nil second arg; wcmatch is case-insensitive.
import Foundation

enum StringBuiltins {
    static let table: [String: LispBuiltin] = [
        "STRCAT": strcat,
        "STRLEN": strlen,
        "SUBSTR": substr,
        "STRCASE": strcase,
        "ASCII": ascii,
        "CHR": chr,
        "ITOA": itoa,
        "ATOI": atoi,
        "ATOF": atof,
        "WCMATCH": wcmatch,
        "ACAD_STRLSORT": acadStrlsort,
        "VL-STRING->LIST": vlStringToList,
        "VL-STRING-ELT": vlStringElt,
        "VL-STRING-POSITION": vlStringPosition,
        "VL-STRING-SEARCH": vlStringSearch,
        "VL-STRING-SUBST": vlStringSubst,
        "VL-STRING-TRIM": vlStringTrim,
        "VL-STRING-LEFT-TRIM": vlStringTrimSide(left: true),
        "VL-STRING-RIGHT-TRIM": vlStringTrimSide(left: false),
        "VL-STRING-MISMATCH": vlStringMismatch,
        "VL-STRING-TRANSLATE": vlStringTranslate,
        "VL-PRIN1-TO-STRING": vlPrin1ToString,
        "VL-PRINC-TO-STRING": vlPrincToString,
        "SNVALID": snvalid,
    ]

    // MARK: - Core

    private static func strcat(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        var out = ""
        for arg in args { out += try BuiltinArgs.string("strcat", arg) }
        return .string(out)
    }

    private static func strlen(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("strlen", args, 1)
        return .int(try BuiltinArgs.string("strlen", args[0]).count)
    }

    private static func substr(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("substr", args, min: 2, max: 3)
        let text = try BuiltinArgs.string("substr", args[0])
        let chars = Array(text)
        var start = try BuiltinArgs.int("substr", args[1])
        start = max(1, start) // 1-based, clamped.
        guard start <= chars.count else { return .string("") }
        let maxLength = chars.count - start + 1
        let length: Int = {
            guard args.count == 3, case let .int(n) = args[2] else { return maxLength }
            return n
        }()
        guard length > 0 else { return .string("") }
        let end = min(chars.count, start - 1 + length)
        return .string(String(chars[(start - 1)..<end]))
    }

    private static func strcase(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("strcase", args, min: 1, max: 2)
        let text = try BuiltinArgs.string("strcase", args[0])
        if args.count == 2, args[1].isTrue { return .string(text.lowercased()) }
        return .string(text.uppercased())
    }

    private static func ascii(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("ascii", args, 1)
        let text = try BuiltinArgs.string("ascii", args[0])
        guard let first = text.unicodeScalars.first else { return .int(0) }
        return .int(Int(first.value))
    }

    private static func chr(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("chr", args, 1)
        let code = try BuiltinArgs.int("chr", args[0])
        guard code >= 0, let scalar = UnicodeScalar(code) else {
            throw LispError.typeMismatch(name: "chr", expected: "char code", got: args[0])
        }
        return .string(String(scalar))
    }

    private static func itoa(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("itoa", args, 1)
        return .string(String(try BuiltinArgs.int("itoa", args[0])))
    }

    /// C-like leading-number scan shared by atoi/atof.
    static func scanNumberPrefix(_ text: String) -> (head: String, isReal: Bool) {
        var head = ""
        var index = text.startIndex
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
        if index < text.endIndex, text[index] == "+" || text[index] == "-" {
            head.append(text[index])
            index = text.index(after: index)
        }
        var sawDigit = false
        var isReal = false
        while index < text.endIndex, text[index].isWholeNumber {
            sawDigit = true
            head.append(text[index])
            index = text.index(after: index)
        }
        if index < text.endIndex, text[index] == "." {
            let afterDot = text.index(after: index)
            if afterDot < text.endIndex, text[afterDot].isWholeNumber {
                isReal = true
                head.append(text[index])
                index = afterDot
                while index < text.endIndex, text[index].isWholeNumber {
                    head.append(text[index])
                    index = text.index(after: index)
                }
            }
        }
        if sawDigit, index < text.endIndex, text[index] == "e" || text[index] == "E" {
            var probe = text.index(after: index)
            if probe < text.endIndex, text[probe] == "+" || text[probe] == "-" {
                probe = text.index(after: probe)
            }
            if probe < text.endIndex, text[probe].isWholeNumber {
                isReal = true
                head.append(text[index])
                index = text.index(after: index)
                if text[index] == "+" || text[index] == "-" {
                    head.append(text[index])
                    index = text.index(after: index)
                }
                while index < text.endIndex, text[index].isWholeNumber {
                    head.append(text[index])
                    index = text.index(after: index)
                }
            }
        }
        guard sawDigit else { return ("", false) }
        return (head, isReal)
    }

    private static func atoi(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("atoi", args, 1)
        let text = try BuiltinArgs.string("atoi", args[0])
        let (head, _) = scanNumberPrefix(text)
        // atoi stops at the dot: truncate any fraction.
        let intHead = head.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return .int(LispValue.wrap32(Int(intHead) ?? 0))
    }

    private static func atof(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("atof", args, 1)
        let text = try BuiltinArgs.string("atof", args[0])
        let (head, _) = scanNumberPrefix(text)
        let value = Double(head) ?? 0.0
        if value.isInfinite {
            return .real(head.hasPrefix("-") ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude)
        }
        return .real(value)
    }

    // MARK: - Wildcard match (case-insensitive)

    private static func wcmatch(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("wcmatch", args, 2)
        let text = try BuiltinArgs.string("wcmatch", args[0]).uppercased()
        let pattern = try BuiltinArgs.string("wcmatch", args[1]).uppercased()
        return .tOrNil(Wildcard.matchAlternatives(text: Array(text), pattern: pattern))
    }

    private static func acadStrlsort(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("acad_strlsort", args, 1)
        let items = try BuiltinArgs.properList("acad_strlsort", args[0])
        var strings: [String] = []
        for item in items { strings.append(try BuiltinArgs.string("acad_strlsort", item)) }
        return LispValue(stringList: strings.sorted())
    }

    // MARK: - vl-string utilities

    private static func vlStringToList(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vl-string->list", args, 1)
        let text = try BuiltinArgs.string("vl-string->list", args[0])
        return LispValue(list: text.unicodeScalars.map { LispValue.int(Int($0.value)) })
    }

    private static func vlStringElt(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vl-string-elt", args, 2)
        let text = try BuiltinArgs.string("vl-string-elt", args[0])
        let index = try BuiltinArgs.int("vl-string-elt", args[1])
        let scalars = Array(text.unicodeScalars)
        guard index >= 0, index < scalars.count else { return .nilValue }
        return .int(Int(scalars[index].value))
    }

    private static func vlStringPosition(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("vl-string-position", args, min: 2, max: 4)
        let code = try BuiltinArgs.int("vl-string-position", args[0])
        let text = try BuiltinArgs.string("vl-string-position", args[1])
        let scalars = Array(text.unicodeScalars)
        var start = 0
        if args.count >= 3 { start = max(0, try BuiltinArgs.int("vl-string-position", args[2])) }
        let fromEnd = args.count == 4 ? args[3].isTrue : false
        let target = UnicodeScalar(code).map(Character.init)
        if fromEnd {
            for index in stride(from: scalars.count - 1, through: start, by: -1) {
                if Character(scalars[index]) == target { return .int(index) }
            }
            return .nilValue
        }
        for index in start..<scalars.count {
            if Character(scalars[index]) == target { return .int(index) }
        }
        return .nilValue
    }

    private static func vlStringSearch(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("vl-string-search", args, min: 2, max: 3)
        let pattern = try BuiltinArgs.string("vl-string-search", args[0])
        let text = try BuiltinArgs.string("vl-string-search", args[1])
        var start = 0
        if args.count == 3 { start = max(0, try BuiltinArgs.int("vl-string-search", args[2])) }
        // Case-sensitive substring search over scalar indices.
        let hay = Array(text.unicodeScalars)
        let needle = Array(pattern.unicodeScalars)
        guard !needle.isEmpty, start + needle.count <= hay.count else { return .nilValue }
        for index in start...(hay.count - needle.count) {
            if hay[index..<(index + needle.count)].elementsEqual(needle) { return .int(index) }
        }
        return .nilValue
    }

    private static func vlStringSubst(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("vl-string-subst", args, min: 3, max: 4)
        let replacement = try BuiltinArgs.string("vl-string-subst", args[0])
        let pattern = try BuiltinArgs.string("vl-string-subst", args[1])
        let text = try BuiltinArgs.string("vl-string-subst", args[2])
        var start = 0
        if args.count == 4 { start = max(0, try BuiltinArgs.int("vl-string-subst", args[3])) }
        guard !pattern.isEmpty else { return .string(text) }
        let chars = Array(text)
        let needle = Array(pattern)
        guard start + needle.count <= chars.count else { return .string(text) }
        for index in start...(chars.count - needle.count) {
            if Array(chars[index..<(index + needle.count)]) == needle {
                return .string(String(chars[..<index]) + replacement + String(chars[(index + needle.count)...]))
            }
        }
        return .string(text)
    }

    private static func vlStringTrim(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vl-string-trim", args, 2)
        return .string(trim(try BuiltinArgs.string("vl-string-trim", args[1]),
            strip: try BuiltinArgs.string("vl-string-trim", args[0]),
            left: true, right: true))
    }

    private static func vlStringTrimSide(left: Bool) -> LispBuiltin {
        let name = left ? "vl-string-left-trim" : "vl-string-right-trim"
        return { _, args, _, _ in
            try BuiltinArgs.exactly(name, args, 2)
            return .string(trim(try BuiltinArgs.string(name, args[1]),
                strip: try BuiltinArgs.string(name, args[0]),
                left: left, right: !left))
        }
    }

    private static func trim(_ text: String, strip: String, left: Bool, right: Bool) -> String {
        let set = Set(strip)
        var chars = Array(text)
        if left {
            while let first = chars.first, set.contains(first) { chars.removeFirst() }
        }
        if right {
            while let last = chars.last, set.contains(last) { chars.removeLast() }
        }
        return String(chars)
    }

    /// First-differing scalar index, or T when the compared spans match.
    private static func vlStringMismatch(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("vl-string-mismatch", args, min: 2, max: 4)
        let first = Array(try BuiltinArgs.string("vl-string-mismatch", args[0]).unicodeScalars)
        let second = Array(try BuiltinArgs.string("vl-string-mismatch", args[1]).unicodeScalars)
        var start1 = 0
        var start2 = 0
        if args.count >= 3 { start1 = max(0, try BuiltinArgs.int("vl-string-mismatch", args[2])) }
        if args.count == 4 { start2 = max(0, try BuiltinArgs.int("vl-string-mismatch", args[3])) }
        var offset = 0
        while start1 + offset < first.count, start2 + offset < second.count {
            if first[start1 + offset] != second[start2 + offset] {
                return .int(start1 + offset)
            }
            offset += 1
        }
        if start1 + offset == first.count, start2 + offset == second.count { return .t }
        return .int(start1 + offset)
    }

    private static func vlStringTranslate(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vl-string-translate", args, 3)
        let source = Array(try BuiltinArgs.string("vl-string-translate", args[0]))
        let dest = Array(try BuiltinArgs.string("vl-string-translate", args[1]))
        let text = try BuiltinArgs.string("vl-string-translate", args[2])
        guard source.count == dest.count else {
            throw LispError.typeMismatch(
                name: "vl-string-translate", expected: "equal-length char sets", got: args[1])
        }
        let map = Dictionary(uniqueKeysWithValues: zip(source, dest))
        return .string(String(text.map { map[$0] ?? $0 }))
    }

    private static func vlPrin1ToString(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vl-prin1-to-string", args, 1)
        return .string(args[0].prin1String)
    }

    private static func vlPrincToString(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.exactly("vl-princ-to-string", args, 1)
        return .string(args[0].displayString)
    }

    /// Symbol-name validity: non-empty, starts with a letter, then
    /// letters/digits/underscore/hyphen/dollar (first char not a digit).
    private static func snvalid(
        _: LispEvaluator, args: [LispValue], _: inout LispEnvironment, _: any LispHost
    ) async throws -> LispValue {
        try BuiltinArgs.range("snvalid", args, min: 1, max: 2)
        let text = try BuiltinArgs.string("snvalid", args[0])
        // Second arg (table type) accepted and ignored for now.
        guard let first = text.first, first.isLetter else { return .nilValue }
        for ch in text {
            if ch.isLetter || ch.isWholeNumber || ch == "_" || ch == "-" || ch == "$" { continue }
            return .nilValue
        }
        return .t
    }
}

// MARK: - Wildcard engine (* ? @ # . ~ [...] with comma alternation)

enum Wildcard {
    static func matchAlternatives(text: [Character], pattern: String) -> Bool {
        // Top-level comma split (no nesting: brackets never contain commas here).
        for alternative in pattern.split(separator: ",", omittingEmptySubsequences: false) {
            if matchOne(text: text, pattern: Array(alternative)) { return true }
        }
        return false
    }

    private static func matchOne(text: [Character], pattern: [Character]) -> Bool {
        var negated = false
        var body = pattern
        if body.first == "~" {
            negated = true
            body = Array(body.dropFirst())
        }
        let matched = match(text: text, textIndex: 0, pattern: body, patternIndex: 0)
        return negated ? !matched : matched
    }

    private static func match(text: [Character], textIndex: Int, pattern: [Character], patternIndex: Int) -> Bool {
        var ti = textIndex
        var pi = patternIndex
        var starTextIndex: Int? = nil
        var starPatternIndex: Int? = nil
        while ti < text.count {
            if pi < pattern.count {
                let p = pattern[pi]
                if p == "*" {
                    starTextIndex = ti
                    pi += 1
                    starPatternIndex = pi
                    continue
                }
                if p == "[" {
                    if let (consumed, matched) = matchClass(text[ti], pattern: pattern, from: pi) {
                        if matched {
                            pi = consumed
                            ti += 1
                            continue
                        }
                    } else {
                        // Malformed class: literal fallthrough handled below.
                    }
                } else if singleMatch(p, text[ti]) {
                    pi += 1
                    ti += 1
                    continue
                }
            }
            // Mismatch: backtrack to the last star, or fail.
            guard let starT = starTextIndex, let starP = starPatternIndex else { return false }
            ti = starT + 1
            starTextIndex = ti
            pi = starP
        }
        while pi < pattern.count, pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }

    private static func singleMatch(_ pattern: Character, _ text: Character) -> Bool {
        switch pattern {
        case "?": return true
        case "#": return text.isWholeNumber
        case "@": return text.isLetter
        case ".": return !text.isLetter && !text.isWholeNumber
        default: return pattern == text
        }
    }

    /// Matches one [...] class at pattern[from]; returns the index just past
    /// ] plus whether the char matched (nil when malformed).
    private static func matchClass(_ ch: Character, pattern: [Character], from: Int) -> (Int, Bool)? {
        var i = from + 1
        var negate = false
        if i < pattern.count, pattern[i] == "~" {
            negate = true
            i += 1
        }
        var matched = false
        var first = true
        while i < pattern.count, pattern[i] != "]" || first {
            first = false
            // Range a-z (a literal - at either end is literal).
            if i + 2 < pattern.count, pattern[i + 1] == "-", pattern[i + 2] != "]" {
                let lo = pattern[i]
                let hi = pattern[i + 2]
                if lo <= ch, ch <= hi { matched = true }
                i += 3
            } else {
                if pattern[i] == ch { matched = true }
                i += 1
            }
        }
        guard i < pattern.count, pattern[i] == "]" else { return nil }
        return (i + 1, negate ? !matched : matched)
    }
}

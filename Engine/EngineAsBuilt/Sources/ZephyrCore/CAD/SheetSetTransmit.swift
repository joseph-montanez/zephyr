import Foundation

// MARK: - SheetSetTransmit
//
// eTransmit-style foreground archive: copy a sheet set (the `.dst` itself
// plus the member drawings in scope) into a package folder, preserving the
// tree under the `.dst` folder and reporting locks, missing files, and
// copy failures per file. Deliberately a subset of LT eTransmit: no bind,
// no xref repathing, no purge, no password — those need LT to verify.
// The `.dst` is copied byte-identical (never re-serialized), so LT-authored
// sections this engine does not model survive the trip untouched.

public enum SheetSetTransmit {
    /// Archive scope. Strict prefix forms only — a bare name is rejected
    /// with usage so a subset and a sheet number can never collide.
    public enum Scope: Sendable, Equatable {
        case all
        case subset(name: String)
        case sheets(numbers: [String])
        case selection(name: String)
    }

    public static let usage =
        "Usage: -TRANSMITSET <file.dst> <folder> [scope] — scope: * | subset:<name> | sheets:<n1,n2> | selection:<name>"

    /// Parse a scope token. `""`/`"*"` selects everything; anything without
    /// a known prefix is nil (usage error, never a guess).
    public static func parseScope(_ text: String) -> Scope? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "*" { return .all }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("subset:") {
            let name = trimmed.dropFirst("subset:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .subset(name: String(name))
        }
        if lower.hasPrefix("sheets:") {
            let list = trimmed.dropFirst("sheets:".count)
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return list.isEmpty ? nil : .sheets(numbers: list)
        }
        if lower.hasPrefix("selection:") {
            let name = trimmed.dropFirst("selection:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .selection(name: String(name))
        }
        return nil
    }

    // MARK: - Plan (pure)

    public struct TransmitFile: Sendable, Equatable {
        /// Absolute source path.
        public var sourcePath: String
        /// Destination path relative to the package root.
        public var relativePath: String
        public var lock: SheetSetLocks.MemberLock
        /// "A-101 Lobby" for member drawings, nil for the `.dst` itself.
        public var sheetLabel: String?
    }

    public struct TransmitPlan: Sendable, Equatable {
        public var setName: String
        public var dstPath: String
        public var dstLocked: Bool
        /// `files[0]` is always the `.dst` itself.
        public var files: [TransmitFile]
        /// Sheet labels (`"A-101 Lobby"`) with no resolvable file.
        public var unresolved: [String]
        /// Non-nil means nothing may transmit (unknown subset/selection/
        /// sheet numbers); the caller fails loudly with this message.
        public var scopeError: String?
    }

    /// Sheets in scope, in display order (loose first, depth-first), plus
    /// labels for selection members that point nowhere (dangling IDs from
    /// an older set surface here instead of vanishing).
    public static func scopeSheets(set: SheetSet, scope: Scope) -> (
        sheets: [SheetSetSheet], unresolved: [String], error: String?
    ) {
        switch scope {
        case .all:
            return (set.allSheetsInOrder, [], nil)
        case .subset(let name):
            guard let found = findSubset(named: name, in: set.subsets) else {
                return ([], [], "Subset '\(name)' not found in '\(set.name)'.")
            }
            return (sheetsOfSubset(found), [], nil)
        case .sheets(let numbers):
            let ordered = set.allSheetsInOrder
            var out: [SheetSetSheet] = []
            var unknown: [String] = []
            for number in numbers {
                if let sheet = ordered.first(where: { $0.number.caseInsensitiveCompare(number) == .orderedSame }) {
                    out.append(sheet)
                } else {
                    unknown.append(number)
                }
            }
            if !unknown.isEmpty {
                return ([], [], "Sheet(s) not found: \(unknown.joined(separator: ", ")).")
            }
            return (out, [], nil)
        case .selection(let name):
            guard let selection = set.selections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                let known = set.selections.map(\.name)
                let hint = known.isEmpty ? "(the set has no saved selections)" : "(known: \(known.joined(separator: ", ")))"
                return ([], [], "Selection '\(name)' not found in '\(set.name)' \(hint).")
            }
            var out: [SheetSetSheet] = []
            var dangling: [String] = []
            for id in selection.sheetIDs {
                if let sheet = set.sheet(id: id) {
                    out.append(sheet)
                } else {
                    dangling.append("selection '\(name)' references unknown sheet '\(id)'")
                }
            }
            return (out, dangling, nil)
        }
    }

    /// Pure plan: resolve scope → files (deduped, tree-preserving dest
    /// paths) with a lock probe per member. `dstLocked` comes from the
    /// caller (`SheetSetStore.lockStatus`); the plan itself is testable.
    public static func plan(set: SheetSet, scope: Scope, dstLocked: Bool) -> TransmitPlan {
        let (sheets, scopeUnresolved, scopeError) = scopeSheets(set: set, scope: scope)
        let dstURL = URL(fileURLWithPath: set.dstPath)
        let dstFolder = dstURL.deletingLastPathComponent().standardized.path
        var files: [TransmitFile] = [TransmitFile(
            sourcePath: set.dstPath,
            relativePath: dstURL.lastPathComponent,
            lock: dstLocked ? .locked(detail: "set lock (.dbl present)") : .available,
            sheetLabel: nil)]
        var unresolved: [String] = []
        var seen = Set<String>([URL(fileURLWithPath: set.dstPath).standardized.path])
        var usedDest = Set<String>([dstURL.lastPathComponent.lowercased()])
        for sheet in sheets {
            let label = "\(sheet.number) \(sheet.title)".trimmingCharacters(in: .whitespaces)
            let raw = sheet.absoluteFile.isEmpty
                ? (sheet.relativeFile.isEmpty ? "" : SheetSetNODHint.resolve(dstPath: sheet.relativeFile, relativeTo: set.dstPath))
                : sheet.absoluteFile
            let standard = raw.isEmpty ? "" : URL(fileURLWithPath: raw).standardized.path
            guard !standard.isEmpty else {
                unresolved.append(label.isEmpty ? "(untitled sheet)" : label)
                continue
            }
            guard seen.insert(standard).inserted else { continue }
            files.append(TransmitFile(
                sourcePath: standard,
                relativePath: destRelative(source: standard, dstFolder: dstFolder, usedDest: &usedDest),
                lock: SheetSetLocks.memberLock(drawingPath: standard),
                sheetLabel: label.isEmpty ? nil : label))
        }
        return TransmitPlan(
            setName: set.name, dstPath: set.dstPath, dstLocked: dstLocked,
            files: files, unresolved: scopeUnresolved + unresolved, scopeError: scopeError)
    }

    // MARK: - Execute (impure)

    public enum FileOutcome: Sendable, Equatable {
        case copied(fromLocked: Bool)
        case skippedMissing
        case failed(reason: String)
    }

    public struct FileResult: Sendable, Equatable {
        public var file: TransmitFile
        public var destPath: String
        public var outcome: FileOutcome
    }

    public struct TransmitReport: Sendable, Equatable {
        public var packageFolder: String
        public var results: [FileResult]

        public var copiedCount: Int {
            results.filter {
                if case .copied = $0.outcome { return true }
                return false
            }.count
        }
    }

    /// Copy every planned file into `folder` (created with intermediates;
    /// existing files are replaced). Missing sources are skipped, copy
    /// failures are recorded — both without aborting the package.
    @discardableResult
    public static func execute(plan: TransmitPlan, to folder: URL) throws -> TransmitReport {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var results: [FileResult] = []
        results.reserveCapacity(plan.files.count)
        for file in plan.files {
            let dest = folder.appendingPathComponent(file.relativePath)
            if file.lock == .missing {
                results.append(FileResult(file: file, destPath: dest.path, outcome: .skippedMissing))
                continue
            }
            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(atPath: file.sourcePath, toPath: dest.path)
                let fromLocked: Bool
                if case .locked = file.lock { fromLocked = true } else { fromLocked = false }
                results.append(FileResult(file: file, destPath: dest.path, outcome: .copied(fromLocked: fromLocked)))
            } catch {
                results.append(FileResult(
                    file: file, destPath: dest.path,
                    outcome: .failed(reason: error.localizedDescription)))
            }
        }
        return TransmitReport(packageFolder: folder.path, results: results)
    }

    // MARK: - Helpers

    private static func findSubset(named name: String, in subsets: [SheetSetSubset]) -> SheetSetSubset? {
        for sub in subsets {
            if sub.name.caseInsensitiveCompare(name) == .orderedSame { return sub }
            if let found = findSubset(named: name, in: sub.subsets) { return found }
        }
        return nil
    }

    private static func sheetsOfSubset(_ subset: SheetSetSubset) -> [SheetSetSheet] {
        var out = subset.sheets
        for child in subset.subsets { out.append(contentsOf: sheetsOfSubset(child)) }
        return out
    }

    private static func destRelative(source: String, dstFolder: String, usedDest: inout Set<String>) -> String {
        let prefix = dstFolder.hasSuffix("/") ? dstFolder : dstFolder + "/"
        if source.hasPrefix(prefix) {
            let rel = String(source.dropFirst(prefix.count))
            usedDest.insert(rel.lowercased())
            return rel
        }
        let url = URL(fileURLWithPath: source)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url.lastPathComponent
        var n = 2
        while usedDest.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        usedDest.insert(candidate.lowercased())
        return candidate
    }
}

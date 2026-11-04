import Foundation

// =========================================================================
// MARK: - Sheet Set Manager view model (Step 8: Sheet List tab)
// -------------------------------------------------------------------------
// Pure, UI-toolkit-free projection of a `SheetSet` into flat tree rows +
// detail lines. `SheetSetManagerUI` renders these with ImGui; the tests
// pin them here. Sheet Views / Model Views tabs arrive later and reuse
// the same row shape.
// =========================================================================

public enum SheetSetRowKind: Sendable, Equatable {
    case sheet
    case subset
}

/// One flat tree row. Subset rows render as collapsing headers (their
/// sheets follow at `depth + 1`); sheet rows render as selectables.
public struct SheetSetTreeRow: Sendable, Equatable {
    public var kind: SheetSetRowKind
    public var depth: Int
    public var sheetID: String?
    public var title: String
    public var subtitle: String

    public init(kind: SheetSetRowKind, depth: Int, sheetID: String? = nil, title: String, subtitle: String = "") {
        self.kind = kind
        self.depth = depth
        self.sheetID = sheetID
        self.title = title
        self.subtitle = subtitle
    }
}

public enum SheetSetManagerViewModel {
    /// Flat rows in set display order (loose sheets, then subsets depth-first).
    public static func rows(for set: SheetSet) -> [SheetSetTreeRow] {
        var out: [SheetSetTreeRow] = []
        for sheet in set.sheets {
            out.append(sheetRow(sheet, depth: 0))
        }
        func walk(_ subsets: [SheetSetSubset], depth: Int) {
            for sub in subsets {
                var title = "[\(sub.name)]"
                if !sub.publishSheets { title += " [publish off]" }
                out.append(SheetSetTreeRow(kind: .subset, depth: depth, title: title))
                for sheet in sub.sheets {
                    out.append(sheetRow(sheet, depth: depth + 1))
                }
                walk(sub.subsets, depth: depth + 1)
            }
        }
        walk(set.subsets, depth: 0)
        return out
    }

    /// Detail lines for the inspector: selected sheet, else the set.
    public static func details(for set: SheetSet, sheetID: String?, locked: Bool) -> [String] {
        var lines: [String] = [
            "Set: \(set.name)",
            "File: \(set.dstPath.isEmpty ? "(unsaved)" : set.dstPath)",
            "Sheets: \(set.allSheetsInOrder.count)",
            "Lock: \(locked ? "locked by another session" : "available")",
        ]
        if let id = sheetID, let sheet = set.sheet(id: id) {
            lines.append("Number: \(sheet.number)")
            lines.append("Title: \(sheet.title)")
            if !sheet.description.isEmpty { lines.append("Desc: \(sheet.description)") }
            lines.append("Drawing: \(sheet.absoluteFile.isEmpty ? "(none)" : sheet.absoluteFile)")
            lines.append("Layout: \(sheet.layoutName.isEmpty ? "(none)" : sheet.layoutName)")
            lines.append("Handle: \(sheet.handle.isEmpty ? "(none)" : sheet.handle)")
            lines.append("Plot: \(sheet.includeForPlot ? "yes" : "no")")
        }
        return lines
    }

    /// Drawing folders backing Model Views: configured locations plus
    /// the directories holding member drawings (deduped, sorted).
    /// Enumeration itself stays in the UI layer so this remains pure.
    public static func modelViewFolders(for set: SheetSet) -> [String] {
        var seen: [String: String] = [:]
        func add(_ path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.replacingOccurrences(of: "\\", with: "/").lowercased()
            if seen[key] == nil { seen[key] = trimmed }
        }
        for folder in set.modelViewFolders { add(folder) }
        for sheet in set.allSheetsInOrder where !sheet.absoluteFile.isEmpty {
            add(URL(fileURLWithPath: sheet.absoluteFile).deletingLastPathComponent().path)
        }
        return seen.values.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// One Model Views file row.
    public struct ModelViewFileRow: Sendable, Equatable {
        public var path: String
        public var title: String
    }

    /// File rows for one folder, sorted by display name.
    public static func modelViewFileRows(files: [String]) -> [ModelViewFileRow] {
        files.map {
            ModelViewFileRow(path: $0, title: URL(fileURLWithPath: $0).lastPathComponent)
        }.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private static func sheetRow(_ sheet: SheetSetSheet, depth: Int) -> SheetSetTreeRow {
        var title = [sheet.number, sheet.title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if title.isEmpty { title = "(unnamed sheet)" }
        if !sheet.includeForPlot { title += " [no plot]" }
        return SheetSetTreeRow(
            kind: .sheet, depth: depth, sheetID: sheet.id, title: title,
            subtitle: URL(fileURLWithPath: sheet.absoluteFile).lastPathComponent)
    }
}

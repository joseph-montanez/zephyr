import Foundation

// =========================================================================
// MARK: - Publish sheet-list persistence (`.dsd`, Phases 5-6)
// -------------------------------------------------------------------------
// INI-formatted save/load for a PUBLISH sheet list so a batch export
// re-runs in one click. Stored per row: drawing identity (source path +
// tab + space), the display sheet name, the native setup name, and the
// assignment as NAMES only (`Default` / `Named` / `Imported` + setup name
// + master path).
//
// This is a Zephyr-internal tolerant subset for Zephyr sheet paths,
// layouts, sheet names, setup overrides, and job options. It is NOT
// AutoCAD grammar: no authenticated AutoCAD LT `.dsd` sample was
// available, so this format is documented from and tested against
// Zephyr's own writer only. Do not claim AutoCAD compatibility for
// files written or read here.
//
// Names re-resolve against loaded drawings on load (see
// `PublishSheetStore.candidateSetups` / `assign(setupName:from:to:)`):
// full `CADPlotSettings` snapshots are deliberately not serialized.
// Unknown sections and unknown keys are ignored so newer files still
// load; sheets missing `Tab` (identity) throw `malformedSheet`
// (callers surface the section name), and a document with neither
// `[Job]` nor any `[SheetN]` throws `emptyDocument`.
//
// Sections honored: `[Job]` plus `[SheetN]` (N = 1, 2, …; applied in
// numeric order, so `[Sheet10]` follows `[Sheet9]`). Section and key
// names are case-insensitive; surrounding whitespace is trimmed; lines
// starting with `;` or `#` are comments; blank lines are skipped.
// Values are single-line (`clean` folds CR/LF to spaces on write).
// Unrecognized `PublishTo` / `FileType` / `Naming` / `MergeControl` /
// `Space` / `AssignMode` values fall back to defaults (`PlotterNamed`,
// `Multi`, `Prompt`, `Overwrite`, `Layout`, `Default`); a non-numeric
// or out-of-range `Copies` keeps the default (1).
//
// Format:
//
//   [Job]
//   PublishTo=PlotterNamed|PDF
//   FileType=Multi|Single
//   Naming=Prompt|Auto
//   TargetName=<name or empty>
//   OutputDir=<path or empty>
//   IncludeLayerInfo=1|0
//   MergeControl=Overwrite|Merge
//   Copies=<int>
//   PlotStamp=1|0
//   Background=1|0
//   OpenViewer=1|0
//
//   [Sheet1]
//   Source=<drawing path, may be empty for never-saved tabs>
//   Tab=<layout tab name>
//   Space=Model|Layout
//   Name=<display sheet name>
//   DefaultSetup=<native setup name, may be empty>
//   AssignMode=Default|Named|Imported
//   SetupName=<assigned setup name, may be empty>
//   MasterPath=<owning drawing path for Imported, may be empty>
// =========================================================================

/// How a `.dsd` sheet list merges into an existing sheet list (Phase 6).
public enum PublishDSDLoadMode: Sendable, Equatable {
    /// Discard the current list, then load.
    case replace
    /// Keep the current rows and append the loaded ones (names de-duped).
    case append
}

/// Errors from `PublishDSD.parse`.
public enum PublishDSDError: Error, LocalizedError, Equatable {
    case emptyDocument
    case malformedSheet(section: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "Not a sheet list: no [Job] or [SheetN] sections found."
        case .malformedSheet(let section, let detail):
            return "Sheet '\(section)' is incomplete: \(detail)"
        }
    }
}

/// Serializable form of one sheet row: identity + assignment names.
public struct PublishDSDSheet: Sendable, Equatable {
    public var sourcePath: String
    public var tabName: String
    public var space: PublishSpace
    public var sheetName: String
    public var defaultSetupName: String
    public var assignMode: PublishSetupMode
    public var setupName: String
    public var masterPath: String

    public init(
        sourcePath: String,
        tabName: String,
        space: PublishSpace,
        sheetName: String,
        defaultSetupName: String = "",
        assignMode: PublishSetupMode = .default,
        setupName: String = "",
        masterPath: String = ""
    ) {
        self.sourcePath = sourcePath
        self.tabName = tabName
        self.space = space
        self.sheetName = sheetName
        self.defaultSetupName = defaultSetupName
        self.assignMode = assignMode
        self.setupName = setupName
        self.masterPath = masterPath
    }

    /// Name-only projection of a live row (resolved setups re-resolve).
    public init(entry: PublishSheetEntry) {
        self.init(
            sourcePath: entry.sourceDwgPath,
            tabName: entry.tabName,
            space: entry.space,
            sheetName: entry.sheetName,
            defaultSetupName: entry.defaultSetupName,
            assignMode: entry.assignment.mode,
            setupName: entry.assignment.mode == .default ? "" : entry.assignment.setupName,
            masterPath: entry.assignment.masterDwgPath ?? "")
    }
}

/// Serializable form of a publish job: options + name-only sheet rows.
public struct PublishDSDJob: Sendable, Equatable {
    public var publishTo: PublishDestination
    public var outputDirectory: String
    public var fileType: PublishFileType
    public var namingPolicy: PublishNamingPolicy
    public var targetFileName: String?
    public var includeLayerInfo: Bool
    public var mergeControl: PDFMergeControl
    public var numberOfCopies: Int
    public var includePlotStamp: Bool
    public var publishInBackground: Bool
    public var openInViewerWhenDone: Bool
    public var sheets: [PublishDSDSheet]

    public init(
        publishTo: PublishDestination = .plotterNamedInPageSetup,
        outputDirectory: String = "",
        fileType: PublishFileType = .multiSheetFile,
        namingPolicy: PublishNamingPolicy = .promptForName,
        targetFileName: String? = nil,
        includeLayerInfo: Bool = true,
        mergeControl: PDFMergeControl = .overwriteLines,
        numberOfCopies: Int = 1,
        includePlotStamp: Bool = false,
        publishInBackground: Bool = false,
        openInViewerWhenDone: Bool = false,
        sheets: [PublishDSDSheet] = []
    ) {
        self.publishTo = publishTo
        self.outputDirectory = outputDirectory
        self.fileType = fileType
        self.namingPolicy = namingPolicy
        self.targetFileName = targetFileName
        self.includeLayerInfo = includeLayerInfo
        self.mergeControl = mergeControl
        self.numberOfCopies = numberOfCopies
        self.includePlotStamp = includePlotStamp
        self.publishInBackground = publishInBackground
        self.openInViewerWhenDone = openInViewerWhenDone
        self.sheets = sheets
    }

    /// Name-only projection of a live job spec.
    public init(spec: PublishJobSpec) {
        self.init(
            publishTo: spec.publishTo,
            outputDirectory: spec.outputDirectory,
            fileType: spec.fileType,
            namingPolicy: spec.namingPolicy,
            targetFileName: spec.targetFileName,
            includeLayerInfo: spec.includeLayerInfo,
            mergeControl: spec.mergeControl,
            numberOfCopies: spec.numberOfCopies,
            includePlotStamp: spec.includePlotStamp,
            publishInBackground: spec.publishInBackground,
            openInViewerWhenDone: spec.openInViewerWhenDone,
            sheets: spec.sheets.map(PublishDSDSheet.init(entry:)))
    }
}

public enum PublishDSD {
    // MARK: - Serialize

    /// One-line INI value: CR/LF become spaces, surrounding space trimmed.
    static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    /// Serialize a live job spec (rows project to names; see file header).
    public static func serialize(spec: PublishJobSpec) -> String {
        serialize(job: PublishDSDJob(spec: spec))
    }

    /// Serialize an already-projected job.
    public static func serialize(job: PublishDSDJob) -> String {
        var lines: [String] = []
        lines.append("; Zephyr publish sheet list (.dsd)")
        lines.append("[Job]")
        lines.append("PublishTo=\(job.publishTo == .pdf ? "PDF" : "PlotterNamed")")
        lines.append("FileType=\(job.fileType == .singleSheetFiles ? "Single" : "Multi")")
        lines.append("Naming=\(job.namingPolicy == .autoName ? "Auto" : "Prompt")")
        lines.append("TargetName=\(clean(job.targetFileName ?? ""))")
        lines.append("OutputDir=\(clean(job.outputDirectory))")
        lines.append("IncludeLayerInfo=\(flag(job.includeLayerInfo))")
        lines.append("MergeControl=\(job.mergeControl == .mergeLines ? "Merge" : "Overwrite")")
        lines.append("Copies=\(max(1, job.numberOfCopies))")
        lines.append("PlotStamp=\(flag(job.includePlotStamp))")
        lines.append("Background=\(flag(job.publishInBackground))")
        lines.append("OpenViewer=\(flag(job.openInViewerWhenDone))")
        for (index, sheet) in job.sheets.enumerated() {
            lines.append("[Sheet\(index + 1)]")
            lines.append("Source=\(clean(sheet.sourcePath))")
            lines.append("Tab=\(clean(sheet.tabName))")
            lines.append("Space=\(sheet.space == .model ? "Model" : "Layout")")
            lines.append("Name=\(clean(sheet.sheetName))")
            lines.append("DefaultSetup=\(clean(sheet.defaultSetupName))")
            lines.append("AssignMode=\(sheet.assignMode == .namedLocal ? "Named" : sheet.assignMode == .importedMaster ? "Imported" : "Default")")
            lines.append("SetupName=\(clean(sheet.setupName))")
            lines.append("MasterPath=\(clean(sheet.masterPath))")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Parse

    private static func bool(_ value: String, default defaultValue: Bool) -> Bool {
        let t = value.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "1" || t == "true" || t == "yes" { return true }
        if t == "0" || t == "false" || t == "no" { return false }
        return defaultValue
    }

    /// Parse `.dsd` text. Unknown sections/keys are ignored; sheet sections
    /// missing `Tab` (identity) throw `malformedSheet`. A document
    /// with no `[Job]` and no `[SheetN]` throws `emptyDocument`.
    public static func parse(_ text: String) throws -> PublishDSDJob {
        var sections: [(name: String, keys: [String: String])] = []
        var currentName: String? = nil
        var currentKeys: [String: String] = [:]
        func flush() {
            if let name = currentName { sections.append((name, currentKeys)) }
            currentName = nil
            currentKeys = [:]
        }
        // Normalize all line endings first so values never carry CR.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                currentName = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard currentName != nil else { continue } // stray keys outside sections
            guard let eq = line.firstIndex(of: "=") else { continue } // stray text
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            currentKeys[key] = value
        }
        flush()

        guard sections.contains(where: {
            $0.name.caseInsensitiveCompare("Job") == .orderedSame
                || $0.name.lowercased().hasPrefix("sheet")
        }) else {
            throw PublishDSDError.emptyDocument
        }

        var job = PublishDSDJob()
        if let jobSection = sections.first(where: {
            $0.name.caseInsensitiveCompare("Job") == .orderedSame
        }) {
            let k = jobSection.keys
            if let v = k["PUBLISHTO"] {
                job.publishTo = v.caseInsensitiveCompare("PDF") == .orderedSame ? .pdf : .plotterNamedInPageSetup
            }
            if let v = k["FILETYPE"] {
                job.fileType = v.caseInsensitiveCompare("Single") == .orderedSame ? .singleSheetFiles : .multiSheetFile
            }
            if let v = k["NAMING"] {
                job.namingPolicy = v.caseInsensitiveCompare("Auto") == .orderedSame ? .autoName : .promptForName
            }
            if let v = k["TARGETNAME"], !v.isEmpty { job.targetFileName = v }
            if let v = k["OUTPUTDIR"] { job.outputDirectory = v }
            if let v = k["INCLUDELAYERINFO"] { job.includeLayerInfo = bool(v, default: true) }
            if let v = k["MERGECONTROL"] {
                job.mergeControl = v.caseInsensitiveCompare("Merge") == .orderedSame ? .mergeLines : .overwriteLines
            }
            if let v = k["COPIES"], let n = Int(v), n >= 1 { job.numberOfCopies = n }
            if let v = k["PLOTSTAMP"] { job.includePlotStamp = bool(v, default: false) }
            if let v = k["BACKGROUND"] { job.publishInBackground = bool(v, default: false) }
            if let v = k["OPENVIEWER"] { job.openInViewerWhenDone = bool(v, default: false) }
        }

        // Sheet sections in numeric order ([Sheet10] after [Sheet9]).
        let sheetSections = sections.filter { $0.name.lowercased().hasPrefix("sheet") }.sorted {
            let a = Int($0.name.dropFirst("sheet".count)) ?? Int.max
            let b = Int($1.name.dropFirst("sheet".count)) ?? Int.max
            if a != b { return a < b }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        for section in sheetSections {
            let k = section.keys
            guard let tab = k["TAB"], !tab.isEmpty else {
                throw PublishDSDError.malformedSheet(
                    section: section.name, detail: "missing Tab=<layout name>.")
            }
            let spaceRaw = (k["SPACE"] ?? "").lowercased()
            let space: PublishSpace = spaceRaw == "model" ? .model : .layout
            let modeRaw = (k["ASSIGNMODE"] ?? "").lowercased()
            let mode: PublishSetupMode =
                modeRaw == "named" ? .namedLocal
                : modeRaw == "imported" ? .importedMaster : .default
            job.sheets.append(PublishDSDSheet(
                sourcePath: k["SOURCE"] ?? "",
                tabName: tab,
                space: space,
                sheetName: k["NAME"] ?? tab,
                defaultSetupName: k["DEFAULTSETUP"] ?? "",
                assignMode: mode,
                setupName: k["SETUPNAME"] ?? "",
                masterPath: k["MASTERPATH"] ?? ""))
        }
        return job
    }
}

// =========================================================================
// MARK: - Publish CSV log beside the `.dsd` (Phase 6)
// -------------------------------------------------------------------------
// After a `-PUBLISH` foreground run, one CSV row per sheet lands next to
// the sheet list (`<base>-publish-log.csv`, same folder). Columns are
// fixed; fields containing `,`, `"`, or a newline are RFC-4180 quoted.
// The log is a Zephyr-internal companion to the internal `.dsd` subset
// above, not an AutoCAD artifact.
// =========================================================================

public enum PublishDSDLog {
    /// Log path beside `dsdPath`: `<base>-publish-log.csv` in the same
    /// folder (or the temp directory when `dsdPath` has no folder).
    public static func logURL(besideDSDPath dsdPath: String) -> URL {
        let ns = dsdPath as NSString
        let base = ns.deletingPathExtension
        let stem = base.isEmpty ? "publish" : base
        let dir = ns.deletingLastPathComponent
        if dir.isEmpty || dir == dsdPath {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("\((stem as NSString).lastPathComponent)-publish-log.csv")
        }
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("\((stem as NSString).lastPathComponent)-publish-log.csv")
    }

    /// Quote one CSV field (RFC-4180: wrap when it holds `,`, `"`, CR/LF).
    public static func field(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Whole log text for `report` (spec order): header + one row per sheet.
    public static func csvText(report: PublishJobReport, spec: PublishJobSpec) -> String {
        let outputs = Dictionary(
            uniqueKeysWithValues: report.sheets.map { ($0.id, $0.outputURL) })
        var lines = ["Sheet,Source,Tab,Space,Setup,Status,Message,Output"]
        for entry in spec.sheets {
            let row = report.sheets.first(where: { $0.id == entry.id })
            let setup: String
            switch entry.assignment.mode {
            case .default:
                setup = entry.defaultSetupName.isEmpty ? "<Default: None>" : "<Default: \(entry.defaultSetupName)>"
            case .namedLocal, .importedMaster:
                setup = entry.assignment.setupName
            }
            lines.append([
                field(entry.sheetName),
                field(entry.sourceDwgPath),
                field(entry.tabName),
                entry.space == .model ? "Model" : "Layout",
                field(setup),
                field(row?.status.rawValue ?? "error"),
                field(row?.message ?? "No result recorded for this sheet."),
                field(outputs[entry.id]??.path ?? ""),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Write the log beside `dsdPath` (creating the folder) and return
    /// the log URL.
    @discardableResult
    public static func write(
        report: PublishJobReport,
        spec: PublishJobSpec,
        besideDSDPath dsdPath: String
    ) throws -> URL {
        let url = logURL(besideDSDPath: dsdPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try csvText(report: report, spec: spec).write(
            to: url, atomically: true, encoding: .utf8)
        return url
    }
}

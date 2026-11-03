import Foundation

// =========================================================================
// MARK: - Publish sheet model (Phase 3, core only — no UI, no execution)
// -------------------------------------------------------------------------
// Value model for the PUBLISH sheet list: sheet entries with page-setup
// resolution provenance, a job spec mirroring the Publish dialog controls,
// space-filtered candidate lookup across loaded drawings, unique sheet
// naming, bulk assignment, and per-row preflight statuses.
//
// Space scoping mirrors `TabManager.applyNamedSetupToLayout`: a MODEL setup
// (`isModelType == true`) only ever applies to a `*-Model` row and a
// LAYOUT setup only to a `*-Layout*` row.
// =========================================================================

/// Sheet space: Model rows take MODEL setups, Layout rows take LAYOUT setups.
public enum PublishSpace: String, Sendable, Equatable, Codable {
    case model
    case layout

    public init(kind: DXFDrawingViewKind) {
        self = (kind == .model) ? .model : .layout
    }
}

/// How a row's page setup was resolved (provenance for the Page Setup column).
public enum PublishSetupMode: String, Sendable, Equatable, Codable {
    /// The sheet's native setup from its own drawing (`<Default: ...>`).
    case `default`
    /// A named setup from the row's own drawing.
    case namedLocal
    /// A named setup borrowed from another loaded drawing (Master DWG flow).
    case importedMaster
}

/// A row's page-setup assignment with resolution provenance.
public struct PublishSetupAssignment: Sendable, Equatable {
    public var mode: PublishSetupMode
    /// Column text: `<Default: Name>` / `<Default: None>` for `.default`,
    /// otherwise the setup name.
    public var setupName: String
    /// Populated when `mode == .importedMaster`.
    public var masterDwgPath: String?
    /// Snapshot of the effective settings. Nil for `.default` (resolved live
    /// from the row's own drawing) and when no setup could be resolved.
    public var resolvedSetup: CADPlotSettings?

    public init(
        mode: PublishSetupMode,
        setupName: String,
        masterDwgPath: String? = nil,
        resolvedSetup: CADPlotSettings? = nil
    ) {
        self.mode = mode
        self.setupName = setupName
        self.masterDwgPath = masterDwgPath
        self.resolvedSetup = resolvedSetup
    }

    /// Default provenance for a row's native setup (`""` renders `<Default: None>`).
    public static func `default`(named name: String) -> PublishSetupAssignment {
        let label = name.isEmpty ? "<Default: None>" : "<Default: \(name)>"
        return PublishSetupAssignment(mode: .default, setupName: label)
    }
}

/// Preflight outcome for one sheet row.
public enum PublishSheetStatus: String, Sendable, Equatable, Codable {
    case ready
    case warning
    case error
}

/// One row of the Publish sheet list (`<DwgBaseName>-<TabName>` by default).
public struct PublishSheetEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sheetName: String
    /// Owning drawing, matched by identity (see `PublishDrawingMetadata.id`).
    public var drawingID: UUID
    public var sourceDwgPath: String
    public var tabName: String
    public var space: PublishSpace
    /// This tab's native setup name from its own drawing (`""` = `<None>`).
    public var defaultSetupName: String
    /// This tab's native settings from its own drawing (nil = `<None>`).
    public var defaultSetup: CADPlotSettings?
    public var assignment: PublishSetupAssignment
    public var status: PublishSheetStatus
    public var statusMessage: String

    public init(
        id: UUID = UUID(),
        sheetName: String,
        drawingID: UUID,
        sourceDwgPath: String,
        tabName: String,
        space: PublishSpace,
        defaultSetupName: String = "",
        defaultSetup: CADPlotSettings? = nil,
        assignment: PublishSetupAssignment? = nil,
        status: PublishSheetStatus = .ready,
        statusMessage: String = "No errors"
    ) {
        self.id = id
        self.sheetName = sheetName
        self.drawingID = drawingID
        self.sourceDwgPath = sourceDwgPath
        self.tabName = tabName
        self.space = space
        self.defaultSetupName = defaultSetupName
        self.defaultSetup = defaultSetup
        self.assignment = assignment ?? .default(named: defaultSetupName)
        self.status = status
        self.statusMessage = statusMessage
    }

    /// Effective settings for this row: the borrowed snapshot for
    /// `.namedLocal` / `.importedMaster`, the live native setup for `.default`.
    public var resolvedSetup: CADPlotSettings? {
        if assignment.mode == .default { return defaultSetup }
        return assignment.resolvedSetup
    }
}

/// Publish destination (Publish dialog `Publish to:`).
public enum PublishDestination: String, Sendable, Equatable, Codable {
    case plotterNamedInPageSetup
    case pdf
}

/// Output granularity (`File type:`).
public enum PublishFileType: String, Sendable, Equatable, Codable {
    case multiSheetFile
    case singleSheetFiles
}

/// Output naming (`Naming:`).
public enum PublishNamingPolicy: String, Sendable, Equatable, Codable {
    case promptForName
    case autoName
}

/// Batch publish job (serializable to `.dsd` in a later phase).
public struct PublishJobSpec: Sendable, Equatable {
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
    public var sheets: [PublishSheetEntry]

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
        sheets: [PublishSheetEntry] = []
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
}

// MARK: - Candidate setups (space-filtered, own drawing first)

/// A named setup available to a row, with its owning drawing.
public struct PublishSetupCandidate: Sendable, Equatable {
    public var setup: CADNamedPageSetup
    public var originPath: String
    public var isOwnDrawing: Bool

    public init(setup: CADNamedPageSetup, originPath: String, isOwnDrawing: Bool) {
        self.setup = setup
        self.originPath = originPath
        self.isOwnDrawing = isOwnDrawing
    }
}

// MARK: - Preflight

/// Preflight outcome for one row under `publishTo`.
///
/// - Missing setup: `.error` for plotter-named output (nothing to plot
///   with), `.warning` for PDF output (the global PDF preset covers it).
/// - Non-positive paper size: `.error` (no meaningful page to emit).
/// - Missing/unknown plotter device: `.warning` for plotter-named output,
///   `.ready` for PDF output (the device is irrelevant there).
public func preflightPublishEntry(
    _ entry: PublishSheetEntry,
    publishTo: PublishDestination
) -> (status: PublishSheetStatus, message: String) {
    guard let resolved = entry.resolvedSetup else {
        if publishTo == .plotterNamedInPageSetup {
            return (.error, "No page setup assigned; pick a setup or import one from the Master drawing.")
        }
        return (.warning, "No page setup assigned; the PDF preset will be used.")
    }
    guard resolved.paperWidthMM > 0, resolved.paperHeightMM > 0,
          resolved.paperWidthMM.isFinite, resolved.paperHeightMM.isFinite else {
        return (.error, "Invalid paper size (\(resolved.paperWidthMM) x \(resolved.paperHeightMM) mm).")
    }
    let device = resolved.plotConfigName.trimmingCharacters(in: .whitespacesAndNewlines)
    if publishTo == .plotterNamedInPageSetup,
       device.isEmpty || device.caseInsensitiveCompare("None") == .orderedSame {
        return (.warning, "No plotter assigned; set a device in the page setup.")
    }
    if publishTo == .plotterNamedInPageSetup, PlotDeviceCatalog.device(named: device) == nil {
        return (.warning, "Plotter '\(device)' not found; output may fall back to a default driver.")
    }
    return (.ready, "No errors")
}

// MARK: - Sheet store (list + loaded drawings, Add/Remove/Move + bulk assign)

/// Owns the sheet list plus the loaded drawing metadata rows resolve against.
public struct PublishSheetStore: Sendable, Equatable {
    public var drawings: [PublishDrawingMetadata]
    public var sheets: [PublishSheetEntry]

    public init(drawings: [PublishDrawingMetadata] = [], sheets: [PublishSheetEntry] = []) {
        self.drawings = drawings
        self.sheets = sheets
    }

    // MARK: Naming

    /// Default sheet name for one tab (`<DwgBaseName>-<TabName>`).
    public static func baseSheetName(drawingBaseName: String, tabName: String) -> String {
        "\(drawingBaseName)-\(tabName)"
    }

    /// File base name for sheet naming (`1.dwg` → `1`; empty path → display name).
    public static func drawingBaseName(sourcePath: String, displayName: String) -> String {
        let last = (sourcePath as NSString).lastPathComponent
        let base = (last as NSString).deletingPathExtension
        if !base.isEmpty { return base }
        let fallback = (displayName as NSString).deletingPathExtension
        return fallback.isEmpty ? "Untitled" : fallback
    }

    /// Unique sheet name within `sheets` (`Name`, `Name (2)`, `Name (3)`, …).
    public func uniqueSheetName(proposing base: String, excluding excludedID: UUID? = nil) -> String {
        let taken = Set(sheets.filter { $0.id != excludedID }.map(\.sheetName))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    // MARK: Add / Remove / Move

    /// Append one row per tab of `metadata` (Model included when
    /// `includeModel` is true, mirroring PUBLISHALLSHEETS). Rows run a
    /// plotter-named preflight by default; callers targeting PDF output
    /// should follow with `refreshPreflight(publishTo: .pdf)`.
    @discardableResult
    public mutating func addDrawing(
        _ metadata: PublishDrawingMetadata,
        includeModel: Bool = true,
        publishTo: PublishDestination = .plotterNamedInPageSetup
    ) -> [PublishSheetEntry] {
        if !drawings.contains(where: { $0.id == metadata.id }) {
            drawings.append(metadata)
        }
        let base = Self.drawingBaseName(sourcePath: metadata.sourcePath, displayName: metadata.displayName)
        var added: [PublishSheetEntry] = []
        for tab in metadata.tabs {
            guard includeModel || tab.space == .layout else { continue }
            var entry = PublishSheetEntry(
                sheetName: uniqueSheetName(proposing: Self.baseSheetName(
                    drawingBaseName: base, tabName: tab.name)),
                drawingID: metadata.id,
                sourceDwgPath: metadata.sourcePath,
                tabName: tab.name,
                space: tab.space,
                defaultSetupName: tab.defaultSetupName,
                defaultSetup: tab.defaultSetup)
            let outcome = preflightPublishEntry(entry, publishTo: publishTo)
            entry.status = outcome.status
            entry.statusMessage = outcome.message
            sheets.append(entry)
            added.append(entry)
        }
        return added
    }

    /// Remove rows at list offsets (descending so indices stay valid).
    public mutating func removeSheets(at offsets: [Int]) {
        for offset in offsets.sorted(by: >) {
            guard sheets.indices.contains(offset) else { continue }
            sheets.remove(at: offset)
        }
    }

    /// Remove one row by id. Returns false when unknown.
    @discardableResult
    public mutating func removeSheet(id: UUID) -> Bool {
        guard let index = sheets.firstIndex(where: { $0.id == id }) else { return false }
        sheets.remove(at: index)
        return true
    }

    /// Move a row within the list (Move Up/Down/To). Returns false for
    /// out-of-range indices.
    @discardableResult
    public mutating func moveSheet(from source: Int, to destination: Int) -> Bool {
        guard sheets.indices.contains(source),
              destination >= 0, destination < sheets.count else { return false }
        guard source != destination else { return true }
        let entry = sheets.remove(at: source)
        sheets.insert(entry, at: destination)
        return true
    }

    // MARK: Candidates + assignment

    public func drawing(for entry: PublishSheetEntry) -> PublishDrawingMetadata? {
        drawings.first(where: { $0.id == entry.drawingID })
    }

    /// Named setups applicable to `entry`: the row's own drawing first, then
    /// every other loaded drawing (the Master DWG flow), all filtered to the
    /// row's space.
    public func candidateSetups(for entry: PublishSheetEntry) -> [PublishSetupCandidate] {
        let wantModel = entry.space == .model
        var out: [PublishSetupCandidate] = []
        if let own = drawing(for: entry) {
            for setup in own.namedSetups where setup.isModelType == wantModel {
                out.append(PublishSetupCandidate(
                    setup: setup, originPath: own.sourcePath, isOwnDrawing: true))
            }
        }
        for drawing in drawings where drawing.id != entry.drawingID {
            for setup in drawing.namedSetups where setup.isModelType == wantModel {
                out.append(PublishSetupCandidate(
                    setup: setup, originPath: drawing.sourcePath, isOwnDrawing: false))
            }
        }
        return out
    }

    /// Bulk-assign `setupName` (resolved against `originPath` when given, else
    /// the first space-matching candidate) to every listed row whose space
    /// matches. Borrowed setups record `.importedMaster` provenance with the
    /// owning drawing's path; own-drawing setups record `.namedLocal`.
    /// Returns the number of rows changed.
    @discardableResult
    public mutating func assign(
        setupName: String,
        from originPath: String? = nil,
        to sheetIDs: Set<UUID>
    ) -> Int {
        var changed = 0
        for index in sheets.indices {
            guard sheetIDs.contains(sheets[index].id) else { continue }
            var candidates = candidateSetups(for: sheets[index])
            if let originPath {
                candidates = candidates.filter {
                    $0.originPath.caseInsensitiveCompare(originPath) == .orderedSame
                }
            }
            guard let match = candidates.first(where: {
                $0.setup.name.caseInsensitiveCompare(setupName) == .orderedSame
            }) else { continue }
            var snapshot = match.setup.settings
            snapshot.pageSetupName = match.setup.name
            if match.isOwnDrawing {
                sheets[index].assignment = PublishSetupAssignment(
                    mode: .namedLocal, setupName: match.setup.name, resolvedSetup: snapshot)
            } else {
                sheets[index].assignment = PublishSetupAssignment(
                    mode: .importedMaster, setupName: match.setup.name,
                    masterDwgPath: match.originPath, resolvedSetup: snapshot)
            }
            changed += 1
        }
        return changed
    }

    /// Reset rows to their native setups (`<Default: ...>` provenance).
    public mutating func assignDefault(to sheetIDs: Set<UUID>) {
        for index in sheets.indices {
            guard sheetIDs.contains(sheets[index].id) else { continue }
            sheets[index].assignment = .default(named: sheets[index].defaultSetupName)
        }
    }

    /// Re-run preflight for every row under `publishTo`.
    public mutating func refreshPreflight(publishTo: PublishDestination) {
        for index in sheets.indices {
            let outcome = preflightPublishEntry(sheets[index], publishTo: publishTo)
            sheets[index].status = outcome.status
            sheets[index].statusMessage = outcome.message
        }
    }

    // MARK: - `.dsd` application (replace / append, Phase 6)

    /// Merge a parsed `.dsd` job into this store (Phase 6 shared loader
    /// for the dialog Load button, `+PUBLISH` preloading, and `-PUBLISH`).
    ///
    /// - `mode == .replace` clears the list first; `.append` keeps the
    ///   current rows and appends the loaded ones.
    /// - Drawings re-resolve through `metadataProvider` (nil = missing or
    ///   unreadable → the rows still list from a stub record with an
    ///   honest preflight status, mirroring the dialog).
    /// - Only the record's tabs become rows; setup names re-resolve via
    ///   `assign` (Master imports pull their owning drawing in too).
    ///
    /// Returns the number of non-default assignments that no longer
    /// resolve. Job options are the caller's to apply (`dsd.publishTo`,
    /// `fileType`, `namingPolicy`, …); preflight refreshes to
    /// `dsd.publishTo` here.
    @discardableResult
    public mutating func applyDSDJob(
        _ dsd: PublishDSDJob,
        mode: PublishDSDLoadMode,
        metadataProvider: (String) -> PublishDrawingMetadata?
    ) -> Int {
        if mode == .replace {
            self = PublishSheetStore()
        }
        // Group records by drawing (case-insensitive path), preserving
        // first-seen order.
        var grouped: [(key: String, records: [PublishDSDSheet])] = []
        for record in dsd.sheets {
            let key = record.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let i = grouped.firstIndex(where: { $0.key == key }) {
                grouped[i].records.append(record)
            } else {
                grouped.append((key, [record]))
            }
        }
        var unresolved = 0
        for group in grouped {
            let records = group.records
            let path = records[0].sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
            var meta: PublishDrawingMetadata?
            if !path.isEmpty {
                // Reuse an already-loaded drawing for the same file so
                // appended rows resolve against live setups.
                meta = drawings.first(where: {
                    $0.sourcePath.caseInsensitiveCompare(path) == .orderedSame
                }) ?? metadataProvider(path)
            }
            if meta == nil {
                let display = Self.drawingBaseName(
                    sourcePath: path, displayName: records[0].sheetName)
                meta = PublishDrawingMetadata(
                    sourcePath: path,
                    displayName: display.isEmpty ? "Untitled" : display,
                    tabs: records.map {
                        PublishDrawingTabMetadata(
                            name: $0.tabName, space: $0.space,
                            defaultSetupName: $0.defaultSetupName)
                    },
                    namedSetups: [])
            }
            guard let meta else { continue }
            let added = addDrawing(
                meta, includeModel: true, publishTo: dsd.publishTo)
            let addedIDs = Set(added.map(\.id))
            // Keep only the record's tabs; drop the rest of the drawing.
            let wanted = Set(records.map { $0.tabName.lowercased() })
            var idByTab: [String: UUID] = [:]
            for row in added where wanted.contains(row.tabName.lowercased()) {
                idByTab[row.tabName.lowercased()] = row.id
            }
            let keepIDs = Set(idByTab.values)
            removeSheets(at: sheets.indices.filter {
                addedIDs.contains(sheets[$0].id)
                    && !keepIDs.contains(sheets[$0].id)
            })
            for record in records {
                guard let id = idByTab[record.tabName.lowercased()],
                      let idx = sheets.firstIndex(where: { $0.id == id })
                else { continue }
                let proposal = record.sheetName.trimmingCharacters(in: .whitespacesAndNewlines)
                sheets[idx].sheetName = uniqueSheetName(
                    proposing: proposal.isEmpty ? sheets[idx].sheetName : proposal,
                    excluding: id)
                guard record.assignMode != .default, !record.setupName.isEmpty else { continue }
                if record.assignMode == .importedMaster, !record.masterPath.isEmpty,
                   !drawings.contains(where: {
                       $0.sourcePath.caseInsensitiveCompare(record.masterPath) == .orderedSame
                   }),
                   let master = metadataProvider(record.masterPath)
                {
                    drawings.append(master)
                }
                let origin: String? = record.assignMode == .importedMaster
                    ? (record.masterPath.isEmpty ? nil : record.masterPath)
                    : (record.assignMode == .namedLocal ? record.sourcePath : nil)
                if assign(setupName: record.setupName, from: origin, to: [id]) == 0 {
                    unresolved += 1
                }
            }
        }
        refreshPreflight(publishTo: dsd.publishTo)
        return unresolved
    }
}

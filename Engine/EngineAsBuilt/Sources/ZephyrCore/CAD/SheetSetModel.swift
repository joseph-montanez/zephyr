import Foundation

// =========================================================================
/// COM-style IDs for sheet set objects: "g" + uppercase UUID with dashes
/// (matches `crypto.randomUUID()` output in dst-edit/dst-codec fixtures).
public enum SheetSetModelID {
    public static func fresh() -> String {
        "g" + UUID().uuidString.uppercased()
    }
}

// MARK: - Sheet Set model (Step 2: core, no UI, no execution)
// -------------------------------------------------------------------------
// Durable project artifact behind the future Sheet Set Manager palette.
// A `SheetSet` is an ordered tree of subsets + sheets plus named sheet
// selections; `.dst` persistence lives in `SheetSetDST` (bytes <-> XML)
// with `SheetSetSheetRef` as the zero-DWG interchange row. This file owns
// ordering, renumbering, and the MRU index backing `SSLOCATE` when a DWG
// was never back-saved with its `AcSheetSetData` hint.
// =========================================================================

/// One sheet in a set. Identity keys on `(absoluteFile, handle)` — the
/// stored layout name can be stale; the `AcDbHandle` wins.
public struct SheetSetSheet: Sendable, Equatable, Identifiable {
    public var id: String
    public var number: String
    public var title: String
    public var description: String
    public var relativeFile: String
    public var absoluteFile: String
    public var handle: String
    public var layoutName: String
    public var includeForPlot: Bool
    public var includeForAutoNumbering: Bool
    public var custom: [String: String]

    public init(
        id: String = SheetSetModelID.fresh(),
        number: String = "",
        title: String = "",
        description: String = "",
        relativeFile: String = "",
        absoluteFile: String = "",
        handle: String = "",
        layoutName: String = "",
        includeForPlot: Bool = true,
        includeForAutoNumbering: Bool = true,
        custom: [String: String] = [:]
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.description = description
        self.relativeFile = relativeFile
        self.absoluteFile = absoluteFile
        self.handle = handle
        self.layoutName = layoutName
        self.includeForPlot = includeForPlot
        self.includeForAutoNumbering = includeForAutoNumbering
        self.custom = custom
    }

    public init(ref: SheetSetSheetRef) {
        self.init(
            id: ref.id.isEmpty ? SheetSetModelID.fresh() : ref.id,
            number: ref.number,
            title: ref.title,
            description: ref.description,
            relativeFile: ref.relativeFile,
            absoluteFile: ref.absoluteFile,
            handle: ref.handle,
            layoutName: ref.layoutName,
            includeForPlot: ref.includeForPlot,
            custom: ref.custom
        )
    }
}

/// Named subset; nestable. `publishSheets == false` suspends every sheet
/// in the subtree from publish (LT "Do Not Publish Sheets").
public struct SheetSetSubset: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var newSheetLocation: String
    public var creationTemplate: String
    public var publishSheets: Bool
    public var sheets: [SheetSetSheet]
    public var subsets: [SheetSetSubset]

    public init(
        id: String = SheetSetModelID.fresh(),
        name: String,
        description: String = "",
        newSheetLocation: String = "",
        creationTemplate: String = "",
        publishSheets: Bool = true,
        sheets: [SheetSetSheet] = [],
        subsets: [SheetSetSubset] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.newSheetLocation = newSheetLocation
        self.creationTemplate = creationTemplate
        self.publishSheets = publishSheets
        self.sheets = sheets
        self.subsets = subsets
    }
}

/// Saved sheet selection (publish/transmit/archive scope).
public struct SheetSetSelection: Sendable, Equatable {
    public var name: String
    public var sheetIDs: [String]

    public init(name: String, sheetIDs: [String] = []) {
        self.name = name
        self.sheetIDs = sheetIDs
    }
}

/// The set itself. Loose `sheets` render before `subsets` (LT order).
public struct SheetSet: Sendable, Equatable {
    public var name: String
    public var description: String
    public var dstPath: String
    public var sheetStorageLocation: String
    public var creationTemplate: String
    public var labelBlockFile: String
    public var calloutBlocksFile: String
    public var pageSetupOverridesFile: String
    public var modelViewFolders: [String]
    public var projectNumber: String
    public var projectName: String
    public var projectPhase: String
    public var projectMilestone: String
    public var customSetProps: [String: String]
    public var customSheetProps: [String]
    public var sheets: [SheetSetSheet]
    public var subsets: [SheetSetSubset]
    public var selections: [SheetSetSelection]
    /// Byte-exact `<AcSmSheetSelSets>` element captured at open. Emitted
    /// back verbatim on save (see `SheetSetDST.selSetsBlock`): the member
    /// grammar is unverified, so the model never reformats LT selections.
    /// In-session selections stay session-scoped until that gate passes.
    public var preservedSelSetsXML: String?

    public init(
        name: String,
        description: String = "",
        dstPath: String = "",
        sheetStorageLocation: String = "",
        creationTemplate: String = "",
        labelBlockFile: String = "",
        calloutBlocksFile: String = "",
        pageSetupOverridesFile: String = "",
        modelViewFolders: [String] = [],
        projectNumber: String = "",
        projectName: String = "",
        projectPhase: String = "",
        projectMilestone: String = "",
        customSetProps: [String: String] = [:],
        customSheetProps: [String] = [],
        sheets: [SheetSetSheet] = [],
        subsets: [SheetSetSubset] = [],
        selections: [SheetSetSelection] = [],
        preservedSelSetsXML: String? = nil
    ) {
        self.name = name
        self.description = description
        self.dstPath = dstPath
        self.sheetStorageLocation = sheetStorageLocation
        self.creationTemplate = creationTemplate
        self.labelBlockFile = labelBlockFile
        self.calloutBlocksFile = calloutBlocksFile
        self.pageSetupOverridesFile = pageSetupOverridesFile
        self.modelViewFolders = modelViewFolders
        self.projectNumber = projectNumber
        self.projectName = projectName
        self.projectPhase = projectPhase
        self.projectMilestone = projectMilestone
        self.customSetProps = customSetProps
        self.customSheetProps = customSheetProps
        self.sheets = sheets
        self.subsets = subsets
        self.selections = selections
        self.preservedSelSetsXML = preservedSelSetsXML
    }

    // MARK: - Traversal

    /// Every sheet in display/publish order (loose first, depth-first).
    public var allSheetsInOrder: [SheetSetSheet] {
        var out = sheets
        func walk(_ subsets: [SheetSetSubset]) {
            for sub in subsets {
                out.append(contentsOf: sub.sheets)
                walk(sub.subsets)
            }
        }
        walk(subsets)
        return out
    }

    public func sheet(id: String) -> SheetSetSheet? {
        allSheetsInOrder.first { $0.id == id }
    }

    // MARK: - Mutations (value semantics; caller writes back)

    @discardableResult
    public mutating func removeSheet(id: String) -> Bool {
        if let i = sheets.firstIndex(where: { $0.id == id }) {
            sheets.remove(at: i)
            return true
        }
        return Self.removeSheet(id: id, subsets: &subsets)
    }

    private static func removeSheet(id: String, subsets: inout [SheetSetSubset]) -> Bool {
        for s in subsets.indices {
            var sub = subsets[s]
            if let i = sub.sheets.firstIndex(where: { $0.id == id }) {
                sub.sheets.remove(at: i)
                subsets[s] = sub
                return true
            }
            if removeSheet(id: id, subsets: &sub.subsets) {
                subsets[s] = sub
                return true
            }
        }
        return false
    }

    /// Rename + renumber one sheet. Returns false when the id is unknown.
    @discardableResult
    public mutating func renameSheet(id: String, number: String, title: String) -> Bool {
        if let i = sheets.firstIndex(where: { $0.id == id }) {
            sheets[i].number = number
            sheets[i].title = title
            return true
        }
        return Self.renameSheet(id: id, number: number, title: title, subsets: &subsets)
    }

    private static func renameSheet(id: String, number: String, title: String, subsets: inout [SheetSetSubset]) -> Bool {
        for s in subsets.indices {
            var sub = subsets[s]
            if let i = sub.sheets.firstIndex(where: { $0.id == id }) {
                sub.sheets[i].number = number
                sub.sheets[i].title = title
                subsets[s] = sub
                return true
            }
            if renameSheet(id: id, number: number, title: title, subsets: &sub.subsets) {
                subsets[s] = sub
                return true
            }
        }
        return false
    }

    /// Sheets eligible for LT auto-numbering, in display order.
    public var autoNumberingScope: [SheetSetSheet] {
        allSheetsInOrder.filter { $0.includeForAutoNumbering }
    }
}

// =========================================================================
// MARK: - MRU index backing SSLOCATE
// -------------------------------------------------------------------------
// A DWG carries its set hint in `AcSheetSetData` only after it was
// back-saved post-association. The MRU covers the rest: every set open
// registers the DWG paths it references, so opening a drawing can still
// locate its set.
// =========================================================================

public struct SheetSetMRU: Sendable, Equatable {
    private var dwgToDST: [String: String] = [:]

    public init() {}

    static func key(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    public mutating func register(dstPath: String, dwgPaths: [String]) {
        for dwg in dwgPaths {
            dwgToDST[Self.key(dwg)] = dstPath
        }
    }

    public mutating func unregisterDST(_ dstPath: String) {
        dwgToDST = dwgToDST.filter { $0.value != dstPath }
    }

    public func locate(dwgPath: String) -> String? {
        dwgToDST[Self.key(dwgPath)]
    }
}

import Foundation

// =========================================================================
/// Errors from `SheetSetStore.saveCurrent`.
public enum SheetSetStoreError: Error, LocalizedError, Equatable {
    case noCurrentSet
    case unsavedSet

    public var errorDescription: String? {
        switch self {
        case .noCurrentSet:
            return "No sheet set is open."
        case .unsavedSet:
            return "The current set has no .dst path; use OPENSHEETSET or NEWSHEETSET with a path first."
        }
    }
}

// MARK: - Sheet set session state (Step 3: store + sysvars + .dbl lock)
// -------------------------------------------------------------------------
// `SheetSetSysvars` mirrors the `XrefSysvars` pattern: UserDefaults-backed
// ints for setvar/getvar (thread-safe for Lisp), in-memory session state
// for the manager window and last-located path. `SheetSetStore` owns the
// open sets, the current set, and the MRU index backing SSLOCATE when a
// DWG was never back-saved with its `AcSheetSetData` hint.
// Locking note: a `.dbl` file beside the `.dst` means another session
// holds the set (green dot = you, red dot = them); per-sheet lock icons
// reflect the OS file lock on each sheet DWG, with `.dwl`/`.dwl2` read
// for the WHOHAS owner tooltip only — never as the lock itself.
// =========================================================================

/// Sheet Set Manager system variables. Defaults marked ASSUMED match
/// believed LT behavior; verify against LT before the interchange gate.
public enum SheetSetSysvars {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var session: (managerOpen: Bool, lastFound: String) =
        (managerOpen: false, lastFound: "")

    private static func intValue(_ key: String, default defaultValue: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue : UserDefaults.standard.integer(forKey: key)
    }

    /// SSLOCATE: locate + open the set when a member drawing opens. ASSUMED default 1.
    public static var sslocate: Int {
        get { intValue("Zephyr.CAD.SSLOCATE", default: 1) }
        set { UserDefaults.standard.set(newValue, forKey: "Zephyr.CAD.SSLOCATE") }
    }
    /// SSMAUTOOPEN: open the located set in the manager. ASSUMED default 1.
    public static var ssmAutoOpen: Int {
        get { intValue("Zephyr.CAD.SSMAUTOOPEN", default: 1) }
        set { UserDefaults.standard.set(newValue, forKey: "Zephyr.CAD.SSMAUTOOPEN") }
    }
    /// SSMPOLLTIME: seconds between sheet-status refreshes. ASSUMED default 60.
    public static var ssmPollTime: Int {
        get { intValue("Zephyr.CAD.SSMPOLLTIME", default: 60) }
        set { UserDefaults.standard.set(newValue, forKey: "Zephyr.CAD.SSMPOLLTIME") }
    }
    /// SSMSHEETSTATUS: how status refreshes (0 never … 2 automatic). ASSUMED default 2.
    public static var ssmSheetStatus: Int {
        get { intValue("Zephyr.CAD.SSMSHEETSTATUS", default: 2) }
        set { UserDefaults.standard.set(newValue, forKey: "Zephyr.CAD.SSMSHEETSTATUS") }
    }
    /// UPDATETHUMBNAIL: update view/layout previews. ASSUMED default 1.
    public static var updateThumbnail: Int {
        get { intValue("Zephyr.CAD.UPDATETHUMBNAIL", default: 1) }
        set { UserDefaults.standard.set(newValue, forKey: "Zephyr.CAD.UPDATETHUMBNAIL") }
    }

    /// SSFOUND backing: last successfully located `.dst` path ("" = none).
    public static var lastFoundPath: String {
        get { lock.withLock { session.lastFound } }
        set { lock.withLock { session.lastFound = newValue } }
    }
    /// SSMSTATE backing: true while the Sheet Set Manager is open.
    public static var managerOpen: Bool {
        get { lock.withLock { session.managerOpen } }
        set { lock.withLock { session.managerOpen = newValue } }
    }
}

/// Open sets + current set + MRU for one processor session.
public struct SheetSetStore: Sendable, Equatable {
    /// Open sets keyed by `.dst` path ("" key = never-saved NEWSHEETSET set).
    public var openSets: [String: SheetSet] = [:]
    public var currentDSTPath: String? = nil
    public var mru = SheetSetMRU()

    public init() {}

    public var current: SheetSet? {
        currentDSTPath.flatMap { openSets[$0] }
    }

    /// Register an already-built set (NEWSHEETSET path or test fixture).
    public mutating func register(_ set: SheetSet) {
        openSets[set.dstPath] = set
        currentDSTPath = set.dstPath
        mru.register(dstPath: set.dstPath, dwgPaths: set.allSheetsInOrder.map(\.absoluteFile).filter { !$0.isEmpty })
    }

    /// Build + register a set from decoded `.dst` XML (OPENSHEETSET path).
    /// Sheet identity keys on (absoluteFile, AcDbHandle); the set name
    /// comes from `<AcSmSheetSet>` when present, else the file base name.
    @discardableResult
    public mutating func open(dstPath: String, xml: String) -> SheetSet {
        let children = SheetSetDST.parseChildren(SheetSetDST.scope(xml))
        let base = URL(fileURLWithPath: dstPath).deletingPathExtension().lastPathComponent
        let name = SheetSetDST.sheetSetName(xml: xml)
        var set = SheetSet(
            name: name.isEmpty ? base : name,
            description: SheetSetDST.sheetSetDescription(xml: xml),
            dstPath: dstPath)
        set.sheets = children.sheets.map(SheetSetSheet.init(ref:))
        set.subsets = children.subsets
        set.preservedSelSetsXML = SheetSetDST.selSetsBlock(xml: xml)
        // Set-scope customs round-trip; sheet-scope *defaults* restore as
        // names only (their values live per-sheet until the property
        // editor lands).
        set.customSetProps = Dictionary(
            uniqueKeysWithValues: children.setCustoms
                .filter { $0.flags == "1" && !$0.name.isEmpty }
                .map { ($0.name, $0.value) })
        set.customSheetProps = children.setCustoms
            .filter { $0.flags == "2" && !$0.name.isEmpty }
            .map(\.name)
        register(set)
        SheetSetSysvars.lastFoundPath = dstPath
        return set
    }

    /// Run a mutation against the current set. Returns false when there
    /// is no current set. The palette's edit actions go through here.
    @discardableResult
    public mutating func updateCurrent(_ body: (inout SheetSet) -> Void) -> Bool {
        // Copy back explicitly: `&openSets[key]!` would mutate a temporary.
        guard let key = currentDSTPath, var set = openSets[key] else { return false }
        body(&set)
        openSets[key] = set
        return true
    }

    /// Write the current set back to its `.dst` (serialize → encode →
    /// atomic write). Throws when there is no current set, it has no
    /// path, or serialization fails.
    @discardableResult
    public func saveCurrent() throws -> String {
        guard let set = current else { throw SheetSetStoreError.noCurrentSet }
        guard !set.dstPath.isEmpty else { throw SheetSetStoreError.unsavedSet }
        let xml = try SheetSetXML.serialize(set)
        let data = try SheetSetDST.encode(xml)
        try data.write(to: URL(fileURLWithPath: set.dstPath), options: .atomic)
        return set.dstPath
    }

    public mutating func close(dstPath: String) {
        openSets.removeValue(forKey: dstPath)
        mru.unregisterDST(dstPath)
        if currentDSTPath == dstPath {
            currentDSTPath = openSets.keys.sorted().first
        }
        if SheetSetSysvars.lastFoundPath == dstPath {
            SheetSetSysvars.lastFoundPath = ""
        }
    }

    /// SSLOCATE lookup over the MRU index. The caller (`autoOpenSheetSet`)
    /// consults the NOD `AcSheetSetData` hint first. Returns the owning
    /// `.dst` path or nil.
    public func locate(dwgPath: String) -> String? {
        mru.locate(dwgPath: dwgPath)
    }

    /// Sheet context for FIELD evaluation: the open set + sheet whose file
    /// and layout match a document's open-time identity. Layout-handle
    /// matching arrives with the NOD work; name matching is the v1 rule.
    public func sheetContext(documentFile: String?, layoutName: String?) -> (set: SheetSet, sheet: SheetSetSheet)? {
        guard let file = documentFile, !file.isEmpty,
              let layout = layoutName, !layout.isEmpty else { return nil }
        let key = SheetSetMRU.key(file)
        for set in openSets.values {
            for sheet in set.allSheetsInOrder {
                guard !sheet.absoluteFile.isEmpty,
                      SheetSetMRU.key(sheet.absoluteFile) == key,
                      sheet.layoutName.caseInsensitiveCompare(layout) == .orderedSame else { continue }
                return (set, sheet)
            }
        }
        return nil
    }

    /// `.dbl` beside the `.dst` = another session holds the set. Presence
    /// only; the owner identity is not decoded here.
    public func lockStatus(dstPath: String) -> (locked: Bool, detail: String?) {
        guard !dstPath.isEmpty else { return (false, nil) }
        let dbl = URL(fileURLWithPath: dstPath)
            .deletingPathExtension().appendingPathExtension("dbl").path
        guard FileManager.default.fileExists(atPath: dbl) else { return (false, nil) }
        return (true, "a .dbl lock file is present (\(dbl)); open read-only")
    }
}

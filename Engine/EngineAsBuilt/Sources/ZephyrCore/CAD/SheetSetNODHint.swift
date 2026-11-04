import Foundation

// MARK: - SheetSetNODHint
//
// SSLOCATE's first lookup: the `AcSheetSetData` dictionary AutoCAD writes
// into a drawing's Named Object Dictionary when a layout joins a sheet
// set. Layout (from public AutoLISP/VBA usage, not a guessed binary
// layout):
//
//   NOD ──"AcSheetSetData"──▶ DICTIONARY ──"ShSetFileName"──▶ XRECORD(1: dst path)
//                                          ──"SheetDwgName"──▶ XRECORD(1: dwg name)
//                                          ──"LayoutHandle"──▶ XRECORD(handle value)
//
// Only `.dxf`/`.dwt` are readable here (ASCII group-code pairs via
// `DXFReader`, which already parses every DICTIONARY and XRECORD into
// public maps). Binary `.dwg` needs the ODA converter and stays on the
// MRU fallback, as does any drawing never back-saved after joining a
// set. Fail-closed: anything missing or empty yields nil.

public enum SheetSetNODHint {
    public struct Hint: Sendable, Equatable {
        /// `.dst` path exactly as stored (often absolute, sometimes
        /// relative to the drawing — see `resolve(dstPath:relativeTo:)`).
        public var dstPath: String
        public var dwgName: String?
        public var layoutHandle: String?

        public init(dstPath: String, dwgName: String? = nil, layoutHandle: String? = nil) {
            self.dstPath = dstPath
            self.dwgName = dwgName
            self.layoutHandle = layoutHandle
        }
    }

    /// Pure lookup over an already-parsed reader. Case-insensitive on
    /// dictionary/entry names; AutoCAD always writes `AcSheetSetData` /
    /// `ShSetFileName`, but third-party writers vary the case.
    public static func read(reader: DXFReader) -> Hint? {
        let codec = DXFTextCodec()
        guard let dictHandle = reader.objectDictionaryNameByHandle.first(where: {
            $0.value.caseInsensitiveCompare("AcSheetSetData") == .orderedSame
        })?.key,
        let entries = reader.objectDictionaryEntries[dictHandle]
        else { return nil }
        func entry(_ name: String) -> UInt32? {
            entries.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
        }
        guard let fileHandle = entry("ShSetFileName"),
              let groups = reader.xrecordGroups[fileHandle],
              let raw = groups.first(where: { $0.code == 1 && !$0.value.isEmpty })?.value
        else { return nil }
        let dstPath = codec.toUtf8(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dstPath.isEmpty else { return nil }
        var hint = Hint(dstPath: dstPath)
        if let dwgHandle = entry("SheetDwgName"),
           let groups = reader.xrecordGroups[dwgHandle],
           let raw = groups.first(where: { $0.code == 1 && !$0.value.isEmpty })?.value {
            let name = codec.toUtf8(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { hint.dwgName = name }
        }
        if let layoutHandle = entry("LayoutHandle"),
           let groups = reader.xrecordGroups[layoutHandle],
           let raw = xrecordValue(in: groups) {
            let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !handle.isEmpty { hint.layoutHandle = handle }
        }
        return hint
    }

    /// Value lookup inside one XRECORD's raw pairs. Group 1 first (text).
    /// Group 5/105 second, skipping the record's own leading handle pair —
    /// `parseXRecord` takes the object's handle from the first 5/105, so
    /// the first such pair is structural, never the value.
    private static func xrecordValue(in groups: [(code: Int, value: String)]) -> String? {
        if let text = groups.first(where: { $0.code == 1 && !$0.value.isEmpty }) {
            return text.value
        }
        var skippedOwnHandle = false
        for pair in groups where (pair.code == 5 || pair.code == 105) && !pair.value.isEmpty {
            if !skippedOwnHandle {
                skippedOwnHandle = true
                continue
            }
            return pair.value
        }
        return nil
    }

    /// File wrapper. Returns nil for anything but `.dxf`/`.dwt`, for
    /// missing files, and for any parse failure — callers fall back to
    /// the MRU index.
    public static func readFile(atPath path: String) -> Hint? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ext == "dxf" || ext == "dwt" else { return nil }
        guard let reader = try? DXFReader().readFile(at: path) else { return nil }
        return read(reader: reader)
    }

    /// Resolve a stored hint against the drawing's folder. Absolute
    /// hints pass through; relative ones resolve beside the drawing.
    public static func resolve(dstPath: String, relativeTo drawingPath: String) -> String {
        let url = URL(fileURLWithPath: dstPath)
        if url.path.hasPrefix("/") || dstPath.range(of: "^[A-Za-z]:[\\\\/]", options: .regularExpression) != nil {
            return dstPath
        }
        return URL(fileURLWithPath: drawingPath)
            .deletingLastPathComponent()
            .appendingPathComponent(dstPath).path
    }
}

import Foundation

// =========================================================================
// MARK: - Import Layouts as Sheets (Step 4: palette flow)
// -------------------------------------------------------------------------
// Builds `SheetSetSheet`s from a drawing's paper-space layouts (LT's
// "Import Layouts as Sheets"). Enumeration reuses
// `PublishMetadataInspector.readFile`, so DXF/DWT work everywhere and
// DWG wherever ODA is available.
// Sheet identity notes: layout names can be stale in real files, so
// `AcDbHandle` normally wins — but handles are unknown without the DXF
// OBJECTS read, and import therefore leaves them empty until the NOD
// work lands. Matching falls back to (file, layout name) meanwhile.
// `Relative_FileName` uses the `.\`-prefixed backslash form LT writes;
// the exact separator style is single-sourced and re-verified at the
// interchange gate.
// =========================================================================

public enum SheetSetLayoutImport {
    /// One sheet per paper-space layout. Numbers/titles stay empty for
    /// the user (or Rename) to fill; the model tab never becomes a sheet.
    public static func sheets(
        from metadata: PublishDrawingMetadata,
        dstFolder: String
    ) -> [SheetSetSheet] {
        metadata.tabs
            .filter { $0.space == .layout }
            .map { tab in
                SheetSetSheet(
                    number: "",
                    title: "",
                    relativeFile: relativePath(from: dstFolder, to: metadata.sourcePath),
                    absoluteFile: metadata.sourcePath,
                    handle: "",
                    layoutName: tab.name)
            }
    }

    /// One drawing's worth of import input (layouts pre-enumerated).
    public struct ImportFile: Sendable, Equatable {
        public var path: String
        public var layouts: [String]

        public init(path: String, layouts: [String]) {
            self.path = path
            self.layouts = layouts
        }
    }

    /// Builds a set the way the wizard's Existing-Drawings flow does:
    /// every paper-space layout becomes a sheet (number empty, title =
    /// layout name, optionally prefixed with the file base name).
    /// With nesting, files group into subsets mirroring their folders
    /// under the deepest common directory; files at that root stay
    /// loose. Files without layouts contribute nothing.
    public static func buildSet(
        name: String,
        description: String,
        dstPath: String,
        files: [ImportFile],
        nestSubsets: Bool,
        prefixTitleWithFile: Bool
    ) -> SheetSet {
        var set = SheetSet(name: name, description: description, dstPath: dstPath)
        let dstFolder = URL(fileURLWithPath: dstPath).deletingLastPathComponent().path
        let root = nestSubsets ? commonRoot(of: files.map(\.path)) : ""
        for file in files {
            let base = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
            let sheets = file.layouts.map { layout in
                SheetSetSheet(
                    number: "",
                    title: prefixTitleWithFile ? "\(base) - \(layout)" : layout,
                    relativeFile: relativePath(from: dstFolder, to: file.path),
                    absoluteFile: file.path,
                    handle: "",
                    layoutName: layout)
            }
            guard !sheets.isEmpty else { continue }
            if nestSubsets, let rel = relativeDir(of: file.path, under: root), !rel.isEmpty {
                place(sheets, into: &set.subsets, components: rel.split(separator: "/").map(String.init))
            } else {
                set.sheets.append(contentsOf: sheets)
            }
        }
        return set
    }

    /// Deepest common directory of the given files (slash-normalized).
    public static func commonRoot(of paths: [String]) -> String {
        let dirs = paths.map { dirName(of: $0) }.filter { !$0.isEmpty }
        guard var prefix = dirs.first?.split(separator: "/").map(String.init) else { return "" }
        for dir in dirs.dropFirst() {
            let parts = dir.split(separator: "/").map(String.init)
            prefix = zip(prefix, parts).prefix(while: { $0.lowercased() == $1.lowercased() }).map(\.0)
            if prefix.isEmpty { return "" }
        }
        return prefix.joined(separator: "/")
    }

    /// Directory of `file` relative to `root` ("" when identical),
    /// nil when `file` is not under `root`.
    public static func relativeDir(of file: String, under root: String) -> String? {
        let dir = dirName(of: file)
        guard !root.isEmpty else { return dir.isEmpty ? "" : nil }
        let key = dir.lowercased()
        let base = root.lowercased()
        if key == base { return "" }
        guard key.hasPrefix(base + "/") else { return nil }
        return String(dir.dropFirst(base.count + 1))
    }

    fileprivate static func dirName(of path: String) -> String {
        var dir = path.replacingOccurrences(of: "\\", with: "/")
        if let slash = dir.lastIndex(of: "/") {
            dir = String(dir[..<slash])
        } else {
            dir = ""
        }
        return dir
    }

    fileprivate static func place(_ sheets: [SheetSetSheet], into subsets: inout [SheetSetSubset], components: [String]) {
        guard let head = components.first else { return }
        let index: Int
        if let found = subsets.firstIndex(where: { $0.name == head }) {
            index = found
        } else {
            subsets.append(SheetSetSubset(name: head))
            index = subsets.count - 1
        }
        if components.count == 1 {
            subsets[index].sheets.append(contentsOf: sheets)
        } else {
            place(sheets, into: &subsets[index].subsets, components: Array(components.dropFirst()))
        }
    }

    /// `.\`-prefixed relative path when `file` lives under `folder`,
    /// else the absolute path. Comparison is slash- and case-insensitive
    /// (Windows-first); the returned remainder keeps its separators.
    public static func relativePath(from folder: String, to file: String) -> String {
        let normFolder = folder.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normFile = file.replacingOccurrences(of: "\\", with: "/")
        guard !normFolder.isEmpty, !normFile.isEmpty else { return file }
        let prefix = normFolder.hasSuffix("/") ? normFolder : normFolder + "/"
        guard normFile.lowercased().hasPrefix(prefix.lowercased()) else { return file }
        let remainder = String(normFile.dropFirst(prefix.count))
        guard !remainder.isEmpty else { return file }
        return ".\\" + remainder.replacingOccurrences(of: "/", with: "\\")
    }
}

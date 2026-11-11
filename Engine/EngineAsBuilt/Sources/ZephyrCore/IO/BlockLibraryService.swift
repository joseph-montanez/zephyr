import Foundation

// =========================================================================
// MARK: - BlockLibraryService
//
// Folder scan + background container parsing for the Blocks palette
// Libraries tab. Mirrors the XrefLoader threading split:
//
//   - UI thread: `scanFolder` returns filenames instantly (no parsing).
//   - Background: `requestParse(entry:)` / `resolveBundle(sourcePath:)`
//     parse off-thread; the caller applies results on the MainActor.
//
// DWG goes through the ODA temp conversion, gated behind a serial actor so
// a 50-DWG folder spawns at most one converter process at a time.
// Converted DXFs are cached by (path, mtime, size) and reused while fresh.
// =========================================================================

public enum BlockLibraryService {
    public static let supportedExtensions: Set<String> = ["dxf", "dwg", "eab"]

    // MARK: - Entries

    /// One file row in a library folder. `containerBlocks` is nil until a
    /// background parse fills it in; `error` carries the failure message.
    public struct FileEntry: Hashable, Sendable {
        public var path: String
        public var displayName: String
        public var modified: Date
        public var size: UInt64
        public var rootPreview: BlockPreview?
        public var containerBlocks: [BlockEntry]?
        public var error: String?

        public var ext: String {
            (path as NSString).pathExtension.lowercased()
        }
    }

    /// One insertable definition inside a container file.
    public struct BlockEntry: Hashable, Sendable {
        public var blockName: String
        public var preview: BlockPreview?
        public var attributeTags: [String]
    }

    // MARK: - Folder scan (instant, no parsing)

    /// Build one library row for a file URL, or nil when the URL is not an
    /// existing supported drawing file (wrong extension, missing, directory).
    /// Shared by `scanFolder` and by session file picks so both paths agree
    /// on what is listable.
    public static func entry(for url: URL) -> FileEntry? {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return nil }
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue
        else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileEntry(
            path: url.path,
            displayName: url.deletingPathExtension().lastPathComponent,
            modified: values?.contentModificationDate ?? .distantPast,
            size: UInt64(values?.fileSize ?? 0))
    }

    public static func scanFolder(at folder: URL) -> [FileEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap(entry(for:)).sorted {
            $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Merge session-picked files into a folder scan: deduped by path,
    /// vanished files dropped, result kept in display order.
    public static func merging(_ entries: [FileEntry], withExtraPaths extraPaths: [String])
        -> [FileEntry]
    {
        var out = entries
        var known = Set(entries.map(\.path))
        for path in extraPaths {
            guard !known.contains(path) else { continue }
            guard let picked = entry(for: URL(fileURLWithPath: path)) else { continue }
            known.insert(path)
            out.append(picked)
        }
        return out.sorted {
            $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Drop session-picked paths that no longer resolve to a listable file
    /// (deleted, replaced by a directory, or an unsupported extension).
    public static func pruningVanished(_ extraPaths: [String]) -> [String] {
        extraPaths.filter { entry(for: URL(fileURLWithPath: $0)) != nil }
    }

    // MARK: - ODA cache

    static func cacheKey(for entry: FileEntry) -> String {
        let raw = "\(entry.path)|\(entry.modified.timeIntervalSince1970)|\(entry.size)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    public static func convertedCacheURL(for entry: FileEntry) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-oda", isDirectory: true)
            .appendingPathComponent(cacheKey(for: entry) + ".dxf")
    }

    private static func cacheIsFresh(_ url: URL, for entry: FileEntry) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let stamp = values.contentModificationDate
        else { return false }
        return stamp >= entry.modified
    }

    /// Serial ODA lane: at most one converter process at a time, no matter
    /// how many background parses are in flight.
    private actor SerialODALane {
        static let shared = SerialODALane()

        func convert(source: URL, destination: URL) throws {
            let fm = FileManager.default
            try? fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try ODADWGConverter.convertSync(
                input: source, output: destination, toFormat: "DXF")
        }
    }

    // MARK: - Bundle resolution (background)

    /// Local parse path for any supported source: the source itself for
    /// `.dxf`/`.eab`, or the serial-lane converted DXF cache for `.dwg`.
    /// All ODA conversion funnels through here, so background parses never
    /// spawn concurrent converter processes.
    static func resolveLocalURL(sourcePath: String) async throws -> URL {
        let ext = (sourcePath as NSString).pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw DrawingFileInsert.InsertError.fileNotFound(sourcePath)
        }
        guard ext == "dwg" else {
            guard supportedExtensions.contains(ext) else {
                throw DrawingFileInsert.InsertError.unsupportedFile(sourcePath)
            }
            return URL(fileURLWithPath: sourcePath)
        }
        let url = URL(fileURLWithPath: sourcePath)
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey])
        let entry = FileEntry(
            path: sourcePath,
            displayName: url.deletingPathExtension().lastPathComponent,
            modified: values?.contentModificationDate ?? .distantPast,
            size: UInt64(values?.fileSize ?? 0))
        let cached = convertedCacheURL(for: entry)
        if !cacheIsFresh(cached, for: entry) {
            try await SerialODALane.shared.convert(source: url, destination: cached)
        }
        return cached
    }

    /// Load the insertable bundle for any supported source path.
    public static func resolveBundle(sourcePath: String) async throws
        -> DrawingFileInsert.ContainerBundle
    {
        let local = try await resolveLocalURL(sourcePath: sourcePath)
        return try DrawingFileInsert.loadContainerBundle(fromFile: local.path)
    }

    /// Fill in one folder row: root (file-as-block) preview plus the
    /// insertable container definitions. Throws on unreadable sources; the
    /// caller records `error` and keeps the row visible.
    public static func requestParse(entry: FileEntry) async throws -> FileEntry {
        var out = entry
        let local = try await resolveLocalURL(sourcePath: entry.path)
        let bundle = try DrawingFileInsert.loadContainerBundle(fromFile: local.path)
        let insertables = bundle.blocks.filter(BlockLibraryPolicy.isUserInsertable)
        out.containerBlocks = insertables.map { block in
            BlockEntry(
                blockName: block.name,
                preview: BlockPreview.build(geometry: block.geometry),
                attributeTags: block.attributeDefinitions.map(\.key))
        }
        if entry.ext == "eab" {
            guard let baked = try? DrawingFileInsert.loadModelSpaceEAB(
                fromFile: local.path).baked
            else {
                out.rootPreview = nil
                return out
            }
            out.rootPreview = BlockPreview.build(geometry: baked.geometry)
            return out
        }
        guard let baked = try? DrawingFileInsert.loadModelSpace(fromFile: local.path).baked
        else {
            out.rootPreview = nil
            return out
        }
        out.rootPreview = BlockPreview.build(geometry: baked.geometry)
        return out
    }
}

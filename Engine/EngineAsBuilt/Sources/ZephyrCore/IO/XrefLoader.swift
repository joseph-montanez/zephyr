import Foundation

// =========================================================================
// MARK: - XrefPathResolver
//
// AutoCAD saved-path semantics: full / relative / no-path, resolved in
// order — saved absolute, relative to the immediate host file, the root
// document's folder, user search paths, then by bare filename in those
// folders. Windows separators and drive prefixes degrade to filename
// search on POSIX systems.
// =========================================================================

public enum XrefPathResolver {

    public static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: normalized(path)).standardizedFileURL.path
    }

    public static func fileName(of savedPath: String) -> String {
        (normalized(savedPath) as NSString).lastPathComponent
    }

    /// Ordered candidate locations for `savedPath` (first existing wins
    /// in `resolve`). Folders may be nil (unsaved document).
    public static func candidates(
        savedPath: String,
        immediateHostFolder: String?,
        documentFolder: String?,
        searchPaths: [String] = [],
        fallbackFolder: String? = nil
    ) -> [String] {
        let clean = normalized(savedPath.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        func add(_ candidate: String?) {
            guard let candidate, !candidate.isEmpty else { return }
            let standardized = (candidate as NSString).standardizingPath
            if seen.insert(standardized).inserted { out.append(standardized) }
        }
        let kind = CADXrefDescriptor.pathKind(of: savedPath)
        if kind == .absolute {
            add(clean)
        }
        let folders = [immediateHostFolder, documentFolder] + searchPaths.map { Optional($0) } + [fallbackFolder]
        if kind == .relative {
            for folder in folders {
                if let folder { add((folder as NSString).appendingPathComponent(clean)) }
            }
        }
        // Bare-filename search (also the POSIX fallback for drive/UNC paths).
        let name = fileName(of: savedPath)
        for folder in folders {
            if let folder { add((folder as NSString).appendingPathComponent(name)) }
        }
        add(clean)  // relative to the process current directory
        return out
    }

    public static func resolve(
        savedPath: String,
        immediateHostFolder: String?,
        documentFolder: String?,
        searchPaths: [String] = [],
        fallbackFolder: String? = nil
    ) -> String? {
        candidates(
            savedPath: savedPath,
            immediateHostFolder: immediateHostFolder,
            documentFolder: documentFolder,
            searchPaths: searchPaths,
            fallbackFolder: fallbackFolder
        ).first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Express `absolutePath` relative to `folder` (AutoCAD relative-path
    /// form "..\x" / ".\x" with platform separators). Returns the
    /// absolute path when no relative form exists.
    public static func relativePath(fromFolder folder: String, to absolutePath: String) -> String {
        let from = (normalized(folder) as NSString).standardizingPath
            .split(separator: "/").map(String.init)
        let to = (normalized(absolutePath) as NSString).standardizingPath
            .split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] {
            common += 1
        }
        guard common > 0 || (from.first == to.first) else { return absolutePath }
        let ups = Array(repeating: "..", count: from.count - common)
        let rest = Array(to.dropFirst(common))
        let parts = ups + rest
        if parts.isEmpty { return absolutePath }
        let joined = parts.joined(separator: "/")
        return ups.isEmpty ? "./" + joined : joined
    }
}

// =========================================================================
// MARK: - XrefLoader
//
// Resolves, reads, bakes and installs xref content. The heavy work
// (file IO, DXF parse, bake) runs off the main actor; applying results
// (store update + dependent-symbol merge + bounds resync) is @MainActor.
// =========================================================================

public enum XrefLoader {

    struct LoadOutcome: Sendable {
        var status: XrefStatus
        var detail: String?
        var foundAtPath: String?
        var canonicalPath: String?
        var fileModifiedAt: Date?
        var fileSize: Int?
        var baked: CADModelSpaceBaker.Baked?
        var grid: CADBlockSpatialGrid?
        var layers: [Layer] = []
        var textStyles: [String: CADTextStyle] = [:]
        var dimensionStyles: [String: CADDimensionStyle] = [:]
        var leaderStyles: [String: CADLeaderStyle] = [:]
        var linetypePatterns: [String: [Double]] = [:]
        var mlineStyles: [String: CADMlineStyle] = [:]
        var children: [XrefChildInfo] = []
    }

    // MARK: - Public @MainActor orchestration

    /// Request (or re-request) loading of one xref definition shared by
    /// `documents` (all views of a tab). No-ops when already loading,
    /// or when loaded and `forceReload` is false.
    @MainActor
    public static func requestLoad(
        store: XrefRuntimeStore,
        blockHandle: UUID,
        documents: [CADDocument],
        hostFolder: String?,
        forceReload: Bool = false
    ) {
        guard let document = documents.first(where: { $0.block(for: blockHandle)?.isXref == true }),
              let block = document.block(for: blockHandle),
              let descriptor = block.xrefDescriptor else { return }
        let entry = store.ensureEntry(
            for: blockHandle, descriptor: descriptor, blockName: block.name)
        if entry.status == .loading { return }
        if entry.status.hasShadowGeometry && !forceReload { return }
        if entry.userUnloaded && !forceReload { return }

        store.updateEntry(for: blockHandle) {
            $0.status = .loading
            $0.statusDetail = nil
            $0.userUnloaded = false
        }
        for doc in documents { doc.markNeedsRegeneration() }

        let limits = store.limits
        let searchPaths = store.searchPaths
        let fallbackFolder = document.xrefSourceFolder
        let blockName = block.name
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                performLoad(
                    descriptor: descriptor,
                    blockName: blockName,
                    hostFolder: hostFolder,
                    fallbackFolder: fallbackFolder,
                    searchPaths: searchPaths,
                    limits: limits,
                    store: store)
            }.value
            apply(outcome, blockHandle: blockHandle, store: store, documents: documents)
        }
    }

    /// Kick loads for every xref definition in the tab's documents that
    /// is not user-unloaded (EAB-persisted unload state respected).
    @MainActor
    public static func loadAllPending(
        store: XrefRuntimeStore, documents: [CADDocument], hostFolder: String?
    ) {
        var handles = Set<UUID>()
        for doc in documents {
            for block in doc.allBlocks where block.isXref {
                handles.insert(block.handle)
                if let descriptor = block.xrefDescriptor {
                    store.ensureEntry(
                        for: block.handle, descriptor: descriptor, blockName: block.name)
                    if doc.eabUnloadedXrefHandles.contains(block.handle) {
                        store.updateEntry(for: block.handle) { $0.userUnloaded = true }
                    }
                }
            }
        }
        for handle in handles where store.status(for: handle) == .unloaded {
            requestLoad(
                store: store, blockHandle: handle,
                documents: documents, hostFolder: hostFolder)
        }
    }

    @MainActor
    static func apply(
        _ outcome: LoadOutcome, blockHandle: UUID,
        store: XrefRuntimeStore, documents: [CADDocument]
    ) {
        // Budget gate at commit time (other loads may have landed first).
        var outcome = outcome
        if outcome.status == .loaded, XrefSysvars.xloadCtl != 0, let baked = outcome.baked {
            let totals = store.loadTotals()
            let selfCount = store.entry(for: blockHandle)?.shadow != nil ? 1 : 0
            let selfPrims = store.entry(for: blockHandle)?.shadow?.geometry.count ?? 0
            if totals.count - selfCount + 1 > store.limits.maxLoadedXrefs
                || totals.primitives - selfPrims + baked.geometry.count > store.limits.maxTotalPrimitives {
                outcome = LoadOutcome(
                    status: .overBudget,
                    detail: "Load limits reached (max \(store.limits.maxLoadedXrefs) xrefs, \(store.limits.maxTotalPrimitives) primitives); unload another xref or raise the limits.",
                    foundAtPath: outcome.foundAtPath,
                    canonicalPath: outcome.canonicalPath,
                    fileModifiedAt: outcome.fileModifiedAt,
                    fileSize: outcome.fileSize,
                    children: outcome.children)
            }
        }

        store.updateEntry(for: blockHandle) { entry in
            entry.status = outcome.status
            entry.statusDetail = outcome.detail
            entry.foundAtPath = outcome.foundAtPath
            entry.canonicalPath = outcome.canonicalPath
            entry.fileModifiedAt = outcome.fileModifiedAt
            entry.fileSize = outcome.fileSize
            entry.children = outcome.children
            entry.grid = outcome.status == .loaded ? outcome.grid : entry.grid
            if let baked = outcome.baked, outcome.status == .loaded {
                entry.shadow = CADBlock(
                    handle: blockHandle,
                    name: entry.blockName,
                    geometry: baked.geometry,
                    primitiveStyles: baked.primitiveStyles,
                    primitiveXData: baked.primitiveXData,
                    xrefDescriptor: entry.descriptor)
            } else if outcome.status != .needsReload {
                entry.shadow = nil
                entry.grid = nil
            }
        }
        if outcome.status == .loaded {
            for doc in documents {
                doc.mergeXrefDependentSymbols(
                    layers: outcome.layers,
                    textStyles: outcome.textStyles,
                    dimensionStyles: outcome.dimensionStyles,
                    leaderStyles: outcome.leaderStyles,
                    linetypePatterns: outcome.linetypePatterns,
                    mlineStyles: outcome.mlineStyles,
                    resetExisting: XrefSysvars.visRetain == 0)
            }
        }
        for doc in documents {
            doc.resyncXrefInstanceBounds(forBlock: blockHandle)
            doc.markNeedsRegeneration()
        }
    }

    /// Re-attempt xrefs that previously failed to resolve (e.g. after
    /// SaveAs moved the host into the folder its relative paths need).
    @MainActor
    public static func retryUnresolved(
        store: XrefRuntimeStore, documents: [CADDocument], hostFolder: String?
    ) {
        for (handle, entry) in store.allEntries()
        where entry.status == .notFound || entry.status == .unresolved || entry.status == .circular {
            store.updateEntry(for: handle) { $0.status = .unloaded }
            requestLoad(
                store: store, blockHandle: handle,
                documents: documents, hostFolder: hostFolder)
        }
        loadAllPending(store: store, documents: documents, hostFolder: hostFolder)
    }

    /// Compare loaded xrefs' file stamps against disk (stat calls run
    /// off the main actor — a dead network path must never stall the
    /// frame loop) and flag changed files as Needs Reloading.
    @MainActor
    public static func checkForChanges(
        store: XrefRuntimeStore, documents: [CADDocument]
    ) {
        let loaded = store.allEntries().filter { $0.entry.status.hasShadowGeometry }
        guard !loaded.isEmpty else { return }
        let stamps: [(UUID, String, Date?, Int?)] = loaded.compactMap { handle, entry in
            guard let path = entry.foundAtPath else { return nil }
            return (handle, path, entry.fileModifiedAt, entry.fileSize)
        }
        Task { @MainActor in
            let changed: [UUID] = await Task.detached {
                stamps.compactMap { handle, path, mtime, size in
                    let now = fileStamp(of: path)
                    return (now.modifiedAt != mtime || now.size != size) ? handle : nil
                }
            }.value
            guard !changed.isEmpty else { return }
            for handle in changed {
                store.updateEntry(for: handle) {
                    if $0.status == .loaded { $0.status = .needsReload }
                }
            }
            for doc in documents { doc.markNeedsRegeneration() }
        }
    }

    @MainActor
    public static func unload(
        store: XrefRuntimeStore, blockHandle: UUID, documents: [CADDocument]
    ) {
        store.updateEntry(for: blockHandle) {
            $0.status = .unloaded
            $0.statusDetail = nil
            $0.shadow = nil
            $0.grid = nil
            $0.userUnloaded = true
        }
        for doc in documents {
            doc.resyncXrefInstanceBounds(forBlock: blockHandle)
            doc.markNeedsRegeneration()
        }
    }

    // MARK: - Background load

    static func fileStamp(of path: String) -> (modifiedAt: Date?, size: Int?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date, (attrs?[.size] as? NSNumber)?.intValue)
    }

    static func performLoad(
        descriptor: CADXrefDescriptor,
        blockName: String,
        hostFolder: String?,
        fallbackFolder: String?,
        searchPaths: [String],
        limits: XrefLoadLimits,
        store: XrefRuntimeStore
    ) -> LoadOutcome {
        guard let found = XrefPathResolver.resolve(
            savedPath: descriptor.savedPath,
            immediateHostFolder: hostFolder,
            documentFolder: hostFolder,
            searchPaths: searchPaths,
            fallbackFolder: fallbackFolder)
        else {
            return LoadOutcome(
                status: .notFound,
                detail: "Saved path \"\(descriptor.savedPath)\" could not be resolved.")
        }
        let canonical = XrefPathResolver.canonicalPath(found)
        let stamp = fileStamp(of: found)
        do {
            let built = try buildContent(
                filePath: found, canonical: canonical, stamp: stamp,
                prefixName: blockName, depth: 1, chain: [canonical],
                documentFolder: hostFolder, fallbackFolder: fallbackFolder,
                searchPaths: searchPaths, limits: limits, store: store)
            return LoadOutcome(
                status: .loaded, detail: nil,
                foundAtPath: found, canonicalPath: canonical,
                fileModifiedAt: stamp.modifiedAt, fileSize: stamp.size,
                baked: built.baked, grid: built.grid, layers: built.layers,
                textStyles: built.textStyles,
                dimensionStyles: built.dimensionStyles,
                leaderStyles: built.leaderStyles,
                linetypePatterns: built.linetypePatterns,
                mlineStyles: built.mlineStyles,
                children: built.children)
        } catch let error as DrawingFileInsert.InsertError {
            return LoadOutcome(
                status: .unresolved, detail: "\(error)",
                foundAtPath: found, canonicalPath: canonical,
                fileModifiedAt: stamp.modifiedAt, fileSize: stamp.size)
        } catch {
            return LoadOutcome(
                status: .unresolved, detail: "\(error)",
                foundAtPath: found, canonicalPath: canonical,
                fileModifiedAt: stamp.modifiedAt, fileSize: stamp.size)
        }
    }

    struct BuiltContent: Sendable {
        var baked: CADModelSpaceBaker.Baked
        var grid: CADBlockSpatialGrid?
        var layers: [Layer] = []
        var textStyles: [String: CADTextStyle] = [:]
        var dimensionStyles: [String: CADDimensionStyle] = [:]
        var leaderStyles: [String: CADLeaderStyle] = [:]
        var linetypePatterns: [String: [Double]] = [:]
        var mlineStyles: [String: CADMlineStyle] = [:]
        var children: [XrefChildInfo] = []
    }

    static func importFile(
        at path: String, canonical: String,
        stamp: (modifiedAt: Date?, size: Int?), store: XrefRuntimeStore
    ) throws -> DXFImportResult {
        if let cached = store.cachedImport(
            canonicalPath: canonical, modifiedAt: stamp.modifiedAt, fileSize: stamp.size) {
            return cached
        }
        let imported = try DrawingFileInsert.loadImportedFile(fromFile: path)
        store.storeImport(
            canonicalPath: canonical, modifiedAt: stamp.modifiedAt,
            fileSize: stamp.size, result: imported)
        return imported
    }

    static func buildContent(
        filePath: String, canonical: String,
        stamp: (modifiedAt: Date?, size: Int?),
        prefixName: String, depth: Int, chain: [String],
        documentFolder: String?, fallbackFolder: String?,
        searchPaths: [String], limits: XrefLoadLimits,
        store: XrefRuntimeStore
    ) throws -> BuiltContent {
        let imported = try importFile(at: filePath, canonical: canonical, stamp: stamp, store: store)
        let immediateFolder = (canonical as NSString).deletingLastPathComponent

        var augmentedBlocks = imported.blocks
        var built = BuiltContent(baked: CADModelSpaceBaker.Baked())

        // Expand nested attachment xrefs into this content.
        for pending in imported.pendingXrefs {
            func child(_ status: XrefStatus, _ detail: String?, _ kids: [XrefChildInfo] = []) {
                built.children.append(XrefChildInfo(
                    blockName: pending.blockName, savedPath: pending.savedPath,
                    isOverlay: pending.isOverlay, status: status,
                    detail: detail, children: kids))
            }
            if pending.isOverlay {
                child(.orphaned, "Overlay of a nested xref is not loaded.")
                continue
            }
            if depth >= limits.maxNestingDepth {
                child(.orphaned, "Maximum nesting depth (\(limits.maxNestingDepth)) reached.")
                continue
            }
            guard let nestedFound = XrefPathResolver.resolve(
                savedPath: pending.savedPath,
                immediateHostFolder: immediateFolder,
                documentFolder: documentFolder,
                searchPaths: searchPaths,
                fallbackFolder: fallbackFolder)
            else {
                child(.notFound, "Saved path \"\(pending.savedPath)\" could not be resolved.")
                continue
            }
            let nestedCanonical = XrefPathResolver.canonicalPath(nestedFound)
            if chain.contains(nestedCanonical) {
                child(.circular, "Circular reference through \(pending.blockName).")
                continue
            }
            do {
                let nestedBuilt = try buildContent(
                    filePath: nestedFound, canonical: nestedCanonical,
                    stamp: fileStamp(of: nestedFound),
                    prefixName: pending.blockName, depth: depth + 1,
                    chain: chain + [nestedCanonical],
                    documentFolder: documentFolder,
                    fallbackFolder: fallbackFolder,
                    searchPaths: searchPaths, limits: limits, store: store)
                if let idx = augmentedBlocks.firstIndex(where: { $0.handle == pending.blockHandle }) {
                    augmentedBlocks[idx] = CADBlock(
                        handle: pending.blockHandle,
                        name: pending.blockName,
                        geometry: nestedBuilt.baked.geometry,
                        primitiveStyles: nestedBuilt.baked.primitiveStyles,
                        primitiveXData: nestedBuilt.baked.primitiveXData)
                }
                mergeSymbols(from: nestedBuilt, into: &built)
                child(.loaded, nil, nestedBuilt.children)
            } catch {
                child(.unresolved, "\(error)")
            }
        }

        // Bake this file's own model space (nested inserts resolve
        // against the augmented blocks), then rewrite dependent names.
        var baked = CADModelSpaceBaker.bake(
            entities: imported.entities,
            layers: imported.layers,
            blocks: augmentedBlocks,
            basePoint: imported.insBase)
        rewriteDependentNames(
            in: &baked, imported: imported, prefix: prefixName, into: &built)
        built.baked = baked
        if baked.geometry.count > CADBlockSpatialGrid.buildThreshold {
            built.grid = CADBlockSpatialGrid(primitives: baked.geometry)
        }
        return built
    }

    private static func mergeSymbols(from child: BuiltContent, into parent: inout BuiltContent) {
        let existing = Set(parent.layers.map { $0.name.uppercased() })
        parent.layers += child.layers.filter { !existing.contains($0.name.uppercased()) }
        for (k, v) in child.textStyles where parent.textStyles[k] == nil { parent.textStyles[k] = v }
        for (k, v) in child.dimensionStyles where parent.dimensionStyles[k] == nil { parent.dimensionStyles[k] = v }
        for (k, v) in child.leaderStyles where parent.leaderStyles[k] == nil { parent.leaderStyles[k] = v }
        for (k, v) in child.linetypePatterns where parent.linetypePatterns[k] == nil { parent.linetypePatterns[k] = v }
    }

    /// Prefix this file's own symbol names as `Prefix|Name` inside the
    /// baked styles/xdata and collect the renamed definitions. Names
    /// already containing "|" came from nested content and are left
    /// alone; layer "0" and built-in linetypes are never prefixed.
    private static func rewriteDependentNames(
        in baked: inout CADModelSpaceBaker.Baked,
        imported: DXFImportResult,
        prefix: String,
        into built: inout BuiltContent
    ) {
        func prefixed(_ name: String) -> String { "\(prefix)|\(name)" }
        let layerMap = Dictionary(uniqueKeysWithValues: imported.layers.compactMap { layer -> (String, String)? in
            layer.name == "0" ? nil : (layer.name.uppercased(), prefixed(layer.name))
        })
        let builtinLinetypes: Set<String> = ["CONTINUOUS", "BYLAYER", "BYBLOCK"]
        let linetypeMap = Dictionary(uniqueKeysWithValues: imported.linetypePatterns.keys.compactMap { key -> (String, String)? in
            builtinLinetypes.contains(key.uppercased()) ? nil : (key.uppercased(), prefixed(key))
        })
        let mlineStyleMap = Dictionary(uniqueKeysWithValues: imported.mlineStyles.keys.map {
            ($0.uppercased(), prefixed($0))
        })
        let textStyleMap = Dictionary(uniqueKeysWithValues: imported.textStyles.keys.map {
            ($0.uppercased(), prefixed($0))
        })

        for layer in imported.layers where layer.name != "0" {
            var copy = layer
            copy.name = prefixed(layer.name)
            if let lt = linetypeMap[layer.lineType.uppercased()] { copy.lineType = lt }
            built.layers.append(copy)
        }
        for (name, style) in imported.textStyles {
            var copy = style
            copy.name = prefixed(name)
            built.textStyles[prefixed(name)] = copy.normalized
        }
        for (name, style) in imported.dimensionStyles {
            built.dimensionStyles[prefixed(name)] = style
        }
        for (name, style) in imported.leaderStyles {
            var copy = style
            copy.name = prefixed(name)
            built.leaderStyles[prefixed(name)] = copy
        }
        for (name, style) in imported.mlineStyles {
            var copy = style
            copy.name = prefixed(name)
            built.mlineStyles[prefixed(name)] = copy
        }
        for (name, pattern) in imported.linetypePatterns
        where !builtinLinetypes.contains(name.uppercased()) {
            built.linetypePatterns[prefixed(name)] = pattern
        }

        func rewrite(_ name: String?, via map: [String: String]) -> String? {
            guard let name, !name.contains("|") else { return name }
            return map[name.uppercased()] ?? name
        }
        for (index, style) in baked.primitiveStyles {
            var style = style
            style.layerName = rewrite(style.layerName, via: layerMap)
            style.lineType = rewrite(style.lineType, via: linetypeMap)
            baked.primitiveStyles[index] = style
        }
        for (index, xdata) in baked.primitiveXData {
            var xdata = xdata
            if case .string(let name) = xdata["dxf.textStyle"],
               let mapped = rewrite(name, via: textStyleMap) {
                xdata["dxf.textStyle"] = .string(mapped)
            }
            if case .string(let name) = xdata["dxf.mlineStyle"],
               let mapped = rewrite(name, via: mlineStyleMap) {
                xdata["dxf.mlineStyle"] = .string(mapped)
            }
            if case .string(let name) = xdata["dxf.lineType"],
               let mapped = rewrite(name, via: linetypeMap) {
                xdata["dxf.lineType"] = .string(mapped)
            }
            baked.primitiveXData[index] = xdata
        }
    }
}

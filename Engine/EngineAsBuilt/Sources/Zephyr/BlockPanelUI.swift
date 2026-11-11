import ZephyrCore
import Foundation
import ImGui

// MARK: - BlockPanelUI
//
// Tabbed Blocks palette (BLOCKSPALETTE): Current / Recent / Favorites /
// Libraries. Heavy file I/O stays off the MainActor render path — folder
// scans list filenames instantly while container parses fill in through
// background tasks (serial ODA lane, see BlockLibraryService).
//
// Insertion always funnels into InsertCommand with palette bottom-bar
// options (Explode / Repeat / Prompt for attributes).

@MainActor
struct BlockPanelUI {
    /// Track docking state of this window.
    static var _isDockedBySlot: [WindowSlotID: Bool] = [:]

    // MARK: - Panel state (MainActor)

    private static var searchText: String = ""
    private static var libraryFolderField: String = ""
    private static var libraryFolderReady: Bool = false
    private static var libraryScannedFolder: String = ""
    private static var libraryError: String? = nil
    /// Session-picked drawing files (Add Files…), listed alongside the
    /// folder scan. Not persisted; re-merged on every rescan.
    private static var libraryExtraPaths: [String] = []
    private static var libraryEntries: [BlockLibraryService.FileEntry] = []
    private static var libraryParses: [String: Task<Void, Never>] = [:]
    private static var collapsedPaths = Set<String>()
    private static var sessionRecent: [String] = []

    private struct CurrentRow {
        var handle: UUID
        var name: String
        var count: Int
        var preview: BlockPreview
        var tags: [String]
    }

    private static var currentCache: (
        doc: ObjectIdentifier?, edit: UInt64, render: UInt64, rows: [CurrentRow]
    ) = (nil, 0, 0, [])

    /// Renders the block panel window.
    /// - Parameter engine: The engine instance for document access and command execution.
    static func render(engine: PhrostEngine) {
        let doc = engine.document

        // Size the window based on font size for proportional scaling.
        ImGuiSetNextWindowSize(
            ImVec2(x: ImGuiGetFontSize() * 24, y: ImGuiGetFontSize() * 32),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let isDocked = _isDockedBySlot[engine.ui.frameSlot] ?? false
        var flags = Int32(0)
        if isDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("Blocks##BlockPanel", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("Blocks##BlockPanel", &opened, flags)
        }
        _isDockedBySlot[engine.ui.frameSlot] = ImGuiIsWindowDocked()
        AppLayout.reportCurrentDockedPanel(engine: engine)

        guard entered else {
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
            return
        }
        defer {
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
        }

        if !isDocked && !opened {
            engine.ui.blockPanelVisible = false
            return
        }

        ImGuiTextV("Blocks")
        ImGuiSameLine(0, 8)

        // "Create Block" button — only enabled when entities are selected.
        // A block cannot be created from an empty selection.
        let hasSelection = engine.cadSelection.hasSelection
        if !hasSelection {
            ImGuiBeginDisabled(true)
        }
        if igButton("Create Block", ImVec2(x: 0, y: 0)) {
            engine.commandProcessor.executeCommand("BLOCK")
        }
        if !hasSelection {
            ImGuiEndDisabled()
        }

        igSeparator()

        _ = DataTablePanelUI.inputText(
            id: "##blocksearch", value: &searchText, enterReturnsTrue: false)

        igSeparator()

        if ImGuiBeginTabBar("BlocksPaletteTabs", 0) {
            if ImGuiBeginTabItem("Current", nil, 0) {
                renderCurrentTab(engine: engine, doc: doc)
                ImGuiEndTabItem()
            }
            if ImGuiBeginTabItem("Recent", nil, 0) {
                renderRecentTab(engine: engine, doc: doc)
                ImGuiEndTabItem()
            }
            if ImGuiBeginTabItem("Favorites", nil, 0) {
                renderFavoritesTab(engine: engine, doc: doc)
                ImGuiEndTabItem()
            }
            if ImGuiBeginTabItem("Libraries", nil, 0) {
                renderLibrariesTab(engine: engine)
                ImGuiEndTabItem()
            }
            ImGuiEndTabBar()
        }

        igSeparator()

        // Insertion parameter controls (persisted via UserSettings.capture).
        _ = ImGuiCheckbox("Explode", &engine.ui.blockInsertExplode)
        ImGuiSameLine(0, 8)
        _ = ImGuiCheckbox("Repeat", &engine.ui.blockInsertRepeat)
        ImGuiSameLine(0, 8)
        _ = ImGuiCheckbox("Prompt attributes", &engine.ui.blockInsertPromptAttributes)
    }

    // MARK: - Shared widgets

    private static func col(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> UInt32 {
        igGetColorU32_Vec4(ImVec4(x: r / 255, y: g / 255, z: b / 255, w: a / 255))
    }

    /// Vector thumbnail cell: reserves `size` px, then draws fitted preview
    /// segments (aspect preserved, block-local origin kept).
    private static func previewCell(_ preview: BlockPreview?, size: Float) {
        let dl = ImGuiGetWindowDrawList()!
        let origin = ImGuiGetCursorScreenPos()
        _ = igInvisibleButton("##blockpv", ImVec2(x: size, y: size), 0)
        let corner = ImVec2(x: origin.x + size, y: origin.y + size)
        ImDrawListAddRect(dl, origin, corner, col(150, 150, 150, 255), 0.0, 1.0, 0)
        guard let preview, !preview.isEmpty else { return }
        let w = max(preview.width, 1e-6)
        let h = max(preview.height, 1e-6)
        let s = min(size / w, size / h)
        let ox = origin.x + (size - w * s) / 2 - preview.boundsMin.x * s
        let oy = origin.y + (size - h * s) / 2 - preview.boundsMin.y * s
        let line = col(255, 217, 51, 230)
        for seg in preview.segments {
            ImDrawListAddLine(
                dl,
                ImVec2(x: ox + seg.x0 * s, y: oy + seg.y0 * s),
                ImVec2(x: ox + seg.x1 * s, y: oy + seg.y1 * s), line, 1.0)
        }
    }

    private static func matchesSearch(_ name: String) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return name.range(of: q, options: .caseInsensitive) != nil
    }

    // MARK: - Insert dispatch

    /// Funnel every palette insert through one configured InsertCommand and
    /// record Recent (persisted refs for pathed sources, session names for
    /// unsaved in-drawing blocks).
    private static func beginInsert(
        engine: PhrostEngine,
        source: InsertCommand.Source,
        preview: BlockPreview?,
        record: BlockLibraryRef?,
        sessionName: String?
    ) {
        if let sessionName, !sessionRecent.contains(sessionName) {
            sessionRecent.insert(sessionName, at: 0)
            sessionRecent = Array(sessionRecent.prefix(50))
        }
        if let record {
            BlockLibraryPolicy.recordRecent(record, into: &engine.ui.blockRecent)
        }
        let cmd = InsertCommand(source: source, preview: preview)
        cmd.explodeOnInsert = engine.ui.blockInsertExplode
        cmd.repeatPlacement = engine.ui.blockInsertRepeat
        cmd.promptForAttributes = engine.ui.blockInsertPromptAttributes
        engine.commandProcessor.activateFeatureCommand(cmd)
    }

    private static func refForCurrentBlock(name: String, engine: PhrostEngine) -> BlockLibraryRef? {
        guard let url = engine.tabManager.activeFileURL else { return nil }
        return BlockLibraryRef(kind: .container, path: url.path, block: name)
    }

    private static func toggleFavorite(engine: PhrostEngine, ref: BlockLibraryRef) {
        if let i = engine.ui.blockFavorites.firstIndex(where: {
            $0.kind == ref.kind && $0.path == ref.path && $0.block == ref.block
        }) {
            engine.ui.blockFavorites.remove(at: i)
        } else {
            engine.ui.blockFavorites.append(ref)
        }
    }

    private static func isFavorite(engine: PhrostEngine, ref: BlockLibraryRef) -> Bool {
        engine.ui.blockFavorites.contains {
            $0.kind == ref.kind && $0.path == ref.path && $0.block == ref.block
        }
    }

    // MARK: - Current tab

    private static func currentRows(doc: CADDocument) -> [CurrentRow] {
        let key = (ObjectIdentifier(doc), doc.editRevision, doc.renderRevision)
        if currentCache.doc == key.0, currentCache.edit == key.1,
           currentCache.render == key.2 {
            return currentCache.rows
        }
        // Single O(entities) pass (the old per-block filter was O(n*m)).
        var counts: [UUID: Int] = [:]
        for entity in doc.entitiesView {
            if let bid = entity.blockID {
                counts[bid, default: 0] += 1
            }
        }
        let rows = doc.allBlocks
            .filter(BlockLibraryPolicy.isUserInsertable)
            .map { block in
                CurrentRow(
                    handle: block.handle,
                    name: block.name,
                    count: counts[block.handle] ?? 0,
                    preview: BlockPreview.build(geometry: block.geometry),
                    tags: block.attributeDefinitions.map(\.key))
            }
            .sorted {
                $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
            }
        currentCache = (key.0, key.1, key.2, rows)
        return rows
    }

    private static func renderCurrentTab(engine: PhrostEngine, doc: CADDocument) {
        let rows = currentRows(doc: doc).filter { matchesSearch($0.name) }
        if rows.isEmpty {
            ImGuiTextV("No blocks in this document.")
            return
        }
        var rowIdx: Int32 = 0
        for row in rows {
            rowIdx &+= 1
            ImGuiPushID(rowIdx)
            previewCell(row.preview, size: 56)
            ImGuiSameLine(0, 8)
            ImGuiTextV("\(row.name) (\(row.count))")
            if !row.tags.isEmpty {
                ImGuiSameLine(0, 8)
                ImGuiTextV("[\(row.tags.joined(separator: ", "))]")
            }
            ImGuiSameLine(0, 8)
            if igSmallButton("Insert") {
                beginInsert(
                    engine: engine,
                    source: .resident(name: row.name),
                    preview: row.preview,
                    record: refForCurrentBlock(name: row.name, engine: engine),
                    sessionName: engine.tabManager.activeFileURL == nil ? row.name : nil)
            }
            ImGuiSameLine(0, 4)
            // Enter block editor — isolates this block's geometry for in-place editing.
            if igSmallButton("Edit") {
                engine.tabManager.enterBlockEditor(blockID: row.handle)
                engine.cadSelection.clearSelection()
            }
            ImGuiSameLine(0, 4)
            // Write this definition to a DXF/DWG file: skips straight to
            // the destination step (no source or base-point questions —
            // block output is block-local at the origin).
            if igSmallButton("Export") {
                let cmd = WblockCommand(useFileDialog: true)
                cmd.seedBlockExport(name: row.name)
                engine.commandProcessor.activateFeatureCommand(cmd)
            }
            if let ref = refForCurrentBlock(name: row.name, engine: engine) {
                ImGuiSameLine(0, 4)
                let star = isFavorite(engine: engine, ref: ref) ? "Unpin" : "Pin"
                if igSmallButton(star) {
                    toggleFavorite(engine: engine, ref: ref)
                }
            }
            ImGuiPopID()
        }
    }

    // MARK: - Recent / Favorites tabs

    private static func refAvailable(_ ref: BlockLibraryRef, doc: CADDocument) -> Bool {
        guard FileManager.default.fileExists(atPath: ref.path) else { return false }
        return true
    }

    private static func renderRefRow(
        engine: PhrostEngine, doc: CADDocument, ref: BlockLibraryRef,
        trailing: (PhrostEngine) -> Void
    ) {
        ImGuiPushID(ref.path + "\n" + (ref.block ?? ""))
        let missing = !refAvailable(ref, doc: doc)
        let label = missing ? "\(ref.displayName) (missing)" : ref.displayName
        ImGuiTextV(label)
        ImGuiSameLine(0, 8)
        ImGuiTextV(ref.kind == .file ? "(file)" : "(block)")
        ImGuiSameLine(0, 8)
        if igSmallButton("Insert") {
            let source: InsertCommand.Source
            switch ref.kind {
            case .file:
                source = .file(path: ref.path)
            case .container:
                source = .container(path: ref.path, block: ref.block ?? "")
            }
            beginInsert(
                engine: engine, source: source, preview: nil,
                record: ref, sessionName: nil)
        }
        ImGuiSameLine(0, 4)
        trailing(engine)
        ImGuiPopID()
    }

    private static func renderRecentTab(engine: PhrostEngine, doc: CADDocument) {
        let names = Set(doc.allBlocks.map(\.name))
        let live = sessionRecent.filter { names.contains($0) }
        var shown = false
        for name in live.filter({ matchesSearch($0) }) {
            shown = true
            ImGuiPushID("recent\n" + name)
            ImGuiTextV("\(name) (this drawing)")
            ImGuiSameLine(0, 8)
            if igSmallButton("Insert") {
                beginInsert(
                    engine: engine,
                    source: .resident(name: name),
                    preview: doc.allBlocks.first { $0.name == name }
                        .map { BlockPreview.build(geometry: $0.geometry) },
                    record: nil,
                    sessionName: name)
            }
            ImGuiSameLine(0, 4)
            if igSmallButton("Remove") {
                sessionRecent.removeAll { $0 == name }
            }
            ImGuiPopID()
        }
        for ref in engine.ui.blockRecent.filter({ matchesSearch($0.displayName) }) {
            shown = true
            renderRefRow(engine: engine, doc: doc, ref: ref) { engine in
                if igSmallButton("Remove") {
                    engine.ui.blockRecent.removeAll {
                        $0.kind == ref.kind && $0.path == ref.path && $0.block == ref.block
                    }
                }
            }
        }
        if !shown {
            ImGuiTextV("No recent blocks yet.")
        }
    }

    private static func renderFavoritesTab(engine: PhrostEngine, doc: CADDocument) {
        let refs = engine.ui.blockFavorites.filter { matchesSearch($0.displayName) }
        if refs.isEmpty {
            ImGuiTextV("No favorites yet. Pin blocks from Current or Libraries.")
            return
        }
        for ref in refs {
            renderRefRow(engine: engine, doc: doc, ref: ref) { engine in
                if igSmallButton("Unpin") {
                    toggleFavorite(engine: engine, ref: ref)
                }
            }
        }
    }

    // MARK: - Libraries tab

    private static func libraryFolder(engine: PhrostEngine) -> String {
        if !libraryFolderReady {
            if let first = engine.ui.blockLibraryFolders.first, !first.isEmpty {
                libraryFolderField = first
            } else if case let .string(path)? = engine.commandProcessor.systemVariable(
                "BLOCKSLIBRARYPATH"),
                !path.isEmpty {
                libraryFolderField = path
            }
            libraryFolderReady = true
        }
        return libraryFolderField
    }

    private static func renderLibrariesTab(engine: PhrostEngine) {
        _ = libraryFolder(engine: engine)
        let committed = DataTablePanelUI.inputText(
            id: "##libraryfolder", value: &libraryFolderField, enterReturnsTrue: true)
        ImGuiSameLine(0, 8)
        // Load always rescans (even for an unchanged path) so drawings
        // added on disk since the last scan appear.
        if igSmallButton("Load") || committed {
            commitLibraryFolder(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igSmallButton("Browse…") {
            browseLibraryFolder(engine: engine)
        }
        ImGuiSameLine(0, 8)
        if igSmallButton("Add Files…") {
            addLibraryFiles(engine: engine)
        }
        renderLibraryRecent(engine: engine)
        igSeparator()
        if let error = libraryError {
            ImGuiTextV(error)
        }
        if libraryEntries.isEmpty {
            if libraryError == nil {
                ImGuiTextV(
                    libraryScannedFolder.isEmpty && libraryExtraPaths.isEmpty
                        ? "Enter a library folder above, or Browse / Add Files."
                        : "No drawings found in this folder.")
            }
            return
        }
        pumpLibraryParses(maxInflight: 4)
        var shown = 0
        for entry in libraryEntries.prefix(200) {
            renderLibraryFileRow(engine: engine, entry: entry)
            shown += 1
        }
        if libraryEntries.count > shown {
            ImGuiTextV("…and \(libraryEntries.count - shown) more.")
        }
    }

    /// Commit the folder field: persist the MRU, then rescan. An empty
    /// field is a no-op (the previous list stays visible).
    private static func commitLibraryFolder(engine: PhrostEngine) {
        let trimmed = libraryFolderField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        libraryFolderField = trimmed
        BlockLibraryPolicy.recordLibraryFolder(
            trimmed, into: &engine.ui.blockLibraryFolders)
        rescanLibraries()
    }

    /// Folder picker for the library path. Cancelling leaves everything
    /// unchanged; picking sets the field and rescans like Load.
    private static func browseLibraryFolder(engine: PhrostEngine) {
        let start = libraryFolderField.trimmingCharacters(in: .whitespacesAndNewlines)
        NativeFileDialog.showOpenFolderDialog(
            window: engine.dialogParentWindow,
            defaultLocation: start.isEmpty ? nil : start
        ) { [weak engine] urls in
            guard let engine, let url = urls.first else { return }
            libraryFolderField = url.path
            commitLibraryFolder(engine: engine)
        }
    }

    /// Single-file picks (DWG/DXF/EAB) listed alongside the folder scan
    /// for this session. Already-listed and unsupported files are skipped.
    private static func addLibraryFiles(engine: PhrostEngine) {
        NativeFileDialog.showOpenDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(
                label: "Drawings", extensions: ["dxf", "dwg", "eab"])],
            allowMultiple: true
        ) { urls in
            var added = false
            for url in urls {
                guard !libraryExtraPaths.contains(url.path),
                      !libraryEntries.contains(where: { $0.path == url.path }),
                      BlockLibraryService.entry(for: url) != nil
                else { continue }
                libraryExtraPaths.append(url.path)
                added = true
            }
            guard added else { return }
            libraryExtraPaths = BlockLibraryService.pruningVanished(libraryExtraPaths)
            libraryEntries = BlockLibraryService.merging(
                libraryEntries, withExtraPaths: libraryExtraPaths)
        }
    }

    /// Recent-libraries dropdown (most-recent first, persisted). Picking a
    /// folder sets the field and rescans like Load.
    private static func renderLibraryRecent(engine: PhrostEngine) {
        let recent = engine.ui.blockLibraryFolders
        guard !recent.isEmpty else { return }
        ImGuiSameLine(0, 8)
        ImGuiSetNextItemWidth(160)
        if ImGuiBeginCombo("##libraryrecent", "Recent", 0) {
            for folder in recent {
                if ImGuiSelectable(
                    folder, folder == libraryFolderField, 0, ImVec2(x: 0, y: 0))
                {
                    libraryFolderField = folder
                    commitLibraryFolder(engine: engine)
                }
            }
            ImGuiEndCombo()
        }
    }

    private static func rescanLibraries() {
        for task in libraryParses.values {
            task.cancel()
        }
        libraryParses = [:]
        collapsedPaths = []
        libraryError = nil
        libraryExtraPaths = BlockLibraryService.pruningVanished(libraryExtraPaths)
        var isDir = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: libraryFolderField, isDirectory: &isDir)
        if !libraryFolderField.isEmpty, (!exists || !isDir.boolValue) {
            libraryError = "Folder not found: \(libraryFolderField)"
            libraryEntries = BlockLibraryService.merging(
                [], withExtraPaths: libraryExtraPaths)
        } else {
            let url = URL(fileURLWithPath: libraryFolderField)
            libraryEntries = BlockLibraryService.merging(
                libraryFolderField.isEmpty
                    ? [] : BlockLibraryService.scanFolder(at: url),
                withExtraPaths: libraryExtraPaths)
        }
        libraryScannedFolder = libraryFolderField
    }

    private static func pumpLibraryParses(maxInflight: Int) {
        let folder = libraryScannedFolder
        for entry in libraryEntries {
            guard libraryParses.count < maxInflight else { break }
            guard entry.containerBlocks == nil, entry.error == nil,
                  libraryParses[entry.path] == nil
            else { continue }
            libraryParses[entry.path] = Task.detached {
                let parsed = try? await BlockLibraryService.requestParse(entry: entry)
                await MainActor.run {
                    libraryParses[entry.path] = nil
                    guard libraryScannedFolder == folder else { return }
                    guard let i = libraryEntries.firstIndex(where: { $0.path == entry.path })
                    else { return }
                    if let parsed {
                        libraryEntries[i] = parsed
                    } else {
                        libraryEntries[i].error = "Unreadable file"
                    }
                }
            }
        }
    }

    private static func renderLibraryFileRow(engine: PhrostEngine, entry: BlockLibraryService.FileEntry) {
        // Scope the repeated "Insert file"/"Pin" labels: without this every
        // visible file row shares one ID and Dear ImGui asserts.
        ImGuiPushID(entry.path)
        // File thumbnail (model-space content): block-definition-only files
        // show their root preview here so (0 blocks) rows are not blank.
        previewCell(entry.rootPreview, size: 44)
        ImGuiSameLine(0, 8)
        let collapsed = collapsedPaths.contains(entry.path)
        if igSmallButton(collapsed ? "+##\(entry.path)" : "-##\(entry.path)") {
            if collapsed {
                collapsedPaths.remove(entry.path)
            } else {
                collapsedPaths.insert(entry.path)
            }
        }
        ImGuiSameLine(0, 4)
        ImGuiTextV("\(entry.displayName).\(entry.ext)")
        ImGuiSameLine(0, 8)
        if let error = entry.error {
            ImGuiTextV("(\(error))")
        } else if let blocks = entry.containerBlocks {
            let shown = blocks.filter { matchesSearch($0.blockName) }
            ImGuiTextV("(\(blocks.count) blocks)")
            ImGuiSameLine(0, 8)
            if igSmallButton("Insert file") {
                beginInsert(
                    engine: engine,
                    source: .file(path: entry.path),
                    preview: entry.rootPreview,
                    record: BlockLibraryRef(kind: .file, path: entry.path),
                    sessionName: nil)
            }
            ImGuiSameLine(0, 4)
            let fileRef = BlockLibraryRef(kind: .file, path: entry.path)
            if igSmallButton(isFavorite(engine: engine, ref: fileRef) ? "Unpin" : "Pin") {
                toggleFavorite(engine: engine, ref: fileRef)
            }
            if !collapsed {
                for block in shown {
                    renderLibraryBlockRow(engine: engine, filePath: entry.path, block: block)
                }
            }
        } else {
            ImGuiTextV("(…)")
        }
        ImGuiPopID()
    }

    private static func renderLibraryBlockRow(
        engine: PhrostEngine, filePath: String, block: BlockLibraryService.BlockEntry
    ) {
        // Stable string scope: hash-based IDs collide (and Swift hashes
        // vary per launch), which trips the duplicate-ID assert.
        ImGuiPushID(filePath + "\n" + block.blockName)
        previewCell(block.preview, size: 44)
        ImGuiSameLine(0, 8)
        ImGuiTextV("\(block.blockName)")
        if !block.attributeTags.isEmpty {
            ImGuiSameLine(0, 8)
            ImGuiTextV("[\(block.attributeTags.joined(separator: ", "))]")
        }
        ImGuiSameLine(0, 8)
        if igSmallButton("Insert") {
            beginInsert(
                engine: engine,
                source: .container(path: filePath, block: block.blockName),
                preview: block.preview,
                record: BlockLibraryRef(
                    kind: .container, path: filePath, block: block.blockName),
                sessionName: nil)
        }
        ImGuiSameLine(0, 4)
        let ref = BlockLibraryRef(kind: .container, path: filePath, block: block.blockName)
        if igSmallButton(isFavorite(engine: engine, ref: ref) ? "Unpin" : "Pin") {
            toggleFavorite(engine: engine, ref: ref)
        }
        ImGuiPopID()
    }
}

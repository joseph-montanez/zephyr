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
        // Each wraps below when the panel is too narrow to fit the row.
        _ = ImGuiCheckbox("Explode", &engine.ui.blockInsertExplode)
        PanelWidgets.flow(itemWidth: checkboxWidth("Repeat"), gap: 8)
        _ = ImGuiCheckbox("Repeat", &engine.ui.blockInsertRepeat)
        PanelWidgets.flow(itemWidth: checkboxWidth("Prompt attributes"), gap: 8)
        _ = ImGuiCheckbox("Prompt attributes", &engine.ui.blockInsertPromptAttributes)
    }

    // MARK: - Shared widgets

    private static func col(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> UInt32 {
        igGetColorU32_Vec4(ImVec4(x: r / 255, y: g / 255, z: b / 255, w: a / 255))
    }

    /// Estimated width of an `igSmallButton` label (text + frame padding).
    /// Used with `PanelWidgets.flow` so button rows wrap instead of clipping.
    private static func smallButtonWidth(_ label: String) -> Float {
        let textW = ImGuiCalcTextSize(label, nil, false, -1).x
        let padX = ImGuiGetStyle()?.pointee.FramePadding.x ?? 4.0
        return textW + padX * 2 + 8
    }

    /// Estimated width of an `ImGuiCheckbox` row (box + label).
    private static func checkboxWidth(_ label: String) -> Float {
        ImGuiCalcTextSize(label, nil, false, -1).x + ImGuiGetFrameHeight() + 12
    }

    /// Middle-truncates `name` to `maxWidth`, keeping the start and end
    /// visible (file extensions stay readable) with an ellipsis between.
    /// Returns the full name when it fits, "" when nothing fits.
    private static func fittedMiddle(_ name: String, maxWidth: Float) -> String {
        if maxWidth <= 0 { return "" }
        let ellipsis = "…"
        if ImGuiCalcTextSize(ellipsis, nil, false, -1).x > maxWidth { return "" }
        if ImGuiCalcTextSize(name, nil, false, -1).x <= maxWidth { return name }
        // Binary-search the longest keepable head+tail split; validity is
        // monotonic in the kept count, so this needs O(log n) measures.
        var lo = 0
        var hi = name.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let headCount = (mid + 1) / 2
            let candidate = String(name.prefix(headCount)) + ellipsis +
                String(name.suffix(mid - headCount))
            if ImGuiCalcTextSize(candidate, nil, false, -1).x <= maxWidth {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        guard lo > 0 else { return ellipsis }
        let headCount = (lo + 1) / 2
        return String(name.prefix(headCount)) + ellipsis +
            String(name.suffix(lo - headCount))
    }

    /// Width budget for a file title: whatever is left after the collapse
    /// button, the status text, and the trailing file actions, so those
    /// actions are always reachable no matter how long the file name is.
    private static func titleMaxWidth(avail: Float, statusText: String, actionsWidth: Float) -> Float {
        let collapseW = smallButtonWidth("+")
        let statusW = ImGuiCalcTextSize(statusText, nil, false, -1).x
        return max(32, avail - collapseW - 4 - statusW - 8 - actionsWidth - 4)
    }

    /// Title text that middle-truncates to `maxWidth` and reveals the full
    /// name in a hover tooltip whenever truncation kicked in.
    private static func titleText(_ full: String, maxWidth: Float) {
        let title = fittedMiddle(full, maxWidth: maxWidth)
        ImGuiTextV(title)
        if title != full, ImGuiIsItemHovered(0) {
            ImGuiBeginTooltip()
            ImGuiTextV(full)
            ImGuiEndTooltip()
        }
    }

    /// Vector thumbnail cell: reserves `size` px, then draws fitted preview
    /// segments (aspect preserved, block-local origin kept).
    private static func previewCell(_ preview: BlockPreview?, size: Float) {
        let origin = ImGuiGetCursorScreenPos()
        _ = igInvisibleButton("##blockpv", ImVec2(x: size, y: size), 0)
        drawPreview(preview, origin: origin, size: size)
    }

    /// Fitted preview art inside the `size` square at `origin` (border +
    /// aspect-preserved segments). No interaction: callers add their own
    /// button, tooltip, or overlay around the art.
    private static func drawPreview(_ preview: BlockPreview?, origin: ImVec2, size: Float) {
        let dl = ImGuiGetWindowDrawList()!
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
            PanelWidgets.flow(itemWidth: smallButtonWidth("Insert"), gap: 8)
            if igSmallButton("Insert") {
                beginInsert(
                    engine: engine,
                    source: .resident(name: row.name),
                    preview: row.preview,
                    record: refForCurrentBlock(name: row.name, engine: engine),
                    sessionName: engine.tabManager.activeFileURL == nil ? row.name : nil)
            }
            PanelWidgets.flow(itemWidth: smallButtonWidth("Edit"), gap: 4)
            // Enter block editor — isolates this block's geometry for in-place editing.
            if igSmallButton("Edit") {
                engine.tabManager.enterBlockEditor(blockID: row.handle)
                engine.cadSelection.clearSelection()
            }
            PanelWidgets.flow(itemWidth: smallButtonWidth("Export"), gap: 4)
            // Write this definition to a DXF/DWG file: skips straight to
            // the destination step (no source or base-point questions —
            // block output is block-local at the origin).
            if igSmallButton("Export") {
                let cmd = WblockCommand(useFileDialog: true)
                cmd.seedBlockExport(name: row.name)
                engine.commandProcessor.activateFeatureCommand(cmd)
            }
            if let ref = refForCurrentBlock(name: row.name, engine: engine) {
                PanelWidgets.flow(itemWidth: max(smallButtonWidth("Pin"), smallButtonWidth("Unpin")), gap: 4)
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
        PanelWidgets.flow(itemWidth: smallButtonWidth("Insert"), gap: 8)
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
        PanelWidgets.flow(itemWidth: max(smallButtonWidth("Remove"), smallButtonWidth("Unpin")), gap: 4)
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
            PanelWidgets.flow(itemWidth: smallButtonWidth("Insert"), gap: 8)
            if igSmallButton("Insert") {
                beginInsert(
                    engine: engine,
                    source: .resident(name: name),
                    preview: doc.allBlocks.first { $0.name == name }
                        .map { BlockPreview.build(geometry: $0.geometry) },
                    record: nil,
                    sessionName: name)
            }
            PanelWidgets.flow(itemWidth: smallButtonWidth("Remove"), gap: 4)
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
        // Folder field shares its row with the buttons when everything fits;
        // otherwise it takes the full width and the buttons wrap below.
        let libGap: Float = 8
        let libButtonsW = smallButtonWidth("Load") + libGap +
            smallButtonWidth("Browse…") + libGap +
            smallButtonWidth("Add Files…") + libGap + 172
        let libAvail = ImGuiGetContentRegionAvail().x
        let libWide = libAvail >= libButtonsW + libGap + 120
        if libWide {
            ImGuiSetNextItemWidth(libAvail - libButtonsW - libGap)
        }
        let committed = DataTablePanelUI.inputText(
            id: "##libraryfolder", value: &libraryFolderField, enterReturnsTrue: true)
        if libWide {
            ImGuiSameLine(0, libGap)
        } else {
            PanelWidgets.flow(itemWidth: smallButtonWidth("Load"), gap: libGap)
        }
        // Load always rescans (even for an unchanged path) so drawings
        // added on disk since the last scan appear.
        if igSmallButton("Load") || committed {
            commitLibraryFolder(engine: engine)
        }
        PanelWidgets.flow(itemWidth: smallButtonWidth("Browse…"), gap: libGap)
        if igSmallButton("Browse…") {
            browseLibraryFolder(engine: engine)
        }
        PanelWidgets.flow(itemWidth: smallButtonWidth("Add Files…"), gap: libGap)
        if igSmallButton("Add Files…") {
            addLibraryFiles(engine: engine)
        }
        renderLibraryRecent(engine: engine, wrapped: !libWide)
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
    private static func renderLibraryRecent(engine: PhrostEngine, wrapped: Bool) {
        let recent = engine.ui.blockLibraryFolders
        guard !recent.isEmpty else { return }
        if wrapped {
            PanelWidgets.flow(itemWidth: 172, gap: 8)
        } else {
            ImGuiSameLine(0, 8)
        }
        ImGuiSetNextItemWidth(min(160, max(ImGuiGetContentRegionAvail().x - 12, 60)))
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

    private static let libraryPinSize: Float = 20
    private static let libraryTileMaxColumns = 8

    /// One library block as an image tile: click the tile to insert, hover
    /// for its name, pin overlay (top right) toggles the favorite. Leaves
    /// the cursor at the tile's bottom-right.
    private static func renderBlockTile(
        engine: PhrostEngine, filePath: String, fileLabel: String,
        block: BlockLibraryService.BlockEntry, size: Float
    ) {
        // Stable string scope: hash-based IDs collide (and Swift hashes
        // vary per launch), which trips the duplicate-ID assert.
        ImGuiPushID(filePath + "\n" + block.blockName)
        defer { ImGuiPopID() }
        let ref = BlockLibraryRef(kind: .container, path: filePath, block: block.blockName)
        let pinned = isFavorite(engine: engine, ref: ref)
        let tile = size
        let pin = libraryPinSize
        let origin = ImGuiGetCursorScreenPos()
        let clicked = igInvisibleButton("##libtile", ImVec2(x: tile, y: tile), 0)
        let tileHovered = ImGuiIsItemHovered(0)
        let tileMin = ImGuiGetItemRectMin()
        let tileMax = ImGuiGetItemRectMax()
        drawPreview(block.preview, origin: origin, size: tile)
        if tileHovered {
            let hoverDL = ImGuiGetWindowDrawList()!
            ImDrawListAddRect(
                hoverDL, tileMin, tileMax,
                igGetColorU32_Vec4(PanelWidgets.withAlpha(engine.ui.theme.brandGold, 0.7)),
                0.0, 2.0, 0)
        }
        let pinMin = ImVec2(x: tileMax.x - pin - 2, y: tileMin.y + 2)
        let pinMax = ImVec2(x: pinMin.x + pin, y: pinMin.y + pin)
        if pinned {
            // Opaque backdrop so the checked wash stays legible over tile art.
            ImDrawListAddRectFilled(
                ImGuiGetWindowDrawList()!, pinMin, pinMax,
                igGetColorU32_Vec4(engine.ui.theme.buttonBg), 4, 0)
        }
        ImGuiSetCursorScreenPos(pinMin)
        let pinFired = PanelWidgets.iconButton(
            id: "libtilepin", icon: "pin",
            tooltip: pinned ? "Unpin" : "Pin",
            theme: engine.ui.theme, size: pin, checked: pinned)
        if pinned {
            ImDrawListAddRect(
                ImGuiGetWindowDrawList()!, pinMin, pinMax,
                igGetColorU32_Vec4(engine.ui.theme.brandGold), 0.0, 2.0, 0)
        }
        let pinHovered = ImGuiIsItemHovered(0)
        // Leave the cursor as if the tile button were the last item, so the
        // next tile (or row) starts from the tile's bottom-right corner.
        ImGuiSetCursorScreenPos(tileMax)
        if tileHovered, !pinHovered {
            ImGuiBeginTooltip()
            ImGuiTextV("\(block.blockName)")
            if !block.attributeTags.isEmpty {
                ImGuiTextV("[\(block.attributeTags.joined(separator: ", "))]")
            }
            ImGuiTextV(fileLabel)
            ImGuiTextV(pinned ? "Pinned - click the pin to unpin" : "Click to insert - pin to keep")
            ImGuiEndTooltip()
        }
        // The pin overlays the tile, so a press in its corner can reach the
        // tile button first: route by location for exactly one action.
        if pinFired {
            toggleFavorite(engine: engine, ref: ref)
        } else if clicked {
            if pinHovered {
                toggleFavorite(engine: engine, ref: ref)
            } else {
                beginInsert(
                    engine: engine,
                    source: .container(path: filePath, block: block.blockName),
                    preview: block.preview,
                    record: ref,
                    sessionName: nil)
            }
        }
    }

    /// Block-tile grid that fills the panel width. The column count follows
    /// the available width (and UI scale via the font size) while each tile
    /// stretches to fill its column, so narrow panels show few tiles per row
    /// and wide panels show more. Tiles are absolutely positioned, so rows
    /// can never drift.
    private static func gridBlockTiles(
        engine: PhrostEngine, entryPath: String, fileLabel: String,
        blocks: [BlockLibraryService.BlockEntry]
    ) {
        ImGuiNewLine()
        let gap: Float = 8
        let gridOrigin = ImGuiGetCursorScreenPos()
        let gridAvail = ImGuiGetContentRegionAvail().x
        let minTile = max(48, ImGuiGetFontSize() * 3.5)
        let cols = min(max(Int((gridAvail + gap) / (minTile + gap)), 1), libraryTileMaxColumns)
        let tile = max(24, (gridAvail - Float(cols - 1) * gap) / Float(cols))
        for (index, block) in blocks.enumerated() {
            let x = gridOrigin.x + Float(index % cols) * (tile + gap)
            let y = gridOrigin.y + Float(index / cols) * (tile + gap)
            ImGuiSetCursorScreenPos(ImVec2(x: x, y: y))
            renderBlockTile(
                engine: engine, filePath: entryPath, fileLabel: fileLabel,
                block: block, size: tile)
        }
        let rows = (blocks.count + cols - 1) / cols
        ImGuiSetCursorScreenPos(ImVec2(
            x: gridOrigin.x, y: gridOrigin.y + Float(rows) * (tile + gap)))
    }

    private static func renderLibraryFileRow(engine: PhrostEngine, entry: BlockLibraryService.FileEntry) {
        // File group title: collapse, file name, and block count on one row
        // with compact file actions; block tiles grid underneath. Tiles
        // insert on click and pin via overlay (see renderBlockTile), so no
        // dedicated text-button rows are needed anywhere.
        ImGuiPushID(entry.path)
        let titleAvail = ImGuiGetContentRegionAvail().x
        let fullTitle = "\(entry.displayName).\(entry.ext)"
        let collapsed = collapsedPaths.contains(entry.path)
        if igSmallButton(collapsed ? "+##\(entry.path)" : "-##\(entry.path)") {
            if collapsed {
                collapsedPaths.remove(entry.path)
            } else {
                collapsedPaths.insert(entry.path)
            }
        }
        ImGuiSameLine(0, 4)
        if let error = entry.error {
            let status = "(\(error))"
            titleText(fullTitle, maxWidth: titleMaxWidth(avail: titleAvail, statusText: status, actionsWidth: 0))
            ImGuiSameLine(0, 8)
            ImGuiTextV(status)
        } else if let blocks = entry.containerBlocks {
            let shown = blocks.filter { matchesSearch($0.blockName) }
            let status = "(\(blocks.count) blocks)"
            titleText(
                fullTitle,
                maxWidth: titleMaxWidth(
                    avail: titleAvail, statusText: status,
                    actionsWidth: 4 + libraryPinSize + 4 + libraryPinSize))
            ImGuiSameLine(0, 8)
            ImGuiTextV(status)
            PanelWidgets.flow(itemWidth: libraryPinSize, gap: 4)
            if PanelWidgets.iconButton(
                id: "libfileinsert", icon: "insert",
                tooltip: "Insert file", theme: engine.ui.theme,
                size: libraryPinSize)
            {
                beginInsert(
                    engine: engine,
                    source: .file(path: entry.path),
                    preview: entry.rootPreview,
                    record: BlockLibraryRef(kind: .file, path: entry.path),
                    sessionName: nil)
            }
            let fileRef = BlockLibraryRef(kind: .file, path: entry.path)
            let filePinned = isFavorite(engine: engine, ref: fileRef)
            PanelWidgets.flow(itemWidth: libraryPinSize, gap: 4)
            if PanelWidgets.iconButton(
                id: "libfilepin", icon: "pin",
                tooltip: filePinned ? "Unpin file" : "Pin file",
                theme: engine.ui.theme, size: libraryPinSize,
                checked: filePinned)
            {
                toggleFavorite(engine: engine, ref: fileRef)
            }
            if !collapsed, !shown.isEmpty {
                gridBlockTiles(
                    engine: engine, entryPath: entry.path,
                    fileLabel: "\(entry.displayName).\(entry.ext)",
                    blocks: shown)
            }
        } else {
            let status = "(…)"
            titleText(fullTitle, maxWidth: titleMaxWidth(avail: titleAvail, statusText: status, actionsWidth: 0))
            ImGuiSameLine(0, 8)
            ImGuiTextV(status)
        }
        ImGuiPopID()
    }

}

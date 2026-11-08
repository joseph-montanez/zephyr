import ZephyrCore
import Foundation
import ImGui

// MARK: - XrefPaletteUI
//
// External References palette: one row per xref definition with status,
// type, saved/found paths, nested children, and lifecycle actions.
// Rows/enablement come from XrefPalettePolicy (cached per revision).

@MainActor
struct XrefPaletteUI {
    static var _isDockedBySlot: [WindowSlotID: Bool] = [:]
    // Cache rows against document revisions (single O(entities) pass).
    private static var cachedRevision: (edit: UInt64, render: UInt64) = (0, 0)
    private static var cachedRows: [XrefPalettePolicy.Row] = []
    private static var cachedMediaRows: [XrefPalettePolicy.MediaRow] = []
    private static var cachedMediaRevision: (edit: UInt64, render: UInt64) = (0, 0)
    private static var cachedMediaDocumentID: ObjectIdentifier?
    private static var cachedDocumentID: ObjectIdentifier?

    static func render(engine: PhrostEngine) {
        guard let tab = engine.tabManager.activeTab else { return }
        let documents = tab.drawingViews.map(\.document)
        let active = engine.document
        let store = tab.xrefStore
        let hostFolder = tab.fileURL?.deletingLastPathComponent().path

        ImGuiSetNextWindowSize(
            ImVec2(x: ImGuiGetFontSize() * 30, y: ImGuiGetFontSize() * 26),
            Int32(ImGuiCond_FirstUseEver.rawValue))

        let isDocked = _isDockedBySlot[engine.ui.frameSlot] ?? false
        var flags = Int32(0)
        if isDocked { flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue) }
        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("External References##XrefPalette", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("External References##XrefPalette", &opened, flags)
        }
        _isDockedBySlot[engine.ui.frameSlot] = ImGuiIsWindowDocked()
        AppLayout.reportCurrentDockedPanel(engine: engine)
        guard entered else {
            ImGuiEnd(); ImGuiPopStyleVar(1); ImGuiPopStyleColor(1)
            return
        }
        defer { ImGuiEnd(); ImGuiPopStyleVar(1); ImGuiPopStyleColor(1) }
        if !isDocked && !opened {
            engine.ui.xrefPanelVisible = false
            return
        }

        if igButton("Attach…", ImVec2(x: 0, y: 0)) {
            engine.commandProcessor.executeCommand("ATTACH")
        }
        ImGuiSameLine(0, 6)
        if igButton("Attach DWG…", ImVec2(x: 0, y: 0)) {
            engine.commandProcessor.executeCommand("XATTACH")
        }
        ImGuiSameLine(0, 6)
        if igButton("Reload All", ImVec2(x: 0, y: 0)) {
            for row in currentRows(engine: engine, store: store, documents: documents) {
                XrefLoader.requestLoad(
                    store: store, blockHandle: row.blockHandle,
                    documents: documents, hostFolder: hostFolder, forceReload: true)
            }
            for row in currentMediaRows(engine: engine, store: tab.mediaStore, documents: documents) {
                MediaLoader.requestLoad(
                    store: tab.mediaStore, name: row.name,
                    documents: documents, hostFolder: hostFolder, forceReload: true)
            }
        }
        igSeparator()

        // Settings row: fade + caps (persisted via UserSettings on change).
        var fade = Int32(active.xrefFadePercent)
        ImGuiTextV("Fade")
        ImGuiSameLine(0, 4)
        ImGuiPushItemWidth(90)
        if igSliderInt("##xrefFade", &fade, 0, 90, "%d%%", 0) {
            engine.ui.xrefFadePercent = Int(fade)
            XrefSysvars.fadePercent = Int(fade)
            for doc in documents {
                doc.xrefFadePercent = Int(fade)
                doc.markNeedsRegeneration()
            }
            var settings = UserSettings.load()
            settings.xrefFadePercent = Int(fade)
            settings.save()
        }
        ImGuiPopItemWidth()
        ImGuiSameLine(0, 10)
        var maxLoaded = Int32(store.limits.maxLoadedXrefs)
        ImGuiTextV("Max loaded")
        ImGuiSameLine(0, 4)
        ImGuiPushItemWidth(60)
        if igInputInt("##xrefMax", &maxLoaded, 1, 5, 0) {
            store.limits.maxLoadedXrefs = max(1, Int(maxLoaded))
            engine.ui.xrefMaxLoaded = store.limits.maxLoadedXrefs
            var settings = UserSettings.load()
            settings.xrefMaxLoaded = store.limits.maxLoadedXrefs
            settings.save()
        }
        ImGuiPopItemWidth()
        igSeparator()

        let rows = currentRows(engine: engine, store: store, documents: documents)
        let mediaRows = currentMediaRows(engine: engine, store: tab.mediaStore, documents: documents)
        if rows.isEmpty && mediaRows.isEmpty {
            ImGuiTextV("No external references in this drawing.")
            return
        }
        var rowID: Int32 = 0
        for row in rows {
            rowID &+= 1
            ImGuiPushID(rowID)
            renderRow(
                row, engine: engine, store: store,
                documents: documents, active: active, hostFolder: hostFolder)
            ImGuiPopID()
            igSeparator()
        }
        for row in mediaRows {
            rowID &+= 1
            ImGuiPushID(rowID)
            renderMediaRow(
                row, engine: engine, store: tab.mediaStore,
                documents: documents, active: active, hostFolder: hostFolder)
            ImGuiPopID()
            igSeparator()
        }
    }

    private static func currentMediaRows(
        engine: PhrostEngine, store: MediaReferenceStore, documents: [CADDocument]
    ) -> [XrefPalettePolicy.MediaRow] {
        let doc = engine.document
        let key = (doc.editRevision, doc.renderRevision)
        if cachedMediaDocumentID == ObjectIdentifier(doc), cachedMediaRevision == key {
            return cachedMediaRows
        }
        cachedMediaRows = XrefPalettePolicy.mediaRows(store: store, documents: documents)
        cachedMediaRevision = key
        cachedMediaDocumentID = ObjectIdentifier(doc)
        return cachedMediaRows
    }

    private static func renderMediaRow(
        _ row: XrefPalettePolicy.MediaRow, engine: PhrostEngine,
        store: MediaReferenceStore, documents: [CADDocument],
        active: CADDocument, hostFolder: String?
    ) {
        let warn = !row.status.hasShadowGeometry && row.status != .unloaded
        if warn {
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.macMin)
        }
        ImGuiTextV("\(row.name)")
        if warn { ImGuiPopStyleColor(1) }
        ImGuiSameLine(0, 8)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
        ImGuiTextV("\(row.statusText) · \(row.typeText) · \(row.instanceCount)×")
        ImGuiPopStyleColor(1)

        if let detail = row.statusDetail, !detail.isEmpty {
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
            ImGuiTextWrappedV(detail)
            ImGuiPopStyleColor(1)
        }
        ImGuiTextV("Saved: \(row.savedPath)")
        if let found = row.foundAtPath {
            ImGuiTextV("Found: \(found)")
        }

        if row.canLoad && igSmallButton("Load") {
            store.updateEntry(forName: row.name) { $0.userUnloaded = false; $0.status = .unloaded }
            MediaLoader.requestLoad(
                store: store, name: row.name, documents: documents,
                hostFolder: hostFolder, forceReload: true)
        }
        ImGuiSameLine(0, 4)
        if row.canUnload && igSmallButton("Unload") {
            MediaLoader.unload(store: store, name: row.name, documents: documents)
        }
        ImGuiSameLine(0, 4)
        if row.canReload && igSmallButton("Reload") {
            MediaLoader.requestLoad(
                store: store, name: row.name, documents: documents,
                hostFolder: hostFolder, forceReload: true)
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Repath…") {
            let extensions = row.kind == .pdf
                ? ["pdf"] : Array(CADImageAsset.supportedExtensions).sorted()
            let rowName = row.name
            NativeFileDialog.showOpenDialog(
                window: engine.dialogParentWindow,
                filters: [NativeFileDialog.Filter(label: row.typeText, extensions: extensions)]
            ) { [weak engine] urls in
                guard let engine, let url = urls.first else { return }
                MainActor.assumeIsolated {
                    guard let tab = engine.tabManager.activeTab else { return }
                    MediaManager.repath(
                        store: tab.mediaStore,
                        documents: tab.drawingViews.map(\.document),
                        activeDocument: engine.document,
                        name: rowName, newURL: url,
                        pathType: XrefSysvars.refPathType, hostFolder: hostFolder)
                }
            }
        }
        ImGuiSameLine(0, 4)
        if row.canEmbed && igSmallButton("Embed") {
            if MediaManager.embed(
                store: store, documents: documents,
                activeDocument: active, name: row.name) {
                cachedDocumentID = nil
                cachedMediaDocumentID = nil
            } else {
                print("[Attach] Embed failed for '\(row.name)': not loaded.")
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Detach") {
            MediaManager.detach(
                store: store, documents: documents,
                activeDocument: active, name: row.name)
            print("[Attach] Detached '\(row.name)'.")
            cachedDocumentID = nil
            cachedMediaDocumentID = nil
        }
    }

    private static func currentRows(
        engine: PhrostEngine, store: XrefRuntimeStore, documents: [CADDocument]
    ) -> [XrefPalettePolicy.Row] {
        let doc = engine.document
        let key = (doc.editRevision, doc.renderRevision)
        if cachedDocumentID == ObjectIdentifier(doc),
           cachedRevision == key {
            return cachedRows
        }
        cachedRows = XrefPalettePolicy.rows(store: store, documents: documents)
        cachedRevision = key
        cachedDocumentID = ObjectIdentifier(doc)
        return cachedRows
    }

    private static func renderRow(
        _ row: XrefPalettePolicy.Row, engine: PhrostEngine,
        store: XrefRuntimeStore, documents: [CADDocument],
        active: CADDocument, hostFolder: String?
    ) {
        let warn = !row.status.hasShadowGeometry && row.status != .unloaded
        if warn {
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.macMin)
        }
        ImGuiTextV("\(row.name)")
        if warn { ImGuiPopStyleColor(1) }
        ImGuiSameLine(0, 8)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
        ImGuiTextV("\(row.statusText) · \(row.typeText) · \(row.instanceCount)×")
        ImGuiPopStyleColor(1)

        if let detail = row.statusDetail, !detail.isEmpty {
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
            ImGuiTextWrappedV(detail)
            ImGuiPopStyleColor(1)
        }
        ImGuiTextV("Saved: \(row.savedPath)")
        if let found = row.foundAtPath {
            ImGuiTextV("Found: \(found)")
        }
        for child in row.children {
            renderChild(child, indent: 1, engine: engine)
        }

        if row.canLoad && igSmallButton("Load") {
            store.updateEntry(for: row.blockHandle) { $0.userUnloaded = false; $0.status = .unloaded }
            XrefLoader.requestLoad(
                store: store, blockHandle: row.blockHandle,
                documents: documents, hostFolder: hostFolder, forceReload: true)
        }
        ImGuiSameLine(0, 4)
        if row.canUnload && igSmallButton("Unload") {
            XrefLoader.unload(store: store, blockHandle: row.blockHandle, documents: documents)
        }
        ImGuiSameLine(0, 4)
        if row.canReload && igSmallButton("Reload") {
            XrefLoader.requestLoad(
                store: store, blockHandle: row.blockHandle,
                documents: documents, hostFolder: hostFolder, forceReload: true)
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Insert") {
            engine.commandProcessor.activateFeatureCommand(
                InsertCommand(preseededBlockName: row.name))
        }
        ImGuiSameLine(0, 4)
        if row.canOpen, igSmallButton("Open") {
            if let found = row.foundAtPath {
                _ = try? engine.tabManager.openTab(url: URL(fileURLWithPath: found))
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Repath…") {
            NativeFileDialog.showOpenDialog(
                window: engine.dialogParentWindow,
                filters: [NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg"])]
            ) { [weak engine] urls in
                guard let engine, let url = urls.first else { return }
                MainActor.assumeIsolated {
                    guard let tab = engine.tabManager.activeTab else { return }
                    XrefManager.repath(
                        store: tab.xrefStore,
                        documents: tab.drawingViews.map(\.document),
                        blockHandle: row.blockHandle, newFileURL: url,
                        pathType: XrefSysvars.refPathType, hostFolder: hostFolder)
                }
            }
        }
        ImGuiSameLine(0, 4)
        if row.status.hasShadowGeometry && igSmallButton(XrefSysvars.bindType == 1 ? "Bind (merge)" : "Bind") {
            do {
                try XrefManager.bind(
                    store: store, documents: documents, activeDocument: active,
                    blockHandle: row.blockHandle, bindType: XrefSysvars.bindType)
                cachedDocumentID = nil
            } catch {
                print("[Xref] Bind failed: \(error)")
            }
        }
        ImGuiSameLine(0, 4)
        if igSmallButton("Detach") {
            let result = XrefManager.detach(
                store: store, documents: documents,
                activeDocument: active, blockHandle: row.blockHandle)
            print("[Xref] Detached '\(row.name)': \(result.instances) instance(s), purged \(result.layersPurged).")
            cachedDocumentID = nil
        }
    }

    private static func renderChild(
        _ child: XrefPalettePolicy.ChildRow, indent: Int, engine: PhrostEngine
    ) {
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
        ImGuiTextV("\(String(repeating: "  ", count: indent))↳ \(child.name) — \(child.statusText)\(child.detail.map { " (\($0))" } ?? "")")
        ImGuiPopStyleColor(1)
        for grandchild in child.children {
            renderChild(grandchild, indent: indent + 1, engine: engine)
        }
    }
}

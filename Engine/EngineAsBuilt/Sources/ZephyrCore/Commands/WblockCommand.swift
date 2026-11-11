// Sources/ZephyrCore/Commands/WblockCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// WBLOCK / -WBLOCK: writes a block, the selection, or the entire
/// drawing to a DXF or DWG file. The destination format follows the
/// output extension (`.dxf` direct, `.dwg` via a temp DXF + ODA
/// FileConverter); the base-point prompt feeds `$INSBASE`, shifted to
/// the origin for object selections (LT layout).
///
/// - Block: the definition's geometry is exploded to loose model-space
///   entities (block-local coords become world coords) via
///   `explodeEntities`, then the helper INSERT and definition are removed,
///   so the file carries just the entities like LT. `$INSBASE` is 0,0,0.
/// - Objects: selected (or picked) entities shifted by `-basePoint`, plus
///   pruned definition tables. `Retain? No` deletes them from the source
///   drawing — the deletion flows through `removeEntities`, so it is
///   OOPS-restorable (the LT Retain/Delete/Oops equivalent).
/// - Entire drawing: every view's entities and pruned tables.
/// `WBLOCK` offers the native save dialog (DXF/DWG filters); `-WBLOCK`
/// and `FILEDIA = 0` keep the typed-path prompt flow for scripts.
@MainActor
public final class WblockCommand: FeatureCommand {

    enum Source {
        case block
        case objects
        case entire
    }

    /// Output format, decided by the destination extension (D1).
    enum WblockFormat {
        case dxf
        case dwg
    }

    /// Save-dialog filters for the destination step: WBLOCK targets are
    /// drawings only (no EAB/PDF, unlike Save As).
    static let wblockFilters = [
        NativeFileDialog.Filter(label: "DXF Drawing", extensions: ["dxf"]),
        NativeFileDialog.Filter(label: "DWG Drawing", extensions: ["dwg"]),
    ]

    private enum Phase {
        case source
        case blockName
        case pick
        case base
        case file
        case awaitingDialog
        case retain
    }

    private var phase: Phase = .source
    private var source: Source = .objects
    private var blockName = ""
    private var basePoint = Vector3(x: 0, y: 0, z: 0)
    /// Staged destination once a path is known (typed or dialog-picked).
    private var pendingURL: URL?
    private var pendingFormat: WblockFormat = .dxf
    /// Panel entry: export this definition, skipping the source and
    /// base-point questions. Consumed by `start()`.
    private var seededBlockName: String?

    /// When false (the `-WBLOCK` factory), the typed-path prompt is used
    /// even when FILEDIA would allow the dialog.
    private let useFileDialog: Bool

    public init(useFileDialog: Bool = true) {
        self.useFileDialog = useFileDialog
    }

    /// Object snaps stay on only while picking the base point: selection
    /// clicks resolve through hit-testing, where snap glyphs do not apply.
    /// The loop feeds the (possibly snapped) cursor into `handleMouseClick`.
    public var isSnappingEnabled: Bool { phase == .base }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .source
        pendingURL = nil
        pendingFormat = .dxf
        if let seed = seededBlockName, !seed.isEmpty {
            seededBlockName = nil
            startSeededBlockExport(named: seed, engine: engine, processor: processor)
            return
        }
        if engine.cadSelection.hasSelection {
            // Noun/verb: a pre-selection means Objects; skip the source
            // question instead of asking again.
            source = .objects
            _ = askBase(engine: engine, processor: processor)
            return
        }
        processor.commandPrompt =
            "Source [Block/Objects/Entire drawing] <Objects>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        pendingURL = nil
        seededBlockName = nil
        processor.commandPrompt = "Command cancelled."
    }

    /// Panel entry: export a known block definition, skipping the source
    /// and base-point questions (block output is block-local at the
    /// origin, so a base point would be meaningless). The destination
    /// step (dialog or typed path) still runs, so format choice stays.
    public func seedBlockExport(name: String) {
        seededBlockName = name
    }

    private func startSeededBlockExport(
        named seed: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        if let block = try? Self.resolveBlock(named: seed, in: engine.document) {
            source = .block
            blockName = block.name
            _ = askDestination(engine: engine, processor: processor)
            return
        }
        // Stale seed (renamed/deleted definition): fall back to the
        // interactive source question.
        processor.commandPrompt =
            "Source [Block/Objects/Entire drawing] <Objects>:"
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // A native save dialog owns the destination while open: swallow
        // canvas clicks so they never leak into the selection.
        if phase == .awaitingDialog { return .handled }
        switch phase {
        case .pick:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY, document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks)
            else { return .handled }
            let shiftHeld = engine.io?.pointee.KeyShift ?? false
            if shiftHeld {
                engine.cadSelection.removeFromSelection(handle)
            } else {
                engine.cadSelection.addToSelection(handle)
            }
            processor.commandPrompt =
                "Select objects, then press Enter " +
                "(\(engine.cadSelection.selectedCount) selected)"
            return .handled
        case .blockName:
            // Picking a block reference answers the name question: look
            // the definition up from the INSERT instead of typing it.
            // The selection is left untouched.
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY, document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks),
                  let blockID = engine.document.entity(for: handle)?.blockID,
                  let picked = engine.document.block(for: blockID)
            else {
                processor.commandPrompt =
                    "Selected object is not a block reference. " +
                    "Enter block name or select a block reference:"
                return .handled
            }
            return resolveBlockName(picked.name, engine: engine, processor: processor)
        case .base:
            basePoint = Vector3(x: worldX, y: worldY, z: 0)
            return askDestination(engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            // Canvas-focus Enter confirms the current step exactly like
            // submitting an empty line (bare Enter never reaches
            // handleCommandText, and Space re-dispatches here when the
            // command declines it — so this also fixes Space-to-confirm).
            let result = handleCommandText("", engine: engine, processor: processor)
            return result == .finished ? .finished : .handled
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .source:
            return readSource(trimmed, engine: engine, processor: processor)
        case .blockName:
            guard !trimmed.isEmpty else {
                processor.commandPrompt =
                    "Block name cannot be blank. Enter block name or select a block reference:"
                return .continue
            }
            return resolveBlockName(trimmed, engine: engine, processor: processor)
        case .pick:
            guard trimmed.isEmpty else { return .continue }
            guard !engine.cadSelection.selectedHandles.isEmpty else {
                processor.commandPrompt = "Nothing selected; nothing written."
                return .finished
            }
            return askBase(engine: engine, processor: processor)
        case .base:
            if !trimmed.isEmpty {
                guard let point = Self.parsePoint(trimmed) else {
                    processor.commandPrompt =
                        "Enter base point as x,y[,z] or pick a point:"
                    return .continue
                }
                basePoint = point
            }
            return askDestination(engine: engine, processor: processor)
        case .file:
            guard !trimmed.isEmpty else {
                processor.commandPrompt = "File path cannot be blank. File path:"
                return .continue
            }
            do {
                let (target, format) = try Self.resolveTarget(trimmed)
                return receiveDestination(
                    url: target, format: format,
                    engine: engine, processor: processor)
            } catch {
                processor.commandPrompt = "Write failed: \(error.localizedDescription)"
                return .finished
            }
        case .awaitingDialog:
            // Typed input arriving while the dialog is open is stale.
            return .continue
        case .retain:
            let answer = trimmed.uppercased()
            let retain = answer.isEmpty || answer == "Y" || answer == "YES"
            guard let target = pendingURL else {
                processor.commandPrompt = "No destination file; command cancelled."
                return .finished
            }
            performWrite(
                url: target, format: pendingFormat, retain: retain,
                engine: engine, processor: processor)
            return .finished
        }
    }

    /// Chips for the source question (`.source`) and the retain
    /// confirmation (`.retain`); name/path phases take free input.
    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        switch phase {
        case .source:
            return [
                FeatureCommandTextOption(value: "Block", title: "Block", aliases: ["B"], description: "Write a block definition"),
                FeatureCommandTextOption(value: "Objects", title: "Objects", aliases: ["O"], description: "Write selected objects (default)"),
                FeatureCommandTextOption(value: "Entire", title: "Entire drawing", aliases: ["E"], description: "Write the entire drawing"),
            ].filter { $0.matches(input) }
        case .retain:
            return [
                FeatureCommandTextOption(value: "Yes", title: "Yes", aliases: ["Y"], description: "Retain source objects (default)"),
                FeatureCommandTextOption(value: "No", title: "No", aliases: ["N"], description: "Delete source objects after writing"),
            ].filter { $0.matches(input) }
        default:
            return []
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func readSource(
        _ trimmed: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = trimmed.uppercased()
        if trimmed.isEmpty || upper == "O" || upper == "OBJECTS" {
            source = .objects
            if !engine.cadSelection.selectedHandles.isEmpty {
                return askBase(engine: engine, processor: processor)
            }
            phase = .pick
            processor.commandPrompt = "Select objects, then press Enter:"
            return .continue
        }
        if upper == "B" || upper == "BLOCK" {
            source = .block
            phase = .blockName
            processor.commandPrompt = "Enter block name or select a block reference:"
            return .continue
        }
        if upper == "E" || upper == "ENTIRE" || upper == "ENTIRE DRAWING" {
            source = .entire
            return askBase(engine: engine, processor: processor)
        }
        processor.commandPrompt =
            "Unknown source '\(trimmed)'. Source [Block/Objects/Entire drawing] <Objects>:"
        return .continue
    }

    private func askBase(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        phase = .base
        basePoint = engine.document.insertionBase
        processor.commandPrompt =
            "Base point <\(fmt(basePoint))> (type x,y[,z] or pick):"
        return .continue
    }

    /// Shared typed/picked block resolution: unknown names and external
    /// references stay in the block question with an explanation.
    private func resolveBlockName(
        _ name: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Spell the failures out: "\(error)" on a LocalizedError prints
        // the case reflection, not the human message.
        do {
            blockName = try Self.resolveBlock(named: name, in: engine.document).name
            return askBase(engine: engine, processor: processor)
        } catch WblockError.blockNotFound(let missing) {
            processor.commandPrompt =
                "Block '\(missing)' not found. Enter block name or select a block reference:"
            return .continue
        } catch WblockError.externalReference(let ref) {
            processor.commandPrompt =
                "Cannot WBLOCK an external reference '\(ref)'; bind it first. " +
                "Enter block name or select a block reference:"
            return .continue
        } catch {
            processor.commandPrompt =
                "Could not resolve block '\(name)'. Enter block name or select a block reference:"
            return .continue
        }
    }

    /// Look a definition up by name for export. External references are
    /// rejected: their geometry lives in another file, and exploding
    /// them would silently write an empty drawing.
    static func resolveBlock(named name: String, in document: CADDocument) throws -> CADBlock {
        guard let block = document.allBlocks.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw WblockError.blockNotFound(name)
        }
        guard !block.isXref else {
            throw WblockError.externalReference(block.name)
        }
        return block
    }

    /// Destination step (D1): the native save dialog for `WBLOCK` with
    /// FILEDIA on, else the typed-path prompt (also `-WBLOCK` always).
    private func askDestination(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard fileDialogEnabled(engine: engine, processor: processor) else {
            phase = .file
            processor.commandPrompt = "File path:"
            return .continue
        }
        phase = .awaitingDialog
        processor.commandPrompt = "Select destination file…"
        processor.commandLineActive = false
        let stem: String
        if source == .block, !blockName.isEmpty {
            stem = blockName
        } else {
            stem = ((engine.tabManager.activeTab?.displayName ?? "untitled") as NSString)
                .deletingPathExtension
        }
        let defaultName = Self.defaultFileName(base: stem)
        NativeFileDialog.showSaveDialog(
            window: engine.dialogParentWindow,
            filters: Self.wblockFilters,
            defaultName: defaultName
        ) { [weak self, weak engine, weak processor] url, filterIndex in
            guard let self, let engine, let processor else { return }
            self.fileDialogCompleted(
                url: url, filterIndex: filterIndex, offeredName: defaultName,
                engine: engine, processor: processor)
        }
        return .continue
    }

    private func fileDialogEnabled(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        guard useFileDialog else { return false }
        if case .int(let value) = processor.lispVars.get(
            "FILEDIA", document: engine.document, activeCommand: nil) {
            return value != 0
        }
        return true
    }

    private func fileDialogCompleted(
        url: URL?, filterIndex: Int, offeredName: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Stay on the canvas: the confirmation lives in the passive
        // prompt bar, and reopening the command palette just to show a
        // notice is the wart this avoids.
        processor.commandLineActive = false
        // Escape while the dialog was open already finished the command.
        guard phase == .awaitingDialog else { return }
        guard let url else {
            processor.commandPrompt = nil
            processor.activeFeatureCommand = nil
            return
        }
        do {
            let (target, format) = try Self.resolveDialogTarget(
                url: url, filterIndex: filterIndex, offeredName: offeredName)
            if receiveDestination(
                url: target, format: format,
                engine: engine, processor: processor) == .finished {
                // performWrite already set the confirmation prompt; end
                // without routing through cancel() so it survives.
                processor.activeFeatureCommand = nil
            }
        } catch {
            processor.commandPrompt = "Write failed: \(error.localizedDescription)"
            processor.activeFeatureCommand = nil
        }
    }

    /// Stage a known destination: Objects asks Retain first, other
    /// sources write immediately.
    private func receiveDestination(
        url: URL, format: WblockFormat,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if source == .objects {
            phase = .retain
            pendingURL = url
            pendingFormat = format
            processor.commandPrompt = "Retain objects? [Yes/No] <Yes>:"
            return .continue
        }
        performWrite(
            url: url, format: format, retain: true,
            engine: engine, processor: processor)
        return .finished
    }

    private func performWrite(
        url: URL, format: WblockFormat, retain: Bool,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Capture the doomed handles before export: a Delete disposition
        // clears the selection, and export must not mutate the source.
        let doomed = (source == .objects && !retain)
            ? engine.cadSelection.selectedHandles : Set<UUID>()
        do {
            guard let tab = engine.tabManager.activeTab else {
                throw WblockError.noActiveDocument
            }
            let currentStyle = Self.currentTextStyleName(
                engine: engine, processor: processor)
            let views = try Self.exportViews(
                source: source, blockName: blockName, basePoint: basePoint,
                handles: engine.cadSelection.selectedHandles,
                tab: tab, currentTextStyle: currentStyle)
            try Self.writeExport(
                views: views, to: url, format: format,
                dxfVersion: tab.dxfVersion)
            // Delete only after the final file exists: a failed DWG
            // conversion must leave the source drawing untouched.
            if !doomed.isEmpty {
                engine.document.removeEntities(handles: doomed)
                engine.cadSelection.clearSelection()
                engine.tabManager.markActiveDirty()
            }
            let count = views.reduce(0) { $0 + $1.document.allEntities.count }
            let xrefs = views.reduce(0) {
                $0 + Self.xrefReferenceCount(in: $1.document)
            }
            var message =
                "Wrote \(count) object\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
            if xrefs > 0 {
                message += " Includes \(xrefs) xref reference\(xrefs == 1 ? "" : "s") (not bound)."
            }
            processor.commandPrompt = message
        } catch {
            processor.commandPrompt = "Write failed: \(error.localizedDescription)"
        }
    }

    /// Resolve a typed or dialog-picked destination to a file URL plus
    /// format (D1). Extensionless gains `.dxf`; anything but dxf/dwg
    /// throws — DXF bytes must never land under a foreign extension.
    static func resolveTarget(_ path: String) throws -> (url: URL, format: WblockFormat) {
        let expanded = (path as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded)
        if url.pathExtension.isEmpty {
            url = url.appendingPathExtension("dxf")
        }
        switch url.pathExtension.lowercased() {
        case "dxf":
            return (url, .dxf)
        case "dwg":
            return (url, .dwg)
        default:
            throw WblockError.unsupportedExtension(url.pathExtension)
        }
    }

    /// Prefill the save dialog with a complete name: SDL's save dialog
    /// does not append the selected filter's extension (see
    /// `pdfExportDefaultName`), so offer `<base>.dxf` outright instead of
    /// a bare stem.
    static func defaultFileName(base: String) -> String {
        var stem = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty { stem = "untitled" }
        for ext in ["dxf", "dwg"] {
            if stem.lowercased().hasSuffix("." + ext) {
                stem = String(stem.dropLast(ext.count + 1))
                break
            }
        }
        return stem + ".dxf"
    }

    /// Resolve a save-dialog result (D1): SDL returns the filename
    /// verbatim, so the selected filter takes effect here. An untouched
    /// prefill (`offeredName`, e.g. `Chair.dxf` with DWG picked) follows
    /// the dropdown; any user-edited name keeps the typed-extension-wins
    /// rule; bare names gain the selected filter (DXF when the platform
    /// reports none).
    static func resolveDialogTarget(
        url: URL, filterIndex: Int, offeredName: String
    ) throws -> (url: URL, format: WblockFormat) {
        var resolved = url
        let selectedExt: String? = wblockFilters.indices.contains(filterIndex)
            ? wblockFilters[filterIndex].extensions.first.map { $0.lowercased() }
            : nil
        let typedExt = url.pathExtension.lowercased()
        if url.lastPathComponent.lowercased() == offeredName.lowercased(),
           let selected = selectedExt, selected != typedExt {
            // Untouched prefill: the dropdown is the only explicit format
            // signal, so it moves the offered extension.
            resolved = url.deletingPathExtension().appendingPathExtension(selected)
        } else if typedExt.isEmpty {
            resolved = url.appendingPathExtension(selectedExt ?? "dxf")
        }
        // Anything else (typed known/foreign extension) flows through
        // unchanged: typed-known wins, foreign is rejected by resolveTarget.
        return try resolveTarget(resolved.path)
    }

    /// Write prepared views to `url`: DXF directly, DWG via a temp DXF +
    /// ODA FileConverter (the same pipeline as Save As DWG). Throws
    /// without touching `url` when the converter is missing or fails.
    static func writeExport(
        views: [DrawingView], to url: URL,
        format: WblockFormat, dxfVersion: DXFVersion
    ) throws {
        switch format {
        case .dxf:
            try DXFExporter.export(views: views, to: url, dxfVersion: dxfVersion)
        case .dwg:
            guard ODADWGConverter.isAvailable else {
                throw ODADWGConvertError.converterNotFound
            }
            let tempDXF = FileManager.default.temporaryDirectory
                .appendingPathComponent("wblock-\(UUID().uuidString).dxf")
            defer { try? FileManager.default.removeItem(at: tempDXF) }
            try DXFExporter.export(views: views, to: tempDXF, dxfVersion: dxfVersion)
            try ODADWGConverter.convertSync(
                odaVersion: ODADWGConverter.odaVersion(for: dxfVersion),
                input: tempDXF, output: url, toFormat: "DWG")
        }
    }

    /// Build one pruned export document per source (D5): Block/Objects
    /// use the active view's document; Entire maps every drawing view so
    /// sheets travel with the file.
    static func exportViews(
        source: Source, blockName: String, basePoint: Vector3,
        handles: Set<UUID>, tab: DocumentTab,
        currentTextStyle: String = "Standard"
    ) throws -> [DrawingView] {
        switch source {
        case .block, .objects:
            let index = tab.drawingViews.indices.contains(tab.activeViewIndex)
                ? tab.activeViewIndex : tab.drawingViews.startIndex
            let active = tab.drawingViews[index]
            let temp = try exportDocument(
                source, blockName: blockName, basePoint: basePoint,
                handles: handles, from: active.document,
                currentTextStyle: currentTextStyle)
            return [DrawingView(name: active.name, kind: active.kind, document: temp)]
        case .entire:
            return try tab.drawingViews.map { view in
                let temp = try exportDocument(
                    .entire, blockName: "", basePoint: basePoint,
                    handles: [], from: view.document,
                    currentTextStyle: currentTextStyle)
                return DrawingView(name: view.name, kind: view.kind, document: temp)
            }
        }
    }

    /// Builds the export document for a source (never mutates the source).
    /// Objects are shifted by `-basePoint` with `$INSBASE` at the origin
    /// (D2); Entire keeps world coords with the prompted base; Block keeps
    /// block-local coords at the origin. Tables are completed from the
    /// source, then pruned to referenced records (D3).
    static func exportDocument(
        _ source: Source, blockName: String, basePoint: Vector3,
        handles: Set<UUID>, from document: CADDocument,
        currentTextStyle: String = "Standard"
    ) throws -> CADDocument {
        let temp = CADDocument()
        temp.importLayersBlocksEntities(
            layers: document.allLayers,
            blocks: document.allBlocks,
            entities: [])
        temp.textStyles = document.textStyles
        temp.dimensionStyles = document.dimensionStyles
        temp.leaderStyles = document.leaderStyles
        temp.linetypePatterns = document.linetypePatterns
        temp.mlineStyles = document.mlineStyles
        temp.currentLeaderStyleName = document.currentLeaderStyleName
        temp.currentDimensionStyleName = document.currentDimensionStyleName
        temp.currentMlineStyleName = document.currentMlineStyleName
        temp.globalLineTypeScale = document.globalLineTypeScale
        temp.unit = document.unit
        switch source {
        case .entire:
            temp.importLayersBlocksEntities(
                layers: [], blocks: [], entities: document.allEntities)
            temp.insertionBase = basePoint
        case .objects:
            temp.importLayersBlocksEntities(
                layers: [], blocks: [],
                entities: document.allEntities.filter { handles.contains($0.handle) })
            if basePoint != .zero {
                Self.shiftObjectsToOrigin(temp, basePoint: basePoint)
            }
            temp.insertionBase = .zero
        case .block:
            let block = try Self.resolveBlock(named: blockName, in: document)
            // Explode one helper INSERT at identity so block-local coords
            // become world coords, then drop the helper + definition.
            let zeroID = temp.findLayer(named: "0")?.handle
                ?? temp.allLayers.first?.handle ?? UUID()
            let helper = CADEntity(
                layerID: zeroID, blockID: block.handle, transform: .identity)
            temp.addEntity(helper)
            _ = temp.explodeEntities(handles: [helper.handle])
            temp.removeEntities(handles: [helper.handle])
            temp.removeBlock(handle: block.handle)
            temp.insertionBase = .zero
        }
        retainReferencedMediaAndGroups(temp, from: document)
        // Pin the active layer to "0" before purging so the sweep keeps
        // the right records; the temp has no current layer of its own.
        temp.activeLayerID = temp.findLayer(named: "0")?.handle
            ?? temp.allLayers.first?.handle
        pruneUnusedDefinitions(temp, currentTextStyle: currentTextStyle)
        return temp
    }

    /// Reachability sweep to fixpoint (D3): one pass can orphan newly
    /// unreferenced records (e.g. a block dropped with its private layer).
    private static func pruneUnusedDefinitions(
        _ temp: CADDocument, currentTextStyle: String
    ) {
        for _ in 0..<10 {
            let report = temp.purgeableDefinitions(currentTextStyle: currentTextStyle)
            guard !report.items.isEmpty else { break }
            let removed = temp.applyPurge(report)
            guard removed.values.reduce(0, +) > 0 else { break }
        }
    }

    /// World-space shift for Objects mode (D2). `moveEntities` covers
    /// every transform-derived export (loose geometry, INSERTs, images,
    /// tables, leaders, mlines, arrays), but DIMENSION records are
    /// written raw from metadata — translate definition points too —
    /// and *D display blocks are the reimport display source, so blocks
    /// referenced only by dimension entities move as well. Shared
    /// definition geometry is never touched: regular blocks stay
    /// block-local and ride their instances' shifted transforms.
    private static func shiftObjectsToOrigin(_ temp: CADDocument, basePoint: Vector3) {
        let delta = Vector3(x: -basePoint.x, y: -basePoint.y, z: -basePoint.z)
        temp.moveEntities(
            handles: Set(temp.allEntities.map(\.handle)), by: delta)
        var retranslated: [CADEntity] = []
        var retranslatedHandles = Set<UUID>()
        for entity in temp.allEntities {
            guard !entity.isViewportProjected,
                  let box = entity.dimensionMetadata else { continue }
            let d = box.value
            var copy = entity
            copy.dimensionMetadata = CADDimensionMetadataBox(CADDimensionMetadata(
                styleName: d.styleName,
                type: d.type,
                measurement: d.measurement,
                defPoint: d.defPoint + delta,
                defPoint2: d.defPoint2 + delta,
                defPoint3: d.defPoint3.map { $0 + delta },
                defPoint4: d.defPoint4.map { $0 + delta },
                defPoint5: d.defPoint5.map { $0 + delta },
                textMidpoint: d.textMidpoint + delta,
                textOverride: d.textOverride,
                rotationAngle: d.rotationAngle,
                textRotationAngle: d.textRotationAngle,
                obliqueAngle: d.obliqueAngle,
                dimBreaks: d.dimBreaks,
                flags: d.flags,
                styleOverrides: d.styleOverrides))
            retranslated.append(copy)
            retranslatedHandles.insert(copy.handle)
        }
        if !retranslatedHandles.isEmpty {
            temp.removeEntities(handles: retranslatedHandles)
            temp.importLayersBlocksEntities(
                layers: [], blocks: [], entities: retranslated)
        }
        translateDimensionDisplayBlocks(temp, by: delta)
    }

    /// Translate *D-style display blocks referenced only by dimension
    /// entities: on reimport the DIMENSION display is baked from the
    /// block, not regenerated from metadata. Blocks with any
    /// non-dimension reference keep shared block-local geometry.
    private static func translateDimensionDisplayBlocks(_ temp: CADDocument, by delta: Vector3) {
        var dimensionBlocks = Set<UUID>()
        var otherBlocks = Set<UUID>()
        for entity in temp.allEntities {
            guard let blockID = entity.blockID else { continue }
            if entity.dimensionMetadata != nil {
                dimensionBlocks.insert(blockID)
            } else {
                otherBlocks.insert(blockID)
            }
        }
        let shift = Transform3D.translated(by: delta)
        for blockID in dimensionBlocks.subtracting(otherBlocks) {
            guard var block = temp.block(for: blockID),
                  !block.geometry.isEmpty else { continue }
            block.geometry = CADGeometryMath.transformPrimitives(block.geometry, by: shift)
            block.updateBoundingBox()
            temp.addBlock(block)
        }
    }

    /// Narrow document-wide media and group tables to what the export
    /// actually references (D3): PURGE covers layers/blocks/styles, but
    /// not image/PDF definitions, assets, or groups.
    private static func retainReferencedMediaAndGroups(
        _ temp: CADDocument, from document: CADDocument
    ) {
        let mediaNames = referencedMediaNames(in: temp)
        temp.imageDefinitions = document.imageDefinitions.filter { key, def in
            mediaNames.contains(key) || mediaNames.contains(def.name)
        }
        temp.pdfDefinitions = document.pdfDefinitions.filter { key, def in
            mediaNames.contains(key) || mediaNames.contains(def.name)
        }
        temp.imageStore = document.imageStore.filter { key, _ in
            mediaNames.contains(key)
        }
        let exportedHandles = Set(temp.allEntities.map(\.handle))
        temp.groups = document.groups.filter { _, group in
            group.members.contains(where: exportedHandles.contains)
        }
    }

    /// Names referenced by `.image` primitives (images and PDF underlays
    /// share the primitive; the writer keys both definition tables by it).
    /// Block bodies are scanned too so INSERTs keep their media.
    private static func referencedMediaNames(in document: CADDocument) -> Set<String> {
        var names = Set<String>()
        func scan(_ primitives: [CADPrimitive]) {
            for primitive in primitives {
                if case .image(_, _, _, let name, _, _) = primitive {
                    names.insert(name)
                }
            }
        }
        for entity in document.allEntities {
            if let geometry = entity.localGeometry { scan(geometry) }
        }
        for block in document.allBlocks { scan(block.geometry) }
        return names
    }

    /// INSERTs whose definition is an external reference stay references
    /// in the output (D4); counted for the completion prompt.
    static func xrefReferenceCount(in document: CADDocument) -> Int {
        document.allEntities.filter { entity in
            guard let blockID = entity.blockID else { return false }
            return document.block(for: blockID)?.isXref == true
        }.count
    }

    /// Current text style for the purge sweep (mirrors PurgeCommand).
    private static func currentTextStyleName(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> String {
        if case .string(let name) = processor.lispVars.get(
            "TEXTSTYLE", document: engine.document, activeCommand: nil),
           !name.isEmpty {
            return name
        }
        return "Standard"
    }

    private enum WblockError: Error, LocalizedError {
        case blockNotFound(String)
        case externalReference(String)
        case unsupportedExtension(String)
        case noActiveDocument

        var errorDescription: String? {
            switch self {
            case .blockNotFound(let name):
                return "Block '\(name)' not found."
            case .externalReference(let name):
                return "Cannot WBLOCK an external reference '\(name)'; bind it first."
            case .unsupportedExtension(let ext):
                return ext.isEmpty
                    ? "Missing file extension; use .dxf or .dwg"
                    : "Unsupported extension '.\(ext)'; use .dxf or .dwg"
            case .noActiveDocument:
                return "No active drawing"
            }
        }
    }

    static func parsePoint(_ text: String) -> Vector3? {
        let parts = text.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return Vector3(x: parts[0], y: parts[1], z: parts.count == 3 ? parts[2] : 0)
    }

    private func fmt(_ point: Vector3) -> String {
        "\(point.x),\(point.y),\(point.z)"
    }
}

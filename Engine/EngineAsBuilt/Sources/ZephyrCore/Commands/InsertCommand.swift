import Foundation
import CSDL3
import ImGui

// =========================================================================
// INSERT — place a block reference.
//
// Sources: an existing definition by name (.resident), one definition out
// of a container file (.container — cloned at commit, never before), or a
// whole drawing file imported as a new definition (.file).
//
// Prompt order mirrors AutoCAD: name → insertion point (click or x,y[,z])
// → X scale [XYZ] → Y scale → rotation → attribute prompts (ATTREQ=1).
// The ghost renders cached BlockPreview segments under the live scale in
// every pre-commit stage. Commit (clone + place + optional explode) runs
// inside one undo group; Repeat loops the point stage until Esc.
// =========================================================================

public final class InsertCommand: FeatureCommand {
    public var name: String { "INSERT" }

    /// Placement source. Set by the Blocks palette; the legacy
    /// `preseededBlockName` maps to `.resident`.
    public enum Source {
        case resident(name: String)
        case container(path: String, block: String)
        case file(path: String)
    }

    /// Set by the Blocks panel Insert action to skip the name prompt.
    public var preseededBlockName: String?
    /// Palette preseed: source plus its background-loaded preview, so
    /// resolving never parses on the main thread.
    public var preseededSource: Source?
    public var preseededPreview: BlockPreview?
    public var preseededPreviewScale: Double?
    /// Placement options (palette bottom bar).
    public var explodeOnInsert = false
    public var repeatPlacement = false
    public var promptForAttributes = false

    private enum Stage {
        case awaitingName
        case awaitingFile
        case awaitingPoint
        case awaitingScaleX
        case awaitingScaleY
        case awaitingScaleZ
        case awaitingRotation
        case awaitingAttribute
        case done
    }

    private var stage: Stage = .awaitingName
    private var source: Source?
    private var blockID: UUID?
    private var blockName: String = ""
    private var insertionPoint: Vector3 = .zero
    private var defaultScale: Double = 1
    private var scaleX: Double = 1
    private var scaleY: Double = 1
    private var scaleZ: Double = 1
    private var separateXYZ = false
    private var preview: BlockPreview?
    /// Host-size multiplier for the (source-unit) preview and nothing else:
    /// unit-baked container clones place at user scale; file imports carry
    /// the unit scale in their entity transform (legacy behavior).
    private var previewScale: Double = 1
    private var stagedBundle: DrawingFileInsert.ContainerBundle?
    private var pendingDefs: [CADAttributeDefinition] = []
    private var stagedValues: [String: CADAttributeValue] = [:]
    private var attrIndex: Int = 0
    private var stagedRotation: Double = 0

    public init(preseededBlockName: String? = nil) {
        self.preseededBlockName = preseededBlockName
    }

    public init(source: Source, preview: BlockPreview? = nil, previewScale: Double? = nil) {
        self.preseededSource = source
        self.preseededPreview = preview
        self.preseededPreviewScale = previewScale
    }

    // MARK: - Lifecycle

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let seed: Source?
        if let preseededSource {
            seed = preseededSource
        } else if let preseededBlockName {
            seed = .resident(name: preseededBlockName)
        } else {
            seed = nil
        }
        if let seed {
            if resolveSource(seed, engine: engine, processor: processor) {
                return
            }
            openTextPrompt(
                "Source not found. Enter block name or ~ for file:",
                processor: processor)
            return
        }
        openTextPrompt("Enter block name or ~ to insert a file <~>:", processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        stage = .done
        stagedBundle = nil
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    // MARK: - Text input

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage {
        case .awaitingName:
            return handleNameInput(input, engine: engine, processor: processor)
        case .awaitingPoint:
            guard let point = Self.parsePoint(input) else {
                showCanvasPrompt(
                    "Requires a point. Specify insertion point (x,y[,z]) for \"\(blockName)\":",
                    processor: processor)
                return .continue
            }
            insertionPoint = point
            stage = .awaitingScaleX
            openTextPrompt(
                "Specify X scale factor [XYZ] <\(fmt(defaultScale))>:", processor: processor)
            return .continue
        case .awaitingScaleX:
            if input.uppercased() == "XYZ" {
                separateXYZ = true
                openTextPrompt("Specify X scale factor <\(fmt(defaultScale))>:", processor: processor)
                return .continue
            }
            scaleX = Double(input) ?? defaultScale
            stage = .awaitingScaleY
            openTextPrompt("Specify Y scale factor <\(fmt(scaleX))>:", processor: processor)
            return .continue
        case .awaitingScaleY:
            scaleY = Double(input) ?? scaleX
            if separateXYZ {
                stage = .awaitingScaleZ
                openTextPrompt("Specify Z scale factor <\(fmt(scaleX))>:", processor: processor)
            } else {
                scaleZ = scaleX
                stage = .awaitingRotation
                openTextPrompt("Specify rotation angle <0>:", processor: processor)
            }
            return .continue
        case .awaitingScaleZ:
            scaleZ = Double(input) ?? scaleX
            stage = .awaitingRotation
            openTextPrompt("Specify rotation angle <0>:", processor: processor)
            return .continue
        case .awaitingRotation:
            stagedRotation = Double(input) ?? 0
            return maybeAttributesOrPlace(engine: engine, processor: processor)
        case .awaitingAttribute:
            storeAttribute(input)
            if attrIndex < pendingDefs.count {
                promptAttribute(at: attrIndex, processor: processor)
                return .continue
            }
            place(engine: engine, processor: processor)
            return repeatPlacement ? .continue : .finished
        case .awaitingFile, .done:
            return stage == .done ? .finished : .continue
        }
    }

    private func handleNameInput(
        _ input: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if input.isEmpty || input == "~" {
            stage = .awaitingFile
            processor.commandPrompt = "Select drawing file to insert (Esc to cancel)…"
            processor.commandLineActive = false
            NativeFileDialog.showOpenDialog(
                window: engine.dialogParentWindow,
                filters: [NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg", "eab"])]
            ) { [weak self, weak engine, weak processor] urls in
                guard let self, let engine, let processor, let url = urls.first else { return }
                _ = MainActor.assumeIsolated {
                    self.stashFile(at: url.path, engine: engine, processor: processor)
                }
            }
            return .continue
        }
        if Self.looksLikeDrawingPath(input) {
            stashFile(at: input, engine: engine, processor: processor)
            return stage == .done ? .finished : .continue
        }
        if resolveSource(.resident(name: input), engine: engine, processor: processor) {
            return .continue
        }
        openTextPrompt(
            "Block \"\(input)\" not found. Enter block name or ~ for file:",
            processor: processor)
        return .continue
    }

    private static func looksLikeDrawingPath(_ input: String) -> Bool {
        let ext = (input as NSString).pathExtension.lowercased()
        if ext == "dxf" || ext == "dwg" || ext == "eab" { return true }
        return FileManager.default.fileExists(atPath: input)
    }

    /// Typed point entry ("x,y[,z]", mirroring WblockCommand.parsePoint).
    static func parsePoint(_ text: String) -> Vector3? {
        let parts = text.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return Vector3(x: parts[0], y: parts[1], z: parts.count == 3 ? parts[2] : 0)
    }

    // MARK: - Source resolution (no document mutation)

    @discardableResult
    private func resolveSource(
        _ newSource: Source, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        switch newSource {
        case .resident(let name):
            return resolveBlock(named: name, engine: engine, processor: processor)
        case .container(let path, let block):
            let bundle: DrawingFileInsert.ContainerBundle
            if let stagedBundle, stagedPath == path {
                bundle = stagedBundle
            } else if let loaded = try? DrawingFileInsert.loadContainerBundle(fromFile: path) {
                bundle = loaded
                stagedBundle = loaded
                stagedPath = path
            } else {
                return false
            }
            guard let def = bundle.blocks.first(where: {
                $0.name.caseInsensitiveCompare(block) == .orderedSame
            }) else { return false }
            source = newSource
            blockID = nil
            blockName = def.name
            // The clone is unit-baked at commit, so prompts work in host
            // units (default 1); the ghost still scales source-unit preview
            // art by the unit factor for a true-size outline.
            defaultScale = 1
            scaleX = 1; scaleY = 1; scaleZ = 1
            separateXYZ = false
            preview = preseededPreview ?? BlockPreview.build(geometry: def.geometry)
            preseededPreview = nil
            let unit = CADModelSpaceBaker.unitScale(from: bundle.sourceUnit, to: engine.document.unit)
            previewScale = preseededPreviewScale ?? unit
            preseededPreviewScale = nil
            pendingDefs = def.attributeDefinitions
            stage = .awaitingPoint
            showCanvasPrompt("Specify insertion point for \"\(def.name)\":", processor: processor)
            return true
        case .file(let path):
            return stashFile(at: path, engine: engine, processor: processor)
        }
    }

    private var stagedPath: String?

    @discardableResult
    private func resolveBlock(
        named name: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        guard let block = engine.document.allBlocks.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
                && BlockLibraryPolicy.isUserInsertable($0)
        }) else { return false }
        source = .resident(name: block.name)
        blockID = block.handle
        blockName = block.name
        defaultScale = 1
        scaleX = 1; scaleY = 1; scaleZ = 1
        separateXYZ = false
        preview = preseededPreview ?? BlockPreview.build(geometry: block.geometry)
        preseededPreview = nil
        previewScale = preseededPreviewScale ?? 1
        preseededPreviewScale = nil
        pendingDefs = block.attributeDefinitions
        stage = .awaitingPoint
        showCanvasPrompt("Specify insertion point for \"\(block.name)\":", processor: processor)
        return true
    }

    /// Validate a drawing file and stash it for commit. Pure: parses without
    /// touching the document (the merge + addBlock move into place()).
    @discardableResult
    private func stashFile(
        at path: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        do {
            let ext = (path as NSString).pathExtension.lowercased()
            let baked: CADModelSpaceBaker.Baked
            let unit: CADUnit?
            if ext == "eab" {
                let eab = try DrawingFileInsert.loadModelSpaceEAB(fromFile: path)
                baked = eab.baked
                unit = eab.bundle.sourceUnit
            } else {
                let model = try DrawingFileInsert.loadModelSpace(fromFile: path)
                baked = model.baked
                unit = model.imported.sourceUnit
            }
            source = .file(path: path)
            blockID = nil
            blockName = DrawingFileInsert.blockName(forFilePath: path)
            defaultScale = CADModelSpaceBaker.unitScale(from: unit, to: engine.document.unit)
            scaleX = defaultScale; scaleY = defaultScale; scaleZ = defaultScale
            separateXYZ = false
            preview = preseededPreview ?? BlockPreview.build(geometry: baked.geometry)
            preseededPreview = nil
            previewScale = preseededPreviewScale ?? defaultScale
            preseededPreviewScale = nil
            pendingDefs = []
            stage = .awaitingPoint
            showCanvasPrompt("Specify insertion point for \"\(blockName)\":", processor: processor)
            return true
        } catch {
            stage = .awaitingName
            openTextPrompt("\(error). Enter block name or ~ for file:", processor: processor)
            return false
        }
    }

    // MARK: - Mouse

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard stage == .awaitingPoint else { return stage == .done ? .finished : .continue }
        insertionPoint = Vector3(x: worldX, y: worldY, z: 0)
        stage = .awaitingScaleX
        openTextPrompt(
            "Specify X scale factor [XYZ] <\(fmt(defaultScale))>:", processor: processor)
        return .continue
    }

    // MARK: - Preview (cached-segment ghost at the cursor)

    private var mouseWorldX: Double = 0
    private var mouseWorldY: Double = 0

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        mouseWorldX = worldX
        mouseWorldY = worldY
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        switch stage {
        case .awaitingPoint, .awaitingScaleX, .awaitingScaleY,
             .awaitingScaleZ, .awaitingRotation, .awaitingAttribute:
            break
        case .awaitingName, .awaitingFile, .done:
            return
        }
        guard let preview, !preview.isEmpty else {
            renderLegacyBoxGhost(cam: cam, engine: engine)
            return
        }
        // Live triple: untyped axes still show their prompt defaults.
        let (ux, uy, uz): (Double, Double, Double)
        switch stage {
        case .awaitingPoint, .awaitingScaleX:
            (ux, uy, uz) = (defaultScale, defaultScale, defaultScale)
        case .awaitingScaleY:
            (ux, uy, uz) = (scaleX, scaleX, scaleX)
        default:
            (ux, uy, uz) = (scaleX, scaleY, separateXYZ ? scaleZ : scaleX)
        }
        let t = DrawingFileInsert.insertionTransform(
            point: Vector3(x: mouseWorldX, y: mouseWorldY, z: 0),
            scaleX: previewScale * ux, scaleY: previewScale * uy, scaleZ: previewScale * uz,
            rotationDegrees: 0)
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(255, 217, 51, 230)
        for s in preview.segments {
            let a = t.transformPoint(Vector3(x: Double(s.x0), y: Double(s.y0), z: 0))
            let b = t.transformPoint(Vector3(x: Double(s.x1), y: Double(s.y1), z: 0))
            let sa = EngineCameraManager.worldToScreen(worldX: a.x, worldY: a.y, cam: cam)
            let sb = EngineCameraManager.worldToScreen(worldX: b.x, worldY: b.y, cam: cam)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: sa.x, y: sa.y), ImVec2(x: sb.x, y: sb.y), color, 1.5)
        }
    }

    /// Fallback when no cached preview exists (should not happen on the
    /// resolve/stash paths above, which always build one).
    private func renderLegacyBoxGhost(cam: CameraTransform, engine: PhrostEngine) {
        guard stage == .awaitingPoint, let blockID,
              let block = engine.document.block(for: blockID),
              !block.geometry.isEmpty else { return }
        let box = block.localBoundingBox
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(255, 217, 51, 230)
        let corners = [
            (box.min.x, box.min.y), (box.max.x, box.min.y),
            (box.max.x, box.max.y), (box.min.x, box.max.y),
        ]
        let screen = corners.map { c in
            EngineCameraManager.worldToScreen(
                worldX: mouseWorldX + c.0 * defaultScale,
                worldY: mouseWorldY + c.1 * defaultScale, cam: cam)
        }
        for i in screen.indices {
            let a = screen[i]
            let b = screen[(i + 1) % screen.count]
            ImDrawListAddLine(
                drawList,
                ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), color, 1.5)
        }
    }

    // MARK: - Attributes (ATTREQ)

    private func attributesRequested(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        if promptForAttributes { return true }
        if case let .int(value) = processor.lispVars.get(
            "ATTREQ", document: engine.document, activeCommand: nil) {
            return value != 0
        }
        return false
    }

    private func maybeAttributesOrPlace(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard !pendingDefs.isEmpty, attributesRequested(engine: engine, processor: processor) else {
            stagedValues = CADAttributeSync.apply(definitions: pendingDefs, to: [:])
            place(engine: engine, processor: processor)
            return repeatPlacement ? .continue : .finished
        }
        stagedValues = [:]
        attrIndex = 0
        promptAttribute(at: 0, processor: processor)
        stage = .awaitingAttribute
        return .continue
    }

    private func promptAttribute(at index: Int, processor: CADCommandProcessor) {
        let def = pendingDefs[index]
        let label = def.prompt.isEmpty ? "Enter value for \(def.tag)" : def.prompt
        openTextPrompt("\(label) <\(def.defaultValue)>:", processor: processor)
    }

    private func storeAttribute(_ input: String) {
        guard attrIndex < pendingDefs.count else { return }
        let def = pendingDefs[attrIndex]
        let value = input.isEmpty ? def.defaultValue : input
        stagedValues[def.key] = CADAttributeValue(value: value)
        attrIndex += 1
    }

    // MARK: - Commit (single undo group)

    private func place(engine: PhrostEngine, processor: CADCommandProcessor) {
        let doc = engine.document
        doc.undoManager.beginUndoGroup()
        do {
            let bid = try commitBlockID(doc: doc)
            let layerID = doc.activeLayerID
                ?? doc.allLayers.first?.handle ?? UUID()
            var entity = CADEntity(
                layerID: layerID,
                blockID: bid,
                transform: DrawingFileInsert.insertionTransform(
                    point: insertionPoint,
                    scaleX: scaleX, scaleY: scaleY, scaleZ: scaleZ,
                    rotationDegrees: stagedRotation))
            entity.attributeValues = CADAttributeSync.apply(
                definitions: pendingDefs, to: stagedValues)
            doc.addEntity(entity)
            if explodeOnInsert {
                _ = doc.explodeEntities(handles: [entity.handle])
            }
            print("[CAD] Inserted block '\(blockName)' at (\(insertionPoint.x), \(insertionPoint.y))")
            doc.undoManager.endUndoGroup()
        } catch {
            doc.undoManager.discardOpenUndoGroups()
            stagedBundle = nil
            stage = .awaitingName
            openTextPrompt("\(error). Enter block name or ~ for file:", processor: processor)
            return
        }
        if repeatPlacement {
            // Whole-file sources become resident after the first commit so
            // later iterations place instances instead of re-importing.
            if case .file = source {
                source = .resident(name: blockName)
                pendingDefs = []
            }
            stagedValues = [:]
            attrIndex = 0
            stage = .awaitingPoint
            showCanvasPrompt(
                "Specify insertion point for \"\(blockName)\" (Esc to finish):",
                processor: processor)
        } else {
            stagedBundle = nil
            stage = .done
        }
    }

    /// Clone (container), import (file), or look up (resident) the
    /// definition. The only mutating step before addEntity, inside the
    /// placement undo group — Esc before the point leaves no residue.
    private func commitBlockID(doc: CADDocument) throws -> UUID {
        guard let source else {
            throw DrawingFileInsert.InsertError.importFailed("No insert source")
        }
        switch source {
        case .resident:
            guard let blockID, doc.block(for: blockID) != nil else {
                throw DrawingFileInsert.InsertError.importFailed(
                    "Block \"\(blockName)\" is no longer in the drawing")
            }
            return blockID
        case .container(let path, let block):
            let bundle: DrawingFileInsert.ContainerBundle
            if let stagedBundle, stagedPath == path {
                bundle = stagedBundle
            } else {
                bundle = try DrawingFileInsert.loadContainerBundle(fromFile: path)
            }
            // Repeat iterations naturally hit .useExisting here.
            let (cloned, _) = try DrawingFileInsert.cloneBlock(
                named: block, from: bundle, into: doc, policy: .useExisting)
            blockID = cloned.handle
            blockName = cloned.name
            pendingDefs = cloned.attributeDefinitions
            return cloned.handle
        case .file(let path):
            let (imported, scale) = try DrawingFileInsert.insertFile(at: path, into: doc)
            blockID = imported.handle
            blockName = imported.name
            defaultScale = scale
            pendingDefs = []
            return imported.handle
        }
    }

    // MARK: - Helpers

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func openTextPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }

    private func showCanvasPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = false
    }
}

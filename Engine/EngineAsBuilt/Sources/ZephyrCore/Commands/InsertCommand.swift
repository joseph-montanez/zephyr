import Foundation
import CSDL3
import ImGui

// =========================================================================
// INSERT — place a block reference: an existing definition by name, or a
// DXF/DWG file imported as a new definition (name "~" opens the picker;
// a path inserts directly). Prompt order mirrors AutoCAD: name →
// insertion point → X scale [XYZ] → Y scale → rotation.
// =========================================================================

public final class InsertCommand: FeatureCommand {
    public var name: String { "INSERT" }

    /// Set by the Blocks panel Insert action to skip the name prompt.
    public var preseededBlockName: String?

    private enum Stage {
        case awaitingName
        case awaitingFile
        case awaitingPoint
        case awaitingScaleX
        case awaitingScaleY
        case awaitingScaleZ
        case awaitingRotation
        case done
    }

    private var stage: Stage = .awaitingName
    private var blockID: UUID?
    private var blockName: String = ""
    private var insertionPoint: Vector3 = .zero
    private var defaultScale: Double = 1
    private var scaleX: Double = 1
    private var scaleY: Double = 1
    private var scaleZ: Double = 1
    private var separateXYZ = false

    public init(preseededBlockName: String? = nil) {
        self.preseededBlockName = preseededBlockName
    }

    // MARK: - Lifecycle

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if let preseededBlockName {
            if resolveBlock(named: preseededBlockName, engine: engine, processor: processor) {
                return
            }
            openTextPrompt(
                "Block \"\(preseededBlockName)\" not found. Enter block name or ~ for file:",
                processor: processor)
            return
        }
        openTextPrompt("Enter block name or ~ to insert a file <~>:", processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        stage = .done
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
            let rotation = Double(input) ?? 0
            place(rotationDegrees: rotation, engine: engine)
            return .finished
        case .awaitingPoint, .awaitingFile, .done:
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
                filters: [NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg"])]
            ) { [weak self, weak engine, weak processor] urls in
                guard let self, let engine, let processor, let url = urls.first else { return }
                MainActor.assumeIsolated {
                    self.insertFile(at: url.path, engine: engine, processor: processor)
                }
            }
            return .continue
        }
        if Self.looksLikeDrawingPath(input) {
            insertFile(at: input, engine: engine, processor: processor)
            return stage == .done ? .finished : .continue
        }
        if resolveBlock(named: input, engine: engine, processor: processor) {
            return .continue
        }
        openTextPrompt(
            "Block \"\(input)\" not found. Enter block name or ~ for file:",
            processor: processor)
        return .continue
    }

    private static func looksLikeDrawingPath(_ input: String) -> Bool {
        let ext = (input as NSString).pathExtension.lowercased()
        if ext == "dxf" || ext == "dwg" { return true }
        return FileManager.default.fileExists(atPath: input)
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

    // MARK: - Preview (block bounding-box ghost at the cursor)

    private var mouseWorldX: Double = 0
    private var mouseWorldY: Double = 0

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        mouseWorldX = worldX
        mouseWorldY = worldY
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
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

    // MARK: - Helpers

    @discardableResult
    private func resolveBlock(
        named name: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        guard let block = engine.document.allBlocks.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
                && !$0.name.hasPrefix("*")
                && !$0.isInternalTableDisplayBlock
        }) else { return false }
        blockID = block.handle
        blockName = block.name
        defaultScale = 1
        stage = .awaitingPoint
        showCanvasPrompt("Specify insertion point for \"\(block.name)\":", processor: processor)
        return true
    }

    private func insertFile(
        at path: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        do {
            let (block, scale) = try DrawingFileInsert.insertFile(
                at: path, into: engine.document)
            blockID = block.handle
            blockName = block.name
            defaultScale = scale
            stage = .awaitingPoint
            showCanvasPrompt("Specify insertion point for \"\(block.name)\":", processor: processor)
        } catch {
            stage = .awaitingName
            openTextPrompt("\(error). Enter block name or ~ for file:", processor: processor)
        }
    }

    private func place(rotationDegrees: Double, engine: PhrostEngine) {
        guard let blockID else { stage = .done; return }
        let layerID = engine.document.activeLayerID
            ?? engine.document.allLayers.first?.handle ?? UUID()
        var entity = CADEntity(
            layerID: layerID,
            blockID: blockID,
            transform: DrawingFileInsert.insertionTransform(
                point: insertionPoint,
                scaleX: scaleX, scaleY: scaleY, scaleZ: scaleZ,
                rotationDegrees: rotationDegrees))
        // New inserts start ATTSYNC-clean: every defined tag present
        // with its default value, under the same single undo entry.
        if let block = engine.document.block(for: blockID),
           !block.attributeDefinitions.isEmpty {
            entity.attributeValues = CADAttributeSync.apply(
                definitions: block.attributeDefinitions, to: [:])
        }
        engine.document.addEntity(entity)
        print("[CAD] Inserted block '\(blockName)' at (\(insertionPoint.x), \(insertionPoint.y))")
        stage = .done
    }

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

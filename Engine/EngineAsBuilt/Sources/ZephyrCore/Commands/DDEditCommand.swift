import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - DDEditCommand
// =========================================================================

/// Edit an existing text entity. Opens the TextEditorUI pre-populated
/// with the entity's current text, font, height, alignment, etc.
///
/// Modes:
///   - If a text entity is already selected, edit it immediately.
///   - If no text entity is selected, prompt user to select one, then edit.
///
/// The entity's xdata is updated on OK; on Cancel, nothing changes.
@MainActor
public final class DDEditCommand: FeatureCommand {

    private enum State {
        case findingTarget       // Looking for a text/dimension entity to edit
        case editorOpen          // Editor is displayed
        case finished
    }

    private var state: State = .findingTarget
    private var targetHandle: UUID? = nil
    private var isEditingDimension: Bool = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        print("[DDEDIT] start() called")
        // Check if there's already a dimension entity or text entity selected.
        if let handle = engine.cadSelection.lastSelectedHandle,
           let entity = engine.document.entity(for: handle) {
            if entity.xdata["dxf.text"] != nil {
                print("[DDEDIT] Found selected text entity: \(handle)")
                targetHandle = handle
                isEditingDimension = false
                openEditor(for: handle, engine: engine, processor: processor)
                return
            }
            if entity.dimensionMetadata != nil {
                print("[DDEDIT] Found selected dimension entity: \(handle)")
                targetHandle = handle
                isEditingDimension = true
                openDimensionEditor(for: handle, engine: engine, processor: processor)
                return
            }
        }

        // No text or dimension entity selected — prompt user
        print("[DDEDIT] No text/dimension entity selected, prompting user to select one")
        state = .findingTarget
        targetHandle = nil
        engine.textManager.isEditorActive = false
        engine.textManager.editorResult = .active
        processor.commandPrompt = "Select a text or dimension entity to edit (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .finished
        engine.textManager.isEditorActive = false
        engine.textManager.editorResult = .active
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .findingTarget:
            // Try to hit-test for a text or dimension entity
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom
            )
            if let handle = hitHandle,
               let entity = engine.document.entity(for: handle) {
                if entity.xdata["dxf.text"] != nil {
                    targetHandle = handle
                    isEditingDimension = false
                    openEditor(for: handle, engine: engine, processor: processor)
                    return .continue
                }
                if entity.dimensionMetadata != nil {
                    targetHandle = handle
                    isEditingDimension = true
                    openDimensionEditor(for: handle, engine: engine, processor: processor)
                    return .continue
                }
            }
            // Clicked something that isn't text or a dimension — continue looking
            return .continue

        case .editorOpen, .finished:
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // No-op
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if state == .editorOpen && scancode == SDL_SCANCODE_ESCAPE {
            engine.textManager.isEditorActive = false
            engine.textManager.editorResult = .active
            state = .finished
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        // No overlay needed — the editor is a modal dialog.
    }

    /// Called from the render loop to check if the text editor has been dismissed.
    /// Returns true if the command should finish.
    public func checkEditorResult(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        guard state == .editorOpen else { return false }

        if engine.textManager.isEditorActive { return false }

        let result = engine.textManager.editorResult
        engine.textManager.editorResult = .active

        switch result {
        case .active:
            return false

        case .confirmed(let editorState):
            applyEdits(from: editorState, engine: engine, processor: processor)
            state = .finished
            return true

        case .cancelled:
            state = .finished
            processor.commandPrompt = "Edit cancelled."
            return true
        }
    }

    // MARK: - Private

    private func openEditor(
        for handle: UUID,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        print("[DDEDIT] openEditor() for handle: \(handle)")
        guard let entity = engine.document.entity(for: handle) else {
            print("[DDEDIT] Entity not found!")
            processor.commandPrompt = "Entity no longer exists."
            state = .finished
            return
        }

        let text: String
        if case .string(let s) = entity.xdata["dxf.text"] { text = s }
        else { text = "" }

        let styleReference: String
        if case .string(let value) = entity.xdata["dxf.textStyle"] { styleReference = value }
        else { styleReference = "Standard" }
        let matchedStyle = engine.document.textStyle(named: styleReference)
            ?? engine.document.textStyles.values.first { $0.fontFile.caseInsensitiveCompare(styleReference) == .orderedSame }
            ?? .standard
        let styleName = matchedStyle.name
        let fontName = matchedStyle.fontFile

        let height: Double
        if case .double(let d) = entity.xdata["dxf.textHeight"] { height = d }
        else { height = 2.5 }

        print("[DDEDIT] text='\(text.prefix(50))' font=\(fontName) height=\(height)")

        let alignH: Int
        if case .int(let i) = entity.xdata["dxf.alignH"] { alignH = i }
        else { alignH = 0 }

        let alignV: Int
        if case .int(let i) = entity.xdata["dxf.alignV"] { alignV = i }
        else { alignV = 0 }

        let mtextWidth: Double
        if case .double(let d) = entity.xdata["dxf.mtextWidth"] { mtextWidth = d }
        else { mtextWidth = 0 }

        engine.textManager.editorState = TextEditorState(
            text: text,
            styleName: styleName,
            fontName: fontName,
            height: height,
            rotation: entity.transform.rotation,
            alignH: alignH,
            alignV: alignV,
            mtextWidth: mtextWidth,
            targetHandle: handle
        )
        engine.textManager.isEditorActive = true
        engine.textManager.editorResult = .active
        state = .editorOpen
        processor.commandPrompt = "Editing text. Modify and click OK."
    }

    private func openDimensionEditor(
        for handle: UUID,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        print("[DDEDIT] openDimensionEditor() for handle: \(handle)")
        guard let entity = engine.document.entity(for: handle),
              let box = entity.dimensionMetadata,
              let bid = entity.blockID,
              let block = engine.document.block(for: bid)
        else {
            print("[DDEDIT] Dimension entity or block not found!")
            processor.commandPrompt = "Entity no longer exists."
            state = .finished
            return
        }

        // Extract text from the dimension block's .text primitive
        var text = box.value.textOverride ?? ""
        var styleName = engine.document.resolvedTextStyleName("Standard")
        var fontName = engine.document.textStyle(named: styleName)?.fontFile ?? "simplex.shx"
        var height: Double = 3.5
        var alignH: Int = 4  // Center Middle
        var alignV: Int = 2  // Middle
        var mtextWidth: Double = 0

        for prim in block.geometry {
            if case .text(_, let t, let h, _, let style, let ah, let av, let mw, _) = prim {
                if text.isEmpty { text = t }
                height = h
                if let reference = style {
                    let resolved = engine.document.textStyle(named: reference)
                        ?? engine.document.textStyles.values.first { $0.fontFile.caseInsensitiveCompare(reference) == .orderedSame }
                    if let resolved {
                        styleName = resolved.name
                        fontName = resolved.fontFile
                    }
                }
                alignH = ah
                alignV = av
                mtextWidth = mw ?? 0
                break
            }
        }

        print("[DDEDIT] dimension text='\(text.prefix(50))' font=\(fontName) height=\(height)")

        engine.textManager.editorState = TextEditorState(
            text: text,
            styleName: styleName,
            fontName: fontName,
            height: height,
            rotation: 0,
            alignH: alignH,
            alignV: alignV,
            mtextWidth: mtextWidth,
            targetHandle: handle
        )
        engine.textManager.isEditorActive = true
        engine.textManager.editorResult = .active
        state = .editorOpen
        processor.commandPrompt = "Editing dimension text. Modify and click OK."
    }

    private func applyEdits(
        from editorState: TextEditorState,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        guard let handle = editorState.targetHandle,
              let entity = engine.document.entity(for: handle) else {
            processor.commandPrompt = "Entity no longer exists."
            return
        }

        let text = editorState.text
        guard !text.isEmpty else {
            processor.commandPrompt = "Edit cancelled (empty text)."
            return
        }

        if isEditingDimension {
            applyDimensionEdits(from: editorState, entity: entity, engine: engine, processor: processor)
        } else {
            applyTextEdits(from: editorState, engine: engine, processor: processor)
        }
    }

    private func applyDimensionEdits(
        from editorState: TextEditorState,
        entity: CADEntity,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        guard let box = entity.dimensionMetadata,
              let bid = entity.blockID,
              let block = engine.document.block(for: bid)
        else { return }

        let text = editorState.text
        let styleName = engine.document.resolvedTextStyleName(editorState.styleName)
        let height = engine.document.effectiveTextHeight(styleName: styleName, localHeight: editorState.height)
        let alignH = editorState.alignH
        let alignV = editorState.alignV
        let mtextWidth = editorState.mtextWidth

        // Update the .text primitive in the block geometry
        var newGeometry = block.geometry
        for i in 0..<newGeometry.count {
            if case .text(let pos, _, _, let rotation, _, _, _, _, let color) = newGeometry[i] {
                newGeometry[i] = .text(
                    position: pos,
                    text: text,
                    height: height,
                    rotation: rotation,
                    style: styleName,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: mtextWidth > 0 ? mtextWidth : nil,
                    color: color
                )
                break
            }
        }

        // Update the block geometry
        engine.document.updateBlockGeometry(handle: bid, geometry: newGeometry)

        // Update dimension metadata text override
        var metadata = box.value
        metadata.textOverride = text
        var updatedEntity = entity
        updatedEntity.dimensionMetadata = CADDimensionMetadataBox(metadata)
        engine.document.updateEntityLive(updatedEntity)

        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Dimension text updated."
    }

    private func applyTextEdits(
        from editorState: TextEditorState,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        guard let handle = editorState.targetHandle,
              let entity = engine.document.entity(for: handle) else {
            processor.commandPrompt = "Entity no longer exists."
            return
        }

        let text = editorState.text
        guard !text.isEmpty else {
            processor.commandPrompt = "Edit cancelled (empty text)."
            return
        }

        let originalText: String
        if case .string(let value) = entity.xdata["dxf.text"] {
            originalText = value
        } else {
            originalText = ""
        }
        let originalHeight: Double
        if case .double(let value) = entity.xdata["dxf.textHeight"], value > 0 {
            originalHeight = value
        } else {
            originalHeight = editorState.height
        }
        let contentChanged = text != originalText

        let styleName = engine.document.resolvedTextStyleName(editorState.styleName)
        let style = engine.document.textStyle(named: styleName) ?? .standard
        let height = max(editorState.height, 1e-9)
        let rotation = editorState.rotation
        let fontName = style.fontFile
        let alignH = editorState.alignH
        let alignV = editorState.alignV
        let mtextWidth = editorState.mtextWidth

        // Update entity transform for rotation
        let pos = entity.transform.position
        var newTransform = Transform3D.translated(by: pos)
        if rotation != 0 {
            newTransform = newTransform.multiplying(by: .rotated(by: rotation))
        }
        engine.document.updateTransform(for: handle, to: newTransform)

        // Update the text primitive in local geometry
        let prim: CADPrimitive = .text(
            position: .zero,  // World position comes from transform
            text: text,
            height: height,
            rotation: 0,      // Rotation is in transform
            style: styleName,
            alignH: alignH,
            alignV: alignV,
            mtextWidth: mtextWidth > 0 ? mtextWidth : nil
        )
        engine.document.updateEntityGeometry(for: handle, geometry: [prim])

        // Update xdata
        engine.document.setXData(for: handle, key: "dxf.text", value: .string(text))
        engine.document.setXData(for: handle, key: "dxf.textStyle", value: .string(styleName))
        engine.document.setXData(for: handle, key: "dxf.textHeight", value: .double(height))
        engine.document.setXData(for: handle, key: "dxf.textHeightOverride", value: .int(1))
        engine.document.setXData(for: handle, key: "dxf.alignH", value: .int(alignH))
        engine.document.setXData(for: handle, key: "dxf.alignV", value: .int(alignV))
        if mtextWidth > 0 {
            engine.document.setXData(for: handle, key: "dxf.mtextWidth", value: .double(mtextWidth))
        } else {
            engine.document.removeXData(for: handle, key: "dxf.mtextWidth")
        }

        if contentChanged {
            engine.document.setXData(for: handle, key: "dxf.mtextRaw", value: .string(""))

            let formatted = FormattedText.plain(
                text,
                styleName: styleName,
                font: fontName,
                height: height)
            if let jsonData = try? JSONEncoder().encode(formatted),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                engine.document.setXData(
                    for: handle,
                    key: "dxf.formattedText",
                    value: .string(jsonStr))
            }
        } else if abs(height - originalHeight) > 1e-12,
                  case .string(let json) = entity.xdata["dxf.formattedText"],
                  let data = json.data(using: .utf8),
                  var formatted = try? JSONDecoder().decode(FormattedText.self, from: data) {
            let scale = height / max(originalHeight, 1e-12)
            formatted.defaultHeight *= scale
            for paragraphIndex in formatted.paragraphs.indices {
                for runIndex in formatted.paragraphs[paragraphIndex].runs.indices {
                    if let runHeight = formatted.paragraphs[paragraphIndex].runs[runIndex].height {
                        formatted.paragraphs[paragraphIndex].runs[runIndex].height = runHeight * scale
                    }
                }
            }
            if let jsonData = try? JSONEncoder().encode(formatted),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                engine.document.setXData(
                    for: handle,
                    key: "dxf.formattedText",
                    value: .string(jsonStr))
            }
        }

        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Text updated."
    }
}

import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - TextCommand
// =========================================================================

/// Interactive single-point text placement command.
/// Click to place the insertion point, then opens the TextEditorUI modal
/// for entering text content, selecting font, setting height/alignment.
/// Creates a new CADEntity with text stored in xdata.
@MainActor
public final class TextCommand: FeatureCommand {

    private enum State {
        case waitingForInsertion
        case editorOpen
        case finished
    }

    private var state: State = .waitingForInsertion
    private var insertWorldX: Double = 0
    private var insertWorldY: Double = 0
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .waitingForInsertion
        currentMouseWorldX = 0
        currentMouseWorldY = 0

        // Initialize editor state with defaults
        engine.textManager.editorState = defaultEditorState(engine: engine)
        engine.textManager.isEditorActive = false
        engine.textManager.editorResult = .active

        processor.commandPrompt = "Specify insertion point for text (Esc to cancel)."
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
        case .waitingForInsertion:
            insertWorldX = worldX
            insertWorldY = worldY

            // Open text editor
            engine.textManager.editorState = defaultEditorState(engine: engine)
            engine.textManager.isEditorActive = true
            engine.textManager.editorResult = .active
            state = .editorOpen
            processor.commandPrompt = "Enter text in the dialog, then click OK."
            return .continue

        case .editorOpen, .finished:
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // The text editor handles its own keyboard input.
        // If the editor is active and user pressed Esc, cancel.
        if state == .editorOpen && scancode == SDL_SCANCODE_ESCAPE {
            engine.textManager.isEditorActive = false
            engine.textManager.editorResult = .active
            state = .finished
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForInsertion = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(255, 255, 255, 180)

        // Draw a small cross at the cursor position showing where text will go
        let cx = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
        let crossSize: Float = 8
        ImDrawListAddLine(drawList,
            ImVec2(x: cx.x - crossSize, y: cx.y),
            ImVec2(x: cx.x + crossSize, y: cx.y), col, 1.5)
        ImDrawListAddLine(drawList,
            ImVec2(x: cx.x, y: cx.y - crossSize),
            ImVec2(x: cx.x, y: cx.y + crossSize), col, 1.5)

        // Show "Click to place text" tooltip
        let tip = "Click to place text"
        let tipSize = ImGuiCalcTextSize(tip, nil, false, -1)
        ImDrawListAddText(drawList,
            ImVec2(x: cx.x - tipSize.x / 2, y: cx.y + crossSize + 4),
            col, tip, nil)
    }

    /// Called from the render loop to check if the text editor has been dismissed
    /// and create the entity if the user clicked OK.
    /// Returns true if the command should finish.
    public func checkEditorResult(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        guard state == .editorOpen else { return false }

        // If editor is still active, check its result
        if engine.textManager.isEditorActive { return false }

        let result = engine.textManager.editorResult
        engine.textManager.editorResult = .active

        switch result {
        case .active:
            return false

        case .confirmed(let editorState):
            createTextEntity(from: editorState, engine: engine, processor: processor)
            state = .finished
            return true

        case .cancelled:
            state = .finished
            processor.commandPrompt = "Text cancelled."
            return true
        }
    }

    private func defaultEditorState(engine: PhrostEngine) -> TextEditorState {
        let style = engine.document.textStyle(named: "Standard") ?? .standard
        return TextEditorState(
            styleName: style.name,
            fontName: style.fontFile,
            height: style.fixedHeight > 0 ? style.fixedHeight : 2.5
        )
    }

    private func createTextEntity(
        from editorState: TextEditorState,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        let text = editorState.text
        guard !text.isEmpty else {
            processor.commandPrompt = "Text cancelled (empty)."
            return
        }

        let styleName = engine.document.resolvedTextStyleName(editorState.styleName)
        let style = engine.document.textStyle(named: styleName) ?? .standard
        let height = max(editorState.height, 1e-9)
        let rotation = editorState.rotation
        let fontName = style.fontFile
        let alignH = editorState.alignH
        let alignV = editorState.alignV
        let mtextWidth = editorState.mtextWidth

        // Build the CADPrimitive for rendering
        let prim: CADPrimitive = .text(
            position: .zero,
            text: text,
            height: height,
            rotation: 0.0,
            style: styleName,
            alignH: alignH,
            alignV: alignV,
            mtextWidth: mtextWidth > 0 ? mtextWidth : nil
        )

        // Create entity with text in xdata and the primitive as local geometry
        let layerID = engine.document.activeLayerID ?? engine.document.allLayers.first?.handle ?? UUID()
        let insertPos = Vector3(x: insertWorldX, y: insertWorldY, z: 0)
        var entityTransform = Transform3D.translated(by: insertPos)
        if rotation != 0 {
            entityTransform = entityTransform.multiplying(by: .rotated(by: rotation))
        }

        var entity = CADEntity(
            layerID: layerID,
            localGeometry: [prim],
            transform: entityTransform
        )

        // Store text metadata in xdata
        entity.xdata["dxf.text"] = .string(text)
        entity.xdata["dxf.textStyle"] = .string(styleName)
        entity.xdata["dxf.textHeight"] = .double(height)
        entity.xdata["dxf.textHeightOverride"] = .int(1)
        entity.xdata["dxf.alignH"] = .int(alignH)
        entity.xdata["dxf.alignV"] = .int(alignV)
        if mtextWidth > 0 {
            entity.xdata["dxf.mtextWidth"] = .double(mtextWidth)
        }

        // Store formatted text (even for plain text, so DDEDIT has structured data)
        let formatted = FormattedText.plain(text, styleName: styleName, font: fontName, height: height)
        if let jsonData = try? JSONEncoder().encode(formatted),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            entity.xdata["dxf.formattedText"] = .string(jsonStr)
        }

        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Text created."
    }
}

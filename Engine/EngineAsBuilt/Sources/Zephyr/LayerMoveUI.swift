import ZephyrCore
import Foundation
import ImGui

// MARK: - LayerMoveUI
//
// Renders a modal dialog for moving selected entities to a different layer.
// Activated by the LAYMOVE or LAYMCUR commands, this dialog presents a
// filterable list of layers with color swatches. The user can type to filter
// or click a layer to immediately reassign the selected entities.
//
// The dialog is positioned in the center of the screen and supports:
//   - Incremental text filtering (case-insensitive, partial matching)
//   - Keyboard navigation (Enter to confirm selection)
//   - Color-coded layer indicators
//   - Clipper-based virtual scrolling for large layer counts

@MainActor
struct LayerMoveUI {
    /// Renders the modal layer-move dialog.
    /// - Parameters:
    ///   - engine: The engine instance.
    ///   - dw: Display width for centering.
    ///   - dh: Display height for centering.
    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        let doc = engine.document
        let allLayers = doc.allLayers.sorted { $0.name < $1.name }

        // Filter layers by user's typed input (case-insensitive, partial match).
        let input = engine.ui.layerMoveBuffer.uppercased().trimmingCharacters(in: .whitespaces)
        if input.isEmpty {
            engine.ui.layerMoveMatches = allLayers
        } else {
            engine.ui.layerMoveMatches = allLayers.filter { $0.name.uppercased().contains(input) }
        }

        if !engine.ui.layerMoveMatches.isEmpty {
            if engine.ui.layerMoveSelectionIndex >= engine.ui.layerMoveMatches.count {
                engine.ui.layerMoveSelectionIndex = engine.ui.layerMoveMatches.count - 1
            }
        } else {
            engine.ui.layerMoveSelectionIndex = 0
        }

        // Center the dialog on screen.
        let popupW: Float = 280
        let popupH: Float = 200
        let x = (dw - popupW) / 2
        let y = (dh - popupH) / 2

        ImGuiSetNextWindowPos(ImVec2(x: x, y: y), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: popupW, y: popupH), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
        if igBegin("Move to Layer##LayerMove", &opened, flags) {
            if !opened {
                engine.ui.layerMoveActive = false
                engine.ui.layerMoveBuffer = ""
                engine.ui.layerMoveMatches = []
                ImGuiEnd()
                return
            }

            ImGuiTextV("Move selected entities to layer:")

            // Text input with EnterReturnsTrue for submission.
            let bufSize = 128
            var cBuf = [CChar](repeating: 0, count: bufSize)
            let currentText = engine.ui.layerMoveBuffer
            let initBytes = currentText.utf8CString
            let copyLen = min(initBytes.count, bufSize - 1)
            cBuf.withUnsafeMutableBufferPointer { ptr in
                _ = ptr.initialize(from: initBytes.prefix(copyLen))
            }

            ImGuiSetKeyboardFocusHere(0)
            ImGuiPushItemWidth(-1)

            let submitted = cBuf.withUnsafeMutableBufferPointer { bufPtr -> Bool in
                guard let base = bufPtr.baseAddress else { return false }
                return igInputText(
                    "##LayerMoveInput", base, bufSize,
                    Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue)
                        | Int32(ImGuiInputTextFlags_AutoSelectAll.rawValue),
                    { _ in return 0 }, nil)
            }
            ImGuiPopItemWidth()

            let newText = cBuf.withUnsafeBufferPointer { ptr -> String in
                let bytes = UnsafeRawBufferPointer(ptr).prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }
            engine.ui.layerMoveBuffer = newText

            // Enter pressed: move entities to the selected layer and dismiss.
            if submitted {
                if engine.ui.layerMoveSelectionIndex >= 0
                    && engine.ui.layerMoveSelectionIndex < engine.ui.layerMoveMatches.count
                {
                    let layer = engine.ui.layerMoveMatches[engine.ui.layerMoveSelectionIndex]
                    doc.reassignEntities(handles: engine.cadSelection.selectedHandles, to: layer.handle)
                }
                engine.ui.layerMoveActive = false
                engine.ui.layerMoveBuffer = ""
                engine.ui.layerMoveMatches = []
                ImGuiEnd()
                return
            }

            igSeparator()

            let listH = popupH - ImGuiGetCursorPosY() - 8
            if ImGuiBeginChild(
                "##LayerMoveList",
                ImVec2(x: 0, y: listH),
                Int32(ImGuiChildFlags_None.rawValue),
                Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)) {
                if engine.ui.layerMoveMatches.isEmpty {
                    ImGuiPushStyleColor(
                        Int32(ImGuiCol_Text.rawValue),
                        engine.ui.theme.textDim)
                    ImGuiTextV("(no matching layers)")
                    ImGuiPopStyleColor(1)
                } else {
                    let rowH = ImGuiGetTextLineHeightWithSpacing()
                    var clipper = ImGuiListClipper()
                    ImGuiListClipperBegin(&clipper, Int32(engine.ui.layerMoveMatches.count), rowH)
                    while ImGuiListClipperStep(&clipper) {
                        let start = Int(clipper.DisplayStart)
                        let end = Int(clipper.DisplayEnd)
                        for i in start..<end {
                            let layer = engine.ui.layerMoveMatches[i]
                            let isSelected = (i == engine.ui.layerMoveSelectionIndex)

                            ImGuiPushStyleColor(
                                Int32(ImGuiCol_Button.rawValue),
                                ImVec4(
                                    x: Float(layer.color.r) / 255, y: Float(layer.color.g) / 255,
                                    z: Float(layer.color.b) / 255, w: 1))
                            ImGuiPushStyleColor(
                                Int32(ImGuiCol_ButtonHovered.rawValue),
                                ImVec4(
                                    x: Float(layer.color.r) / 255, y: Float(layer.color.g) / 255,
                                    z: Float(layer.color.b) / 255, w: 0.8))
                            igSmallButton(" ")
                            ImGuiPopStyleColor(2)
                            ImGuiSameLine(0, 6)

                            if ImGuiSelectable(
                                layer.name, isSelected,
                                Int32(ImGuiSelectableFlags_AllowDoubleClick.rawValue),
                                ImVec2(x: 0, y: 0))
                            {
                                doc.reassignEntities(handles: engine.cadSelection.selectedHandles, to: layer.handle)
                                engine.ui.layerMoveActive = false
                                engine.ui.layerMoveBuffer = ""
                                engine.ui.layerMoveMatches = []
                            }
                            if ImGuiIsItemHovered(0) {
                                engine.ui.layerMoveSelectionIndex = i
                            }
                        }
                    }
                }
            }
            ImGuiEndChild()
        }
        ImGuiEnd()
    }

}

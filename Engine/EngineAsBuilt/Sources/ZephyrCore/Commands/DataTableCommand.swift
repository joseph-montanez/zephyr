import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DataTableCommand: FeatureCommand {
    private enum Phase {
        case configuring
        case placing
    }

    private var phase: Phase = .configuring
    private var configuration = DataTableInsertConfiguration()
    private var previewOrigin = Vector3.zero
    private var hasPreviewOrigin = false

    public init() {}

    public var isSnappingEnabled: Bool { phase == .placing }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .configuring
        hasPreviewOrigin = false
        processor.commandPrompt = "Configure the table, then click in the drawing to place it."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        hasPreviewOrigin = false
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .placing else { return .handled }

        let data = DataTableEditor.makeData(configuration: configuration)
        let origin = Vector3(x: worldX, y: worldY, z: 0)
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            blockID: nil,
            localGeometry: [.table(data: data, origin: origin, color: nil)],
            transform: .identity,
            xdata: [:])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        engine.cadSelection.select(entity.handle)
        engine.interaction.selectTable(handle: entity.handle)
        processor.commandPrompt = "Table created."
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        guard phase == .placing else { return }
        previewOrigin = Vector3(x: worldX, y: worldY, z: 0)
        hasPreviewOrigin = true
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        return phase == .configuring ? .handled : .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard phase == .placing, hasPreviewOrigin else { return }
        let data = DataTableEditor.makeData(configuration: configuration)
        let layout = DataTableTessellator.layout(data: data, origin: previewOrigin)
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        let fill = (color & 0x00FFFFFF) | 0x22000000

        let p0 = screenPoint(Vector3(x: layout.origin.x, y: layout.origin.y, z: 0), cam: cam)
        let p1 = screenPoint(Vector3(x: layout.origin.x + layout.totalWidth, y: layout.origin.y, z: 0), cam: cam)
        let p2 = screenPoint(Vector3(x: layout.origin.x + layout.totalWidth, y: layout.origin.y + layout.totalHeight, z: 0), cam: cam)
        let p3 = screenPoint(Vector3(x: layout.origin.x, y: layout.origin.y + layout.totalHeight, z: 0), cam: cam)
        ImDrawListAddQuadFilled(drawList, p0, p1, p2, p3, fill)
        ImDrawListAddQuad(drawList, p0, p1, p2, p3, color, 2.0)

        for x in layout.columnEdges.dropFirst().dropLast() {
            let start = screenPoint(Vector3(x: x, y: layout.dataTop, z: 0), cam: cam)
            let end = screenPoint(Vector3(x: x, y: layout.origin.y + layout.totalHeight, z: 0), cam: cam)
            ImDrawListAddLine(drawList, start, end, color, 1.0)
        }
        for y in layout.rowEdges.dropFirst().dropLast() {
            let start = screenPoint(Vector3(x: layout.origin.x, y: y, z: 0), cam: cam)
            let end = screenPoint(Vector3(x: layout.origin.x + layout.totalWidth, y: y, z: 0), cam: cam)
            ImDrawListAddLine(drawList, start, end, color, 1.0)
        }
        if layout.titleHeight > 0 {
            let start = screenPoint(Vector3(x: layout.origin.x, y: layout.dataTop, z: 0), cam: cam)
            let end = screenPoint(Vector3(x: layout.origin.x + layout.totalWidth, y: layout.dataTop, z: 0), cam: cam)
            ImDrawListAddLine(drawList, start, end, color, 1.0)
        }
    }

    public func renderImGui(engine: PhrostEngine) {
        guard phase == .configuring else { return }

        let io = ImGuiGetIO()!.pointee
        let width: Float = 390
        ImGuiSetNextWindowPos(
            ImVec2(x: (io.DisplaySize.x - width) * 0.5, y: io.DisplaySize.y * 0.22),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: 0), Int32(ImGuiCond_Always.rawValue))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 12.0)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 16, y: 16))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)

        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        var open = true
        if igBegin("Insert Table##DataTableInsert", &open, flags) {
            ImGuiTextV("Insert Table")
            ImGuiTextV("Set the initial structure, then place it in the drawing.")
            igSeparator()

            var columns = Int32(configuration.columnCount)
            var rows = Int32(configuration.dataRowCount)
            var headers = Int32(configuration.headerRowCount)
            var columnWidth = Float(configuration.defaultColumnWidth)
            var rowHeight = Float(configuration.defaultRowHeight)
            var textHeight = Float(configuration.textHeight)

            ImGuiSetNextItemWidth(110)
            if igInputInt("Columns", &columns, 1, 4, ImGuiInputTextFlags(0)) {
                configuration.columnCount = Int(max(1, min(columns, 256)))
            }
            ImGuiSetNextItemWidth(110)
            if igInputInt("Data rows", &rows, 1, 10, ImGuiInputTextFlags(0)) {
                configuration.dataRowCount = Int(max(1, min(rows, 100_000)))
            }
            ImGuiSetNextItemWidth(110)
            if igInputInt("Header rows", &headers, 1, 1, ImGuiInputTextFlags(0)) {
                configuration.headerRowCount = Int(max(0, min(headers, 1_000)))
            }

            _ = igCheckbox("Title row", &configuration.includeTitle)
            if configuration.includeTitle {
                ImGuiSetNextItemWidth(-1)
                inputText("Title", value: &configuration.title)
            }

            ImGuiSetNextItemWidth(160)
            if ImGuiBeginCombo("Table style", configuration.stylePreset.rawValue, 0) {
                for preset in DataTableStylePreset.allCases {
                    let selected = configuration.stylePreset == preset
                    if ImGuiSelectable(preset.rawValue, selected, 0, ImVec2(x: 0, y: 0)) {
                        configuration.stylePreset = preset
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }

            ImGuiSetNextItemWidth(110)
            if igInputFloat("Column width", &columnWidth, 0.25, 1.0, "%.2f", 0) {
                configuration.defaultColumnWidth = Double(max(0.25, columnWidth))
            }
            ImGuiSetNextItemWidth(110)
            if igInputFloat("Row height", &rowHeight, 0.25, 1.0, "%.2f", 0) {
                configuration.defaultRowHeight = Double(max(0.25, rowHeight))
            }
            ImGuiSetNextItemWidth(110)
            if igInputFloat("Text height", &textHeight, 0.1, 0.5, "%.2f", 0) {
                configuration.textHeight = Double(max(0.1, textHeight))
            }

            igSeparator()
            if igButton("Place Table", ImVec2(x: 120, y: 0)) {
                phase = .placing
                engine.commandProcessor.commandPrompt = "Click to place the table. Esc cancels."
            }
            ImGuiSameLine(0, 8)
            if igButton("Cancel", ImVec2(x: 90, y: 0)) {
                ImGuiEnd()
                ImGuiPopStyleColor(1)
                ImGuiPopStyleVar(2)
                engine.commandProcessor.finishFeatureCommand(engine: engine)
                return
            }
        }
        ImGuiEnd()
        ImGuiPopStyleColor(1)
        ImGuiPopStyleVar(2)

        if !open {
            engine.commandProcessor.finishFeatureCommand(engine: engine)
        }
    }

    private func inputText(_ label: String, value: inout String, capacity: Int = 256) {
        let bufferCapacity = max(capacity, value.utf8.count + 1)
        var buffer = [CChar](repeating: 0, count: bufferCapacity)
        let bytes = value.utf8CString
        for index in 0..<min(bytes.count, bufferCapacity) {
            buffer[index] = bytes[index]
        }

        let changed = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let baseAddress = pointer.baseAddress else { return false }
            return igInputText(label, baseAddress, pointer.count, 0, nil, nil)
        }

        if changed {
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            value = String(
                decoding: buffer[..<end].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
    }

    private func screenPoint(_ point: Vector3, cam: CameraTransform) -> ImVec2 {
        let screen = EngineCameraManager.worldToScreen(worldX: point.x, worldY: point.y, cam: cam)
        return ImVec2(x: screen.x, y: screen.y)
    }
}

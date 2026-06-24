import ZephyrCore
import Foundation
import ImGui

// MARK: - PropertiesPanelUI
//
// Renders the floating Properties inspector panel for the currently selected
// entity. Displays comprehensive information organized in collapsible sections:
//
// Sections:
//   1. General — Handle (UUID), assigned layer, parent block with Edit button
//   2. Layer Properties — Color, line weight, line type, visibility
//   3. Entity Overrides — Per-entity XData that overrides layer defaults
//      (line type, line weight, color, draw order, etc.)
//   4. Transform — Position, rotation (degrees), scale
//   5. Bounding Box — World-space min/max and size
//   6. Geometry — Resolved primitives (delegates to GeometryPanelUI)
//   7. XData — Any remaining custom extended data key-value pairs
//
// The panel auto-closes when the selection becomes invalid (entity deleted
// or deselected).

@MainActor
struct PropertiesPanelUI {
    /// Track docking state of this window.
    static var _isDocked: Bool = false
    /// Tracks previous frame's showPropertiesPanel flag to detect re-open.
    static var _wasVisible: Bool = false
    /// Renders the properties panel if the engine's showPropertiesPanel flag is set.
    /// Auto-closes when the selected entity is no longer valid.
    /// - Parameter engine: The engine instance.
    static func render(engine: PhrostEngine) {
        guard engine.ui.showPropertiesPanel else {
            _wasVisible = false
            return
        }

        print("[PropsPanel] render() called, showPropertiesPanel=true")

        let doc = engine.document
        // Validate the selection — if the entity no longer exists, dismiss the panel.
        guard let handle = engine.cadSelection.lastSelectedHandle,
              let entity = doc.entity(for: handle)
        else {
            print("[PropsPanel] No valid lastSelectedHandle, closing panel")
            _wasVisible = false
            engine.ui.showPropertiesPanel = false
            return
        }

        let layer = doc.layer(for: entity.layerID)
        let block = entity.blockID.flatMap { doc.block(for: $0) }
        // Resolve entity to renderable primitives (decomposes complex entities).
        let geometry = doc.resolvedGeometry(for: entity) ?? []

        ImGuiSetNextWindowSize(
            ImVec2(x: ImGuiGetFontSize() * 24, y: ImGuiGetFontSize() * 36),
            Int32(ImGuiCond_Appearing.rawValue))
        // Also position the panel at a visible default location when it first appears,
        // so it isn't placed at (0,0) or behind the dockspace.
        ImGuiSetNextWindowPos(
            ImVec2(x: ImGuiGetFontSize() * 4, y: AppLayout.topChromeHeight + AppLayout.tabBarHeight + ImGuiGetFontSize() * 2),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))

        // When the panel is re-opened after being closed, reset docking state
        // so it doesn't get stuck in an invisible docked tab.
        if !_wasVisible {
            _isDocked = false
        }
        _wasVisible = true

        let isDocked = _isDocked
        var flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
        if isDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        var opened = true
        let entered: Bool
        if isDocked {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0.0)
            entered = igBegin("Properties##PropsPanel", nil, flags)
        } else {
            ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBgDim)
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)
            entered = igBegin("Properties##PropsPanel", &opened, flags)
        }

        guard entered else {
            print("[PropsPanel] igBegin returned false, isDocked=\(isDocked), ImGuiIsWindowDocked=\(ImGuiIsWindowDocked())")
            _isDocked = ImGuiIsWindowDocked()
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
            return
        }
        print("[PropsPanel] igBegin returned true, isDocked=\(ImGuiIsWindowDocked()), handle=\(entity.handle)")
        _isDocked = ImGuiIsWindowDocked()
        defer {
            ImGuiEnd()
            ImGuiPopStyleVar(1)
            ImGuiPopStyleColor(1)
        }

        if !isDocked && !opened {
            engine.ui.showPropertiesPanel = false
            return
        }

        // Section 1: General — handle, layer, block
        if ImGuiCollapsingHeader("General", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
            let uuidStr = entity.handle.uuidString
            let shortUUID = String(uuidStr.prefix(12)) + "..."
            ImGuiTextV("Handle: \(shortUUID)")

            let layerName = layer?.name ?? "?"
            if let ly = layer {
                let hexColor = String(
                    format: "#%02X%02X%02X", ly.color.r, ly.color.g, ly.color.b)
                ImGuiTextV("Layer: \(layerName)  [\(hexColor)]")
            } else {
                ImGuiTextV("Layer: \(layerName)")
            }

            let blockName = block?.name ?? "\u{2014}"
            ImGuiTextV("Block: \(blockName)")
            if let blockID = block?.handle {
                ImGuiSameLine(0, 8)
                if igSmallButton("Edit Block") {
                    engine.tabManager.enterBlockEditor(blockID: blockID)
                    engine.cadSelection.clearSelection()
                }
            }
            // Show "Edit Text" button for text entities
            if entity.xdata["dxf.text"] != nil {
                ImGuiSameLine(0, 8)
                if igSmallButton("Edit Text") {
                    engine.commandProcessor.executeCommand("DDEDIT")
                }
            }
            igSeparator()
        }

        // Section 2: Layer Properties (if the entity has a layer assignment)
        if let ly = layer {
            if ImGuiCollapsingHeader("Layer Properties", Int32(ImGuiTreeNodeFlags_None.rawValue)) {
                let hexColor = String(
                    format: "#%02X%02X%02X", ly.color.r, ly.color.g, ly.color.b)
                ImGuiTextV("Color: \(hexColor)")
                ImGuiTextV("Opacity: \(String(format: "%.0f", ly.opacity * 100))%%")
                ImGuiTextV("LineWeight: \(String(format: "%.3f", ly.lineWeight)) mm")
                ImGuiTextV("LineType: \(ly.lineType)")
                ImGuiTextV("Visible: \(ly.isVisible ? "Yes" : "No")")
                igSeparator()
            }
        }

        // Section 3: Entity Overrides — editable controls with BYLAYER toggle
        if ImGuiCollapsingHeader("Entity Overrides", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
            let layerColor = layer?.color ?? .white
            let layerLW = layer?.lineWeight ?? 0.25
            let layerLT = layer?.lineType ?? "CONTINUOUS"

            // --- Color override ---
            let hasColorOverride = entity.xdata["dxf.color"] != nil
            var useColorOverride = hasColorOverride
            if ImGuiCheckbox("Use color override", &useColorOverride) {
                if useColorOverride {
                    // Enable: write current layer color as default
                    let hex = String(format: "#%02X%02X%02X", layerColor.r, layerColor.g, layerColor.b)
                    engine.document.setXData(for: handle, key: "dxf.color", value: .string(hex))
                } else {
                    engine.document.removeXData(for: handle, key: "dxf.color")
                }
            }
            if useColorOverride {
                let currentHex: String
                if let cv = entity.xdata["dxf.color"], case .string(let s) = cv { currentHex = s }
                else { currentHex = String(format: "#%02X%02X%02X", layerColor.r, layerColor.g, layerColor.b) }
                var col = Self.hexToFloatArray(currentHex)
                if igColorEdit3("##EntityColor", &col, 0) {
                    let hex = String(format: "#%02X%02X%02X",
                        Int(max(0, min(255, col[0] * 255))),
                        Int(max(0, min(255, col[1] * 255))),
                        Int(max(0, min(255, col[2] * 255))))
                    engine.document.setXData(for: handle, key: "dxf.color", value: .string(hex))
                }
            }

            // --- Line weight override ---
            let hasLWOverride = entity.xdata["dxf.lineWeight"] != nil
            var useLWOverride = hasLWOverride
            if ImGuiCheckbox("Use line weight override", &useLWOverride) {
                if useLWOverride {
                    engine.document.setXData(for: handle, key: "dxf.lineWeight", value: .double(layerLW))
                } else {
                    engine.document.removeXData(for: handle, key: "dxf.lineWeight")
                }
            }
            if useLWOverride {
                let currentLW = entity.xdata["dxf.lineWeight"].flatMap { v -> Double? in
                    if case .double(let d) = v { return d }
                    return nil
                } ?? layerLW
                var lw = Float(currentLW)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 6)
                if ImGuiInputFloat("##EntityLW", &lw, 0.05, 0.25, "%.3f mm", 0) {
                    engine.document.setXData(for: handle, key: "dxf.lineWeight", value: .double(Double(max(0, lw))))
                }
                ImGuiPopItemWidth()
            }

            // --- Line type override ---
            let hasLTOverride = entity.xdata["dxf.lineType"] != nil
            var useLTOverride = hasLTOverride
            if ImGuiCheckbox("Use line type override", &useLTOverride) {
                if useLTOverride {
                    engine.document.setXData(for: handle, key: "dxf.lineType", value: .string(layerLT))
                } else {
                    engine.document.removeXData(for: handle, key: "dxf.lineType")
                }
            }
            if useLTOverride {
                let currentLT = entity.xdata["dxf.lineType"].flatMap { v -> String? in
                    if case .string(let s) = v { return s }
                    return nil
                } ?? layerLT
                let lineTypes: [String] = ["CONTINUOUS", "DASHED", "HIDDEN", "DASHDOT", "DOT", "CENTER", "PHANTOM"]
                if ImGuiBeginCombo("##EntityLT", currentLT, 0) {
                    for lt in lineTypes {
                        let selected = (lt == currentLT)
                        if ImGuiSelectable(lt, selected, 0, ImVec2(x: 0, y: 0)) {
                            engine.document.setXData(for: handle, key: "dxf.lineType", value: .string(lt))
                        }
                        if selected {
                            ImGuiSetItemDefaultFocus()
                        }
                    }
                    ImGuiEndCombo()
                }
            }

            // --- Draw order ---
            var isDefaultOrder = entity.drawOrder == Int.max
            if ImGuiCheckbox("Default draw order", &isDefaultOrder) {
                if isDefaultOrder {
                    engine.document.setDrawOrder(for: handle, to: Int.max)
                } else {
                    engine.document.setDrawOrder(for: handle, to: 0)
                }
            }
            if !isDefaultOrder {
                var drawOrder = Int32(clamping: entity.drawOrder)
                ImGuiPushItemWidth(ImGuiGetFontSize() * 4)
                if ImGuiInputInt("Draw order", &drawOrder, 1, 10, 0) {
                    engine.document.setDrawOrder(for: handle, to: Int(drawOrder))
                }
                ImGuiPopItemWidth()
            }

            igSeparator()
        }

        // Section 4: Transform — position, rotation (in degrees), scale
        if ImGuiCollapsingHeader("Transform", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) {
            let pos = entity.transform.position
            let rot = entity.transform.rotation * 180.0 / .pi
            let scl = entity.transform.scale
            ImGuiTextV("Position: (\(String(format: "%.2f", pos.x)), \(String(format: "%.2f", pos.y)), \(String(format: "%.2f", pos.z)))")
            ImGuiTextV("Rotation: \(String(format: "%.1f", rot))\u{00B0}")
            ImGuiTextV("Scale: (\(String(format: "%.2f", scl.x)), \(String(format: "%.2f", scl.y)), \(String(format: "%.2f", scl.z)))")
            igSeparator()
        }

        if ImGuiCollapsingHeader("Bounding Box", Int32(ImGuiTreeNodeFlags_None.rawValue)) {
            if let bb = entity.worldBoundingBox {
                ImGuiTextV("Min: (\(String(format: "%.2f", bb.min.x)), \(String(format: "%.2f", bb.min.y)), \(String(format: "%.2f", bb.min.z)))")
                ImGuiTextV("Max: (\(String(format: "%.2f", bb.max.x)), \(String(format: "%.2f", bb.max.y)), \(String(format: "%.2f", bb.max.z)))")
                let sz = bb.size
                ImGuiTextV("Size: (\(String(format: "%.2f", sz.x)), \(String(format: "%.2f", sz.y)), \(String(format: "%.2f", sz.z)))")
            } else {
                ImGuiTextV("N/A")
            }
            igSeparator()
        }

        // Section 6: Geometry — delegates to GeometryPanelUI for resolved primitives
        GeometryPanelUI.render(geometry: geometry)

        // Section 7: Remaining XData entries not shown in the overrides section
        let shownOverrideKeys: Set<String> = [
            "dxf.lineType", "dxf.lineWeight", "dxf.lineTypeScale",
            "dxf.polylineWidth", "dxf.color", "dxf.drawOrder"]
        let remainingXData = entity.xdata.filter { !shownOverrideKeys.contains($0.key) }
        if !remainingXData.isEmpty {
            if ImGuiCollapsingHeader("XData", Int32(ImGuiTreeNodeFlags_None.rawValue)) {
                for (key, val) in remainingXData.sorted(by: { $0.key < $1.key }) {
                    let valStr: String
                    switch val {
                    case .string(let s): valStr = s
                    case .double(let d): valStr = String(format: "%.4f", d)
                    case .int(let i):    valStr = "\(i)"
                    case .bool(let b):   valStr = b ? "true" : "false"
                    case .date(let d):   valStr = "\(d)"
                    }
                    ImGuiTextV("\(key): \(valStr)")
                }
                igSeparator()
            }
        }
    }

    /// Parse a hex color string like "#FF8000" or "FF8000" into [Float] (0–1 range).
    private static func hexToFloatArray(_ hex: String) -> [Float] {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt32(s, radix: 16) else {
            return [1.0, 1.0, 1.0] // default white
        }
        return [
            Float((val >> 16) & 0xFF) / 255.0,
            Float((val >> 8) & 0xFF) / 255.0,
            Float(val & 0xFF) / 255.0
        ]
    }

}

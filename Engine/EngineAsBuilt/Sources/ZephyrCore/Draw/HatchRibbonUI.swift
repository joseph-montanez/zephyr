import Foundation
import ImGui

// MARK: - HatchRibbonUI
//
// Shared floating card for hatch creation and post-selection editing.

@MainActor
public struct HatchRibbonUI {

    /// Settings bundle passed between the ribbon and its owner.
    public struct Settings: Equatable {
        public var fillType: Int32 = 1       // 0=Pattern, 1=Solid, 2=Gradient
        public var patternName: String = "ANSI31"
        public var gradientName: String = "LINEAR"
        public var scale: Float = 1.0
        public var angle: Float = 0.0
        public var primaryColor: ColorRGBA? = nil
        public var backgroundColor: ColorRGBA? = nil
        public var secondaryColor: ColorRGBA? = nil
        public var selectionMode: Int32 = 0  // 0=PickPoints, 1=SelectBoundary
        public var showModeSection: Bool = true  // hidden during edit mode
        public var applyClicked: Bool = false
        public var closeRequested: Bool = false
        public var associative: Bool = true

        public init(fillType: Int32, patternName: String, gradientName: String = "LINEAR", scale: Float, angle: Float,
                    primaryColor: ColorRGBA?, backgroundColor: ColorRGBA?,
                    secondaryColor: ColorRGBA?, selectionMode: Int32, showModeSection: Bool,
                    applyClicked: Bool = false, closeRequested: Bool = false, associative: Bool = true) {
            self.fillType = fillType
            self.patternName = patternName
            self.gradientName = gradientName
            self.scale = scale
            self.angle = angle
            self.primaryColor = primaryColor
            self.backgroundColor = backgroundColor
            self.secondaryColor = secondaryColor
            self.selectionMode = selectionMode
            self.showModeSection = showModeSection
            self.applyClicked = applyClicked
            self.closeRequested = closeRequested
            self.associative = associative
        }
    }

    public static var activeColorPopup: Int = 0  // 0=none, 1=primary, 2=background, 3=secondary
    private static var patternSearchText = ""

    // MARK: - Public render entry point

    public static func render(_ settings: inout Settings, engine: PhrostEngine) {
        let fontSize = ImGuiGetFontSize()
        let uiScale = max(0.75, engine.effectiveUiScale)
        let pad: Float = 16.0 * uiScale
        let itemGap: Float = 4.0 * uiScale
        let controlH = max(ImGuiGetFrameHeight(), 30.0 * uiScale)

        let topChromeH: Float = {
            #if os(macOS)
            return 36.0 * uiScale
            #else
            return 50.0 * uiScale
            #endif
        }()
        
        let io = ImGuiGetIO()!.pointee
        let availableW = max(180.0, io.DisplaySize.x - 32.0 * uiScale)
        let preferredW = max(fontSize * 24.0, 400.0 * uiScale)
        let windowW = min(preferredW, availableW)
        let windowY = topChromeH + 24.0 * uiScale
        let windowX = max(8.0 * uiScale, io.DisplaySize.x - windowW - 24.0 * uiScale)
        let maxWindowH = max(220.0 * uiScale, io.DisplaySize.y - windowY - 16.0 * uiScale)

        ImGuiSetNextWindowPos(
            ImVec2(x: windowX, y: windowY),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSizeConstraints(
            ImVec2(x: windowW, y: 0),
            ImVec2(x: windowW, y: maxWindowH),
            { _ in },
            nil)

        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 12.0 * uiScale)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: pad, y: pad))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)

        let flags = Int32(ImGuiWindowFlags_NoTitleBar.rawValue
                        | ImGuiWindowFlags_NoSavedSettings.rawValue
                        | ImGuiWindowFlags_NoCollapse.rawValue
                        | ImGuiWindowFlags_AlwaysAutoResize.rawValue)

        guard igBegin("##HatchCard", nil, flags) else {
            ImGuiEnd()
            ImGuiPopStyleVar(2)
            ImGuiPopStyleColor(1)
            return
        }

        defer {
            ImGuiEnd()
            ImGuiPopStyleVar(2)
            ImGuiPopStyleColor(1)
        }

        let dl = igGetWindowDrawList()
        let activeBg = engine.ui.theme.activeBg
        let contentW = ImGuiGetContentRegionAvail().x

        // --- Custom Header ---
        igBeginGroup()
        // We simulate a bold header
        ImGuiTextV("... Hatch")
        
        if !settings.showModeSection {
            ImGuiSameLine(0, 8)
            ImGuiTextV("[ 1 SELECTED ]")
        }

        // Close button 'x' on right
        ImGuiSameLine(0, 0)
        let closeX = pad + contentW - controlH
        if ImGuiGetCursorPosX() < closeX {
            ImGuiSetCursorPosX(closeX)
        }
        if igButton("x##HatchClose", ImVec2(x: controlH, y: controlH)) {
            settings.closeRequested = true
        }
        igEndGroup()
        
        ImGuiDummy(ImVec2(x: 0, y: 8.0 * uiScale))

        // --- Fill Type Segments ---
        let fillTypeTabs = [
            (label: "Pattern", value: 0),
            (label: "Gradient", value: 2),
            (label: "Solid", value: 1),
            (label: "User", value: 3)
        ]
        
        let segW = max(48.0 * uiScale, (contentW - itemGap * 3.0) / 4.0)
        for (idx, tab) in fillTypeTabs.enumerated() {
            if idx > 0 { ImGuiSameLine(0, itemGap) }
            let isSelected = settings.fillType == Int32(tab.value)
            
            if isSelected {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), activeBg)
            }
            
            if igButton(tab.label, ImVec2(x: segW, y: controlH)) {
                settings.fillType = Int32(tab.value)
            }
            
            if isSelected {
                ImGuiPopStyleColor(1)
            }
        }
        
        ImGuiDummy(ImVec2(x: 0, y: 12.0 * uiScale))

        // --- Preview Area ---
        let previewH: Float = 100.0 * uiScale
        let pScreenPos = igGetCursorScreenPos()
        let pMin = ImVec2(x: pScreenPos.x, y: pScreenPos.y)
        let pMax = ImVec2(x: pMin.x + contentW, y: pMin.y + previewH)
        
        let bgCol = settings.backgroundColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
        let bgU32 = makeCol32(bgCol.r, bgCol.g, bgCol.b, bgCol.a)
        
        if settings.fillType == 2 {
            let c1 = settings.primaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            let c1U32 = makeCol32(c1.r, c1.g, c1.b, c1.a)
            ImDrawListAddRectFilled(dl, pMin, pMax, c1U32, 8.0 * uiScale, 0)
        } else {
            ImDrawListAddRectFilled(dl, pMin, pMax, bgU32, 8.0 * uiScale, 0)
            let fgCol = settings.primaryColor ?? ColorRGBA(r: 100, g: 100, b: 100, a: 255)
            let fgU32 = makeCol32(fgCol.r, fgCol.g, fgCol.b, fgCol.a)
            
            if settings.fillType == 0 {
                renderPatternPreview(
                    patternKey: settings.patternName,
                    angleRadians: Double(settings.angle),
                    pMin: pMin,
                    pMax: pMax,
                    color: fgU32,
                    uiScale: uiScale,
                    drawList: dl)
            } else if settings.fillType == 1 {
                ImDrawListAddRectFilled(dl, pMin, pMax, fgU32, 8.0 * uiScale, 0)
            }
        }
        ImDrawListAddRect(dl, pMin, pMax, makeCol32(255, 255, 255, 40), 8.0 * uiScale, 1.0 * uiScale, 0)
        
        // Pattern / Gradient Name Badge in bottom left
        let badgeText = settings.fillType == 0
            ? DXFHatchGenerator.patternDisplayName(for: settings.patternName)
            : (settings.fillType == 2 ? settings.gradientName.capitalized : "Solid")
        let badgeSize = igCalcTextSize(badgeText, nil, false, -1.0)
        let badgeMin = ImVec2(x: pMin.x + 8.0 * uiScale, y: pMax.y - badgeSize.y - 12.0 * uiScale)
        let badgeMax = ImVec2(x: badgeMin.x + badgeSize.x + 12.0 * uiScale, y: badgeMin.y + badgeSize.y + 8.0 * uiScale)
        ImDrawListAddRectFilled(dl, badgeMin, badgeMax, makeCol32(40, 40, 40, 200), 4.0 * uiScale, 0)
        
        ImGuiDummy(ImVec2(x: contentW, y: previewH))
        
        let oldPos = igGetCursorScreenPos()
        ImGuiSetCursorScreenPos(ImVec2(x: badgeMin.x + 6.0 * uiScale, y: badgeMin.y + 4.0 * uiScale))
        ImGuiTextV(badgeText)
        ImGuiSetCursorScreenPos(oldPos)
        
        ImGuiDummy(ImVec2(x: 0, y: 12.0 * uiScale))

        if settings.fillType == 0 {
            renderPatternBrowser(
                settings: &settings,
                contentWidth: contentW,
                controlHeight: controlH,
                uiScale: uiScale,
                engine: engine)
            ImGuiDummy(ImVec2(x: 0, y: 12.0 * uiScale))
        }

        // Colors
        if settings.fillType == 0 || settings.fillType == 1 {
            ImGuiTextV(settings.fillType == 0 ? "Pattern color" : "Color")
            renderColorPresetRow(id: 1, currentColor: &settings.primaryColor, engine: engine)
            
            if settings.fillType == 0 {
                ImGuiDummy(ImVec2(x: 0, y: 8.0 * uiScale))
                var hasBg = settings.backgroundColor != nil
                if igCheckbox("Background color", &hasBg) {
                    if hasBg {
                        settings.backgroundColor = ColorRGBA(r: 200, g: 200, b: 200, a: 255)
                    } else {
                        settings.backgroundColor = nil
                    }
                }
                if hasBg {
                    ImGuiDummy(ImVec2(x: 0, y: 4.0 * uiScale))
                    renderColorPresetRow(id: 2, currentColor: &settings.backgroundColor, engine: engine)
                }
            }
        } else if settings.fillType == 2 {
            ImGuiDummy(ImVec2(x: 0, y: 8.0 * uiScale))
            ImGuiTextV("Type")
            let gradients = ["LINEAR", "CYLINDER", "INVCYLINDER", "SPHERICAL", "HEMISPHERICAL", "CURVED", "INVCURVED", "INVSPHERICAL", "INVHEMISPHERICAL"]
            if let currentIdx = gradients.firstIndex(of: settings.gradientName.uppercased()) {
                var idx = Int32(currentIdx)
                ImGuiPushItemWidth(-1)
                // Use a C array of C strings for Combo
                let cStrings = gradients.map { z_strdup($0) }
                var cPointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
                if igCombo_Str_arr("##GradientCombo", &idx, &cPointers, Int32(gradients.count), -1) {
                    settings.gradientName = gradients[Int(idx)]
                }
                ImGuiPopItemWidth()
                for cStr in cStrings { free(cStr) }
            } else {
                var idx: Int32 = 0
                ImGuiPushItemWidth(-1)
                let cStrings = gradients.map { z_strdup($0) }
                var cPointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
                if igCombo_Str_arr("##GradientCombo", &idx, &cPointers, Int32(gradients.count), -1) {
                    settings.gradientName = gradients[Int(idx)]
                }
                ImGuiPopItemWidth()
                for cStr in cStrings { free(cStr) }
            }

            ImGuiDummy(ImVec2(x: 0, y: 12.0 * uiScale))
            ImGuiTextV("Start color")
            renderColorPresetRow(id: 1, currentColor: &settings.primaryColor, engine: engine)
            ImGuiDummy(ImVec2(x: 0, y: 8.0 * uiScale))
            ImGuiTextV("Stop color")
            renderColorPresetRow(id: 3, currentColor: &settings.secondaryColor, engine: engine)
        }
        
        ImGuiDummy(ImVec2(x: 0, y: 12.0 * uiScale))
        
        // Sliders
        ImGuiTextV("Angle")
        ImGuiPushItemWidth(-1)
        ImGuiSliderAngle("##HatchAngle", &settings.angle, -180, 180, "%.0f", ImGuiSliderFlags(0))
        ImGuiPopItemWidth()
        
        if settings.fillType == 0 {
            ImGuiDummy(ImVec2(x: 0, y: 8.0 * uiScale))
            ImGuiTextV("Scale")
            ImGuiPushItemWidth(-1)
            ImGuiInputFloat("##HatchScale", &settings.scale, 0.1, 1.0, "%.2f", 0)
            ImGuiPopItemWidth()
        }
        
        ImGuiDummy(ImVec2(x: 0, y: 12.0 * uiScale))
        
        // Associative Toggle
        // Swift ImGui checkbox uses inout Bool, let's use a var
        var assoc = settings.associative
        if igCheckbox("Associative boundary", &assoc) {
            settings.associative = assoc
        }
        
        // Creation Actions
        if settings.showModeSection {
            ImGuiDummy(ImVec2(x: 0, y: 16.0 * uiScale))
            
            // Pick / Boundary segmented
            let selW = max(80.0 * uiScale, (contentW - itemGap) / 2.0)
            if settings.selectionMode == 0 {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), engine.ui.theme.activeBg)
            }
            if igButton("+ Pick Points", ImVec2(x: selW, y: controlH)) { settings.selectionMode = 0 }
            if settings.selectionMode == 0 { ImGuiPopStyleColor(1) }
            
            ImGuiSameLine(0, itemGap)
            
            if settings.selectionMode == 1 {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), engine.ui.theme.activeBg)
            }
            if igButton("* Boundary", ImVec2(x: selW, y: controlH)) { settings.selectionMode = 1 }
            if settings.selectionMode == 1 { ImGuiPopStyleColor(1) }
            
            ImGuiDummy(ImVec2(x: 0, y: 12.0 * uiScale))
            
            // Apply hatch button
            ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), makeCol32(220, 150, 40, 255))
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), makeCol32(240, 170, 60, 255))
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), makeCol32(200, 130, 20, 255))
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), makeCol32(20, 20, 20, 255))
            
            if igButton("Apply hatch", ImVec2(x: ImGuiGetContentRegionAvail().x, y: max(controlH, 40.0 * uiScale))) {
                settings.applyClicked = true
            }
            ImGuiPopStyleColor(4)
        }
    }


    private static func renderPatternBrowser(
        settings: inout Settings,
        contentWidth: Float,
        controlHeight: Float,
        uiScale: Float,
        engine: PhrostEngine
    ) {
        HatchPatternLibrary.ensureLoaded()

        var searchBuffer = [CChar](repeating: 0, count: 192)
        let bytes = patternSearchText.utf8CString
        let copyCount = min(bytes.count, searchBuffer.count - 1)
        if copyCount > 0 {
            searchBuffer.withUnsafeMutableBufferPointer { target in
                _ = target.initialize(from: bytes.prefix(copyCount))
            }
        }

        ImGuiPushItemWidth(-1)
        if igInputTextWithHint(
            "##HatchPatternSearch",
            "Search hatch patterns...",
            &searchBuffer,
            searchBuffer.count,
            0,
            nil,
            nil) {
            patternSearchText = searchBuffer.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
        }
        ImGuiPopItemWidth()

        ImGuiDummy(ImVec2(x: 0, y: 6.0 * uiScale))
        let matches = HatchPatternLibrary.search(patternSearchText)
        let fileCount = HatchPatternLibrary.loadedFiles.count
        ImGuiTextV("\(matches.count) patterns from \(fileCount) PAT file\(fileCount == 1 ? "" : "s")")

        let reloadLabel = "Reload##HatchPatterns"
        let reloadWidth = ImGuiCalcTextSize("Reload", nil, false, -1).x + 20.0 * uiScale
        ImGuiSameLine(max(0, contentWidth - reloadWidth), 0)
        if igButton(reloadLabel, ImVec2(x: reloadWidth, y: controlHeight)) {
            HatchPatternLibrary.reload()
        }

        ImGuiDummy(ImVec2(x: 0, y: 6.0 * uiScale))
        let listHeight = min(220.0 * uiScale, max(110.0 * uiScale, ImGuiGetTextLineHeightWithSpacing() * 7.0))
        if igBeginChild_Str(
            "##HatchPatternResults",
            ImVec2(x: contentWidth, y: listHeight),
            1,
            Int32(ImGuiWindowFlags_AlwaysVerticalScrollbar.rawValue)) {
            if matches.isEmpty {
                ImGuiTextV("No matching hatch patterns")
            } else {
                for entry in matches {
                    let selected = settings.patternName.caseInsensitiveCompare(entry.key) == .orderedSame
                    let label = "\(entry.name)  [\(entry.sourceName)]##\(entry.key)"
                    if ImGuiSelectable(
                        label,
                        selected,
                        Int32(ImGuiSelectableFlags_None.rawValue),
                        ImVec2(x: 0, y: controlHeight)) {
                        settings.fillType = 0
                        settings.patternName = entry.key
                    }
                    if ImGuiIsItemHovered(0) {
                        ImGuiBeginTooltip()
                        ImGuiTextV(entry.name)
                        if !entry.description.isEmpty { ImGuiTextWrappedV(entry.description) }
                        ImGuiTextV("Source: \(entry.sourceName).pat")
                        ImGuiTextV("Definition lines: \(entry.definition.lines.count)")
                        ImGuiEndTooltip()
                    }
                }
            }
        }
        igEndChild()
    }

    private static func renderPatternPreview(
        patternKey: String,
        angleRadians: Double,
        pMin: ImVec2,
        pMax: ImVec2,
        color: UInt32,
        uiScale: Float,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) {
        let inset = 5.0 * uiScale
        let width = max(1.0, Double(pMax.x - pMin.x - inset * 2.0))
        let height = max(1.0, Double(pMax.y - pMin.y - inset * 2.0))
        let polygon = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: width, y: 0, z: 0),
            Vector3(x: width, y: height, z: 0),
            Vector3(x: 0, y: height, z: 0)
        ]
        let previewScale = DXFHatchGenerator.previewScale(
            for: patternKey,
            targetSpacing: Double(10.0 * uiScale))
        let primitives = DXFHatchGenerator.generatePatternHatch(
            polygon: polygon,
            patternName: patternKey,
            scale: previewScale,
            angleDegrees: angleRadians * 180.0 / .pi,
            minimumSpacing: Double(2.0 * uiScale))

        for primitive in primitives.prefix(2048) {
            switch primitive {
            case .line(let start, let end, _):
                ImDrawListAddLine(
                    drawList,
                    ImVec2(x: pMin.x + inset + Float(start.x), y: pMin.y + inset + Float(start.y)),
                    ImVec2(x: pMin.x + inset + Float(end.x), y: pMin.y + inset + Float(end.y)),
                    color,
                    max(1.0, uiScale))
            case .point(let position, _):
                ImDrawListAddCircleFilled(
                    drawList,
                    ImVec2(x: pMin.x + inset + Float(position.x), y: pMin.y + inset + Float(position.y)),
                    max(1.0, 1.5 * uiScale),
                    color,
                    8)
            default:
                break
            }
        }
    }

    private static func renderColorPresetRow(id: Int, currentColor: inout ColorRGBA?, engine: PhrostEngine) {
        let presetColors: [ColorRGBA] = [
            ColorRGBA(r: 255, g: 90,  b: 90),
            ColorRGBA(r: 250, g: 180, b: 40),
            ColorRGBA(r: 80,  g: 220, b: 120),
            ColorRGBA(r: 40,  g: 220, b: 240),
            ColorRGBA(r: 60,  g: 140, b: 255),
            ColorRGBA(r: 160, g: 90,  b: 220),
            ColorRGBA(r: 250, g: 250, b: 250),
            ColorRGBA(r: 140, g: 150, b: 160)
        ]
        
        let uiScale = max(0.75, engine.effectiveUiScale)
        let spacing: Float = 4.0 * uiScale
        let buttonCount: Float = 9.0
        let available = ImGuiGetContentRegionAvail().x
        let buttonW = min(24.0 * uiScale, max(14.0 * uiScale, (available - spacing * (buttonCount - 1.0)) / buttonCount))
        let size = ImVec2(x: buttonW, y: max(ImGuiGetFrameHeight(), 24.0 * uiScale))
        for (i, col) in presetColors.enumerated() {
            if i > 0 { ImGuiSameLine(0, spacing) }
            
            let colU32 = makeCol32(col.r, col.g, col.b, 255)
            ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), colU32)
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), colU32)
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), colU32)
            
            if igButton("##c\(id)_\(i)", size) {
                currentColor = col
            }
            
            ImGuiPopStyleColor(3)
            
            // Highlight if selected
            if currentColor == col {
                let rMin = igGetItemRectMin()
                let rMax = igGetItemRectMax()
                ImDrawListAddRect(igGetWindowDrawList(), rMin, rMax, makeCol32(255, 255, 255, 255), 4.0 * uiScale, 2.0 * uiScale, 0)
            } else {
                let rMin = igGetItemRectMin()
                let rMax = igGetItemRectMax()
                ImDrawListAddRect(igGetWindowDrawList(), rMin, rMax, makeCol32(0, 0, 0, 50), 4.0 * uiScale, 1.0 * uiScale, 0)
            }
        }
        
        // Custom + button
        ImGuiSameLine(0, spacing)
        if igButton("+##custom_\(id)", size) {
            activeColorPopup = id
            igOpenPopup_Str("##ColorPopup", 0)
        }
        
        if activeColorPopup == id && igBeginPopup("##ColorPopup", 0) {
            var col: [Float] = [0.5, 0.5, 0.5, 1.0]
            if let c = currentColor {
                col = [Float(c.r) / 255.0, Float(c.g) / 255.0, Float(c.b) / 255.0, Float(c.a) / 255.0]
            }
            if igColorEdit4("##CustomColor", &col, 0) {
                currentColor = ColorRGBA(
                    r: UInt8(Swift.max(0, Swift.min(255, col[0] * 255))),
                    g: UInt8(Swift.max(0, Swift.min(255, col[1] * 255))),
                    b: UInt8(Swift.max(0, Swift.min(255, col[2] * 255))),
                    a: UInt8(Swift.max(0, Swift.min(255, col[3] * 255))))
            }
            igEndPopup()
        }
    }
}


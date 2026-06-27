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

    // MARK: - Public render entry point

    public static func render(_ settings: inout Settings, engine: PhrostEngine) {
        let fontSize = ImGuiGetFontSize()
        let pad: Float = 16.0

        let topChromeH: Float = {
            #if os(macOS)
            return 36.0
            #else
            return 50.0
            #endif
        }()
        
        let windowW = fontSize * 22 // about 300-350px
        let io = ImGuiGetIO()!.pointee
        let windowX = io.DisplaySize.x - windowW - 24.0
        let windowY = topChromeH + 24.0

        ImGuiSetNextWindowPos(
            ImVec2(x: windowX, y: windowY),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: windowW, y: 0),
            Int32(ImGuiCond_Always.rawValue))

        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 12.0)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: pad, y: pad))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)

        let flags = Int32(ImGuiWindowFlags_NoTitleBar.rawValue
                        | ImGuiWindowFlags_NoScrollbar.rawValue
                        | ImGuiWindowFlags_NoSavedSettings.rawValue
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

        // --- Custom Header ---
        igBeginGroup()
        // We simulate a bold header
        ImGuiTextV("... Hatch")
        
        if !settings.showModeSection {
            ImGuiSameLine(0, 8)
            ImGuiTextV("[ 1 SELECTED ]")
        }

        // Close button 'x' on right
        let avail = igGetContentRegionAvail().x
        ImGuiSameLine(avail - 16, 0)
        if igSmallButton("x") {
            settings.closeRequested = true
        }
        igEndGroup()
        
        ImGuiDummy(ImVec2(x: 0, y: 8))

        // --- Fill Type Segments ---
        let fillTypeTabs = [
            (label: "Pattern", value: 0),
            (label: "Gradient", value: 2),
            (label: "Solid", value: 1),
            (label: "User", value: 3)
        ]
        
        let segW = (windowW - pad * 2 - 12.0) / 4.0
        for (idx, tab) in fillTypeTabs.enumerated() {
            if idx > 0 { ImGuiSameLine(0, 4) }
            let isSelected = settings.fillType == Int32(tab.value)
            
            if isSelected {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), activeBg)
            }
            
            if igButton(tab.label, ImVec2(x: segW, y: 26)) {
                settings.fillType = Int32(tab.value)
            }
            
            if isSelected {
                ImGuiPopStyleColor(1)
            }
        }
        
        ImGuiDummy(ImVec2(x: 0, y: 12))

        // --- Preview Area ---
        let previewH: Float = 100.0
        let pScreenPos = igGetCursorScreenPos()
        let pMin = ImVec2(x: pScreenPos.x, y: pScreenPos.y)
        let pMax = ImVec2(x: pMin.x + windowW - pad*2, y: pMin.y + previewH)
        
        let bgCol = settings.backgroundColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
        let bgU32 = makeCol32(bgCol.r, bgCol.g, bgCol.b, bgCol.a)
        
        if settings.fillType == 2 {
            let c1 = settings.primaryColor ?? ColorRGBA(r: 255, g: 255, b: 255, a: 255)
            let c1U32 = makeCol32(c1.r, c1.g, c1.b, c1.a)
            ImDrawListAddRectFilled(dl, pMin, pMax, c1U32, 8.0, 0)
        } else {
            ImDrawListAddRectFilled(dl, pMin, pMax, bgU32, 8.0, 0)
            let fgCol = settings.primaryColor ?? ColorRGBA(r: 100, g: 100, b: 100, a: 255)
            let fgU32 = makeCol32(fgCol.r, fgCol.g, fgCol.b, fgCol.a)
            
            if settings.fillType == 0 {
                // simple horizontal pattern lines
                let lineSpacing: Float = 6.0
                for y in stride(from: pMin.y + 4.0, to: pMax.y - 4.0, by: lineSpacing) {
                    ImDrawListAddLine(dl, ImVec2(x: pMin.x + 4.0, y: y), ImVec2(x: pMax.x - 4.0, y: y), fgU32, 2.0)
                }
            } else if settings.fillType == 1 {
                ImDrawListAddRectFilled(dl, pMin, pMax, fgU32, 8.0, 0)
            }
        }
        ImDrawListAddRect(dl, pMin, pMax, makeCol32(255, 255, 255, 40), 8.0, 1.0, 0)
        
        // Pattern / Gradient Name Badge in bottom left
        let badgeText = settings.fillType == 0 ? settings.patternName : (settings.fillType == 2 ? settings.gradientName.capitalized : "Solid")
        let badgeSize = igCalcTextSize(badgeText, nil, false, -1.0)
        let badgeMin = ImVec2(x: pMin.x + 8, y: pMax.y - badgeSize.y - 12)
        let badgeMax = ImVec2(x: badgeMin.x + badgeSize.x + 12, y: badgeMin.y + badgeSize.y + 8)
        ImDrawListAddRectFilled(dl, badgeMin, badgeMax, makeCol32(40, 40, 40, 200), 4.0, 0)
        
        ImGuiDummy(ImVec2(x: windowW - pad*2, y: previewH))
        
        let oldPos = igGetCursorScreenPos()
        ImGuiSetCursorScreenPos(ImVec2(x: badgeMin.x + 6, y: badgeMin.y + 4))
        ImGuiTextV(badgeText)
        ImGuiSetCursorScreenPos(oldPos)
        
        ImGuiDummy(ImVec2(x: 0, y: 12))

        // Search Bar (Dummy)
        var searchBuf = [CChar](repeating: 0, count: 64)
        ImGuiPushItemWidth(-1)
        igInputTextWithHint("##search", "Q Search...", &searchBuf, 64, 0, nil, nil)
        ImGuiPopItemWidth()
        
        ImGuiDummy(ImVec2(x: 0, y: 12))

        // Colors
        if settings.fillType == 0 || settings.fillType == 1 {
            ImGuiTextV(settings.fillType == 0 ? "Pattern color" : "Color")
            renderColorPresetRow(id: 1, currentColor: &settings.primaryColor, engine: engine)
            
            if settings.fillType == 0 {
                ImGuiDummy(ImVec2(x: 0, y: 8))
                var hasBg = settings.backgroundColor != nil
                if igCheckbox("Background color", &hasBg) {
                    if hasBg {
                        settings.backgroundColor = ColorRGBA(r: 200, g: 200, b: 200, a: 255)
                    } else {
                        settings.backgroundColor = nil
                    }
                }
                if hasBg {
                    ImGuiDummy(ImVec2(x: 0, y: 4))
                    renderColorPresetRow(id: 2, currentColor: &settings.backgroundColor, engine: engine)
                }
            }
        } else if settings.fillType == 2 {
            ImGuiDummy(ImVec2(x: 0, y: 8))
            ImGuiTextV("Type")
            let gradients = ["LINEAR", "CYLINDER", "INVCYLINDER", "SPHERICAL", "HEMISPHERICAL", "CURVED", "INVCURVED", "INVSPHERICAL", "INVHEMISPHERICAL"]
            if let currentIdx = gradients.firstIndex(of: settings.gradientName.uppercased()) {
                var idx = Int32(currentIdx)
                ImGuiPushItemWidth(-1)
                // Use a C array of C strings for Combo
                let cStrings = gradients.map { strdup($0) }
                var cPointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
                if igCombo_Str_arr("##GradientCombo", &idx, &cPointers, Int32(gradients.count), -1) {
                    settings.gradientName = gradients[Int(idx)]
                }
                ImGuiPopItemWidth()
                for cStr in cStrings { free(cStr) }
            } else {
                var idx: Int32 = 0
                ImGuiPushItemWidth(-1)
                let cStrings = gradients.map { strdup($0) }
                var cPointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
                if igCombo_Str_arr("##GradientCombo", &idx, &cPointers, Int32(gradients.count), -1) {
                    settings.gradientName = gradients[Int(idx)]
                }
                ImGuiPopItemWidth()
                for cStr in cStrings { free(cStr) }
            }

            ImGuiDummy(ImVec2(x: 0, y: 12))
            ImGuiTextV("Start color")
            renderColorPresetRow(id: 1, currentColor: &settings.primaryColor, engine: engine)
            ImGuiDummy(ImVec2(x: 0, y: 8))
            ImGuiTextV("Stop color")
            renderColorPresetRow(id: 3, currentColor: &settings.secondaryColor, engine: engine)
        }
        
        ImGuiDummy(ImVec2(x: 0, y: 12))
        
        // Sliders
        ImGuiTextV("Angle")
        ImGuiPushItemWidth(-1)
        ImGuiSliderAngle("##HatchAngle", &settings.angle, -180, 180, "%.0f", ImGuiSliderFlags(0))
        ImGuiPopItemWidth()
        
        if settings.fillType == 0 {
            ImGuiDummy(ImVec2(x: 0, y: 8))
            ImGuiTextV("Scale")
            ImGuiPushItemWidth(-1)
            ImGuiInputFloat("##HatchScale", &settings.scale, 0.1, 1.0, "%.2f", 0)
            ImGuiPopItemWidth()
        }
        
        ImGuiDummy(ImVec2(x: 0, y: 12))
        
        // Associative Toggle
        // Swift ImGui checkbox uses inout Bool, let's use a var
        var assoc = settings.associative
        if igCheckbox("Associative boundary", &assoc) {
            settings.associative = assoc
        }
        
        // Creation Actions
        if settings.showModeSection {
            ImGuiDummy(ImVec2(x: 0, y: 16))
            
            // Pick / Boundary segmented
            let selW = (windowW - pad * 2 - 4.0) / 2.0
            if settings.selectionMode == 0 {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), engine.ui.theme.activeBg)
            }
            if igButton("+ Pick Points", ImVec2(x: selW, y: 30)) { settings.selectionMode = 0 }
            if settings.selectionMode == 0 { ImGuiPopStyleColor(1) }
            
            ImGuiSameLine(0, 4)
            
            if settings.selectionMode == 1 {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), engine.ui.theme.activeBg)
            }
            if igButton("* Boundary", ImVec2(x: selW, y: 30)) { settings.selectionMode = 1 }
            if settings.selectionMode == 1 { ImGuiPopStyleColor(1) }
            
            ImGuiDummy(ImVec2(x: 0, y: 12))
            
            // Apply hatch button
            ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), makeCol32(220, 150, 40, 255))
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), makeCol32(240, 170, 60, 255))
            ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), makeCol32(200, 130, 20, 255))
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), makeCol32(20, 20, 20, 255))
            
            if igButton("Apply hatch", ImVec2(x: -1, y: 40)) {
                settings.applyClicked = true
            }
            ImGuiPopStyleColor(4)
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
        
        let size = ImVec2(x: 24, y: 24)
        for (i, col) in presetColors.enumerated() {
            if i > 0 { ImGuiSameLine(0, 4) }
            
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
                ImDrawListAddRect(igGetWindowDrawList(), rMin, rMax, makeCol32(255, 255, 255, 255), 4.0, 2.0, 0)
            } else {
                let rMin = igGetItemRectMin()
                let rMax = igGetItemRectMax()
                ImDrawListAddRect(igGetWindowDrawList(), rMin, rMax, makeCol32(0, 0, 0, 50), 4.0, 1.0, 0)
            }
        }
        
        // Custom + button
        ImGuiSameLine(0, 4)
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


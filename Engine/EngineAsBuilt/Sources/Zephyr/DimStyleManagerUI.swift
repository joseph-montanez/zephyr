import ZephyrCore
import Foundation
import ImGui

/// Dimension Style Manager (DIMSTYLE command, Phase 2.1). Mirrors
/// LeaderStyleManagerUI: per-document tracking, style list with the
/// current style badged, an editable draft, and New / Delete / Set
/// Current / Apply / Reset / Close. Draft edits apply through
/// CADDocument.applyDimensionStyle so renames rewrite entity references;
/// the LT sysvar subset (DIMSCALE/DIMASZ/...) edits the same table rows.
@MainActor
struct DimStyleManagerUI {
    private static var documentID: ObjectIdentifier?
    private static var selectedName = "Standard"
    private static var originalName = "Standard"
    private static var draft = CADDimensionStyle.default
    private static var message = ""

    private static let unitsFormats: [DimUnitsFormat] = [
        .scientific, .decimal, .engineering,
        .architectural, .fractional, .windowsDesktop,
    ]

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        let document = engine.document
        let currentID = ObjectIdentifier(document)
        if documentID != currentID {
            documentID = currentID
            select(document.currentDimensionStyleName, document: document)
        }
        if !document.dimensionStyles.keys.contains(where: {
            $0.caseInsensitiveCompare(selectedName) == .orderedSame
        }) {
            select("Standard", document: document)
        }

        let width: Float = 800
        let height: Float = 570
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        guard igBegin("Dimension Style Manager##DimStyleManager", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }

        if !opened {
            engine.ui.dimStyleManagerActive = false
            return
        }

        let names = document.dimensionStyles.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        if igBeginChild_Str("##DimStyleList", ImVec2(x: 225, y: -54), 1, 0) {
            ImGuiTextV("Styles")
            igSeparator()
            for name in names {
                let active = name.caseInsensitiveCompare(document.currentDimensionStyleName) == .orderedSame
                let label = active ? "\(name)  (current)" : name
                let selected = name.caseInsensitiveCompare(selectedName) == .orderedSame
                if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                    select(name, document: document)
                }
            }
        }
        igEndChild()

        ImGuiSameLine(0, 14)
        if igBeginChild_Str("##DimStyleProperties", ImVec2(x: 0, y: -54), 0, 0) {
            ImGuiTextV("Dimension format")
            igSeparator()
            inputText("Name", value: &draft.name)

            dragDouble("Overall scale (DIMSCALE)", value: &draft.overallScale, speed: 0.05, minimum: 0.0001)
            dragDouble("Arrow size (DIMASZ)", value: &draft.arrowSize, speed: 0.1, minimum: 0)
            dragDouble("Text height (DIMTXT)", value: &draft.textHeight, speed: 0.1, minimum: 0.0001)
            dragDouble("Text offset (DIMGAP)", value: &draft.textOffset, speed: 0.05, minimum: 0)
            dragDouble("Ext line offset (DIMEXO)", value: &draft.extensionLineOffset, speed: 0.05, minimum: 0)
            dragDouble("Ext line extend (DIMEXE)", value: &draft.extensionLineExtend, speed: 0.05, minimum: 0)
            dragDouble("Baseline spacing", value: &draft.dimLineOffset, speed: 0.1, minimum: 0)
            dragDouble("Tick size", value: &draft.tickSize, speed: 0.1, minimum: 0)

            var precision = Int32(draft.unitsPrecision)
            ImGuiSetNextItemWidth(190)
            if ImGuiDragInt("Precision (DIMDEC)", &precision, 0.1, 0, 8, "%d", ImGuiSliderFlags(0)) {
                draft.unitsPrecision = max(0, min(8, Int(precision)))
            }
            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Units (DIMLUNIT)", unitsLabel(draft.unitsFormat), 0) {
                for value in unitsFormats {
                    let selected = value == draft.unitsFormat
                    if ImGuiSelectable(unitsLabel(value), selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.unitsFormat = value
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }

            igSpacing()
            ImGuiTextV("Text")
            igSeparator()
            var textStyle = draft.textStyle ?? ""
            inputText("Text style", value: &textStyle)
            draft.textStyle = textStyle.isEmpty ? nil : textStyle
            var prefix = draft.dimensionPrefix ?? ""
            inputText("Prefix", value: &prefix)
            draft.dimensionPrefix = prefix.isEmpty ? nil : prefix
            var suffix = draft.dimensionSuffix ?? ""
            inputText("Suffix", value: &suffix)
            draft.dimensionSuffix = suffix.isEmpty ? nil : suffix
            var linearScale = draft.linearScaleFactor ?? 1.0
            dragDouble("Linear scale", value: &linearScale, speed: 0.05, minimum: 0.0001)
            draft.linearScaleFactor = linearScale

            igSpacing()
            ImGuiTextV("Suppress")
            igSeparator()
            _ = ImGuiCheckbox("First extension line", &draft.suppressFirstExtension)
            _ = ImGuiCheckbox("Second extension line", &draft.suppressSecondExtension)
            _ = ImGuiCheckbox("First dimension line", &draft.suppressFirstDimLine)
            _ = ImGuiCheckbox("Second dimension line", &draft.suppressSecondDimLine)

            if !message.isEmpty {
                igSpacing()
                ImGuiTextWrappedV(message)
            }
        }
        igEndChild()

        if igButton("New", ImVec2(x: 85, y: 0)) {
            let name = uniqueName(document: document)
            var style = CADDimensionStyle.default
            style.name = name
            if document.applyDimensionStyle(style) {
                select(name, document: document)
                message = "Created \(name)."
            }
        }
        ImGuiSameLine(0, 7)

        let isStandard = selectedName.caseInsensitiveCompare("Standard") == .orderedSame
        if isStandard { ImGuiBeginDisabled(true) }
        if igButton("Delete", ImVec2(x: 85, y: 0)) {
            if document.deleteDimensionStyle(named: selectedName) {
                select("Standard", document: document)
                message = "Style deleted."
            }
        }
        if isStandard { ImGuiEndDisabled() }

        ImGuiSameLine(0, 7)
        if igButton("Set Current", ImVec2(x: 105, y: 0)) {
            if document.setCurrentDimensionStyle(named: selectedName) {
                message = "Current style set to \(selectedName)."
            } else {
                message = "Style no longer exists."
            }
        }

        ImGuiSameLine(0, 7)
        if igButton("Apply", ImVec2(x: 85, y: 0)) {
            let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                message = "Style name cannot be empty."
            } else if originalName.caseInsensitiveCompare("Standard") == .orderedSame
                        && trimmed.caseInsensitiveCompare("Standard") != .orderedSame {
                message = "Standard cannot be renamed."
            } else {
                draft.name = trimmed
                if document.applyDimensionStyle(draft, replacing: originalName) {
                    select(trimmed, document: document)
                    message = "Style applied."
                } else {
                    message = "Apply failed."
                }
            }
        }

        ImGuiSameLine(0, 7)
        if igButton("Reset", ImVec2(x: 80, y: 0)) {
            select(selectedName, document: document)
        }

        ImGuiSameLine(width - 112, 0)
        if igButton("Close", ImVec2(x: 90, y: 0)) {
            engine.ui.dimStyleManagerActive = false
        }
        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            engine.ui.dimStyleManagerActive = false
        }
    }

    private static func select(_ name: String, document: CADDocument) {
        // Keys are the source of truth: decoded styles may carry a stale
        // embedded name, so re-stamp the draft from the resolved key.
        let key = document.resolvedDimensionStyleName(name)
        var style = document.dimensionStyle(named: key)
        style.name = key
        selectedName = key
        originalName = key
        draft = style
        message = ""
    }

    private static func uniqueName(document: CADDocument) -> String {
        var index = 1
        while document.dimensionStyles.keys.contains(where: {
            $0.caseInsensitiveCompare("DimStyle\(index)") == .orderedSame
        }) { index += 1 }
        return "DimStyle\(index)"
    }

    private static func unitsLabel(_ value: DimUnitsFormat) -> String {
        switch value {
        case .scientific: return "Scientific"
        case .decimal: return "Decimal"
        case .engineering: return "Engineering"
        case .architectural: return "Architectural"
        case .fractional: return "Fractional"
        case .windowsDesktop: return "Windows desktop"
        }
    }

    private static func dragDouble(
        _ label: String,
        value: inout Double,
        speed: Float,
        minimum: Double
    ) {
        var floatValue = Float(value)
        ImGuiSetNextItemWidth(190)
        if ImGuiDragFloat(label, &floatValue, speed, Float(minimum), Float.greatestFiniteMagnitude, "%.3f", ImGuiSliderFlags(0)) {
            value = max(minimum, Double(floatValue))
        }
    }

    private static func inputText(_ label: String, value: inout String) {
        let capacity = 256
        var buffer = [CChar](repeating: 0, count: capacity)
        let bytes = value.utf8CString
        for index in 0..<min(bytes.count, capacity - 1) { buffer[index] = bytes[index] }
        ImGuiSetNextItemWidth(-1)
        let changed = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            return igInputText(label, base, capacity, 0, { _ in 0 }, nil)
        }
        if changed {
            value = buffer.withUnsafeBufferPointer { pointer in String(cString: pointer.baseAddress!) }
        }
    }
}

import ZephyrCore
import Foundation
import ImGui

@MainActor
struct LeaderStyleManagerUI {
    private static var documentID: ObjectIdentifier?
    private static var selectedName = "Standard"
    private static var originalName = "Standard"
    private static var draft = CADLeaderStyle.standard
    private static var message = ""

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        let document = engine.document
        let currentID = ObjectIdentifier(document)
        if documentID != currentID {
            documentID = currentID
            select(document.currentLeaderStyleName, document: document)
        }
        if document.leaderStyle(named: selectedName) == nil {
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
        guard igBegin("Multileader Style Manager##MLeaderStyleManager", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }

        if !opened {
            engine.ui.leaderStyleManagerActive = false
            return
        }

        let styles = document.leaderStyles.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if igBeginChild_Str("##LeaderStyleList", ImVec2(x: 225, y: -54), 1, 0) {
            ImGuiTextV("Styles")
            igSeparator()
            for style in styles {
                let active = style.name.caseInsensitiveCompare(document.currentLeaderStyleName) == .orderedSame
                let label = active ? "\(style.name)  (current)" : style.name
                let selected = style.name.caseInsensitiveCompare(selectedName) == .orderedSame
                if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                    select(style.name, document: document)
                }
            }
        }
        igEndChild()

        ImGuiSameLine(0, 14)
        if igBeginChild_Str("##LeaderStyleProperties", ImVec2(x: 0, y: -54), 0, 0) {
            ImGuiTextV("Leader format")
            igSeparator()
            inputText("Name", value: &draft.name)

            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Leader type", pathLabel(draft.pathType), 0) {
                for value in CADLeaderPathType.allCases {
                    let selected = value == draft.pathType
                    if ImGuiSelectable(pathLabel(value), selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.pathType = value
                    }
                }
                ImGuiEndCombo()
            }

            _ = ImGuiCheckbox("Arrowhead", &draft.arrowEnabled)
            let arrowhead = draft.arrowhead ?? .closedFilled
            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Arrow type", arrowheadLabel(arrowhead), 0) {
                for value in CADLeaderArrowhead.allCases {
                    let selected = value == arrowhead
                    if ImGuiSelectable(arrowheadLabel(value), selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.arrowhead = value
                        draft.arrowEnabled = value != .none
                        if value != .custom { draft.arrowBlockName = nil }
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            if draft.arrowhead == .custom {
                let current = draft.arrowBlockName ?? "Select block"
                ImGuiSetNextItemWidth(190)
                if ImGuiBeginCombo("Arrow block", current, 0) {
                    for block in engine.document.allBlocks.filter({ !$0.name.isEmpty }).sorted(by: { $0.name < $1.name }) {
                        let selected = block.name.caseInsensitiveCompare(draft.arrowBlockName ?? "") == .orderedSame
                        if ImGuiSelectable(block.name, selected, 0, ImVec2(x: 0, y: 0)) {
                            draft.arrowBlockName = block.name
                        }
                        if selected { ImGuiSetItemDefaultFocus() }
                    }
                    ImGuiEndCombo()
                }
            }
            dragDouble("Arrow size", value: &draft.arrowSize, speed: 0.1, minimum: 0)
            _ = ImGuiCheckbox("Landing", &draft.landingEnabled)
            _ = ImGuiCheckbox("Dogleg", &draft.doglegEnabled)
            dragDouble("Dogleg length", value: &draft.doglegLength, speed: 0.1, minimum: 0)
            dragDouble("Content gap", value: &draft.contentGap, speed: 0.05, minimum: 0)
            var extendToText = draft.extendLeaderToText ?? false
            if ImGuiCheckbox("Extend leader to text", &extendToText) {
                draft.extendLeaderToText = extendToText
            }

            igSpacing()
            ImGuiTextV("Content")
            igSeparator()
            dragDouble("Text height", value: &draft.textHeight, speed: 0.1, minimum: 0.0001)
            inputText("Text style", value: &draft.textStyleName)
            let alignment = draft.textAlignment ?? .left
            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Text alignment", textAlignmentLabel(alignment), 0) {
                for value in CADLeaderTextAlignment.allCases {
                    let selected = value == alignment
                    if ImGuiSelectable(textAlignmentLabel(value), selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.textAlignment = value
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let leftAttachment = draft.leftAttachment ?? .middleOfTop
            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Left attachment", attachmentLabel(leftAttachment), 0) {
                for value in CADLeaderTextAttachment.allCases {
                    let selected = value == leftAttachment
                    if ImGuiSelectable(attachmentLabel(value), selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.leftAttachment = value
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let rightAttachment = draft.rightAttachment ?? .middleOfTop
            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Right attachment", attachmentLabel(rightAttachment), 0) {
                for value in CADLeaderTextAttachment.allCases {
                    let selected = value == rightAttachment
                    if ImGuiSelectable(attachmentLabel(value), selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.rightAttachment = value
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let angleType = draft.textAngleType ?? .insertAngle
            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Text angle", textAngleLabel(angleType), 0) {
                for value in CADLeaderTextAngleType.allCases {
                    let selected = value == angleType
                    if ImGuiSelectable(textAngleLabel(value), selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.textAngleType = value
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            let direction = draft.textAttachmentDirection ?? .horizontal
            ImGuiSetNextItemWidth(190)
            if ImGuiBeginCombo("Attachment direction", direction == .horizontal ? "Horizontal" : "Vertical", 0) {
                for value in CADLeaderTextAttachmentDirection.allCases {
                    let selected = value == direction
                    let label = value == .horizontal ? "Horizontal" : "Vertical"
                    if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                        draft.textAttachmentDirection = value
                    }
                    if selected { ImGuiSetItemDefaultFocus() }
                }
                ImGuiEndCombo()
            }
            var alwaysLeft = draft.alwaysLeftJustify ?? false
            if ImGuiCheckbox("Always left justify", &alwaysLeft) {
                draft.alwaysLeftJustify = alwaysLeft
            }
            _ = ImGuiCheckbox("Text frame", &draft.textFrameEnabled)

            var points = Int32(draft.maxLeaderPoints)
            ImGuiSetNextItemWidth(190)
            if ImGuiDragInt("Maximum points", &points, 0.1, 2, 128, "%d", ImGuiSliderFlags(0)) {
                draft.maxLeaderPoints = max(2, Int(points))
            }
            dragDouble("Block scale", value: &draft.blockScale, speed: 0.05, minimum: 0.0001)
            var rotation = Float(draft.blockRotation * 180 / .pi)
            ImGuiSetNextItemWidth(190)
            if ImGuiDragFloat("Block rotation", &rotation, 0.5, -360, 360, "%.1f°", ImGuiSliderFlags(0)) {
                draft.blockRotation = Double(rotation) * .pi / 180
            }

            if !message.isEmpty {
                igSpacing()
                ImGuiTextWrappedV(message)
            }
        }
        igEndChild()

        if igButton("New", ImVec2(x: 85, y: 0)) {
            let name = uniqueName(document: document)
            var style = CADLeaderStyle.standard
            style.name = name
            if document.applyLeaderStyle(style) {
                select(name, document: document)
                message = "Created \(name)."
            }
        }
        ImGuiSameLine(0, 7)

        let isStandard = selectedName.caseInsensitiveCompare("Standard") == .orderedSame
        if isStandard { ImGuiBeginDisabled(true) }
        if igButton("Delete", ImVec2(x: 85, y: 0)) {
            if document.deleteLeaderStyle(named: selectedName) {
                select("Standard", document: document)
                message = "Style deleted."
            }
        }
        if isStandard { ImGuiEndDisabled() }

        ImGuiSameLine(0, 7)
        if igButton("Set Current", ImVec2(x: 105, y: 0)) {
            document.pushUndo()
            document.currentLeaderStyleName = selectedName
            document.markEdited(regenerate: false)
            message = "Current style set to \(selectedName)."
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
                if document.applyLeaderStyle(draft, replacing: originalName) {
                    select(trimmed, document: document)
                    message = "Style applied."
                } else {
                    message = "A style with that name already exists."
                }
            }
        }

        ImGuiSameLine(0, 7)
        if igButton("Reset", ImVec2(x: 80, y: 0)) {
            select(selectedName, document: document)
        }

        ImGuiSameLine(width - 112, 0)
        if igButton("Close", ImVec2(x: 90, y: 0)) {
            engine.ui.leaderStyleManagerActive = false
        }
        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            engine.ui.leaderStyleManagerActive = false
        }
    }

    private static func select(_ name: String, document: CADDocument) {
        let style = document.leaderStyle(named: name) ?? .standard
        selectedName = style.name
        originalName = style.name
        draft = style
        message = ""
    }

    private static func uniqueName(document: CADDocument) -> String {
        var index = 1
        while document.leaderStyle(named: "LeaderStyle\(index)") != nil { index += 1 }
        return "LeaderStyle\(index)"
    }

    private static func arrowheadLabel(_ value: CADLeaderArrowhead) -> String {
        switch value {
        case .none: return "None"
        case .closedFilled: return "Closed filled"
        case .closedBlank: return "Closed blank"
        case .open: return "Open"
        case .dot: return "Dot"
        case .dotBlank: return "Dot blank"
        case .architecturalTick: return "Architectural tick"
        case .oblique: return "Oblique"
        case .originIndicator: return "Origin indicator"
        case .boxFilled: return "Box filled"
        case .boxBlank: return "Box blank"
        case .custom: return "Custom block"
        }
    }

    private static func textAlignmentLabel(_ value: CADLeaderTextAlignment) -> String {
        switch value {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    private static func textAngleLabel(_ value: CADLeaderTextAngleType) -> String {
        switch value {
        case .insertAngle: return "Insert angle"
        case .horizontal: return "Horizontal"
        case .alwaysRightReading: return "Always right-reading"
        }
    }

    private static func attachmentLabel(_ value: CADLeaderTextAttachment) -> String {
        switch value {
        case .topOfTop: return "Top of top line"
        case .middleOfTop: return "Middle of top line"
        case .middle: return "Middle"
        case .middleOfBottom: return "Middle of bottom line"
        case .bottomOfBottom: return "Bottom of bottom line"
        case .bottomLine: return "Bottom line"
        case .bottomOfTopLine: return "Bottom of top line"
        case .bottomOfTop: return "Bottom of top"
        case .allLine: return "All lines"
        case .center: return "Center"
        case .linedCenter: return "Underline/overline center"
        }
    }

    private static func pathLabel(_ value: CADLeaderPathType) -> String {
        switch value {
        case .straight: return "Straight"
        case .spline: return "Spline"
        case .none: return "None"
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

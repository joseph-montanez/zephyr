import Foundation
import CSDL3
import ImGui

@MainActor
public final class LeaderCreateCommand: FeatureCommand {
    public enum Mode: Sendable {
        case leader
        case qleader
        case mleader
    }

    private enum State {
        case points
        case contentOptions
        case blockName
        case copyContent
        case mtextEditor
        case toleranceDialog
        case done
    }

    private static let contentOptions = [
        FeatureCommandTextOption(
            value: "Mtext",
            title: "Mtext",
            aliases: ["M"],
            description: "Open the multiline text editor"),
        FeatureCommandTextOption(
            value: "Block",
            title: "Block",
            aliases: ["B"],
            description: "Attach a block to the leader"),
        FeatureCommandTextOption(
            value: "None",
            title: "None",
            aliases: ["N"],
            description: "Finish with no annotation content"),
        FeatureCommandTextOption(
            value: "Tolerance",
            title: "Tolerance",
            aliases: ["T"],
            description: "Create a geometric tolerance annotation"),
        FeatureCommandTextOption(
            value: "Copy",
            title: "Copy",
            aliases: ["C"],
            description: "Copy multiline text from an existing annotation")
    ]

    private let mode: Mode
    private var state: State = .points
    private var points: [Vector3] = []
    private var annotationLines: [String] = []
    private var mouse = Vector3.zero
    private var tolerancePopupOpened = false
    private var toleranceSymbol = ""
    private var toleranceValue = ""
    private var toleranceDatum1 = ""
    private var toleranceDatum2 = ""
    private var toleranceDatum3 = ""

    public init(mode: Mode) {
        self.mode = mode
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        annotationLines.removeAll()
        state = .points
        tolerancePopupOpened = false
        processor.commandPrompt = "Specify leader arrowhead location:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        annotationLines.removeAll()
        state = .done
        tolerancePopupOpened = false
        engine.textManager.isEditorActive = false
        engine.textManager.editorResult = .active
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let point = Vector3(x: worldX, y: worldY, z: 0)

        switch state {
        case .points:
            points.append(point)
            if points.count == 1 {
                processor.commandPrompt = "Specify next leader point:"
            } else {
                let style = currentStyle(engine)
                if mode != .leader && points.count >= style.maxLeaderPoints {
                    beginContentOptions(processor: processor, resetLines: true)
                } else {
                    processor.commandPrompt = "Specify next leader point or press Enter for annotation:"
                }
            }
            return .handled

        case .copyContent:
            let threshold = 10.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold
            ), let entity = engine.document.entity(for: handle),
               let copiedText = annotationText(from: entity),
               !copiedText.isEmpty else {
                processor.commandPrompt = "Select multiline text or an MText leader annotation:"
                return .handled
            }
            return create(
                contentType: .mtext,
                text: copiedText,
                blockName: nil,
                engine: engine,
                processor: processor)

        case .contentOptions, .blockName, .mtextEditor, .toleranceDialog, .done:
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        mouse = Vector3(x: worldX, y: worldY, z: 0)
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            switch state {
            case .points:
                guard points.count >= 2 else {
                    processor.commandPrompt = "Specify at least two leader points."
                    return .handled
                }
                beginContentOptions(processor: processor, resetLines: true)
                return .handled

            case .contentOptions:
                return finishAnnotation(engine: engine, processor: processor)

            default:
                return .handled
            }

        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch state {
        case .points:
            guard points.count >= 2 else {
                processor.commandPrompt = "Specify at least two leader points."
                return .handled
            }
            beginContentOptions(processor: processor, resetLines: true)
            if value.isEmpty { return .handled }
            return handleContentInput(value, engine: engine, processor: processor)

        case .contentOptions:
            return handleContentInput(value, engine: engine, processor: processor)

        case .blockName:
            guard !value.isEmpty else {
                openCommandLine(processor: processor, prompt: "Enter block name:")
                return .handled
            }
            guard let block = engine.document.allBlocks.first(where: {
                !$0.isInternalTableDisplayBlock && $0.name.caseInsensitiveCompare(value) == .orderedSame
            }) else {
                openCommandLine(processor: processor, prompt: "Block not found. Enter block name:")
                return .handled
            }
            return create(
                contentType: .block,
                text: "",
                blockName: block.name,
                engine: engine,
                processor: processor)

        case .copyContent:
            processor.commandPrompt = "Select multiline text or an MText leader annotation:"
            return .handled

        case .mtextEditor, .toleranceDialog:
            return .handled

        case .done:
            return .finished
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        switch state {
        case .contentOptions:
            return Self.contentOptions.filter { $0.matches(input) }
        case .blockName:
            return []
        default:
            return []
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard state == .points, !points.isEmpty else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        var preview = points
        preview.append(mouse)
        for index in 0..<(preview.count - 1) {
            let a = EngineCameraManager.worldToScreen(
                worldX: preview[index].x,
                worldY: preview[index].y,
                cam: cam)
            let b = EngineCameraManager.worldToScreen(
                worldX: preview[index + 1].x,
                worldY: preview[index + 1].y,
                cam: cam)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: a.x, y: a.y),
                ImVec2(x: b.x, y: b.y),
                color,
                1.5)
        }
    }

    public func renderImGui(engine: PhrostEngine) {
        switch state {
        case .mtextEditor:
            finishMTextEditorIfNeeded(engine: engine, processor: engine.commandProcessor)
        case .toleranceDialog:
            renderToleranceDialog(engine: engine, processor: engine.commandProcessor)
        default:
            break
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        state == .points ? points : []
    }

    private func handleContentInput(
        _ value: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch value.lowercased() {
        case "":
            return finishAnnotation(engine: engine, processor: processor)

        case "m", "mtext":
            beginMTextEditor(
                prefill: annotationLines.joined(separator: "\n"),
                engine: engine,
                processor: processor)
            return .handled

        case "b", "block":
            state = .blockName
            openCommandLine(processor: processor, prompt: "Enter block name:")
            return .handled

        case "n", "none":
            return create(
                contentType: .none,
                text: "",
                blockName: nil,
                engine: engine,
                processor: processor)

        case "t", "tolerance":
            beginToleranceDialog(processor: processor)
            return .handled

        case "c", "copy":
            state = .copyContent
            processor.commandLineActive = false
            processor.commandBuffer = ""
            processor.commandPrompt = "Select multiline text or an MText leader annotation:"
            return .handled

        default:
            annotationLines.append(value)
            openAnnotationPrompt(processor: processor)
            return .handled
        }
    }

    private func finishAnnotation(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let text = annotationLines.joined(separator: "\n")
        return create(
            contentType: text.isEmpty ? .none : .mtext,
            text: text,
            blockName: nil,
            engine: engine,
            processor: processor)
    }

    private func beginContentOptions(
        processor: CADCommandProcessor,
        resetLines: Bool
    ) {
        if resetLines { annotationLines.removeAll() }
        state = .contentOptions
        openAnnotationPrompt(processor: processor)
    }

    private func openAnnotationPrompt(processor: CADCommandProcessor) {
        let prompt = annotationLines.isEmpty
            ? "Enter first annotation line or [Mtext/Block/None/Tolerance/Copy] <finish>:"
            : "Enter next annotation line or [Mtext/Block/None/Tolerance/Copy] <finish>:"
        openCommandLine(processor: processor, prompt: prompt)
    }

    private func openCommandLine(processor: CADCommandProcessor, prompt: String) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }

    private func beginMTextEditor(
        prefill: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        let leaderStyle = currentStyle(engine)
        let textStyle = engine.document.textStyle(named: leaderStyle.textStyleName) ?? .standard
        engine.textManager.editorState = TextEditorState(
            text: prefill,
            styleName: textStyle.name,
            fontName: textStyle.fontFile,
            height: leaderStyle.textHeight,
            rotation: 0,
            alignH: 0,
            alignV: 2,
            mtextWidth: max(leaderStyle.textHeight * 20.0, 1.0))
        engine.textManager.editorResult = .active
        engine.textManager.isEditorActive = true
        state = .mtextEditor
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandPrompt = "Enter leader annotation in the text editor."
    }

    private func finishMTextEditorIfNeeded(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        guard !engine.textManager.isEditorActive else { return }

        let result = engine.textManager.editorResult
        engine.textManager.editorResult = .active

        switch result {
        case .active:
            return

        case .cancelled:
            state = .contentOptions
            openAnnotationPrompt(processor: processor)

        case .confirmed(let editorState):
            let text = editorState.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                state = .contentOptions
                openAnnotationPrompt(processor: processor)
                return
            }

            var styleOverride = currentStyle(engine)
            styleOverride.textStyleName = engine.document.resolvedTextStyleName(editorState.styleName)
            styleOverride.textHeight = max(editorState.height, 0.0001)

            let result = create(
                contentType: .mtext,
                text: text,
                blockName: nil,
                textWidth: editorState.mtextWidth > 0 ? editorState.mtextWidth : nil,
                contentRotation: editorState.rotation,
                styleOverride: styleOverride,
                engine: engine,
                processor: processor)
            if result == .finished {
                processor.finishFeatureCommand(engine: engine)
            }
        }
    }

    private func beginToleranceDialog(processor: CADCommandProcessor) {
        state = .toleranceDialog
        tolerancePopupOpened = false
        toleranceSymbol = ""
        toleranceValue = ""
        toleranceDatum1 = ""
        toleranceDatum2 = ""
        toleranceDatum3 = ""
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandPrompt = "Complete the geometric tolerance dialog."
    }

    private func renderToleranceDialog(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        let popupID = "Geometric Tolerance##LeaderTolerance"
        if !tolerancePopupOpened {
            ImGuiOpenPopup(popupID, Int32(ImGuiPopupFlags_None.rawValue))
            tolerancePopupOpened = true
        }

        ImGuiSetNextWindowSize(ImVec2(x: 520, y: 0), Int32(ImGuiCond_Appearing.rawValue))
        var open = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_AlwaysAutoResize.rawValue)
        guard ImGuiBeginPopupModal(popupID, &open, flags) else { return }
        defer { ImGuiEndPopup() }

        if !open {
            state = .contentOptions
            openAnnotationPrompt(processor: processor)
            return
        }

        ImGuiTextV("Feature control frame")
        ImGuiSeparator()
        ImGuiPushItemWidth(-1)
        inputText("Geometric symbol", value: &toleranceSymbol)
        inputText("Tolerance", value: &toleranceValue)
        inputText("Primary datum", value: &toleranceDatum1)
        inputText("Secondary datum", value: &toleranceDatum2)
        inputText("Tertiary datum", value: &toleranceDatum3)
        ImGuiPopItemWidth()
        ImGuiSpacing()
        ImGuiSeparator()
        ImGuiSpacing()

        if ImGuiButton("OK", ImVec2(x: 120, y: 0)) {
            let text = toleranceText()
            guard !text.isEmpty else {
                processor.commandPrompt = "Enter a tolerance value or datum."
                return
            }
            ImGuiCloseCurrentPopup()
            let result = create(
                contentType: .mtext,
                text: text,
                blockName: nil,
                engine: engine,
                processor: processor)
            if result == .finished {
                processor.finishFeatureCommand(engine: engine)
            }
        }

        ImGuiSameLine(0, 8)
        if ImGuiButton("Back", ImVec2(x: 120, y: 0)) {
            ImGuiCloseCurrentPopup()
            state = .contentOptions
            openAnnotationPrompt(processor: processor)
        }
    }

    private func inputText(_ label: String, value: inout String) {
        let capacity = 256
        var buffer = [CChar](repeating: 0, count: capacity)
        let bytes = value.utf8CString
        let count = min(bytes.count, capacity - 1)
        for index in 0..<count {
            buffer[index] = bytes[index]
        }
        if igInputText(label, &buffer, capacity, 0, nil, nil) {
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            value = String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private func toleranceText() -> String {
        [toleranceSymbol, toleranceValue, toleranceDatum1, toleranceDatum2, toleranceDatum3]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private func annotationText(from entity: CADEntity) -> String? {
        if let data = entity.leaderData?.value,
           data.contentType == .mtext,
           !data.text.isEmpty {
            return data.text
        }
        if case .string(let text) = entity.xdata["dxf.text"], !text.isEmpty {
            return text
        }
        for primitive in entity.localGeometry ?? [] {
            if case .text(_, let text, _, _, _, _, _, _, _) = primitive,
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func currentStyle(_ engine: PhrostEngine) -> CADLeaderStyle {
        engine.document.leaderStyle(named: engine.document.currentLeaderStyleName) ?? .standard
    }

    private func create(
        contentType: CADLeaderContentType,
        text: String,
        blockName: String?,
        textWidth: Double? = nil,
        contentRotation: Double = 0,
        styleOverride: CADLeaderStyle? = nil,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard let layerID = engine.document.activeLayerID ?? engine.document.allLayers.first?.handle,
              points.count >= 2 else {
            processor.commandPrompt = "Unable to create leader."
            return .finished
        }
        let style = styleOverride ?? currentStyle(engine)
        let last = points[points.count - 1]
        let previous = points[points.count - 2]
        let direction = Vector3(x: last.x >= previous.x ? 1 : -1, y: 0, z: 0)
        let contentPosition = last + direction * (style.doglegLength + style.contentGap)
        let data = CADLeaderData(
            styleName: style.name,
            branches: [CADLeaderBranch(vertices: points, doglegDirection: direction)],
            contentType: contentType,
            text: text,
            blockName: blockName,
            contentPosition: contentPosition,
            contentRotation: contentRotation,
            textWidth: textWidth,
            isLegacyLeader: mode != .mleader,
            styleOverrides: styleOverride)
        let geometry = CADLeaderGeometry.build(
            data: data,
            style: style,
            blockResolver: { name in
                engine.document.allBlocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            })
        let entity = CADEntity(
            layerID: layerID,
            localGeometry: geometry,
            leaderData: CADLeaderDataBox(data))
        engine.document.addEntity(entity)
        engine.cadSelection.select(entity.handle)
        state = .done
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandPrompt = mode == .mleader ? "Multileader created." : "Leader created."
        return .finished
    }
}


@MainActor
public final class MLeaderEditCommand: FeatureCommand {
    private enum State {
        case select
        case option
        case addBranch
        case removeBranch
        case moveContent
        case editContent
        case done
    }

    private var state: State = .select
    private var target: UUID?

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if let handle = engine.cadSelection.lastSelectedHandle,
           engine.document.entity(for: handle)?.leaderData != nil {
            target = handle
            state = .option
            processor.commandPrompt = "Enter multileader edit option [Add/Remove/Content/Move]:"
        } else {
            state = .select
            processor.commandPrompt = "Select multileader:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .done
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let point = Vector3(x: worldX, y: worldY, z: 0)
        switch state {
        case .select:
            let threshold = 10.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold),
                  engine.document.entity(for: handle)?.leaderData != nil else {
                processor.commandPrompt = "Select a leader or multileader:"
                return .handled
            }
            target = handle
            engine.cadSelection.select(handle)
            state = .option
            processor.commandPrompt = "Enter multileader edit option [Add/Remove/Content/Move]:"
            return .handled

        case .addBranch:
            return update(engine: engine, processor: processor) { data, style in
                let endpoint = data.branches.first?.vertices.last
                    ?? data.contentPosition - Vector3(x: style.doglegLength, y: 0, z: 0)
                data.branches.append(CADLeaderBranch(vertices: [point, endpoint]))
            }

        case .removeBranch:
            return update(engine: engine, processor: processor) { data, _ in
                guard data.branches.count > 1 else { return }
                let nearest = data.branches.enumerated().min { lhs, rhs in
                    let lp = lhs.element.vertices.first ?? .zero
                    let rp = rhs.element.vertices.first ?? .zero
                    return lp.distance(to: point) < rp.distance(to: point)
                }?.offset ?? 0
                data.branches.remove(at: nearest)
            }

        case .moveContent:
            return update(engine: engine, processor: processor) { data, _ in
                let delta = point - data.contentPosition
                data.contentPosition = point
                if let base = data.contentBasePosition {
                    data.contentBasePosition = base + delta
                }
            }

        case .option, .editContent, .done:
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .option:
            switch value.lowercased() {
            case "a", "add":
                state = .addBranch
                processor.commandPrompt = "Specify new leader arrowhead location:"
            case "r", "remove":
                state = .removeBranch
                processor.commandPrompt = "Select leader branch to remove:"
            case "c", "content":
                state = .editContent
                processor.commandPrompt = "Enter replacement annotation text:"
            case "m", "move":
                state = .moveContent
                processor.commandPrompt = "Specify new content location:"
            default:
                processor.commandPrompt = "Enter multileader edit option [Add/Remove/Content/Move]:"
            }
            return .handled

        case .editContent:
            return update(engine: engine, processor: processor) { data, _ in
                data.contentType = .mtext
                data.text = value
                data.sourceText = nil
                data.blockName = nil
                data.collectedBlockNames = []
            }

        default:
            return .handled
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func update(
        engine: PhrostEngine,
        processor: CADCommandProcessor,
        mutation: (inout CADLeaderData, CADLeaderStyle) -> Void
    ) -> CommandResult {
        guard let target,
              var entity = engine.document.entity(for: target),
              var data = entity.leaderData?.value else { return .finished }
        let style = data.styleOverrides ?? engine.document.leaderStyle(named: data.styleName) ?? .standard
        let before = engine.document.snapshot()
        mutation(&data, style)
        entity.leaderData = CADLeaderDataBox(data)
        entity = engine.document.regeneratedLeaderEntity(entity)
        engine.document.pushUndo(before)
        engine.document.updateEntityLive(entity)
        state = .done
        processor.commandPrompt = "Multileader updated."
        return .finished
    }
}

@MainActor
public final class MLeaderAlignCommand: FeatureCommand {
    private var handles: [UUID] = []
    private var firstPoint: Vector3?
    private var mouse = Vector3.zero

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        handles = engine.cadSelection.selectedHandles.filter {
            engine.document.entity(for: $0)?.leaderData != nil
        }
        guard handles.count >= 2 else {
            processor.commandPrompt = "Select at least two multileaders before MLEADERALIGN."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        processor.commandPrompt = "Specify first alignment point:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        firstPoint = nil
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard handles.count >= 2 else { return .finished }
        let point = Vector3(x: worldX, y: worldY, z: 0)
        if firstPoint == nil {
            firstPoint = point
            processor.commandPrompt = "Specify second alignment point:"
            return .handled
        }
        let before = engine.document.snapshot()
        let start = firstPoint!
        let delta = point - start
        let axis = delta.magnitudeSquared > 1e-18 ? delta.normalized : Vector3(x: 1, y: 0, z: 0)
        let orderedHandles = handles.sorted { lhs, rhs in
            let left = engine.document.entity(for: lhs)?.leaderData?.value.contentPosition ?? .zero
            let right = engine.document.entity(for: rhs)?.leaderData?.value.contentPosition ?? .zero
            return left.dot(axis) < right.dot(axis)
        }
        for (index, handle) in orderedHandles.enumerated() {
            guard var entity = engine.document.entity(for: handle), var data = entity.leaderData?.value else { continue }
            let t = Double(index) / Double(max(orderedHandles.count - 1, 1))
            let newPosition = start + delta * t
            let contentDelta = newPosition - data.contentPosition
            data.contentPosition = newPosition
            if let base = data.contentBasePosition {
                data.contentBasePosition = base + contentDelta
            }
            entity.leaderData = CADLeaderDataBox(data)
            engine.document.updateEntityLive(engine.document.regeneratedLeaderEntity(entity))
        }
        engine.document.pushUndo(before)
        processor.commandPrompt = "Multileaders aligned."
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) { mouse = Vector3(x: worldX, y: worldY, z: 0) }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard let firstPoint else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let a = EngineCameraManager.worldToScreen(worldX: firstPoint.x, worldY: firstPoint.y, cam: cam)
        let b = EngineCameraManager.worldToScreen(worldX: mouse.x, worldY: mouse.y, cam: cam)
        ImDrawListAddLine(drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y),
                          igGetColorU32_Vec4(engine.ui.theme.brandGold), 1.5)
    }
}

@MainActor
public final class MLeaderCollectCommand: FeatureCommand {
    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let leaders = engine.cadSelection.selectedHandles.compactMap { handle -> CADEntity? in
            guard let entity = engine.document.entity(for: handle),
                  entity.leaderData?.value.contentType == .block else { return nil }
            return entity
        }
        guard leaders.count >= 2, var primary = leaders.first, var data = primary.leaderData?.value else {
            processor.commandPrompt = "Select at least two block-content multileaders."
            processor.finishFeatureCommand(engine: engine)
            return
        }

        var names: [String] = []
        for entity in leaders {
            guard let leader = entity.leaderData?.value else { continue }
            data.branches.append(contentsOf: entity.handle == primary.handle ? [] : leader.branches)
            if !leader.collectedBlockNames.isEmpty {
                names.append(contentsOf: leader.collectedBlockNames)
            } else if let name = leader.blockName {
                names.append(name)
            }
        }
        data.collectedBlockNames = names
        data.blockName = names.first
        primary.leaderData = CADLeaderDataBox(data)
        primary = engine.document.regeneratedLeaderEntity(primary)
        let remove = Set(leaders.dropFirst().map(\.handle))
        engine.document.replaceEntities(remove: remove.union([primary.handle]), add: [primary])
        engine.cadSelection.select(primary.handle)
        processor.commandPrompt = "Block multileaders collected."
        processor.finishFeatureCommand(engine: engine)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .finished }
    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .finished }
    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
}

@MainActor
public final class MLeaderStyleCommand: FeatureCommand {
    private weak var processor: CADCommandProcessor?

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        self.processor = processor
        engine.ui.leaderStyleManagerActive = true
        processor.commandPrompt = "Manage multileader styles."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.leaderStyleManagerActive = false
        self.processor = nil
    }

    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .handled }
    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            engine.ui.leaderStyleManagerActive = false
            return .finished
        }
        return .handled
    }
    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public func renderImGui(engine: PhrostEngine) {
        guard !engine.ui.leaderStyleManagerActive, let processor else { return }
        processor.finishFeatureCommand(engine: engine)
        self.processor = nil
    }
    public var isSnappingEnabled: Bool { false }
}

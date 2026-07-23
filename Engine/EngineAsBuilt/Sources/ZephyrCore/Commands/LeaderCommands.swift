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
        case blockName
        case done
    }

    private let mode: Mode
    private var state: State = .points
    private var points: [Vector3] = []
    private var mouse = Vector3.zero

    public init(mode: Mode) {
        self.mode = mode
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        state = .points
        processor.commandPrompt = "Specify leader arrowhead location:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        points.removeAll()
        state = .done
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard state == .points else { return .handled }
        points.append(Vector3(x: worldX, y: worldY, z: 0))
        if points.count == 1 {
            processor.commandPrompt = "Specify leader landing location:"
        } else {
            let style = currentStyle(engine)
            if points.count >= style.maxLeaderPoints {
                processor.commandPrompt = "Enter annotation text or [Block/None]:"
            } else {
                processor.commandPrompt = "Specify next point or enter annotation text [Block/None]:"
            }
        }
        return .handled
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
        if (scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER), points.count >= 2 {
            processor.commandPrompt = "Enter annotation text or [Block/None]:"
            return .handled
        }
        return .continue
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
            if value.caseInsensitiveCompare("BLOCK") == .orderedSame || value.caseInsensitiveCompare("B") == .orderedSame {
                state = .blockName
                processor.commandPrompt = "Enter block name:"
                return .handled
            }
            if value.caseInsensitiveCompare("NONE") == .orderedSame || value.caseInsensitiveCompare("N") == .orderedSame {
                return create(contentType: .none, text: "", blockName: nil, engine: engine, processor: processor)
            }
            return create(contentType: .mtext, text: value, blockName: nil, engine: engine, processor: processor)

        case .blockName:
            guard let block = engine.document.allBlocks.first(where: {
                !$0.isInternalTableDisplayBlock && $0.name.caseInsensitiveCompare(value) == .orderedSame
            }) else {
                processor.commandPrompt = "Block not found. Enter block name:"
                return .handled
            }
            return create(contentType: .block, text: "", blockName: block.name, engine: engine, processor: processor)

        case .done:
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard state == .points, !points.isEmpty else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = igGetColorU32_Vec4(engine.ui.theme.brandGold)
        var preview = points
        preview.append(mouse)
        for index in 0..<(preview.count - 1) {
            let a = EngineCameraManager.worldToScreen(worldX: preview[index].x, worldY: preview[index].y, cam: cam)
            let b = EngineCameraManager.worldToScreen(worldX: preview[index + 1].x, worldY: preview[index + 1].y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), color, 1.5)
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] { points }

    private func currentStyle(_ engine: PhrostEngine) -> CADLeaderStyle {
        engine.document.leaderStyle(named: engine.document.currentLeaderStyleName) ?? .standard
    }

    private func create(
        contentType: CADLeaderContentType,
        text: String,
        blockName: String?,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard let layerID = engine.document.activeLayerID ?? engine.document.allLayers.first?.handle,
              points.count >= 2 else {
            processor.commandPrompt = "Unable to create leader."
            return .finished
        }
        let style = currentStyle(engine)
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
            isLegacyLeader: mode != .mleader)
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
                data.contentPosition = point
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
            data.contentPosition = start + delta * t
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

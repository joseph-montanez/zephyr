import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - OffsetCommand
// =========================================================================
//
// OFFSET (alias O) — AutoCAD-style parallel copy.
//
// Flow: specify a distance (typed, or by picking two points), pick an
// object, then pick a point on the side to offset. Options mirror
// AutoCAD: Through, Erase, Layer at the distance prompt; Exit, Multiple,
// Undo at the side prompt. The command loops back to object selection
// after each offset until Enter/Esc. Polyline outside corners follow
// the OFFSETGAPTYPE system variable (see OffsetGapTypeCommand below).
//
// Geometry lives in OffsetGeometryEngine; this class is the interactive
// shell (prompts, picking, preview, undo bookkeeping).

@MainActor
public final class OffsetCommand: FeatureCommand {

    public enum LayerOption: Sendable {
        case source
        case current
    }

    /// Session-level option defaults (AutoCAD remembers these per session).
    public static var eraseSource: Bool = false
    public static var layerOption: LayerOption = .source

    private struct PickedSource {
        let handle: UUID
        var entity: CADEntity
        /// True after this command erased the source from the document
        /// (Multiple mode keeps offsetting the snapshot).
        var erasedByUs: Bool = false
    }

    private enum Step {
        case distance
        case distanceSecondPoint(Vector3)
        case erasePrompt
        case layerPrompt
        case selectObject(through: Bool)
        case specifySide(PickedSource)
        case specifyThroughPoint(PickedSource)
    }

    private var step: Step = .distance
    private var offsetDistance: Double = 0
    private var multiple: Bool = false
    private var operationsInSession: Int = 0
    private var currentMouse: Vector3 = .zero
    private var previewPoints: [Vector3] = []
    private var previewClosed: Bool = false
    private var didSelectSource: Bool = false

    public init() {}

    // MARK: - FeatureCommand

    public var isSnappingEnabled: Bool {
        switch step {
        case .selectObject: return false
        default: return true
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        if case .distanceSecondPoint(let first) = step { return [first] }
        return []
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        step = .distance
        multiple = false
        operationsInSession = 0
        previewPoints = []
        didSelectSource = false
        openInput(processor, prompt: distancePrompt)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        if didSelectSource {
            engine.cadSelection.clearSelection()
            didSelectSource = false
        }
        step = .distance
        previewPoints = []
        processor.commandPrompt = nil
    }

    // MARK: - Prompts

    private var distancePrompt: String {
        if let last = OffsetSettings.lastDistance {
            return "Specify offset distance or [Through/Erase/Layer] <\(format(last))>:"
        }
        return "Specify offset distance or [Through/Erase/Layer] <Through>:"
    }

    private var selectObjectPrompt: String {
        "Select object to offset or [Exit/Undo] <Exit>:"
    }

    private func sidePrompt(through: Bool) -> String {
        if multiple {
            return through
                ? "Specify through point or [Exit/Undo] <next object>:"
                : "Specify point on side to offset or [Exit/Undo] <next object>:"
        }
        return through
            ? "Specify through point or [Exit/Multiple/Undo] <Exit>:"
            : "Specify point on side to offset or [Exit/Multiple/Undo] <Exit>:"
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func openInput(_ processor: CADCommandProcessor, prompt: String) {
        processor.commandPrompt = prompt
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    // MARK: - Mouse input

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let snapped = Vector3(x: worldX, y: worldY, z: 0)

        switch step {
        case .distance:
            // First of two points that define the distance graphically.
            processor.commandLineActive = false
            processor.commandBuffer = ""
            step = .distanceSecondPoint(snapped)
            processor.commandPrompt = "Specify second point:"
            return .handled

        case .distanceSecondPoint(let first):
            let distance = first.distance(to: snapped)
            guard distance > 1e-9 else {
                processor.commandPrompt = "Points are coincident. Specify second point:"
                return .handled
            }
            acceptDistance(distance, processor: processor)
            return .handled

        case .erasePrompt, .layerPrompt:
            return .handled

        case .selectObject(let through):
            let raw = rawWorldPoint(engine: engine)
            guard let handle = CADHitTesting.hitTest(
                worldX: raw.x, worldY: raw.y,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom,
                simplifyComplexBlocks: false),
                  let entity = engine.document.entity(for: handle)
            else {
                processor.commandPrompt = selectObjectPrompt
                return .handled
            }
            guard OffsetGeometryEngine.isOffsettable(entity: entity) else {
                processor.commandPrompt = "Cannot offset that object. \(selectObjectPrompt)"
                return .handled
            }
            multiple = false
            previewPoints = []
            engine.cadSelection.select(handle)
            didSelectSource = true
            let source = PickedSource(handle: handle, entity: entity)
            step = through ? .specifyThroughPoint(source) : .specifySide(source)
            processor.commandPrompt = sidePrompt(through: through)
            return .handled

        case .specifySide(let source):
            performOffset(
                source: source,
                mode: .distance(offsetDistance, sidePoint: snapped),
                through: false, engine: engine, processor: processor)
            return .handled

        case .specifyThroughPoint(let source):
            performOffset(
                source: source, mode: .through(snapped),
                through: true, engine: engine, processor: processor)
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouse = Vector3(x: worldX, y: worldY, z: 0)
        updatePreview(engine: engine)
    }

    private func rawWorldPoint(engine: PhrostEngine) -> Vector3 {
        let (x, y) = engine.camera.screenToWorld(
            screenX: Float(engine.interaction.lastMouseX),
            screenY: Float(engine.interaction.lastMouseY),
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        return Vector3(x: x, y: y, z: 0)
    }

    // MARK: - Keyboard / command-line text

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE { return .finished }
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            return acceptDefault(engine: engine, processor: processor)
        }
        guard !processor.commandLineActive else { return .continue }

        switch (step, scancode) {
        case (.distance, SDL_SCANCODE_T):
            return chooseThrough(processor: processor)
        case (.distance, SDL_SCANCODE_E):
            step = .erasePrompt
            openInput(processor, prompt: erasePromptText)
            return .handled
        case (.distance, SDL_SCANCODE_L):
            step = .layerPrompt
            openInput(processor, prompt: layerPromptText)
            return .handled
        case (.specifySide, SDL_SCANCODE_M), (.specifyThroughPoint, SDL_SCANCODE_M):
            multiple = true
            processor.commandPrompt = sidePrompt(through: isThroughStep)
            return .handled
        case (.selectObject, SDL_SCANCODE_U),
             (.specifySide, SDL_SCANCODE_U),
             (.specifyThroughPoint, SDL_SCANCODE_U):
            undoInSession(engine: engine, processor: processor)
            return .handled
        case (.selectObject, SDL_SCANCODE_E),
             (.specifySide, SDL_SCANCODE_E),
             (.specifyThroughPoint, SDL_SCANCODE_E):
            return .finished
        default:
            return .continue
        }
    }

    private var isThroughStep: Bool {
        switch step {
        case .specifyThroughPoint: return true
        case .selectObject(let through): return through
        default: return false
        }
    }

    private var erasePromptText: String {
        "Erase source object after offsetting? [Yes/No] <\(Self.eraseSource ? "Yes" : "No")>:"
    }

    private var layerPromptText: String {
        "Enter layer option for offset objects [Current/Source] <\(Self.layerOption == .current ? "Current" : "Source")>:"
    }

    /// Enter with empty input: accept the prompt default.
    private func acceptDefault(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .distance:
            if let last = OffsetSettings.lastDistance {
                acceptDistance(last, processor: processor)
            } else {
                _ = chooseThrough(processor: processor)
            }
            return .handled
        case .distanceSecondPoint:
            step = .distance
            openInput(processor, prompt: distancePrompt)
            return .handled
        case .erasePrompt, .layerPrompt:
            step = .distance
            openInput(processor, prompt: distancePrompt)
            return .handled
        case .selectObject:
            return .finished
        case .specifySide, .specifyThroughPoint:
            if multiple {
                leaveSource()
                step = .selectObject(through: isThroughStep)
                processor.commandPrompt = selectObjectPrompt
                return .handled
            }
            return .finished
        }
    }

    private func acceptDistance(_ distance: Double, processor: CADCommandProcessor) {
        offsetDistance = distance
        OffsetSettings.lastDistance = distance
        processor.commandLineActive = false
        step = .selectObject(through: false)
        processor.commandPrompt = selectObjectPrompt
    }

    private func chooseThrough(processor: CADCommandProcessor) -> CommandResult {
        // AutoCAD: choosing Through makes it the next default (OFFSETDIST=-1).
        OffsetSettings.lastDistance = nil
        processor.commandLineActive = false
        step = .selectObject(through: true)
        processor.commandPrompt = selectObjectPrompt
        return .handled
    }

    private func leaveSource() {
        multiple = false
        previewPoints = []
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()
        if value.isEmpty { return acceptDefault(engine: engine, processor: processor) }

        switch step {
        case .distance:
            switch upper {
            case "T", "THROUGH":
                return chooseThrough(processor: processor)
            case "E", "ERASE":
                step = .erasePrompt
                openInput(processor, prompt: erasePromptText)
                return .handled
            case "L", "LAYER":
                step = .layerPrompt
                openInput(processor, prompt: layerPromptText)
                return .handled
            default:
                guard let distance = Double(value), distance.isFinite, distance > 0 else {
                    openInput(processor, prompt: "Offset distance must be positive. \(distancePrompt)")
                    return .handled
                }
                acceptDistance(distance, processor: processor)
                return .handled
            }

        case .distanceSecondPoint:
            processor.commandPrompt = "Specify second point:"
            return .handled

        case .erasePrompt:
            switch upper {
            case "Y", "YES": Self.eraseSource = true
            case "N", "NO": Self.eraseSource = false
            default:
                openInput(processor, prompt: erasePromptText)
                return .handled
            }
            step = .distance
            openInput(processor, prompt: distancePrompt)
            return .handled

        case .layerPrompt:
            switch upper {
            case "C", "CURRENT": Self.layerOption = .current
            case "S", "SOURCE": Self.layerOption = .source
            default:
                openInput(processor, prompt: layerPromptText)
                return .handled
            }
            step = .distance
            openInput(processor, prompt: distancePrompt)
            return .handled

        case .selectObject:
            switch upper {
            case "E", "EXIT":
                return .finished
            case "U", "UNDO":
                undoInSession(engine: engine, processor: processor)
                return .handled
            default:
                processor.commandPrompt = selectObjectPrompt
                return .handled
            }

        case .specifySide, .specifyThroughPoint:
            switch upper {
            case "E", "EXIT":
                return .finished
            case "M", "MULTIPLE":
                multiple = true
                processor.commandPrompt = sidePrompt(through: isThroughStep)
                return .handled
            case "U", "UNDO":
                undoInSession(engine: engine, processor: processor)
                return .handled
            default:
                processor.commandPrompt = sidePrompt(through: isThroughStep)
                return .handled
            }
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        let options: [FeatureCommandTextOption]
        switch step {
        case .distance:
            options = [
                .init(value: "T", title: "Through", aliases: ["THROUGH"],
                      description: "Offset through a picked point"),
                .init(value: "E", title: "Erase", aliases: ["ERASE"],
                      description: "Erase source object after offsetting"),
                .init(value: "L", title: "Layer", aliases: ["LAYER"],
                      description: "Current or source layer for offset objects"),
            ]
        case .erasePrompt:
            options = [
                .init(value: "Y", title: "Yes", aliases: ["YES"]),
                .init(value: "N", title: "No", aliases: ["NO"]),
            ]
        case .layerPrompt:
            options = [
                .init(value: "C", title: "Current", aliases: ["CURRENT"]),
                .init(value: "S", title: "Source", aliases: ["SOURCE"]),
            ]
        case .selectObject:
            options = [
                .init(value: "E", title: "Exit", aliases: ["EXIT"]),
                .init(value: "U", title: "Undo", aliases: ["UNDO"],
                      description: "Revert the last offset in this session"),
            ]
        case .specifySide, .specifyThroughPoint:
            options = [
                .init(value: "E", title: "Exit", aliases: ["EXIT"]),
                .init(value: "M", title: "Multiple", aliases: ["MULTIPLE"],
                      description: "Offset the same object repeatedly"),
                .init(value: "U", title: "Undo", aliases: ["UNDO"],
                      description: "Revert the last offset in this session"),
            ]
        case .distanceSecondPoint:
            options = []
        }
        return options.filter { $0.matches(input) }
    }

    // MARK: - Execution

    private func performOffset(
        source: PickedSource, mode: OffsetMode, through: Bool,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let document = engine.document
        var source = source

        if let live = document.entity(for: source.handle) {
            source.entity = live
            source.erasedByUs = false
        } else if !source.erasedByUs {
            leaveSource()
            step = .selectObject(through: through)
            processor.commandPrompt = "Source object no longer exists. \(selectObjectPrompt)"
            return
        }

        guard let primitive = OffsetGeometryEngine.offset(
            entity: source.entity, mode: mode, gapType: OffsetSettings.gapType)
        else {
            writeBack(source, through: through)
            processor.commandPrompt = "Cannot offset that object. \(sidePrompt(through: through))"
            return
        }

        let layerID: UUID
        let outPrimitive: CADPrimitive
        switch Self.layerOption {
        case .source:
            layerID = source.entity.layerID
            outPrimitive = primitive
        case .current:
            layerID = document.activeLayerID
                ?? document.layersView.first?.handle
                ?? source.entity.layerID
            outPrimitive = Self.strippingColor(primitive)
        }

        let newEntity = CADEntity(
            layerID: layerID,
            localGeometry: [outPrimitive],
            xdata: source.entity.xdata,
            drawOrder: source.entity.drawOrder)

        if Self.eraseSource, !source.erasedByUs,
           document.entity(for: source.handle) != nil {
            document.replaceEntities(remove: [source.handle], add: [newEntity])
            source.erasedByUs = true
        } else {
            document.addEntities([newEntity])
        }
        operationsInSession += 1
        engine.tabManager.markActiveDirty()
        previewPoints = []

        if multiple {
            writeBack(source, through: through)
            processor.commandPrompt = sidePrompt(through: through)
        } else {
            step = .selectObject(through: through)
            processor.commandPrompt = selectObjectPrompt
        }
    }

    private func writeBack(_ source: PickedSource, through: Bool) {
        step = through ? .specifyThroughPoint(source) : .specifySide(source)
    }

    private func undoInSession(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard operationsInSession > 0 else {
            processor.commandPrompt = "Nothing to undo in this OFFSET session."
            return
        }
        engine.document.undo()
        operationsInSession -= 1
        engine.tabManager.markActiveDirty()
        previewPoints = []

        // Reconcile the picked source with post-undo document state.
        switch step {
        case .specifySide(var source), .specifyThroughPoint(var source):
            let through = isThroughStep
            if let live = engine.document.entity(for: source.handle) {
                source.entity = live
                source.erasedByUs = false
                writeBack(source, through: through)
            } else if !source.erasedByUs {
                leaveSource()
                step = .selectObject(through: through)
            }
            processor.commandPrompt = stepPrompt
        default:
            processor.commandPrompt = stepPrompt
        }
    }

    private var stepPrompt: String {
        switch step {
        case .distance: return distancePrompt
        case .distanceSecondPoint: return "Specify second point:"
        case .erasePrompt: return erasePromptText
        case .layerPrompt: return layerPromptText
        case .selectObject: return selectObjectPrompt
        case .specifySide: return sidePrompt(through: false)
        case .specifyThroughPoint: return sidePrompt(through: true)
        }
    }

    /// Current-layer option: BYLAYER color (nil) like AutoCAD's CECOLOR default.
    private static func strippingColor(_ primitive: CADPrimitive) -> CADPrimitive {
        switch primitive {
        case .line(let s, let e, _): return .line(start: s, end: e, color: nil)
        case .ray(let s, let d, _): return .ray(start: s, direction: d, color: nil)
        case .xline(let p, let d, _): return .xline(point: p, direction: d, color: nil)
        case .circle(let c, let r, _): return .circle(center: c, radius: r, color: nil)
        case .arc(let c, let r, let sa, let ea, _):
            return .arc(center: c, radius: r, startAngle: sa, endAngle: ea, color: nil)
        case .ellipse(let c, let m, let mr, _):
            return .ellipse(center: c, majorAxis: m, minorRatio: mr, color: nil)
        case .spline(let cps, let knots, let degree, let weights, _):
            return .spline(controlPoints: cps, knots: knots, degree: degree,
                           weights: weights, color: nil)
        case .polyline(let path, _): return .polyline(path: path, color: nil)
        case .polygon(let points, _): return .polygon(points: points, color: nil)
        default: return primitive
        }
    }

    // MARK: - Preview

    private func updatePreview(engine: PhrostEngine) {
        let mode: OffsetMode
        let entity: CADEntity
        switch step {
        case .specifySide(let source):
            entity = engine.document.entity(for: source.handle) ?? source.entity
            mode = .distance(offsetDistance, sidePoint: currentMouse)
        case .specifyThroughPoint(let source):
            entity = engine.document.entity(for: source.handle) ?? source.entity
            mode = .through(currentMouse)
        default:
            previewPoints = []
            return
        }
        guard let primitive = OffsetGeometryEngine.offset(
            entity: entity, mode: mode, gapType: OffsetSettings.gapType)
        else {
            previewPoints = []
            return
        }
        let tessellated = Self.tessellate(primitive)
        previewPoints = tessellated.points
        previewClosed = tessellated.closed
    }

    private static func tessellate(
        _ primitive: CADPrimitive
    ) -> (points: [Vector3], closed: Bool) {
        switch primitive {
        case .line(let start, let end, _):
            return ([start, end], false)
        case .ray(let start, let direction, _):
            let length = direction.magnitude
            guard length > 1e-12 else { return ([start], false) }
            return ([start, start + direction / length * 25000.0], false)
        case .xline(let point, let direction, _):
            let length = direction.magnitude
            guard length > 1e-12 else { return ([point], false) }
            let unit = direction / length
            return ([point - unit * 25000.0, point + unit * 25000.0], false)
        case .circle(let center, let radius, _):
            let points = (0..<128).map { index in
                let angle = 2.0 * Double.pi * Double(index) / 128.0
                return Vector3(x: center.x + cos(angle) * radius,
                               y: center.y + sin(angle) * radius, z: center.z)
            }
            return (points, true)
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * Double.pi }
            let divisions = max(8, Int(ceil(span * 32.0 / Double.pi)))
            let points = (0...divisions).map { index in
                let angle = startAngle + span * Double(index) / Double(divisions)
                return Vector3(x: center.x + cos(angle) * radius,
                               y: center.y + sin(angle) * radius, z: center.z)
            }
            return (points, false)
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let minor = Vector3(x: -majorAxis.y * minorRatio,
                                y: majorAxis.x * minorRatio, z: 0)
            let points = (0..<128).map { index in
                let t = 2.0 * Double.pi * Double(index) / 128.0
                return center + majorAxis * cos(t) + minor * sin(t)
            }
            return (points, true)
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let points = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree, knots: knots, controlPoints: controlPoints,
                weights: weights, segmentsPerSpan: 8)
            let closed = points.count > 2
                && (points.first?.distance(to: points.last ?? .zero) ?? .infinity) <= 1e-6
            return (points, closed)
        case .polyline(let path, _):
            return (path.tessellatedPoints(), path.isClosed)
        case .polygon(let points, _):
            return (points, true)
        default:
            return ([], false)
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(0, 255, 128, 220)

        func screen(_ point: Vector3) -> ImVec2 {
            let s = EngineCameraManager.worldToScreen(
                worldX: point.x, worldY: point.y, cam: cam)
            return ImVec2(x: s.x, y: s.y)
        }

        if case .distanceSecondPoint(let first) = step {
            ImDrawListAddLine(drawList, screen(first), screen(currentMouse), color, 1.5)
            let label = format(first.distance(to: currentMouse))
            let mid = (first + currentMouse) * 0.5
            ImDrawListAddText(drawList, screen(mid), makeCol32(255, 255, 255, 220), label, nil)
            return
        }

        guard previewPoints.count >= 2 else { return }
        var points = previewPoints.map(screen)
        if previewClosed, let first = points.first { points.append(first) }
        points.withUnsafeBufferPointer { buffer in
            ImDrawListAddPolyline(
                drawList, buffer.baseAddress, Int32(buffer.count),
                color, 2.0, ImDrawFlags(0))
        }
    }
}

// =========================================================================
// MARK: - OffsetGapTypeCommand (OFFSETGAPTYPE system variable)
// =========================================================================

@MainActor
public final class OffsetGapTypeCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt =
            "Enter new value for OFFSETGAPTYPE <\(OffsetSettings.gapType.rawValue)>:"
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .handled }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER
            || scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        return .continue
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .finished }
        guard let raw = Int(value), let gapType = OffsetGapType(rawValue: raw) else {
            processor.commandPrompt =
                "OFFSETGAPTYPE requires an integer between 0 and 2. Enter new value <\(OffsetSettings.gapType.rawValue)>:"
            processor.commandLineActive = true
            processor.commandBuffer = ""
            return .handled
        }
        OffsetSettings.gapType = gapType
        return .finished
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        [
            .init(value: "0", title: "0 — Extend segments",
                  description: "Sharp mitered corners (default)"),
            .init(value: "1", title: "1 — Filleted corners",
                  description: "Arc radius equals the offset distance"),
            .init(value: "2", title: "2 — Chamfered corners",
                  description: "Straight bevel"),
        ].filter { $0.matches(input) }
    }
}

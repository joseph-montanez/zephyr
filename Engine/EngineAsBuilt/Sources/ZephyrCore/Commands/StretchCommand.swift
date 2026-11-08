// Sources/ZephyrCore/Commands/StretchCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel
import ZephyrLisp

// =========================================================================
// MARK: - StretchCommand
//
// STRETCH (alias S) — AutoCAD-style stretch across a crossing selection.
//
// Flow: adopt the pickfirst pre-selection as move-whole targets (else a
// select loop: crossing window right-to-left drag or C keyword, crossing
// polygon CP, individual picks move whole, R remove mode, Enter finishes).
// The command CAPTURES each crossing rect/polygon (not just the handles),
// because the stretch decision is per defining point. Then "Specify base
// point or [Displacement] <last>", then "Specify second point or <use
// first point as displacement>" with a live ghost of the stretched
// geometry (MOVE ghost idiom: displaced tessellation + rubber band;
// direct-distance entry, @x,y and dist<angle via `UserPointParser`). The
// Displacement branch ("Specify displacement <last>") takes a bare x,y as
// a relative vector. The last displacement is remembered per session
// (`StretchSettings`, OffsetSettings precedent); zero displacement exits
// with no undo. One `pushUndo` entry covers the whole set; results are
// left selected (reselected).
// =========================================================================

@MainActor
public final class StretchCommand: FeatureCommand {

    // MARK: - State Machine

    private enum Step {
        /// Pick members (click toggles, empty click starts a rect) or Enter ends.
        case selectObjects
        /// Awaiting the first rect corner after the C keyword (forced crossing).
        case awaitFirstCorner(remove: Bool)
        /// Interactive rect selection of stretch targets.
        case rectAnchor(startWorld: Vector3, startScreen: SDL_FPoint, forcedCrossing: Bool, remove: Bool)
        /// Collecting crossing-polygon vertices (click appends, Enter commits).
        case polygonCollecting(points: [Vector3])
        /// R remove mode: picks/rects subtract from the selection.
        case removeSelecting
        /// Interactive rect subtraction in remove mode.
        case removeRectAnchor(startWorld: Vector3, startScreen: SDL_FPoint)
        /// "Specify base point or [Displacement] <last>".
        case askBase
        /// "Specify second point or <use first point as displacement>" (live ghost).
        case askSecond(base: Vector3)
        /// Displacement branch: "Specify displacement <last>".
        case askDisplacement
    }

    // MARK: - Stored State

    private var active: Bool = false
    private var step: Step = .selectObjects
    private var targets: Set<UUID> = []
    /// Individually picked handles: move whole regardless of containment.
    private var pickedWhole: Set<UUID> = []
    /// Captured crossing regions (world space), in selection order.
    private var regions: [StretchRegion] = []
    private var operationsInSession: Int = 0
    private var currentMouse: Vector3 = .zero

    public init() {}

    // MARK: - FeatureCommand

    public var isSnappingEnabled: Bool {
        switch step {
        case .selectObjects, .awaitFirstCorner, .rectAnchor,
             .polygonCollecting, .removeSelecting, .removeRectAnchor:
            return false
        case .askBase, .askSecond, .askDisplacement:
            return true
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        switch step {
        case .askSecond(let base):
            return [base]
        default:
            return []
        }
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = true
        operationsInSession = 0
        targets.removeAll()
        pickedWhole.removeAll()
        regions.removeAll()
        currentMouse = .zero
        // Adopt the pickfirst pre-selection as move-whole targets (like an
        // individual pick each); a crossing selection afterwards still
        // stretches partially-enclosed members of the set.
        let preselected = engine.cadSelection.selectedHandles.filter { handle in
            guard let entity = engine.document.entity(for: handle) else { return false }
            guard !entity.isViewportProjected else { return false }
            guard let layer = engine.document.layer(for: entity.layerID),
                  layer.isVisible else { return false }
            return true
        }
        engine.cadSelection.clearSelection()
        if !preselected.isEmpty {
            targets = Set(preselected)
            pickedWhole = Set(preselected)
            for handle in preselected {
                engine.cadSelection.addToSelection(handle)
            }
            step = .askBase
            processor.commandPrompt = askBasePrompt
        } else {
            step = .selectObjects
            processor.commandPrompt = selectPrompt
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = false
        step = .selectObjects
        targets.removeAll()
        pickedWhole.removeAll()
        regions.removeAll()
        processor.commandPrompt = nil
    }

    // MARK: - Prompts

    private var selectPrompt: String {
        "Select objects to stretch by crossing-window or crossing-polygon... Select objects:"
    }

    private var askBasePrompt: String {
        if let last = StretchSettings.lastDisplacement {
            return "Specify base point or [Displacement] <\(formatDisplacement(last))>:"
        }
        return "Specify base point or [Displacement]:"
    }

    private var askDisplacementPrompt: String {
        if let last = StretchSettings.lastDisplacement {
            return "Specify displacement <\(formatDisplacement(last))>:"
        }
        return "Specify displacement:"
    }

    private func formatDisplacement(_ delta: Vector3) -> String {
        String(format: "%.4f,%.4f", delta.x, delta.y)
    }

    // MARK: - Mouse Input

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard active else { return .finished }
        let point = Vector3(x: worldX, y: worldY, z: 0)
        switch step {
        case .selectObjects:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            if let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks
            ) {
                if engine.io?.pointee.KeyShift ?? false {
                    engine.cadSelection.removeFromSelection(handle)
                    targets.remove(handle)
                    pickedWhole.remove(handle)
                } else {
                    engine.cadSelection.addToSelection(handle)
                    targets.insert(handle)
                    pickedWhole.insert(handle)
                }
                processor.commandPrompt =
                    "Select objects: \(targets.count) selected (Enter to finish)"
                return .handled
            }
            let startScreen = SDL_FPoint(
                x: Float(engine.interaction.lastMouseX),
                y: Float(engine.interaction.lastMouseY))
            step = .rectAnchor(
                startWorld: point, startScreen: startScreen,
                forcedCrossing: false, remove: false)
            processor.commandPrompt = "Specify opposite corner:"
            return .handled

        case .awaitFirstCorner(let remove):
            let startScreen = SDL_FPoint(
                x: Float(engine.interaction.lastMouseX),
                y: Float(engine.interaction.lastMouseY))
            if remove {
                step = .removeRectAnchor(startWorld: point, startScreen: startScreen)
            } else {
                step = .rectAnchor(
                    startWorld: point, startScreen: startScreen,
                    forcedCrossing: true, remove: false)
            }
            processor.commandPrompt = "Specify opposite corner:"
            return .handled

        case .rectAnchor(let startWorld, let startScreen, let forcedCrossing, let remove):
            commitRect(
                startWorld: startWorld, endWorld: point, startScreen: startScreen,
                forcedCrossing: forcedCrossing, remove: remove,
                engine: engine, processor: processor)
            return .handled

        case .polygonCollecting(var points):
            points.append(point)
            step = .polygonCollecting(points: points)
            processor.commandPrompt =
                "Specify next point or press Enter to finish (\(points.count) points):"
            return .handled

        case .removeSelecting:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            if let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks
            ) {
                engine.cadSelection.removeFromSelection(handle)
                targets.remove(handle)
                pickedWhole.remove(handle)
                processor.commandPrompt =
                    "Removed. \(targets.count) selected (Add/Enter to return)"
                return .handled
            }
            let startScreen = SDL_FPoint(
                x: Float(engine.interaction.lastMouseX),
                y: Float(engine.interaction.lastMouseY))
            step = .removeRectAnchor(startWorld: point, startScreen: startScreen)
            processor.commandPrompt = "Specify opposite corner:"
            return .handled

        case .removeRectAnchor(let startWorld, let startScreen):
            commitRect(
                startWorld: startWorld, endWorld: point, startScreen: startScreen,
                forcedCrossing: true, remove: true,
                engine: engine, processor: processor)
            return .handled

        case .askBase:
            step = .askSecond(base: point)
            processor.commandPrompt =
                "Specify second point or <use first point as displacement>:"
            return .handled

        case .askSecond(let base):
            return apply(delta: point - base, engine: engine, processor: processor)

        case .askDisplacement:
            // A click's coordinates are the displacement vector.
            return apply(delta: point, engine: engine, processor: processor)
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouse = Vector3(x: worldX, y: worldY, z: 0)
    }

    // MARK: - Selection commit

    /// Commit a two-click rect: record the crossing region and add the
    /// enclosed members (individual picks stay move-whole; rect members
    /// stretch per-point unless fully enclosed).
    private func commitRect(
        startWorld: Vector3, endWorld: Vector3, startScreen: SDL_FPoint,
        forcedCrossing: Bool, remove: Bool,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let minX = min(startWorld.x, endWorld.x)
        let maxX = max(startWorld.x, endWorld.x)
        let minY = min(startWorld.y, endWorld.y)
        let maxY = max(startWorld.y, endWorld.y)
        let rawScreenX = Float(engine.interaction.lastMouseX)
        let style: CADSelectionManager.RectSelectStyle =
            (forcedCrossing || rawScreenX < startScreen.x) ? .crossing : .window
        let handles = CADRectSelect.handlesInRect(
            worldX: minX, worldY: minY,
            worldW: maxX - minX, worldH: maxY - minY,
            document: engine.document, style: style)
        var changed = 0
        for handle in handles {
            guard let entity = engine.document.entity(for: handle) else { continue }
            guard !entity.isViewportProjected else { continue }
            guard let layer = engine.document.layer(for: entity.layerID),
                  layer.isVisible else { continue }
            if remove {
                if targets.remove(handle) != nil { changed += 1 }
                pickedWhole.remove(handle)
                engine.cadSelection.removeFromSelection(handle)
            } else {
                if targets.insert(handle).inserted { changed += 1 }
                engine.cadSelection.addToSelection(handle)
            }
        }
        if !remove {
            regions.append(.rect(
                min: Vector3(x: minX, y: minY, z: 0),
                max: Vector3(x: maxX, y: maxY, z: 0)))
            step = .selectObjects
            processor.commandPrompt =
                "Select objects: \(targets.count) selected (Enter to finish)"
        } else {
            step = .removeSelecting
            processor.commandPrompt =
                "Removed \(changed). \(targets.count) selected (Add/Enter to return)"
        }
    }

    /// Commit the collected crossing polygon: record the region and add the
    /// members it crosses.
    private func commitPolygon(
        points: [Vector3],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard points.count >= 3 else {
            step = .selectObjects
            processor.commandPrompt =
                "Crossing polygon needs at least 3 points. Select objects:"
            return
        }
        let handles = CADLassoSelect.handlesInPolygon(
            worldPoints: points, document: engine.document, style: .crossing)
        for handle in handles {
            guard let entity = engine.document.entity(for: handle) else { continue }
            guard !entity.isViewportProjected else { continue }
            guard let layer = engine.document.layer(for: entity.layerID),
                  layer.isVisible else { continue }
            targets.insert(handle)
            engine.cadSelection.addToSelection(handle)
        }
        regions.append(.polygon(points))
        step = .selectObjects
        processor.commandPrompt =
            "Select objects: \(targets.count) selected (Enter to finish)"
    }

    // MARK: - Key Down Handling

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            switch step {
            case .awaitFirstCorner, .rectAnchor, .polygonCollecting,
                 .removeRectAnchor, .removeSelecting:
                step = .selectObjects
                processor.commandPrompt = selectPrompt
                return .handled
            case .selectObjects, .askBase, .askSecond, .askDisplacement:
                return .finished
            }

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return acceptEnter(engine: engine, processor: processor)

        case SDL_SCANCODE_C where isSelecting:
            step = .awaitFirstCorner(remove: false)
            processor.commandPrompt = "Specify first corner:"
            return .handled

        case SDL_SCANCODE_R where isSelecting:
            step = .removeSelecting
            processor.commandPrompt = "Select objects to remove (Add/Enter to return):"
            return .handled

        case SDL_SCANCODE_A where isRemoving:
            step = .selectObjects
            processor.commandPrompt =
                "Select objects: \(targets.count) selected (Enter to finish)"
            return .handled

        case SDL_SCANCODE_D where isAskingBase:
            step = .askDisplacement
            processor.commandPrompt = askDisplacementPrompt
            return .handled

        case SDL_SCANCODE_U:
            return performUndo(engine: engine, processor: processor)

        default:
            return .continue
        }
    }

    private var isSelecting: Bool {
        if case .selectObjects = step { return true }
        return false
    }

    private var isRemoving: Bool {
        if case .removeSelecting = step { return true }
        return false
    }

    private var isAskingBase: Bool {
        if case .askBase = step { return true }
        return false
    }

    /// Enter with empty input: advance the prompt flow.
    private func acceptEnter(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .selectObjects:
            guard !targets.isEmpty else {
                processor.commandPrompt = "Nothing selected; nothing changed."
                return .finished
            }
            step = .askBase
            processor.commandPrompt = askBasePrompt
            return .handled

        case .awaitFirstCorner, .rectAnchor, .removeRectAnchor:
            // Enter with an open rect: keep it (click the opposite corner).
            return .continue

        case .polygonCollecting(let points):
            commitPolygon(points: points, engine: engine, processor: processor)
            return .handled

        case .removeSelecting:
            step = .selectObjects
            processor.commandPrompt =
                "Select objects: \(targets.count) selected (Enter to finish)"
            return .handled

        case .askBase:
            // Bare Enter reuses the last displacement directly.
            guard let last = StretchSettings.lastDisplacement else {
                processor.commandPrompt = askBasePrompt
                return .handled
            }
            return apply(delta: last, engine: engine, processor: processor)

        case .askSecond(let base):
            // Bare Enter uses the first point as the displacement.
            return apply(delta: base, engine: engine, processor: processor)

        case .askDisplacement:
            guard let last = StretchSettings.lastDisplacement else {
                processor.commandPrompt = askDisplacementPrompt
                return .handled
            }
            return apply(delta: last, engine: engine, processor: processor)
        }
    }

    // MARK: - Command Text Handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()

        switch step {
        case .selectObjects:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            switch upper {
            case "C", "CROSSING":
                step = .awaitFirstCorner(remove: false)
                processor.commandPrompt = "Specify first corner:"
                return .handled
            case "CP":
                step = .polygonCollecting(points: [])
                processor.commandPrompt = "Specify first polygon point:"
                return .handled
            case "R", "REMOVE":
                step = .removeSelecting
                processor.commandPrompt = "Select objects to remove (Add/Enter to return):"
                return .handled
            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                return .continue
            }

        case .awaitFirstCorner, .rectAnchor, .removeRectAnchor:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if upper == "U" || upper == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            return .continue

        case .polygonCollecting(let points):
            if value.isEmpty {
                commitPolygon(points: points, engine: engine, processor: processor)
                return .handled
            }
            return .continue

        case .removeSelecting:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            switch upper {
            case "A", "ADD":
                step = .selectObjects
                processor.commandPrompt =
                    "Select objects: \(targets.count) selected (Enter to finish)"
                return .handled
            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                return .continue
            }

        case .askBase:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            switch upper {
            case "D", "DISPLACEMENT":
                step = .askDisplacement
                processor.commandPrompt = askDisplacementPrompt
                return .handled
            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                break
            }
            guard let point = Self.parseTypedPoint(value, base: .zero) else {
                processor.commandPrompt =
                    "Invalid point. \(askBasePrompt)"
                return .handled
            }
            step = .askSecond(base: point)
            processor.commandPrompt =
                "Specify second point or <use first point as displacement>:"
            return .handled

        case .askSecond(let base):
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if upper == "U" || upper == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            // Direct-distance entry: a bare number runs along the current
            // base → cursor direction (MOVE idiom).
            if let distance = Double(value), distance.isFinite, distance != 0 {
                let direction = currentMouse - base
                let length = direction.magnitude
                let unit = length > 1e-9 ? direction / length : Vector3(x: 1, y: 0, z: 0)
                return apply(delta: unit * distance, engine: engine, processor: processor)
            }
            guard let point = Self.parseTypedPoint(value, base: base) else {
                processor.commandPrompt =
                    "Invalid point. Specify second point or <use first point as displacement>:"
                return .handled
            }
            return apply(delta: point - base, engine: engine, processor: processor)

        case .askDisplacement:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if upper == "U" || upper == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            // A bare x,y is a relative vector here (not an absolute point).
            guard let delta = Self.parseDisplacement(value) else {
                processor.commandPrompt =
                    "Invalid displacement. \(askDisplacementPrompt)"
                return .handled
            }
            return apply(delta: delta, engine: engine, processor: processor)
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        let options: [FeatureCommandTextOption]
        switch step {
        case .selectObjects:
            options = [
                .init(value: "C", title: "Crossing", aliases: ["CROSSING"],
                      description: "Two-corner crossing selection"),
                .init(value: "CP", title: "Crossing Polygon", aliases: [],
                      description: "Crossing polygon selection"),
                .init(value: "R", title: "Remove", aliases: ["REMOVE"],
                      description: "Remove objects from the selection"),
            ] + (operationsInSession > 0
                ? [.init(value: "U", title: "Undo", aliases: ["UNDO"],
                         description: "Revert the last stretch in this session")]
                : [])
        case .removeSelecting:
            options = [
                .init(value: "A", title: "Add", aliases: ["ADD"],
                      description: "Return to adding objects"),
            ] + (operationsInSession > 0
                ? [.init(value: "U", title: "Undo", aliases: ["UNDO"],
                         description: "Revert the last stretch in this session")]
                : [])
        case .askBase:
            options = [
                .init(value: "D", title: "Displacement", aliases: ["DISPLACEMENT"],
                      description: "Enter the displacement directly"),
            ] + (operationsInSession > 0
                ? [.init(value: "U", title: "Undo", aliases: ["UNDO"],
                         description: "Revert the last stretch in this session")]
                : [])
        case .askSecond, .askDisplacement:
            options = operationsInSession > 0
                ? [.init(value: "U", title: "Undo", aliases: ["UNDO"],
                         description: "Revert the last stretch in this session")]
                : []
        default:
            options = []
        }
        return options.filter { $0.matches(input) }
    }

    /// Parse a typed point (`x,y[,z]`, `@dx,dy[,dz]`, `dist<angle`) relative
    /// to `base` (origin for the base point, the base point for the second
    /// point). Stretching lives in XY, so the elevation resolves to 0.
    static func parseTypedPoint(_ text: String, base: Vector3) -> Vector3? {
        guard let input = UserPointParser.parse(text) else { return nil }
        let resolved = UserPointParser.resolve(
            input,
            from: Point3d(x: base.x, y: base.y, z: 0),
            userAngleToCanonical: {
                AngleConvention.default.canonicalOrientation(fromUser: $0)
            })
        return Vector3(x: resolved.x, y: resolved.y, z: 0)
    }

    /// Parse a displacement (`x,y[,z]`, `@dx,dy[,dz]`, `dist<angle`): every
    /// form resolves as a relative vector, so a bare `x,y` is the
    /// displacement itself rather than an absolute point.
    static func parseDisplacement(_ text: String) -> Vector3? {
        guard let input = UserPointParser.parse(text) else { return nil }
        let resolved = UserPointParser.resolve(
            input,
            from: Point3d(x: 0, y: 0, z: 0),
            userAngleToCanonical: {
                AngleConvention.default.canonicalOrientation(fromUser: $0)
            })
        return Vector3(x: resolved.x, y: resolved.y, z: 0)
    }

    // MARK: - Execution

    /// Apply the displacement to the whole set: one `stretchEntities` call
    /// (one undo entry), then leave the changed results selected and finish.
    private func apply(
        delta: Vector3, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard delta.magnitude > 1e-9 else {
            reset()
            processor.commandPrompt = "Nothing stretched (zero displacement)."
            print("[CAD] STRETCH: zero displacement, nothing changed.")
            return .finished
        }
        let outcome = engine.document.stretchEntities(
            handles: targets, regions: regions,
            moveWhole: pickedWhole, by: delta)
        guard outcome.stretched + outcome.movedWhole > 0 else {
            var message = "Nothing stretched."
            if outcome.lockedSkipped > 0 {
                message += " \(outcome.lockedSkipped) object(s) on locked layers skipped."
            }
            if outcome.projectedSkipped > 0 {
                message += " \(outcome.projectedSkipped) viewport copy(ies) skipped."
            }
            reset()
            print("[CAD] STRETCH: \(message)")
            return .finished
        }
        operationsInSession += 1
        StretchSettings.lastDisplacement = delta
        engine.cadSelection.clearSelection()
        for handle in outcome.changedHandles {
            engine.cadSelection.addToSelection(handle)
        }
        engine.interaction.cachedGripGeneration = -1
        engine.tabManager.markActiveDirty()
        var message = "Stretched \(outcome.stretched + outcome.movedWhole) object(s)"
        message += " by (\(String(format: "%.4f", delta.x)), \(String(format: "%.4f", delta.y)))."
        if outcome.lockedSkipped > 0 {
            message += " \(outcome.lockedSkipped) on locked layer(s) skipped."
        }
        if outcome.projectedSkipped > 0 {
            message += " \(outcome.projectedSkipped) viewport copy(ies) skipped."
        }
        reset()
        print("[CAD] STRETCH: \(message)")
        return .finished
    }

    private func performUndo(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard operationsInSession > 0 else {
            processor.commandPrompt = "Nothing to undo in this STRETCH session."
            return .handled
        }
        engine.document.undo()
        operationsInSession -= 1
        targets.removeAll()
        pickedWhole.removeAll()
        regions.removeAll()
        engine.cadSelection.clearSelection()
        step = .selectObjects
        processor.commandPrompt = "Undid stretch. \(selectPrompt)"
        return .handled
    }

    private func reset() {
        step = .selectObjects
        targets.removeAll()
        pickedWhole.removeAll()
        regions.removeAll()
        currentMouse = .zero
    }

    // MARK: - Overlay Rendering

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard active else { return }
        guard let drawList = igGetForegroundDrawList_ViewportPtr(nil) else { return }
        func screen(_ point: Vector3) -> ImVec2 {
            let s = EngineCameraManager.worldToScreen(
                worldX: point.x, worldY: point.y, cam: cam)
            return ImVec2(x: s.x, y: s.y)
        }
        switch step {
        case .askSecond(let base):
            drawStretchGhost(
                drawList: drawList, screen: screen, base: base,
                delta: currentMouse - base, engine: engine)
        case .askDisplacement:
            // The cursor's coordinates are the displacement vector.
            drawStretchGhost(
                drawList: drawList, screen: screen, base: .zero,
                delta: currentMouse, engine: engine)
        default:
            return
        }
    }

    /// Live ghost of the stretched geometry (MOVE ghost idiom): each target
    /// re-tessellated under the pending displacement, plus a rubber-band
    /// line from the base point to the cursor.
    private func drawStretchGhost(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        screen: (Vector3) -> ImVec2,
        base: Vector3,
        delta: Vector3,
        engine: PhrostEngine
    ) {
        guard delta.magnitude > 1e-9 else { return }
        // Rubber band.
        ImDrawListAddLine(
            drawList, screen(base), screen(base + delta),
            makeCol32(255, 200, 0, 230), 1.5)
        let ghostCol = makeCol32(0, 220, 255, 200)
        for handle in targets {
            guard let entity = engine.document.entity(for: handle) else { continue }
            let decision = StretchGeometryEngine.stretch(
                entity: entity, regions: regions,
                moveWhole: pickedWhole.contains(handle), by: delta)
            let previewGeometry: [CADPrimitive]
            let previewTransform: Transform3D
            switch decision {
            case .unchanged:
                continue
            case .moveWhole:
                previewGeometry = entity.localGeometry ?? []
                previewTransform = Self.shifted(entity.transform, by: delta)
            case .stretched(let geometry):
                previewGeometry = geometry
                previewTransform = entity.transform
            }
            for primitive in previewGeometry {
                for strip in Self.tessellatedWorldStrips(
                    primitive, transform: previewTransform) {
                    let points = strip.map(screen)
                    guard points.count >= 2 else { continue }
                    points.withUnsafeBufferPointer { buffer in
                        ImDrawListAddPolyline(
                            drawList, buffer.baseAddress, Int32(buffer.count),
                            ghostCol, 1.5, ImDrawFlags(0))
                    }
                }
            }
        }
    }

    private static func shifted(_ transform: Transform3D, by delta: Vector3) -> Transform3D {
        var result = transform
        result.position += delta
        return result
    }

    /// World-space tessellation of one primitive for ghost preview.
    static func tessellatedWorldStrips(
        _ primitive: CADPrimitive, transform: Transform3D
    ) -> [[Vector3]] {
        func world(_ points: [Vector3]) -> [Vector3] {
            points.map { transform.transformPoint($0) }
        }
        switch primitive {
        case .line(let start, let end, _):
            return [world([start, end])]
        case .polyline(let path, _):
            return [world(path.tessellatedPoints())]
        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                degree: degree, knots: knots, controlPoints: controlPoints,
                weights: weights, segmentsPerSpan: 8)
            return [world(evaluated.isEmpty ? controlPoints : evaluated)]
        case .circle(let center, let radius, _):
            let points = (0...64).map { index -> Vector3 in
                let angle = 2.0 * Double.pi * Double(index) / 64.0
                return Vector3(x: center.x + cos(angle) * radius,
                               y: center.y + sin(angle) * radius, z: center.z)
            }
            return [world(points)]
        case .arc(let center, let radius, let startAngle, let endAngle, _):
            var span = endAngle - startAngle
            if span < 0 { span += 2.0 * Double.pi }
            let divisions = max(8, Int(ceil(span * 32.0 / Double.pi)))
            let points = (0...divisions).map { index -> Vector3 in
                let angle = startAngle + span * Double(index) / Double(divisions)
                return Vector3(x: center.x + cos(angle) * radius,
                               y: center.y + sin(angle) * radius, z: center.z)
            }
            return [world(points)]
        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let minor = Vector3(x: -majorAxis.y * minorRatio,
                                y: majorAxis.x * minorRatio, z: 0)
            let points = (0...64).map { index -> Vector3 in
                let t = 2.0 * Double.pi * Double(index) / 64.0
                return center + majorAxis * cos(t) + minor * sin(t)
            }
            return [world(points)]
        case .rect(let origin, let size, _), .fillRect(let origin, let size, _):
            var corners = StretchGeometryEngine.rectCorners(origin: origin, size: size)
            if let first = corners.first { corners.append(first) }
            return [world(corners)]
        case .polygon(let points, _), .fillPolygon(let points, _):
            var loop = points
            if let first = loop.first { loop.append(first) }
            return [world(loop)]
        case .fillComplexPolygon(let outer, let holes, _),
             .gradient(let outer, let holes, _, _, _, _):
            var strips: [[Vector3]] = []
            var loop = outer
            if let first = loop.first { loop.append(first) }
            strips.append(world(loop))
            for hole in holes {
                var ring = hole
                if let first = ring.first { ring.append(first) }
                strips.append(world(ring))
            }
            return strips
        case .hatch(let boundary, _, _, _, _, _):
            var loop = boundary
            if let first = loop.first { loop.append(first) }
            return [world(loop)]
        case .hatchPath(let boundary, let holes, _, _, _, _, _):
            var strips = [world(boundary.tessellatedPoints())]
            for hole in holes {
                strips.append(world(hole.tessellatedPoints()))
            }
            return strips
        case .ray(let start, let direction, _):
            let length = direction.magnitude
            guard length > 1e-12 else { return [world([start])] }
            return [world([start, start + direction / length * 25000.0])]
        case .xline(let point, let direction, _):
            let length = direction.magnitude
            guard length > 1e-12 else { return [world([point])] }
            let unit = direction / length
            return [world([point - unit * 25000.0, point + unit * 25000.0])]
        case .point(let position, _), .text(let position, _, _, _, _, _, _, _, _):
            // Single-point marker: the rubber band carries the displacement.
            return [world([position])]
        case .image(let insertion, let uAxis, let vAxis, _, _, _):
            let corners = [
                insertion,
                insertion + uAxis,
                insertion + uAxis + vAxis,
                insertion + vAxis,
                insertion,
            ]
            return [world(corners)]
        case .penStroke(let vertices, _, _):
            return [world(vertices.map(\.position))]
        case .table:
            return []
        }
    }
}

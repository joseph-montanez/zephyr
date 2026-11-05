// Sources/ZephyrCore/Commands/MirrorCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel
import ZephyrLisp

// =========================================================================
// MARK: - MirrorCommand
//
// MIRROR (alias MI) — AutoCAD-style mirror across a user-picked mirror line.
//
// Flow: adopt the pickfirst pre-selection (else a pick/box loop, Enter ends),
// ask for the first and second points of the mirror line (snapped mouse picks
// or typed points via `UserPointParser`), then ask
// "Erase source objects? [Yes/No] <N>" (default No). The reflection is
// composed into each entity transform via `multiplying(by:)`; with No the
// sources are kept and `duplicateEntities` copies are reflected instead.
// Viewport-projected entities are skipped and locked-layer entities are
// refused with a counted message. `MIRRTEXT` is honored (0 keeps text and
// attributes readable, nonzero mirrors them truly). One `pushUndo` entry
// covers the apply either way, counted in `operationsInSession`; results are
// left selected (reselected).
// =========================================================================

@MainActor
public final class MirrorCommand: FeatureCommand {

    // MARK: - State Machine

    private enum Step {
        /// Pick members (click toggles, empty click starts a box) or Enter ends.
        case selectObjects
        /// Interactive box selection of mirror targets.
        case boxSelecting(startWorld: Vector3, startScreen: SDL_FPoint)
        /// "Specify first point of mirror line".
        case askFirstPoint
        /// "Specify second point of mirror line" (live mirrored ghost).
        case askSecondPoint(first: Vector3)
        /// "Erase source objects? [Yes/No] <N>".
        case askErase(first: Vector3, second: Vector3)
    }

    // MARK: - Stored State

    private var active: Bool = false
    private var step: Step = .selectObjects
    private var targets: Set<UUID> = []
    private var operationsInSession: Int = 0
    private var currentMouse: Vector3 = .zero

    public init() {}

    // MARK: - FeatureCommand

    public var isSnappingEnabled: Bool {
        switch step {
        case .selectObjects, .boxSelecting, .askErase:
            return false
        case .askFirstPoint, .askSecondPoint:
            return true
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        switch step {
        case .askSecondPoint(let first):
            return [first]
        case .askErase(let first, let second):
            return [first, second]
        default:
            return []
        }
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = true
        operationsInSession = 0
        targets.removeAll()
        currentMouse = .zero
        let preselected = engine.cadSelection.selectedHandles.filter { handle in
            guard let entity = engine.document.entity(for: handle) else { return false }
            guard !entity.isViewportProjected else { return false }
            guard let layer = engine.document.layer(for: entity.layerID),
                  layer.isVisible else { return false }
            return true
        }
        if !preselected.isEmpty {
            targets = Set(preselected)
            engine.cadSelection.clearSelection()
            step = .askFirstPoint
            processor.commandPrompt = "Specify first point of mirror line:"
        } else {
            engine.cadSelection.clearSelection()
            step = .selectObjects
            processor.commandPrompt = "Select objects:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = false
        step = .selectObjects
        targets.removeAll()
        processor.commandPrompt = nil
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
                } else {
                    engine.cadSelection.addToSelection(handle)
                    targets.insert(handle)
                }
                processor.commandPrompt =
                    "Select objects: \(targets.count) selected (Enter to finish)"
                return .handled
            }
            let startScreen = SDL_FPoint(
                x: Float(engine.interaction.lastMouseX),
                y: Float(engine.interaction.lastMouseY))
            step = .boxSelecting(startWorld: point, startScreen: startScreen)
            processor.commandPrompt = "Specify opposite corner:"
            return .handled

        case .boxSelecting(let startWorld, let startScreen):
            let minX = min(startWorld.x, point.x)
            let maxX = max(startWorld.x, point.x)
            let minY = min(startWorld.y, point.y)
            let maxY = max(startWorld.y, point.y)
            let rawScreenX = Float(engine.interaction.lastMouseX)
            let style: CADSelectionManager.RectSelectStyle =
                rawScreenX < startScreen.x ? .crossing : .window
            let handles = CADRectSelect.handlesInRect(
                worldX: minX, worldY: minY,
                worldW: maxX - minX, worldH: maxY - minY,
                document: engine.document, style: style)
            for handle in handles {
                guard let entity = engine.document.entity(for: handle) else { continue }
                guard !entity.isViewportProjected else { continue }
                guard let layer = engine.document.layer(for: entity.layerID),
                      layer.isVisible else { continue }
                engine.cadSelection.addToSelection(handle)
                targets.insert(handle)
            }
            step = .selectObjects
            processor.commandPrompt =
                "Select objects: \(targets.count) selected (Enter to finish)"
            return .handled

        case .askFirstPoint:
            step = .askSecondPoint(first: point)
            processor.commandPrompt = "Specify second point of mirror line:"
            return .handled

        case .askSecondPoint(let first):
            guard CADGeometryMath.mirrorTransform(p1: first, p2: point) != nil else {
                processor.commandPrompt =
                    "Points are coincident. Specify second point of mirror line:"
                return .handled
            }
            step = .askErase(first: first, second: point)
            processor.commandPrompt = "Erase source objects? [Yes/No] <N>:"
            return .handled

        case .askErase:
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouse = Vector3(x: worldX, y: worldY, z: 0)
    }

    // MARK: - Key Down Handling

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return acceptEnter(engine: engine, processor: processor)

        case SDL_SCANCODE_Y where isAskingErase:
            return apply(eraseSource: true, engine: engine, processor: processor)

        case SDL_SCANCODE_N where isAskingErase:
            return apply(eraseSource: false, engine: engine, processor: processor)

        case SDL_SCANCODE_U:
            return performUndo(engine: engine, processor: processor)

        default:
            return .continue
        }
    }

    private var isAskingErase: Bool {
        if case .askErase = step { return true }
        return false
    }

    /// Enter with empty input: advance the prompt flow (pick at cursor for
    /// point steps, default No at the erase prompt, commit the selection).
    private func acceptEnter(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .selectObjects:
            guard !targets.isEmpty else {
                processor.commandPrompt = "Nothing selected; nothing changed."
                return .finished
            }
            step = .askFirstPoint
            processor.commandPrompt = "Specify first point of mirror line:"
            return .handled

        case .boxSelecting:
            // Enter with an open box: keep it (click the opposite corner).
            return .continue

        case .askFirstPoint:
            step = .askSecondPoint(first: currentMouse)
            processor.commandPrompt = "Specify second point of mirror line:"
            return .handled

        case .askSecondPoint(let first):
            guard CADGeometryMath.mirrorTransform(p1: first, p2: currentMouse) != nil else {
                processor.commandPrompt =
                    "Points are coincident. Specify second point of mirror line:"
                return .handled
            }
            step = .askErase(first: first, second: currentMouse)
            processor.commandPrompt = "Erase source objects? [Yes/No] <N>:"
            return .handled

        case .askErase:
            return apply(eraseSource: false, engine: engine, processor: processor)
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
        case .selectObjects, .boxSelecting:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if upper == "U" || upper == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            return .continue

        case .askFirstPoint:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            guard let point = Self.parseTypedPoint(value, base: .zero) else {
                processor.commandPrompt =
                    "Invalid point. Specify first point of mirror line:"
                return .handled
            }
            step = .askSecondPoint(first: point)
            processor.commandPrompt = "Specify second point of mirror line:"
            return .handled

        case .askSecondPoint(let first):
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            guard let point = Self.parseTypedPoint(value, base: first) else {
                processor.commandPrompt =
                    "Invalid point. Specify second point of mirror line:"
                return .handled
            }
            guard CADGeometryMath.mirrorTransform(p1: first, p2: point) != nil else {
                processor.commandPrompt =
                    "Points are coincident. Specify second point of mirror line:"
                return .handled
            }
            step = .askErase(first: first, second: point)
            processor.commandPrompt = "Erase source objects? [Yes/No] <N>:"
            return .handled

        case .askErase:
            switch upper {
            case "", "N", "NO":
                return apply(eraseSource: false, engine: engine, processor: processor)
            case "Y", "YES":
                return apply(eraseSource: true, engine: engine, processor: processor)
            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                processor.commandPrompt = "Erase source objects? [Yes/No] <N>:"
                return .handled
            }
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        let options: [FeatureCommandTextOption]
        switch step {
        case .askErase:
            options = [
                .init(value: "Y", title: "Yes", aliases: ["YES"],
                      description: "Erase source objects after mirroring"),
                .init(value: "N", title: "No", aliases: ["NO"],
                      description: "Keep source objects (default)"),
            ]
        case .selectObjects, .boxSelecting:
            options = operationsInSession > 0
                ? [.init(value: "U", title: "Undo", aliases: ["UNDO"],
                         description: "Revert the last mirror in this session")]
                : []
        default:
            options = []
        }
        return options.filter { $0.matches(input) }
    }

    /// Parse a typed point (`x,y[,z]`, `@dx,dy[,dz]`, `dist<angle`) relative
    /// to `base` (origin for the first mirror point, the first point for the
    /// second). Mirror lines live in XY, so the elevation resolves to 0.
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

    /// Normalize a `MIRRTEXT` sysvar value: 0 keeps text/attributes readable,
    /// anything nonzero mirrors them truly. Missing/unreadable reads as 0.
    static func mirrTextValue(_ value: LispValue?) -> Int {
        if case .int(let raw) = value { return raw == 0 ? 0 : 1 }
        return 0
    }

    // MARK: - Execution

    /// Mirror the targets across the accepted mirror line: one
    /// `mirrorEntities` call (one undo entry either way), then leave the
    /// results selected and finish.
    private func apply(
        eraseSource: Bool, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard case .askErase(let first, let second) = step else { return .handled }
        guard let mirror = CADGeometryMath.mirrorTransform(p1: first, p2: second) else {
            processor.commandPrompt =
                "Points are coincident. Specify second point of mirror line:"
            step = .askSecondPoint(first: first)
            return .handled
        }
        let mirrText = Self.mirrTextValue(processor.systemVariable("MIRRTEXT"))
        let outcome = engine.document.mirrorEntities(
            handles: targets, mirror: mirror,
            eraseSource: eraseSource, mirrText: mirrText)
        guard outcome.mirrored > 0 else {
            var message = "Nothing mirrored."
            if outcome.lockedSkipped > 0 {
                message += " \(outcome.lockedSkipped) object(s) on locked layers skipped."
            }
            if outcome.projectedSkipped > 0 {
                message += " \(outcome.projectedSkipped) viewport copy(ies) skipped."
            }
            reset()
            print("[CAD] MIRROR: \(message)")
            return .finished
        }
        operationsInSession += 1
        engine.cadSelection.clearSelection()
        let resultHandles: Set<UUID> =
            eraseSource ? targets : Set(outcome.newHandles)
        for handle in resultHandles {
            engine.cadSelection.addToSelection(handle)
        }
        engine.interaction.cachedGripGeneration = -1
        engine.document.invalidateEntityGrid()
        engine.tabManager.markActiveDirty()
        var message = "Mirrored \(outcome.mirrored) object(s)"
        message += eraseSource ? " (sources erased)." : " (sources kept)."
        if outcome.lockedSkipped > 0 {
            message += " \(outcome.lockedSkipped) on locked layer(s) skipped."
        }
        if outcome.projectedSkipped > 0 {
            message += " \(outcome.projectedSkipped) viewport copy(ies) skipped."
        }
        reset()
        print("[CAD] MIRROR: \(message)")
        return .finished
    }

    private func performUndo(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard operationsInSession > 0 else {
            processor.commandPrompt = "Nothing to undo in this MIRROR session."
            return .handled
        }
        engine.document.undo()
        operationsInSession -= 1
        targets.removeAll()
        engine.cadSelection.clearSelection()
        step = .selectObjects
        processor.commandPrompt = "Undid mirror. Select objects:"
        return .handled
    }

    private func reset() {
        step = .selectObjects
        targets.removeAll()
        currentMouse = .zero
    }

    // MARK: - Overlay Rendering

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard active else { return }
        guard let drawList = igGetForegroundDrawList_ViewportPtr(nil) else { return }
        let axis: (Vector3, Vector3)?
        switch step {
        case .askSecondPoint(let first):
            axis = (first, currentMouse)
        case .askErase(let first, let second):
            axis = (first, second)
        default:
            axis = nil
        }
        guard let (anchor, tip) = axis,
              hypot(tip.x - anchor.x, tip.y - anchor.y) > 1e-9 else { return }
        func screen(_ point: Vector3) -> ImVec2 {
            let s = EngineCameraManager.worldToScreen(
                worldX: point.x, worldY: point.y, cam: cam)
            return ImVec2(x: s.x, y: s.y)
        }
        // Rubber-band mirror line.
        ImDrawListAddLine(
            drawList, screen(anchor), screen(tip),
            makeCol32(255, 200, 0, 230), 1.5)
        // Mirrored ghost: each target's world bounding box reflected.
        guard let mirror = CADGeometryMath.mirrorTransform(p1: anchor, p2: tip) else {
            return
        }
        let ghostCol = makeCol32(0, 220, 255, 200)
        for handle in targets {
            guard let entity = engine.document.entity(for: handle),
                  let box = entity.worldBoundingBox else { continue }
            let corners = [
                Vector3(x: box.min.x, y: box.min.y, z: 0),
                Vector3(x: box.max.x, y: box.min.y, z: 0),
                Vector3(x: box.max.x, y: box.max.y, z: 0),
                Vector3(x: box.min.x, y: box.max.y, z: 0),
            ].map { mirror.transformPoint($0) }
            for index in 0..<corners.count {
                ImDrawListAddLine(
                    drawList,
                    screen(corners[index]),
                    screen(corners[(index + 1) % corners.count]),
                    ghostCol, 1.5)
            }
        }
    }
}

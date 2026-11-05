// Sources/ZephyrCore/Commands/BreakCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel
import ZephyrLisp

// =========================================================================
// MARK: - BreakCommand
//
// BREAK (alias BR) and BREAKATPOINT — AutoCAD-style partial erase.
//
// BREAK flow: Select object (a single pick; the pick point becomes the
// first break point, projected onto the object via
// `BreakGeometryEngine.projectedPoint`), then "Specify second break point
// or [First point]" (pick or typed point; F re-prompts "Specify first
// break point" then "Specify second break point" with snapping). The span
// between the two points is erased: one successful break applies and the
// command exits single-shot (Enter afterwards repeats via last-command).
//
// BREAKATPOINT flow: Select object then "Specify break point", splitting
// with no gap. The command stays active and repeats until Enter.
//
// Both modes push exactly one undo entry per applied break (counted in
// `operationsInSession` for in-session U); rejected picks and degenerate
// splits push nothing and stay in the prompt flow.
// =========================================================================

@MainActor
public final class BreakCommand: FeatureCommand {

    // MARK: - Mode

    /// Which command this instance serves.
    public enum Mode {
        /// Erase the span between two break points, then exit.
        case breakSpan
        /// Split at one point with no gap, then repeat.
        case breakAtPoint
    }

    // MARK: - State Machine

    private enum Step {
        /// Pick one object (click only; empty click reprompts).
        case selectObject
        /// "Specify second break point or [First point]" (BREAK).
        case askSecond(target: UUID, first: Vector3)
        /// "Specify first break point" (BREAK F-option / pickfirst).
        case askFirst(target: UUID)
        /// "Specify break point" (BREAKATPOINT).
        case askBreakPoint(target: UUID)
    }

    // MARK: - Stored State

    private let mode: Mode
    private var active: Bool = false
    private var step: Step = .selectObject
    private var operationsInSession: Int = 0
    private var currentMouse: Vector3 = .zero

    public init(mode: Mode = .breakSpan) {
        self.mode = mode
    }

    private var isBreakAtPoint: Bool {
        if case .breakAtPoint = mode { return true }
        return false
    }

    // MARK: - FeatureCommand

    public var isSnappingEnabled: Bool {
        switch step {
        case .selectObject:
            return false
        case .askSecond, .askFirst, .askBreakPoint:
            return true
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        switch step {
        case .askSecond(_, let first):
            return [first]
        default:
            return []
        }
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = true
        operationsInSession = 0
        step = .selectObject
        currentMouse = .zero
        // Adopt a single pickfirst object (no pick point exists, so BREAK
        // still asks for the first point explicitly).
        let preselected = engine.cadSelection.selectedHandles.filter { handle in
            guard let entity = engine.document.entity(for: handle) else { return false }
            guard !entity.isViewportProjected else { return false }
            guard let layer = engine.document.layer(for: entity.layerID),
                  layer.isVisible else { return false }
            return true
        }
        engine.cadSelection.clearSelection()
        if preselected.count == 1, let handle = preselected.first {
            if isBreakAtPoint {
                step = .askBreakPoint(target: handle)
                processor.commandPrompt = "Specify break point:"
            } else {
                step = .askFirst(target: handle)
                processor.commandPrompt = "Specify first break point:"
            }
        } else {
            step = .selectObject
            processor.commandPrompt = "Select object:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = false
        step = .selectObject
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
        case .selectObject:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks
            ) else {
                processor.commandPrompt = "No object found there. Select object:"
                return .handled
            }
            guard let entity = engine.document.entity(for: handle),
                  let first = BreakGeometryEngine.projectedPoint(
                      entity: entity, worldPick: point) else {
                processor.commandPrompt =
                    "That object cannot be broken. Select object:"
                return .handled
            }
            if isBreakAtPoint {
                step = .askBreakPoint(target: handle)
                processor.commandPrompt = "Specify break point:"
            } else {
                step = .askSecond(target: handle, first: first)
                processor.commandPrompt =
                    "Specify second break point or [First point]:"
            }
            return .handled

        case .askSecond(let target, let first):
            return apply(
                target: target, first: first, second: point,
                engine: engine, processor: processor)

        case .askFirst(let target):
            guard let entity = engine.document.entity(for: target),
                  let first = BreakGeometryEngine.projectedPoint(
                      entity: entity, worldPick: point) else {
                processor.commandPrompt =
                    "That object cannot be broken. Select object:"
                step = .selectObject
                return .handled
            }
            step = .askSecond(target: target, first: first)
            processor.commandPrompt =
                "Specify second break point or [First point]:"
            return .handled

        case .askBreakPoint(let target):
            return applyAtPoint(
                target: target, point: point,
                engine: engine, processor: processor)
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

        case SDL_SCANCODE_F where isAskingSecond:
            guard case .askSecond(let target, _) = step else { return .handled }
            step = .askFirst(target: target)
            processor.commandPrompt = "Specify first break point:"
            return .handled

        case SDL_SCANCODE_U:
            return performUndo(engine: engine, processor: processor)

        default:
            return .continue
        }
    }

    private var isAskingSecond: Bool {
        if case .askSecond = step { return true }
        return false
    }

    /// Enter with empty input: advance the prompt flow (point steps use
    /// the cursor, like the MirrorCommand point steps).
    private func acceptEnter(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .selectObject:
            processor.commandPrompt = "Nothing selected; nothing changed."
            return .finished

        case .askSecond(let target, let first):
            return apply(
                target: target, first: first, second: currentMouse,
                engine: engine, processor: processor)

        case .askFirst(let target):
            guard let entity = engine.document.entity(for: target),
                  let first = BreakGeometryEngine.projectedPoint(
                      entity: entity, worldPick: currentMouse) else {
                processor.commandPrompt =
                    "That object cannot be broken. Select object:"
                step = .selectObject
                return .handled
            }
            step = .askSecond(target: target, first: first)
            processor.commandPrompt =
                "Specify second break point or [First point]:"
            return .handled

        case .askBreakPoint(let target):
            return applyAtPoint(
                target: target, point: currentMouse,
                engine: engine, processor: processor)
        }
    }

    // MARK: - Command Text Handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()
        // `_.F` / `_F` spellings collapse to the F keyword.
        let keyword = upper.hasPrefix("_.") ? String(upper.dropFirst(2))
            : upper.hasPrefix("_") ? String(upper.dropFirst(1)) : upper

        switch step {
        case .selectObject:
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if keyword == "U" || keyword == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            return .continue

        case .askSecond(let target, let first):
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if keyword == "F" || keyword == "FIRST" {
                step = .askFirst(target: target)
                processor.commandPrompt = "Specify first break point:"
                return .handled
            }
            if keyword == "U" || keyword == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            guard let point = MirrorCommand.parseTypedPoint(value, base: first) else {
                processor.commandPrompt =
                    "Invalid point. Specify second break point or [First point]:"
                return .handled
            }
            return apply(
                target: target, first: first, second: point,
                engine: engine, processor: processor)

        case .askFirst(let target):
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if keyword == "U" || keyword == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            guard let raw = MirrorCommand.parseTypedPoint(value, base: .zero),
                  let entity = engine.document.entity(for: target),
                  let first = BreakGeometryEngine.projectedPoint(
                      entity: entity, worldPick: raw) else {
                processor.commandPrompt =
                    "Invalid point. Specify first break point:"
                return .handled
            }
            step = .askSecond(target: target, first: first)
            processor.commandPrompt =
                "Specify second break point or [First point]:"
            return .handled

        case .askBreakPoint(let target):
            if value.isEmpty { return acceptEnter(engine: engine, processor: processor) }
            if keyword == "U" || keyword == "UNDO" {
                return performUndo(engine: engine, processor: processor)
            }
            guard let point = MirrorCommand.parseTypedPoint(value, base: .zero) else {
                processor.commandPrompt = "Invalid point. Specify break point:"
                return .handled
            }
            return applyAtPoint(
                target: target, point: point,
                engine: engine, processor: processor)
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        var options: [FeatureCommandTextOption] = []
        switch step {
        case .askSecond:
            options.append(.init(
                value: "F", title: "First point", aliases: ["FIRST"],
                description: "Re-specify the first break point"))
        default:
            break
        }
        if operationsInSession > 0 {
            options.append(.init(
                value: "U", title: "Undo", aliases: ["UNDO"],
                description: "Revert the last break in this session"))
        }
        return options.filter { $0.matches(input) }
    }

    // MARK: - Execution

    /// Break at one point with no gap (BREAKATPOINT), then repeat.
    private func applyAtPoint(
        target: UUID, point: Vector3,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let outcome = engine.document.breakEntity(
            handle: target, firstWorld: point, secondWorld: point)
        guard outcome.broken + outcome.removed > 0 else {
            processor.commandPrompt =
                "\(outcome.message ?? "Nothing broken.") Select object:"
            step = .selectObject
            print("[CAD] \(commandName): \(outcome.message ?? "nothing broken")")
            return .handled
        }
        operationsInSession += 1
        afterApply(outcome: outcome, engine: engine)
        step = .selectObject
        processor.commandPrompt = "Select object:"
        print("[CAD] \(commandName): \(outcome.message ?? "broke the object")")
        return .handled
    }

    /// Erase the span between two points (BREAK), then exit single-shot.
    private func apply(
        target: UUID, first: Vector3, second: Vector3,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let outcome = engine.document.breakEntity(
            handle: target, firstWorld: first, secondWorld: second)
        guard outcome.broken + outcome.removed > 0 else {
            // Rejected or degenerate: stay in the flow (BREAK exits only
            // after a successful break).
            if outcome.lockedSkipped > 0 || outcome.projectedSkipped > 0 {
                processor.commandPrompt =
                    "\(outcome.message ?? "Nothing broken.") Select object:"
                step = .selectObject
            } else {
                processor.commandPrompt =
                    "\(outcome.message ?? "Nothing broken.") " +
                    "Specify second break point or [First point]:"
            }
            print("[CAD] BREAK: \(outcome.message ?? "nothing broken")")
            return .handled
        }
        operationsInSession += 1
        afterApply(outcome: outcome, engine: engine)
        processor.commandPrompt = nil
        step = .selectObject
        print("[CAD] BREAK: \(outcome.message ?? "broke the object")")
        return .finished
    }

    /// Shared post-apply bookkeeping: reselect the changed objects and
    /// refresh the render state (MirrorCommand idiom).
    private func afterApply(
        outcome: CADDocument.BreakOutcome, engine: PhrostEngine
    ) {
        engine.cadSelection.clearSelection()
        let survivors = outcome.changedHandles.filter {
            engine.document.entity(for: $0) != nil
        }
        for handle in survivors {
            engine.cadSelection.addToSelection(handle)
        }
        engine.interaction.cachedGripGeneration = -1
        engine.document.invalidateEntityGrid()
        engine.tabManager.markActiveDirty()
    }

    private var commandName: String {
        isBreakAtPoint ? "BREAKATPOINT" : "BREAK"
    }

    private func performUndo(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard operationsInSession > 0 else {
            processor.commandPrompt = "Nothing to undo in this \(commandName) session."
            return .handled
        }
        engine.document.undo()
        operationsInSession -= 1
        engine.cadSelection.clearSelection()
        step = .selectObject
        processor.commandPrompt = "Undid break. Select object:"
        return .handled
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
        let ghostCol = makeCol32(0, 220, 255, 200)
        switch step {
        case .askSecond(let target, let first):
            // Rubber band from the first break point to the cursor.
            ImDrawListAddLine(
                drawList, screen(first), screen(currentMouse),
                makeCol32(255, 200, 0, 230), 1.5)
            guard let entity = engine.document.entity(for: target) else { return }
            drawBreakGhost(
                drawList: drawList, screen: screen, entity: entity,
                first: first, second: currentMouse,
                ghostCol: ghostCol, engine: engine)
        case .askBreakPoint(let target):
            guard let entity = engine.document.entity(for: target) else { return }
            drawBreakGhost(
                drawList: drawList, screen: screen, entity: entity,
                first: currentMouse, second: currentMouse,
                ghostCol: ghostCol, engine: engine)
            // X marker at the pending break point.
            let c = screen(currentMouse)
            let r: Float = 6
            ImDrawListAddLine(
                drawList, ImVec2(x: c.x - r, y: c.y - r),
                ImVec2(x: c.x + r, y: c.y + r),
                makeCol32(255, 200, 0, 230), 1.5)
            ImDrawListAddLine(
                drawList, ImVec2(x: c.x - r, y: c.y + r),
                ImVec2(x: c.x + r, y: c.y - r),
                makeCol32(255, 200, 0, 230), 1.5)
        default:
            return
        }
    }

    /// Ghost of the kept pieces under the pending break (StretchCommand
    /// ghost idiom): pure `BreakGeometryEngine` solve, tessellated in
    /// world space, never mutating the document.
    private func drawBreakGhost(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        screen: (Vector3) -> ImVec2,
        entity: CADEntity,
        first: Vector3,
        second: Vector3,
        ghostCol: UInt32,
        engine: PhrostEngine
    ) {
        let kept: [[CADPrimitive]]
        switch BreakGeometryEngine.split(
            entity: entity, firstWorld: first, secondWorld: second)
        {
        case .singlePiece(let prims):
            kept = [prims]
        case .twoPieces(let a, let b):
            kept = [a, b]
        case .unchanged, .removeObject, .reject:
            return
        }
        for prims in kept {
            for primitive in prims {
                for strip in StretchCommand.tessellatedWorldStrips(
                    primitive, transform: entity.transform) {
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
        _ = engine
    }
}

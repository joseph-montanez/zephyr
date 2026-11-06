// Sources/ZephyrCore/Commands/ExtendCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel
import ZephyrLisp

// =========================================================================
// MARK: - ExtendCommand
//
// EXTEND (alias EX) — AutoCAD-style extension to boundary edges.
//
// Flow: the command prints the Current settings line (Projection from
// PROJMODE, Edge from EDGEMODE), then Standard mode runs boundary picking
// (the same pick/box loop + pre-selection adoption as TRIM: picks toggle,
// empty click starts a box, Enter commits or takes <select all>), while
// Quick mode (TRIMEXTENDMODE=1, shared with TRIM via TrimCommand) skips
// straight to the extend prompt with everything visible as boundary.
//
// Extend prompt: "Select object to extend or shift-select to trim or
// [Cutting edges/Fence/Crossing/Mode/Project/Edge/Undo]" (Quick omits
// Edge). In Quick mode an empty-space press arms a freehand path (drag +
// release extends via fence, plain click arms a two-point fence); C forces
// a crossing box. Sub-flows: Fence (first/next point or [Undo], Enter executes,
// Undo drops the last fence point), Crossing (two corners; candidates are
// ordered clockwise from the first corner), Cutting edges (back to boundary
// picking), Mode (explicit [Quick/Standard] entry sets TRIMEXTENDMODE and
// recompiles), Project (explicit [None/UCS/View] entry, default UCS, sets
// PROJMODE; every intersection already resolves in the UCS XY plane in 2D
// parity), Edge (Standard only; explicit [Extend/No extend] entry sets
// EDGEMODE), Undo (reverts the last extension in-session via an operations
// counter), and Shift-pick (trims through the existing trim solvers with
// the same boundary set).
//
// The extend rule lives in TrimGeometryEngine: the nearest-boundary hit
// along the target natural path for the end nearest the pick; EDGEMODE=0
// intersects boundaries as built, EDGEMODE=1 lets them extend naturally.
// Boundaries always exclude the target's own edges and are recompiled
// after every op; a miss stays in the command with a message.
// =========================================================================

@MainActor
public final class ExtendCommand: FeatureCommand {

    // MARK: - State Machine

    private enum ExtendStep {
        /// Picking boundary edges (Standard): click toggles, empty click boxes.
        case selectBoundaries
        /// Interactive box selection of boundary edges.
        case boundaryBoxSelecting(startWorld: Vector3, startScreen: SDL_FPoint)
        /// Picking objects to extend (shift-click trims).
        case selectExtendTarget
        /// Interactive box selection to batch-extend.
        case targetBoxSelecting(startWorld: Vector3, startScreen: SDL_FPoint)
        /// Forced crossing: waiting for the first corner.
        case crossingFirst
        /// Forced crossing: waiting for the opposite corner.
        case crossingSecond(startWorld: Vector3, startScreen: SDL_FPoint)
        /// Interactive fence: clicks append points, Enter executes.
        case fenceSelecting(points: [Vector3])
        /// Quick-mode press-drag: empty-space press arms a freehand path,
        /// resolved on release (drag extends via fence, plain click arms a
        /// two-point fence). AutoCAD Quick parity (TRIM idiom).
        case freehandSelecting(points: [Vector3], startScreen: SDL_FPoint)
        /// Quick-mode two-point fence: first empty click is armed, the second
        /// click executes a single fence segment.
        case fenceTwoPoint(first: Vector3)
        /// Explicit mode entry [Quick/Standard].
        case askMode
        /// Explicit projection entry [None/UCS/View].
        case askProject
        /// Explicit implied-edge entry [Extend/No extend] (Standard only).
        case askEdge
    }

    // MARK: - Stored State

    private var active: Bool = true
    private var currentMode: TrimCommand.TrimMode = TrimCommand.preferredMode
    private var step: ExtendStep = .selectBoundaries
    /// Step to return to after an askMode/askProject/askEdge sub-prompt.
    private var askReturn: ExtendStep = .selectExtendTarget

    /// Handles of entities explicitly selected as boundary edges.
    private var selectedBoundaryHandles: Set<UUID> = []

    /// Compiled boundary edges (same provenance-tracked compilation as TRIM,
    /// so each extend can exclude the target's own edges).
    private var cachedBoundaries = TrimGeometryEngine.TrimCuttingEdges.empty

    /// Number of operations executed in this active session (in-session undo).
    private var operationsInSession: Int = 0

    /// Current mouse position in world space.
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    /// Current mouse position in screen space.
    private var currentMouseScreenX: Float = 0
    private var currentMouseScreenY: Float = 0

    public init() {}

    // MARK: - Prompts

    private var extendPrompt: String {
        if currentMode == .quick {
            return "Select object to extend or shift-select to trim or [Cutting edges/Fence/Crossing/Mode/Project/Undo]:"
        }
        return "Select object to extend or shift-select to trim or [Cutting edges/Fence/Crossing/Mode/Project/Edge/Undo]:"
    }

    private var boundaryPrompt: String {
        if selectedBoundaryHandles.isEmpty {
            return "Select boundary edges ... Select objects or <select all>:"
        }
        return "Select boundary edges: \(selectedBoundaryHandles.count) selected. (Press Enter to finish, or click empty space to box select)"
    }

    // MARK: - FeatureCommand Conformance

    public var isSnappingEnabled: Bool {
        if case .fenceSelecting = step { return true }
        return false
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        if case .fenceSelecting(let points) = step {
            return points
        }
        return []
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = true
        operationsInSession = 0
        currentMode = TrimCommand.preferredMode
        selectedBoundaryHandles.removeAll()
        askReturn = .selectExtendTarget
        print("[CAD] EXTEND: \(TrimCommand.currentSettingsLine(processor: processor))")

        // Noun/verb pre-selection (PICKFIRST, TRIM idiom): when on,
        // pre-selected objects become the only boundary edges, even in
        // Quick mode. When off, the selection set is left intact.
        let preselected = engine.cadSelection.selectedHandles.filter { handle in
            guard let entity = engine.document.entity(for: handle) else { return false }
            guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { return false }
            return entity.blockID == nil
        }

        switch TrimCommand.startDecision(
            pickFirst: TrimCommand.readPickFirst(processor: processor),
            mode: currentMode, hasPreselection: !preselected.isEmpty
        ) {
        case .adoptPreselected:
            selectedBoundaryHandles = Set(preselected)
            engine.cadSelection.clearSelection()
            recompileBoundaries(in: engine.document)
            step = .selectExtendTarget
            processor.commandPrompt =
                "Boundary edge(s) selected (\(selectedBoundaryHandles.count)). \(extendPrompt)"
        case .promptForEdges:
            selectedBoundaryHandles.removeAll()
            step = .selectBoundaries
            processor.commandPrompt = boundaryPrompt
        case .allEdges:
            selectedBoundaryHandles.removeAll()
            recompileBoundaries(in: engine.document)
            step = .selectExtendTarget
            processor.commandPrompt = extendPrompt
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = false
        step = .selectBoundaries
        selectedBoundaryHandles.removeAll()
        cachedBoundaries = .empty
        processor.commandPrompt = nil
    }

    // MARK: - Mouse Click Handling

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard active else { return .finished }

        let rawScreenX = engine.interaction.lastMouseX
        let rawScreenY = engine.interaction.lastMouseY
        let (rawWX, rawWY) = engine.camera.screenToWorld(
            screenX: Float(rawScreenX), screenY: Float(rawScreenY),
            windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let rawClick = Vector3(x: rawWX, y: rawWY, z: 0)
        let doc = engine.document

        switch step {

        // ── Phase 1: Selecting Boundary Edges (Standard) ──
        case .selectBoundaries:
            if let hitHandle = CADHitTesting.hitTest(
                worldX: rawWX, worldY: rawWY,
                document: doc,
                threshold: 12.0 / engine.camera.zoom,
                simplifyComplexBlocks: false
            ), let entity = doc.entity(for: hitHandle), entity.blockID == nil {
                if selectedBoundaryHandles.contains(hitHandle) {
                    selectedBoundaryHandles.remove(hitHandle)
                } else {
                    selectedBoundaryHandles.insert(hitHandle)
                }
                recompileBoundaries(in: doc)
                processor.commandPrompt = boundaryPrompt
                return .handled
            } else {
                step = .boundaryBoxSelecting(
                    startWorld: rawClick,
                    startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
                processor.commandPrompt = "Specify opposite corner:"
                return .handled
            }

        case .boundaryBoxSelecting(let startWorld, let startScreen):
            let minX = min(startWorld.x, rawClick.x)
            let maxX = max(startWorld.x, rawClick.x)
            let minY = min(startWorld.y, rawClick.y)
            let maxY = max(startWorld.y, rawClick.y)
            let isCrossing = Float(rawScreenX) < startScreen.x
            let style: CADSelectionManager.RectSelectStyle = isCrossing ? .crossing : .window

            let handles = CADRectSelect.handlesInRect(
                worldX: minX, worldY: minY,
                worldW: maxX - minX, worldH: maxY - minY,
                document: doc, style: style)

            for h in handles {
                if let ent = doc.entity(for: h), ent.blockID == nil,
                   let layer = doc.layer(for: ent.layerID), layer.isVisible {
                    selectedBoundaryHandles.insert(h)
                }
            }

            recompileBoundaries(in: doc)
            step = .selectBoundaries
            processor.commandPrompt = boundaryPrompt
            return .handled

        // ── Phase 2: Selecting Extend Targets ──
        case .selectExtendTarget:
            if let hitHandle = CADHitTesting.hitTest(
                worldX: rawWX, worldY: rawWY,
                document: doc,
                threshold: 12.0 / engine.camera.zoom,
                simplifyComplexBlocks: false
            ) {
                // Shift-pick trims through the existing trim solvers with the
                // same boundary set (TRIM handshake mirror).
                if engine.io?.pointee.KeyShift ?? false {
                    let trimmed = performSingleShiftTrim(
                        on: hitHandle, rawClick: rawClick, engine: engine, processor: processor)
                    if trimmed {
                        processor.commandPrompt = "Trimmed. \(extendPrompt)"
                    }
                    return .handled
                }
                let success = performSingleExtend(
                    on: hitHandle, rawClick: rawClick, engine: engine, processor: processor)
                if success {
                    processor.commandPrompt = "Extended. \(extendPrompt)"
                }
                return .handled
            } else {
                if currentMode == .quick {
                    // Quick mode (AutoCAD parity): arm a freehand path. A
                    // press-drag extends everything the path crosses on
                    // release; a plain click arms a two-point fence instead.
                    step = .freehandSelecting(
                        points: [rawClick],
                        startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
                    processor.commandPrompt = "Drag to extend with a freehand path, or click a second point for a fence:"
                    return .handled
                }
                step = .targetBoxSelecting(
                    startWorld: rawClick,
                    startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
                processor.commandPrompt = "Specify opposite corner:"
                return .handled
            }

        case .targetBoxSelecting(let startWorld, let startScreen):
            let minX = min(startWorld.x, rawClick.x)
            let maxX = max(startWorld.x, rawClick.x)
            let minY = min(startWorld.y, rawClick.y)
            let maxY = max(startWorld.y, rawClick.y)
            // Direction decides window vs crossing (TRIM idiom): a drag to
            // the left of the anchor is a crossing selection.
            let style: CADSelectionManager.RectSelectStyle =
                (Float(rawScreenX) < startScreen.x) ? .crossing : .window

            let (extended, locked) = performBoxExtend(
                boxMin: Vector3(x: minX, y: minY, z: 0),
                boxMax: Vector3(x: maxX, y: maxY, z: 0),
                style: style, firstCorner: startWorld,
                engine: engine, processor: processor)

            step = .selectExtendTarget
            if extended > 0 {
                processor.commandPrompt = "\(extended) object(s) extended. \(extendPrompt)"
            } else if locked > 0 {
                processor.commandPrompt = "\(locked) object(s) on locked layers skipped. \(extendPrompt)"
            } else {
                processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
            }
            return .handled

        case .crossingFirst:
            step = .crossingSecond(
                startWorld: rawClick,
                startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
            processor.commandPrompt = "Specify opposite corner:"
            return .handled

        case .crossingSecond(let startWorld, _):
            let minX = min(startWorld.x, rawClick.x)
            let maxX = max(startWorld.x, rawClick.x)
            let minY = min(startWorld.y, rawClick.y)
            let maxY = max(startWorld.y, rawClick.y)

            let (extended, locked) = performBoxExtend(
                boxMin: Vector3(x: minX, y: minY, z: 0),
                boxMax: Vector3(x: maxX, y: maxY, z: 0),
                style: .crossing, firstCorner: startWorld,
                engine: engine, processor: processor)

            step = .selectExtendTarget
            if extended > 0 {
                processor.commandPrompt = "\(extended) object(s) extended. \(extendPrompt)"
            } else if locked > 0 {
                processor.commandPrompt = "\(locked) object(s) on locked layers skipped. \(extendPrompt)"
            } else {
                processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
            }
            return .handled

        case .fenceSelecting(var points):
            points.append(rawClick)
            step = .fenceSelecting(points: points)
            processor.commandPrompt = "Specify next fence point or [Undo] (\(points.count) points):"
            return .handled

        case .freehandSelecting:
            // Mid-press extra press (e.g. multi-touch): hold the armed path;
            // the release resolves it.
            return .handled

        case .fenceTwoPoint(let first):
            let fenceCount = performFenceExtend(
                points: [first, rawClick], engine: engine, processor: processor)
            step = .selectExtendTarget
            if fenceCount > 0 {
                processor.commandPrompt = "\(fenceCount) object(s) extended by fence. \(extendPrompt)"
            } else {
                processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
            }
            return .handled

        case .askMode, .askProject, .askEdge:
            processor.commandPrompt = askPromptForCurrentStep(processor: processor)
            return .handled
        }
    }

    // MARK: - Mouse Motion

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
        currentMouseScreenX = Float(engine.interaction.lastMouseX)
        currentMouseScreenY = Float(engine.interaction.lastMouseY)
        // Grow the armed Quick freehand path (TRIM idiom).
        if case .freehandSelecting(var points, let startScreen) = step {
            if let last = points.last {
                let minSpacing = 4.0 / max(Double(engine.camera.zoom), 0.001)
                let dx = worldX - last.x
                let dy = worldY - last.y
                if hypot(dx, dy) >= minSpacing {
                    points.append(Vector3(x: worldX, y: worldY, z: 0))
                    step = .freehandSelecting(points: points, startScreen: startScreen)
                }
            }
        }
    }

    public func handleMouseUp(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard active else { return .finished }
        switch step {
        case .freehandSelecting(let points, let startScreen):
            let releaseScreenX = Float(engine.interaction.lastMouseX)
            let releaseScreenY = Float(engine.interaction.lastMouseY)
            let dragPx = hypot(
                releaseScreenX - startScreen.x, releaseScreenY - startScreen.y)
            let threshPx = engine.interaction.pressDragThresholdPixels
                * max(engine.currentDpiScale, 1.0)
            if dragPx > threshPx, points.count >= 2 {
                // Deliberate press-drag: extend everything the path crosses.
                var path = points
                path.append(Vector3(x: worldX, y: worldY, z: 0))
                let count = performFenceExtend(
                    points: path, engine: engine, processor: processor)
                step = .selectExtendTarget
                if count > 0 {
                    processor.commandPrompt = "\(count) object(s) extended by fence. \(extendPrompt)"
                } else {
                    processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
                }
                return .handled
            }
            // Plain click in empty space: arm a two-point fence.
            step = .fenceTwoPoint(
                first: points.first ?? Vector3(x: worldX, y: worldY, z: 0))
            processor.commandPrompt = "Specify second fence point:"
            return .handled
        default:
            return .continue
        }
    }

    // MARK: - Key Down Handling

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            switch step {
            case .boundaryBoxSelecting:
                step = .selectBoundaries
                processor.commandPrompt = boundaryPrompt
                return .handled
            case .targetBoxSelecting, .fenceSelecting, .freehandSelecting, .fenceTwoPoint, .crossingFirst, .crossingSecond:
                step = .selectExtendTarget
                processor.commandPrompt = extendPrompt
                return .handled
            case .askMode, .askProject, .askEdge:
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case .selectBoundaries, .selectExtendTarget:
                active = false
                return .finished
            }

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER, SDL_SCANCODE_SPACE:
            switch step {
            case .selectBoundaries:
                recompileBoundaries(in: engine.document)
                step = .selectExtendTarget
                if selectedBoundaryHandles.isEmpty {
                    processor.commandPrompt = "All objects selected as boundary edges. \(extendPrompt)"
                } else {
                    processor.commandPrompt =
                        "\(selectedBoundaryHandles.count) boundary edge(s) selected. \(extendPrompt)"
                }
                return .handled

            case .fenceSelecting(let points):
                if points.count >= 2 {
                    let count = performFenceExtend(
                        points: points, engine: engine, processor: processor)
                    if count > 0 {
                        processor.commandPrompt = "\(count) object(s) extended by fence. \(extendPrompt)"
                    } else {
                        processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
                    }
                } else {
                    processor.commandPrompt = "Fence needs at least two points. \(extendPrompt)"
                }
                step = .selectExtendTarget
                return .handled

            case .crossingFirst, .fenceTwoPoint:
                step = .selectExtendTarget
                processor.commandPrompt = extendPrompt
                return .handled

            case .crossingSecond(let startWorld, _):
                let cursor = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
                let minX = min(startWorld.x, cursor.x)
                let maxX = max(startWorld.x, cursor.x)
                let minY = min(startWorld.y, cursor.y)
                let maxY = max(startWorld.y, cursor.y)
                let (extended, _) = performBoxExtend(
                    boxMin: Vector3(x: minX, y: minY, z: 0),
                    boxMax: Vector3(x: maxX, y: maxY, z: 0),
                    style: .crossing, firstCorner: startWorld,
                    engine: engine, processor: processor)
                step = .selectExtendTarget
                if extended > 0 {
                    processor.commandPrompt = "\(extended) object(s) extended. \(extendPrompt)"
                } else {
                    processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
                }
                return .handled

            case .askMode, .askEdge:
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled

            case .askProject:
                TrimCommand.setProjectionMode(1, engine: engine, processor: processor)
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled

            case .selectExtendTarget:
                active = false
                return .finished

            default:
                return .continue
            }

        case SDL_SCANCODE_F where isWaitingForTarget:
            step = .fenceSelecting(points: [])
            processor.commandPrompt = "Specify first fence point or [Undo]:"
            return .handled

        case SDL_SCANCODE_C where isWaitingForTarget:
            step = .crossingFirst
            processor.commandPrompt = "Specify first corner:"
            return .handled

        case SDL_SCANCODE_E where isWaitingForTarget:
            askReturn = .selectExtendTarget
            step = .selectBoundaries
            processor.commandPrompt = boundaryPrompt
            return .handled

        case SDL_SCANCODE_M where isWaitingForTarget:
            askReturn = .selectExtendTarget
            step = .askMode
            processor.commandPrompt = askPromptForCurrentStep(processor: processor)
            return .handled

        case SDL_SCANCODE_P where isWaitingForTarget:
            askReturn = .selectExtendTarget
            step = .askProject
            processor.commandPrompt = askPromptForCurrentStep(processor: processor)
            return .handled

        case SDL_SCANCODE_U where isWaitingForTarget:
            return performUndo(engine: engine, processor: processor)

        default:
            return .continue
        }
    }

    private var isWaitingForTarget: Bool {
        if case .selectExtendTarget = step { return true }
        return false
    }

    private func promptForStep(_ step: ExtendStep) -> String {
        switch step {
        case .selectBoundaries:
            return boundaryPrompt
        default:
            return extendPrompt
        }
    }

    private func askPromptForCurrentStep(processor: CADCommandProcessor) -> String {
        switch step {
        case .askMode:
            let current = (currentMode == .quick) ? "Quick" : "Standard"
            return "Enter mode [Quick/Standard] <\(current)>:"
        case .askProject:
            let current = TrimCommand.projectionModeName(
                TrimCommand.readProjectionMode(processor: processor))
            return "Enter projection option [None/UCS/View] <\(current)>:"
        case .askEdge:
            let current = TrimCommand.edgeModeName(
                TrimCommand.readEdgeMode(processor: processor))
            return "Enter implied edge mode [Extend/No extend] <\(current)>:"
        default:
            return extendPrompt
        }
    }

    // MARK: - Command Text Handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()

        switch step {
        case .selectBoundaries:
            if value.isEmpty {
                recompileBoundaries(in: engine.document)
                step = .selectExtendTarget
                if selectedBoundaryHandles.isEmpty {
                    processor.commandPrompt = "All objects selected as boundary edges. \(extendPrompt)"
                } else {
                    processor.commandPrompt =
                        "\(selectedBoundaryHandles.count) boundary edge(s) selected. \(extendPrompt)"
                }
                return .handled
            } else if upper == "M" || upper == "MODE" {
                askReturn = .selectBoundaries
                step = .askMode
                processor.commandPrompt = askPromptForCurrentStep(processor: processor)
                return .handled
            }
            return .continue

        case .selectExtendTarget:
            switch upper {
            case "F", "FENCE":
                step = .fenceSelecting(points: [])
                processor.commandPrompt = "Specify first fence point or [Undo]:"
                return .handled

            case "C", "CROSSING":
                step = .crossingFirst
                processor.commandPrompt = "Specify first corner:"
                return .handled

            case "E", "CUTTING", "EDGES", "CUTTING EDGES":
                askReturn = .selectExtendTarget
                step = .selectBoundaries
                processor.commandPrompt = boundaryPrompt
                return .handled

            case "M", "MODE":
                askReturn = .selectExtendTarget
                step = .askMode
                processor.commandPrompt = askPromptForCurrentStep(processor: processor)
                return .handled

            case "P", "PROJECT":
                askReturn = .selectExtendTarget
                step = .askProject
                processor.commandPrompt = askPromptForCurrentStep(processor: processor)
                return .handled

            case "EDGE":
                if currentMode == .quick {
                    processor.commandPrompt =
                        "The Edge option is available in Standard mode only. \(extendPrompt)"
                    return .handled
                }
                askReturn = .selectExtendTarget
                step = .askEdge
                processor.commandPrompt = askPromptForCurrentStep(processor: processor)
                return .handled

            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)

            default:
                break
            }
            // A typed point acts as an extend pick at that location.
            if let point = MirrorCommand.parseTypedPoint(value, base: .zero) {
                let success = performSingleExtendAtPoint(
                    point, engine: engine, processor: processor)
                if success {
                    processor.commandPrompt = "Extended. \(extendPrompt)"
                }
                return .handled
            }
            return .continue

        case .fenceSelecting(var points):
            if value.isEmpty {
                if points.count >= 2 {
                    let count = performFenceExtend(
                        points: points, engine: engine, processor: processor)
                    if count > 0 {
                        processor.commandPrompt = "\(count) object(s) extended by fence. \(extendPrompt)"
                    } else {
                        processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
                    }
                } else {
                    processor.commandPrompt = "Fence needs at least two points. \(extendPrompt)"
                }
                step = .selectExtendTarget
                return .handled
            }
            if upper == "U" || upper == "UNDO" {
                if points.isEmpty {
                    processor.commandPrompt = "No fence points to undo. Specify first fence point or [Undo]:"
                    return .handled
                }
                points.removeLast()
                step = .fenceSelecting(points: points)
                if points.isEmpty {
                    processor.commandPrompt = "Specify first fence point or [Undo]:"
                } else {
                    processor.commandPrompt =
                        "Specify next fence point or [Undo] (\(points.count) points):"
                }
                return .handled
            }
            return .continue

        case .crossingFirst:
            if value.isEmpty {
                step = .selectExtendTarget
                processor.commandPrompt = extendPrompt
                return .handled
            }
            return .continue

        case .fenceTwoPoint:
            if value.isEmpty {
                step = .selectExtendTarget
                processor.commandPrompt = extendPrompt
                return .handled
            }
            return .continue

        case .crossingSecond:
            if value.isEmpty {
                return handleKeyDown(
                    scancode: SDL_SCANCODE_RETURN, engine: engine, processor: processor)
            }
            return .continue

        case .askMode:
            switch upper {
            case "":
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "Q", "QUICK":
                applyMode(.quick, engine: engine, processor: processor)
                return .handled
            case "S", "STANDARD":
                applyMode(.standard, engine: engine, processor: processor)
                return .handled
            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                processor.commandPrompt =
                    "Invalid mode. \(askPromptForCurrentStep(processor: processor))"
                return .handled
            }

        case .askProject:
            switch upper {
            case "":
                TrimCommand.setProjectionMode(1, engine: engine, processor: processor)
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "N", "NONE":
                TrimCommand.setProjectionMode(0, engine: engine, processor: processor)
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "U", "UCS":
                TrimCommand.setProjectionMode(1, engine: engine, processor: processor)
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "V", "VIEW":
                TrimCommand.setProjectionMode(2, engine: engine, processor: processor)
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                processor.commandPrompt =
                    "Invalid projection option. \(askPromptForCurrentStep(processor: processor))"
                return .handled
            }

        case .askEdge:
            switch upper {
            case "":
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "E", "EXTEND":
                TrimCommand.setEdgeMode(1, engine: engine, processor: processor)
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "N", "NO", "NO EXTEND", "NOEXTEND":
                TrimCommand.setEdgeMode(0, engine: engine, processor: processor)
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                processor.commandPrompt =
                    "Invalid edge mode. \(askPromptForCurrentStep(processor: processor))"
                return .handled
            }

        default:
            break
        }

        return .continue
    }

    // MARK: - Command Text Options

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        switch step {
        case .selectBoundaries:
            return [
                .init(value: "ALL", title: "Select all", aliases: ["A"]),
                .init(value: "M", title: "Mode", aliases: ["MODE"], description: "Quick vs Standard boundary mode")
            ].filter { $0.matches(input) }
        case .selectExtendTarget:
            var options: [FeatureCommandTextOption] = [
                .init(value: "F", title: "Fence", aliases: ["FENCE"], description: "Extend everything crossed by a fence"),
                .init(value: "C", title: "Crossing", aliases: ["CROSSING"], description: "Crossing-window extend"),
                .init(value: "E", title: "Cutting edges", aliases: ["CUTTING", "EDGES"], description: "Change boundary edges"),
                .init(value: "M", title: "Mode", aliases: ["MODE"], description: "Quick vs Standard mode"),
                .init(value: "P", title: "Project", aliases: ["PROJECT"], description: "Projection option (None/UCS/View)"),
            ]
            if currentMode == .standard {
                options.append(.init(
                    value: "EDGE", title: "Edge", aliases: [],
                    description: "Implied edge mode (Extend/No extend)"))
            }
            options.append(.init(
                value: "U", title: "Undo", aliases: ["UNDO"],
                description: "Revert the last extend in this session"))
            return options.filter { $0.matches(input) }
        case .fenceSelecting:
            return [
                .init(value: "U", title: "Undo", aliases: ["UNDO"],
                      description: "Drop the last fence point")
            ].filter { $0.matches(input) }
        case .askMode:
            return [
                .init(value: "Q", title: "Quick", aliases: ["QUICK"], description: "Quick mode: everything is a boundary"),
                .init(value: "S", title: "Standard", aliases: ["STANDARD"], description: "Standard mode: pick boundary edges"),
                .init(value: "U", title: "Undo", aliases: ["UNDO"], description: "Revert the last extend"),
            ].filter { $0.matches(input) }
        case .askProject:
            return [
                .init(value: "N", title: "None", aliases: ["NONE"], description: "No projection"),
                .init(value: "U", title: "UCS", aliases: ["UCS"], description: "Project onto the UCS XY plane"),
                .init(value: "V", title: "View", aliases: ["VIEW"], description: "Project onto the view plane"),
                .init(value: "UNDO", title: "Undo", aliases: [], description: "Revert the last extend"),
            ].filter { $0.matches(input) }
        case .askEdge:
            return [
                .init(value: "E", title: "Extend", aliases: ["EXTEND"], description: "Extend boundaries to meet"),
                .init(value: "N", title: "No extend", aliases: ["NO", "NO EXTEND"], description: "Use boundaries as built"),
                .init(value: "U", title: "Undo", aliases: ["UNDO"], description: "Revert the last extend"),
            ].filter { $0.matches(input) }
        default:
            return []
        }
    }

    // MARK: - Extend Execution

    /// Extend the object under a typed point (command-line pick).
    private func performSingleExtendAtPoint(
        _ point: Vector3, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        let threshold = 12.0 / max(engine.camera.zoom, 0.001)
        guard let handle = CADHitTesting.hitTest(
            worldX: point.x, worldY: point.y,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: false
        ) else {
            processor.commandPrompt = "No object found there. \(extendPrompt)"
            return false
        }
        return performSingleExtend(
            on: handle, rawClick: point, engine: engine, processor: processor)
    }

    /// Extend one object: the end nearest the pick runs along its natural
    /// path to the nearest boundary.
    private func performSingleExtend(
        on hitHandle: UUID,
        rawClick: Vector3,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        let doc = engine.document
        guard let entity = doc.entity(for: hitHandle) else { return false }
        guard entity.blockID == nil else {
            processor.commandPrompt = "Cannot extend block references. Explode them first."
            return false
        }
        guard !entity.isViewportProjected else {
            processor.commandPrompt = "Viewport copies cannot be extended."
            return false
        }
        if let layer = doc.layer(for: entity.layerID), layer.isLocked {
            processor.commandPrompt = "The object is on a locked layer."
            return false
        }

        let preSnapshot = doc.snapshot()
        let edges = cachedBoundaries.excluding(hitHandle)
        let edgeMode = TrimCommand.readEdgeMode(processor: processor)
        let (newGeom, modified, errorMsg) = TrimGeometryEngine.extendEntity(
            entity: entity, pickWorld: rawClick, boundaries: edges, edgeMode: edgeMode)

        if let errorMsg {
            processor.commandPrompt = "\(errorMsg) \(extendPrompt)"
            return false
        }

        guard modified, let geom = newGeom else {
            processor.commandPrompt = "No boundary found to extend to. \(extendPrompt)"
            return false
        }

        doc.pushUndo(preSnapshot)
        operationsInSession += 1
        doc.updateEntityGeometryLive(for: hitHandle, geometry: geom)
        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()
        refreshBoundaryContribution(for: hitHandle, in: doc, deleted: false)
        return true
    }

    /// Shift-pick trim: the existing trim solvers cut with the same boundary
    /// set (TRIM handshake mirror).
    private func performSingleShiftTrim(
        on hitHandle: UUID,
        rawClick: Vector3,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        let doc = engine.document
        guard let entity = doc.entity(for: hitHandle) else { return false }
        guard entity.blockID == nil else {
            processor.commandPrompt = "Cannot trim block references. Explode them first."
            return false
        }

        let preSnapshot = doc.snapshot()
        let edges = cachedBoundaries.excluding(hitHandle)
        let (newGeom, modified, errorMsg) = TrimGeometryEngine.trimEntity(
            entity: entity,
            document: doc,
            criterion: .click(point: rawClick),
            cuttingSegments: edges.segments,
            exactLines: edges.exactLines,
            exactCurves: edges.exactCurves
        )

        if let errorMsg {
            processor.commandPrompt = errorMsg
            return false
        }

        guard modified, let geom = newGeom else {
            processor.commandPrompt = "No valid trim intersection found. Geometry was left unchanged."
            return false
        }

        doc.pushUndo(preSnapshot)
        operationsInSession += 1

        if geom.isEmpty {
            doc.removeEntities(handles: [hitHandle])
            engine.cadSelection.clearSelection()
        } else {
            doc.updateEntityGeometryLive(for: hitHandle, geometry: geom)
        }

        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        refreshBoundaryContribution(for: hitHandle, in: doc, deleted: geom.isEmpty)
        return true
    }

    /// Batch-extend the entities in a box/crossing rect. Candidates run
    /// clockwise from the first corner; each extends toward the end nearest
    /// that corner. One undo entry covers the whole batch (TRIM box idiom).
    private func performBoxExtend(
        boxMin: Vector3, boxMax: Vector3,
        style: CADSelectionManager.RectSelectStyle,
        firstCorner: Vector3,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> (extended: Int, lockedSkipped: Int) {
        let doc = engine.document
        let handles = CADRectSelect.handlesInRect(
            worldX: boxMin.x, worldY: boxMin.y,
            worldW: boxMax.x - boxMin.x, worldH: boxMax.y - boxMin.y,
            document: doc, style: style)
        let ordered = orderClockwiseFromFirstCorner(
            Array(handles), firstCorner: firstCorner,
            boxMin: boxMin, boxMax: boxMax, in: doc)
        let edgeMode = TrimCommand.readEdgeMode(processor: processor)
        let preSnapshot = doc.snapshot()
        var changed: [(UUID, [CADPrimitive])] = []
        var lockedSkipped = 0

        for handle in ordered {
            guard let entity = doc.entity(for: handle) else { continue }
            guard let layer = doc.layer(for: entity.layerID), layer.isVisible else { continue }
            guard entity.blockID == nil else { continue }
            guard !entity.isViewportProjected else { continue }
            guard !layer.isLocked else {
                lockedSkipped += 1
                continue
            }
            let edges = cachedBoundaries.excluding(handle)
            let (newGeom, modified, _) = TrimGeometryEngine.extendEntity(
                entity: entity, pickWorld: firstCorner, boundaries: edges, edgeMode: edgeMode)
            if modified, let geom = newGeom {
                changed.append((handle, geom))
            }
        }

        guard !changed.isEmpty else { return (0, lockedSkipped) }

        doc.pushUndo(preSnapshot)
        operationsInSession += 1
        for (handle, geom) in changed {
            doc.updateEntityGeometryLive(for: handle, geometry: geom)
        }
        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()
        for (handle, _) in changed {
            refreshBoundaryContribution(for: handle, in: doc, deleted: false)
        }
        return (changed.count, lockedSkipped)
    }

    /// Batch-extend everything a fence crosses (the first crossing segment
    /// per target decides the pick). One undo entry covers the batch.
    private func performFenceExtend(
        points: [Vector3],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Int {
        guard points.count >= 2 else { return 0 }
        var fence: [(Vector3, Vector3)] = []
        fence.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            fence.append((points[i], points[i + 1]))
        }
        let doc = engine.document
        let edgeMode = TrimCommand.readEdgeMode(processor: processor)
        let preSnapshot = doc.snapshot()
        var changed: [(UUID, [CADPrimitive])] = []

        for entity in doc.entitiesView {
            let handle = entity.handle
            guard let layer = doc.layer(for: entity.layerID), layer.isVisible else { continue }
            guard entity.blockID == nil else { continue }
            guard !entity.isViewportProjected else { continue }
            guard !layer.isLocked else { continue }
            guard let pick = TrimGeometryEngine.fenceCrossingPick(entity: entity, fence: fence) else {
                continue
            }
            let edges = cachedBoundaries.excluding(handle)
            let (newGeom, modified, _) = TrimGeometryEngine.extendEntity(
                entity: entity, pickWorld: pick, boundaries: edges, edgeMode: edgeMode)
            if modified, let geom = newGeom {
                changed.append((handle, geom))
            }
        }

        guard !changed.isEmpty else { return 0 }

        doc.pushUndo(preSnapshot)
        operationsInSession += 1
        for (handle, geom) in changed {
            doc.updateEntityGeometryLive(for: handle, geometry: geom)
        }
        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()
        for (handle, _) in changed {
            refreshBoundaryContribution(for: handle, in: doc, deleted: false)
        }
        return changed.count
    }

    /// Candidates ordered clockwise from the first corner around the box
    /// center (ambiguous multi-hit resolution for crossing selects).
    private func orderClockwiseFromFirstCorner(
        _ handles: [UUID], firstCorner: Vector3,
        boxMin: Vector3, boxMax: Vector3,
        in doc: CADDocument
    ) -> [UUID] {
        let cx = 0.5 * (boxMin.x + boxMax.x)
        let cy = 0.5 * (boxMin.y + boxMax.y)
        let base = atan2(firstCorner.y - cy, firstCorner.x - cx)
        func key(_ handle: UUID) -> Double {
            guard let entity = doc.entity(for: handle),
                  let box = entity.worldBoundingBox else {
                return Double.greatestFiniteMagnitude
            }
            let ex = 0.5 * (box.min.x + box.max.x)
            let ey = 0.5 * (box.min.y + box.max.y)
            return TrimGeometryEngine.normAngle(base - atan2(ey - cy, ex - cx))
        }
        return handles.sorted {
            let a = key($0), b = key($1)
            if a == b { return $0.uuidString < $1.uuidString }
            return a < b
        }
    }

    private func applyMode(
        _ mode: TrimCommand.TrimMode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMode = mode
        TrimCommand.preferredMode = mode
        recompileBoundaries(in: engine.document)
        if mode == .quick {
            step = .selectExtendTarget
            processor.commandPrompt = extendPrompt
            print("[CAD] EXTEND: mode set to QUICK.")
        } else {
            step = .selectBoundaries
            processor.commandPrompt = boundaryPrompt
            print("[CAD] EXTEND: mode set to STANDARD.")
        }
    }

    private func performUndo(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard operationsInSession > 0 else {
            processor.commandPrompt = "Nothing to undo in this EXTEND session."
            return .handled
        }

        engine.document.undo()
        operationsInSession -= 1
        recompileBoundaries(in: engine.document)
        step = .selectExtendTarget
        processor.commandPrompt = "Undo extend. \(extendPrompt)"
        return .handled
    }

    private func recompileBoundaries(in doc: CADDocument) {
        cachedBoundaries = TrimGeometryEngine.collectCuttingEdges(
            document: doc,
            cuttingHandles: selectedBoundaryHandles.isEmpty ? nil : selectedBoundaryHandles,
            excludedHandle: nil
        )
    }

    /// Splice one entity's new (or removed) geometry into the cached
    /// boundaries instead of recompiling drawing-wide. No-op when the
    /// entity is not part of the boundary set. Undo still recompiles fully.
    private func refreshBoundaryContribution(for handle: UUID, in doc: CADDocument, deleted: Bool) {
        guard selectedBoundaryHandles.isEmpty || selectedBoundaryHandles.contains(handle) else { return }
        if deleted {
            TrimGeometryEngine.removeCuttingEdges(&cachedBoundaries, for: handle)
        } else {
            TrimGeometryEngine.updateCuttingEdges(&cachedBoundaries, for: handle, document: doc)
        }
    }

    // MARK: - Overlay Rendering

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard active else { return }
        guard let drawList = igGetForegroundDrawList_ViewportPtr(nil) else { return }

        // 1. Highlight Boundary Edges (cyan glow, TRIM idiom).
        if !selectedBoundaryHandles.isEmpty {
            let boundaryCol = makeCol32(0, 220, 255, 230)
            for segment in cachedBoundaries.segments {
                let p1 = EngineCameraManager.worldToScreen(worldX: segment.0.x, worldY: segment.0.y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(worldX: segment.1.x, worldY: segment.1.y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), boundaryCol, 2.0)
            }
        }

        // 2. Selection Box Overlay.
        switch step {
        case .boundaryBoxSelecting(let startWorld, let startScreen),
             .targetBoxSelecting(let startWorld, let startScreen),
             .crossingSecond(let startWorld, let startScreen):

            let p1 = EngineCameraManager.worldToScreen(worldX: startWorld.x, worldY: startWorld.y, cam: cam)
            let p3 = EngineCameraManager.worldToScreen(
                worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)

            let minSX = min(p1.x, p3.x)
            let maxSX = max(p1.x, p3.x)
            let minSY = min(p1.y, p3.y)
            let maxSY = max(p1.y, p3.y)

            let p1Draw = ImVec2(x: minSX, y: minSY)
            let p2Draw = ImVec2(x: maxSX, y: minSY)
            let p3Draw = ImVec2(x: maxSX, y: maxSY)
            let p4Draw = ImVec2(x: minSX, y: maxSY)

            let isCrossing = currentMouseScreenX < startScreen.x
            let borderCol: UInt32
            let fillCol: UInt32

            if isCrossing {
                borderCol = makeCol32(64, 220, 80, 240)
                fillCol = makeCol32(64, 180, 80, 45)
            } else {
                borderCol = makeCol32(0, 150, 255, 240)
                fillCol = makeCol32(0, 128, 255, 45)
            }

            ImDrawListAddRectFilled(drawList, p1Draw, p3Draw, fillCol, 0.0, 0)
            ImDrawListAddLine(drawList, p1Draw, p2Draw, borderCol, 1.5)
            ImDrawListAddLine(drawList, p2Draw, p3Draw, borderCol, 1.5)
            ImDrawListAddLine(drawList, p3Draw, p4Draw, borderCol, 1.5)
            ImDrawListAddLine(drawList, p4Draw, p1Draw, borderCol, 1.5)

        // 3. Fence Line Overlay.
        case .fenceSelecting(let points), .freehandSelecting(let points, _):
            let fenceCol = makeCol32(255, 170, 0, 240)
            if !points.isEmpty {
                for i in 0..<(points.count - 1) {
                    let s1 = EngineCameraManager.worldToScreen(worldX: points[i].x, worldY: points[i].y, cam: cam)
                    let s2 = EngineCameraManager.worldToScreen(worldX: points[i+1].x, worldY: points[i+1].y, cam: cam)
                    ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), fenceCol, 2.0)
                }
                if let last = points.last {
                    let sLast = EngineCameraManager.worldToScreen(worldX: last.x, worldY: last.y, cam: cam)
                    let sCur = EngineCameraManager.worldToScreen(
                        worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
                    ImDrawListAddLine(drawList, ImVec2(x: sLast.x, y: sLast.y), ImVec2(x: sCur.x, y: sCur.y), fenceCol, 1.5)
                }
            }

        // 4. Two-point fence rubber band (first point armed, cursor is second).
        case .fenceTwoPoint(let first):
            let fenceCol = makeCol32(255, 170, 0, 240)
            let sFirst = EngineCameraManager.worldToScreen(worldX: first.x, worldY: first.y, cam: cam)
            let sCur = EngineCameraManager.worldToScreen(
                worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: sFirst.x, y: sFirst.y), ImVec2(x: sCur.x, y: sCur.y), fenceCol, 1.5)

        default:
            break
        }

        // 4. Hover ghost: the would-be extension under the cursor.
        if case .selectExtendTarget = step,
           !(engine.io?.pointee.KeyShift ?? false) {
            drawHoverGhost(drawList: drawList, cam: cam, engine: engine)
        }
    }

    /// Ghost of the pending extension under the cursor (BreakCommand ghost
    /// idiom): a pure solver preview, tessellated in world space, never
    /// mutating the document.
    private func drawHoverGhost(
        drawList: UnsafeMutablePointer<ImDrawList>?,
        cam: CameraTransform, engine: PhrostEngine
    ) {
        func screen(_ point: Vector3) -> ImVec2 {
            let s = EngineCameraManager.worldToScreen(
                worldX: point.x, worldY: point.y, cam: cam)
            return ImVec2(x: s.x, y: s.y)
        }
        let pick = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
        guard let hitHandle = CADHitTesting.hitTest(
            worldX: pick.x, worldY: pick.y,
            document: engine.document,
            threshold: 12.0 / engine.camera.zoom,
            simplifyComplexBlocks: false
        ), let entity = engine.document.entity(for: hitHandle),
              entity.blockID == nil, !entity.isViewportProjected else {
            return
        }
        if let layer = engine.document.layer(for: entity.layerID), layer.isLocked { return }
        let edges = cachedBoundaries.excluding(hitHandle)
        let edgeMode = TrimCommand.readEdgeMode(processor: engine.commandProcessor)
        let (newGeom, modified, _) = TrimGeometryEngine.extendEntity(
            entity: entity, pickWorld: pick, boundaries: edges, edgeMode: edgeMode)
        guard modified, let geom = newGeom else { return }
        let ghostCol = makeCol32(0, 220, 255, 200)
        for primitive in geom {
            for strip in TrimGeometryEngine.extendWorldStrips(primitive, transform: entity.transform) {
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

import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel
import ZephyrLisp

// =========================================================================
// MARK: - TrimSettings (TRIMEXTENDMODE sysvar backing)

/// Backing store for the `TRIMEXTENDMODE` sysvar (0 = Standard, 1 = Quick).
///
/// Single source of truth for the TRIM mode, shared by
/// `TrimCommand.preferredMode` and the Lisp `getvar`/`setvar` bridge.
/// Nonisolated (lock-guarded) so the sysvar store can reach it off the main
/// actor; mirrors the `OffsetSettings` sharing pattern.
public enum TrimSettings: Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedMode: Int = 1

    /// 0 = Standard (classic cutting-edge selection),
    /// 1 = Quick (all visible objects act as cutting edges; current AutoCAD default).
    public static var trimExtendMode: Int {
        get { lock.withLock { storedMode } }
        set { lock.withLock { storedMode = (newValue == 0) ? 0 : 1 } }
    }
}

/// Backing store for the `PICKFIRST` sysvar (0 = off, 1 = noun/verb selection).
///
/// Single source of truth shared by TRIM/EXTEND start-up and the Lisp
/// `getvar`/`setvar` bridge. Mirrors the `TrimSettings` sharing pattern.
public enum PickFirstSettings: Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedValue: Int = 1

    /// 0 = ignore pre-selection, 1 = adopt pre-selected objects (AutoCAD default).
    public static var pickFirst: Int {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = (newValue == 0) ? 0 : 1 } }
    }
}

/// Shared TRIM/EXTEND start-up decision: how a command with an optional
/// pre-selection enters, given PICKFIRST and the TRIMEXTENDMODE mode.
///
/// Pure function of its inputs so the noun/verb × mode matrix is unit-testable
/// without an engine harness.
public enum TrimStartDecision: Sendable, Equatable {
    /// PICKFIRST is on and objects were pre-selected: adopt them as the only
    /// cutting/boundary edges and skip the setup prompt (even in Quick mode).
    case adoptPreselected
    /// Standard mode with no adopted pre-selection: prompt for cutting edges.
    case promptForEdges
    /// Quick mode with no adopted pre-selection: all objects act as edges.
    case allEdges
}

// MARK: - TrimCommand
// =========================================================================

/// TRIM — AutoCAD-style trim command supporting cutting edge selection,
/// single-click trimming, crossing/window box trimming, fence trimming,
/// Quick-mode freehand/two-point fence gestures, in-session undo, and
/// on-the-fly option switching.
@MainActor
public final class TrimCommand: FeatureCommand {

    // MARK: - Mode & Enums

    /// Operating mode for the TRIM command.
    public enum TrimMode: String, CaseIterable, Sendable {
        /// Classic AutoCAD: Select cutting edges first (or press Enter for <select all>).
        case standard
        /// Modern AutoCAD: All visible objects act as cutting edges by default.
        case quick
    }

    /// Internal lifecycle step of the TRIM command.
    private enum TrimStep {
        /// Waiting for user to click cutting edges or press Enter to commit.
        case selectCuttingEdges
        /// Interactive box selection to add cutting edges.
        case edgeBoxSelecting(startWorld: Vector3, startScreen: SDL_FPoint)

        /// Waiting for user to click an object to trim, or click empty space to box select.
        case selectTrimTarget
        /// Interactive box selection to batch-trim multiple target objects.
        case targetBoxSelecting(startWorld: Vector3, startScreen: SDL_FPoint)
        /// Interactive polyline fence selection to trim everything crossed by the fence.
        case fenceSelecting(points: [Vector3])
        /// Quick-mode press-drag: empty-space press arms a freehand path,
        /// resolved on release (drag trims via fence, plain click arms a
        /// two-point fence). AutoCAD Quick parity.
        case freehandSelecting(points: [Vector3], startScreen: SDL_FPoint)
        /// Quick-mode two-point fence: first empty click is armed, the second
        /// click executes a single fence segment.
        case fenceTwoPoint(first: Vector3)
        /// Forced crossing (C option): waiting for the first corner.
        case crossingFirst
        /// Forced crossing: waiting for the opposite corner.
        case crossingSecond(startWorld: Vector3, startScreen: SDL_FPoint)

        /// eRase sub-mode: click objects to delete directly without leaving TRIM.
        case eraseSelecting
        /// Interactive box selection for eRase mode.
        case eraseBoxSelecting(startWorld: Vector3, startScreen: SDL_FPoint)
        /// Explicit projection entry [None/UCS/View] (shared EXTEND handshake).
        case askProject
        /// Explicit implied-edge entry [Extend/No extend] (shared EXTEND handshake).
        case askEdge
        /// Explicit mode entry [Quick/Standard] (shared EXTEND handshake).
        case askMode
    }

    // MARK: - Static Configuration

    /// User's preferred TRIM mode across sessions. Defaults to `.quick` (current AutoCAD).
    /// Backed by `TrimSettings.trimExtendMode` (`TRIMEXTENDMODE` sysvar): the single source of truth.
    public static var preferredMode: TrimMode {
        get { TrimSettings.trimExtendMode == 0 ? .standard : .quick }
        set { TrimSettings.trimExtendMode = (newValue == .standard) ? 0 : 1 }
    }

    /// Shared TRIM/EXTEND start-up decision for the noun/verb × mode matrix.
    public static func startDecision(
        pickFirst: Int, mode: TrimMode, hasPreselection: Bool
    ) -> TrimStartDecision {
        if hasPreselection && pickFirst != 0 {
            return .adoptPreselected
        }
        return mode == .standard ? .promptForEdges : .allEdges
    }

    /// Reads PICKFIRST (0 = off, 1 = noun/verb selection); anything else reads as on.
    public static func readPickFirst(processor: CADCommandProcessor) -> Int {
        if case .int(let value) = processor.systemVariable("PICKFIRST"),
           (0...1).contains(value) {
            return value
        }
        return 1
    }

    // MARK: - Projection / Edge (shared EXTEND handshake)

    /// Reads PROJMODE (0 = None, 1 = UCS, 2 = View); anything else reads as UCS.
    /// All intersections already resolve in the UCS XY plane in 2D parity,
    /// so projection is recorded, not computed.
    public static func readProjectionMode(processor: CADCommandProcessor) -> Int {
        if case .int(let value) = processor.systemVariable("PROJMODE"),
           (0...2).contains(value) {
            return value
        }
        return 1
    }

    /// Reads EDGEMODE (0 = No extend, 1 = Extend); anything else reads as No extend.
    public static func readEdgeMode(processor: CADCommandProcessor) -> Int {
        if case .int(let value) = processor.systemVariable("EDGEMODE"),
           (0...1).contains(value) {
            return value
        }
        return 0
    }

    /// Display name for a PROJMODE value.
    public static func projectionModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return "None"
        case 2: return "View"
        default: return "UCS"
        }
    }

    /// Display name for an EDGEMODE value.
    public static func edgeModeName(_ mode: Int) -> String {
        mode == 1 ? "Extend" : "No extend"
    }

    /// "Current settings: Projection=UCS, Edge=No extend" (AutoCAD EXTEND idiom).
    public static func currentSettingsLine(processor: CADCommandProcessor) -> String {
        "Current settings: Projection=\(projectionModeName(readProjectionMode(processor: processor))), Edge=\(edgeModeName(readEdgeMode(processor: processor)))"
    }

    /// Ask prompt for the Project option with the current value as default.
    public static func askProjectPrompt(processor: CADCommandProcessor) -> String {
        "Enter projection option [None/UCS/View] <\(projectionModeName(readProjectionMode(processor: processor)))>:"
    }

    /// Ask prompt for the Edge option with the current value as default.
    public static func askEdgePrompt(processor: CADCommandProcessor) -> String {
        "Enter implied edge mode [Extend/No extend] <\(edgeModeName(readEdgeMode(processor: processor)))>:"
    }

    /// Records PROJMODE (validated 0/1/2 by the caller).
    public static func setProjectionMode(_ mode: Int, engine: PhrostEngine, processor: CADCommandProcessor) {
        _ = processor.lispVars.set("PROJMODE", .int(mode), document: engine.document)
    }

    /// Records EDGEMODE (validated 0/1 by the caller).
    public static func setEdgeMode(_ mode: Int, engine: PhrostEngine, processor: CADCommandProcessor) {
        _ = processor.lispVars.set("EDGEMODE", .int(mode), document: engine.document)
    }

    // MARK: - Mode Prompt Helpers (shared EXTEND handshake)

    /// Ask prompt for the Mode option with the current value as default.
    private func askModePrompt() -> String {
        let current = (currentMode == .quick) ? "Quick" : "Standard"
        return "Enter mode [Quick/Standard] <\(current)>:"
    }

    /// Trim-target prompt (Quick skips cutting-edge selection entirely).
    private var trimTargetPrompt: String {
        "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
    }

    /// Cutting-edge selection prompt.
    private var cuttingEdgePrompt: String {
        "Select cutting edges ... Select objects or <select all>:"
    }

    private func promptForStep(_ step: TrimStep) -> String {
        switch step {
        case .selectCuttingEdges:
            return cuttingEdgePrompt
        case .askMode:
            return askModePrompt()
        default:
            return trimTargetPrompt
        }
    }

    private func applyMode(
        _ mode: TrimMode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMode = mode
        Self.preferredMode = mode
        recompileCuttingSegments(in: engine.document)
        if mode == .quick {
            step = .selectTrimTarget
            processor.commandPrompt = trimTargetPrompt
            print("[CAD] TRIM: mode set to QUICK.")
        } else {
            step = .selectCuttingEdges
            processor.commandPrompt = cuttingEdgePrompt
            print("[CAD] TRIM: mode set to STANDARD.")
        }
    }

    // MARK: - Instance State

    private var active: Bool = true
    private var currentMode: TrimMode = TrimCommand.preferredMode
    private var step: TrimStep = .selectCuttingEdges
    /// Step to return to after an askMode/askProject/askEdge sub-prompt.
    private var askReturn: TrimStep = .selectTrimTarget

    /// Handles of entities explicitly selected as cutting edges. Empty means all visible entities act as cutting edges.
    private var selectedCuttingHandles: Set<UUID> = []

    /// Cached compiled cutting edges (world-space segments, exact lines,
    /// and exact analytical curves) with per-entity provenance, so each
    /// trim can exclude the target's own edges (quick/select-all mode
    /// would otherwise let a curve cut itself).
    private var cachedCuttingEdges = TrimGeometryEngine.TrimCuttingEdges.empty

    /// Number of operations executed in this active session (for in-session undo).
    private var operationsInSession: Int = 0

    /// Current mouse position in world space.
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    /// Current mouse position in screen space.
    private var currentMouseScreenX: Float = 0
    private var currentMouseScreenY: Float = 0

    // MARK: - Init

    public init() {}

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
        currentMode = Self.preferredMode
        askReturn = .selectTrimTarget

        // Noun/verb pre-selection (PICKFIRST): when on, pre-selected objects
        // become the only cutting edges, even in Quick mode. When off, the
        // selection set is left intact but not adopted.
        let preselected = engine.cadSelection.selectedHandles.filter { handle in
            guard let entity = engine.document.entity(for: handle) else { return false }
            guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { return false }
            return entity.blockID == nil
        }

        switch Self.startDecision(
            pickFirst: Self.readPickFirst(processor: processor),
            mode: currentMode, hasPreselection: !preselected.isEmpty
        ) {
        case .adoptPreselected:
            // Adopt pre-selected objects as cutting edges immediately (AutoCAD behavior)
            selectedCuttingHandles = Set(preselected)
            engine.cadSelection.clearSelection()
            recompileCuttingSegments(in: engine.document)
            step = .selectTrimTarget
            processor.commandPrompt = "Cutting edge(s) selected (\(selectedCuttingHandles.count)). Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
        case .promptForEdges:
            selectedCuttingHandles.removeAll()
            step = .selectCuttingEdges
            processor.commandPrompt = "Select cutting edges ... Select objects or <select all>:"
        case .allEdges:
            selectedCuttingHandles.removeAll()
            recompileCuttingSegments(in: engine.document)
            step = .selectTrimTarget
            processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        active = false
        step = .selectCuttingEdges
        selectedCuttingHandles.removeAll()
        cachedCuttingEdges = .empty
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
            windowWidth: engine.windowWidth, windowHeight: engine.windowHeight
        )
        let rawClick = Vector3(x: rawWX, y: rawWY, z: 0)
        let doc = engine.document

        switch step {

        // ── Phase 1: Selecting Cutting Edges ──
        case .selectCuttingEdges:
            if let hitHandle = CADHitTesting.hitTest(
                worldX: rawWX, worldY: rawWY,
                document: doc,
                threshold: 12.0 / engine.camera.zoom,
                simplifyComplexBlocks: false
            ), let entity = doc.entity(for: hitHandle), entity.blockID == nil {
                if selectedCuttingHandles.contains(hitHandle) {
                    selectedCuttingHandles.remove(hitHandle)
                } else {
                    selectedCuttingHandles.insert(hitHandle)
                }
                recompileCuttingSegments(in: doc)
                processor.commandPrompt = "Select cutting edges: \(selectedCuttingHandles.count) selected. (Press Enter to finish, or click empty space to box select)"
                return .handled
            } else {
                // Clicked in empty space → begin box selection of cutting edges
                step = .edgeBoxSelecting(startWorld: rawClick, startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
                processor.commandPrompt = "Specify opposite corner:"
                return .handled
            }

        case .edgeBoxSelecting(let startWorld, let startScreen):
            let minX = min(startWorld.x, rawClick.x)
            let maxX = max(startWorld.x, rawClick.x)
            let minY = min(startWorld.y, rawClick.y)
            let maxY = max(startWorld.y, rawClick.y)
            let isCrossing = Float(rawScreenX) < startScreen.x
            let style: CADSelectionManager.RectSelectStyle = isCrossing ? .crossing : .window

            let handles = CADRectSelect.handlesInRect(
                worldX: minX, worldY: minY,
                worldW: maxX - minX, worldH: maxY - minY,
                document: doc, style: style
            )

            for h in handles {
                if let ent = doc.entity(for: h), ent.blockID == nil,
                   let layer = doc.layer(for: ent.layerID), layer.isVisible {
                    selectedCuttingHandles.insert(h)
                }
            }

            recompileCuttingSegments(in: doc)
            step = .selectCuttingEdges
            processor.commandPrompt = "Select cutting edges: \(selectedCuttingHandles.count) selected. (Press Enter to finish or pick more)"
            return .handled

        // ── Phase 2: Selecting Trim Targets ──
        case .selectTrimTarget:
            if let hitHandle = CADHitTesting.hitTest(
                worldX: rawWX, worldY: rawWY,
                document: doc,
                threshold: 12.0 / engine.camera.zoom,
                simplifyComplexBlocks: false
            ) {
                // Shift-pick extends through the extend solvers with the
                // same boundary set (EXTEND handshake mirror).
                if engine.io?.pointee.KeyShift ?? false {
                    let extended = performSingleExtend(
                        on: hitHandle, rawClick: rawClick, engine: engine, processor: processor)
                    if extended {
                        processor.commandPrompt = "Extended. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                    }
                    return .handled
                }
                // Single-click trim on entity
                let success = performSingleTrim(on: hitHandle, rawClick: rawClick, engine: engine, processor: processor)
                if success {
                    processor.commandPrompt = "Trimmed. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                }
                return .handled
            } else {
                if currentMode == .quick {
                    // Quick mode (AutoCAD parity): arm a freehand path. A
                    // press-drag trims everything the path crosses on release;
                    // a plain click arms a two-point fence instead.
                    step = .freehandSelecting(
                        points: [rawClick],
                        startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
                    processor.commandPrompt = "Drag to trim with a freehand path, or click a second point for a fence:"
                    return .handled
                }
                // Clicked empty space → begin box selection to batch-trim!
                step = .targetBoxSelecting(startWorld: rawClick, startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
                processor.commandPrompt = "Specify opposite corner:"
                return .handled
            }

        case .targetBoxSelecting(let startWorld, let startScreen):
            let minX = min(startWorld.x, rawClick.x)
            let maxX = max(startWorld.x, rawClick.x)
            let minY = min(startWorld.y, rawClick.y)
            let maxY = max(startWorld.y, rawClick.y)
            let isCrossing = Float(rawScreenX) < startScreen.x

            let trimmedCount = performBoxTrim(
                boxMin: Vector3(x: minX, y: minY, z: 0),
                boxMax: Vector3(x: maxX, y: maxY, z: 0),
                isCrossing: isCrossing,
                engine: engine, processor: processor
            )

            step = .selectTrimTarget
            if trimmedCount > 0 {
                processor.commandPrompt = "\(trimmedCount) object(s) trimmed. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
            } else {
                processor.commandPrompt = "No valid trim intersections found. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
            }
            return .handled

        case .fenceSelecting(var points):
            points.append(rawClick)
            step = .fenceSelecting(points: points)
            processor.commandPrompt = "Specify next fence point or press Enter to finish (\(points.count) points):"
            return .handled

        case .freehandSelecting:
            // Mid-press extra press (e.g. multi-touch): hold the armed path;
            // the release resolves it.
            return .handled

        case .fenceTwoPoint(let first):
            let fenceCount = performFenceTrim(
                points: [first, rawClick], engine: engine, processor: processor)
            step = .selectTrimTarget
            if fenceCount > 0 {
                processor.commandPrompt = "\(fenceCount) object(s) trimmed by fence. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
            } else {
                processor.commandPrompt = "No valid trim intersections found. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
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
            let crossedCount = performBoxTrim(
                boxMin: Vector3(x: minX, y: minY, z: 0),
                boxMax: Vector3(x: maxX, y: maxY, z: 0),
                isCrossing: true,
                engine: engine, processor: processor
            )
            step = .selectTrimTarget
            if crossedCount > 0 {
                processor.commandPrompt = "\(crossedCount) object(s) trimmed. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
            } else {
                processor.commandPrompt = "No valid trim intersections found. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
            }
            return .handled

        // ── Phase 3: eRase Mode ──
        case .eraseSelecting:
            if let hitHandle = CADHitTesting.hitTest(
                worldX: rawWX, worldY: rawWY,
                document: doc,
                threshold: 12.0 / engine.camera.zoom,
                simplifyComplexBlocks: false
            ) {
                doc.pushUndo()
                operationsInSession += 1
                doc.removeEntities(handles: [hitHandle])
                doc.rebuildEntityGrid()
                doc.markEdited(regenerate: true)
                engine.tabManager.markActiveDirty()
                refreshCutterContribution(for: hitHandle, in: doc, deleted: true)
                processor.commandPrompt = "Object erased. Select objects to erase or press Enter to return to Trim:"
                return .handled
            } else {
                step = .eraseBoxSelecting(startWorld: rawClick, startScreen: SDL_FPoint(x: Float(rawScreenX), y: Float(rawScreenY)))
                processor.commandPrompt = "Specify opposite corner:"
                return .handled
            }

        case .eraseBoxSelecting(let startWorld, let startScreen):
            let minX = min(startWorld.x, rawClick.x)
            let maxX = max(startWorld.x, rawClick.x)
            let minY = min(startWorld.y, rawClick.y)
            let maxY = max(startWorld.y, rawClick.y)
            let isCrossing = Float(rawScreenX) < startScreen.x
            let style: CADSelectionManager.RectSelectStyle = isCrossing ? .crossing : .window

            let handles = CADRectSelect.handlesInRect(
                worldX: minX, worldY: minY,
                worldW: maxX - minX, worldH: maxY - minY,
                document: doc, style: style
            )

            if !handles.isEmpty {
                doc.pushUndo()
                operationsInSession += 1
                doc.removeEntities(handles: handles)
                doc.rebuildEntityGrid()
                doc.markEdited(regenerate: true)
                engine.tabManager.markActiveDirty()
                for h in handles {
                    refreshCutterContribution(for: h, in: doc, deleted: true)
                }
                processor.commandPrompt = "\(handles.count) object(s) erased. Select objects to erase or press Enter to return to Trim:"
            }
            step = .eraseSelecting
            return .handled

        case .askProject:
            processor.commandPrompt = Self.askProjectPrompt(processor: processor)
            return .handled

        case .askEdge:
            processor.commandPrompt = Self.askEdgePrompt(processor: processor)
            return .handled

        case .askMode:
            processor.commandPrompt = askModePrompt()
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
        // Grow the armed Quick freehand path (screen-spaced so slow and fast
        // drags trim the same segments).
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
                // Deliberate press-drag: trim everything the path crosses.
                var path = points
                path.append(Vector3(x: worldX, y: worldY, z: 0))
                let count = performFenceTrim(
                    points: path, engine: engine, processor: processor)
                step = .selectTrimTarget
                if count > 0 {
                    processor.commandPrompt = "\(count) object(s) trimmed. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                } else {
                    processor.commandPrompt = "No valid trim intersections found. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
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
            case .edgeBoxSelecting:
                step = .selectCuttingEdges
                processor.commandPrompt = "Select cutting edges ... Select objects or <select all>:"
                return .handled
            case .targetBoxSelecting, .fenceSelecting, .freehandSelecting, .fenceTwoPoint, .crossingFirst, .crossingSecond, .eraseSelecting, .eraseBoxSelecting, .askProject, .askEdge:
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case .askMode:
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled
            case .selectCuttingEdges, .selectTrimTarget:
                active = false
                return .finished
            }

        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER, SDL_SCANCODE_SPACE:
            switch step {
            case .selectCuttingEdges:
                // Commit cutting edges
                recompileCuttingSegments(in: engine.document)
                step = .selectTrimTarget
                if selectedCuttingHandles.isEmpty {
                    processor.commandPrompt = "All objects selected as cutting edges. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                } else {
                    processor.commandPrompt = "\(selectedCuttingHandles.count) cutting edge(s) selected. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                }
                return .handled

            case .fenceSelecting(let points):
                if points.count >= 2 {
                    let count = performFenceTrim(points: points, engine: engine, processor: processor)
                    processor.commandPrompt = "\(count) object(s) trimmed by fence. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                }
                step = .selectTrimTarget
                return .handled

            case .eraseSelecting:
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled

            case .fenceTwoPoint, .crossingFirst:
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled

            case .crossingSecond(let startWorld, _):
                let cursor = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
                let minX = min(startWorld.x, cursor.x)
                let maxX = max(startWorld.x, cursor.x)
                let minY = min(startWorld.y, cursor.y)
                let maxY = max(startWorld.y, cursor.y)
                let crossed = performBoxTrim(
                    boxMin: Vector3(x: minX, y: minY, z: 0),
                    boxMax: Vector3(x: maxX, y: maxY, z: 0),
                    isCrossing: true,
                    engine: engine, processor: processor)
                step = .selectTrimTarget
                if crossed > 0 {
                    processor.commandPrompt = "\(crossed) object(s) trimmed. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                } else {
                    processor.commandPrompt = "No valid trim intersections found. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                }
                return .handled

case .askProject:
                Self.setProjectionMode(1, engine: engine, processor: processor)
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled

            case .askEdge:
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled

            case .askMode:
                step = askReturn
                processor.commandPrompt = promptForStep(step)
                return .handled

            case .selectTrimTarget:
                active = false
                return .finished

            default:
                return .continue
            }

        // Shortcuts when in .selectTrimTarget:
        case SDL_SCANCODE_F where isWaitingForTarget:
            step = .fenceSelecting(points: [])
            processor.commandPrompt = "Specify first fence point:"
            return .handled

        case SDL_SCANCODE_C where isWaitingForTarget:
            step = .crossingFirst
            processor.commandPrompt = "Specify first corner:"
            return .handled

        case SDL_SCANCODE_E where isWaitingForTarget:
            step = .selectCuttingEdges
            processor.commandPrompt = "Select cutting edges ... Select objects or <select all>:"
            return .handled

        case SDL_SCANCODE_M where isWaitingForTarget:
            askReturn = .selectTrimTarget
            step = .askMode
            processor.commandPrompt = askModePrompt()
            return .handled

        case SDL_SCANCODE_P where isWaitingForTarget:
            step = .askProject
            processor.commandPrompt = Self.askProjectPrompt(processor: processor)
            return .handled

        case SDL_SCANCODE_R where isWaitingForTarget:
            step = .eraseSelecting
            processor.commandPrompt = "Select objects to erase or press Enter to return to Trim:"
            return .handled

        case SDL_SCANCODE_U where isWaitingForTarget:
            return performUndo(engine: engine, processor: processor)

        default:
            return .continue
        }
    }

    private var isWaitingForTarget: Bool {
        if case .selectTrimTarget = step { return true }
        return false
    }

    // MARK: - Command Text Handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch step {
        case .selectCuttingEdges:
            if upper == "ALL" || upper == "SELECT ALL" || upper == "" {
                selectedCuttingHandles.removeAll()
                recompileCuttingSegments(in: engine.document)
                step = .selectTrimTarget
                processor.commandPrompt = "All objects selected as cutting edges. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            } else if upper == "M" || upper == "MODE" {
                askReturn = .selectCuttingEdges
                step = .askMode
                processor.commandPrompt = askModePrompt()
                return .handled
            }

        case .selectTrimTarget:
            switch upper {
            case "F", "FENCE":
                step = .fenceSelecting(points: [])
                processor.commandPrompt = "Specify first fence point:"
                return .handled

            case "C", "CROSSING":
                step = .crossingFirst
                processor.commandPrompt = "Specify first corner:"
                return .handled

            case "E", "CUTTING", "EDGES", "CUTTING EDGES":
                step = .selectCuttingEdges
                processor.commandPrompt = "Select cutting edges ... Select objects or <select all>:"
                return .handled

            case "M", "MODE":
                askReturn = .selectTrimTarget
                step = .askMode
                processor.commandPrompt = askModePrompt()
                return .handled

            case "P", "PROJECT":
                step = .askProject
                processor.commandPrompt = Self.askProjectPrompt(processor: processor)
                return .handled

            case "EDGE":
                step = .askEdge
                processor.commandPrompt = Self.askEdgePrompt(processor: processor)
                return .handled

            case "R", "ERASE":
                step = .eraseSelecting
                processor.commandPrompt = "Select objects to erase or press Enter to return to Trim:"
                return .handled

            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)

            default:
                break
            }

case .askProject:
            switch upper {
            case "":
                Self.setProjectionMode(1, engine: engine, processor: processor)
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case "N", "NONE":
                Self.setProjectionMode(0, engine: engine, processor: processor)
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case "U", "UCS":
                Self.setProjectionMode(1, engine: engine, processor: processor)
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case "V", "VIEW":
                Self.setProjectionMode(2, engine: engine, processor: processor)
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                processor.commandPrompt =
                    "Invalid projection option. \(Self.askProjectPrompt(processor: processor))"
                return .handled
            }

        case .askEdge:
            switch upper {
            case "":
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case "E", "EXTEND":
                Self.setEdgeMode(1, engine: engine, processor: processor)
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case "N", "NO", "NO EXTEND", "NOEXTEND":
                Self.setEdgeMode(0, engine: engine, processor: processor)
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            case "U", "UNDO":
                return performUndo(engine: engine, processor: processor)
            default:
                processor.commandPrompt =
                    "Invalid edge mode. \(Self.askEdgePrompt(processor: processor))"
                return .handled
            }

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
                    "Invalid mode. \(askModePrompt())"
                return .handled
            }

        case .crossingFirst:
            if upper.isEmpty {
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            }
            return .continue

        case .crossingSecond:
            if upper.isEmpty {
                return handleKeyDown(
                    scancode: SDL_SCANCODE_RETURN, engine: engine, processor: processor)
            }
            return .continue

        case .fenceTwoPoint:
            if upper.isEmpty {
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return .handled
            }
            return .continue

        default:
            break
        }

        return .continue
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        switch step {
        case .selectCuttingEdges:
            return [
                .init(value: "ALL", title: "Select all", aliases: ["A"]),
                .init(value: "M", title: "Mode", aliases: ["MODE"], description: "Quick vs Standard mode")
            ]
        case .selectTrimTarget:
            return [
                .init(value: "F", title: "Fence", aliases: ["FENCE"], description: "Draw fence line to trim"),
                .init(value: "C", title: "Crossing", aliases: ["CROSSING"], description: "Crossing window trim"),
                .init(value: "E", title: "Cutting edges", aliases: ["CUTTING", "EDGES"], description: "Change cutting edges"),
                .init(value: "M", title: "Mode", aliases: ["MODE"], description: "Quick vs Standard mode"),
                .init(value: "R", title: "eRase", aliases: ["ERASE"], description: "Delete entities directly"),
                .init(value: "P", title: "Project", aliases: ["PROJECT"], description: "Projection option (None/UCS/View)"),
                .init(value: "EDGE", title: "Edge", aliases: [], description: "Implied edge mode (Extend/No extend)"),
                .init(value: "U", title: "Undo", aliases: ["UNDO"], description: "Revert last trim operation")
            ]
        case .askMode:
            return [
                .init(value: "Q", title: "Quick", aliases: ["QUICK"], description: "Quick mode: everything is a cutting edge"),
                .init(value: "S", title: "Standard", aliases: ["STANDARD"], description: "Standard mode: pick cutting edges"),
                .init(value: "U", title: "Undo", aliases: ["UNDO"], description: "Revert last trim operation"),
            ]
        default:
            return []
        }
    }

    // MARK: - Trimming Execution

    private func performSingleTrim(
        on hitHandle: UUID,
        rawClick: Vector3,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> Bool {
        let doc = engine.document
        guard let entity = doc.entity(for: hitHandle) else { return false }
        guard entity.blockID == nil else {
            processor.commandPrompt = "Cannot trim block references. Explode them first."
            return false
        }

        let preSnapshot = doc.snapshot()
        let criterion = TrimCriterion.click(point: rawClick)

        // Never let the target cut itself: in quick/select-all mode its
        // own geometry is part of the compiled cutter set.
        let edges = cachedCuttingEdges.excluding(hitHandle)
        let (newGeom, modified, errorMsg) = TrimGeometryEngine.trimEntity(
            entity: entity,
            document: doc,
            criterion: criterion,
            cuttingSegments: edges.segments,
            exactLines: edges.exactLines,
            exactCurves: edges.exactCurves
        )

        if let errorMsg {
            processor.commandPrompt = errorMsg
            return false
        }

        guard modified, let geom = newGeom else {
            // Quick-mode parity: a picked object that cannot be trimmed is
            // deleted instead (AutoCAD Quick behavior). Standard mode leaves
            // the geometry unchanged. Locked layers and viewport copies are
            // never deleted. Returning false preserves the prompt below: the
            // caller overwrites it on true.
            if currentMode == .quick,
               let layer = doc.layer(for: entity.layerID), !layer.isLocked,
               !entity.isViewportProjected {
                doc.pushUndo(preSnapshot)
                operationsInSession += 1
                doc.removeEntities(handles: [hitHandle])
                engine.cadSelection.clearSelection()
                doc.rebuildEntityGrid()
                doc.markEdited(regenerate: true)
                engine.tabManager.markActiveDirty()
                refreshCutterContribution(for: hitHandle, in: doc, deleted: true)
                processor.commandPrompt = "Object cannot be trimmed — deleted. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
                return false
            }
            if let layer = doc.layer(for: entity.layerID), layer.isLocked {
                processor.commandPrompt = "The object is on a locked layer."
                return false
            }
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

        // Rebuild (not just invalidate) so the next snap keeps its grid
        // broad phase instead of falling back to a full scan per mousemove
        // until the background regen lands.
        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        // If the trimmed entity was a cutting edge, splice its new geometry
        // into the cached cutters instead of recompiling drawing-wide.
        refreshCutterContribution(for: hitHandle, in: doc, deleted: geom.isEmpty)

        return true
    }

    /// Extends one object through the extend solvers with this command's
    /// compiled cutting edges as boundaries (Shift-pick handshake).
    private func performSingleExtend(
        on hitHandle: UUID,
        rawClick: Vector3,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> Bool {
        let doc = engine.document
        guard let entity = doc.entity(for: hitHandle) else { return false }
        guard entity.blockID == nil else {
            processor.commandPrompt = "Cannot extend block references. Explode them first."
            return false
        }

        let preSnapshot = doc.snapshot()
        let edges = cachedCuttingEdges.excluding(hitHandle)
        let (newGeom, modified, errorMsg) = TrimGeometryEngine.extendEntity(
            entity: entity, pickWorld: rawClick, boundaries: edges,
            edgeMode: Self.readEdgeMode(processor: processor))

        if let errorMsg {
            processor.commandPrompt = errorMsg
            return false
        }

        guard modified, let geom = newGeom else {
            processor.commandPrompt = "No boundary found to extend to. Geometry was left unchanged."
            return false
        }

        doc.pushUndo(preSnapshot)
        operationsInSession += 1
        doc.updateEntityGeometryLive(for: hitHandle, geometry: geom)
        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        refreshCutterContribution(for: hitHandle, in: doc, deleted: false)

        return true
    }

    private func performBoxTrim(
        boxMin: Vector3, boxMax: Vector3, isCrossing: Bool,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Int {
        let doc = engine.document
        let criterion = TrimCriterion.rect(min: boxMin, max: boxMax, isCrossing: isCrossing)
        let style: CADSelectionManager.RectSelectStyle = isCrossing ? .crossing : .window

        let candidateHandles = CADRectSelect.handlesInRect(
            worldX: boxMin.x, worldY: boxMin.y,
            worldW: boxMax.x - boxMin.x, worldH: boxMax.y - boxMin.y,
            document: doc, style: style
        )

        guard !candidateHandles.isEmpty else { return 0 }

        let preSnapshot = doc.snapshot()
        var modifiedEntities: [(UUID, [CADPrimitive])] = []
        var deletedHandles: Set<UUID> = []

        for handle in candidateHandles {
            guard let entity = doc.entity(for: handle) else { continue }
            guard let layer = doc.layer(for: entity.layerID), layer.isVisible else { continue }
            guard entity.blockID == nil else { continue }

            let edges = cachedCuttingEdges.excluding(handle)
            let (newGeom, modified, _) = TrimGeometryEngine.trimEntity(
                entity: entity,
                document: doc,
                criterion: criterion,
                cuttingSegments: edges.segments,
                exactLines: edges.exactLines,
                exactCurves: edges.exactCurves
            )

            if modified, let geom = newGeom {
                if geom.isEmpty {
                    deletedHandles.insert(handle)
                } else {
                    modifiedEntities.append((handle, geom))
                }
            }
        }

        guard !modifiedEntities.isEmpty || !deletedHandles.isEmpty else { return 0 }

        doc.pushUndo(preSnapshot)
        operationsInSession += 1

        for (handle, geom) in modifiedEntities {
            doc.updateEntityGeometryLive(for: handle, geometry: geom)
        }
        for handle in deletedHandles {
            doc.removeEntities(handles: [handle])
        }

        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        for (handle, _) in modifiedEntities {
            refreshCutterContribution(for: handle, in: doc, deleted: false)
        }
        for handle in deletedHandles {
            refreshCutterContribution(for: handle, in: doc, deleted: true)
        }

        return modifiedEntities.count + deletedHandles.count
    }

    private func performFenceTrim(
        points: [Vector3],
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> Int {
        guard points.count >= 2 else { return 0 }
        let doc = engine.document
        let preSnapshot = doc.snapshot()

        var modifiedEntities: [UUID: [CADPrimitive]] = [:]
        var deletedHandles: Set<UUID> = []

        for i in 0..<(points.count - 1) {
            let p1 = points[i]
            let p2 = points[i + 1]
            let criterion = TrimCriterion.fence(p1: p1, p2: p2)

            for entity in doc.entitiesView {
                let handle = entity.handle
                guard !deletedHandles.contains(handle) else { continue }
                guard let layer = doc.layer(for: entity.layerID), layer.isVisible else { continue }
                guard entity.blockID == nil else { continue }

                // Quick bounding box rejection
                let segMinX = min(p1.x, p2.x)
                let segMaxX = max(p1.x, p2.x)
                let segMinY = min(p1.y, p2.y)
                let segMaxY = max(p1.y, p2.y)
                if let bb = entity.worldBoundingBox {
                    if bb.max.x < segMinX || bb.min.x > segMaxX ||
                       bb.max.y < segMinY || bb.min.y > segMaxY {
                        continue
                    }
                }

                // If already partially modified in earlier fence segments, use current state
                var currentEntity = entity
                if let intermediate = modifiedEntities[handle] {
                    currentEntity.localGeometry = intermediate
                }

                let edges = cachedCuttingEdges.excluding(handle)
                let (newGeom, modified, _) = TrimGeometryEngine.trimEntity(
                    entity: currentEntity,
                    document: doc,
                    criterion: criterion,
                    cuttingSegments: edges.segments,
                    exactLines: edges.exactLines,
                    exactCurves: edges.exactCurves
                )

                if modified, let geom = newGeom {
                    if geom.isEmpty {
                        deletedHandles.insert(handle)
                        modifiedEntities.removeValue(forKey: handle)
                    } else {
                        modifiedEntities[handle] = geom
                    }
                }
            }
        }

        guard !modifiedEntities.isEmpty || !deletedHandles.isEmpty else { return 0 }

        doc.pushUndo(preSnapshot)
        operationsInSession += 1

        for (handle, geom) in modifiedEntities {
            doc.updateEntityGeometryLive(for: handle, geometry: geom)
        }
        for handle in deletedHandles {
            doc.removeEntities(handles: [handle])
        }

        doc.rebuildEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        for handle in modifiedEntities.keys {
            refreshCutterContribution(for: handle, in: doc, deleted: false)
        }
        for handle in deletedHandles {
            refreshCutterContribution(for: handle, in: doc, deleted: true)
        }

        return modifiedEntities.count + deletedHandles.count
    }

    private func performUndo(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard operationsInSession > 0 else {
            processor.commandPrompt = "Nothing to undo in this TRIM session."
            return .handled
        }

        engine.document.undo()
        operationsInSession -= 1
        recompileCuttingSegments(in: engine.document)
        processor.commandPrompt = "Undo trim. Select object to trim or shift-select to extend or [Fence/Crossing/Cutting edges/Mode/Project/Edge/eRase/Undo]:"
        return .handled
    }

    private func recompileCuttingSegments(in doc: CADDocument) {
        cachedCuttingEdges = TrimGeometryEngine.collectCuttingEdges(
            document: doc,
            cuttingHandles: selectedCuttingHandles.isEmpty ? nil : selectedCuttingHandles,
            excludedHandle: nil
        )
    }

    /// Splice one entity's new (or removed) geometry into the cached cutters
    /// instead of recompiling every cutter drawing-wide. No-op when the
    /// entity is not part of the cutter set, mirroring the old full-recompile
    /// guard. Undo still recompiles fully: it can restore arbitrary state.
    private func refreshCutterContribution(for handle: UUID, in doc: CADDocument, deleted: Bool) {
        guard selectedCuttingHandles.isEmpty || selectedCuttingHandles.contains(handle) else { return }
        if deleted {
            TrimGeometryEngine.removeCuttingEdges(&cachedCuttingEdges, for: handle)
        } else {
            TrimGeometryEngine.updateCuttingEdges(&cachedCuttingEdges, for: handle, document: doc)
        }
    }

    // MARK: - Overlay Rendering

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard active else { return }
        guard let drawList = igGetForegroundDrawList_ViewportPtr(nil) else { return }

        // 1. Highlight Cutting Edges (cyan glow)
        if !selectedCuttingHandles.isEmpty {
            let cuttingEdgeCol = makeCol32(0, 220, 255, 230)
            for segment in cachedCuttingEdges.segments {
                let p1 = EngineCameraManager.worldToScreen(worldX: segment.0.x, worldY: segment.0.y, cam: cam)
                let p2 = EngineCameraManager.worldToScreen(worldX: segment.1.x, worldY: segment.1.y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: p1.x, y: p1.y), ImVec2(x: p2.x, y: p2.y), cuttingEdgeCol, 2.0)
            }
        }

        // 2. Selection Box Overlay
        switch step {
        case .edgeBoxSelecting(let startWorld, let startScreen),
             .targetBoxSelecting(let startWorld, let startScreen),
             .crossingSecond(let startWorld, let startScreen),
             .eraseBoxSelecting(let startWorld, let startScreen):

            let p1 = EngineCameraManager.worldToScreen(worldX: startWorld.x, worldY: startWorld.y, cam: cam)
            let p3 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)

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
                // Green crossing window
                borderCol = makeCol32(64, 220, 80, 240)
                fillCol = makeCol32(64, 180, 80, 45)
            } else {
                // Blue window
                borderCol = makeCol32(0, 150, 255, 240)
                fillCol = makeCol32(0, 128, 255, 45)
            }

            ImDrawListAddRectFilled(drawList, p1Draw, p3Draw, fillCol, 0.0, 0)
            ImDrawListAddLine(drawList, p1Draw, p2Draw, borderCol, 1.5)
            ImDrawListAddLine(drawList, p2Draw, p3Draw, borderCol, 1.5)
            ImDrawListAddLine(drawList, p3Draw, p4Draw, borderCol, 1.5)
            ImDrawListAddLine(drawList, p4Draw, p1Draw, borderCol, 1.5)

        // 3. Fence Line Overlay
        case .fenceSelecting(let points), .freehandSelecting(let points, _):
            let fenceCol = makeCol32(255, 170, 0, 240)
            if !points.isEmpty {
                for i in 0..<(points.count - 1) {
                    let s1 = EngineCameraManager.worldToScreen(worldX: points[i].x, worldY: points[i].y, cam: cam)
                    let s2 = EngineCameraManager.worldToScreen(worldX: points[i+1].x, worldY: points[i+1].y, cam: cam)
                    ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), fenceCol, 2.0)
                }
                // Rubber-band from last point to cursor
                if let last = points.last {
                    let sLast = EngineCameraManager.worldToScreen(worldX: last.x, worldY: last.y, cam: cam)
                    let sCur = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
                    ImDrawListAddLine(drawList, ImVec2(x: sLast.x, y: sLast.y), ImVec2(x: sCur.x, y: sCur.y), fenceCol, 1.5)
                }
            }

        // 4. Two-point fence rubber band (first point armed, cursor is second)
        case .fenceTwoPoint(let first):
            let fenceCol = makeCol32(255, 170, 0, 240)
            let sFirst = EngineCameraManager.worldToScreen(worldX: first.x, worldY: first.y, cam: cam)
            let sCur = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: sFirst.x, y: sFirst.y), ImVec2(x: sCur.x, y: sCur.y), fenceCol, 1.5)

        default:
            break
        }
    }
}

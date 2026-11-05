import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel

// =========================================================================
// MARK: - TrimCommand
// =========================================================================

/// TRIM — AutoCAD-style trim command supporting cutting edge selection,
/// single-click trimming, crossing/window box trimming, fence trimming,
/// in-session undo, and on-the-fly option switching.
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

        /// eRase sub-mode: click objects to delete directly without leaving TRIM.
        case eraseSelecting
        /// Interactive box selection for eRase mode.
        case eraseBoxSelecting(startWorld: Vector3, startScreen: SDL_FPoint)
    }

    // MARK: - Static Configuration

    /// User's preferred TRIM mode across sessions. Defaults to `.standard` (classic AutoCAD).
    public static var preferredMode: TrimMode = .standard

    // MARK: - Instance State

    private var active: Bool = true
    private var currentMode: TrimMode = TrimCommand.preferredMode
    private var step: TrimStep = .selectCuttingEdges

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

        // Check for pre-selected entities
        let preselected = engine.cadSelection.selectedHandles.filter { handle in
            guard let entity = engine.document.entity(for: handle) else { return false }
            guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { return false }
            return entity.blockID == nil
        }

        if !preselected.isEmpty {
            // Adopt pre-selected objects as cutting edges immediately (AutoCAD behavior)
            selectedCuttingHandles = Set(preselected)
            engine.cadSelection.clearSelection()
            recompileCuttingSegments(in: engine.document)
            step = .selectTrimTarget
            processor.commandPrompt = "Cutting edge(s) selected (\(selectedCuttingHandles.count)). Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
        } else if currentMode == .standard {
            selectedCuttingHandles.removeAll()
            step = .selectCuttingEdges
            processor.commandPrompt = "Select cutting edges ... Select objects or <select all>:"
        } else {
            selectedCuttingHandles.removeAll()
            recompileCuttingSegments(in: engine.document)
            step = .selectTrimTarget
            processor.commandPrompt = "Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
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
                // Single-click trim on entity
                let success = performSingleTrim(on: hitHandle, rawClick: rawClick, engine: engine, processor: processor)
                if success {
                    processor.commandPrompt = "Trimmed. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
                }
                return .handled
            } else {
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
                processor.commandPrompt = "\(trimmedCount) object(s) trimmed. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
            } else {
                processor.commandPrompt = "No valid trim intersections found. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
            }
            return .handled

        case .fenceSelecting(var points):
            points.append(rawClick)
            step = .fenceSelecting(points: points)
            processor.commandPrompt = "Specify next fence point or press Enter to finish (\(points.count) points):"
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
                doc.invalidateEntityGrid()
                doc.markEdited(regenerate: true)
                engine.tabManager.markActiveDirty()
                recompileCuttingSegments(in: doc)
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
                doc.invalidateEntityGrid()
                doc.markEdited(regenerate: true)
                engine.tabManager.markActiveDirty()
                recompileCuttingSegments(in: doc)
                processor.commandPrompt = "\(handles.count) object(s) erased. Select objects to erase or press Enter to return to Trim:"
            }
            step = .eraseSelecting
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
            case .targetBoxSelecting, .fenceSelecting, .eraseSelecting, .eraseBoxSelecting:
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
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
                    processor.commandPrompt = "All objects selected as cutting edges. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
                } else {
                    processor.commandPrompt = "\(selectedCuttingHandles.count) cutting edge(s) selected. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
                }
                return .handled

            case .fenceSelecting(let points):
                if points.count >= 2 {
                    let count = performFenceTrim(points: points, engine: engine, processor: processor)
                    processor.commandPrompt = "\(count) object(s) trimmed by fence. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
                }
                step = .selectTrimTarget
                return .handled

            case .eraseSelecting:
                step = .selectTrimTarget
                processor.commandPrompt = "Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
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
            processor.commandPrompt = "Crossing selection: click first corner in drawing area."
            return .handled

        case SDL_SCANCODE_E where isWaitingForTarget:
            step = .selectCuttingEdges
            processor.commandPrompt = "Select cutting edges ... Select objects or <select all>:"
            return .handled

        case SDL_SCANCODE_M where isWaitingForTarget:
            currentMode = (currentMode == .standard) ? .quick : .standard
            Self.preferredMode = currentMode
            recompileCuttingSegments(in: engine.document)
            processor.commandPrompt = "TRIM mode set to \(currentMode.rawValue.uppercased()). Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
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
                processor.commandPrompt = "All objects selected as cutting edges. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
                return .handled
            } else if upper == "M" || upper == "MODE" {
                currentMode = (currentMode == .standard) ? .quick : .standard
                Self.preferredMode = currentMode
                recompileCuttingSegments(in: engine.document)
                processor.commandPrompt = "TRIM mode set to \(currentMode.rawValue.uppercased()). Select cutting edges ... Select objects or <select all>:"
                return .handled
            }

        case .selectTrimTarget:
            switch upper {
            case "F", "FENCE":
                step = .fenceSelecting(points: [])
                processor.commandPrompt = "Specify first fence point:"
                return .handled

            case "C", "CROSSING":
                processor.commandPrompt = "Crossing selection: click first corner in drawing area."
                return .handled

            case "E", "CUTTING", "EDGES", "CUTTING EDGES":
                step = .selectCuttingEdges
                processor.commandPrompt = "Select cutting edges ... Select objects or <select all>:"
                return .handled

            case "M", "MODE":
                currentMode = (currentMode == .standard) ? .quick : .standard
                Self.preferredMode = currentMode
                recompileCuttingSegments(in: engine.document)
                processor.commandPrompt = "TRIM mode set to \(currentMode.rawValue.uppercased()). Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
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
                .init(value: "M", title: "Mode", aliases: ["MODE"], description: "Toggle Quick vs Standard")
            ]
        case .selectTrimTarget:
            return [
                .init(value: "F", title: "Fence", aliases: ["FENCE"], description: "Draw fence line to trim"),
                .init(value: "C", title: "Crossing", aliases: ["CROSSING"], description: "Crossing window trim"),
                .init(value: "E", title: "Cutting edges", aliases: ["CUTTING", "EDGES"], description: "Change cutting edges"),
                .init(value: "M", title: "Mode", aliases: ["MODE"], description: "Toggle Quick vs Standard"),
                .init(value: "R", title: "eRase", aliases: ["ERASE"], description: "Delete entities directly"),
                .init(value: "U", title: "Undo", aliases: ["UNDO"], description: "Revert last trim operation")
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

        doc.invalidateEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        // If the trimmed entity was a cutting edge, refresh cached cutting edges
        if selectedCuttingHandles.contains(hitHandle) || selectedCuttingHandles.isEmpty {
            recompileCuttingSegments(in: doc)
        }

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

        doc.invalidateEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        recompileCuttingSegments(in: doc)

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

        doc.invalidateEntityGrid()
        doc.markEdited(regenerate: true)
        engine.tabManager.markActiveDirty()

        recompileCuttingSegments(in: doc)

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
        processor.commandPrompt = "Undo trim. Select object to trim or [Fence/Crossing/Cutting edges/Mode/eRase/Undo]:"
        return .handled
    }

    private func recompileCuttingSegments(in doc: CADDocument) {
        cachedCuttingEdges = TrimGeometryEngine.collectCuttingEdges(
            document: doc,
            cuttingHandles: selectedCuttingHandles.isEmpty ? nil : selectedCuttingHandles,
            excludedHandle: nil
        )
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
        case .fenceSelecting(let points):
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

        default:
            break
        }
    }
}

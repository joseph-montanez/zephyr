import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - EngineLoopController
//
// Replaces Engine+Loop.swift. Handles the main application loop, frame 
// pacing, conditional rendering, and delegates tool mouse handlers.
// =========================================================================
@MainActor
public final class EngineLoopController {
    
    private unowned let engine: PhrostEngine
    private let hoverCoordinator: CADHoverCoordinator
    
    public init(engine: PhrostEngine) {
        self.engine = engine
        self.hoverCoordinator = CADHoverCoordinator(engine: engine)
    }

    // MARK: - Main Loop

    /// The main application loop. Handles frame pacing, event polling,
    /// conditional rendering (lazy loop), and camera updates.
    ///
    /// Event polling is delegated to an `EngineInputHandler` instance to
    /// keep the main loop focused on frame timing rather than input dispatch.
    public func run(updateBlock: (() -> Void)? = nil) {
        var frameCount: Int = 0
        var lastTick: UInt64 = SDL_GetTicks()
        let targetMs: Double = 1000.0 / 60.0

        // Create the input handler once and reuse it for the lifetime of the loop.
        let inputHandler = EngineInputHandler(engine: engine)
        engine.activateInitialWindowForInput()

        // The core of the "Lazy Loop": Determines if the engine should render.
        // Starts at 5 to ensure initial ImGui setup frames render cleanly.
        var framesToRender: Int = 5
        var lastSaveStateCount = engine.tabManager.saveStateByTabID.count

        while engine.running {
            let frameStart: UInt64 = SDL_GetTicks()

            if engine.tabManager.applyPendingSaveUpdates() {
                framesToRender = max(framesToRender, 5)
            }

            let now = SDL_GetTicks()
            let deltaMs = Double(now &- lastTick)

            // Clamp to 0.0001. If the frame took < 1ms, give ImGui a tiny
            // fractional time step so it bypasses the DeltaTime > 0.0f assertion.
            let deltaSec = max(deltaMs / 1000.0, 0.0001)
            lastTick = now

            // 1. Thread Sleeping:
            // If the application is idle, put the thread to sleep until an event
            // is fired or 16ms elapses. This drops idle CPU/GPU usage to near 0%.
            let interaction = engine.interaction
            let saveStateCount = engine.tabManager.saveStateByTabID.count
            if saveStateCount != lastSaveStateCount {
                framesToRender = max(framesToRender, 5)
                lastSaveStateCount = saveStateCount
            }
            let isActionActive =
                interaction.dragActive || interaction.panActive || interaction.touchPanActive
                || engine.commandProcessor.activeCommand != nil || engine.commandProcessor.activeFeatureCommand != nil
                || engine.commandProcessor.commandLineActive || engine.document.needsRegeneration
                || engine._regenerationInFlight != nil
                || engine.renderer._vbInFlightToken != nil
                || saveStateCount > 0
            
            if framesToRender <= 0 && !isActionActive {
                SDL_WaitEventTimeout(nil, 16)
            }

            // 2. Poll Events and check if interaction occurred
            let eventsProcessed = inputHandler.pollEvents()
            if eventsProcessed > 0 {
                framesToRender = 5
            }

            engine.camera.updateFollow(spriteManager: engine.spriteManager)

            // Autosave tick
            engine._autosaveAccumulator += deltaSec
            let autosaveIntervalSec = engine.autosaveIntervalMinutes * 60.0
            if engine._autosaveAccumulator >= autosaveIntervalSec {
                var anyStarted = false
                for tab in engine.tabManager.tabs where tab.hasUnsavedChanges {
                    guard engine.tabManager.saveStateByTabID[tab.id] == nil else { continue }
                    engine.tabManager.startAutosave(tabID: tab.id)
                    anyStarted = true
                }
                if anyStarted || engine.tabManager.tabs.allSatisfy({ !$0.hasUnsavedChanges }) {
                    engine._autosaveAccumulator = 0
                } else {
                    engine._autosaveAccumulator = autosaveIntervalSec * 0.9
                }
            }

            updateBlock?()

            // 3. Conditional Rendering
            if framesToRender > 0 || isActionActive {
                engine.renderer.render(deltaSec: deltaSec)
                framesToRender -= 1
            }

            let frameWorkEnd = SDL_GetTicks()
            let frameTime = Double(frameWorkEnd &- frameStart)
            let sleepMs = targetMs - frameTime

            if sleepMs > 0 && (framesToRender > 0 || isActionActive) {
                SDL_Delay(UInt32(sleepMs))
            }
            frameCount &+= 1
        }
    }

    // MARK: - Tool Mouse Handlers
    
    // Extracted from Engine+Loop.swift
    internal func handleToolMouseDown(x: Float, y: Float) {
        let interaction = engine.interaction
        let snapMgr = engine.snap
        let (wx, wy) = engine.camera.screenToWorld(screenX: x, screenY: y, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let shiftHeld = (engine.io != nil) ? engine.io.pointee.KeyShift : false

        if engine.commandProcessor.activeCommand != nil {
            snapMgr.lockedSnap = nil
            if engine.commandProcessor.activeCommand == "MOVE" {
                engine.commandProcessor.handleCommandClick(worldX: wx, worldY: wy)
            } else if let snap = snapMgr.currentSnapResult {
                engine.commandProcessor.handleCommandClick(worldX: snap.worldPos.x, worldY: snap.worldPos.y)
            } else {
                engine.commandProcessor.handleCommandClick(worldX: wx, worldY: wy)
            }
            return
        }

        // Route to active feature command (if any). Use snapped coords when available.
        if let featureCmd = engine.commandProcessor.activeFeatureCommand {
            let snapWX: Double
            let snapWY: Double
            if let snap = snapMgr.currentSnapResult {
                snapWX = snap.worldPos.x
                snapWY = snap.worldPos.y
            } else {
                snapWX = wx
                snapWY = wy
            }
            // Clear OTRACK tracking points on click (point placed).
            snapMgr.lockedSnap = nil
            engine.snap.snapTrackingEngine.clear()
            snapMgr.lastPolarResult = nil
            let result = featureCmd.handleMouseClick(worldX: snapWX, worldY: snapWY, engine: engine, processor: engine.commandProcessor)
            if result == .finished {
                snapMgr.currentSnapResult = nil
                engine.commandProcessor.finishFeatureCommand(engine: engine)
            }
            return
        }

        if interaction.rectSelectActive {
            interaction.rectSelectActive = false
            interaction.rectSelectPreviewHandles.removeAll()
            let minX = min(interaction.rectSelectStartX, interaction.rectSelectCurrentX)
            let minY = min(interaction.rectSelectStartY, interaction.rectSelectCurrentY)
            let maxX = max(interaction.rectSelectStartX, interaction.rectSelectCurrentX)
            let maxY = max(interaction.rectSelectStartY, interaction.rectSelectCurrentY)
            let w = maxX - minX
            let h = maxY - minY
            if w > 0 || h > 0 {
                let style: CADSelectionManager.RectSelectStyle =
                    (x >= interaction.rectSelectScreenStartX) ? .window : .crossing
                engine.cadSelection.selectInRect(
                    worldX: minX, worldY: minY,
                    worldW: w, worldH: h,
                    document: engine.document,
                    mode: interaction.cadRectSelectMode, style: style)
            }
            return
        }

        let cam = engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        
        let testX: Float
        let testY: Float
        if let snap = snapMgr.currentSnapResult {
            let sp = EngineCameraManager.worldToScreen(worldX: snap.worldPos.x, worldY: snap.worldPos.y, cam: cam)
            testX = sp.x
            testY = sp.y
        } else {
            testX = x
            testY = y
        }
        
        if beginTableBoundaryDragIfNeeded(worldX: wx, worldY: wy) {
            return
        }

        if let gripHit = engine.cadSelection.gripHitTest(
            screenX: testX, screenY: testY, document: engine.document, cam: cam,
            simplifyComplexBlocks: engine.simplifyComplexBlocks)
        {
            interaction.gripActive = true
            interaction.gripHandle = gripHit.handle
            interaction.gripType = gripHit.grip
            interaction.gripUndoSnapshot = engine.document.snapshot()
            interaction.dragLastWorldX = gripHit.worldPos.x
            interaction.dragLastWorldY = gripHit.worldPos.y
            interaction.dragTotalWorldX = 0
            interaction.dragTotalWorldY = 0
            interaction.gripDragAccumRotation = 0
            interaction.gripDragAccumScale = 1.0
            interaction.resetGripVertexEditMode()
            interaction.gripAppliedWorldPosition = gripHit.worldPos

            if case .vertex(let entityHandle, let index) = gripHit.grip,
               index < 1000,
               let constraint = CADGripSystem.lengthenConstraint(
                    for: entityHandle,
                    vertexIndex: index,
                    document: engine.document) {
                interaction.gripLengthenAnchor = constraint.anchor
                interaction.gripLengthenAxis = constraint.axis
            }

            if case .rotation = gripHit.grip,
                let center = engine.cadSelection.collectiveCenter(document: engine.document)
            {
                interaction.dragStartAngle = atan2(wy - center.y, wx - center.x)
            }
            if case .corner = gripHit.grip,
                let center = engine.cadSelection.collectiveCenter(document: engine.document)
            {
                interaction.dragStartDistance = sqrt(
                    (wx - center.x) * (wx - center.x) + (wy - center.y) * (wy - center.y))
            }
            return
        }

        let hitHandle = engine.cadSelection.hitTest(
            worldX: wx, worldY: wy, document: engine.document,
            threshold: 6.0 / engine.camera.zoom,
            simplifyComplexBlocks: engine.simplifyComplexBlocks)

        if let handle = hitHandle {
            let hitEntity = engine.document.entity(for: handle)
            let leaderContentHit = hitEntity.map {
                isLeaderContentHit(entity: $0, worldX: wx, worldY: wy)
            } ?? false
            let now = SDL_GetTicks()
            let dx = abs(x - interaction.lastClickScreenX)
            let dy = abs(y - interaction.lastClickScreenY)
            let isDoubleClick = interaction.lastClickedHandle == handle
                && (now - interaction.lastClickTime) < 400
                && dx < 8
                && dy < 8

            if let entity = engine.document.entity(for: handle),
               DataTableEditor.payload(in: entity) != nil {
                if interaction.tableCellEditorActive {
                    DataTableEditor.commitCellEditing(engine: engine)
                }

                let wasSelectedTable = engine.cadSelection.selectedCount == 1
                    && engine.cadSelection.isSelected(handle)
                    && interaction.selectedTableHandle == handle
                if !wasSelectedTable {
                    engine.cadSelection.select(handle)
                    interaction.selectTable(handle: handle)
                    interaction.lastClickTime = now
                    interaction.lastClickedHandle = handle
                    interaction.lastClickScreenX = x
                    interaction.lastClickScreenY = y
                    return
                }

                engine.cadSelection.addToSelection(handle)
                let worldPoint = Vector3(x: wx, y: wy, z: 0)
                if let cellHit = DataTableEditor.cellHit(
                    handle: handle,
                    worldPoint: worldPoint,
                    document: engine.document) {
                    interaction.selectTableCell(
                        handle: handle,
                        address: cellHit.address,
                        extending: shiftHeld && interaction.selectedTableHandle == handle)
                    if isDoubleClick {
                        DataTableEditor.beginCellEditing(
                            handle: handle,
                            address: cellHit.address,
                            engine: engine)
                    }
                } else {
                    interaction.selectTable(handle: handle)
                    if isDoubleClick {
                        engine.ui.dataTablePanelVisible = true
                    }
                }

                if isDoubleClick {
                    interaction.lastClickTime = 0
                    interaction.lastClickedHandle = nil
                } else {
                    interaction.lastClickTime = now
                    interaction.lastClickedHandle = handle
                    interaction.lastClickScreenX = x
                    interaction.lastClickScreenY = y
                }
                return
            }

            if isDoubleClick {
                if let entity = hitEntity,
                   let leaderData = entity.leaderData?.value {
                    interaction.lastClickTime = 0
                    interaction.lastClickedHandle = nil
                    if leaderContentHit && leaderData.contentType == .mtext {
                        engine.cadSelection.selectLeaderContent(handle)
                        engine.commandProcessor.executeCommand("DDEDIT")
                    } else {
                        engine.cadSelection.select(handle)
                        engine.ui.showPropertiesPanel = true
                    }
                    return
                }
                if let entity = hitEntity,
                   let blockID = entity.blockID {
                    // Skip internal table display blocks (*T blocks)
                    if let block = engine.document.block(for: blockID),
                       block.isInternalTableDisplayBlock {
                        interaction.lastClickTime = 0
                        interaction.lastClickedHandle = nil
                        return
                    }
                    if entity.dimensionMetadata != nil {
                        interaction.lastClickTime = 0
                        interaction.lastClickedHandle = nil
                        engine.cadSelection.clearSelection()
                        engine.cadSelection.addToSelection(handle)
                        engine.commandProcessor.executeCommand("DDEDIT")
                        return
                    } else {
                        interaction.lastClickTime = 0
                        interaction.lastClickedHandle = nil
                        engine.tabManager.enterBlockEditor(blockID: blockID)
                        engine.cadSelection.clearSelection()
                        return
                    }
                }
                if let entity = engine.document.entity(for: handle),
                   entity.xdata["dxf.text"] != nil {
                    interaction.lastClickTime = 0
                    interaction.lastClickedHandle = nil
                    engine.cadSelection.clearSelection()
                    engine.cadSelection.addToSelection(handle)
                    engine.commandProcessor.executeCommand("DDEDIT")
                    return
                }
            }
            interaction.lastClickTime = now
            interaction.lastClickedHandle = handle
            interaction.lastClickScreenX = x
            interaction.lastClickScreenY = y

            if shiftHeld {
                engine.cadSelection.removeFromSelection(handle)
            } else if hitEntity?.leaderData != nil && leaderContentHit {
                engine.cadSelection.selectLeaderContent(handle)
            } else {
                engine.cadSelection.addToSelection(handle)
            }
            return
        }

        interaction.lastClickTime = 0
        interaction.lastClickedHandle = nil

        interaction.rectSelectActive = true
        interaction.rectSelectScreenStartX = x
        interaction.rectSelectStartX = wx
        interaction.rectSelectStartY = wy
        interaction.rectSelectCurrentX = wx
        interaction.rectSelectCurrentY = wy
        interaction.cadRectSelectMode = shiftHeld ? .subtract : .add
    }

    internal func handleToolMouseUp(x: Float, y: Float) {
        let interaction = engine.interaction
        if let tableDrag = interaction.tableBoundaryDrag {
            if tableDrag.moved {
                engine.document.pushUndo(tableDrag.undoSnapshot)
                engine.document.invalidateEntityGrid()
                engine.document.markEdited(regenerate: true)
                engine.tabManager.markActiveDirty()
            }
            interaction.tableBoundaryDrag = nil
            interaction.hoveredTableBoundary = nil
            return
        }
        if interaction.gripActive {
            let moved = interaction.dragTotalWorldX != 0 || interaction.dragTotalWorldY != 0
            switch interaction.gripType {
            case .vertex(let entityHandle, let index):
                if CADLeaderGripIndex.target(for: index) != nil {
                    engine.document.invalidateEntityGrid()
                    engine.geometryManager.buildSpatialGridIfNeeded()
                } else if index < 1000 {
                    engine.cadBridge.vertexEditor.endVertexDirectEdit(
                        handle: entityHandle, vertexIndex: index)
                    engine.document.invalidateEntityGrid()
                    engine.geometryManager.buildSpatialGridIfNeeded()
                }
            case .midpoint(let entityHandle, let aIndex, let bIndex):
                engine.cadBridge.vertexEditor.endVertexDirectEdit(
                    handle: entityHandle, vertexIndex: aIndex)
                engine.cadBridge.vertexEditor.endVertexDirectEdit(
                    handle: entityHandle, vertexIndex: bIndex)
                engine.document.invalidateEntityGrid()
                engine.geometryManager.buildSpatialGridIfNeeded()
            default:
                break
            }
            if moved, let snapshot = interaction.gripUndoSnapshot {
                engine.document.pushUndo(snapshot)
                if let handle = interaction.gripHandle {
                    interaction.pendingPreviewHandles = [handle]
                    interaction.pendingPreviewIsBulkDrag = false
                }
                engine.document.markEdited(regenerate: true)
            }
            interaction.cachedGripGeneration = -1
            interaction.gripActive = false
            interaction.gripHandle = nil
            interaction.gripUndoSnapshot = nil
            interaction.resetGripVertexEditMode()
            
            engine.snap.currentSnapResult = nil
            engine.snap.snapTrackingEngine.clear()
            engine.snap.lastPolarResult = nil
        }
        if interaction.dragActive {
            let moved = interaction.dragTotalWorldX != 0 || interaction.dragTotalWorldY != 0
            interaction.dragActive = false
            if engine.cadSelection.hasSelection && moved {
                // Push the pre-drag snapshot captured when dragActive first became true.
                // The live transform mutations are already applied; this records the
                // original state so a single undo restores the entities to where they
                // were before the drag started.
                if let snapshot = interaction.dragUndoSnapshot {
                    engine.document.pushUndo(snapshot)
                } else {
                    engine.document.pushUndo()
                }
                interaction.pendingPreviewHandles = engine.cadSelection.selectedHandles
                interaction.pendingPreviewIsBulkDrag = true
                engine.document.markEdited(regenerate: true)
            }
            interaction.dragUndoSnapshot = nil
            
            engine.snap.currentSnapResult = nil
            engine.snap.snapTrackingEngine.clear()
            engine.snap.lastPolarResult = nil
        }
    }

    internal func handleToolMouseMotion(x: Float, y: Float) {
        let interaction = engine.interaction
        let (wx, wy) = engine.camera.screenToWorld(screenX: x, screenY: y, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
        let isLeftDown = (engine.io != nil) ? engine.io.pointee.MouseDown.0 : false

        // Heal state if SDL missed a mouse up event (e.g., releasing outside window)
        if (interaction.dragActive || interaction.gripActive || interaction.tableBoundaryDrag != nil) && !isLeftDown {
            handleToolMouseUp(x: x, y: y)
        }

        if var tableDrag = interaction.tableBoundaryDrag,
           let entity = engine.document.entity(for: tableDrag.handle) {
            let localPoint = entity.transform.inverse().transformPoint(Vector3(x: wx, y: wy, z: 0))
            let delta = localPoint - tableDrag.startLocalPoint
            DataTableEditor.applyBoundaryResize(
                handle: tableDrag.handle,
                boundary: tableDrag.boundary,
                originalData: tableDrag.originalData,
                deltaLocal: delta,
                engine: engine,
                live: true)
            tableDrag.moved = tableDrag.moved || abs(delta.x) > 1e-9 || abs(delta.y) > 1e-9
            interaction.tableBoundaryDrag = tableDrag
            return
        }

        computeSnap(worldX: wx, worldY: wy)
        let snapWX = engine.snap.currentSnapResult?.worldPos.x ?? wx
        let snapWY = engine.snap.currentSnapResult?.worldPos.y ?? wy

        if engine.commandProcessor.activeCommand != nil {
            if engine.commandProcessor.activeCommand == "MOVE" {
                engine.commandProcessor.handleCommandMotion(worldX: wx, worldY: wy)
            } else {
                engine.commandProcessor.handleCommandMotion(worldX: snapWX, worldY: snapWY)
            }
        }

        if interaction.dragActive {
            let dx = snapWX - interaction.dragLastWorldX
            let dy = snapWY - interaction.dragLastWorldY
            interaction.dragLastWorldX = snapWX
            interaction.dragLastWorldY = snapWY
            interaction.dragTotalWorldX += dx
            interaction.dragTotalWorldY += dy

            if engine.cadSelection.hasSelection {
                engine.cadSelection.moveAllSelectedLive(by: Vector3(x: dx, y: dy, z: 0), document: engine.document)
            }
            return
        }

        if interaction.gripActive {
            var dx = snapWX - interaction.dragLastWorldX
            var dy = snapWY - interaction.dragLastWorldY
            interaction.dragLastWorldX = snapWX
            interaction.dragLastWorldY = snapWY

            if case .vertex(_, let index) = interaction.gripType,
               index < 1000,
               let previous = interaction.gripAppliedWorldPosition {
                var target = Vector3(x: snapWX, y: snapWY, z: previous.z)

                if interaction.gripVertexEditMode == .lengthen,
                   let anchor = interaction.gripLengthenAnchor,
                   let axis = interaction.gripLengthenAxis {
                    let cursorFromAnchor = Vector3(
                        x: snapWX - anchor.x,
                        y: snapWY - anchor.y,
                        z: 0)
                    let distanceAlongAxis = cursorFromAnchor.x * axis.x
                        + cursorFromAnchor.y * axis.y
                    target = Vector3(
                        x: anchor.x + axis.x * distanceAlongAxis,
                        y: anchor.y + axis.y * distanceAlongAxis,
                        z: previous.z)
                }

                dx = target.x - previous.x
                dy = target.y - previous.y
                interaction.gripAppliedWorldPosition = target
            }

            interaction.dragTotalWorldX += dx
            interaction.dragTotalWorldY += dy

            // ── Dimension grip drag: update metadata and regenerate block geometry ──
            if case .vertex(let entityHandle, let index) = interaction.gripType,
               index >= 1000, index <= 1002,
               let entity = engine.document.entity(for: entityHandle),
               let box = entity.dimensionMetadata,
               let bid = entity.blockID {
                var metadata = box.value
                let worldPos: Vector3
                if engine.snap.currentSnapResult != nil {
                    worldPos = Vector3(x: snapWX, y: snapWY, z: 0)
                } else {
                    worldPos = Vector3(
                        x: interaction.dragLastWorldX,
                        y: interaction.dragLastWorldY, z: 0)
                }
                let newPos = entity.transform.inverse().transformPoint(worldPos)
                switch index {
                case 1000: metadata.defPoint = newPos       // dimension line position
                case 1001: metadata.defPoint2 = newPos       // first extension line origin
                case 1002: metadata.defPoint3 = newPos       // second extension line origin
                default: break
                }
                // Update text midpoint for linear/aligned dimensions
                if case .linearOrRotated = metadata.type, let p2 = metadata.defPoint3 {
                    let dimStart: Vector3, dimEnd: Vector3
                    let midX = (metadata.defPoint2.x + p2.x) / 2.0
                    let midY = (metadata.defPoint2.y + p2.y) / 2.0
                    let distX = abs(metadata.defPoint.x - midX)
                    let distY = abs(metadata.defPoint.y - midY)
                    if distY > distX {
                        dimStart = Vector3(x: metadata.defPoint2.x, y: metadata.defPoint.y, z: 0)
                        dimEnd = Vector3(x: p2.x, y: metadata.defPoint.y, z: 0)
                    } else {
                        dimStart = Vector3(x: metadata.defPoint.x, y: metadata.defPoint2.y, z: 0)
                        dimEnd = Vector3(x: metadata.defPoint.x, y: p2.y, z: 0)
                    }
                    metadata.textMidpoint = Vector3(x: (dimStart.x + dimEnd.x) / 2.0, y: (dimStart.y + dimEnd.y) / 2.0, z: 0)
                } else if case .aligned = metadata.type, let p2 = metadata.defPoint3 {
                    let dir = Vector3(x: cos(metadata.rotationAngle), y: sin(metadata.rotationAngle), z: 0)
                    let perp = Vector3(x: -dir.y, y: dir.x, z: 0).normalized
                    let v = Vector3(x: metadata.defPoint.x - metadata.defPoint2.x, y: metadata.defPoint.y - metadata.defPoint2.y, z: 0)
                    let offset = v.x * perp.x + v.y * perp.y
                    let dimStart = Vector3(x: metadata.defPoint2.x + perp.x * offset, y: metadata.defPoint2.y + perp.y * offset, z: 0)
                    let dimEnd = Vector3(x: p2.x + perp.x * offset, y: p2.y + perp.y * offset, z: 0)
                    metadata.textMidpoint = Vector3(x: (dimStart.x + dimEnd.x) / 2.0, y: (dimStart.y + dimEnd.y) / 2.0, z: 0)
                } else if case .radius = metadata.type {
                    // arcPoint (defPoint2) moved — slide text along radial line from center
                    let center = metadata.defPoint
                    let dir = Vector3(x: metadata.defPoint2.x - center.x, y: metadata.defPoint2.y - center.y, z: 0).normalized
                    let dist = hypot(metadata.textMidpoint.x - center.x, metadata.textMidpoint.y - center.y)
                    metadata.textMidpoint = Vector3(x: center.x + dir.x * dist, y: center.y + dir.y * dist, z: 0)
                } else if case .diameter = metadata.type {
                    // Recompute direction from updated endpoints
                    let dir = Vector3(x: metadata.defPoint2.x - metadata.defPoint.x, y: metadata.defPoint2.y - metadata.defPoint.y, z: 0).normalized
                    let mid = Vector3(x: (metadata.defPoint.x + metadata.defPoint2.x) / 2.0, y: (metadata.defPoint.y + metadata.defPoint2.y) / 2.0, z: 0)
                    let dist = hypot(metadata.textMidpoint.x - mid.x, metadata.textMidpoint.y - mid.y)
                    metadata.textMidpoint = Vector3(x: mid.x + dir.x * dist, y: mid.y + dir.y * dist, z: 0)
                } else if case .arcLength = metadata.type, let center = metadata.defPoint4 {
                    // arc grip (defPoint) moved — change dimRadius, text follows proportionally
                    let newRadius = hypot(metadata.defPoint.x - center.x, metadata.defPoint.y - center.y)
                    // Compute text angle relative to center
                    let textAngle = atan2(metadata.textMidpoint.y - center.y, metadata.textMidpoint.x - center.x)
                    // Keep text at same angle but at new radius
                    metadata.textMidpoint = Vector3(x: center.x + cos(textAngle) * newRadius, y: center.y + sin(textAngle) * newRadius, z: 0)
                }
                // Recompute measurement
                if case .linearOrRotated = metadata.type, let p2 = metadata.defPoint3 {
                    metadata.measurement = hypot(metadata.defPoint2.x - p2.x, metadata.defPoint2.y - p2.y)
                } else if case .aligned = metadata.type, let p2 = metadata.defPoint3 {
                    metadata.measurement = hypot(metadata.defPoint2.x - p2.x, metadata.defPoint2.y - p2.y)
                } else if case .radius = metadata.type {
                    metadata.measurement = hypot(metadata.defPoint2.x - metadata.defPoint.x, metadata.defPoint2.y - metadata.defPoint.y)
                } else if case .diameter = metadata.type {
                    metadata.measurement = hypot(metadata.defPoint2.x - metadata.defPoint.x, metadata.defPoint2.y - metadata.defPoint.y)
                }
                // Regenerate dimension primitives
                let style = metadata.styleOverrides ?? engine.document.dimensionStyles[metadata.styleName] ?? CADDimensionStyle.default
                let color = DimensionPrimitives.resolvedColor(for: entity, in: engine.document)
                let newPrimitives = DimensionPrimitives.generatePrimitives(for: metadata, style: style, color: color)
                engine.document.updateBlockGeometryLive(handle: bid, geometry: newPrimitives)
                // Update entity metadata (live, no undo yet)
                var updatedEntity = entity
                updatedEntity.dimensionMetadata = CADDimensionMetadataBox(metadata)
                updatedEntity.localBoundingBox = engine.document.block(for: bid)?.localBoundingBox ?? updatedEntity.localBoundingBox
                engine.document.updateEntityLive(updatedEntity)
                return
            }

            // ── Dimension center grip drag: slide text along the dimension line ──
            if case .center = interaction.gripType,
               let gripHandle = interaction.gripHandle,
               let entity = engine.document.entity(for: gripHandle),
               let box = entity.dimensionMetadata,
               let bid = entity.blockID {
                var metadata = box.value
                let worldCursor = Vector3(x: snapWX, y: snapWY, z: 0)
                let cursor = entity.transform.inverse().transformPoint(worldCursor)
                // Project cursor onto the dimension line axis so text stays on the line
                var constrainedTextMid = metadata.textMidpoint
                if case .linearOrRotated = metadata.type, let p2 = metadata.defPoint3 {
                    let midX = (metadata.defPoint2.x + p2.x) / 2.0
                    let midY = (metadata.defPoint2.y + p2.y) / 2.0
                    let isHorizontal = abs(metadata.defPoint.y - midY) > abs(metadata.defPoint.x - midX)
                    if isHorizontal {
                        // Horizontal dimension line — constrain Y, slide X
                        constrainedTextMid = Vector3(x: cursor.x, y: metadata.defPoint.y, z: 0)
                    } else {
                        // Vertical dimension line — constrain X, slide Y
                        constrainedTextMid = Vector3(x: metadata.defPoint.x, y: cursor.y, z: 0)
                    }
                } else if case .aligned = metadata.type, let p2 = metadata.defPoint3 {
                    // Project cursor onto the oblique dimension line axis
                    let dir = Vector3(x: p2.x - metadata.defPoint2.x, y: p2.y - metadata.defPoint2.y, z: 0).normalized
                    let perp = Vector3(x: -dir.y, y: dir.x, z: 0).normalized
                    // Current perpendicular offset from the line
                    let v = Vector3(x: metadata.textMidpoint.x - metadata.defPoint2.x, y: metadata.textMidpoint.y - metadata.defPoint2.y, z: 0)
                    let offset = v.x * perp.x + v.y * perp.y
                    // Project cursor onto the axis, then add the perpendicular offset
                    let cv = Vector3(x: cursor.x - metadata.defPoint2.x, y: cursor.y - metadata.defPoint2.y, z: 0)
                    let projT = cv.x * dir.x + cv.y * dir.y
                    constrainedTextMid = Vector3(
                        x: metadata.defPoint2.x + dir.x * projT + perp.x * offset,
                        y: metadata.defPoint2.y + dir.y * projT + perp.y * offset, z: 0)
                } else if case .radius = metadata.type {
                    // Constrain text along the radial line from center to arcPoint
                    let center = metadata.defPoint
                    let dir = Vector3(x: metadata.defPoint2.x - center.x, y: metadata.defPoint2.y - center.y, z: 0).normalized
                    let cv = Vector3(x: cursor.x - center.x, y: cursor.y - center.y, z: 0)
                    let projT = cv.x * dir.x + cv.y * dir.y
                    constrainedTextMid = Vector3(x: center.x + dir.x * projT, y: center.y + dir.y * projT, z: 0)
                } else if case .diameter = metadata.type {
                    // Constrain text along the diameter line direction
                    let dir = Vector3(x: metadata.defPoint2.x - metadata.defPoint.x, y: metadata.defPoint2.y - metadata.defPoint.y, z: 0).normalized
                    let mid = Vector3(x: (metadata.defPoint.x + metadata.defPoint2.x) / 2.0, y: (metadata.defPoint.y + metadata.defPoint2.y) / 2.0, z: 0)
                    let cv = Vector3(x: cursor.x - mid.x, y: cursor.y - mid.y, z: 0)
                    let projT = cv.x * dir.x + cv.y * dir.y
                    constrainedTextMid = Vector3(x: mid.x + dir.x * projT, y: mid.y + dir.y * projT, z: 0)
                } else if case .arcLength = metadata.type, let center = metadata.defPoint4 {
                    // Constrain text to slide along the arc at current dimRadius
                    let dimRadius = hypot(metadata.defPoint.x - center.x, metadata.defPoint.y - center.y)
                    let cursorAngle = atan2(cursor.y - center.y, cursor.x - center.x)
                    constrainedTextMid = Vector3(x: center.x + cos(cursorAngle) * dimRadius, y: center.y + sin(cursorAngle) * dimRadius, z: 0)
                }
                metadata.textMidpoint = constrainedTextMid
                let style = metadata.styleOverrides ?? engine.document.dimensionStyles[metadata.styleName] ?? CADDimensionStyle.default
                let color = DimensionPrimitives.resolvedColor(for: entity, in: engine.document)
                let newPrimitives = DimensionPrimitives.generatePrimitives(for: metadata, style: style, color: color)
                engine.document.updateBlockGeometryLive(handle: bid, geometry: newPrimitives)
                var updatedEntity = entity
                updatedEntity.dimensionMetadata = CADDimensionMetadataBox(metadata)
                engine.document.updateEntityLive(updatedEntity)
                return
            }

            if case .vertex(let entityHandle, let index) = interaction.gripType,
               let leaderTarget = CADLeaderGripIndex.target(for: index),
               let entity = engine.document.entity(for: entityHandle),
               var leaderData = entity.leaderData?.value {
                let worldPoint = Vector3(x: snapWX, y: snapWY, z: 0)
                let localPoint = entity.transform.inverse().transformPoint(worldPoint)

                switch leaderTarget {
                case .content:
                    let delta = localPoint - leaderData.contentPosition
                    leaderData.contentPosition = localPoint
                    if let base = leaderData.contentBasePosition {
                        leaderData.contentBasePosition = base + delta
                    }
                    for branchIndex in leaderData.branches.indices {
                        guard let lastIndex = leaderData.branches[branchIndex].vertices.indices.last else {
                            continue
                        }
                        leaderData.branches[branchIndex].vertices[lastIndex] =
                            leaderData.branches[branchIndex].vertices[lastIndex] + delta
                    }

                case .vertex(let branchIndex, let vertexIndex):
                    guard leaderData.branches.indices.contains(branchIndex),
                          leaderData.branches[branchIndex].vertices.indices.contains(vertexIndex) else {
                        return
                    }
                    leaderData.branches[branchIndex].vertices[vertexIndex] = localPoint
                }

                var updatedEntity = entity
                updatedEntity.leaderData = CADLeaderDataBox(leaderData)
                updatedEntity = engine.document.regeneratedLeaderEntity(updatedEntity)
                engine.document.updateEntityLive(updatedEntity)
                interaction.gripAppliedWorldPosition = worldPoint
                return
            }

            if applyRectangularArrayGripDrag(worldX: snapWX, worldY: snapWY) {
                return
            }

            if case .vertex(let entityHandle, let index) = interaction.gripType {
                engine.cadBridge.moveVertexDirect(
                    handle: entityHandle,
                    vertexIndex: index,
                    by: (dx, dy),
                    in: engine.geometryManager,
                    document: engine.document,
                    spriteManager: engine.spriteManager)
                return
            }

            if case .midpoint(let entityHandle, let aIndex, let bIndex) = interaction.gripType {
                engine.cadBridge.moveVertexDirect(
                    handle: entityHandle,
                    vertexIndex: aIndex,
                    by: (dx, dy),
                    in: engine.geometryManager,
                    document: engine.document,
                    spriteManager: engine.spriteManager)
                engine.cadBridge.moveVertexDirect(
                    handle: entityHandle,
                    vertexIndex: bIndex,
                    by: (dx, dy),
                    in: engine.geometryManager,
                    document: engine.document,
                    spriteManager: engine.spriteManager)
                return
            }

            if let center = engine.cadSelection.collectiveCenter(document: engine.document) {
                if interaction.gripType == .rotation {
                    let newAngle = atan2(snapWY - center.y, snapWX - center.x)
                    let da = newAngle - interaction.dragStartAngle
                    interaction.dragStartAngle = newAngle
                    interaction.gripDragAccumRotation += da
                    engine.cadSelection.rotateAllSelectedLive(around: center, angleDeltaRadians: da, document: engine.document)
                } else if case .corner = interaction.gripType {
                    let newDist = sqrt((snapWX - center.x)*(snapWX - center.x) + (snapWY - center.y)*(snapWY - center.y))
                    if interaction.dragStartDistance > 1e-9 {
                        let scaleFactor = newDist / interaction.dragStartDistance
                        interaction.dragStartDistance = newDist
                        interaction.gripDragAccumScale *= scaleFactor
                        engine.cadSelection.scaleAllSelectedLive(around: center, factor: scaleFactor, document: engine.document)
                    }
                } else {
                    engine.document.moveEntitiesLive(handles: [interaction.gripHandle!], by: Vector3(x: dx, y: dy, z: 0))
                }
            }
            return
        }

        if interaction.rectSelectActive {
            interaction.rectSelectCurrentX = wx
            interaction.rectSelectCurrentY = wy
            return
        }

        let shiftHeld = (engine.io != nil) ? engine.io.pointee.KeyShift : false

        if isLeftDown && !shiftHeld && engine.commandProcessor.activeCommand == nil && engine.commandProcessor.activeFeatureCommand == nil {
            let dx = abs(x - interaction.dragLastScreenX)
            let dy = abs(y - interaction.dragLastScreenY)
            if !interaction.dragActive && (dx > 3 || dy > 3) {
                if engine.cadSelection.hasSelection {
                    let hoverHandle = engine.cadSelection.hitTest(
                        worldX: wx, worldY: wy, document: engine.document,
                        threshold: 6.0 / engine.camera.zoom,
                        simplifyComplexBlocks: engine.simplifyComplexBlocks)
                    if let h = hoverHandle, engine.cadSelection.selectedHandles.contains(h) {
                        interaction.dragActive = true
                        interaction.dragUndoSnapshot = engine.document.snapshot()
                        interaction.dragLastWorldX = wx
                        interaction.dragLastWorldY = wy
                        interaction.dragTotalWorldX = 0
                        interaction.dragTotalWorldY = 0
                    }
                }
            }
        }

        interaction.dragLastScreenX = x
        interaction.dragLastScreenY = y
        updateHoveredTableBoundary(worldX: wx, worldY: wy)

        hoverCoordinator.update(
            worldX: wx,
            worldY: wy,
            screenX: x,
            screenY: y)

        if let featureCmd = engine.commandProcessor.activeFeatureCommand {
            featureCmd.handleMouseMotion(worldX: snapWX, worldY: snapWY, engine: engine, processor: engine.commandProcessor)
        }
    }

    private func isLeaderContentHit(
        entity: CADEntity,
        worldX: Double,
        worldY: Double
    ) -> Bool {
        guard let data = entity.leaderData?.value else { return false }
        let style = data.styleOverrides
            ?? engine.document.leaderStyle(named: data.styleName)
            ?? .standard
        let localPoint = entity.transform.inverse().transformPoint(
            Vector3(x: worldX, y: worldY, z: 0))
        let scale = entity.transform.scale
        let localTolerance = (8.0 / max(engine.camera.zoom, 0.001))
            / max(abs(scale.x), abs(scale.y), 0.001)
        return CADLeaderGeometry.contentHitTest(
            data: data,
            style: style,
            localPoint: localPoint,
            tolerance: localTolerance,
            blockResolver: { name in
                engine.document.allBlocks.first {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }
            })
    }

    private func beginTableBoundaryDragIfNeeded(worldX: Double, worldY: Double) -> Bool {
        let interaction = engine.interaction
        guard engine.commandProcessor.activeCommand == nil,
              engine.commandProcessor.activeFeatureCommand == nil,
              engine.cadSelection.selectedCount == 1,
              let handle = engine.cadSelection.lastSelectedHandle,
              engine.cadSelection.isSelected(handle),
              let entity = engine.document.entity(for: handle),
              let table = DataTableEditor.payload(in: entity) else { return false }

        let localPoint = entity.transform.inverse().transformPoint(Vector3(x: worldX, y: worldY, z: 0))
        let scale = entity.transform.scale
        let worldTolerance = 6.0 / max(engine.camera.zoom, 0.001)
        let toleranceX = worldTolerance / max(abs(scale.x), 0.001)
        let toleranceY = worldTolerance / max(abs(scale.y), 0.001)
        guard let boundary = DataTableTessellator.boundaryHitTest(
            data: table.data,
            origin: table.origin,
            localPoint: localPoint,
            toleranceX: toleranceX,
            toleranceY: toleranceY) else { return false }

        if interaction.tableCellEditorActive {
            DataTableEditor.commitCellEditing(engine: engine)
        }
        interaction.tableBoundaryDrag = EngineInteractionManager.DataTableBoundaryDragState(
            handle: handle,
            boundary: boundary,
            startLocalPoint: localPoint,
            originalData: table.data,
            undoSnapshot: engine.document.snapshot())
        interaction.hoveredTableBoundary = boundary
        return true
    }

    private func updateHoveredTableBoundary(worldX: Double, worldY: Double) {
        let interaction = engine.interaction
        guard interaction.tableBoundaryDrag == nil,
              engine.commandProcessor.activeCommand == nil,
              engine.commandProcessor.activeFeatureCommand == nil,
              engine.cadSelection.selectedCount == 1,
              let handle = engine.cadSelection.lastSelectedHandle,
              let entity = engine.document.entity(for: handle),
              let table = DataTableEditor.payload(in: entity) else {
            interaction.hoveredTableBoundary = nil
            return
        }
        let localPoint = entity.transform.inverse().transformPoint(Vector3(x: worldX, y: worldY, z: 0))
        let scale = entity.transform.scale
        let worldTolerance = 6.0 / max(engine.camera.zoom, 0.001)
        interaction.hoveredTableBoundary = DataTableTessellator.boundaryHitTest(
            data: table.data,
            origin: table.origin,
            localPoint: localPoint,
            toleranceX: worldTolerance / max(abs(scale.x), 0.001),
            toleranceY: worldTolerance / max(abs(scale.y), 0.001))
    }

    private func computeSnap(worldX: Double, worldY: Double) {
        // Full snap logic from Engine+Loop.swift, adapted to use engine.snap...
        let snapMgr = engine.snap
        let interaction = engine.interaction
        
        let shouldSnap = (engine.commandProcessor.activeFeatureCommand?.isSnappingEnabled ?? false)
            || (engine.commandProcessor.activeCommand == "MOVE")
            || interaction.gripActive
            || (interaction.dragActive && engine.cadSelection.hasSelection)

        guard shouldSnap else {
            snapMgr.currentSnapResult = nil
            snapMgr.lastPolarResult = nil
            snapMgr.lockedSnap = nil
            engine.snap.snapTrackingEngine.clear()
            return
        }

        let acquireThreshold = snapMgr.snapAcquisitionThreshold(cameraZoom: engine.camera.zoom)
        let releaseThreshold = snapMgr.snapReleaseThreshold(cameraZoom: engine.camera.zoom)
        let ppwu = engine.camera.zoom
        let now = SDL_GetTicks()
        let cursorWorld = Vector3(x: worldX, y: worldY, z: 0)

        snapMgr.currentSnapResult = nil
        snapMgr.lastPolarResult = nil

        if let locked = snapMgr.lockedSnap {
            if !snapMgr.shouldStickyLock(locked) {
                snapMgr.lockedSnap = nil
            } else {
                let dx = worldX - locked.worldPos.x
                let dy = worldY - locked.worldPos.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist <= releaseThreshold {
                    if snapMgr.objectSnapTrackingEnabled {
                        let wiggleWorld = snapMgr.hoverWigglePixels / max(ppwu, 0.001)
                        let otrackInc = snapMgr.polarTrackingEnabled ? snapMgr.polarAngleIncrement : 90.0
                        _ = engine.snap.snapTrackingEngine.update(
                            currentSnap: locked,
                            cursorWorld: cursorWorld,
                            polarIncrementDeg: otrackInc,
                            snapThresholdWorld: acquireThreshold,
                            wiggleThresholdWorld: wiggleWorld,
                            nowTicks: now)
                    }

                    snapMgr.currentSnapResult = locked
                    return
                }
                snapMgr.lockedSnap = nil
            }
        }

        let visibleEntities: [CADEntity]
        if let gridHandles = engine.document.entityHandlesInWorldRect(
            minX: worldX - acquireThreshold,
            minY: worldY - acquireThreshold,
            maxX: worldX + acquireThreshold,
            maxY: worldY + acquireThreshold
        ) {
            visibleEntities = gridHandles.compactMap { handle in
                if interaction.gripActive, let gripHandle = interaction.gripHandle, handle == gripHandle { return nil }
                if interaction.dragActive, engine.cadSelection.selectedHandles.contains(handle) { return nil }
                guard let entity = engine.document.entity(for: handle) else { return nil }
                guard let layer = engine.document.layer(for: entity.layerID), layer.isVisible else { return nil }
                return entity
            }
        } else {
            visibleEntities = engine.document.entitiesView.filter { entity in
                if interaction.gripActive, let gripHandle = interaction.gripHandle, entity.handle == gripHandle { return false }
                if interaction.dragActive, engine.cadSelection.selectedHandles.contains(entity.handle) { return false }
                guard let layer = engine.document.layer(for: entity.layerID) else { return false }
                return layer.isVisible
            }
        }

        let discreteAnchorSnap = engine.snap.snapEngine.nearestSnap(
            worldX: worldX, worldY: worldY,
            entities: Array(visibleEntities),
            threshold: acquireThreshold,
            resolveGeometry: { [unowned self] in self.engine.document.resolvedGeometry(for: $0) },
            extensionSnapEnabled: snapMgr.extensionSnapEnabled,
            extensionThresholdPx: 12.0,
            pixelsPerWorldUnit: ppwu,
            gridSnapEnabled: false,
            nearestOnCurveOverride: false)

        if snapMgr.objectSnapTrackingEnabled {
            let otrackInc = snapMgr.polarTrackingEnabled ? snapMgr.polarAngleIncrement : 90.0
            let wiggleWorld = snapMgr.hoverWigglePixels / max(ppwu, 0.001)
            let otrackResult = engine.snap.snapTrackingEngine.update(
                currentSnap: discreteAnchorSnap,
                cursorWorld: cursorWorld,
                polarIncrementDeg: otrackInc,
                snapThresholdWorld: acquireThreshold,
                wiggleThresholdWorld: wiggleWorld,
                nowTicks: now)

            // Ortho constraint: hard-lock cursor to the SNAPANG-rotated axes.
            // Runs here (after OTRACK, before wide extension snap) but only when no entity
            // anchor snap is within the narrow acquisition threshold. Entity snap points
            // (endpoints, midpoints, centers, etc.) take priority over ortho constraints.
            if snapMgr.orthoEnabled,
               snapMgr.currentSnapResult == nil,
               discreteAnchorSnap == nil {
                var orthoRef: Vector3? = nil
                if let mref = engine.commandProcessor.commandRefPoint, engine.commandProcessor.activeCommand == "MOVE" {
                    orthoRef = Vector3(x: mref.0, y: mref.1, z: 0)
                } else if let refPt = getLastReferencePoint() {
                    orthoRef = refPt
                }
                if let orthoRef {
                    applyOrthoConstraint(cursor: cursorWorld, reference: orthoRef)
                }
            }

            // Only compute wide extension snaps if ortho didn't constrain the cursor.
            if snapMgr.currentSnapResult == nil {
            snapMgr.currentSnapResult = engine.snap.snapEngine.nearestSnap(
                worldX: worldX, worldY: worldY,
                entities: Array(visibleEntities),
                threshold: acquireThreshold,
                resolveGeometry: { [unowned self] in self.engine.document.resolvedGeometry(for: $0) },
                extensionSnapEnabled: snapMgr.extensionSnapEnabled,
                extensionThresholdPx: snapMgr.trajectoryTrackingAperturePixels,
                pixelsPerWorldUnit: ppwu,
                gridSnapEnabled: false,
                nearestOnCurveOverride: false)

            var bestOsnapDist = snapMgr.currentSnapResult.map { snap in
                let dx = worldX - snap.worldPos.x
                let dy = worldY - snap.worldPos.y
                return sqrt(dx * dx + dy * dy)
            } ?? acquireThreshold

            if let featureCmd = engine.commandProcessor.activeFeatureCommand {
                let drawingPts = featureCmd.getDrawingSnapPoints()

                for (i, pt) in drawingPts.enumerated() {
                    let dx = worldX - pt.x
                    let dy = worldY - pt.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < bestOsnapDist {
                        bestOsnapDist = dist
                        snapMgr.currentSnapResult = SnapResult(
                            entityHandle: PhrostEngine.drawingSnapSentinel,
                            anchor: .vertex(localPosition: pt, index: i),
                            worldPos: pt)
                    }
                }

                if drawingPts.count >= 2 {
                    for i in 0..<(drawingPts.count - 1) {
                        let a = drawingPts[i]
                        let b = drawingPts[i + 1]
                        let midX = (a.x + b.x) * 0.5
                        let midY = (a.y + b.y) * 0.5
                        let dx = worldX - midX
                        let dy = worldY - midY
                        let dist = sqrt(dx * dx + dy * dy)
                        if dist < bestOsnapDist {
                            bestOsnapDist = dist
                            snapMgr.currentSnapResult = SnapResult(
                                entityHandle: PhrostEngine.drawingSnapSentinel,
                                anchor: .midpoint(localPosition: Vector3(x: midX, y: midY, z: 0), segmentIndex: i),
                                worldPos: Vector3(x: midX, y: midY, z: 0))
                        }
                    }
                }
            }

            if let snap = snapMgr.currentSnapResult {
                snapMgr.lastPolarResult = nil
                snapMgr.applyStickyLockIfNeeded(snap)
                return
            }
            } // end if snapMgr.currentSnapResult == nil (wide extension snap wrapper)

            var bestTrackingSnap: SnapResult? = nil
            var bestTrackingDist = acquireThreshold

            if let ot = otrackResult {
                let dx = worldX - ot.worldPos.x
                let dy = worldY - ot.worldPos.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestTrackingDist {
                    bestTrackingDist = dist
                    bestTrackingSnap = ot
                }
            }

            var bestTrackingInfo: PolarTrackingResult? = nil



            if let trajectory = nearestDrawingTrajectorySnap(
                cursor: cursorWorld,
                threshold: snapMgr.trajectoryTrackingThreshold(cameraZoom: ppwu),
                angularToleranceDeg: snapMgr.trajectoryTrackingAngularToleranceDeg
            ) {
                bestTrackingDist = 0
                bestTrackingSnap = SnapResult(
                    entityHandle: PhrostEngine.drawingSnapSentinel,
                    anchor: .nearest(localPosition: trajectory.worldPos),
                    worldPos: trajectory.worldPos
                )
                bestTrackingInfo = trajectory
            }


            var bestPolarSnap: SnapResult? = nil
            var bestPolarDist = acquireThreshold
            var bestPolarInfo: PolarTrackingResult? = nil

            // Polar tracking: ortho already ran earlier and set currentSnapResult if applicable.
            if snapMgr.polarTrackingEnabled && snapMgr.currentSnapResult == nil {
                var polarRefs: [Vector3] = []
                if let refPt = getLastReferencePoint() {
                    polarRefs.append(refPt)
                }
                for tp in engine.snap.snapTrackingEngine.trackingPoints {
                    polarRefs.append(tp.worldPos)
                }
                for refPt in polarRefs {
                    if let polarResult = PolarTracking.nearestPolar(
                        reference: refPt,
                        cursor: cursorWorld,
                        incrementDeg: snapMgr.polarAngleIncrement,
                        thresholdPx: snapMgr.snapAperturePixels,
                        pixelsPerWorldUnit: ppwu)
                    {
                        let dx = worldX - polarResult.worldPos.x
                        let dy = worldY - polarResult.worldPos.y
                        let dist = sqrt(dx * dx + dy * dy)
                        if dist < bestPolarDist {
                            bestPolarDist = dist
                            bestPolarSnap = SnapResult(
                                entityHandle: PhrostEngine.drawingSnapSentinel,
                                anchor: .nearest(localPosition: polarResult.worldPos),
                                worldPos: polarResult.worldPos)
                            bestPolarInfo = polarResult
                        }
                    }
                }
            }

            if snapMgr.currentSnapResult == nil {
                if let trackSnap = bestTrackingSnap {
                    snapMgr.currentSnapResult = trackSnap
                    snapMgr.lastPolarResult = bestTrackingInfo
                } else if let polarSnap = bestPolarSnap {
                    snapMgr.currentSnapResult = polarSnap
                    snapMgr.lastPolarResult = bestPolarInfo
                }
            }
            // If neither tracking nor polar fired, leave lastPolarResult as-is
            // (it may have been set by ortho constraint above).

            if let snap = snapMgr.currentSnapResult {
                snapMgr.applyStickyLockIfNeeded(snap)
                return
            }

            if engine.snap.gridSnapEnabled {
                if let gridSnap = SnapEngine.nearestGridSnap(
                    worldX: worldX, worldY: worldY,
                    originX: engine.snap.gridOriginX, originY: engine.snap.gridOriginY,
                    spacing: engine.snap.effectiveGridSpacing(windowWidth: engine.windowWidth, cameraZoom: engine.camera.zoom),
                    threshold: acquireThreshold)
                {
                    snapMgr.currentSnapResult = gridSnap
                    snapMgr.applyStickyLockIfNeeded(gridSnap)
                    return
                }
            }

            if engine.snap.snapEngine.nearestOnCurveEnabled {
                snapMgr.currentSnapResult = engine.snap.snapEngine.nearestSnap(
                    worldX: worldX, worldY: worldY,
                    entities: Array(visibleEntities),
                    threshold: acquireThreshold,
                    resolveGeometry: { [unowned self] in self.engine.document.resolvedGeometry(for: $0) },
                    extensionSnapEnabled: false,
                    gridSnapEnabled: false,
                    nearestOnCurveOverride: true)

                if snapMgr.currentSnapResult == nil, let featureCmd = engine.commandProcessor.activeFeatureCommand {
                    let drawingPts = featureCmd.getDrawingSnapPoints()
                    if drawingPts.count >= 2 {
                        if let np = CADGeometryMath.nearestPointOnPolyline(to: cursorWorld, points: drawingPts) {
                            let dx = worldX - np.x
                            let dy = worldY - np.y
                            let dist = sqrt(dx * dx + dy * dy)
                            if dist < acquireThreshold {
                                snapMgr.currentSnapResult = SnapResult(
                                    entityHandle: PhrostEngine.drawingSnapSentinel,
                                    anchor: .nearest(localPosition: np),
                                    worldPos: np)
                            }
                        }
                    }
                }

                if let snap = snapMgr.currentSnapResult {
                    snapMgr.applyStickyLockIfNeeded(snap)
                }
            }
        } else {
            snapMgr.lockedSnap = nil
            engine.snap.snapTrackingEngine.clear()



            snapMgr.currentSnapResult = engine.snap.snapEngine.nearestSnap(
                worldX: worldX, worldY: worldY,
                entities: Array(visibleEntities),
                threshold: acquireThreshold,
                resolveGeometry: { [unowned self] in self.engine.document.resolvedGeometry(for: $0) },
                extensionSnapEnabled: false,
                extensionThresholdPx: snapMgr.trajectoryTrackingAperturePixels,
                pixelsPerWorldUnit: ppwu,
                gridSnapEnabled: false,
                nearestOnCurveOverride: false)

            var bestDist = snapMgr.currentSnapResult.map { snap in
                let dx = worldX - snap.worldPos.x
                let dy = worldY - snap.worldPos.y
                return sqrt(dx * dx + dy * dy)
            } ?? acquireThreshold

            if let featureCmd = engine.commandProcessor.activeFeatureCommand {
                let drawingPts = featureCmd.getDrawingSnapPoints()
                for (i, pt) in drawingPts.enumerated() {
                    let dx = worldX - pt.x
                    let dy = worldY - pt.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < bestDist {
                        bestDist = dist
                        snapMgr.currentSnapResult = SnapResult(
                            entityHandle: PhrostEngine.drawingSnapSentinel,
                            anchor: .vertex(localPosition: pt, index: i),
                            worldPos: pt)
                    }
                }
                if drawingPts.count >= 2 {
                    for i in 0..<(drawingPts.count - 1) {
                        let a = drawingPts[i]
                        let b = drawingPts[i + 1]
                        let midX = (a.x + b.x) * 0.5
                        let midY = (a.y + b.y) * 0.5
                        let dx = worldX - midX
                        let dy = worldY - midY
                        let dist = sqrt(dx * dx + dy * dy)
                        if dist < bestDist {
                            bestDist = dist
                            snapMgr.currentSnapResult = SnapResult(
                                entityHandle: PhrostEngine.drawingSnapSentinel,
                                anchor: .midpoint(localPosition: Vector3(x: midX, y: midY, z: 0), segmentIndex: i),
                                worldPos: Vector3(x: midX, y: midY, z: 0))
                        }
                    }
                }
            }

            if snapMgr.currentSnapResult == nil,
               !snapMgr.orthoEnabled,
               let trajectory = nearestDrawingTrajectorySnap(
                    cursor: cursorWorld,
                    threshold: snapMgr.trajectoryTrackingThreshold(cameraZoom: ppwu),
                    angularToleranceDeg: snapMgr.trajectoryTrackingAngularToleranceDeg
               ) {
                snapMgr.currentSnapResult = SnapResult(
                    entityHandle: PhrostEngine.drawingSnapSentinel,
                    anchor: .nearest(localPosition: trajectory.worldPos),
                    worldPos: trajectory.worldPos
                )
                snapMgr.lastPolarResult = trajectory
            }

            // Ortho constraint: hard-lock cursor to the SNAPANG-rotated axes.
            if snapMgr.currentSnapResult == nil, snapMgr.orthoEnabled {
                var orthoRef: Vector3? = nil
                if let mref = engine.commandProcessor.commandRefPoint, engine.commandProcessor.activeCommand == "MOVE" {
                    orthoRef = Vector3(x: mref.0, y: mref.1, z: 0)
                } else if let refPt = getLastReferencePoint() {
                    orthoRef = refPt
                }
                if let orthoRef {
                    applyOrthoConstraint(cursor: cursorWorld, reference: orthoRef)
                }
            }

            // Grid snap: only fires if no ortho result was produced (ortho already integrated grid snap).
            if snapMgr.currentSnapResult == nil, engine.snap.gridSnapEnabled {
                snapMgr.currentSnapResult = SnapEngine.nearestGridSnap(
                    worldX: worldX, worldY: worldY,
                    originX: engine.snap.gridOriginX, originY: engine.snap.gridOriginY,
                    spacing: engine.snap.effectiveGridSpacing(windowWidth: engine.windowWidth, cameraZoom: engine.camera.zoom),
                    threshold: acquireThreshold)
            }

            // Polar tracking: skipped when ortho is active (ortho takes priority).
            if snapMgr.currentSnapResult == nil, snapMgr.polarTrackingEnabled, !snapMgr.orthoEnabled {
                var polarRefs: [Vector3] = []
                if let refPt = getLastReferencePoint() {
                    polarRefs.append(refPt)
                }
                for refPt in polarRefs {
                    if let polarResult = PolarTracking.nearestPolar(
                        reference: refPt,
                        cursor: cursorWorld,
                        incrementDeg: snapMgr.polarAngleIncrement,
                        thresholdPx: snapMgr.snapAperturePixels,
                        pixelsPerWorldUnit: ppwu)
                    {
                        snapMgr.currentSnapResult = SnapResult(
                            entityHandle: PhrostEngine.drawingSnapSentinel,
                            anchor: .nearest(localPosition: polarResult.worldPos),
                            worldPos: polarResult.worldPos)
                        snapMgr.lastPolarResult = polarResult
                        break
                    }
                }
            } else {
                snapMgr.lastPolarResult = nil
            }

            if snapMgr.currentSnapResult == nil, engine.snap.snapEngine.nearestOnCurveEnabled {
                snapMgr.currentSnapResult = engine.snap.snapEngine.nearestSnap(
                    worldX: worldX, worldY: worldY,
                    entities: Array(visibleEntities),
                    threshold: acquireThreshold,
                    resolveGeometry: { [unowned self] in self.engine.document.resolvedGeometry(for: $0) },
                    extensionSnapEnabled: false,
                    gridSnapEnabled: false,
                    nearestOnCurveOverride: true)

                if snapMgr.currentSnapResult == nil, let featureCmd = engine.commandProcessor.activeFeatureCommand {
                    let drawingPts = featureCmd.getDrawingSnapPoints()
                    if drawingPts.count >= 2 {
                        if let np = CADGeometryMath.nearestPointOnPolyline(to: cursorWorld, points: drawingPts) {
                            let dx = worldX - np.x
                            let dy = worldY - np.y
                            let dist = sqrt(dx * dx + dy * dy)
                            if dist < acquireThreshold {
                                snapMgr.currentSnapResult = SnapResult(
                                    entityHandle: PhrostEngine.drawingSnapSentinel,
                                    anchor: .nearest(localPosition: np),
                                    worldPos: np)
                            }
                        }
                    }
                }
            }

            if let snap = snapMgr.currentSnapResult {
                snapMgr.applyStickyLockIfNeeded(snap)
            }
        }
    }

    private func applyOrthoConstraint(cursor: Vector3, reference: Vector3) {
        let snapMgr = engine.snap
        let angleRad = snapMgr.snapAngle * .pi / 180.0
        let cosAngle = cos(angleRad)
        let sinAngle = sin(angleRad)
        let originX = snapMgr.gridOriginX
        let originY = snapMgr.gridOriginY

        func snapCoordinates(for point: Vector3) -> (x: Double, y: Double) {
            let dx = point.x - originX
            let dy = point.y - originY
            return (
                x: dx * cosAngle + dy * sinAngle,
                y: -dx * sinAngle + dy * cosAngle
            )
        }

        let cursorSnap = snapCoordinates(for: cursor)
        let referenceSnap = snapCoordinates(for: reference)
        let deltaX = cursorSnap.x - referenceSnap.x
        let deltaY = cursorSnap.y - referenceSnap.y
        let absDeltaX = abs(deltaX)
        let absDeltaY = abs(deltaY)
        let bias: Double = 1.0 - 1e-4

        let lockHorizontal: Bool
        if snapMgr.orthoLastWasHorizontal && absDeltaX >= absDeltaY * bias {
            lockHorizontal = true
        } else if snapMgr.orthoLastWasVertical && absDeltaY >= absDeltaX * bias {
            lockHorizontal = false
        } else if absDeltaX >= absDeltaY {
            lockHorizontal = true
            snapMgr.orthoLastWasHorizontal = true
            snapMgr.orthoLastWasVertical = false
        } else {
            lockHorizontal = false
            snapMgr.orthoLastWasHorizontal = false
            snapMgr.orthoLastWasVertical = true
        }

        var constrainedSnapX = lockHorizontal ? cursorSnap.x : referenceSnap.x
        var constrainedSnapY = lockHorizontal ? referenceSnap.y : cursorSnap.y
        if snapMgr.gridSnapEnabled {
            let spacing = snapMgr.effectiveGridSpacing(
                windowWidth: engine.windowWidth,
                cameraZoom: engine.camera.zoom
            )
            if lockHorizontal {
                constrainedSnapX = round(constrainedSnapX / spacing) * spacing
            } else {
                constrainedSnapY = round(constrainedSnapY / spacing) * spacing
            }
        }

        let constrained = Vector3(
            x: originX + constrainedSnapX * cosAngle - constrainedSnapY * sinAngle,
            y: originY + constrainedSnapX * sinAngle + constrainedSnapY * cosAngle,
            z: 0
        )
        let direction = lockHorizontal ? deltaX : deltaY
        let axisOffset: Double
        if lockHorizontal {
            axisOffset = direction >= 0 ? 0.0 : 180.0
        } else {
            axisOffset = direction >= 0 ? 90.0 : 270.0
        }
        var angleDeg = (snapMgr.snapAngle + axisOffset).truncatingRemainder(dividingBy: 360.0)
        if angleDeg < 0 { angleDeg += 360.0 }
        let constrainedDistance = hypot(
            constrained.x - reference.x,
            constrained.y - reference.y
        )

        snapMgr.currentSnapResult = SnapResult(
            entityHandle: PhrostEngine.drawingSnapSentinel,
            anchor: .nearest(localPosition: constrained),
            worldPos: constrained
        )
        snapMgr.lastPolarResult = PolarTrackingResult(
            worldPos: constrained,
            angleDeg: angleDeg,
            distance: constrainedDistance,
            reference: reference
        )
    }

    private func getLastReferencePoint() -> Vector3? {
        if let featCmd = engine.commandProcessor.activeFeatureCommand {
            let pts = featCmd.getDrawingSnapPoints()
            if let last = pts.last {
                return last
            }
        }
        if engine.commandProcessor.activeCommand == "MOVE",
           let ref = engine.commandProcessor.commandRefPoint {
            return Vector3(x: ref.0, y: ref.1, z: 0)
        }
        return nil
    }

    private func nearestDrawingTrajectorySnap(
        cursor: Vector3,
        threshold: Double,
        angularToleranceDeg: Double
    ) -> PolarTrackingResult? {
        guard let featureCmd = engine.commandProcessor.activeFeatureCommand else { return nil }

        let pts = featureCmd.getDrawingSnapPoints()
        guard pts.count >= 2 else { return nil }

        let a = pts[pts.count - 2]
        let b = pts[pts.count - 1]

        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1e-9 else { return nil }

        let ux = dx / len
        let uy = dy / len

        let rx = cursor.x - b.x
        let ry = cursor.y - b.y

        let t = rx * ux + ry * uy
        let perp = abs(rx * uy - ry * ux)

        let angularRad = angularToleranceDeg * .pi / 180.0
        let allowed = max(threshold, abs(t) * sin(angularRad))

        guard perp <= allowed else { return nil }

        let proj = Vector3(
            x: b.x + ux * t,
            y: b.y + uy * t,
            z: 0
        )

        return PolarTrackingResult(
            worldPos: proj,
            angleDeg: atan2(uy, ux) * 180.0 / .pi,
            distance: t,
            reference: b
        )
    }




    private func applyRectangularArrayGripDrag(worldX: Double, worldY: Double) -> Bool {
        let interaction = engine.interaction
        guard let handle = interaction.gripHandle,
              var entity = engine.document.entity(for: handle),
              var array = entity.arrayData,
              array.kind == .rectangular else {
            return false
        }

        let axis: Int
        let changesSpacing: Bool
        switch interaction.gripType {
        case .arraySpacing(let value):
            axis = value
            changesSpacing = true
        case .arrayCount(let value):
            axis = value
            changesSpacing = false
        default:
            return false
        }

        let localCursor = entity.transform.inverse().transformPoint(
            Vector3(x: worldX, y: worldY, z: entity.transform.position.z))
        let c = cos(array.axisAngle)
        let s = sin(array.axisAngle)
        let unit = axis == 0
            ? Vector3(x: c, y: s, z: 0)
            : Vector3(x: -s, y: c, z: 0)
        let projected = localCursor.x * unit.x + localCursor.y * unit.y

        if changesSpacing {
            let minimum = 1e-6
            let spacing = abs(projected) < minimum
                ? (projected < 0 ? -minimum : minimum)
                : projected
            if axis == 0 {
                array.columnSpacing = spacing
            } else {
                array.rowSpacing = spacing
            }
        } else {
            let spacing = axis == 0 ? array.columnSpacing : array.rowSpacing
            guard abs(spacing) > 1e-9 else { return true }
            let count = max(1, Int((projected / spacing).rounded()) + 1)
            if axis == 0 {
                array.columns = count
            } else {
                array.rows = count
            }
        }

        entity.arrayData = array
        engine.document.updateEntityLive(entity)
        interaction.cachedGripGeneration = -1
        return true
    }

}

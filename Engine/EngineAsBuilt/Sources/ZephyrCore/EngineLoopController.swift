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

        // The core of the "Lazy Loop": Determines if the engine should render.
        // Starts at 5 to ensure initial ImGui setup frames render cleanly.
        var framesToRender: Int = 5

        while engine.running {
            let frameStart: UInt64 = SDL_GetTicks()
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
            let isActionActive =
                interaction.dragActive || interaction.panActive || interaction.touchPanActive
                || engine.commandProcessor.activeCommand != nil || engine.commandProcessor.activeFeatureCommand != nil
                || engine.commandProcessor.commandLineActive || engine.document.isDirty
            
            if framesToRender <= 0 && !isActionActive {
                SDL_WaitEventTimeout(nil, 16)
            }

            // 2. Poll Events and check if interaction occurred
            let eventsProcessed = inputHandler.pollEvents()
            if eventsProcessed > 0 {
                framesToRender = 5
            }

            engine.camera.updateFollow(spriteManager: engine.spriteManager)
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
            if let snap = snapMgr.currentSnapResult {
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
            let now = SDL_GetTicks()
            let dx = abs(x - interaction.lastClickScreenX)
            let dy = abs(y - interaction.lastClickScreenY)
            if interaction.lastClickedHandle == handle && (now - interaction.lastClickTime) < 400 && dx < 8 && dy < 8 {
                if let entity = engine.document.entity(for: handle),
                   let blockID = entity.blockID {
                    interaction.lastClickTime = 0
                    interaction.lastClickedHandle = nil
                    engine.tabManager.enterBlockEditor(blockID: blockID)
                    engine.cadSelection.clearSelection()
                    return
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
            } else {
                // Always update lastSelectedHandle via addToSelection so
                // the Properties panel reflects the most recently clicked entity.
                // Set.insert is idempotent — already-selected handles are unaffected.
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
        if interaction.gripActive {
            let moved = interaction.dragTotalWorldX != 0 || interaction.dragTotalWorldY != 0
            switch interaction.gripType {
            case .vertex(let entityHandle, let index):
                engine.cadBridge.vertexEditor.endVertexDirectEdit(
                    handle: entityHandle, vertexIndex: index)
                engine.document.invalidateEntityGrid()
                engine.geometryManager.buildSpatialGridIfNeeded()
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
                engine.document.isDirty = true
            }
            interaction.cachedGripGeneration = -1
            interaction.gripActive = false
            interaction.gripHandle = nil
            interaction.gripUndoSnapshot = nil
            
            engine.snap.currentSnapResult = nil
            engine.snap.snapTrackingEngine.clear()
            engine.snap.lastPolarResult = nil
        }
        if interaction.dragActive {
            let moved = interaction.dragTotalWorldX != 0 || interaction.dragTotalWorldY != 0
            interaction.dragActive = false
            if engine.cadSelection.hasSelection && moved {
                // The actual transform mutations were done live, so we just
                // flag it dirty here to trigger the GPU rebuild.
                engine.document.pushUndo()
                interaction.pendingPreviewHandles = engine.cadSelection.selectedHandles
                interaction.pendingPreviewIsBulkDrag = true
                engine.document.isDirty = true
            }
            
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
        if (interaction.dragActive || interaction.gripActive) && !isLeftDown {
            handleToolMouseUp(x: x, y: y)
        }

        computeSnap(worldX: wx, worldY: wy)
        let snapWX = engine.snap.currentSnapResult?.worldPos.x ?? wx
        let snapWY = engine.snap.currentSnapResult?.worldPos.y ?? wy

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
            let dx = snapWX - interaction.dragLastWorldX
            let dy = snapWY - interaction.dragLastWorldY
            interaction.dragLastWorldX = snapWX
            interaction.dragLastWorldY = snapWY
            interaction.dragTotalWorldX += dx
            interaction.dragTotalWorldY += dy

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

        hoverCoordinator.update(
            worldX: wx,
            worldY: wy,
            screenX: x,
            screenY: y)

        if let featureCmd = engine.commandProcessor.activeFeatureCommand {
            featureCmd.handleMouseMotion(worldX: snapWX, worldY: snapWY, engine: engine, processor: engine.commandProcessor)
        }
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

            if snapMgr.polarTrackingEnabled {
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

            if let trackSnap = bestTrackingSnap {
                snapMgr.currentSnapResult = trackSnap
                snapMgr.lastPolarResult = bestTrackingInfo
            } else if let polarSnap = bestPolarSnap {
                snapMgr.currentSnapResult = polarSnap
                snapMgr.lastPolarResult = bestPolarInfo
            } else {
                snapMgr.lastPolarResult = nil
            }

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



            if snapMgr.currentSnapResult == nil, engine.snap.gridSnapEnabled {
                snapMgr.currentSnapResult = SnapEngine.nearestGridSnap(
                    worldX: worldX, worldY: worldY,
                    originX: engine.snap.gridOriginX, originY: engine.snap.gridOriginY,
                    spacing: engine.snap.effectiveGridSpacing(windowWidth: engine.windowWidth, cameraZoom: engine.camera.zoom),
                    threshold: acquireThreshold)
            }

            if snapMgr.currentSnapResult == nil, snapMgr.polarTrackingEnabled {
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




}

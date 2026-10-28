import Foundation
import CSDL3
import SwiftSDL
import SwiftSDL_image
import ImGui

// =========================================================================
// MARK: - EngineInputHandler
//
// Input event handling for PhrostEngine. Processes SDL events (keyboard,
// mouse, touch), routes them to the active command or tool, and manages
// the main loop's render throttling policy.
//
// Extracted from Engine+Loop.swift to keep the main loop file focused on
// frame pacing. Uses `unowned let engine:` to access engine state without
// creating a retain cycle — the handler's lifetime is tied to the engine's.
//
// All methods are @MainActor-isolated because they touch SDL state and
// engine properties that are only safe to access on the main thread.
// =========================================================================

@MainActor
internal final class EngineInputHandler {

    /// Weak reference to the owning engine. All engine state is accessed
    /// through this reference.
    private unowned let engine: PhrostEngine

    /// Set when a click focuses a split pane, so the matching mouse-up is
    /// swallowed too (first click focuses, it doesn't select).
    private var swallowNextMouseUp = false

    internal init(engine: PhrostEngine) {
        self.engine = engine
    }

    private func sampleActivePenStroke() {
        (engine.commandProcessor.activeFeatureCommand as? PenStrokeCommand)?.pollPenState(engine: engine)
    }

    // MARK: - Split-Pane Coordinates

    /// Absolute window coords → focused-leaf-local coords. Identity unless
    /// the main window is split (then CAD input is leaf-local while ImGui
    /// keeps absolute coords from the unmodified event).
    private func paneLocal(x: Float, y: Float, isMain: Bool) -> (x: Float, y: Float) {
        // Pane offsets exist only in the main window; float-window coords
        // must pass through untouched even while main is split.
        guard isMain, let leaf = focusedPaneLeaf() else { return (x, y) }
        return (x - leaf.rect.x, y - leaf.rect.y)
    }

    /// Focused leaf dims for metrics borrow (nil when single-pane).
    private func splitPaneDims() -> (w: Int32, h: Int32)? {
        guard let leaf = focusedPaneLeaf() else { return nil }
        return (Int32(leaf.rect.w), Int32(leaf.rect.h))
    }

    private func focusedPaneLeaf() -> (id: UUID, tabID: UUID?, rect: PaneRect)? {
        guard engine.mainPanes.isSplit,
              let canvasF = engine.ui.drawingViewportRect else { return nil }
        let canvas = PaneRect(x: canvasF.x, y: canvasF.y, w: canvasF.w, h: canvasF.h)
        let leaves = engine.mainPanes.leafRects(canvas: canvas)
        return leaves.first(where: { $0.id == engine.mainPanes.focusedLeafID })
    }

    // MARK: - Event Polling

    /// Set `ZEPHYR_DEBUG_INPUT=1` to log the input gates (showsActive /
    /// handledByImGui) for focus and CAD-relevant mouse events. Diagnostic
    /// for "float window receives no CAD input" reports.
    private static let debugInputGates =
        ProcessInfo.processInfo.environment["ZEPHYR_DEBUG_INPUT"] != nil

    private static func logGateState(
        type: UInt32, target: EngineManagedWindow,
        showsActive: Bool, handledByImGui: Bool, engine: PhrostEngine
    ) {
        let name: String
        switch type {
        case UInt32(SDL_EVENT_WINDOW_FOCUS_GAINED.rawValue): name = "FOCUS_GAINED"
        case UInt32(SDL_EVENT_WINDOW_FOCUS_LOST.rawValue): name = "FOCUS_LOST"
        case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue): name = "MOUSE_DOWN"
        case UInt32(SDL_EVENT_MOUSE_BUTTON_UP.rawValue): name = "MOUSE_UP"
        case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue): name = "WHEEL"
        case UInt32(SDL_EVENT_KEY_DOWN.rawValue): name = "KEY_DOWN"
        default: return
        }
        // Focus events are interesting for every window; the rest only for
        // float windows — plus main-window events while floats exist, so a
        // float click that was misrouted to main shows up positively
        // instead of as a suspicious absence of lines.
        let isFocus = name.hasPrefix("FOCUS")
        guard isFocus || !target.isMain || !engine.windowManager.auxWindows.isEmpty else { return }
        let activeID = engine.tabManager.activeTab?.id
        let focusedID = engine.windowManager.focusedWindow?.id
        print("[InputGate] \(name) win=\(target.id) main=\(target.isMain) "
            + "focusedWin=\(focusedID == target.id) isFocused=\(target.isFocused) "
            + "hosted==active=\(target.hostedTabID != nil && target.hostedTabID == activeID) "
            + "showsActive=\(showsActive) handledByImGui=\(handledByImGui) "
            + "wantCaptureMouse=\(target.wantCaptureMouse)")
    }

    /// Resolve the window an event belongs to via its `windowID`.
    /// Events without one (quit, clipboard) fall back to the main window.
    /// Events for a destroyed (unregistered) window return nil so the caller
    /// can drop them instead of misrouting them to the main window.
    private func targetWindow(for e: SDL_Event) -> EngineManagedWindow? {
        let main = engine.windowManager.mainWindow
        let id: SDL_WindowID?
        switch e.type {
        case UInt32(SDL_EVENT_WINDOW_CLOSE_REQUESTED.rawValue),
             UInt32(SDL_EVENT_WINDOW_RESIZED.rawValue),
             UInt32(SDL_EVENT_WINDOW_FOCUS_LOST.rawValue),
             UInt32(SDL_EVENT_WINDOW_FOCUS_GAINED.rawValue),
             UInt32(SDL_EVENT_WINDOW_MINIMIZED.rawValue),
             UInt32(SDL_EVENT_WINDOW_MAXIMIZED.rawValue),
             UInt32(SDL_EVENT_WINDOW_RESTORED.rawValue),
             UInt32(SDL_EVENT_WINDOW_MOUSE_ENTER.rawValue),
             UInt32(SDL_EVENT_WINDOW_MOUSE_LEAVE.rawValue),
             UInt32(SDL_EVENT_WINDOW_DISPLAY_CHANGED.rawValue):
            id = e.window.windowID
        case UInt32(SDL_EVENT_KEY_DOWN.rawValue),
             UInt32(SDL_EVENT_KEY_UP.rawValue):
            id = e.key.windowID
        case UInt32(SDL_EVENT_TEXT_INPUT.rawValue):
            id = e.text.windowID
        case UInt32(SDL_EVENT_MOUSE_MOTION.rawValue):
            id = e.motion.windowID
        case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue),
             UInt32(SDL_EVENT_MOUSE_BUTTON_UP.rawValue):
            id = e.button.windowID
        case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue):
            id = e.wheel.windowID
        case UInt32(SDL_EVENT_PEN_PROXIMITY_IN.rawValue),
             UInt32(SDL_EVENT_PEN_PROXIMITY_OUT.rawValue):
            id = e.pproximity.windowID
        case UInt32(SDL_EVENT_PEN_DOWN.rawValue),
             UInt32(SDL_EVENT_PEN_UP.rawValue):
            id = e.ptouch.windowID
        case UInt32(SDL_EVENT_PEN_AXIS.rawValue):
            id = e.paxis.windowID
        case UInt32(SDL_EVENT_PEN_MOTION.rawValue):
            id = e.pmotion.windowID
        case UInt32(SDL_EVENT_FINGER_DOWN.rawValue),
             UInt32(SDL_EVENT_FINGER_UP.rawValue),
             UInt32(SDL_EVENT_FINGER_MOTION.rawValue):
            id = e.tfinger.windowID
        case UInt32(SDL_EVENT_DROP_FILE.rawValue):
            id = e.drop.windowID
        default:
            id = nil
        }
        if let id, id != 0 {
            // A nonzero ID that no longer resolves is a destroyed window.
            let resolved = engine.windowManager.window(for: id)
            if resolved == nil && Self.debugInputGates {
                print("[InputGate] DROPPED type=\(e.type) windowID=\(id) (no registered window)")
            }
            return resolved
        }
        if Self.debugInputGates, e.type == UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue)
            || e.type == UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue)
            || e.type == UInt32(SDL_EVENT_WINDOW_FOCUS_GAINED.rawValue)
            || e.type == UInt32(SDL_EVENT_KEY_DOWN.rawValue) {
            print("[InputGate] NO-WINDOWID type=\(e.type) -> routed to main")
        }
        return main
    }

    /// Polls all pending SDL events and dispatches them to the appropriate
    /// handler. Returns the number of events processed so the main loop
    /// knows whether to wake the renderer.
    internal func pollEvents() -> Int {
        var e = SDL_Event()
        var eventCount = 0

        let SDL_BUTTON_LEFT = 1
        let SDL_BUTTON_MIDDLE = 2

        while SDL_PollEvent(&e) {
            guard let target = targetWindow(for: e) else { continue }
            eventCount += 1
            // Poll-side io reads (focus handlers, modifier sync, key state)
            // must hit the target window's own ImGui context.
            engine.activateImGuiContext(for: target)
            let isMain = target.isMain
            var showsActive = engine.windowShowsActiveTab(target)
            let handledByImGui = engine.ui.enqueueImGuiInput(event: &e, for: target)

            // Direct interaction activates the window's tab even if its
            // focus event never landed (lost/misrouted/bounced focus would
            // otherwise leave the window permanently inert: every canvas
            // event below is gated on showsActive). Motion alone does not
            // activate — hover must not steal the active tab.
            if !showsActive {
                switch e.type {
                case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue),
                     UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue),
                     UInt32(SDL_EVENT_PEN_DOWN.rawValue),
                     UInt32(SDL_EVENT_FINGER_DOWN.rawValue),
                     UInt32(SDL_EVENT_KEY_DOWN.rawValue):
                    engine.activateTabForInteraction(in: target)
                    showsActive = engine.windowShowsActiveTab(target)
                case UInt32(SDL_EVENT_MOUSE_MOTION.rawValue),
                     UInt32(SDL_EVENT_MOUSE_BUTTON_UP.rawValue),
                     UInt32(SDL_EVENT_PEN_MOTION.rawValue),
                     UInt32(SDL_EVENT_PEN_UP.rawValue):
                    // Mid-gesture continuation: if activation was bounced
                    // back after the gesture started, re-activate rather
                    // than dropping the rest of the gesture (which would
                    // also strand panActive/relative-mouse-mode on). Only
                    // the window the gesture started in may resume it —
                    // motion in any other window is hover there, not a
                    // continuation of a click it never received.
                    if engine.interaction.shouldContinueWindowGesture(in: target.id) {
                        engine.activateTabForInteraction(in: target)
                        showsActive = engine.windowShowsActiveTab(target)
                    }
                default:
                    break
                }
            }

            // Float windows showing the active tab borrow the engine metrics
            // so all downstream screen math uses their dimensions.
            let borrowsMetrics = !isMain && showsActive
            // Split main window: CAD input works in focused-leaf-local coords.
            let paneDims: (w: Int32, h: Int32)? =
                (isMain && showsActive) ? splitPaneDims() : nil
            let savedMetrics = (borrowsMetrics || paneDims != nil) ? engine.snapshotMetrics() : nil
            if borrowsMetrics {
                engine.borrowMetrics(from: target)
            } else if let paneDims {
                engine.borrowPaneDims(width: paneDims.w, height: paneDims.h)
            }
            // NOTE: no `defer` here — inside the poll loop it would only run
            // at function exit, leaking borrowed metrics into later events
            // of the same batch. Metrics are restored explicitly at the end
            // of each iteration (and before the early returns below).

            if Self.debugInputGates {
                Self.logGateState(
                    type: e.type, target: target, showsActive: showsActive,
                    handledByImGui: handledByImGui, engine: engine)
            }

            switch e.type {
            case UInt32(SDL_EVENT_QUIT.rawValue):
                engine.requestStop()
                if let savedMetrics { engine.restoreMetrics(savedMetrics) }
                return eventCount

            case UInt32(SDL_EVENT_WINDOW_CLOSE_REQUESTED.rawValue):
                if isMain {
                    engine.requestStop()
                    if let savedMetrics { engine.restoreMetrics(savedMetrics) }
                    return eventCount
                }
                // A float window's close box docks its tab back — never loses work.
                if let hostedID = target.hostedTabID {
                    engine.dockTab(id: hostedID)
                } else {
                    engine.closeAuxWindow(id: target.id)
                }

            case UInt32(SDL_EVENT_WINDOW_RESIZED.rawValue):
                break

            case UInt32(SDL_EVENT_WINDOW_FOCUS_LOST.rawValue):
                target.isFocused = false
                guard showsActive else { break }
                // Reset ImGui held buttons/keys so they don't stay "pressed"
                // when the window regains focus.
                if let io = engine.io {
                    ImGuiIO_AddFocusEvent(io, false)
                }
                // Finalize any in-progress drag or grip so the document doesn't
                // stay in a half-edited state.
                if engine.interaction.dragActive || engine.interaction.gripActive {
                    engine.loopController.handleToolMouseUp(x: 0, y: 0)
                }
                // A focus loss must never commit a lasso with a bogus cursor
                // position — discard the path instead.
                if engine.interaction.lassoActive {
                    engine.loopController.cancelLassoSelection()
                }
                // Release panning state that may be stuck from a missed mouse-up.
                engine.interaction.panActive = false
                engine.interaction.touchPanActive = false
                engine.interaction.touchFingersDown = 0
                engine.interaction.forceHideOSCursor = false
                // Release relative mouse mode and show the system cursor.
                _ = SDL_SetWindowRelativeMouseMode(target.handle, false)
                _ = SDL_ShowCursor()
                engine.interaction.clearWindowGestureIfIdle()
                break

            case UInt32(SDL_EVENT_WINDOW_FOCUS_GAINED.rawValue):
                target.isFocused = true
                SDL_StartTextInput(target.handle)
                // Focusing a window activates its tab (camera save/restore and
                // regen supersede ride along via the tab switch).
                if target.isMain {
                    if let shownID = engine.mainShownTabID,
                       shownID != engine.tabManager.activeTab?.id,
                       let idx = engine.tabManager.indexOfTab(id: shownID) {
                        engine.tabManager.switchToTab(at: idx)
                    }
                } else if let hostedID = target.hostedTabID,
                          let idx = engine.tabManager.indexOfTab(id: hostedID) {
                    engine.tabManager.switchToTab(at: idx)
                }
                guard engine.windowShowsActiveTab(target) else { break }
                // Inform ImGui that the window is now focused so it can
                // correctly track mouse/key state going forward.
                if let io = engine.io {
                    ImGuiIO_AddFocusEvent(io, true)
                    // Sync modifier keys that may have changed while unfocused.
                    let mod = UInt32(SDL_GetModState())
                    let ctrlDown  = (mod & SDL_KMOD_CTRL)  != 0
                    let shiftDown = (mod & SDL_KMOD_SHIFT) != 0
                    let altDown   = (mod & SDL_KMOD_ALT)   != 0
                    let guiDown   = (mod & SDL_KMOD_GUI)   != 0
                    ImGuiIO_AddKeyEvent(io, ImGuiMod_Ctrl, ctrlDown)
                    ImGuiIO_AddKeyEvent(io, ImGuiMod_Shift, shiftDown)
                    ImGuiIO_AddKeyEvent(io, ImGuiMod_Alt, altDown)
                    ImGuiIO_AddKeyEvent(io, ImGuiMod_Super, guiDown)
                }
                break

            case UInt32(SDL_EVENT_KEY_DOWN.rawValue):
                if isMain || showsActive {
                    handleKeyDown(event: e, handledByImGui: handledByImGui)
                }

            case UInt32(SDL_EVENT_KEY_UP.rawValue):
                handleKeyUp(event: e)

            case UInt32(SDL_EVENT_MOUSE_MOTION.rawValue):
                guard showsActive else { break }
                let motionLocal = paneLocal(x: e.motion.x, y: e.motion.y, isMain: isMain)
                engine.interaction.lastMouseX = motionLocal.x
                engine.interaction.lastMouseY = motionLocal.y
                if !handledByImGui {
                    handleMouseMotion(x: motionLocal.x, y: motionLocal.y, xrel: e.motion.xrel, yrel: e.motion.yrel)
                }

            case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue):
                // Click-to-raise: some window managers focus a clicked
                // window without raising it, leaving a clicked float window
                // buried under the main window (syncWindowsToActiveTab
                // deliberately doesn't raise already-focused windows). A
                // click is explicit intent — bring that window forward.
                SDL_RaiseWindow(target.handle)
                guard showsActive else { break }
                if Int(e.button.button) == SDL_BUTTON_LEFT && !handledByImGui {
                    if isMain && engine.mainPanes.isSplit
                        && engine.focusSplitPane(at: (e.button.x, e.button.y)) {
                        swallowNextMouseUp = true
                        break
                    }
                    engine.interaction.beginWindowGesture(
                        windowID: target.id, tabID: engine.tabManager.activeTab?.id)
                    let downLocal = paneLocal(x: e.button.x, y: e.button.y, isMain: isMain)
                    handleMouseDown(x: downLocal.x, y: downLocal.y)
                    // No clear here: an entity drag only becomes
                    // dragActive after the motion threshold, and the
                    // claim must survive until mouse-up to cover it.
                } else if Int(e.button.button) == 3 && !handledByImGui {
                    if engine.commandProcessor.isSelectingObjects {
                        engine.commandProcessor.confirmObjectSelection()
                    }
                } else if Int(e.button.button) == SDL_BUTTON_MIDDLE && !handledByImGui {
                    engine.interaction.beginWindowGesture(
                        windowID: target.id, tabID: engine.tabManager.activeTab?.id)
                    engine.interaction.panActive = true
                    engine.interaction.forceHideOSCursor = true
                    _ = SDL_SetWindowRelativeMouseMode(target.handle, true)
                }

            case UInt32(SDL_EVENT_MOUSE_BUTTON_UP.rawValue):
                guard showsActive else { break }
                if Int(e.button.button) == SDL_BUTTON_LEFT {
                    if swallowNextMouseUp {
                        swallowNextMouseUp = false
                        break
                    }
                    if engine.interaction.panActive {
                        engine.interaction.panActive = false
                        engine.interaction.forceHideOSCursor = false
                        _ = SDL_SetWindowRelativeMouseMode(target.handle, false)
                    }
                    let upLocal = paneLocal(x: e.button.x, y: e.button.y, isMain: isMain)
                    handleMouseUp(x: upLocal.x, y: upLocal.y)
                    engine.interaction.clearWindowGestureIfIdle()
                } else if Int(e.button.button) == SDL_BUTTON_MIDDLE {
                    engine.interaction.panActive = false
                    engine.interaction.forceHideOSCursor = false
                    _ = SDL_SetWindowRelativeMouseMode(target.handle, false)
                    engine.interaction.clearWindowGestureIfIdle()
                }

            case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue):
                guard showsActive else { break }
                if !handledByImGui {
                    let wy = e.wheel.y
                    let dir = e.wheel.direction.rawValue == SDL_MouseWheelDirection.flipped.rawValue
                        ? -wy : wy
                    let factor = dir > 0 ? 1.375 : 1.0 / 1.375
                    engine.camera.zoomView(factor: factor, screenX: engine.interaction.lastMouseX, screenY: engine.interaction.lastMouseY, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
                }

            // MARK: SDL3 Pen / Tablet events

            case UInt32(SDL_EVENT_PEN_PROXIMITY_IN.rawValue):
                engine.interaction.penState.penActive = true

            case UInt32(SDL_EVENT_PEN_PROXIMITY_OUT.rawValue):
                engine.interaction.penState.penActive = false
                engine.interaction.penState.penDrawing = false
                engine.interaction.penState.pressure = 0.0

            case UInt32(SDL_EVENT_PEN_DOWN.rawValue):
                SDL_RaiseWindow(target.handle) // click-to-raise, as above
                guard showsActive else { break }
                engine.interaction.beginWindowGesture(
                    windowID: target.id, tabID: engine.tabManager.activeTab?.id)
                let penLocal = paneLocal(x: e.ptouch.x, y: e.ptouch.y, isMain: isMain)
                engine.interaction.penState.penActive = true
                engine.interaction.penState.penDrawing = true
                engine.interaction.penState.isEraser = e.ptouch.eraser
                let (wx, wy) = EngineCameraManager.screenToWorld(
                    screenX: penLocal.x, screenY: penLocal.y,
                    cam: engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight))
                engine.interaction.penState.worldX = wx
                engine.interaction.penState.worldY = wy
                sampleActivePenStroke()
                // Forward pen down as a left-click to the standard mouse handler
                // so the active feature command receives it without special routing.
                if !handledByImGui {
                    handleMouseDown(x: penLocal.x, y: penLocal.y)
                }

            case UInt32(SDL_EVENT_PEN_UP.rawValue):
                guard showsActive else { break }
                let penLocal = paneLocal(x: e.ptouch.x, y: e.ptouch.y, isMain: isMain)
                let (wx, wy) = EngineCameraManager.screenToWorld(
                    screenX: penLocal.x, screenY: penLocal.y,
                    cam: engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight))
                engine.interaction.penState.worldX = wx
                engine.interaction.penState.worldY = wy
                sampleActivePenStroke()
                engine.interaction.penState.penDrawing = false
                sampleActivePenStroke()
                if !handledByImGui {
                    handleMouseUp(x: penLocal.x, y: penLocal.y)
                }
                engine.interaction.clearWindowGestureIfIdle()

            case UInt32(SDL_EVENT_PEN_AXIS.rawValue):
                guard showsActive else { break }
                engine.interaction.penState.penActive = true
                // Accumulate axis values unconditionally — the active command
                // decides whether to use them based on penDrawing state.
                let axisRaw = e.paxis.axis.rawValue
                switch axisRaw {
                case 0:  // SDL_PEN_AXIS_PRESSURE
                    engine.interaction.penState.pressure = max(0.0, min(1.0, Double(e.paxis.value)))
                case 1:  // SDL_PEN_AXIS_XTILT
                    engine.interaction.penState.xtilt = Double(e.paxis.value)
                case 2:  // SDL_PEN_AXIS_YTILT
                    engine.interaction.penState.ytilt = Double(e.paxis.value)
                case 4:  // SDL_PEN_AXIS_ROTATION
                    engine.interaction.penState.rotation = Double(e.paxis.value)
                default:
                    break
                }
                // Update world-space pen position from the axis event's screen coords.
                let penLocal = paneLocal(x: e.paxis.x, y: e.paxis.y, isMain: isMain)
                let (wx, wy) = EngineCameraManager.screenToWorld(
                    screenX: penLocal.x, screenY: penLocal.y,
                    cam: engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight))
                engine.interaction.penState.worldX = wx
                engine.interaction.penState.worldY = wy
                sampleActivePenStroke()
                // Also forward pen axis as mouse motion for cursor update.
                if !handledByImGui {
                    handleMouseMotion(x: penLocal.x, y: penLocal.y, xrel: 0, yrel: 0)
                }

            case UInt32(SDL_EVENT_PEN_MOTION.rawValue):
                guard showsActive else { break }
                engine.interaction.penState.penActive = true
                // Pen moved while touching the surface.
                let penLocal = paneLocal(x: e.pmotion.x, y: e.pmotion.y, isMain: isMain)
                let (wx, wy) = EngineCameraManager.screenToWorld(
                    screenX: penLocal.x, screenY: penLocal.y,
                    cam: engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight))
                engine.interaction.penState.worldX = wx
                engine.interaction.penState.worldY = wy
                sampleActivePenStroke()
                if !handledByImGui {
                    handleMouseMotion(x: penLocal.x, y: penLocal.y, xrel: 0, yrel: 0)
                }

            // MARK: Two-finger trackpad pan
            case UInt32(SDL_EVENT_FINGER_DOWN.rawValue):
                guard showsActive else { break }
                engine.interaction.touchFingersDown += 1
                if engine.interaction.touchFingersDown >= 2 && !engine.interaction.dragActive && !engine.interaction.gripActive && !engine.interaction.rectSelectActive {
                    engine.interaction.lastTouchAvgX = e.tfinger.x
                    engine.interaction.lastTouchAvgY = e.tfinger.y
                    engine.interaction.touchPanActive = false
                }

            case UInt32(SDL_EVENT_FINGER_UP.rawValue):
                guard showsActive else { break }
                engine.interaction.touchFingersDown = max(0, engine.interaction.touchFingersDown - 1)
                if engine.interaction.touchFingersDown < 2 {
                    engine.interaction.touchPanActive = false
                }

            case UInt32(SDL_EVENT_FINGER_MOTION.rawValue):
                guard showsActive else { break }
                if engine.interaction.touchFingersDown >= 2 {
                    let curX = e.tfinger.x
                    let curY = e.tfinger.y
                    if !engine.interaction.touchPanActive {
                        engine.interaction.lastTouchAvgX = curX
                        engine.interaction.lastTouchAvgY = curY
                        engine.interaction.touchPanActive = true
                    } else {
                        let dx = Double(curX - engine.interaction.lastTouchAvgX) * Double(engine.windowWidth)
                        let dy = Double(curY - engine.interaction.lastTouchAvgY) * Double(engine.windowHeight)
                        if abs(dx) > 0.5 || abs(dy) > 0.5 {
                            engine.camera.panByScreenDelta(dx: dx, dy: dy)
                        }
                        engine.interaction.lastTouchAvgX = curX
                        engine.interaction.lastTouchAvgY = curY
                    }
                }

            case UInt32(SDL_EVENT_DROP_FILE.rawValue):
                guard showsActive else { break }
                handleDropFile(event: e)

            default:
                break
            }

            if let savedMetrics {
                engine.restoreMetrics(savedMetrics)
            }
        }
        return eventCount
    }

    // MARK: - Keyboard Handling

    private func handleKeyDown(event e: SDL_Event, handledByImGui: Bool) {
        if (e.key.scancode == SDL_SCANCODE_LCTRL
                || e.key.scancode == SDL_SCANCODE_RCTRL),
           engine.interaction.cycleGripVertexEditMode() {
            engine.loopController.handleToolMouseMotion(
                x: engine.interaction.lastMouseX,
                y: engine.interaction.lastMouseY)
            return
        }

        let scancode = e.key.scancode
        var routedEnterToFeatureCommand = false

        // ── Unified Escape cascade ──
        // Escape always means "give me a clean state". The cascade walks the
        // interaction stack from the innermost transient thing outward, so a
        // single Escape only ever undoes ONE layer (users press Escape
        // repeatedly to wind the state back down). When every layer is idle
        // it clears the remaining transient state (snaps, buffers, previews)
        // and finally the selection.
        if scancode == SDL_SCANCODE_ESCAPE {
            handleEscapeCascade()
            return
        }

        if (scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER),
           !engine.commandProcessor.commandLineActive,
           !engine.textManager.isEditorActive,
           !engine.interaction.tableCellEditorActive,
           let featureCmd = engine.commandProcessor.activeFeatureCommand {
            routedEnterToFeatureCommand = true
            let result = featureCmd.handleKeyDown(
                scancode: scancode,
                engine: engine,
                processor: engine.commandProcessor)
            switch result {
            case .finished:
                engine.commandProcessor.finishFeatureCommand(engine: engine)
                return
            case .handled:
                return
            case .continue:
                break
            }
        }

        // ── Space as a commit key ──
        // AutoCAD treats Space exactly like Enter for "finish this step".
        // Space is also a literal text character, so this is deliberately
        // gated much more tightly than the Enter hoist above: it must not
        // fire while ImGui owns the keyboard, nor while the user is typing
        // in the command line, a text editor, or a table cell.
        //
        // Commands that define their OWN Space behaviour (Trim, Explode, …)
        // get first refusal: we dispatch the real Space scancode, and only
        // when the command declines (.continue) do we re-dispatch it as
        // Return so Enter-only commands behave identically under Space.
        if scancode == SDL_SCANCODE_SPACE,
           !handledByImGui,
           !engine.commandProcessor.commandLineActive,
           !engine.textManager.isEditorActive,
           !engine.interaction.tableCellEditorActive,
           !engine.ui.layerMoveActive,
           !engine.interaction.gripActive,
           !engine.interaction.dragActive,
           !engine.interaction.rectSelectActive {
            if engine.commandProcessor.isSelectingObjects {
                engine.commandProcessor.confirmObjectSelection()
                return
            }
            if let featureCmd = engine.commandProcessor.activeFeatureCommand {
            let spaceResult = featureCmd.handleKeyDown(
                scancode: scancode,
                engine: engine,
                processor: engine.commandProcessor)
            switch spaceResult {
            case .finished:
                engine.commandProcessor.finishFeatureCommand(engine: engine)
                return
            case .handled:
                return
            case .continue:
                let enterResult = featureCmd.handleKeyDown(
                    scancode: SDL_SCANCODE_RETURN,
                    engine: engine,
                    processor: engine.commandProcessor)
                switch enterResult {
                case .finished:
                    engine.commandProcessor.finishFeatureCommand(engine: engine)
                    return
                case .handled:
                    return
                case .continue:
                    break  // fall through to global Space behaviour below
                }
            }
            }
        }

        if !handledByImGui {
            // Use the modifier state from the key event itself — SDL records
            // which modifier keys were held when this key was pressed.
            // macOS: Command key (SDL_KMOD_GUI) triggers shortcuts.
            // Windows/Linux: Control key (SDL_KMOD_CTRL) triggers shortcuts.
            let keyMod = UInt32(e.key.mod)
            #if os(macOS)
            let ctrlHeld = (engine.io != nil && engine.io.pointee.KeySuper)
                || (keyMod & SDL_KMOD_GUI) != 0
            #else
            let ctrlHeld = (engine.io != nil && engine.io.pointee.KeyCtrl)
                || (keyMod & SDL_KMOD_CTRL) != 0
            #endif

            // ── Ctrl+Tab cycles drawing tabs (AutoCAD parity) ──
            // Physical Ctrl counts on every platform: on macOS Cmd+Tab is
            // reserved by the OS, so Ctrl+Tab / Ctrl+Shift+Tab fill the gap.
            if e.key.scancode == SDL_SCANCODE_TAB
                && (ctrlHeld || (keyMod & SDL_KMOD_CTRL) != 0) {
                let shiftHeld = (engine.io != nil && engine.io.pointee.KeyShift)
                    || (keyMod & SDL_KMOD_SHIFT) != 0
                _ = engine.tabManager.cycleTab(direction: shiftHeld ? -1 : 1)
                return
            }

            // ── Ctrl/Cmd + key shortcuts (don't open command line) ──
            if ctrlHeld {
                switch e.key.scancode {
                case SDL_SCANCODE_Z:
                    engine.document.undo()
                case SDL_SCANCODE_Y:
                    engine.document.redo()
                case SDL_SCANCODE_A:
                    engine.selectAll()
                case SDL_SCANCODE_O:
                    NativeFileDialog.showOpenDialog(
                        window: engine.dialogParentWindow,
                        filters: [
                            NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg", "eab"])
                        ],
                        allowMultiple: true
                    ) { [weak engine] urls in
                        guard let engine else { return }
                        for url in urls {
                            do {
                                try engine.tabManager.openTab(url: url)
                            } catch {
                                print("Failed to open \(url.lastPathComponent): \(error)")
                            }
                        }
                        if !urls.isEmpty {
                            engine.zoomExtents()
                        }
                    }
                case SDL_SCANCODE_N:
                    _ = engine.tabManager.newTab()
                    engine.zoomExtents()
                case SDL_SCANCODE_W:
                    if engine.io.pointee.KeyShift {
                        engine.commandProcessor.executeCommand("CLOSEALL")
                    } else {
                    _ = engine.tabManager.requestCloseActiveTab()
                    }
                case SDL_SCANCODE_S:
                    if engine.io.pointee.KeyShift {
                        showNativeSaveDialog()
                    } else {
                        engine.tabManager.startSaveActiveTab()
                        // If the tab has no file URL, startSaveActiveTab does nothing —
                        // fall back to opening the native save dialog.
                        if engine.tabManager.activeFileURL == nil {
                            showNativeSaveDialog()
                        }
                    }
                case SDL_SCANCODE_C:
                    if engine.io.pointee.KeyShift {
                        engine.commandProcessor.executeCommand("COPYBASE")
                    } else {
                        engine.commandProcessor.executeCommand("COPYCLIP")
                    }
                case SDL_SCANCODE_V:
                    if engine.io.pointee.KeyShift {
                        engine.commandProcessor.executeCommand("PASTEBLOCK")
                    } else if engine.commandProcessor.clipboard.hasEntities {
                        engine.commandProcessor.executeCommand("PASTECLIP")
                    } else {
                    handleClipboardPaste()
                    }
                case SDL_SCANCODE_F:
                    engine.commandProcessor.executeCommand("OSNAP")
                case SDL_SCANCODE_G:
                    engine.commandProcessor.executeCommand("GRID")
                case SDL_SCANCODE_L:
                    engine.commandProcessor.executeCommand("ORTHO")
                case SDL_SCANCODE_B:
                    engine.commandProcessor.executeCommand("GRID SNAP")
                case SDL_SCANCODE_1:
                    engine.commandProcessor.executeCommand("PROPERTIES")
                case SDL_SCANCODE_9:
                    engine.commandProcessor.executeCommand("COMMANDLINE")
                case SDL_SCANCODE_0:
                    engine.commandProcessor.executeCommand(
                        engine.ui.cleanScreenActive ? "CLEANSCREENOFF" : "CLEANSCREENON")
                case SDL_SCANCODE_P:
                    if engine.io.pointee.KeyShift {
                        engine.commandProcessor.executeCommand("PDFIMPORT")
                    } else {
                        // No plot dialog yet (Phase 3A): route to the PDF
                        // export flow rather than swallowing the keystroke.
                        engine.commandProcessor.executeCommand("EXPORTPDF")
                    }
                // ── Ctrl/Cmd+Alt+Arrow nudges the focused pane's divider ──
                case SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT, SDL_SCANCODE_UP, SDL_SCANCODE_DOWN:
                    let altHeld = (engine.io != nil && engine.io.pointee.KeyAlt)
                        || (keyMod & SDL_KMOD_ALT) != 0
                    guard altHeld, engine.mainPanes.isSplit else { break }
                    let direction: PaneNudgeDirection
                    switch e.key.scancode {
                    case SDL_SCANCODE_LEFT: direction = .left
                    case SDL_SCANCODE_RIGHT: direction = .right
                    case SDL_SCANCODE_UP: direction = .up
                    default: direction = .down
                    }
                    _ = engine.nudgeFocusedPane(direction)
                default:
                    break
                }
            } else {
                // ── Bare key handling (no Ctrl/Cmd held) ──
                // When a feature command is active, route ALL keys to it first.
                // If it returns .handled or .finished, stop — don't run global behavior.
                if !routedEnterToFeatureCommand,
                   let featureCmd = engine.commandProcessor.activeFeatureCommand {
                    let result = featureCmd.handleKeyDown(
                        scancode: scancode, engine: engine,
                        processor: engine.commandProcessor)
                    switch result {
                    case .finished:
                        engine.commandProcessor.finishFeatureCommand(engine: engine)
                        return
                    case .handled:
                        return
                    case .continue:
                        break  // fall through to global hotkey behavior
                    }
                }

                switch e.key.scancode {
                case SDL_SCANCODE_DELETE, SDL_SCANCODE_BACKSPACE:
                    if !engine.commandProcessor.pendingDistanceBuffer.isEmpty {
                        _ = engine.commandProcessor.pendingDistanceBuffer.removeLast()
                    } else if let handle = engine.interaction.selectedTableHandle,
                              let range = engine.interaction.tableSelectionRange,
                              engine.cadSelection.isSelected(handle) {
                        DataTableEditor.clearCells(handle: handle, range: range, engine: engine)
                    } else {
                        engine.deleteSelected()
                        engine.interaction.clearDataTableEditingState()
                    }
                case SDL_SCANCODE_F3:
                    engine.commandProcessor.executeCommand("OSNAP")
                case SDL_SCANCODE_F7:
                    engine.commandProcessor.executeCommand("GRID")
                case SDL_SCANCODE_F8:
                    engine.commandProcessor.executeCommand("ORTHO")
                case SDL_SCANCODE_F9:
                    engine.commandProcessor.executeCommand("GRID SNAP")
                case SDL_SCANCODE_F10:
                    engine.commandProcessor.executeCommand("POLAR")
                case SDL_SCANCODE_F11:
                    engine.commandProcessor.executeCommand("OTRACK")
                case SDL_SCANCODE_UP:
                    handleArrowUp()
                case SDL_SCANCODE_DOWN:
                    handleArrowDown()

                case SDL_SCANCODE_SPACE:
                    // Space repeats the last command (AutoCAD style).
                    // Any custom Space handling lived in the feature command
                    // and already ran in the Space hoist above.
                    if shouldRepeatLastCommandOnKey {
                        engine.commandProcessor.repeatLastCommand(engine: engine)
                    }
                case SDL_SCANCODE_LEFTBRACKET:
                    engine.camera.rotation -= 15.0 * .pi / 180.0
                case SDL_SCANCODE_RIGHTBRACKET:
                    engine.camera.rotation += 15.0 * .pi / 180.0
                case SDL_SCANCODE_BACKSLASH:
                    engine.camera.rotation = 0
                case SDL_SCANCODE_EQUALS, SDL_SCANCODE_KP_PLUS:
                    engine.camera.zoomView(factor: 1.375, screenX: engine.interaction.lastMouseX, screenY: engine.interaction.lastMouseY, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
                case SDL_SCANCODE_MINUS, SDL_SCANCODE_KP_MINUS:
                    if engine.commandProcessor.activeCommand == "MOVE", engine.commandProcessor.commandRefPoint != nil {
                        appendDistanceChar("-")
                    } else {
                        engine.camera.zoomView(factor: 1.0 / 1.375, screenX: engine.interaction.lastMouseX, screenY: engine.interaction.lastMouseY, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
                    }
                case SDL_SCANCODE_0:
                    if engine.commandProcessor.activeCommand == "MOVE", engine.commandProcessor.commandRefPoint != nil {
                        appendDistanceChar("0")
                    } else {
                        engine.camera.zoom = 1.0
                        engine.camera.offset = (0, 0)
                    }
                case SDL_SCANCODE_1, SDL_SCANCODE_2, SDL_SCANCODE_3, SDL_SCANCODE_4,
                     SDL_SCANCODE_5, SDL_SCANCODE_6, SDL_SCANCODE_7, SDL_SCANCODE_8, SDL_SCANCODE_9,
                     SDL_SCANCODE_KP_1, SDL_SCANCODE_KP_2, SDL_SCANCODE_KP_3, SDL_SCANCODE_KP_4,
                     SDL_SCANCODE_KP_5, SDL_SCANCODE_KP_6, SDL_SCANCODE_KP_7, SDL_SCANCODE_KP_8,
                     SDL_SCANCODE_KP_9:
                    if engine.commandProcessor.activeCommand == "MOVE", engine.commandProcessor.commandRefPoint != nil {
                        appendDistanceChar(scancodeToDigit(e.key.scancode))
                    }
                case SDL_SCANCODE_KP_0:
                    if engine.commandProcessor.activeCommand == "MOVE", engine.commandProcessor.commandRefPoint != nil {
                        appendDistanceChar("0")
                    }
                case SDL_SCANCODE_PERIOD, SDL_SCANCODE_KP_PERIOD:
                    if engine.commandProcessor.activeCommand == "MOVE", engine.commandProcessor.commandRefPoint != nil {
                        appendDistanceChar(".")
                    }
                default:
                    // No feature command active — typing a letter opens the command line.
                    // Also allow during MOVE with refPoint for direct distance entry.
                    let canOpenCommandLine = engine.commandProcessor.activeCommand == nil
                        || (engine.commandProcessor.activeCommand == "MOVE" && engine.commandProcessor.commandRefPoint != nil)
                    if !engine.commandProcessor.commandLineActive
                                && canOpenCommandLine
                                && engine.commandProcessor.activeFeatureCommand == nil {
                        let char = keycodeToChar(e.key.key)
                        if !char.isEmpty {
                            engine.commandProcessor.commandLineActive = true
                            engine.commandProcessor.commandBuffer = char
                            engine.commandProcessor.commandSelectionIndex = 0
                            engine.commandProcessor._lastMatchInput = ""
                            engine.commandProcessor._cachedMatches = []
                        }
                    }
                }
            }
        }

        // Enter key: confirm layer-move popup, apply direct distance entry,
        // or repeat the last command (AutoCAD-style).
        // (Feature command already received Enter via the hoisted routing above.)
        if e.key.scancode == SDL_SCANCODE_RETURN || e.key.scancode == SDL_SCANCODE_KP_ENTER {
            if engine.ui.layerMoveActive {
                if engine.ui.layerMoveSelectionIndex >= 0
                    && engine.ui.layerMoveSelectionIndex < engine.ui.layerMoveMatches.count {
                    let layer = engine.ui.layerMoveMatches[engine.ui.layerMoveSelectionIndex]
                    engine.document.reassignEntities(
                        handles: engine.cadSelection.selectedHandles, to: layer.handle)
                }
                engine.ui.layerMoveActive = false
                engine.ui.layerMoveBuffer = ""
                engine.ui.layerMoveMatches = []
            } else if engine.commandProcessor.isSelectingObjects {
                engine.commandProcessor.confirmObjectSelection()
            } else if !engine.commandProcessor.pendingDistanceBuffer.isEmpty {
                // Apply the accumulated distance.
                engine.commandProcessor.executeCommand(engine.commandProcessor.pendingDistanceBuffer)
                engine.commandProcessor.pendingDistanceBuffer = ""
            } else if shouldRepeatLastCommandOnKey {
                // Idle Enter repeats the last command, matching Space.
                engine.commandProcessor.repeatLastCommand(engine: engine)
            }
        }
    }

    /// Whether Enter/Space should act as "repeat the last command".
    /// Only true when nothing would be lost by doing so: no command line
    /// input, no running command, no picker/editor capturing keystrokes,
    /// and no partially typed numeric input.
    private var shouldRepeatLastCommandOnKey: Bool {
        !engine.commandProcessor.commandLineActive
            && engine.commandProcessor.activeCommand == nil
            && engine.commandProcessor.activeFeatureCommand == nil
            && engine.commandProcessor.pendingDistanceBuffer.isEmpty
            && !engine.ui.layerMoveActive
            && !engine.textManager.isEditorActive
            && !engine.interaction.tableCellEditorActive
            && !engine.interaction.gripActive
            && !engine.interaction.dragActive
            && !engine.interaction.rectSelectActive
    }

    private func handleKeyUp(event e: SDL_Event) {
        // No-op: space-held pan and space-to-open-command-line are removed.
        // Pan is now exclusively via middle-mouse drag or two-finger trackpad.
        // Command line opens by typing any letter key.
    }

    // MARK: - Escape Cascade

    /// Cancel exactly one layer of interaction state, innermost first.
    ///
    /// Escape is the universal "get me out of this" key. Every press peels
    /// off the most transient thing that is currently in progress:
    ///
    ///  1. layer-move picker (a transient combobox over the viewport)
    ///  2. text editor dialog (DDEDIT / MTEXT)
    ///  3. data-table cell editor
    ///  4. grip drag (restores the pre-drag snapshot — the drag mutated
    ///     the document live, so cancelling must roll it back)
    ///  5. selection drag (same — restores the pre-drag snapshot)
    ///  6. rectangle select (in-flight first click of a two-click selection)
    ///  7. active feature command / command line / active command
    ///  8. otherwise: clear snaps, numeric buffers, preview handles, selection
    ///
    /// Steps 1–7 each return immediately so one Escape only changes one
    /// layer. Step 8 is the "nothing is active" fallback and performs the
    /// full clean-up sweep.
    private func handleEscapeCascade() {
        let interaction = engine.interaction
        let processor = engine.commandProcessor

        // 1. Layer-move picker.
        if engine.ui.layerMoveActive {
            engine.ui.layerMoveActive = false
            engine.ui.layerMoveBuffer = ""
            engine.ui.layerMoveMatches = []
            return
        }

        // 2. Text editor dialog (DDEDIT / MTEXT).
        if engine.textManager.isEditorActive {
            engine.textManager.isEditorActive = false
            engine.textManager.editorResult = .cancelled
            return
        }

        // 3. Data-table cell editor.
        if interaction.tableCellEditorActive {
            DataTableEditor.cancelCellEditing(engine: engine)
            return
        }

        // 4. Grip drag — the grip may have already mutated the document in
        //    real time, so roll it back to the pre-drag snapshot.
        if interaction.gripActive {
            if let snapshot = interaction.gripUndoSnapshot {
                engine.document.restore(from: snapshot)
            }
            if let handle = interaction.gripHandle {
                interaction.pendingPreviewHandles = [handle]
                interaction.pendingPreviewIsBulkDrag = false
            }
            interaction.cachedGripGeneration = -1
            interaction.gripActive = false
            interaction.gripHandle = nil
            interaction.gripUndoSnapshot = nil
            interaction.resetGripVertexEditMode()
            clearTransientSnapState()
            interaction.clearWindowGestureIfIdle()
            return
        }

        // 5. Selection drag — same rollback rule as the grip drag.
        if interaction.dragActive {
            if let snapshot = interaction.dragUndoSnapshot {
                engine.document.restore(from: snapshot)
                interaction.pendingPreviewHandles = engine.cadSelection.selectedHandles
                interaction.pendingPreviewIsBulkDrag = true
            }
            interaction.dragActive = false
            interaction.dragUndoSnapshot = nil
            interaction.dragTotalWorldX = 0
            interaction.dragTotalWorldY = 0
            clearTransientSnapState()
            interaction.clearWindowGestureIfIdle()
            return
        }

        // 6. In-flight two-click rectangle selection.
        if interaction.rectSelectActive {
            interaction.cancelRectSelect()
            return
        }

        // 7. Active feature command, command line, then legacy active command.
        if processor.activeFeatureCommand != nil {
            processor.commandLineActive = false
            processor.commandBuffer = ""
            processor.finishFeatureCommand(engine: engine)
            return
        }
        if processor.commandLineActive {
            processor.commandLineActive = false
            processor.commandBuffer = ""
            processor.commandSelectionIndex = 0
            processor._lastMatchInput = ""
            processor._cachedMatches = []
            return
        }
        if processor.activeCommand != nil {
            processor.clearCommand()
            return
        }

        // 8. Nothing active — drop every remaining transient bit of state so
        //    the next click starts from a genuinely clean slate. Live preview
        //    handles are refreshed from the document on the next frame.
        clearTransientSnapState()
        processor.pendingDistanceBuffer = ""
        interaction.pendingPreviewHandles.removeAll()
        interaction.pendingPreviewIsBulkDrag = false

        if let handle = interaction.selectedTableHandle,
           interaction.tableSelectionRange != nil {
            interaction.selectTable(handle: handle)
        } else if engine.cadSelection.hasSelection {
            engine.cadSelection.clearSelection()
            interaction.clearDataTableEditingState()
        }
    }

    /// Clear the ephemeral snap/tracking state shared by the Escape cascade.
    private func clearTransientSnapState() {
        engine.snap.lockedSnap = nil
        engine.snap.snapTrackingEngine.clear()
        engine.snap.currentSnapResult = nil
        engine.snap.lastPolarResult = nil
    }

    // MARK: - Hotkey Helpers

    private func handleArrowUp() {
        if engine.ui.layerMoveActive {
            if engine.ui.layerMoveSelectionIndex > 0 {
                engine.ui.layerMoveSelectionIndex -= 1
            } else if !engine.ui.layerMoveMatches.isEmpty {
                engine.ui.layerMoveSelectionIndex = engine.ui.layerMoveMatches.count - 1
            }
        } else if engine.commandProcessor.commandLineActive {
            let matches = engine.commandProcessor._cachedMatches
            if engine.commandProcessor.commandSelectionIndex > 0 {
                engine.commandProcessor.commandSelectionIndex -= 1
            } else if !matches.isEmpty {
                engine.commandProcessor.commandSelectionIndex = matches.count - 1
            }
        }
    }

    private func handleArrowDown() {
        if engine.ui.layerMoveActive {
            if engine.ui.layerMoveSelectionIndex + 1 < engine.ui.layerMoveMatches.count {
                engine.ui.layerMoveSelectionIndex += 1
            } else {
                engine.ui.layerMoveSelectionIndex = 0
            }
        } else if engine.commandProcessor.commandLineActive {
            let matches = engine.commandProcessor._cachedMatches
            if engine.commandProcessor.commandSelectionIndex + 1 < matches.count {
                engine.commandProcessor.commandSelectionIndex += 1
            } else {
                engine.commandProcessor.commandSelectionIndex = 0
            }
        }
    }

    /// Map an SDL keycode to the uppercase character it represents.
    /// Returns an empty string for non-letter keys (modifiers, arrows, etc.).
    /// SDL keycodes for printable ASCII characters match their ASCII values:
    /// SDLK_A = 0x61 ('a') through SDLK_Z = 0x7A ('z').
    private func keycodeToChar(_ keycode: UInt32) -> String {
        // Letters a-z (ASCII 0x61–0x7A) → uppercase A-Z
        if keycode >= 0x61 && keycode <= 0x7A {
            let ascii = UInt8(keycode - 0x20)  // convert to uppercase
            return String(Character(UnicodeScalar(ascii)))
        }
        return ""
    }

    /// Append a character to the direct distance entry buffer during MOVE.
    /// Does NOT open the command line — the value is displayed as a tooltip.
    private func appendDistanceChar(_ char: String) {
        engine.commandProcessor.pendingDistanceBuffer += char
    }

    /// Map numeric scancodes to their digit character.
    private func scancodeToDigit(_ sc: SDL_Scancode) -> String {
        switch sc {
        case SDL_SCANCODE_1, SDL_SCANCODE_KP_1: return "1"
        case SDL_SCANCODE_2, SDL_SCANCODE_KP_2: return "2"
        case SDL_SCANCODE_3, SDL_SCANCODE_KP_3: return "3"
        case SDL_SCANCODE_4, SDL_SCANCODE_KP_4: return "4"
        case SDL_SCANCODE_5, SDL_SCANCODE_KP_5: return "5"
        case SDL_SCANCODE_6, SDL_SCANCODE_KP_6: return "6"
        case SDL_SCANCODE_7, SDL_SCANCODE_KP_7: return "7"
        case SDL_SCANCODE_8, SDL_SCANCODE_KP_8: return "8"
        case SDL_SCANCODE_9, SDL_SCANCODE_KP_9: return "9"
        default: return ""
        }
    }

    /// Show the native file-save dialog and, on confirmation, save the active tab.
    private func showNativeSaveDialog() {
        let defaultName = engine.tabManager.activeTab?.displayName ?? "untitled"
        let dxfVersion = engine.tabManager.activeTab?.dxfVersion ?? .r2018
        NativeFileDialog.showSaveDialog(
            window: engine.dialogParentWindow,
            filters: [
                NativeFileDialog.Filter(label: "DXF Drawing", extensions: ["dxf"]),
                NativeFileDialog.Filter(label: "Zephyr Drawing", extensions: ["eab"]),
                NativeFileDialog.Filter(label: "PDF Document", extensions: ["pdf"]),
                NativeFileDialog.Filter(label: "All Files", extensions: ["*"])
            ],
            defaultName: defaultName
        ) { [weak engine] url in
            guard let engine, let url else { return }
            engine.tabManager.startSaveActiveTabAs(url: url, dxfVersion: dxfVersion)
        }
    }

    // MARK: - Mouse Motion

    private func handleMouseMotion(x: Float, y: Float, xrel: Float, yrel: Float) {
        if engine.interaction.panActive {
            let screenDx = Double(xrel)
            let screenDy = Double(yrel)
            engine.camera.panByScreenDelta(dx: screenDx, dy: screenDy)
        } else {
            engine.loopController.handleToolMouseMotion(x: x, y: y)
        }
    }

    // MARK: - Mouse Down / Up

    private func handleMouseDown(x: Float, y: Float) {
        engine.loopController.handleToolMouseDown(x: x, y: y)
    }

    private func handleMouseUp(x: Float, y: Float) {
        engine.loopController.handleToolMouseUp(x: x, y: y)
    }

    // MARK: - Drop & Clipboard

    /// Handle a file dropped onto the window. Creates an image entity if the
    /// dropped file is a supported image format.
    private func handleDropFile(event e: SDL_Event) {
        // Access drop event data
        guard let filePath = e.drop.data else { return }
        let pathStr = String(cString: filePath)
        let ext = URL(fileURLWithPath: pathStr).pathExtension.lowercased()

        // ── CAD files: open in new tab ──
        let cadExtensions = Set(["dxf", "dwg", "eab"])
        if cadExtensions.contains(ext) {
            do {
                try engine.tabManager.openTab(url: URL(fileURLWithPath: pathStr))
                engine.zoomExtents()
                print("[Drop] Opened CAD file: \(pathStr)")
            } catch {
                print("[Drop] Failed to open CAD file \(pathStr): \(error)")
            }
            return
        }

        guard CADImageAsset.supportedExtensions.contains(ext) else { return }

        // Validate file size
        guard let fileSize = try? URL(fileURLWithPath: pathStr)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= CADImageAsset.maxFileBytes else {
            print("[Drop] Image file too large: \(pathStr)")
            return
        }

        // Read file data
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: pathStr)) else {
            print("[Drop] Failed to read image: \(pathStr)")
            return
        }

        // Decode to get dimensions
        let extForTmp = ext
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drop_\(UUID().uuidString).\(extForTmp)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try? imageData.write(to: tmpURL)
        guard let loadedSurface = tmpURL.path.withCString({ IMG_Load($0) }) else {
            print("[Drop] Failed to decode image: \(pathStr)")
            return
        }
        let pixelW = Int(loadedSurface.pointee.w)
        let pixelH = Int(loadedSurface.pointee.h)
        SDL_DestroySurface(loadedSurface)

        if pixelW * pixelH > CADImageAsset.maxDecodedPixels {
            print("[Drop] Image too large: \(pixelW)×\(pixelH)")
            return
        }

        // Create asset
        let hash = CADImageAsset.sha256Hex(imageData)
        let mimeType = CADImageAsset.mimeType(forExtension: ext)
        let asset = CADImageAsset(
            name: hash,
            originalFilename: URL(fileURLWithPath: pathStr).lastPathComponent,
            mimeType: mimeType,
            pixelWidth: pixelW,
            pixelHeight: pixelH,
            sha256: hash,
            data: imageData
        )
        engine.document.addImageAsset(asset)

        // Convert drop screen position to world
        let dropScreenX = e.drop.x
        let dropScreenY = e.drop.y
        let (worldX, worldY) = engine.camera.screenToWorld(
            screenX: dropScreenX, screenY: dropScreenY,
            windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)

        // Create image entity
        let layerID = engine.document.activeLayerID ?? engine.document.allLayers.first?.handle ?? UUID()
        let prim = CADPrimitive.image(
            center: Vector3(x: worldX, y: worldY, z: 0),
            width: Double(pixelW),
            height: Double(pixelH),
            rotation: 0,
            imageName: hash
        )
        let entity = CADEntity(layerID: layerID, localGeometry: [prim], transform: .identity)
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
    }

    /// Handle Ctrl+V: paste image from clipboard if available.
    private func handleClipboardPaste() {
        // Check for image data on clipboard
        let mimeTypes: [String] = ["image/png", "image/jpeg", "image/bmp", "image/tiff"]
        for mime in mimeTypes {
            guard SDL_HasClipboardData(mime) else { continue }

            var dataSize: Int = 0
            guard let rawPtr = SDL_GetClipboardData(mime, &dataSize),
                  dataSize > 0 else { continue }

            // Copy into Swift Data immediately, then free SDL buffer
            let imageData = Data(bytes: rawPtr, count: dataSize)
            SDL_free(rawPtr)

            // Validate by attempting decode
            let extForClip = mime.hasPrefix("image/png") ? "png"
                : mime.hasPrefix("image/jpeg") ? "jpg"
                : mime.hasPrefix("image/bmp") ? "bmp"
                : "tiff"
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("clip_\(UUID().uuidString).\(extForClip)")
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            try? imageData.write(to: tmpURL)
            guard let loadedSurface = tmpURL.path.withCString({ IMG_Load($0) }) else { continue }
            let pixelW = Int(loadedSurface.pointee.w)
            let pixelH = Int(loadedSurface.pointee.h)
            SDL_DestroySurface(loadedSurface)

            if pixelW * pixelH > CADImageAsset.maxDecodedPixels {
                print("[Clipboard] Image too large: \(pixelW)×\(pixelH)")
                return
            }

            // Create asset
            let hash = CADImageAsset.sha256Hex(imageData)
            let ext = mime.hasPrefix("image/png") ? "png"
                : mime.hasPrefix("image/jpeg") ? "jpg"
                : mime.hasPrefix("image/bmp") ? "bmp"
                : "tiff"
            let asset = CADImageAsset(
                name: hash,
                originalFilename: "clipboard.\(ext)",
                mimeType: mime,
                pixelWidth: pixelW,
                pixelHeight: pixelH,
                sha256: hash,
                data: imageData
            )
            engine.document.addImageAsset(asset)

            // Place at viewport center
            let (worldX, worldY) = engine.camera.screenToWorld(
                screenX: Float(engine.windowWidth / 2),
                screenY: Float(engine.windowHeight / 2),
                windowWidth: engine.windowWidth,
                windowHeight: engine.windowHeight)
            let layerID = engine.document.activeLayerID ?? engine.document.allLayers.first?.handle ?? UUID()
            let prim = CADPrimitive.image(
                center: Vector3(x: worldX, y: worldY, z: 0),
                width: Double(pixelW),
                height: Double(pixelH),
                rotation: 0,
                imageName: hash
            )
            let entity = CADEntity(layerID: layerID, localGeometry: [prim], transform: .identity)
            engine.document.addEntity(entity)
            engine.tabManager.markActiveDirty()
            return
        }
    }
}

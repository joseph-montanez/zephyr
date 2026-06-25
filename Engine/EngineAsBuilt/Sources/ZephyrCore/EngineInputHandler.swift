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

    internal init(engine: PhrostEngine) {
        self.engine = engine
    }

    // MARK: - Event Polling

    /// Polls all pending SDL events and dispatches them to the appropriate
    /// handler. Returns the number of events processed so the main loop
    /// knows whether to wake the renderer.
    internal func pollEvents() -> Int {
        var e = SDL_Event()
        var eventCount = 0

        let SDL_BUTTON_LEFT = 1
        let SDL_BUTTON_MIDDLE = 2

        while SDL_PollEvent(&e) {
            eventCount += 1
            let handledByImGui = engine.ui.processImGuiInput(event: &e)

            switch e.type {
            case UInt32(SDL_EVENT_QUIT.rawValue):
                engine.running = false
                return eventCount

            case UInt32(SDL_EVENT_WINDOW_RESIZED.rawValue):
                break

            case UInt32(SDL_EVENT_WINDOW_FOCUS_LOST.rawValue):
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
                // Release panning state that may be stuck from a missed mouse-up.
                engine.interaction.panActive = false
                engine.interaction.touchPanActive = false
                engine.interaction.touchFingersDown = 0
                engine.interaction.forceHideOSCursor = false
                // Release relative mouse mode and show the system cursor.
                _ = SDL_SetWindowRelativeMouseMode(engine.window, false)
                _ = SDL_ShowCursor()
                break

            case UInt32(SDL_EVENT_WINDOW_FOCUS_GAINED.rawValue):
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
                handleKeyDown(event: e, handledByImGui: handledByImGui)

            case UInt32(SDL_EVENT_KEY_UP.rawValue):
                handleKeyUp(event: e)

            case UInt32(SDL_EVENT_MOUSE_MOTION.rawValue):
                engine.interaction.lastMouseX = e.motion.x
                engine.interaction.lastMouseY = e.motion.y
                if !handledByImGui {
                    handleMouseMotion(x: e.motion.x, y: e.motion.y, xrel: e.motion.xrel, yrel: e.motion.yrel)
                }

            case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue):
                if Int(e.button.button) == SDL_BUTTON_LEFT && !handledByImGui {
                    handleMouseDown(x: e.button.x, y: e.button.y)
                } else if Int(e.button.button) == SDL_BUTTON_MIDDLE && !handledByImGui {
                    engine.interaction.panActive = true
                    engine.interaction.forceHideOSCursor = true
                    _ = SDL_SetWindowRelativeMouseMode(engine.window, true)
                }

            case UInt32(SDL_EVENT_MOUSE_BUTTON_UP.rawValue):
                if Int(e.button.button) == SDL_BUTTON_LEFT {
                    if engine.interaction.panActive {
                        engine.interaction.panActive = false
                        engine.interaction.forceHideOSCursor = false
                        _ = SDL_SetWindowRelativeMouseMode(engine.window, false)
                    }
                    handleMouseUp(x: e.button.x, y: e.button.y)
                } else if Int(e.button.button) == SDL_BUTTON_MIDDLE {
                    engine.interaction.panActive = false
                    engine.interaction.forceHideOSCursor = false
                    _ = SDL_SetWindowRelativeMouseMode(engine.window, false)
                }

            case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue):
                if !handledByImGui {
                    let wy = e.wheel.y
                    let dir = e.wheel.direction.rawValue == SDL_MouseWheelDirection.flipped.rawValue
                        ? -wy : wy
                    let factor = dir > 0 ? 1.375 : 1.0 / 1.375
                    engine.camera.zoomView(factor: factor, screenX: engine.interaction.lastMouseX, screenY: engine.interaction.lastMouseY, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
                }

            // MARK: Two-finger trackpad pan
            case UInt32(SDL_EVENT_FINGER_DOWN.rawValue):
                engine.interaction.touchFingersDown += 1
                if engine.interaction.touchFingersDown >= 2 && !engine.interaction.dragActive && !engine.interaction.gripActive && !engine.interaction.rectSelectActive {
                    engine.interaction.lastTouchAvgX = e.tfinger.x
                    engine.interaction.lastTouchAvgY = e.tfinger.y
                    engine.interaction.touchPanActive = false
                }

            case UInt32(SDL_EVENT_FINGER_UP.rawValue):
                engine.interaction.touchFingersDown = max(0, engine.interaction.touchFingersDown - 1)
                if engine.interaction.touchFingersDown < 2 {
                    engine.interaction.touchPanActive = false
                }

            case UInt32(SDL_EVENT_FINGER_MOTION.rawValue):
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
                            let cr = -engine.camera.rotation
                            let cosR = cos(cr)
                            let sinR = sin(cr)
                            let dCamX = (-cosR * dx - sinR * dy) / engine.camera.zoom
                            let dCamY = (sinR * dx - cosR * dy) / engine.camera.zoom
                            engine.camera.offset.x += dCamX
                            engine.camera.offset.y += dCamY
                        }
                        engine.interaction.lastTouchAvgX = curX
                        engine.interaction.lastTouchAvgY = curY
                    }
                }

            case UInt32(SDL_EVENT_DROP_FILE.rawValue):
                handleDropFile(event: e)

            default:
                break
            }
        }
        return eventCount
    }

    // MARK: - Keyboard Handling

    private func handleKeyDown(event e: SDL_Event, handledByImGui: Bool) {
        // Escape-to-close the command line / layer-move popup works even
        // when ImGui has keyboard capture.
        if e.key.scancode == SDL_SCANCODE_ESCAPE {
            if engine.ui.layerMoveActive {
                engine.ui.layerMoveActive = false
                engine.ui.layerMoveBuffer = ""
                engine.ui.layerMoveMatches = []
            } else if engine.commandProcessor.commandLineActive {
                engine.commandProcessor.commandLineActive = false
                engine.commandProcessor.commandBuffer = ""
            }
        }

        if !handledByImGui {
            let ctrlHeld = engine.io != nil && (engine.io.pointee.KeyCtrl || engine.io.pointee.KeySuper)

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
                    engine.fileBrowser.open(filterExtension: "dxf;eab")
                case SDL_SCANCODE_N:
                    engine.tabManager.newTab()
                    engine.zoomExtents()
                case SDL_SCANCODE_W:
                    if engine.io.pointee.KeyShift {
                        engine.commandProcessor.executeCommand("CLOSEALL")
                    } else {
                    _ = engine.tabManager.closeActiveTab()
                    }
                case SDL_SCANCODE_S:
                    if engine.io.pointee.KeyShift {
                        engine.saveFileBrowser.openSave(
                            filterExtension: "dxf;eab;pdf",
                            defaultName: engine.tabManager.activeTab?.displayName ?? "untitled")
                    } else {
                        do {
                            try engine.tabManager.saveActiveTab()
                        } catch TabManager.TabError.noFileURL {
                            engine.saveFileBrowser.openSave(
                                filterExtension: "dxf;eab;pdf",
                                defaultName: engine.tabManager.activeTab?.displayName ?? "untitled")
                        } catch {
                            print("Save failed: \(error)")
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
                case SDL_SCANCODE_P:
                    if engine.io.pointee.KeyShift {
                        engine.commandProcessor.executeCommand("PDFIMPORT")
                    }
                default:
                    break
                }
            } else {
                // ── Bare key handling (no Ctrl/Cmd held) ──
                switch e.key.scancode {
                case SDL_SCANCODE_ESCAPE:
                    engine.snap.lockedSnap = nil
                    engine.snap.snapTrackingEngine.clear()
                    engine.snap.lastPolarResult = nil
                    if let featureCmd = engine.commandProcessor.activeFeatureCommand {
                        _ = featureCmd.handleKeyDown(
                            scancode: SDL_SCANCODE_ESCAPE, engine: engine,
                            processor: engine.commandProcessor)
                        engine.commandProcessor.finishFeatureCommand(engine: engine)
                    } else if engine.commandProcessor.activeCommand != nil {
                        engine.commandProcessor.clearCommand()
                    } else if engine.interaction.rectSelectActive {
                        engine.interaction.rectSelectActive = false
                        engine.interaction.rectSelectPreviewHandles.removeAll()
                    } else if engine.cadSelection.hasSelection {
                        engine.cadSelection.clearSelection()
                    }
                case SDL_SCANCODE_DELETE, SDL_SCANCODE_BACKSPACE:
                    engine.deleteSelected()
                case SDL_SCANCODE_UP:
                    handleArrowUp()
                case SDL_SCANCODE_DOWN:
                    handleArrowDown()

                case SDL_SCANCODE_SPACE:
                    // Space repeats last command (AutoCAD style).
                    // Only fires when no command / command-line / layer-move is active.
                    if !engine.commandProcessor.commandLineActive
                        && engine.commandProcessor.activeCommand == nil
                        && engine.commandProcessor.activeFeatureCommand == nil
                        && !engine.ui.layerMoveActive {
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
                    engine.camera.zoomView(factor: 1.0 / 1.375, screenX: engine.interaction.lastMouseX, screenY: engine.interaction.lastMouseY, windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
                case SDL_SCANCODE_0:
                    engine.camera.zoom = 1.0
                    engine.camera.offset = (0, 0)
                default:
                    // Route to active feature command
                    if let featureCmd = engine.commandProcessor.activeFeatureCommand {
                        let result = featureCmd.handleKeyDown(
                            scancode: e.key.scancode, engine: engine,
                            processor: engine.commandProcessor)
                        if result == .finished {
                            engine.commandProcessor.finishFeatureCommand(engine: engine)
                        }
                    } else if !engine.commandProcessor.commandLineActive
                                && engine.commandProcessor.activeCommand == nil
                                && engine.commandProcessor.activeFeatureCommand == nil {
                        // Typing a letter key opens the command line with that character
                        // injected as the first buffer entry (AutoCAD-style dynamic input).
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

        // Enter key: confirm layer-move popup, or route to active feature command
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
            } else if let featureCmd = engine.commandProcessor.activeFeatureCommand {
                let result = featureCmd.handleKeyDown(
                    scancode: e.key.scancode, engine: engine,
                    processor: engine.commandProcessor)
                if result == .finished {
                    engine.commandProcessor.finishFeatureCommand(engine: engine)
                }
            }
        }
    }

    private func handleKeyUp(event e: SDL_Event) {
        // No-op: space-held pan and space-to-open-command-line are removed.
        // Pan is now exclusively via middle-mouse drag or two-finger trackpad.
        // Command line opens by typing any letter key.
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

    // MARK: - Mouse Motion

    private func handleMouseMotion(x: Float, y: Float, xrel: Float, yrel: Float) {
        if engine.interaction.panActive {
            let screenDx = Double(xrel)
            let screenDy = Double(yrel)
            let cr = -engine.camera.rotation
            let cosR = cos(cr)
            let sinR = sin(cr)
            let dCamX = (-cosR * screenDx - sinR * screenDy) / engine.camera.zoom
            let dCamY = (sinR * screenDx - cosR * screenDy) / engine.camera.zoom
            engine.camera.offset.x += dCamX
            engine.camera.offset.y += dCamY
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

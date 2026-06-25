import Foundation
import CSDL3
import SwiftSDL
import ImGui

// =========================================================================
// MARK: - EngineUIManager
//
// Integrates the ImGui library with the SDL3 GPU rendering pipeline.
// Handles:
//   - Rendering ImGui draw lists as GPU draw calls
//   - Mapping SDL3 input events (mouse, keyboard, text) to ImGui IO
//   - UI state visibility (toolbars, layers, block panels)
//   - Applying themes to both the UI and Viewport background
// =========================================================================
@MainActor
public final class EngineUIManager {
    
    // MARK: - UI State Properties
    
    /// Whether the toolbar is visible.
    public var toolbarVisible: Bool = true
    public var radialNavVisible: Bool = false
    public var showFPS: Bool = false

    /// Whether the properties panel is visible (toggled via "props" command).
    public var showPropertiesPanel: Bool = false
    
    /// Whether the Draw Tools palette is visible (toggled via "DRAW" command).
    public var drawPaletteVisible: Bool = false

    /// Whether the Blocks panel is visible (toggled via "BLOCKS" command).
    public var blockPanelVisible: Bool = false

    /// Whether the Layers panel is visible (toggled via "LA"/"LAYER" command). Default true.
    public var layersPanelVisible: Bool = true
    public var fpsCacheFrame: Int = 15

    /// When true, the block editor close-confirmation popup is shown.
    /// Set by the "Save & Close Block" button or BCLOSE command;
    /// cleared by the popup's Save/Discard/Cancel actions.
    public var blockClosePending: Bool = false

    public var layerMoveActive: Bool = false
    public var layerMoveSelectionIndex: Int = 0
    public var layerMoveBuffer: String = ""
    public var layerMoveMatches: [Layer] = []
    
    public var topChromeExcludeRect: SDL_Rect? = nil

    
    public var boldFont: UnsafeMutablePointer<ImFont>? = nil
    public var smallFont: UnsafeMutablePointer<ImFont>? = nil
    public var monoFont: UnsafeMutablePointer<ImFont>? = nil
    public var largeFont: UnsafeMutablePointer<ImFont>? = nil
    public var titleFont: UnsafeMutablePointer<ImFont>? = nil
    public var commandTitleFont: UnsafeMutablePointer<ImFont>? = nil
    public var commandPillFont: UnsafeMutablePointer<ImFont>? = nil
    public var commandDescriptionFont: UnsafeMutablePointer<ImFont>? = nil
    
    // MARK: - Theme State
    
    /// Whether the current UI theme is dark (true) or light (false).
    public var isDarkTheme: Bool = true
    
    /// The currently active AppTheme instance.
    public var theme: AppTheme {
        return isDarkTheme ? AppTheme.dark : AppTheme.light
    }
    
    /// Viewport background color (normalized 0-1). Changed via SET-BACKGROUND command.
    /// Default is navy #102b41 to match dark theme.
    public var backgroundColor = SDL_FColor(r: 0.06, g: 0.17, b: 0.25, a: 1.0) {
        didSet { displayPaletteGeneration &+= 1 }
    }

    /// Monotonic counter bumped on any change that affects display-adaptive colors
    /// (background color, dark/light theme). The render cache compares this against
    /// its cached value to detect when the vertex buffer must be rebuilt.
    public internal(set) var displayPaletteGeneration: Int = 0
    
    public init() {}
    
    // MARK: - Theme Management
    
    /// Apply the current theme to both ImGui style colors and the viewport background.
    public func applyTheme() {
        guard let style = igGetStyle() else { return }

        // Canvas/viewport background
        backgroundColor = theme.viewportBg

        // Base ImGui theme
        if isDarkTheme {
            igStyleColorsDark(style)
        } else {
            igStyleColorsLight(style)
        }

        withUnsafeMutablePointer(to: &style.pointee.Colors) { tuplePtr in
            tuplePtr.withMemoryRebound(to: ImVec4.self, capacity: Int(ImGuiCol_COUNT.rawValue)) { colors in
                
                // Generic mappings for both themes based on semantic colors
                colors[Int(ImGuiCol_Button.rawValue)]        = theme.border
                colors[Int(ImGuiCol_ButtonHovered.rawValue)] = theme.brandGoldHover
                colors[Int(ImGuiCol_ButtonActive.rawValue)]  = theme.brandGoldActive

                colors[Int(ImGuiCol_Header.rawValue)]        = theme.border
                colors[Int(ImGuiCol_HeaderHovered.rawValue)] = theme.brandGoldHover
                colors[Int(ImGuiCol_HeaderActive.rawValue)]  = theme.brandGoldActive

                colors[Int(ImGuiCol_Tab.rawValue)]           = theme.tabBarBg
                colors[Int(ImGuiCol_TabHovered.rawValue)]    = theme.border
                colors[Int(ImGuiCol_TabSelected.rawValue)]   = theme.panelBg

                colors[Int(ImGuiCol_TitleBg.rawValue)]       = theme.topChromeBg
                colors[Int(ImGuiCol_TitleBgActive.rawValue)] = theme.topChromeBg
                
                colors[Int(ImGuiCol_Separator.rawValue)]     = theme.border
                colors[Int(ImGuiCol_Border.rawValue)]        = theme.borderDim
                
                colors[Int(ImGuiCol_WindowBg.rawValue)]      = theme.panelBg
                colors[Int(ImGuiCol_Text.rawValue)]          = theme.textPrimary
            }
        }
    }

    /// Toggle between dark and light theme.
    public func toggleTheme() {
        isDarkTheme.toggle()
        displayPaletteGeneration &+= 1
        applyTheme()
    }
    
    // MARK: - ImGui Rendering

    internal func renderImGuiDrawData(cmd: OpaquePointer, renderPass: OpaquePointer, renderer: EngineRenderer, fontTexture: OpaquePointer?) {
        guard let drawData = ImGuiGetDrawData(), drawData.pointee.CmdListsCount > 0 else {
            return
        }

        let fbWidth = Int(drawData.pointee.DisplaySize.x * drawData.pointee.FramebufferScale.x)
        let fbHeight = Int(drawData.pointee.DisplaySize.y * drawData.pointee.FramebufferScale.y)
        if fbWidth <= 0 || fbHeight <= 0 { return }

        // Bind pipeline
        SDL_BindGPUGraphicsPipeline(renderPass, renderer.imguiPipeline)

        // Bind vertex and index buffers
        var vertexBinding = SDL_GPUBufferBinding(buffer: renderer.imguiVertexBuffer, offset: 0)
        SDL_BindGPUVertexBuffers(renderPass, 0, &vertexBinding, 1)

        var indexBinding = SDL_GPUBufferBinding(buffer: renderer.imguiIndexBuffer, offset: 0)
        SDL_BindGPUIndexBuffer(renderPass, &indexBinding, SDL_GPU_INDEXELEMENTSIZE_16BIT)

        // Push orthographic projection matrix
        let w = Float(drawData.pointee.DisplaySize.x)
        let h = Float(drawData.pointee.DisplaySize.y)
        var proj: [Float] = [
            2.0 / w, 0.0, 0.0, 0.0,
            0.0, -2.0 / h, 0.0, 0.0,
            0.0, 0.0, 0.5, 0.0,
            -1.0, 1.0, 0.0, 1.0
        ]
        SDL_PushGPUVertexUniformData(cmd, 0, &proj, UInt32(proj.count * 4))

        let clipOff = drawData.pointee.DisplayPos
        let clipScale = drawData.pointee.FramebufferScale

        var globalVtxOffset = 0
        var globalIdxOffset = 0

        for n in 0..<Int(drawData.pointee.CmdListsCount) {
            guard let cmdList = drawData.pointee.CmdLists.Data?[n] else { continue }

            for cmdIdx in 0..<Int(cmdList.pointee.CmdBuffer.Size) {
                let cmdDraw = cmdList.pointee.CmdBuffer.Data[cmdIdx]

                if cmdDraw.ElemCount == 0 { continue }

                if let _ = cmdDraw.UserCallback {
                    continue
                }

                // Compute scissor rect
                var clipMinX = (cmdDraw.ClipRect.x - clipOff.x) * clipScale.x
                var clipMinY = (cmdDraw.ClipRect.y - clipOff.y) * clipScale.y
                var clipMaxX = (cmdDraw.ClipRect.z - clipOff.x) * clipScale.x
                var clipMaxY = (cmdDraw.ClipRect.w - clipOff.y) * clipScale.y

                if clipMinX < 0 { clipMinX = 0 }
                if clipMinY < 0 { clipMinY = 0 }
                if clipMaxX > Float(fbWidth) { clipMaxX = Float(fbWidth) }
                if clipMaxY > Float(fbHeight) { clipMaxY = Float(fbHeight) }
                if clipMaxX <= clipMinX || clipMaxY <= clipMinY { continue }

                var scissor = SDL_Rect(
                    x: Int32(clipMinX),
                    y: Int32(clipMinY),
                    w: Int32(clipMaxX - clipMinX),
                    h: Int32(clipMaxY - clipMinY)
                )
                SDL_SetGPUScissor(renderPass, &scissor)

                // Bind texture-sampler
                let textureID = ImDrawCmdGetTexID(&cmdList.pointee.CmdBuffer.Data[cmdIdx])
                let texturePtr: OpaquePointer?
                if textureID != 0 {
                    texturePtr = OpaquePointer(bitPattern: UInt(textureID))
                } else {
                    texturePtr = fontTexture
                }

                var textureBinding = SDL_GPUTextureSamplerBinding(texture: texturePtr, sampler: renderer.fontSampler)
                SDL_BindGPUFragmentSamplers(renderPass, 0, &textureBinding, 1)

                // Issue draw call
                SDL_DrawGPUIndexedPrimitives(
                    renderPass,
                    cmdDraw.ElemCount,
                    1,
                    UInt32(globalIdxOffset) + cmdDraw.IdxOffset,
                    Int32(globalVtxOffset) + Int32(cmdDraw.VtxOffset),
                    0
                )
            }

            globalVtxOffset += Int(cmdList.pointee.VtxBuffer.Size)
            globalIdxOffset += Int(cmdList.pointee.IdxBuffer.Size)
        }
    }

    // MARK: - ImGui Input Processing

    internal func processImGuiInput(event: inout SDL_Event) -> Bool {
        guard let io = ImGuiGetIO() else { return false }

        switch event.type {

        case UInt32(SDL_EVENT_MOUSE_MOTION.rawValue):
            ImGuiIO_AddMousePosEvent(io, event.motion.x, event.motion.y)
            return io.pointee.WantCaptureMouse

        case UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue),
            UInt32(SDL_EVENT_MOUSE_BUTTON_UP.rawValue):
            let isDown = (event.type == UInt32(SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue))
            var imGuiButton: Int32 = 0

            let SDL_BUTTON_LEFT = 1
            let SDL_BUTTON_MIDDLE = 2
            let SDL_BUTTON_RIGHT = 3

            switch Int32(event.button.button) {
            case Int32(SDL_BUTTON_LEFT): imGuiButton = 0
            case Int32(SDL_BUTTON_RIGHT): imGuiButton = 1
            case Int32(SDL_BUTTON_MIDDLE): imGuiButton = 2
            default: return false
            }
            ImGuiIO_AddMouseButtonEvent(io, imGuiButton, isDown)
            return io.pointee.WantCaptureMouse

        case UInt32(SDL_EVENT_MOUSE_WHEEL.rawValue):
            var wheelX = event.wheel.x
            var wheelY = event.wheel.y
            if event.wheel.direction.rawValue == SDL_MouseWheelDirection.flipped.rawValue {
                wheelX *= -1
                wheelY *= -1
            }
            ImGuiIO_AddMouseWheelEvent(io, wheelX, wheelY)
            return io.pointee.WantCaptureMouse

        case UInt32(SDL_EVENT_TEXT_INPUT.rawValue):
            if let textPtr = event.text.text {
                ImGuiIO_AddInputCharactersUTF8(io, textPtr)
            }
            return io.pointee.WantCaptureKeyboard

        case UInt32(SDL_EVENT_KEY_DOWN.rawValue),
            UInt32(SDL_EVENT_KEY_UP.rawValue):
            let isDown = (event.type == UInt32(SDL_EVENT_KEY_DOWN.rawValue))
            let imKey = Self.mapSDLKeyToImGuiKey(event.key.key)

            if imKey != ImGuiKey_None {
                ImGuiIO_AddKeyEvent(io, imKey, isDown)
            }

            if event.key.scancode == SDL_SCANCODE_LCTRL || event.key.scancode == SDL_SCANCODE_RCTRL {
                ImGuiIO_AddKeyEvent(io, ImGuiMod_Ctrl, isDown)
            }
            if event.key.scancode == SDL_SCANCODE_LSHIFT || event.key.scancode == SDL_SCANCODE_RSHIFT {
                ImGuiIO_AddKeyEvent(io, ImGuiMod_Shift, isDown)
            }
            if event.key.scancode == SDL_SCANCODE_LALT || event.key.scancode == SDL_SCANCODE_RALT {
                ImGuiIO_AddKeyEvent(io, ImGuiMod_Alt, isDown)
            }
            return io.pointee.WantCaptureKeyboard

        default:
            return false
        }
    }

    private static func mapSDLKeyToImGuiKey(_ k: UInt32) -> ImGuiKey {
        switch k {
        case SDLK_TAB:        return ImGuiKey_Tab
        case SDLK_LEFT:       return ImGuiKey_LeftArrow
        case SDLK_RIGHT:      return ImGuiKey_RightArrow
        case SDLK_UP:         return ImGuiKey_UpArrow
        case SDLK_DOWN:       return ImGuiKey_DownArrow
        case SDLK_PAGEUP:     return ImGuiKey_PageUp
        case SDLK_PAGEDOWN:   return ImGuiKey_PageDown
        case SDLK_HOME:       return ImGuiKey_Home
        case SDLK_END:        return ImGuiKey_End
        case SDLK_INSERT:     return ImGuiKey_Insert
        case SDLK_DELETE:     return ImGuiKey_Delete
        case SDLK_BACKSPACE:  return ImGuiKey_Backspace
        case SDLK_SPACE:      return ImGuiKey_Space
        case SDLK_RETURN, SDLK_KP_ENTER: return ImGuiKey_Enter
        case SDLK_ESCAPE:     return ImGuiKey_Escape
        case SDLK_CAPSLOCK:   return ImGuiKey_CapsLock
        case SDLK_SCROLLLOCK: return ImGuiKey_ScrollLock
        case SDLK_NUMLOCKCLEAR: return ImGuiKey_NumLock
        case SDLK_PRINTSCREEN: return ImGuiKey_PrintScreen
        case SDLK_PAUSE:      return ImGuiKey_Pause
        case SDLK_A...SDLK_Z:
            return ImGuiKey(rawValue: ImGuiKey_A.rawValue + ImGuiKey.RawValue(k - SDLK_A))
        case SDLK_0...SDLK_9:
            return ImGuiKey(rawValue: ImGuiKey_0.rawValue + ImGuiKey.RawValue(k - SDLK_0))
        case SDLK_F1...SDLK_F12:
            return ImGuiKey(rawValue: ImGuiKey_F1.rawValue + ImGuiKey.RawValue(k - SDLK_F1))
        case SDLK_KP_0: return ImGuiKey_Keypad0
        case SDLK_KP_1: return ImGuiKey_Keypad1
        case SDLK_KP_2: return ImGuiKey_Keypad2
        case SDLK_KP_3: return ImGuiKey_Keypad3
        case SDLK_KP_4: return ImGuiKey_Keypad4
        case SDLK_KP_5: return ImGuiKey_Keypad5
        case SDLK_KP_6: return ImGuiKey_Keypad6
        case SDLK_KP_7: return ImGuiKey_Keypad7
        case SDLK_KP_8: return ImGuiKey_Keypad8
        case SDLK_KP_9: return ImGuiKey_Keypad9
        case SDLK_KP_DECIMAL:  return ImGuiKey_KeypadDecimal
        case SDLK_KP_DIVIDE:   return ImGuiKey_KeypadDivide
        case SDLK_KP_MULTIPLY: return ImGuiKey_KeypadMultiply
        case SDLK_KP_MINUS:    return ImGuiKey_KeypadSubtract
        case SDLK_KP_PLUS:     return ImGuiKey_KeypadAdd
        case SDLK_KP_EQUALS:   return ImGuiKey_KeypadEqual
        case SDLK_LCTRL:       return ImGuiKey_LeftCtrl
        case SDLK_LSHIFT:      return ImGuiKey_LeftShift
        case SDLK_LALT:        return ImGuiKey_LeftAlt
        case SDLK_LGUI:        return ImGuiKey_LeftSuper
        case SDLK_RCTRL:       return ImGuiKey_RightCtrl
        case SDLK_RSHIFT:      return ImGuiKey_RightShift
        case SDLK_RALT:        return ImGuiKey_RightAlt
        case SDLK_RGUI:        return ImGuiKey_RightSuper
        case SDLK_MENU:        return ImGuiKey_Menu
        case SDLK_COMMA:       return ImGuiKey_Comma
        case SDLK_PERIOD:      return ImGuiKey_Period
        case SDLK_SLASH:       return ImGuiKey_Slash
        case SDLK_SEMICOLON:   return ImGuiKey_Semicolon
        case SDLK_EQUALS:      return ImGuiKey_Equal
        case SDLK_LEFTBRACKET:  return ImGuiKey_LeftBracket
        case SDLK_BACKSLASH:    return ImGuiKey_Backslash
        case SDLK_RIGHTBRACKET: return ImGuiKey_RightBracket
        case SDLK_GRAVE:        return ImGuiKey_GraveAccent
        case SDLK_MINUS:        return ImGuiKey_Minus
        case SDLK_APOSTROPHE:   return ImGuiKey_Apostrophe
        default:
            return ImGuiKey_None
        }
    }
}

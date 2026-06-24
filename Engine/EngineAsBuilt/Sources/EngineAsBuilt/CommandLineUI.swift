import EngineAsBuiltCore
import Foundation
import ImGui

// MARK: - CommandLineUI
//
// Renders the command-line interface at the bottom of the screen.
// Activated by the Space key, this provides an AutoCAD-style command prompt
// with input buffer, autocomplete popup, and Up/Down arrow history.
//
// Key behaviors:
//   - Space: Toggle command line open/closed
//   - Tab: Auto-complete to the first match
//   - Up/Down: Navigate through autocomplete matches
//   - Enter: Execute the current buffer or selected autocomplete match
//   - Esc: Cancel / close command line
//
// The command buffer is persisted in engine.commandProcessor.commandBuffer
// between frames, allowing incremental typing and live filtering of matches.

@MainActor
struct CommandLineUI {
    /// Cached autocomplete matches updated each frame while the command line is open.
    static var _cmdAutoMatches: [(descriptor: CommandDescriptor, matchingAlias: String)] = []

    /// When true, the next InputText callback frame will clear any text selection
    /// and move the cursor to the end. Set after filling the buffer with a command
    /// name that needs parameters (Enter on BACKGROUND, LAYER NEW, etc.).
    static var _needsClearSelection: Bool = false

    /// Tracks previous frame's command line state to detect when it just opened.
    static var _wasCommandLineActive: Bool = false
    static var _needsFocus: Bool = false

    /// Renders the command line at the bottom of the screen.
    /// - Parameters:
    ///   - engine: The engine instance for command execution and state.
    ///   - dw: Display width for full-width positioning.
    ///   - dh: Display height for bottom-anchored positioning.
    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        let isCommandLineActive = engine.commandProcessor.commandLineActive

        // When the command line first opens, we must clear any default text selection
        // (e.g., from ImGui auto-selecting the injected first character like 't').
        if isCommandLineActive && !_wasCommandLineActive {
            _needsClearSelection = true
            _needsFocus = true
        }
        _wasCommandLineActive = isCommandLineActive

        guard isCommandLineActive else { return }

        let cmdW: Float = 1000 // Centered fixed width
        let winX = (dw - cmdW) / 2.0
        let winY = dh * 0.3

        // Position centered
        ImGuiSetNextWindowPos(
            ImVec2(x: winX, y: winY),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0)
        )
        // Let it auto-resize height based on autocomplete matches up to a max
        ImGuiSetNextWindowSizeConstraints(
            ImVec2(x: cmdW, y: 0),
            ImVec2(x: cmdW, y: dh * 0.6),
            { _ in },
            nil
        )

        ImGuiPushStyleVarX(Int32(ImGuiStyleVar_WindowPadding.rawValue), 16)
        ImGuiPushStyleVarY(Int32(ImGuiStyleVar_WindowPadding.rawValue), 16)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), 14.0)
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), engine.ui.theme.panelBg)
        
        ImGuiPushStyleColor(Int32(ImGuiCol_FrameBg.rawValue), ImVec4(x: 0, y: 0, z: 0, w: 0))
        ImGuiPushStyleColor(Int32(ImGuiCol_Border.rawValue), engine.ui.theme.border)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 1.0)

        let wflags: Int32 = 1 | 2 | 4 | 8 | 64 | 256 // Added ImGuiWindowFlags_AlwaysAutoResize (64)
        let paletteFlags: Int32 = wflags | 4096 // ImGuiWindowFlags_NoFocusOnAppearing
        
        // Filter commands based on the current input to populate the autocomplete.
        let newText = engine.commandProcessor.commandBuffer
        let inputMatches = engine.commandProcessor.matchCommands(input: newText)
        let selIndex = engine.commandProcessor.commandSelectionIndex
        _cmdAutoMatches = inputMatches
        
        let clampedIndex = !inputMatches.isEmpty ? max(0, min(selIndex, inputMatches.count - 1)) : 0
        let paramHint = findParameterHint(input: newText)
        let showPalette = !inputMatches.isEmpty || (!newText.isEmpty && paramHint != nil)
        
        var currentY = winY
        
        // 1. INPUT WINDOW
        ImGuiSetNextWindowPos(ImVec2(x: winX, y: currentY), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSizeConstraints(ImVec2(x: cmdW, y: 0), ImVec2(x: cmdW, y: dh * 0.6), { _ in }, nil)
        
        if igBegin("##CmdLine", nil, wflags) {
            if let titleFont = engine.ui.titleFont { ImGuiPushFont(titleFont, 0.0) }
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.brandGold)
            ImGuiTextV("›")
            ImGuiPopStyleColor(1)
            ImGuiSameLine(0, 16)
            
            let promptText = "Cmd: "
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textDim)
            ImGuiTextV(promptText)
            ImGuiPopStyleColor(1)
            ImGuiSameLine(0, 8)

            ImGuiPushItemWidth(-1)
            
            let bufSize = 256
            var cBuf = [CChar](repeating: 0, count: bufSize)
            let initBytes = engine.commandProcessor.commandBuffer.utf8CString
            let copyLen = min(initBytes.count, bufSize - 1)

            cBuf.withUnsafeMutableBufferPointer { ptr in
                _ = ptr.initialize(from: initBytes.prefix(copyLen))
            }

            var submitted = false
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), engine.ui.theme.textPrimary)
            
            if CommandLineUI._needsFocus {
                igSetKeyboardFocusHere(0)
                CommandLineUI._needsFocus = false
            }

            submitted = cBuf.withUnsafeMutableBufferPointer { bufPtr -> Bool in
                guard let base = bufPtr.baseAddress else { return false }
                
                return igInputTextWithHint(
                    "##CmdInput",
                    "type a command...",
                    base,
                    bufSize,
                    Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue)
                        | Int32(ImGuiInputTextFlags_CallbackCompletion.rawValue)
                        | Int32(ImGuiInputTextFlags_CallbackAlways.rawValue),
                    { data in
                        guard let d = data else { return 0 }
                        if CommandLineUI._needsClearSelection {
                            let len = d.pointee.BufTextLen
                            d.pointee.CursorPos = len
                            d.pointee.SelectionStart = len
                            d.pointee.SelectionEnd = len
                            CommandLineUI._needsClearSelection = false
                        }
                        return 0
                    },
                    nil
                )
            }
            ImGuiPopStyleColor(1)
            
            let pMin = igGetItemRectMin()
            let pMax = igGetItemRectMax()
            let drawList = igGetWindowDrawList()
            let goldCol = igGetColorU32_Vec4(engine.ui.theme.brandGold)
            let goldTransparent = (goldCol & 0x00FFFFFF) | 0x7F000000
            let underlineY = pMax.y + 4.0
            ImDrawListAddRectFilled(drawList, ImVec2(x: pMin.x, y: underlineY), ImVec2(x: pMax.x, y: underlineY + 3.0), goldTransparent, 0.0, 0)

            let newTextFromInput = cBuf.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress else { return "" }
                return String(cString: base)
            }

            if newTextFromInput != engine.commandProcessor.commandBuffer {
                engine.commandProcessor.commandBuffer = newTextFromInput
                engine.commandProcessor.commandSelectionIndex = 0
                CommandLineUI._needsClearSelection = true
            }

            if !inputMatches.isEmpty && ImGuiIsKeyPressed(ImGuiKey_Tab, false) {
                engine.commandProcessor.commandBuffer = inputMatches[0].descriptor.canonicalName
                engine.commandProcessor.commandSelectionIndex = 0
                CommandLineUI._needsClearSelection = true
            }

            updateSelection(engine: engine, matches: inputMatches)

            if submitted {
                if !inputMatches.isEmpty && clampedIndex >= 0 && clampedIndex < inputMatches.count {
                    let desc = inputMatches[clampedIndex].descriptor
                    if !desc.syntax.isEmpty {
                        prepareForParameterEntry(engine: engine, descriptor: desc)
                    } else {
                        engine.commandProcessor.commandLineActive = false
                        engine.commandProcessor.executeCommand(desc.canonicalName)
                    }
                } else {
                    let hint = findParameterHint(input: newTextFromInput)
                    if let hintDesc = hint {
                        let cmdLen = hintDesc.canonicalName.count + 1
                        if newTextFromInput.count > cmdLen {
                            engine.commandProcessor.commandLineActive = false
                            engine.commandProcessor.executeCommand(newTextFromInput)
                        } else {
                            prepareForParameterEntry(engine: engine, descriptor: hintDesc)
                        }
                    } else {
                        engine.commandProcessor.commandLineActive = false
                        engine.commandProcessor.executeCommand(newTextFromInput)
                    }
                }
            }

            ImGuiPopItemWidth()
            if engine.ui.titleFont != nil { ImGuiPopFont() }
        }
        let inputHeight = igGetWindowHeight()
        igEnd()

        currentY += inputHeight + 8.0

        // 2. PALETTE WINDOW
        if showPalette || (!newText.isEmpty) {
            ImGuiSetNextWindowPos(ImVec2(x: winX, y: currentY), Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
            ImGuiSetNextWindowSizeConstraints(ImVec2(x: cmdW, y: 0), ImVec2(x: cmdW, y: dh * 0.6), { _ in }, nil)
            
            if igBegin("##CmdPalette", nil, paletteFlags) {
                if !inputMatches.isEmpty {
                    CommandAutocompleteUI.renderMatches(
                        engine: engine,
                        matches: inputMatches,
                        clampedIndex: clampedIndex,
                        cmdW: cmdW
                    )
                } else if !newText.isEmpty {
                    if let hintDesc = paramHint {
                        CommandAutocompleteUI.renderMatches(
                            engine: engine,
                            matches: [(hintDesc, hintDesc.canonicalName)],
                            clampedIndex: 0,
                            cmdW: cmdW
                        )
                    } else {
                        CommandAutocompleteUI.renderNoMatches(engine: engine, cmdW: cmdW)
                    }
                }
            }
            igEnd()
        }

        ImGuiPopStyleVar(4)
        ImGuiPopStyleColor(3)
    }

    /// Completes a command that still needs arguments and keeps the text field
    /// ready for uninterrupted typing after Enter deactivates InputText.
    private static func prepareForParameterEntry(
        engine: PhrostEngine,
        descriptor: CommandDescriptor
    ) {
        engine.commandProcessor.commandBuffer = descriptor.canonicalName + " "
        engine.commandProcessor.commandSelectionIndex = 0
        _needsClearSelection = true
        _needsFocus = true
    }

    private static func findParameterHint(input: String) -> CommandDescriptor? {
        let upper = input.uppercased()
        for desc in CommandDescriptor.allCommands {
            for candidate in desc.allMatches {
                if upper.hasPrefix(candidate + " ") {
                    return desc
                }
            }
        }
        return nil
    }

    /// Handles Up/Down arrow key navigation through the autocomplete list.
    /// Wraps around at the boundaries for a seamless cycling experience.
    @MainActor
    private static func updateSelection(
        engine: PhrostEngine,
        matches: [(descriptor: CommandDescriptor, matchingAlias: String)]
    ) {
        guard !matches.isEmpty else { return }

        if ImGuiIsKeyPressed(ImGuiKey_UpArrow, false) {
            if engine.commandProcessor.commandSelectionIndex > 0 {
                engine.commandProcessor.commandSelectionIndex -= 1
            } else {
                engine.commandProcessor.commandSelectionIndex = matches.count - 1
            }
        }

        if ImGuiIsKeyPressed(ImGuiKey_DownArrow, false) {
            if engine.commandProcessor.commandSelectionIndex + 1 < matches.count {
                engine.commandProcessor.commandSelectionIndex += 1
            } else {
                engine.commandProcessor.commandSelectionIndex = 0
            }
        }
    }
}

import Foundation

// =========================================================================
// MARK: - Command Prompt Input Kind + Pending Prompted Sessions
//
// Space == Enter rework (one token per keypress).
//
// Every command-line prompt declares an input kind:
//   * `.token` — Space submits exactly like Enter (default). The buffer can
//     never hold a space, so `"UCS Z 45"` can never be typed as one line.
//   * `.line` — Space is literal; only Enter submits. Reserved for values
//     that may legally contain blanks: layer/block names, paths, text
//     strings, and `getstring T` input (AutoCAD parity).
//
// One-shot commands that need arguments no longer parse a same-line tail.
// Bare `CMD` opens a pending prompted session (phases below); each submit
// contributes one phase. Multi-token programmatic input
// (`executeCommand("UCS Z 45")`, pasted text, ribbon macros) replays through
// the same single-submit path token by token, so old spellings keep working
// without any `hasPrefix("CMD ")` fast path on the interactive path.
//
// Pending completion reconstructs a full line and runs it through the
// existing `executeFullLine` dispatch, so all validation and side effects
// stay in one place. Bare-submit (empty) at a prompt runs the command's
// former bare behaviour via `_inPendingCompletion`.
// =========================================================================

/// Input kind for the command-line prompt.
public enum CommandPromptInputKind: Sendable {
    /// Space submits exactly like Enter; the buffer never holds a space.
    case token
    /// Space is literal; only Enter submits (names, paths, text).
    case line
}

/// One phase of a pending prompted session.
public struct PendingPromptPhase: Sendable {
    /// Prompt text shown when the phase opens.
    public var prompt: String
    /// Whether Space submits (`.token`) or is literal (`.line`).
    public var kind: CommandPromptInputKind
    /// When true, an empty submit finishes the session with the args
    /// collected so far (accepting the `<default>`).
    public var emptyFinishes: Bool

    public init(
        prompt: String,
        kind: CommandPromptInputKind,
        emptyFinishes: Bool = false
    ) {
        self.prompt = prompt
        self.kind = kind
        self.emptyFinishes = emptyFinishes
    }
}

extension CADCommandProcessor {

    // MARK: - Session state primitives

    /// Opens a pending prompted session for a bare command. The phase table
    /// comes from `pendingPhases(for:engine:)`; unknown commands run their
    /// legacy bare behaviour immediately instead of stranding the user.
    public func startPendingPrompt(
        command: String,
        engine: PhrostEngine?
    ) {
        guard let phases = pendingPhases(for: command, engine: engine),
              let first = phases.first
        else {
            _inPendingCompletion = true
            defer { _inPendingCompletion = false }
            executeFullLine(command)
            return
        }
        pendingPromptCommand = command
        pendingPromptCollected = []
        pendingPromptPhaseIndex = 0
        showPendingPhase(prompt: first.prompt, kind: first.kind)
    }

    /// Shows one pending phase (prompt text + input kind, buffer cleared).
    public func showPendingPhase(prompt: String, kind: CommandPromptInputKind) {
        commandPrompt = prompt
        commandBuffer = ""
        commandSelectionIndex = 0
        promptInputKind = kind
        commandLineActive = true
        _lastMatchInput = ""
        _cachedMatches = []
        print("[CAD] \(prompt)")
    }

    /// Cancels any pending session and resets the prompt to a fresh token.
    public func finishPendingPrompt() {
        pendingPromptCommand = nil
        pendingPromptCollected = []
        pendingPromptPhaseIndex = 0
        promptInputKind = .token
    }

    /// Routes one submitted line to the open pending session.
    /// Returns true when a session consumed the submit.
    @discardableResult
    public func handlePendingSubmit(
        _ text: String,
        engine: PhrostEngine?
    ) -> Bool {
        guard let command = pendingPromptCommand,
              let phases = pendingPhases(for: command, engine: engine),
              !phases.isEmpty
        else { return false }
        // LAYMRG collects a variable-length source list before its target.
        if command == "LAYMRG" {
            handleLayMrgSubmit(text, phases: phases, engine: engine)
            return true
        }
        // LAYERSORT validates the key up front: direction words and invalid
        // keys finish immediately (one-line parity), real keys ask direction.
        if command == "LAYERSORT" {
            handleLaySortSubmit(text, phases: phases, engine: engine)
            return true
        }
        let index = min(pendingPromptPhaseIndex, phases.count - 1)
        let phase = phases[index]
        let arg: String
        if phase.kind == .line {
            arg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            arg = text.split(
                whereSeparator: { $0.isWhitespace }
            ).first.map(String.init) ?? ""
        }
        if arg.isEmpty {
            if phase.emptyFinishes {
                completePendingPrompt(engine: engine)
            } else {
                print("[CAD] A value is required here; press Esc to cancel.")
                showPendingPhase(prompt: phase.prompt, kind: phase.kind)
            }
            return true
        }
        pendingPromptCollected.append(arg)
        if index + 1 < phases.count {
            pendingPromptPhaseIndex = index + 1
            let next = phases[index + 1]
            showPendingPhase(prompt: next.prompt, kind: next.kind)
        } else {
            completePendingPrompt(engine: engine)
        }
        return true
    }

    /// Runs the pending completion: reconstructs a full line from the
    /// collected args and dispatches it through `executeFullLine` under
    /// `_inPendingCompletion`, so bare-form cases run their legacy behaviour
    /// instead of re-opening the prompt.
    public func completePendingPrompt(engine: PhrostEngine?) {
        guard let command = pendingPromptCommand else { return }
        let args = pendingPromptCollected
        if command == "GRIDORIGIN" {
            completeGridOrigin(args: args, engine: engine)
            return
        }
        if command == "LAYMRG" {
            completeLayMrg(args: args, engine: engine)
            return
        }
        let quote = Self.pendingArgsNeedQuoting(command)
        let tail = args.map { quote ? Self.quotePendingArg($0) : $0 }
            .joined(separator: " ")
        let line = tail.isEmpty ? command : "\(command) \(tail)"
        _inPendingCompletion = true
        defer { _inPendingCompletion = false }
        executeFullLine(line)
    }

    /// Quote-aware commands (sheet-set flows, file paths) need quoting so a
    /// collected arg with blanks survives the full-line split. Naive-split
    /// commands take args raw (single tokens, or whole-line tails they
    /// rejoin themselves).
    static func pendingArgsNeedQuoting(_ command: String) -> Bool {
        switch command {
        case "NEWSHEETSET", "OPENSHEETSET", "-PUBLISHSET", "-TRANSMITSET",
            "+PUBLISH", "-EXPORTPDF":
            return true
        default:
            return false
        }
    }

    /// Quotes one collected arg when it contains whitespace.
    public static func quotePendingArg(_ arg: String) -> String {
        if arg.contains(where: { $0.isWhitespace }) {
            return "\"\(arg)\""
        }
        return arg
    }

    // MARK: - LAYMRG (variable-length source list)

    private func handleLayMrgSubmit(
        _ text: String,
        phases: [PendingPromptPhase],
        engine: PhrostEngine?
    ) {
        let arg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingPromptPhaseIndex == 0 {
            if arg.isEmpty {
                if pendingPromptCollected.isEmpty {
                    print("[CAD] Enter at least one source layer; press Esc to cancel.")
                    showPendingPhase(prompt: phases[0].prompt, kind: phases[0].kind)
                } else {
                    pendingPromptPhaseIndex = 1
                    showPendingPhase(prompt: phases[1].prompt, kind: phases[1].kind)
                }
                return
            }
            pendingPromptCollected.append(arg)
            print("[CAD] Source \(pendingPromptCollected.count): '\(arg)'. Blank Enter when done.")
            showPendingPhase(prompt: phases[0].prompt, kind: phases[0].kind)
            return
        }
        if arg.isEmpty {
            print("[CAD] Enter the target layer; press Esc to cancel.")
            showPendingPhase(prompt: phases[1].prompt, kind: phases[1].kind)
            return
        }
        pendingPromptCollected.append(arg)
        completePendingPrompt(engine: engine)
    }

    private func completeLayMrg(args: [String], engine: PhrostEngine?) {
        guard args.count >= 2 else {
            print("[CAD] Usage: LAYMRG <source,...> <target>")
            clearCommand()
            return
        }
        guard let engine else {
            print("[CAD] LAYMRG needs an open drawing.")
            clearCommand()
            return
        }
        let target = args.last!
        let sources = Array(args.dropLast())
        switch LayerTransactionService().mergeLayers(
            in: engine.document, from: sources, into: target) {
        case .success(let outcome):
            print("[CAD] Merged \(outcome.deleted) layer(s) into '\(outcome.target.name)'; \(outcome.moved) entit\(outcome.moved == 1 ? "y" : "ies") moved.")
        case .failure(let error):
            print("[CAD] \(error.description)")
        }
        clearCommand()
    }

    // MARK: - Phase table

    /// Prompt phases per canonical pending command. Single-phase commands
    /// finish through the reconstructed full line; multi-phase commands
    /// collect verb + operands stepwise. `nil` means "no pending flow".
    public func pendingPhases(
        for command: String,
        engine: PhrostEngine?
    ) -> [PendingPromptPhase]? {
        switch command {
        case "UNDO":
            return [PendingPromptPhase(
                prompt: "Enter number of steps to undo <1>:", kind: .token,
                emptyFinishes: true)]
        case "REDO":
            return [PendingPromptPhase(
                prompt: "Enter number of steps to redo <1>:", kind: .token,
                emptyFinishes: true)]
        case "RIBBONMODE":
            let current = engine?.ui.ribbonMode.rawValue ?? "full"
            return [PendingPromptPhase(
                prompt: "Enter ribbon mode [Menu/Labels/Full] <\(current)>:",
                kind: .token, emptyFinishes: true)]
        case "VPRESIZE":
            return [PendingPromptPhase(
                prompt: "Enter pane resize percent (+N/-N):", kind: .token,
                emptyFinishes: true)]
        case "VPORTS":
            return [PendingPromptPhase(
                prompt: "Enter VPORTS option [2V/2H/Single/Join/Toggle/?]:",
                kind: .token, emptyFinishes: true)]
        case "DXFVERSION":
            return [PendingPromptPhase(
                prompt: "Enter DXF version [2018|2013|2010|2007|2004|2000|R14|R13|R12|R10]:",
                kind: .token, emptyFinishes: true)]
        case "-EXPORTPDF":
            return [PendingPromptPhase(
                prompt: "Enter PDF export path (empty = drawing folder default):",
                kind: .line, emptyFinishes: true)]
        case "LANGUAGE":
            let current = engine?.uiFontLanguageProfile.rawValue ?? ""
            return [PendingPromptPhase(
                prompt: "Enter UI font language profile <\(current)>:",
                kind: .token, emptyFinishes: true)]
        case "LAYERSORT":
            return [
                PendingPromptPhase(
                    prompt: "Enter layer sort key [Name|On|Color|Linetype|Lineweight|Opacity|Plot|Used] (empty = show current):",
                    kind: .token, emptyFinishes: true),
                PendingPromptPhase(
                    prompt: "Enter sort direction [Asc|Desc|Reverse] (empty = keep):",
                    kind: .token, emptyFinishes: true),
            ]
        case "-LAYER":
            return [
                PendingPromptPhase(
                    prompt: "Enter -LAYER option [?/Make/Set/New/Rename/Delete/On/Off/Color/Ltype/LWeight/Transparency/Plot/NoPlot/Description/Reconcile/Lock/Unlock/Freeze/Thaw/VPFreeze/VPThaw/State]:",
                    kind: .token, emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter option arguments (empty = none):",
                    kind: .line, emptyFinishes: true),
            ]
        case "LAYERSTATE":
            return [
                PendingPromptPhase(
                    prompt: "Enter LAYERSTATE option [Save/Restore/Delete/Rename/List/Export/Import]:",
                    kind: .token, emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter option arguments (empty = none):",
                    kind: .line, emptyFinishes: true),
            ]
        case "-DIMSTYLE":
            return [
                PendingPromptPhase(
                    prompt: "Enter -DIMSTYLE option [Restore/Save/Apply]:",
                    kind: .token, emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter style name (empty = none):",
                    kind: .line, emptyFinishes: true),
            ]
        case "VPLAYER":
            return [
                PendingPromptPhase(
                    prompt: "Enter VPLAYER option [Freeze/Thaw/Reset/List]:",
                    kind: .token, emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter option arguments (empty = list):",
                    kind: .line, emptyFinishes: true),
            ]
        case "MVIEW":
            return [
                PendingPromptPhase(
                    prompt: "Enter MVIEW option [?/ON/OFF/S/T/Select/Freeze/Thaw or two paper corners]:",
                    kind: .token, emptyFinishes: true),
                PendingPromptPhase(
                    prompt: "Enter option arguments (empty = none):",
                    kind: .line, emptyFinishes: true),
            ]
        case "SCALELISTEDIT":
            return [
                PendingPromptPhase(
                    prompt: "Enter SCALELISTEDIT option [List/Add/Delete/Reset] <List>:",
                    kind: .token, emptyFinishes: true),
                PendingPromptPhase(
                    prompt: "Enter option arguments (empty = none):",
                    kind: .line, emptyFinishes: true),
            ]
        case "-HATCH":
            return [
                PendingPromptPhase(
                    prompt: "Enter hatch pattern (empty = pick on screen):",
                    kind: .token, emptyFinishes: true),
                PendingPromptPhase(
                    prompt: "Enter hatch scale (empty = current):",
                    kind: .token, emptyFinishes: true),
                PendingPromptPhase(
                    prompt: "Enter hatch angle (empty = current):",
                    kind: .token, emptyFinishes: true),
            ]
        case "LAYFRZ", "LAYTHW", "LAYLCK", "LAYULK":
            return [PendingPromptPhase(
                prompt: "Enter layer name:", kind: .line,
                emptyFinishes: false)]
        case "LAYDEL":
            return [PendingPromptPhase(
                prompt: "Enter layer name to delete:", kind: .line,
                emptyFinishes: false)]
        case "LAYWALK":
            return [PendingPromptPhase(
                prompt: "Enter layer name to walk (empty = list all):",
                kind: .line, emptyFinishes: true)]
        case "COPYTOLAYER":
            return [PendingPromptPhase(
                prompt: "Enter target layer name:", kind: .line,
                emptyFinishes: false)]
        case "VIEW":
            return [PendingPromptPhase(
                prompt: "Enter view name or index (empty = cycle views):",
                kind: .token, emptyFinishes: true)]
        case "SNAPANG":
            return [PendingPromptPhase(
                prompt: "Enter snap angle in degrees:", kind: .token,
                emptyFinishes: true)]
        case "POLARANG":
            return [PendingPromptPhase(
                prompt: "Enter polar angle increment in degrees:",
                kind: .token, emptyFinishes: true)]
        case "SPLINETESS":
            return [PendingPromptPhase(
                prompt: "Enter spline tessellation divisor (>= 10):",
                kind: .token, emptyFinishes: true)]
        case "SET-BACKGROUND":
            return [PendingPromptPhase(
                prompt: "Enter background color <ACI index|hex RRGGBB>:",
                kind: .token, emptyFinishes: true)]
        case "AUTOCONTRAST":
            return [PendingPromptPhase(
                prompt: "Enter TrueColor auto-contrast [ON/OFF] (empty = toggle):",
                kind: .token, emptyFinishes: true)]
        case "SIMPLIFY":
            return [PendingPromptPhase(
                prompt: "Enter complex-block simplification [ON/OFF] (empty = toggle):",
                kind: .token, emptyFinishes: true)]
        case "SIMPLIFYPOLY":
            return [PendingPromptPhase(
                prompt: "Enter dense-polyline simplification [ON/OFF] (empty = toggle):",
                kind: .token, emptyFinishes: true)]
        case "LASSO":
            return [PendingPromptPhase(
                prompt: "Enter press-and-drag lasso [ON/OFF] (empty = toggle):",
                kind: .token, emptyFinishes: true)]
        case "SETUISCALE":
            return [PendingPromptPhase(
                prompt: "Enter UI scale [0.5-4.0|AUTO] (empty = show current):",
                kind: .token, emptyFinishes: true)]
        case "UNITS":
            return [PendingPromptPhase(
                prompt: "Enter drawing unit [mm|cm|m|in|ft|yd] (empty = show current):",
                kind: .token, emptyFinishes: true)]
        case "SETTINGSGRIPOBJECTMAX":
            return [PendingPromptPhase(
                prompt: "Enter grip object max (positive integer):",
                kind: .token, emptyFinishes: true)]
        case "SETTINGSGRIPMAX":
            return [PendingPromptPhase(
                prompt: "Enter grip max (positive integer):",
                kind: .token, emptyFinishes: true)]
        case "SELECTIONPREVIEWLIMIT":
            return [PendingPromptPhase(
                prompt: "Enter selection preview limit (positive integer):",
                kind: .token, emptyFinishes: true)]
        case "NEWSHEETSET":
            return [
                PendingPromptPhase(
                    prompt: "Enter new sheet set name:", kind: .line,
                    emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter .dst path (empty = in memory only):",
                    kind: .line, emptyFinishes: true),
            ]
        case "OPENSHEETSET":
            return [PendingPromptPhase(
                prompt: "Enter sheet set .dst path (empty = file picker):",
                kind: .line, emptyFinishes: true)]
        case "-PUBLISHSET":
            return [
                PendingPromptPhase(
                    prompt: "Enter sheet set .dst path:", kind: .line,
                    emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter page setup override (empty = none):",
                    kind: .line, emptyFinishes: true),
                PendingPromptPhase(
                    prompt: "Enter override file (empty = none):",
                    kind: .line, emptyFinishes: true),
            ]
        case "-TRANSMITSET":
            return [
                PendingPromptPhase(
                    prompt: "Enter sheet set .dst path:", kind: .line,
                    emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter target folder:", kind: .line,
                    emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter scope (empty = all):", kind: .line,
                    emptyFinishes: true),
            ]
        case "+PUBLISH":
            return [PendingPromptPhase(
                prompt: "Enter sheet list .dsd path (empty = none):",
                kind: .line, emptyFinishes: true)]
        case "GRIDSPACING":
            return [PendingPromptPhase(
                prompt: "Enter base grid spacing in world units:",
                kind: .token, emptyFinishes: true)]
        case "GRIDORIGIN":
            return [
                PendingPromptPhase(
                    prompt: "Enter grid origin X:", kind: .token,
                    emptyFinishes: false),
                PendingPromptPhase(
                    prompt: "Enter grid origin Y:", kind: .token,
                    emptyFinishes: false),
            ]
        case "LAYMRG":
            return [
                PendingPromptPhase(
                    prompt: "Enter source layer (blank Enter when done):",
                    kind: .line, emptyFinishes: true),
                PendingPromptPhase(
                    prompt: "Enter target layer:", kind: .line,
                    emptyFinishes: false),
            ]
        default:
            return nil
        }
    }

    // MARK: - Feature option submit resolution

    /// Text actually submitted to the active feature command: an empty
    /// buffer with a highlighted context option submits that option's value
    /// (arrows + Enter picks it without typing); typed text always wins so
    /// numbers and custom strings are never clobbered by the highlight.
    public static func featureSubmitText(
        buffer: String,
        options: [FeatureCommandTextOption],
        selectedIndex: Int
    ) -> String {
        if buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           selectedIndex >= 0, selectedIndex < options.count {
            return options[selectedIndex].value
        }
        return buffer
    }

    // MARK: - LAYERSORT (validate early, finish like the one-line form)

    private func handleLaySortSubmit(
        _ text: String,
        phases: [PendingPromptPhase],
        engine: PhrostEngine?
    ) {
        let arg = text.split(
            whereSeparator: { $0.isWhitespace }
        ).first.map(String.init) ?? ""
        if pendingPromptPhaseIndex == 0 {
            if arg.isEmpty {
                // Bare LAYERSORT: report current, like the legacy bare form.
                let current = LayerSortSettings.load()
                print("[CAD] Current layer sort: \(current.key.displayName) \(current.ascending ? "ASC" : "DESC")")
                print("[CAD] Usage: LAYERSORT <key> [ASC|DESC] (example: LAYERSORT COLOR DESC)")
                clearCommand()
                return
            }
            if LayerSortSettings.key(forCommandToken: arg) != nil {
                pendingPromptCollected.append(arg.uppercased())
                pendingPromptPhaseIndex = 1
                showPendingPhase(prompt: phases[1].prompt, kind: phases[1].kind)
                return
            }
            // A lone direction word applies immediately; anything else is a
            // usage error. Both finish, matching the one-line form.
            applyLaySortTokens([arg], engine: engine)
            return
        }
        if arg.isEmpty {
            applyLaySortTokens(pendingPromptCollected, engine: engine)
            return
        }
        applyLaySortTokens(pendingPromptCollected + [arg.uppercased()], engine: engine)
    }

    private func applyLaySortTokens(_ tokens: [String], engine: PhrostEngine?) {
        let current = LayerSortSettings.load()
        guard let updated = current.applyingCommandTokens(tokens) else {
            print("[CAD] Invalid sort option '\(tokens.last ?? "")'. Usage: LAYERSORT <key> [ASC|DESC] (example: LAYERSORT COLOR DESC)")
            clearCommand()
            return
        }
        updated.save()
        var msg = "[CAD] Layers sorted by \(updated.key.displayName) \(updated.ascending ? "ASC" : "DESC")"
        if tokens.count == 1,
           let key = LayerSortSettings.key(forCommandToken: tokens[0]),
           key == current.key {
            msg += " (toggled)"
        }
        print(msg)
        engine?.ui.layersPanelVisible = true
        clearCommand()
    }

    // MARK: - GRIDORIGIN (two plain numbers, never one spaced line)

    private func completeGridOrigin(args: [String], engine: PhrostEngine?) {
        guard args.count == 2,
              let x = Double(args[0]),
              let y = Double(args[1])
        else {
            print("[CAD] GRIDORIGIN requires two numbers (e.g. GRIDORIGIN, then 100, then 50)")
            clearCommand()
            return
        }
        guard let engine else {
            print("[CAD] GRIDORIGIN needs an open drawing.")
            clearCommand()
            return
        }
        engine.snap.gridOriginX = x
        engine.snap.gridOriginY = y
        print("[CAD] Grid origin set to (\(x), \(y))")
        clearCommand()
    }
}

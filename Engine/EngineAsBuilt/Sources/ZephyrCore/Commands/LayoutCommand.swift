import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - TabManager Layout Naming Extensions
// =========================================================================

public extension TabManager {
    /// Reserved characters forbidden in AutoCAD LT layout names.
    static let reservedLayoutCharacters = CharacterSet(charactersIn: "<>/\\\":;?*|=")

    /// Next sequential default layout name (`Layout1`, `Layout2`, …) not yet
    /// used in the active tab (AutoCAD LT `<LayoutN>` prompt default).
    func nextAvailableLayoutName() -> String {
        var n = 1
        while layoutNameTaken("Layout\(n)") { n += 1 }
        return "Layout\(n)"
    }

    /// Next default copy destination name (`<source> (2)`, `<source> (3)`, …)
    /// matching AutoCAD LT's `LAYOUT Copy` prompt default.
    func nextCopyLayoutName(from sourceName: String) -> String {
        let base = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nextAvailableLayoutName() }
        var n = 2
        while layoutNameTaken("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }
}

// =========================================================================
// MARK: - LayoutCommand (LAYOUT / LO / SHEET / -LAYOUT)
// =========================================================================

/// AutoCAD LT-compatible interactive and inline `LAYOUT` command.
///
/// Supports both multi-step interactive command-line prompts:
///   `LAYOUT` -> `Enter` -> `[Copy/Delete/New/Template/Rename/SAveas/Set/?] <set>:`
///   -> `N` -> `Enter` -> `Enter new Layout name <Layout1>:` -> `<name>` -> `Enter`
/// and single-line inline arguments (`LAYOUT NEW Sheet2`, `LO N Sheet2`, etc.).
@MainActor
public final class LayoutCommand: FeatureCommand {

    public enum Phase: Equatable {
        case option
        case newName(defaultName: String)
        case setName(defaultName: String)
        case deleteName(defaultName: String)
        case copySource(defaultSource: String)
        case copyDest(sourceName: String, defaultDest: String)
        case renameSource(defaultSource: String)
        case renameDest(oldName: String)
    }

    public static let optionPromptText =
        "Enter layout option [Copy/Delete/New/Template/Rename/SAveas/Set/?] <set>:"

    /// Alias kept for the command-parity tests (`optionPrompt`).
    public static var optionPrompt: String { optionPromptText }

    public private(set) var phase: Phase = .option
    private var cachedSheetNames: [String] = []

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    // MARK: - FeatureCommand Lifecycle

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        start(tabManager: engine.tabManager, processor: processor)
    }

    /// Headless entry point for unit testing without an SDL `PhrostEngine`.
    public func start(tabManager: TabManager, processor: CADCommandProcessor) {
        phase = .option
        cachedSheetNames = tabManager.paperLayoutNames
        openPrompt(Self.optionPromptText, processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        cancel(processor: processor)
    }

    public func cancel(processor: CADCommandProcessor) {
        phase = .option
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
    }

    // MARK: - Context-Sensitive Command-Line Options

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        switch phase {
        case .option:
            let options: [FeatureCommandTextOption] = [
                .init(
                    value: "C", title: "Copy", aliases: ["COPY"],
                    description: "Copy an existing layout"),
                .init(
                    value: "D", title: "Delete", aliases: ["DELETE", "DEL"],
                    description: "Delete a layout"),
                .init(
                    value: "N", title: "New", aliases: ["NEW"],
                    description: "Create a new layout tab"),
                .init(
                    value: "T", title: "Template", aliases: ["TEMPLATE"],
                    description: "Import a layout from a template"),
                .init(
                    value: "R", title: "Rename", aliases: ["RENAME", "REN"],
                    description: "Rename an existing layout"),
                .init(
                    value: "SA", title: "SAveas", aliases: ["SAVEAS"],
                    description: "Save a layout to a template"),
                .init(
                    value: "S", title: "Set", aliases: ["SET"],
                    description: "Make a layout current (default)"),
                .init(
                    value: "?", title: "?", aliases: ["LIST", "L"],
                    description: "List all layouts in the drawing"),
            ]
            return options.filter { $0.matches(input) }

        case .setName, .deleteName, .copySource, .renameSource:
            return cachedSheetNames.map { name in
                FeatureCommandTextOption(
                    value: name,
                    title: name,
                    aliases: [],
                    description: "Existing layout")
            }.filter { $0.matches(input) }

        case .newName, .copyDest, .renameDest:
            // Do not offer autocomplete options when typing a brand-new layout name.
            return []
        }
    }

    // MARK: - Command Text Handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        handleCommandText(
            text,
            tabManager: engine.tabManager,
            processor: processor,
            onZoomExtents: { engine.zoomExtents() })
    }

    /// Headless command-text handler for unit tests and live engine dispatch.
    @discardableResult
    public func handleCommandText(
        _ text: String,
        tabManager: TabManager,
        processor: CADCommandProcessor,
        onZoomExtents: () -> Void = {}
    ) -> CommandResult {
        cachedSheetNames = tabManager.paperLayoutNames
        let raw = stripCommandPrefixIfNeeded(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            inOptionPhase: phase == .option)

        switch phase {
        case .option:
            return handleOptionPhase(
                raw: raw,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case .newName(let defaultName):
            let target = raw.isEmpty ? defaultName : raw
            return performNewLayout(
                named: target,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case .setName(let defaultName):
            let target = raw.isEmpty ? defaultName : raw
            return performSetLayout(
                named: target,
                defaultName: defaultName,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case .deleteName(let defaultName):
            let target = raw.isEmpty ? defaultName : raw
            return performDeleteLayout(
                named: target,
                defaultName: defaultName,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case .copySource(let defaultSource):
            let src = raw.isEmpty ? defaultSource : raw
            return advanceCopySource(
                sourceName: src,
                defaultSource: defaultSource,
                tabManager: tabManager,
                processor: processor)

        case .copyDest(let sourceName, let defaultDest):
            let dst = raw.isEmpty ? defaultDest : raw
            return performCopyLayout(
                from: sourceName,
                to: dst,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case .renameSource(let defaultSource):
            let old = raw.isEmpty ? defaultSource : raw
            return advanceRenameSource(
                oldName: old,
                defaultSource: defaultSource,
                tabManager: tabManager,
                processor: processor)

        case .renameDest(let oldName):
            return performRenameLayout(
                from: oldName,
                to: raw,
                tabManager: tabManager,
                processor: processor)
        }
    }

    // MARK: - Option Phase Dispatch

    private func handleOptionPhase(
        raw: String,
        tabManager: TabManager,
        processor: CADCommandProcessor,
        onZoomExtents: () -> Void
    ) -> CommandResult {
        // Bare Enter at the option prompt selects the <set> default.
        if raw.isEmpty {
            let def = defaultSheetName(in: tabManager)
            phase = .setName(defaultName: def)
            openPrompt("Enter layout to make current <\(def)>:", processor: processor)
            return .consumed
        }

        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let keyword = parts.first?.uppercased() else {
            openPrompt(Self.optionPromptText, processor: processor)
            return .consumed
        }
        let inline = parts.count > 1
            ? parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            : ""

        switch keyword {
        case "?", "LIST", "L", "HELP":
            printLayoutList(tabManager: tabManager)
            let sheets = tabManager.paperLayoutNames
            let summary = sheets.isEmpty ? "(none)" : sheets.joined(separator: ", ")
            openPrompt(
                "Layouts: \(summary) — \(Self.optionPromptText)",
                processor: processor)
            return .consumed

        case "N", "NEW":
            if inline.isEmpty {
                let def = tabManager.nextAvailableLayoutName()
                phase = .newName(defaultName: def)
                openPrompt("Enter new Layout name <\(def)>:", processor: processor)
                return .consumed
            }
            return performNewLayout(
                named: inline,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case "S", "SET":
            let def = defaultSheetName(in: tabManager)
            if inline.isEmpty {
                phase = .setName(defaultName: def)
                openPrompt("Enter layout to make current <\(def)>:", processor: processor)
                return .consumed
            }
            return performSetLayout(
                named: inline,
                defaultName: def,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case "D", "DEL", "DELETE":
            let def = defaultSheetName(in: tabManager)
            if inline.isEmpty {
                phase = .deleteName(defaultName: def)
                openPrompt("Enter name of layout to delete <\(def)>:", processor: processor)
                return .consumed
            }
            return performDeleteLayout(
                named: inline,
                defaultName: def,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case "C", "COPY":
            let defSrc = defaultSheetName(in: tabManager)
            let inlineTokens = inline.split(whereSeparator: \.isWhitespace).map(String.init)
            if inlineTokens.isEmpty {
                phase = .copySource(defaultSource: defSrc)
                openPrompt("Enter layout to copy <\(defSrc)>:", processor: processor)
                return .consumed
            } else if inlineTokens.count == 1 {
                return advanceCopySource(
                    sourceName: inlineTokens[0],
                    defaultSource: defSrc,
                    tabManager: tabManager,
                    processor: processor)
            } else {
                let src = inlineTokens[0]
                let dst = inlineTokens.dropFirst().joined(separator: " ")
                return performCopyLayout(
                    from: src,
                    to: dst,
                    tabManager: tabManager,
                    processor: processor,
                    onZoomExtents: onZoomExtents)
            }

        case "R", "REN", "RENAME":
            let defSrc = defaultSheetName(in: tabManager)
            let inlineTokens = inline.split(whereSeparator: \.isWhitespace).map(String.init)
            if inlineTokens.isEmpty {
                phase = .renameSource(defaultSource: defSrc)
                openPrompt("Enter layout to rename <\(defSrc)>:", processor: processor)
                return .consumed
            } else if inlineTokens.count == 1 {
                return advanceRenameSource(
                    oldName: inlineTokens[0],
                    defaultSource: defSrc,
                    tabManager: tabManager,
                    processor: processor)
            } else {
                let old = inlineTokens[0]
                let newName = inlineTokens.dropFirst().joined(separator: " ")
                return performRenameLayout(
                    from: old,
                    to: newName,
                    tabManager: tabManager,
                    processor: processor)
            }

        case "SA", "SAVEAS":
            // SAveas duplicates the current layout under a new name (the same
            // result COPY offers; exporting to a .dwt template file is future work).
            let saveSrc = defaultSheetName(in: tabManager)
            if saveSrc.caseInsensitiveCompare("Model") == .orderedSame {
                phase = .option
                print("[CAD] Model tab cannot be saved as a layout copy.")
                openPrompt(Self.optionPromptText, processor: processor)
                return .consumed
            }
            guard let canonicalSaveSrc = tabManager.paperLayoutNames.first(where: {
                $0.caseInsensitiveCompare(saveSrc) == .orderedSame
            }) else {
                phase = .option
                print("[CAD] No current layout to save.")
                openPrompt(Self.optionPromptText, processor: processor)
                return .consumed
            }
            if inline.isEmpty {
                let defDst = tabManager.nextCopyLayoutName(from: canonicalSaveSrc)
                phase = .copyDest(sourceName: canonicalSaveSrc, defaultDest: defDst)
                openPrompt("Enter new layout name <\(defDst)>:", processor: processor)
                return .consumed
            }
            return performCopyLayout(
                from: canonicalSaveSrc,
                to: inline,
                tabManager: tabManager,
                processor: processor,
                onZoomExtents: onZoomExtents)

        case "T", "TEMPLATE":
            print("[CAD] LAYOUT Template is not supported yet (use COPY).")
            openPrompt(
                "LAYOUT Template is not supported yet (use COPY). \(Self.optionPromptText)",
                processor: processor)
            return .consumed

        default:
            // Direct layout name or 1-based sheet index (e.g. `LAYOUT Layout1` or `LAYOUT 1`).
            if trySwitchLayout(named: raw, tabManager: tabManager, onZoomExtents: onZoomExtents) {
                processor.commandLineActive = false
                return .finished
            }
            openPrompt(
                "Invalid option keyword. \(Self.optionPromptText)",
                processor: processor)
            return .consumed
        }
    }

    // MARK: - Sub-Operation Actions

    private func performNewLayout(
        named candidate: String,
        tabManager: TabManager,
        processor: CADCommandProcessor,
        onZoomExtents: () -> Void
    ) -> CommandResult {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextDef = tabManager.nextAvailableLayoutName()
        guard !trimmed.isEmpty else {
            phase = .newName(defaultName: nextDef)
            openPrompt("Layout name cannot be blank. Enter new Layout name <\(nextDef)>:", processor: processor)
            return .consumed
        }
        if trimmed.rangeOfCharacter(from: TabManager.reservedLayoutCharacters) != nil {
            phase = .newName(defaultName: nextDef)
            openPrompt(
                "Layout name cannot contain <>/\\\":;?*|= characters. Enter new Layout name <\(nextDef)>:",
                processor: processor)
            return .consumed
        }
        if tabManager.layoutNameTaken(trimmed) {
            phase = .newName(defaultName: nextDef)
            openPrompt(
                "Layout \"\(trimmed)\" already exists. Enter new Layout name <\(nextDef)>:",
                processor: processor)
            return .consumed
        }
        if tabManager.createLayout(named: trimmed) {
            cachedSheetNames = tabManager.paperLayoutNames
            onZoomExtents()
            let createdName = tabManager.activeViewName ?? trimmed
            print("[CAD] Layout '\(createdName)' created.")
            processor.commandLineActive = false
            return .finished
        }
        phase = .newName(defaultName: nextDef)
        openPrompt("Cannot create layout \"\(trimmed)\". Enter new Layout name <\(nextDef)>:", processor: processor)
        return .consumed
    }

    private func performSetLayout(
        named candidate: String,
        defaultName: String,
        tabManager: TabManager,
        processor: CADCommandProcessor,
        onZoomExtents: () -> Void
    ) -> CommandResult {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? defaultName : trimmed
        if trySwitchLayout(named: target, tabManager: tabManager, onZoomExtents: onZoomExtents) {
            processor.commandLineActive = false
            return .finished
        }
        phase = .setName(defaultName: defaultName)
        openPrompt(
            "Layout \"\(target)\" not found. Enter layout to make current <\(defaultName)>:",
            processor: processor)
        return .consumed
    }

    private func performDeleteLayout(
        named candidate: String,
        defaultName: String,
        tabManager: TabManager,
        processor: CADCommandProcessor,
        onZoomExtents: () -> Void
    ) -> CommandResult {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? defaultName : trimmed
        if target.caseInsensitiveCompare("Model") == .orderedSame {
            phase = .deleteName(defaultName: defaultName)
            openPrompt(
                "Model tab cannot be deleted. Enter name of layout to delete <\(defaultName)>:",
                processor: processor)
            return .consumed
        }
        if tabManager.deleteLayout(named: target) {
            cachedSheetNames = tabManager.paperLayoutNames
            onZoomExtents()
            print("[CAD] Layout '\(target)' deleted.")
            processor.commandLineActive = false
            return .finished
        }
        let nextDef = defaultSheetName(in: tabManager)
        phase = .deleteName(defaultName: nextDef)
        openPrompt(
            "Layout \"\(target)\" not found or cannot be deleted. Enter name of layout to delete <\(nextDef)>:",
            processor: processor)
        return .consumed
    }

    private func advanceCopySource(
        sourceName: String,
        defaultSource: String,
        tabManager: TabManager,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let src = trimmed.isEmpty ? defaultSource : trimmed
        if src.caseInsensitiveCompare("Model") == .orderedSame {
            phase = .copySource(defaultSource: defaultSource)
            openPrompt(
                "Model tab cannot be copied. Enter layout to copy <\(defaultSource)>:",
                processor: processor)
            return .consumed
        }
        guard let canonicalSrc = tabManager.paperLayoutNames.first(where: {
            $0.caseInsensitiveCompare(src) == .orderedSame
        }) else {
            phase = .copySource(defaultSource: defaultSource)
            openPrompt(
                "Layout \"\(src)\" not found. Enter layout to copy <\(defaultSource)>:",
                processor: processor)
            return .consumed
        }
        let defDst = tabManager.nextCopyLayoutName(from: canonicalSrc)
        phase = .copyDest(sourceName: canonicalSrc, defaultDest: defDst)
        openPrompt("Enter layout name for copy <\(defDst)>:", processor: processor)
        return .consumed
    }

    private func performCopyLayout(
        from sourceName: String,
        to destCandidate: String,
        tabManager: TabManager,
        processor: CADCommandProcessor,
        onZoomExtents: () -> Void
    ) -> CommandResult {
        let defDst = tabManager.nextCopyLayoutName(from: sourceName)
        let trimmedDst = destCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = trimmedDst.isEmpty ? defDst : trimmedDst

        if dst.rangeOfCharacter(from: TabManager.reservedLayoutCharacters) != nil {
            phase = .copyDest(sourceName: sourceName, defaultDest: defDst)
            openPrompt(
                "Layout name cannot contain <>/\\\":;?*|= characters. Enter layout name for copy <\(defDst)>:",
                processor: processor)
            return .consumed
        }
        if tabManager.layoutNameTaken(dst) {
            phase = .copyDest(sourceName: sourceName, defaultDest: defDst)
            openPrompt(
                "Layout \"\(dst)\" already exists. Enter layout name for copy <\(defDst)>:",
                processor: processor)
            return .consumed
        }
        if tabManager.copyLayout(from: sourceName, to: dst) {
            cachedSheetNames = tabManager.paperLayoutNames
            onZoomExtents()
            print("[CAD] Layout '\(dst)' copied.")
            processor.commandLineActive = false
            return .finished
        }
        phase = .copyDest(sourceName: sourceName, defaultDest: defDst)
        openPrompt(
            "Cannot copy \"\(sourceName)\" to \"\(dst)\". Enter layout name for copy <\(defDst)>:",
            processor: processor)
        return .consumed
    }

    private func advanceRenameSource(
        oldName: String,
        defaultSource: String,
        tabManager: TabManager,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let src = trimmed.isEmpty ? defaultSource : trimmed
        if src.caseInsensitiveCompare("Model") == .orderedSame {
            phase = .renameSource(defaultSource: defaultSource)
            openPrompt(
                "Model tab cannot be renamed. Enter layout to rename <\(defaultSource)>:",
                processor: processor)
            return .consumed
        }
        guard let canonicalOld = tabManager.paperLayoutNames.first(where: {
            $0.caseInsensitiveCompare(src) == .orderedSame
        }) else {
            phase = .renameSource(defaultSource: defaultSource)
            openPrompt(
                "Layout \"\(src)\" not found. Enter layout to rename <\(defaultSource)>:",
                processor: processor)
            return .consumed
        }
        phase = .renameDest(oldName: canonicalOld)
        openPrompt("Enter new layout name:", processor: processor)
        return .consumed
    }

    private func performRenameLayout(
        from oldName: String,
        to newCandidate: String,
        tabManager: TabManager,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = newCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .renameDest(oldName: oldName)
            openPrompt("Layout name cannot be blank. Enter new layout name:", processor: processor)
            return .consumed
        }
        if trimmed.rangeOfCharacter(from: TabManager.reservedLayoutCharacters) != nil {
            phase = .renameDest(oldName: oldName)
            openPrompt(
                "Layout name cannot contain <>/\\\":;?*|= characters. Enter new layout name:",
                processor: processor)
            return .consumed
        }
        if tabManager.layoutNameTaken(trimmed) {
            phase = .renameDest(oldName: oldName)
            openPrompt(
                "Layout \"\(trimmed)\" already exists. Enter new layout name:",
                processor: processor)
            return .consumed
        }
        if tabManager.renameLayout(from: oldName, to: trimmed) {
            cachedSheetNames = tabManager.paperLayoutNames
            print("[CAD] Renamed to '\(trimmed)'.")
            processor.commandLineActive = false
            return .finished
        }
        phase = .renameDest(oldName: oldName)
        openPrompt(
            "Cannot rename \"\(oldName)\" to \"\(trimmed)\". Enter new layout name:",
            processor: processor)
        return .consumed
    }

    // MARK: - Keyboard & Pointer Events

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Keep the modal command-line prompt open if the user clicks the canvas.
        if !processor.commandLineActive {
            processor.commandLineActive = true
        }
        return .handled
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        // Fallback when the command line popup was dismissed while LAYOUT is active:
        // Enter accepts the current <default>, and printable keys reopen the input.
        if !processor.commandLineActive {
            if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
                return handleCommandText("", engine: engine, processor: processor)
            }
            if let ch = Self.scancodeToInitialChar(scancode) {
                processor.commandLineActive = true
                processor.commandBuffer = ch
                processor.commandSelectionIndex = 0
                return .handled
            }
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Internal Helpers

    private func openPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
        print("[CAD] \(prompt)")
    }

    private func defaultSheetName(in manager: TabManager) -> String {
        if manager.isPaperSpace, let active = manager.activeViewName, !active.isEmpty {
            return active
        }
        if let firstSheet = manager.paperLayoutNames.first {
            return firstSheet
        }
        return manager.activeViewName ?? "Model"
    }

    private func trySwitchLayout(
        named name: String,
        tabManager: TabManager,
        onZoomExtents: () -> Void
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let sheets = tabManager.availableViews.enumerated().filter { $0.element.kind == .sheet }
        if let n = Int(trimmed), n >= 1, n <= sheets.count {
            if tabManager.switchToView(at: sheets[n - 1].offset) {
                onZoomExtents()
                print("[CAD] Sheet: \(tabManager.activeViewName ?? trimmed)")
                return true
            }
        } else if tabManager.switchToView(named: trimmed) {
            onZoomExtents()
            print("[CAD] Sheet: \(tabManager.activeViewName ?? trimmed)")
            return true
        }
        return false
    }

    private func printLayoutList(tabManager: TabManager) {
        let views = tabManager.availableViews
        guard !views.isEmpty else {
            print("[CAD] No views in this drawing.")
            return
        }
        let activeIdx = tabManager.activeTab?.activeViewIndex ?? -1
        for (index, view) in views.enumerated() {
            let marker = index == activeIdx ? "*" : " "
            print("[CAD] \(marker)\(index + 1): \(view.name)\(view.kind == .model ? " (Model)" : "")")
        }
    }

    private func stripCommandPrefixIfNeeded(_ text: String, inOptionPhase: Bool) -> String {
        guard inOptionPhase else { return text }
        let up = text.uppercased()
        for prefix in ["LAYOUT", "-LAYOUT", "SHEET", "LO"] {
            if up == prefix {
                return ""
            }
            if up.hasPrefix(prefix + " ") {
                return String(text.dropFirst(prefix.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    private static func scancodeToInitialChar(_ scancode: SDL_Scancode) -> String? {
        if scancode.rawValue >= SDL_SCANCODE_A.rawValue
            && scancode.rawValue <= SDL_SCANCODE_Z.rawValue {
            let offset = UInt8(scancode.rawValue - SDL_SCANCODE_A.rawValue)
            return String(Character(UnicodeScalar(UInt8(ascii: "A") + offset)))
        }
        switch scancode {
        case SDL_SCANCODE_1, SDL_SCANCODE_KP_1: return "1"
        case SDL_SCANCODE_2, SDL_SCANCODE_KP_2: return "2"
        case SDL_SCANCODE_3, SDL_SCANCODE_KP_3: return "3"
        case SDL_SCANCODE_4, SDL_SCANCODE_KP_4: return "4"
        case SDL_SCANCODE_5, SDL_SCANCODE_KP_5: return "5"
        case SDL_SCANCODE_6, SDL_SCANCODE_KP_6: return "6"
        case SDL_SCANCODE_7, SDL_SCANCODE_KP_7: return "7"
        case SDL_SCANCODE_8, SDL_SCANCODE_KP_8: return "8"
        case SDL_SCANCODE_9, SDL_SCANCODE_KP_9: return "9"
        case SDL_SCANCODE_0, SDL_SCANCODE_KP_0: return "0"
        case SDL_SCANCODE_SLASH: return "?"
        default: return nil
        }
    }
}

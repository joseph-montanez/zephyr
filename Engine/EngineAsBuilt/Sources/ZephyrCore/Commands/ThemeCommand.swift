import CSDL3
import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - ThemeCommand
//
// Prompted THEME sub-command (Space == Enter rework).
//
// Bare `THEME` opens a sub-prompt instead of cycling:
//
//   Enter theme [Dark/Light/Latte/Frappe/Macchiato/Mocha/Candy/Next/?] <DARK>:
//
// Each Space/Enter submits exactly one token. `NEXT` cycles to the next
// preset, `?` lists presets and re-prompts, an exact name or unique prefix
// applies it, and bare Enter/Space accepts the `<current>` default (no
// change, reports the current theme). Ambiguous prefixes and unknown names
// re-prompt instead of clearing the command.
//
// `DARKMODE` / `LIGHTMODE` stay single-token commands and are untouched.
// =========================================================================

@MainActor
public final class ThemeCommand: FeatureCommand {

    public init() {}

    public var isSnappingEnabled: Bool { false }

    // MARK: - FeatureCommand conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        openPrompt(currentName: engine.ui.theme.name, processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.promptInputKind = .token
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Canvas clicks never choose a theme; use typed text or options.
        .handled
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Context-sensitive command-line options

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        var options = AppTheme.allPresets.map {
            FeatureCommandTextOption(
                value: $0.shortName,
                title: $0.displayName,
                aliases: [$0.id],
                description: $0.isDark ? "Dark theme" : "Light theme")
        }
        options.append(.init(
            value: "NEXT", title: "Next", aliases: [],
            description: "Cycle to the next theme"))
        return options.filter { $0.matches(input) }
    }

    public func activeOptionValues(engine: PhrostEngine) -> Set<String> {
        guard let preset = AppTheme.allPresets.first(where: { $0.id == engine.ui.theme.id }) else { return [] }
        return [preset.shortName]
    }

    // MARK: - Command text handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        handleCommandText(
            text,
            currentThemeName: engine.ui.theme.name,
            applyThemeNamed: { engine.ui.setTheme(named: $0) },
            appliedThemeName: { engine.ui.theme.name },
            cycleTheme: {
                engine.ui.cycleTheme()
                return engine.ui.theme.name
            },
            processor: processor)
    }

    /// Resolution outcome for one submitted token.
    public enum Resolution: Equatable {
        /// Bare submit: accept the `<current>` default.
        case useDefault
        /// List presets and re-prompt.
        case list
        /// Cycle to the next preset.
        case next
        /// Apply the preset with this short name.
        case named(String)
        /// Prefix matched several presets (their short names).
        case ambiguous([String])
        /// No preset matches.
        case unknown(String)
    }

    /// Maps raw prompt text to a resolution. Bare input accepts the default;
    /// otherwise an exact name wins, then a unique prefix over short names,
    /// ids, and display names (all normalized like `AppTheme.theme(named:)`).
    public static func resolve(_ text: String) -> Resolution {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .useDefault }
        let upper = trimmed.uppercased()
        if upper == "?" || upper == "LIST" || upper == "LS" { return .list }
        if upper == "NEXT" || upper == "N" { return .next }
        if let resolvedTheme = AppTheme.theme(named: trimmed),
           let preset = AppTheme.allPresets.first(where: {
               $0.theme.id == resolvedTheme.id || ThemeCommand.normalized($0.shortName) == ThemeCommand.normalized(trimmed)
                   || ThemeCommand.normalized($0.id) == ThemeCommand.normalized(trimmed)
                   || ThemeCommand.normalized($0.displayName) == ThemeCommand.normalized(trimmed)
           }) {
            return .named(preset.shortName)
        }
        let needle = ThemeCommand.normalized(trimmed)
        let hits = AppTheme.allPresets.filter { preset in
            ThemeCommand.normalized(preset.shortName).hasPrefix(needle)
                || ThemeCommand.normalized(preset.id).hasPrefix(needle)
                || ThemeCommand.normalized(preset.displayName).hasPrefix(needle)
        }
        switch hits.count {
        case 0:
            return .unknown(trimmed)
        case 1:
            return .named(hits[0].shortName)
        default:
            return .ambiguous(hits.map(\.shortName))
        }
    }

    /// Same normalization as `AppTheme.theme(named:)` so prefix matching
    /// agrees with exact matching ("Catppuccin Latte" == "latte").
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "é", with: "e")
    }

    /// Headless text handling for unit tests (no engine required).
    @discardableResult
    public func handleCommandText(
        _ text: String,
        currentThemeName: String,
        applyThemeNamed: (String) -> Bool,
        appliedThemeName: () -> String,
        cycleTheme: () -> String,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch Self.resolve(text) {
        case .useDefault:
            print("[CAD] Theme: \(currentThemeName) (unchanged).")
            return .finished
        case .list:
            print("[CAD] \(Self.listLine())")
            openPrompt(currentName: currentThemeName, processor: processor)
            return .continue
        case .next:
            let name = cycleTheme()
            print("[CAD] Theme set to: \(name)")
            return .finished
        case .named(let shortName):
            if applyThemeNamed(shortName) {
                print("[CAD] Theme set to: \(appliedThemeName())")
            } else {
                print("[CAD] Unknown theme '\(shortName)'. \(Self.listLine())")
                openPrompt(currentName: currentThemeName, processor: processor)
                return .continue
            }
            return .finished
        case .ambiguous(let shorts):
            print("[CAD] Ambiguous theme '\(text.trimmingCharacters(in: .whitespacesAndNewlines))' matches \(shorts.joined(separator: ", ")). \(Self.listLine())")
            openPrompt(currentName: currentThemeName, processor: processor)
            return .continue
        case .unknown(let raw):
            print("[CAD] Unknown theme '\(raw)'. \(Self.listLine())")
            openPrompt(currentName: currentThemeName, processor: processor)
            return .continue
        }
    }

    // MARK: - Helpers

    public static func promptText(currentName: String) -> String {
        let keys = (AppTheme.allPresets.map(\.shortName) + ["Next", "?"]).joined(separator: "/")
        let current = currentName.uppercased()
        return "Enter theme [\(keys)] <\(current)>:"
    }

    public static func listLine() -> String {
        let names = AppTheme.allPresets.map { "\($0.displayName) (\($0.shortName))" }
        return "Available themes: \(names.joined(separator: ", "))."
    }

    private func openPrompt(currentName: String, processor: CADCommandProcessor) {
        processor.commandPrompt = Self.promptText(currentName: currentName)
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.promptInputKind = .token
        processor.commandLineActive = true
        print("[CAD] \(processor.commandPrompt ?? "")")
    }
}

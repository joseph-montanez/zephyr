// Sources/ZephyrCore/Commands/OverkillCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// OVERKILL and -OVERKILL (Delete Duplicate Objects).
///
/// Interactive OVERKILL previews the `OverkillEngine` plan for the current
/// selection (or for the whole drawing after an explicit `ALL`) and applies
/// it on confirmation. `-OVERKILL` applies immediately with no prompts, for
/// macros and script files. Both modes mutate through one `replaceEntities`
/// batch (exactly one undo entry); OOPS is not populated — UNDO restores.
///
/// Option keywords accept `KEY value` or `KEY=value` form:
/// `TOLERANCE`, `IGNORE`, `OPTIMIZE`, `KEEP`, `OVERLAP`, `END`, `WIDTHS`,
/// `ASSOCIATIVE`, `RESET`. Settings persist per session.
@MainActor
public final class OverkillCommand: FeatureCommand {

    public enum Mode {
        case confirm
        case scripted
    }

    /// Sticky session settings (LT persists the dialog per session).
    static var savedOptions = OverkillOptions()

    private let mode: Mode
    private var options: OverkillOptions
    private var scope: Set<UUID>?
    private var plan: OverkillPlan?
    private var awaitingScope = false

    public init(mode: Mode) {
        self.mode = mode
        self.options = Self.savedOptions
    }

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        options = Self.savedOptions
        let selected = engine.cadSelection.selectedHandles
        if mode == .scripted {
            scope = selected.isEmpty ? nil : selected
            apply(engine: engine, processor: processor)
            processor.finishFeatureCommand(engine: engine)
            return
        }
        if selected.isEmpty {
            awaitingScope = true
            processor.commandPrompt =
                "No objects selected. Type ALL to clean the entire drawing, or Esc to cancel."
            return
        }
        scope = selected
        refreshPreview(engine: engine)
        processor.commandPrompt = confirmPrompt()
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if awaitingScope {
            if input.uppercased() == "ALL" {
                awaitingScope = false
                scope = nil
                refreshPreview(engine: engine)
                processor.commandPrompt = confirmPrompt()
                return .continue
            }
            processor.commandPrompt = "OVERKILL cancelled; nothing removed."
            return .finished
        }
        let upper = input.uppercased()
        switch upper {
        case "Y", "YES":
            apply(engine: engine, processor: processor)
            return .finished
        case "N", "NO":
            processor.commandPrompt = "OVERKILL cancelled; nothing removed."
            return .finished
        case "S", "SETTINGS", "?":
            processor.commandPrompt = settingsHelp() + " " + confirmPrompt()
            return .continue
        default:
            if applySetting(input) {
                Self.savedOptions = options
                refreshPreview(engine: engine)
                processor.commandPrompt = confirmPrompt()
            } else {
                processor.commandPrompt =
                    "Unknown option \"\(input)\". " + settingsHelp() + " " + confirmPrompt()
            }
            return .continue
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        if awaitingScope {
            return [
                .init(value: "ALL", title: "All",
                      description: "Clean all unlocked objects in the drawing"),
            ].filter { $0.matches(input) }
        }
        return [
            .init(value: "Y", title: "Yes", aliases: ["YES"],
                  description: "Apply the cleanup"),
            .init(value: "N", title: "No", aliases: ["NO"],
                  description: "Cancel without changes"),
            .init(value: "S", title: "Settings", aliases: ["SETTINGS"],
                  description: settingsSummary()),
            .init(value: "TOLERANCE", title: "Tolerance",
                  description: "Coordinate matching precision (current \(formatTol()))"),
            .init(value: "IGNORE", title: "Ignore",
                  description: "Properties to disregard when comparing"),
            .init(value: "OPTIMIZE", title: "Optimize",
                  description: "Optimize segments within polylines"),
            .init(value: "KEEP", title: "Keep",
                  description: "Do not break polylines"),
            .init(value: "OVERLAP", title: "Overlap",
                  description: "Combine collinear objects that partially overlap"),
            .init(value: "END", title: "End",
                  description: "Combine collinear objects aligned end to end"),
            .init(value: "WIDTHS", title: "Widths",
                  description: "Ignore polyline segment widths"),
            .init(value: "ASSOCIATIVE", title: "Associative",
                  description: "Maintain associative objects"),
            .init(value: "RESET", title: "Reset",
                  description: "Restore default settings"),
        ].filter { $0.matches(input) }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func refreshPreview(engine: PhrostEngine) {
        plan = OverkillEngine.plan(
            document: engine.document, handles: scope, options: options)
    }

    private func confirmPrompt() -> String {
        let summary = plan?.report.summary ?? "No duplicates found."
        return "OVERKILL: \(summary) [Yes/No/Settings]:"
    }

    private func formatTol() -> String {
        let t = options.effectiveTolerance
        if t == OverkillEngine.defaultTolerance { return "0.000001" }
        return String(t)
    }

    private func settingsSummary() -> String {
        let ignored = options.ignoredProperties.isEmpty
            ? "none" : options.ignoredProperties.map { $0.rawValue }.sorted().joined(separator: ",")
        func on(_ v: Bool) -> String { v ? "on" : "off" }
        return "tol=\(formatTol()) ignore=\(ignored) optimize=\(on(options.optimizePolylineSegments))"
            + " keep=\(on(options.keepPolylinesIntact)) overlap=\(on(options.mergePartialOverlap))"
            + " end=\(on(options.mergeEndToEnd)) widths=\(on(options.ignorePolylineWidths))"
            + " assoc=\(on(options.protectAssociative))"
    }

    private func settingsHelp() -> String {
        "Options: TOLERANCE <value> | IGNORE <prop,...|none> | OPTIMIZE on|off"
            + " | KEEP on|off | OVERLAP on|off | END on|off | WIDTHS on|off"
            + " | ASSOCIATIVE on|off | RESET. Current: \(settingsSummary())."
    }

    /// Parse one `KEY value` / `KEY=value` settings line. Returns false when
    /// the input is not a recognized setting.
    private func applySetting(_ input: String) -> Bool {
        let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        let value: String
        if let eq = line.firstIndex(of: "=") {
            key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        } else {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                return input.uppercased() == "RESET" ? resetAll() : false
            }
            key = parts[0].uppercased()
            value = parts[1]
        }
        switch key {
        case "T", "TOLERANCE", "TOL":
            guard let v = Double(value), v.isFinite, v > 0 else { return false }
            options.tolerance = v
            return true
        case "IGNORE", "IGN":
            return applyIgnore(value)
        case "OPTIMIZE", "OPT":
            guard let v = parseBool(value) else { return false }
            options.optimizePolylineSegments = v
            return true
        case "KEEP", "KEEPINTACT":
            guard let v = parseBool(value) else { return false }
            options.keepPolylinesIntact = v
            return true
        case "OVERLAP":
            guard let v = parseBool(value) else { return false }
            options.mergePartialOverlap = v
            return true
        case "END", "ENDTOEND":
            guard let v = parseBool(value) else { return false }
            options.mergeEndToEnd = v
            return true
        case "WIDTHS", "WIDTH":
            guard let v = parseBool(value) else { return false }
            options.ignorePolylineWidths = v
            return true
        case "ASSOCIATIVE", "ASSOC":
            guard let v = parseBool(value) else { return false }
            options.protectAssociative = v
            return true
        case "RESET":
            return resetAll()
        default:
            return false
        }
    }

    private func resetAll() -> Bool {
        options = OverkillOptions()
        return true
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespaces).uppercased() {
        case "ON", "YES", "Y", "TRUE", "1": return true
        case "OFF", "NO", "N", "FALSE", "0": return false
        default: return nil
        }
    }

    private func applyIgnore(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: .whitespaces).uppercased()
        if raw == "NONE" || raw == "CLEAR" || raw.isEmpty {
            options.ignoredProperties = []
            return true
        }
        var parsed = Set<OverkillIgnoredProperty>()
        for token in raw.split(whereSeparator: { $0 == "," || $0 == " " }) {
            guard let prop = ignoredProperty(named: String(token)) else { return false }
            parsed.insert(prop)
        }
        options.ignoredProperties = parsed
        return true
    }

    private func ignoredProperty(named token: String) -> OverkillIgnoredProperty? {
        switch token {
        case "COLOR", "COLOUR", "C": return .color
        case "LAYER", "LA": return .layer
        case "LINETYPE", "LTYPE", "LT": return .linetype
        case "LINETYPESCALE", "LTSCALE", "SCALE": return .linetypeScale
        case "LINEWEIGHT", "LWEIGHT", "WEIGHT", "LW": return .lineweight
        case "THICKNESS", "THICK": return .thickness
        case "TRANSPARENCY", "TRANS", "TR": return .transparency
        case "PLOTSTYLE", "PLOT": return .plotStyle
        default: return nil
        }
    }

    private func apply(engine: PhrostEngine, processor: CADCommandProcessor) {
        if plan == nil { refreshPreview(engine: engine) }
        guard let plan else {
            processor.commandPrompt = "OVERKILL cancelled; nothing removed."
            return
        }
        Self.savedOptions = options
        if plan.isEmpty {
            processor.commandPrompt = "OVERKILL: \(plan.report.summary)"
            print("[OVERKILL] \(plan.report.summary)")
            return
        }
        engine.document.replaceEntities(remove: plan.remove, add: plan.add)
        for handle in plan.remove {
            engine.cadSelection.removeFromSelection(handle)
        }
        for entity in plan.add {
            engine.cadSelection.addToSelection(entity.handle)
        }
        engine.tabManager.markActiveDirty()
        let message = "OVERKILL: \(plan.report.summary)"
        print("[OVERKILL] \(message)")
        processor.commandPrompt = message
    }
}

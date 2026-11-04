import CSDL3
import Foundation
import ImGui
import SwiftSDL
import ZephyrKernel

// =========================================================================
// MARK: - PlanCommand
//
// AutoCAD-style PLAN for the planar engine: align the view so the active
// UCS X axis is screen-horizontal, then zoom to extents. The rotation that
// achieves this is exactly the canonical UCS angle: worldToScreen applies
// R(-rotation), so a UCS X axis at world angle A lands horizontal when
// rotation == A. Named saved UCS views are out of scope and report honestly.
// =========================================================================

@MainActor
public final class PlanCommand: FeatureCommand {

    public enum Selection {
        case current
        case world
        case namedUnsupported
        case invalid
    }

    public static let optionPrompt =
        "Enter an option [Current ucs/Ucs/World] <Current>:"

    public init() {}

    public var isSnappingEnabled: Bool { false }

    // MARK: - FeatureCommand conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        start(processor: processor)
    }

    /// Headless entry point for unit tests (no SDL engine required).
    public func start(processor: CADCommandProcessor) {
        openPrompt(Self.optionPrompt, processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Canvas clicks never choose a PLAN option; use keys or typed text.
        .handled
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        case SDL_SCANCODE_C:
            return handleCommandText(
                "CURRENT", engine: engine, processor: processor)
        case SDL_SCANCODE_U:
            return handleCommandText(
                "UCS", engine: engine, processor: processor)
        case SDL_SCANCODE_W:
            return handleCommandText(
                "WORLD", engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Context-sensitive command-line options

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        let options: [FeatureCommandTextOption] = [
            .init(
                value: "C", title: "Current ucs", aliases: ["CURRENT"],
                description: "Plan view of the current UCS"),
            .init(
                value: "U", title: "Ucs", aliases: ["UCS"],
                description: "Plan view of a saved UCS (not supported yet)"),
            .init(
                value: "W", title: "World", aliases: ["WORLD"],
                description: "Plan view of the world coordinate system"),
        ]
        return options.filter { $0.matches(input) }
    }

    // MARK: - Command text handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        handleCommandText(
            text,
            ucsAngle: engine.document.ucsState.definition.angle,
            pushViewState: engine.camera.pushViewState,
            applyRotation: { engine.camera.rotation = $0 },
            zoomToExtents: engine.zoomExtents,
            processor: processor)
    }

    /// Headless PLAN application for unit tests.
    @discardableResult
    public func handleCommandText(
        _ text: String,
        ucsAngle: Double,
        pushViewState: () -> Void,
        applyRotation: (Double) -> Void,
        zoomToExtents: () -> Void,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch Self.selection(for: text) {
        case .current:
            pushViewState()
            applyRotation(ucsAngle)
            zoomToExtents()
            print("[CAD] Plan view of current UCS.")
            return .finished
        case .world:
            pushViewState()
            applyRotation(0)
            zoomToExtents()
            print("[CAD] Plan view of World UCS.")
            return .finished
        case .namedUnsupported:
            print("[CAD] Saved UCS names are not supported yet.")
            return .finished
        case .invalid:
            openPrompt("Unknown PLAN option. \(Self.optionPrompt)", processor: processor)
            return .continue
        }
    }

    // MARK: - Option mapping

    /// Map raw command-line text to a PLAN selection.
    /// Bare input selects the `<Current>` default.
    public static func selection(for text: String) -> Selection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        let body: String
        if upper.isEmpty || upper == "PLAN" {
            body = ""
        } else if upper.hasPrefix("PLAN ") {
            body = String(upper.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = upper
        }
        switch body {
        case "", "CURRENT", "C":
            return .current
        case "WORLD", "W":
            return .world
        case "UCS", "U":
            return .namedUnsupported
        default:
            return .invalid
        }
    }

    /// Camera rotation that makes the selected frame screen-horizontal.
    /// Nil for selections with no executable meaning yet.
    public static func cameraRotation(for selection: Selection, ucsAngle: Double) -> Double? {
        switch selection {
        case .current:
            return ucsAngle
        case .world:
            return 0
        case .namedUnsupported, .invalid:
            return nil
        }
    }

    // MARK: - Helpers

    private func openPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
        print("[CAD] \(prompt)")
    }
}

// MARK: - Command-line dispatch

/// Start (or continue) the interactive PLAN command for command-line input.
/// Kept as a free function so the S2 dispatch table gains PLAN options
/// without restructuring the legacy switch.
@MainActor internal func startPlanFeatureCommand(
    text: String,
    engine: PhrostEngine?,
    processor: CADCommandProcessor
) {
    guard let engine else {
        processor.clearCommand()
        return
    }
    // A keyboard-driven command never inherits a centered cursor: drop any
    // stray relative capture (missed mouse-up elsewhere) on entry.
    RadialNavCapture.releaseAllRelativeMouseModes(windows: engine.windowManager.windows)
    let upper = text.uppercased()
    let argument: String
    if upper == "PLAN" {
        argument = ""
    } else if upper.hasPrefix("PLAN ") {
        argument = String(upper.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        argument = upper
    }
    if let active = processor.activeFeatureCommand as? PlanCommand {
        let result = active.handleCommandText(argument, engine: engine, processor: processor)
        if result == .finished {
            processor.finishFeatureCommand(engine: engine)
        }
        return
    }
    let command = PlanCommand()
    processor.activeFeatureCommand = command
    command.start(engine: engine, processor: processor)
    // Bare PLAN stops at the options prompt (AutoCAD flow); the next Enter
    // arrives as a continuation submit and accepts <Current>. Mirrors UCS.
    guard !argument.isEmpty else { return }
    let result = command.handleCommandText(argument, engine: engine, processor: processor)
    if result == .finished {
        processor.finishFeatureCommand(engine: engine)
    }
}

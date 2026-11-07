import Foundation
import SwiftSDL

@MainActor
public final class AutoContrastCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let current = engine.tabManager.activeDocument.autoContrastTrueColor ? "ON" : "OFF"
        processor.commandPrompt = "Enter TrueColor auto-contrast mode [ON/OFF] <\(current)>:"
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .handled }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER {
            let doc = engine.tabManager.activeDocument
            let nextState = !doc.autoContrastTrueColor
            doc.autoContrastTrueColor = nextState
            doc.markNeedsRegeneration()
            processor.commandPrompt = nil
            return .finished
        }
        if scancode == SDL_SCANCODE_ESCAPE {
            processor.commandPrompt = nil
            return .finished
        }
        return .continue
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let doc = engine.tabManager.activeDocument
        if trimmed.isEmpty {
            let nextState = !doc.autoContrastTrueColor
            doc.autoContrastTrueColor = nextState
            doc.markNeedsRegeneration()
            return .finished
        }
        if trimmed == "ON" || trimmed == "1" || trimmed == "TRUE" {
            doc.autoContrastTrueColor = true
            doc.markNeedsRegeneration()
            return .finished
        } else if trimmed == "OFF" || trimmed == "0" || trimmed == "FALSE" {
            doc.autoContrastTrueColor = false
            doc.markNeedsRegeneration()
            return .finished
        } else {
            let current = doc.autoContrastTrueColor ? "ON" : "OFF"
            processor.commandPrompt = "Invalid option. Enter TrueColor auto-contrast mode [ON/OFF] <\(current)>:"
            processor.commandLineActive = true
            processor.commandBuffer = ""
            return .handled
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        [
            .init(value: "ON", title: "ON", description: "Enable auto-contrast for TrueColor values (default CAD behavior)"),
            .init(value: "OFF", title: "OFF", description: "Disable auto-contrast for TrueColor values (render exact RGB)")
        ].filter { $0.matches(input) }
    }

    public func activeOptionValues(engine: PhrostEngine) -> Set<String> {
        [engine.tabManager.activeDocument.autoContrastTrueColor ? "ON" : "OFF"]
    }
}

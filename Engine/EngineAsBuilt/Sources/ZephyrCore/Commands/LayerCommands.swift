import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - LayerPickCommand (LAYOFF / LAYON / LAYISO / LAYUNISO / LAYMCUR)
// =========================================================================

/// One pick-driven feature command behind the layer quick tools: click an
/// entity, resolve its layer, and apply the mode. LAYOFF refuses the current
/// layer (AutoCAD behavior); LAYUNISO needs no pick and runs in `start`.
/// Visibility and isolation changes land in exactly one undo step via the
/// batch document APIs. LAYMCH is intentionally separate: it reuses the
/// existing layer-move popup UI instead of a pick flow.
@MainActor
public final class LayerPickCommand: FeatureCommand {

    public enum Mode {
        case off
        case on
        case isolate
        case unisolate
        case makeCurrent
    }

    private let mode: Mode

    public init(mode: Mode) {
        self.mode = mode
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        switch mode {
        case .unisolate:
            if engine.document.unisolateLayers() {
                processor.commandPrompt = "Layers restored."
            } else {
                processor.commandPrompt = "Nothing to unisolate."
            }
            processor.finishFeatureCommand(engine: engine)
        case .off:
            processor.commandPrompt = "Select object on the layer to turn off:"
        case .on:
            processor.commandPrompt = "Select object on the layer to turn on:"
        case .isolate:
            processor.commandPrompt =
                "Select object on the layer to isolate or [Settings]:"
        case .makeCurrent:
            processor.commandPrompt = "Select object on the layer to make current:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        guard mode == .isolate else { return [] }
        return [
            .init(
                value: "S", title: "Settings", aliases: ["SETTINGS"],
                description: "Toggle hide-others vs fade-others"),
        ]
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard mode == .isolate else { return .continue }
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper == "S" || upper == "SETTINGS" else { return .continue }
        engine.document.layisoFadeOthers.toggle()
        processor.commandPrompt = engine.document.layisoFadeOthers
            ? "Isolating fades other layers. Select object on the layer to isolate:"
            : "Isolating hides other layers. Select object on the layer to isolate:"
        return .handled
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let doc = engine.document
        guard let handle = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY,
            document: doc,
            threshold: 12.0 / engine.camera.zoom,
            simplifyComplexBlocks: false
        ), let entity = doc.entity(for: handle) else {
            processor.commandPrompt = "No object there. Select object (Esc to cancel):"
            return .handled
        }
        guard let layer = doc.layer(for: entity.layerID) else {
            processor.commandPrompt = "Object has no layer. Select object (Esc to cancel):"
            return .handled
        }
        switch mode {
        case .off:
            if layer.handle == doc.activeLayerID {
                processor.commandPrompt =
                    "Cannot turn off the current layer '\(layer.name)'. Select object (Esc to cancel):"
                return .handled
            }
            if !layer.isVisible {
                processor.commandPrompt =
                    "Layer '\(layer.name)' is already off. Select object (Esc to cancel):"
                return .handled
            }
            doc.setLayersVisible([layer.handle], visible: false)
            processor.commandPrompt = "Layer '\(layer.name)' turned off."
            return .finished
        case .on:
            doc.setLayersVisible([layer.handle], visible: true)
            processor.commandPrompt = "Layer '\(layer.name)' turned on."
            return .finished
        case .isolate:
            doc.isolateLayers(keeping: [layer.handle])
            processor.commandPrompt = doc.layisoFadeOthers
                ? "Isolated '\(layer.name)'; others faded."
                : "Isolated '\(layer.name)'."
            return .finished
        case .makeCurrent:
            doc.activeLayerID = layer.handle
            processor.commandPrompt = "Current layer set to '\(layer.name)'."
            return .finished
        case .unisolate:
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

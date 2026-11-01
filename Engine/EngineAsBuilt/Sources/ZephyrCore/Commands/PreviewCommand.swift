import Foundation
import CSDL3
import SwiftSDL

/// `PREVIEW`: live-canvas plot preview (step 23). Opens a full preview
/// window rendering the active layout through its plot settings
/// (paper sheet, printable area, plot-area framing) with Fit/zoom,
/// drag-to-pan, and Esc to return. No PDFium rasterization in v1.
@MainActor
public final class PreviewCommand: FeatureCommand {
    private weak var processor: CADCommandProcessor?

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        self.processor = processor
        if let tab = engine.tabManager.activeTab {
            let view = tab.drawingViews[tab.activeViewIndex]
            if view.kind == .sheet {
                engine.ui.previewSettings = view.document.plotSettings ?? CADPlotSettings(
                    paperWidthMM: 279.4, paperHeightMM: 215.9, plotPaperUnits: 1)
            } else {
                engine.ui.previewSettings = nil
            }
        }
        engine.ui.previewActive = true
        processor.commandPrompt = "Plot preview — Esc to exit."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        engine.ui.previewActive = false
        self.processor = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        .handled
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            engine.ui.previewActive = false
            return .finished
        }
        return .handled
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func renderImGui(engine: PhrostEngine) {
        guard !engine.ui.previewActive, let processor else { return }
        processor.finishFeatureCommand(engine: engine)
        self.processor = nil
    }
}

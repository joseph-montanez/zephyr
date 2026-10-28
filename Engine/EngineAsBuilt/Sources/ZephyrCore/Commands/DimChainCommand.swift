// Sources/ZephyrCore/Commands/DimChainCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// Shared engine for DIMCONTINUE (DCO) and DIMBASELINE (DBA), following the
/// LayerPickCommand(mode:) precedent: one class, two factories.
/// LT flow: adopt one linear/aligned source dimension (current selection or
/// a pick), then each picked extension origin commits a chained dimension
/// with live preview. Continue chains from the previous second origin;
/// baseline always measures from the base origin with stacked dimlines.
/// Enter or Escape finishes; each commit is its own undo step via
/// commitDimension, matching DimLinearCommand.
@MainActor
public final class DimChainCommand: FeatureCommand {

    public enum Mode {
        case cont
        case base
    }

    private enum State {
        case pickingSource
        case chaining
    }

    private let mode: Mode
    private var state: State = .pickingSource
    private var chain: DimChainMath.SourceChain?
    private var stackIndex: Int = 0
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    public init(mode: Mode) {
        self.mode = mode
    }

    private var noun: String { mode == .cont ? "continue" : "baseline" }

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickingSource
        chain = nil
        stackIndex = 0
        // LT adopts a pre-selected dimension without asking.
        if engine.cadSelection.selectedHandles.count == 1,
           let handle = engine.cadSelection.selectedHandles.first,
           let entity = engine.document.entity(for: handle),
           let metadata = entity.dimensionMetadata?.value,
           let source = DimChainMath.resolveSource(from: metadata) {
            chain = source
            state = .chaining
            processor.commandPrompt = "Specify extension line origin or [Enter] to finish:"
        } else {
            processor.commandPrompt = "Select a linear or aligned dimension to \(noun):"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        guard let chain else { return [] }
        return [chain.baseOrigin, chain.prevOrigin]
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .pickingSource:
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY, document: engine.document),
                  let entity = engine.document.entity(for: handle),
                  let metadata = entity.dimensionMetadata?.value,
                  let source = DimChainMath.resolveSource(from: metadata)
            else {
                processor.commandPrompt = "Not a linear or aligned dimension. Select a dimension to \(noun):"
                return .continue
            }
            chain = source
            stackIndex = 0
            state = .chaining
            processor.commandPrompt = "Specify extension line origin or [Enter] to finish:"
            return .continue

        case .chaining:
            guard let chain else { return .finished }
            let picked = engine.snap.currentSnapResult?.worldPos
                ?? Vector3(x: worldX, y: worldY, z: 0)
            let next: DimChainMath.ChainedDim?
            switch mode {
            case .cont:
                next = DimChainMath.continueNext(from: chain, picked: picked)
            case .base:
                let spacing = engine.document.currentDimensionStyle().dimLineOffset
                next = DimChainMath.baselineNext(
                    from: chain, picked: picked,
                    stackIndex: stackIndex + 1, spacing: spacing)
            }
            guard let next else {
                processor.commandPrompt = "Points must be distinct. Specify extension line origin or [Enter] to finish:"
                return .continue
            }
            commit(next, engine: engine)
            switch mode {
            case .cont:
                self.chain?.prevOrigin = picked
            case .base:
                stackIndex += 1
            }
            processor.commandPrompt = "Specify extension line origin or [Enter] to finish:"
            return .continue
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE, SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard state == .chaining, let chain else { return }
        let mouse = engine.snap.currentSnapResult?.worldPos
            ?? Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
        let next: DimChainMath.ChainedDim?
        switch mode {
        case .cont:
            next = DimChainMath.continueNext(from: chain, picked: mouse)
        case .base:
            let spacing = engine.document.currentDimensionStyle().dimLineOffset
            next = DimChainMath.baselineNext(
                from: chain, picked: mouse,
                stackIndex: stackIndex + 1, spacing: spacing)
        }
        guard let next else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)
        let p1s = EngineCameraManager.worldToScreen(worldX: next.p1.x, worldY: next.p1.y, cam: cam)
        let p2s = EngineCameraManager.worldToScreen(worldX: next.p2.x, worldY: next.p2.y, cam: cam)
        let dsScreen = EngineCameraManager.worldToScreen(worldX: next.dimStart.x, worldY: next.dimStart.y, cam: cam)
        let deScreen = EngineCameraManager.worldToScreen(worldX: next.dimEnd.x, worldY: next.dimEnd.y, cam: cam)
        ImDrawListAddLine(drawList, ImVec2(x: p1s.x, y: p1s.y), ImVec2(x: dsScreen.x, y: dsScreen.y), col, 1.0)
        ImDrawListAddLine(drawList, ImVec2(x: p2s.x, y: p2s.y), ImVec2(x: deScreen.x, y: deScreen.y), col, 1.0)
        ImDrawListAddLine(drawList, ImVec2(x: dsScreen.x, y: dsScreen.y), ImVec2(x: deScreen.x, y: deScreen.y), col, 1.5)
    }

    private func commit(
        _ chained: DimChainMath.ChainedDim, engine: PhrostEngine
    ) {
        let style = engine.document.currentDimensionStyle()
        let color: ColorRGBA = .white
        let metadata = CADDimensionMetadata(
            styleName: engine.document.currentDimensionStyleName,
            type: chained.type,
            measurement: chained.measurement,
            defPoint: chained.dimLinePos,
            defPoint2: chained.p1,
            defPoint3: chained.p2,
            textMidpoint: chained.textMidpoint,
            rotationAngle: chained.angle)
        let primitives = DimChainMath.buildPrimitives(chained, style: style, color: color)
        DimensionPrimitives.commitDimension(
            primitives: primitives, metadata: metadata,
            layerID: engine.document.activeLayerID ?? UUID(),
            document: engine.document)
    }
}

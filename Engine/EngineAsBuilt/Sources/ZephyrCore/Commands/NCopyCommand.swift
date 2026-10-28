import Foundation
import CSDL3
import ImGui

// =========================================================================
// NCOPY — copy nested geometry out of blocks and xrefs: click block
// members (Enter commits, Esc cancels), each pick becomes a world-space
// loose entity under one undo entry. Picks never hit their own output:
// collection happens first, entities are added only on commit.
// =========================================================================

/// Pure NCOPY copy builder (engine-free for tests).
public enum NCopySupport {
    public static func makeCopy(
        hit: CADHitTesting.NestedHit, in document: CADDocument
    ) -> CADEntity? {
        guard let geometry = document.resolvedGeometry(for: hit.entity),
              hit.primitiveIndex < geometry.count else { return nil }
        let world = CADGeometryMath.transformPrimitives(
            [geometry[hit.primitiveIndex]], by: hit.transform)
        let styles = document.primitiveStyles(for: hit.entity)
        var layerID = hit.entity.layerID
        if let name = styles[hit.primitiveIndex]?.effectiveLayerName,
           let layer = document.allLayers.first(where: {
               $0.name.caseInsensitiveCompare(name) == .orderedSame
           }) {
            layerID = layer.handle
        }
        // Display-side xdata travels with the copy (shadow-sourced for
        // xrefs); stale handles never do.
        var xdata = hit.entity.xdata
        if let bid = hit.entity.blockID,
           let block = document.effectiveBlock(for: bid),
           let primXData = block.primitiveXData[hit.primitiveIndex] {
            for (key, value) in primXData { xdata[key] = value }
        }
        xdata.removeValue(forKey: "dxf.handle")
        return CADEntity(
            layerID: layerID,
            localGeometry: world,
            transform: .identity,
            xdata: xdata,
            drawOrder: hit.entity.drawOrder)
    }
}

@MainActor
public final class NCopyCommand: FeatureCommand {
    public var name: String { "NCOPY" }

    private var picks: [(point: Vector3, hit: CADHitTesting.NestedHit)] = []
    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        picks = []
        finished = false
        showCanvasPrompt(
            "Select nested objects (Enter to copy, Esc to cancel):",
            processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        picks = []
        finished = true
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard !finished else { return .finished }
        guard !picks.isEmpty else {
            processor.commandPrompt = "No nested objects selected."
            finished = true
            return .finished
        }
        let copies = picks.compactMap {
            NCopySupport.makeCopy(hit: $0.hit, in: engine.document)
        }
        if !copies.isEmpty {
            engine.document.addEntities(copies)
            engine.tabManager.markActiveDirty()
        }
        processor.commandPrompt = "Copied \(copies.count) nested object(s) to model space."
        finished = true
        return .finished
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard !finished else { return .finished }
        guard let hit = CADHitTesting.nestedHitTest(
            worldX: worldX, worldY: worldY, document: engine.document) else {
            return .continue
        }
        picks.append((point: Vector3(x: worldX, y: worldY, z: 0), hit: hit))
        showCanvasPrompt(
            "\(picks.count) nested object(s) selected (Enter to copy, Esc to cancel):",
            processor: processor)
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard !picks.isEmpty else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(80, 200, 255, 230)
        for pick in picks {
            let s = EngineCameraManager.worldToScreen(
                worldX: pick.point.x, worldY: pick.point.y, cam: cam)
            let r: Float = 6
            ImDrawListAddLine(
                drawList,
                ImVec2(x: s.x - r, y: s.y - r), ImVec2(x: s.x + r, y: s.y + r),
                color, 2)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: s.x - r, y: s.y + r), ImVec2(x: s.x + r, y: s.y - r),
                color, 2)
        }
    }

    private func showCanvasPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = false
    }
}

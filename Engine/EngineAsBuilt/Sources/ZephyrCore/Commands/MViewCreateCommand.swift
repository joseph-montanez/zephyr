import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// Interactive `MVIEW NEW` command: two-corner paper-space pick with a
/// live rectangle preview. Started from the `MVIEW NEW` text option or
/// the sheet tab-bar "New Viewport..." item; the typed
/// `MVIEW <x1,y1> <x2,y2>` form is unchanged and still works.
@MainActor
public final class MViewCreateCommand: FeatureCommand {

    private var firstCorner: (x: Double, y: Double)?
    private var currentMouse = (x: 0.0, y: 0.0)
    private var hasMouse = false

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func getDrawingSnapPoints() -> [Vector3] {
        guard let firstCorner else { return [] }
        return [Vector3(x: firstCorner.x, y: firstCorner.y, z: 0)]
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        start(tabManager: engine.tabManager, processor: processor)
    }

    /// Headless entry point for unit tests without a PhrostEngine.
    public func start(tabManager: TabManager, processor: CADCommandProcessor) {
        firstCorner = nil
        hasMouse = false
        processor.commandPrompt = "Specify first corner:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    /// Corner-pick entry shared by mouse, typed points, and tests.
    @discardableResult
    public func handlePoint(
        _ x: Double, _ y: Double,
        tabManager: TabManager,
        processor: CADCommandProcessor
    ) -> CommandResult {
        advance(worldX: x, worldY: y, tabManager: tabManager, processor: processor)
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        advance(worldX: worldX, worldY: worldY, tabManager: engine.tabManager, processor: processor)
    }

    public func handleMouseUp(
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
    ) {
        currentMouse = (x: worldX, y: worldY)
        hasMouse = true
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE { return .finished }
        return .handled
    }

    /// Typed paper points (`x,y`) are accepted as corner picks so the
    /// selection is scriptable without mouse coordinates.
    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let parts = cleaned.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            processor.commandPrompt = firstCorner == nil
                ? "Specify first corner (x,y):"
                : "Specify second corner (x,y):"
            return .consumed
        }
        return advance(worldX: x, worldY: y, tabManager: engine.tabManager, processor: processor)
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard let firstCorner, hasMouse else { return }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = UInt32(0xFF80FF00)
        let corners = [
            Vector3(x: firstCorner.x, y: firstCorner.y, z: 0),
            Vector3(x: currentMouse.x, y: firstCorner.y, z: 0),
            Vector3(x: currentMouse.x, y: currentMouse.y, z: 0),
            Vector3(x: firstCorner.x, y: currentMouse.y, z: 0),
            Vector3(x: firstCorner.x, y: firstCorner.y, z: 0),
        ]
        for i in 0..<(corners.count - 1) {
            let a = EngineCameraManager.worldToScreen(
                worldX: corners[i].x, worldY: corners[i].y, cam: cam)
            let b = EngineCameraManager.worldToScreen(
                worldX: corners[i + 1].x, worldY: corners[i + 1].y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), color, 1.5)
        }
    }

    // MARK: - Private

    private func advance(
        worldX: Double,
        worldY: Double,
        tabManager: TabManager,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if let first = firstCorner {
            if let id = tabManager.createSheetViewport(
                paperX1: first.x, paperY1: first.y,
                paperX2: worldX, paperY2: worldY) {
                print("[CAD] Viewport \(id) created.")
                return .finished
            }
            processor.commandPrompt = "Degenerate viewport. Specify first corner:"
            firstCorner = nil
            return .consumed
        }
        firstCorner = (x: worldX, y: worldY)
        processor.commandPrompt = "Specify second corner:"
        return .consumed
    }
}

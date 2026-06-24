import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - CleanSpecklesCommand
// =========================================================================

/// Select-by-example speckle cleaner.
///
/// **Workflow (AutoCAD-style):**
///   1. Pre-select a few example speckles (include the biggest one and each colour variant).
///   2. Type `CLEANSPECKLES` (or `CS` / `SPECKLES`).
///   3. Click first corner, then click second corner to define the area to clean.
///   4. Matching entities are selected — review, Shift-deselect keepers, then ERASE.
///
/// **Learned from the examples:** colour(s) + max diagonal size. Nothing to type.
///
/// **Pure pattern match:** every entity whose colour, size ceiling, and primitive type
/// match the examples is selected, regardless of what it touches.
@MainActor
public final class CleanSpecklesCommand: FeatureCommand {

    // MARK: - State Machine

    private enum State {
        /// Inspect the current selection to learn colours & max size.
        case learningFromExamples
        /// Waiting for the user to click the first corner of the area.
        case waitingForFirstCorner
        /// First corner stored; tracking mouse for live preview; waiting for second corner.
        case waitingForSecondCorner(firstX: Double, firstY: Double)
    }

    private var state: State = .learningFromExamples

    /// Colour signatures learned from the example selection.
    private var sampleColors: Set<ColorRGBA> = []
    /// Max bounding-box diagonal from examples, with a 30% fudge factor.
    private var maxDiagonal: Double = 0

    /// Live mouse position (world-space), updated by `handleMouseMotion`.
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    // MARK: - Init

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .learningFromExamples
        sampleColors.removeAll()
        maxDiagonal = 0
        currentMouseWorldX = 0
        currentMouseWorldY = 0

        let selection = engine.cadSelection
        let doc = engine.document

        guard selection.hasSelection else {
            processor.commandPrompt = "Select example speckles first, then run CLEANSPECKLES again."
            processor.finishFeatureCommand(engine: engine)
            return
        }

        // Learn colours and max diagonal from selected examples.
        for handle in selection.selectedHandles {
            guard let entity = doc.entity(for: handle) else { continue }
            let color = Self.resolveColor(for: entity, in: doc)
            sampleColors.insert(color)

            if let bb = entity.worldBoundingBox {
                let dx = bb.max.x - bb.min.x
                let dy = bb.max.y - bb.min.y
                let diag = sqrt(dx * dx + dy * dy)
                if diag > maxDiagonal { maxDiagonal = diag }
            }
        }
        maxDiagonal *= 1.3

        if maxDiagonal <= 0 {
            maxDiagonal = 0.05
        }

        let colorCount = sampleColors.count
        print(
            "[CleanSpeckles] Learned: \(colorCount) colour(s), max speckle diagonal ~\(maxDiagonal).")

        state = .waitingForFirstCorner
        processor.commandPrompt = "Click first corner of area to clean (Esc to cancel)."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .learningFromExamples
        sampleColors.removeAll()
        maxDiagonal = 0
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .learningFromExamples:
            // Should not happen — start() transitions away from this state.
            return .finished

        case .waitingForFirstCorner:
            state = .waitingForSecondCorner(firstX: worldX, firstY: worldY)
            currentMouseWorldX = worldX
            currentMouseWorldY = worldY
            processor.commandPrompt = "Click opposite corner (Esc to cancel)."
            return .continue

        case .waitingForSecondCorner(let firstX, let firstY):
            let cam = engine.camera.currentTransform(windowWidth: engine.windowWidth, windowHeight: engine.windowHeight)
            let p1 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: firstY, cam: cam)
            let p3 = EngineCameraManager.worldToScreen(worldX: worldX, worldY: worldY, cam: cam)

            let minSX = min(p1.x, p3.x)
            let maxSX = max(p1.x, p3.x)
            let minSY = min(p1.y, p3.y)
            let maxSY = max(p1.y, p3.y)

            let doc = engine.document
            var matchedHandles: [UUID] = []

            for entity in doc.entitiesView {
                guard let layer = doc.layer(for: entity.layerID), layer.isVisible else { continue }

                // Colour must match one of the learned examples.
                let entityColor = Self.resolveColor(for: entity, in: doc)
                guard sampleColors.contains(entityColor) else { continue }

                // Bounding box must fully lie within the selection window AND be small enough.
                guard let bb = entity.worldBoundingBox else { continue }
                
                let c1 = EngineCameraManager.worldToScreen(worldX: bb.min.x, worldY: bb.min.y, cam: cam)
                let c2 = EngineCameraManager.worldToScreen(worldX: bb.max.x, worldY: bb.min.y, cam: cam)
                let c3 = EngineCameraManager.worldToScreen(worldX: bb.max.x, worldY: bb.max.y, cam: cam)
                let c4 = EngineCameraManager.worldToScreen(worldX: bb.min.x, worldY: bb.max.y, cam: cam)

                let eMinSX = min(c1.x, c2.x, c3.x, c4.x)
                let eMaxSX = max(c1.x, c2.x, c3.x, c4.x)
                let eMinSY = min(c1.y, c2.y, c3.y, c4.y)
                let eMaxSY = max(c1.y, c2.y, c3.y, c4.y)

                guard eMinSX >= minSX && eMaxSX <= maxSX
                    && eMinSY >= minSY && eMaxSY <= maxSY else { continue }

                let dx = bb.max.x - bb.min.x
                let dy = bb.max.y - bb.min.y
                let diag = sqrt(dx * dx + dy * dy)
                guard diag < maxDiagonal else { continue }

                // Primitive type filter: must be simple (few primitives, speckle-like types).
                guard let geometry = doc.resolvedGeometry(for: entity),
                      geometry.count < 10,
                      geometry.allSatisfy(Self.isSpecklePrimitive(_:))
                else { continue }

                matchedHandles.append(entity.handle)
            }

            // Select the matches.
            engine.cadSelection.clearSelection()
            for handle in matchedHandles {
                engine.cadSelection.addToSelection(handle)
            }

            let count = matchedHandles.count
            print("[CleanSpeckles] Selected \(count) speckles in window.")
            if count > 0 {
                processor.commandPrompt =
                    "Selected \(count) speckle(s) matching your examples. Review, then ERASE."
            } else {
                processor.commandPrompt = "No speckles matched in the window."
            }

            return .finished
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
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    // MARK: - Render Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .waitingForSecondCorner(let firstX, let firstY) = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        // Bright cyan rectangle for the selection area preview.
        let col = makeCol32(0, 200, 255, 200)

        let p1 = EngineCameraManager.worldToScreen(worldX: firstX, worldY: firstY, cam: cam)
        let p3 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)

        let minSX = min(p1.x, p3.x)
        let maxSX = max(p1.x, p3.x)
        let minSY = min(p1.y, p3.y)
        let maxSY = max(p1.y, p3.y)

        let p1Draw = ImVec2(x: minSX, y: minSY)
        let p2Draw = ImVec2(x: maxSX, y: minSY)
        let p3Draw = ImVec2(x: maxSX, y: maxSY)
        let p4Draw = ImVec2(x: minSX, y: maxSY)

        ImDrawListAddLine(drawList, p1Draw, p2Draw, col, 1.5)
        ImDrawListAddLine(drawList, p2Draw, p3Draw, col, 1.5)
        ImDrawListAddLine(drawList, p3Draw, p4Draw, col, 1.5)
        ImDrawListAddLine(drawList, p4Draw, p1Draw, col, 1.5)

        // Filled semi-transparent overlay.
        let fillCol = makeCol32(0, 200, 255, 40)
        ImDrawListAddRectFilled(drawList, p1Draw, p3Draw, fillCol, 0.0, 0)
    }

    // MARK: - Helpers

    /// Resolve the **displayed** colour of an entity using the fallback chain:
    /// 1. `xdata["dxf.color"]` override (hex string from DXF).
    /// 2. Parent `Layer.color`.
    /// 3. White fallback.
    public static func resolveColor(for entity: CADEntity, in document: CADDocument) -> ColorRGBA {
        if let cv = entity.xdata["dxf.color"],
           case .string(let hex) = cv,
           let c = ColorRGBA(hex: hex)
        {
            return c
        }
        return document.layer(for: entity.layerID)?.color ?? .white
    }

    /// Returns `true` if the primitive is a "speckle-like" simple type.
    /// Excludes circles, arcs, text, and complex polygons.
    public static func isSpecklePrimitive(_ prim: CADPrimitive) -> Bool {
        switch prim {
        case .point, .line, .rect, .polygon, .polyline, .fillRect, .fillPolygon:
            return true
        case .fillComplexPolygon, .gradient, .circle, .arc, .text, .spline, .ellipse, .hatch, .ray, .image:
            return false
        }
    }
}

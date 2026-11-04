import Foundation
import CSDL3
import ImGui

// MARK: - PlaceViewCommand
//
// PLACEVIEW: one-shot place-on-sheet from the command line.
//   PLACEVIEW "<model.dxf>" <view> <scale> [paperX paperY]
// The view is a named view in the model file (matched case-insensitively);
// scale is the denominator (50 = 1:50). With a point the placement lands
// immediately, otherwise the command prompts for a canvas click and a
// paper-frame ghost follows the cursor. The sheet tab must be active;
// attach, instance, and viewport reuse the shared
// `TabManager.placeSheetView` flow.

@MainActor
public final class PlaceViewCommand: FeatureCommand {
    /// Parsed operands. `paperX/paperY` nil means "prompt for a click".
    public struct Request: Sendable, Equatable {
        public var modelPath: String
        public var viewName: String
        public var scaleDenominator: Double
        public var paperX: Double?
        public var paperY: Double?

        public init(
            modelPath: String, viewName: String, scaleDenominator: Double,
            paperX: Double? = nil, paperY: Double? = nil
        ) {
            self.modelPath = modelPath
            self.viewName = viewName
            self.scaleDenominator = scaleDenominator
            self.paperX = paperX
            self.paperY = paperY
        }
    }

    private enum Phase {
        case idle
        case awaitingPoint
    }

    /// Quote-aware parse. Strict arity: model, view (single token or
    /// quoted), scale, optional point. Anything else is usage error (nil).
    public static func parse(_ text: String) -> Request? {
        let args = CADCommandProcessor.splitSheetSetArgs(text)
        guard args.count == 3 || args.count == 5 else { return nil }
        guard !args[0].isEmpty, !args[1].isEmpty else { return nil }
        guard let scale = Double(args[2]), scale > 0 else { return nil }
        var request = Request(modelPath: args[0], viewName: args[1], scaleDenominator: scale)
        if args.count == 5 {
            guard let x = Double(args[3]), let y = Double(args[4]) else { return nil }
            request.paperX = x
            request.paperY = y
        }
        return request
    }

    /// Named-view lookup in the model file (first case-insensitive
    /// match). Nil when the file is unreadable, has no views, or the
    /// name is absent — callers fail loudly before attaching anything.
    public static func resolveView(
        modelPath: String, viewName: String
    ) -> SheetSetSheetViews.NamedView? {
        SheetSetSheetViews.readViews(atPath: modelPath)?
            .first { $0.name.caseInsensitiveCompare(viewName) == .orderedSame }
    }

    public static let usage =
        "PLACEVIEW \"<model.dxf>\" <view> <scale> [paperX paperY] (e.g. PLACEVIEW \"C:/m.dxf\" Lobby 50)"

    private var request: Request?
    private var view: SheetSetSheetViews.NamedView?
    private var phase: Phase = .idle
    private var mouseWorldX: Double = 0
    private var mouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .idle
        processor.commandPrompt = "Model drawing, view name, and scale (\(Self.usage))"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            processor.commandPrompt = Self.usage
            return .continue
        }
        guard let parsed = Self.parse(input) else {
            processor.commandPrompt = Self.usage
            return .continue
        }
        guard let found = Self.resolveView(modelPath: parsed.modelPath, viewName: parsed.viewName) else {
            let known = SheetSetSheetViews.readViews(atPath: parsed.modelPath)?
                .map(\.name).joined(separator: ", ") ?? "(unreadable — .dxf/.dwt only)"
            print("[PlaceView] View '\(parsed.viewName)' not found in '\(parsed.modelPath)'. Known: \(known). Nothing placed.")
            return .finished
        }
        request = parsed
        view = found
        if let x = parsed.paperX, let y = parsed.paperY {
            place(atX: x, y: y, engine: engine)
            return .finished
        }
        phase = .awaitingPoint
        processor.commandPrompt = "Specify placement point for '\(found.name)' at 1:\(parsed.scaleDenominator):"
        return .continue
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .awaitingPoint else { return .continue }
        let picked = engine.snap.currentSnapResult?.worldPos
            ?? Vector3(x: worldX, y: worldY, z: 0)
        place(atX: picked.x, y: picked.y, engine: engine)
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        mouseWorldX = worldX
        mouseWorldY = worldY
    }

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard phase == .awaitingPoint,
              let view = view, let request = request else { return }
        let corners = PlacePreview.rectCorners(
            centerX: mouseWorldX, centerY: mouseWorldY,
            width: view.width / request.scaleDenominator,
            height: view.height / request.scaleDenominator)
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(255, 217, 51, 230)
        let screen = corners.map { c in
            EngineCameraManager.worldToScreen(worldX: c.x, worldY: c.y, cam: cam)
        }
        for i in screen.indices {
            let a = screen[i]
            let b = screen[(i + 1) % screen.count]
            ImDrawListAddLine(
                drawList,
                ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), color, 1.5)
        }
    }

    private func place(atX x: Double, y: Double, engine: PhrostEngine) {
        guard let request, let view else { return }
        do {
            let placed = try engine.tabManager.placeSheetView(
                modelFileURL: URL(fileURLWithPath: request.modelPath),
                modelCenterX: view.targetX, modelCenterY: view.targetY,
                modelWidth: view.width, modelHeight: view.height,
                paperCenterXUp: x, paperCenterYUp: y,
                scaleDenominator: request.scaleDenominator)
            print("[PlaceView] Placed '\(view.name)' as viewport \(placed.viewportID).")
        } catch {
            print("[PlaceView] \(error.localizedDescription) Nothing placed.")
        }
    }
}

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
        case file
        case view
        case scale
        case paperX
        case paperY(x: Double)
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
        "PLACEVIEW prompts for model drawing, view name, scale, then an optional point (e.g. PLACEVIEW, \"C:/m.dxf\", Lobby, 50)"

    private var request: Request?
    private var view: SheetSetSheetViews.NamedView?
    private var phase: Phase = .file
    private var mouseWorldX: Double = 0
    private var mouseWorldY: Double = 0
    private var collectedModelPath: String = ""
    private var collectedViewName: String = ""
    private var collectedScale: Double = 50

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .file
        collectedModelPath = ""
        collectedViewName = ""
        openPrompt("Model drawing path:", kind: .line, processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.promptInputKind = .token
    }

    // Space == Enter: operands arrive one submit at a time (file → view →
    // scale → point). The retired one-line form lives on only as the static
    // `parse(_:)` below, which stays for tests and scripted callers.
    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .file:
            guard !input.isEmpty else {
                openPrompt("Model drawing path:", kind: .line, processor: processor)
                return .continue
            }
            collectedModelPath = input
            phase = .view
            openPrompt("View name in '\(input)':", kind: .line, processor: processor)
            return .continue
        case .view:
            guard !input.isEmpty else {
                openPrompt("View name in '\(collectedModelPath)':", kind: .line, processor: processor)
                return .continue
            }
            collectedViewName = input
            guard let found = Self.resolveView(
                modelPath: collectedModelPath, viewName: collectedViewName) else {
                let known = SheetSetSheetViews.readViews(atPath: collectedModelPath)?
                    .map(\.name).joined(separator: ", ") ?? "(unreadable — .dxf/.dwt only)"
                print("[PlaceView] View '\(collectedViewName)' not found in '\(collectedModelPath)'. Known: \(known). Nothing placed.")
                return .finished
            }
            view = found
            phase = .scale
            openPrompt("Scale denominator for '\(found.name)' (50 = 1:50):", kind: .token, processor: processor)
            return .continue
        case .scale:
            guard let scale = Double(input), scale > 0 else {
                openPrompt("Invalid scale. Scale denominator for '\(collectedViewName)' (50 = 1:50):", kind: .token, processor: processor)
                return .continue
            }
            collectedScale = scale
            request = Request(
                modelPath: collectedModelPath, viewName: collectedViewName,
                scaleDenominator: scale)
            phase = .paperX
            openPrompt("Placement paper X (empty = pick on screen):", kind: .token, processor: processor)
            return .continue
        case .paperX:
            if input.isEmpty {
                return openPlacementPoint(processor: processor)
            }
            guard let x = Double(input) else {
                openPrompt("Invalid number. Placement paper X (empty = pick on screen):", kind: .token, processor: processor)
                return .continue
            }
            phase = .paperY(x: x)
            openPrompt("Placement paper Y:", kind: .token, processor: processor)
            return .continue
        case .paperY(let x):
            guard let y = Double(input) else {
                openPrompt("Invalid number. Placement paper Y:", kind: .token, processor: processor)
                return .continue
            }
            request?.paperX = x
            request?.paperY = y
            place(atX: x, y: y, engine: engine)
            return .finished
        case .awaitingPoint:
            openPlacementPoint(processor: processor)
            return .continue
        }
    }

    @discardableResult
    private func openPlacementPoint(processor: CADCommandProcessor) -> CommandResult {
        phase = .awaitingPoint
        let name = view?.name ?? collectedViewName
        openPrompt(
            "Specify placement point for '\(name)' at 1:\(collectedScale):",
            kind: .token, processor: processor)
        return .continue
    }

    private func openPrompt(
        _ prompt: String, kind: CommandPromptInputKind,
        processor: CADCommandProcessor
    ) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.promptInputKind = kind
        processor.commandLineActive = true
        print("[CAD] \(prompt)")
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard case .awaitingPoint = phase else { return .continue }
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
        guard case .awaitingPoint = phase,
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

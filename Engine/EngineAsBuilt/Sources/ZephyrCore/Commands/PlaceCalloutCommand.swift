import Foundation
import CSDL3
import ImGui

// MARK: - PlaceCalloutCommand
//
// PLACECALLOUT: place a callout/label block for a named model view.
//   PLACECALLOUT "<model.dxf>" <view> <block> [paperX paperY] [TAG=value ...]
// The block must be defined in the active sheet (same *-prefix/internal
// filter as INSERT). Attributes fill from the view name, the active sheet's
// number/title when that sheet belongs to an open set, and explicit
// TAG=value overrides (matched case-insensitively, any position after the
// block); view-number tags stay defaulted unless overridden (LT-assigned).
// With a point the callout lands immediately, otherwise the command prompts
// for a canvas click and a block-bounds ghost follows the cursor; an
// unknown block fails before prompting. The sheet tab must be active.

@MainActor
public final class PlaceCalloutCommand: FeatureCommand {
    /// Parsed operands. `paperX/paperY` nil means "prompt for a click";
    /// `overrides` keys are uppercased tag names.
    public struct Request: Sendable, Equatable {
        public var modelPath: String
        public var viewName: String
        public var blockName: String
        public var paperX: Double?
        public var paperY: Double?
        public var overrides: [String: String]

        public init(
            modelPath: String, viewName: String, blockName: String,
            paperX: Double? = nil, paperY: Double? = nil,
            overrides: [String: String] = [:]
        ) {
            self.modelPath = modelPath
            self.viewName = viewName
            self.blockName = blockName
            self.paperX = paperX
            self.paperY = paperY
            self.overrides = overrides
        }
    }

    private enum Phase {
        case idle
        case awaitingPoint
    }

    /// Quote-aware parse. Strict arity: model, view (single token or
    /// quoted), block, then an optional paper point (exactly two numerics)
    /// and any number of TAG=value overrides in any order. A lone numeric
    /// or a `=key` token is a usage error (nil).
    public static func parse(_ text: String) -> Request? {
        let args = CADCommandProcessor.splitSheetSetArgs(text)
        guard args.count >= 3,
              !args[0].isEmpty, !args[1].isEmpty, !args[2].isEmpty else { return nil }
        var point: (Double, Double)?
        var overrides: [String: String] = [:]
        var plain: [String] = []
        for token in args.dropFirst(3) {
            if let eq = token.firstIndex(of: "=") {
                let rawKey = token[..<eq].trimmingCharacters(in: .whitespaces)
                guard !rawKey.isEmpty else { return nil }
                overrides[rawKey.uppercased()] = String(token[token.index(after: eq)...])
            } else {
                plain.append(token)
            }
        }
        switch plain.count {
        case 0:
            break
        case 2:
            guard let x = Double(plain[0]), let y = Double(plain[1]) else { return nil }
            point = (x, y)
        default:
            return nil
        }
        return Request(
            modelPath: args[0], viewName: args[1], blockName: args[2],
            paperX: point?.0, paperY: point?.1, overrides: overrides)
    }

    /// Named-view lookup in the model file (first case-insensitive
    /// match). Shared with PLACEVIEW: nil when the file is unreadable,
    /// has no views, or the name is absent.
    public static func resolveView(
        modelPath: String, viewName: String
    ) -> SheetSetSheetViews.NamedView? {
        PlaceViewCommand.resolveView(modelPath: modelPath, viewName: viewName)
    }

    public static let usage =
        "PLACECALLOUT \"<model.dxf>\" <view> <block> [paperX paperY] [TAG=value ...] (e.g. PLACECALLOUT \"C:/m.dxf\" Lobby CALLOUT VIEW_NO=3)"

    private var request: Request?
    private var view: SheetSetSheetViews.NamedView?
    private var phase: Phase = .idle
    private var mouseWorldX: Double = 0
    private var mouseWorldY: Double = 0
    private var previewBox: BoundingBox3D?

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .idle
        processor.commandPrompt = "Model drawing, view name, and callout block (\(Self.usage))"
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
            print("[PlaceCallout] View '\(parsed.viewName)' not found in '\(parsed.modelPath)'. Known: \(known). Nothing placed.")
            return .finished
        }
        request = parsed
        view = found
        if let x = parsed.paperX, let y = parsed.paperY {
            place(atX: x, y: y, engine: engine, processor: processor)
            return .finished
        }
        guard engine.tabManager.activeViewKind == .sheet else {
            print("[PlaceCallout] The active view is not a sheet; nothing placed.")
            return .finished
        }
        guard let preview = engine.document.allBlocks.first(where: {
            $0.name.caseInsensitiveCompare(parsed.blockName) == .orderedSame
                && !$0.name.hasPrefix("*")
                && !$0.isInternalTableDisplayBlock
        }) else {
            print("[PlaceCallout] Block \"\(parsed.blockName)\" is not defined in the active sheet. Nothing placed.")
            return .finished
        }
        previewBox = preview.geometry.isEmpty ? nil : preview.localBoundingBox
        phase = .awaitingPoint
        processor.commandPrompt = "Specify placement point for '\(parsed.blockName)' (\(found.name)):"
        return .continue
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .awaitingPoint else { return .continue }
        let picked = engine.snap.currentSnapResult?.worldPos
            ?? Vector3(x: worldX, y: worldY, z: 0)
        place(atX: picked.x, y: picked.y, engine: engine, processor: processor)
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
        guard phase == .awaitingPoint, let box = previewBox else { return }
        let corners = PlacePreview.rectCorners(
            centerX: mouseWorldX + (box.min.x + box.max.x) / 2.0,
            centerY: mouseWorldY + (box.min.y + box.max.y) / 2.0,
            width: box.max.x - box.min.x,
            height: box.max.y - box.min.y)
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

    private func place(
        atX x: Double, y: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let request, let view else { return }
        guard engine.tabManager.activeViewKind == .sheet else {
            print("[PlaceCallout] The active view is not a sheet; nothing placed.")
            return
        }
        let doc = engine.document
        let ctx = processor.sheetSetStore.sheetContext(
            documentFile: doc.sourceFileName, layoutName: doc.layoutName)
        let target = SheetViewCallouts.Target(
            viewName: view.name,
            modelFileName: URL(fileURLWithPath: request.modelPath).lastPathComponent,
            sheetNumber: ctx?.sheet.number,
            sheetTitle: ctx?.sheet.title)
        do {
            let handle = try engine.tabManager.placeSheetCallout(
                blockName: request.blockName, paperX: x, paperY: y
            ) { definitions in
                SheetViewCallouts.resolve(
                    definitions: definitions, target: target,
                    overrides: request.overrides)
            }
            print("[PlaceCallout] Placed '\(request.blockName)' for view '\(view.name)' (\(handle)).")
        } catch {
            print("[PlaceCallout] \(error) Nothing placed.")
        }
    }
}

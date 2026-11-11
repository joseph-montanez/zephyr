import Foundation
import CSDL3
import ImGui

// =========================================================================
// MARK: - PasteCommand
//
// Interactive PASTECLIP / PASTEBLOCK: prompts for an insertion point with
// a cursor-anchored ghost, then commits through the shared
// CADDocument.importClipboardEntry path (name-based remap, one undo).
//
// The ghost is baked once at start in source-unit anchor-relative space;
// each frame it is scaled to host units (INSUNITS) and translated to the
// cursor, so tab switches mid-command only affect the live scale factor.
// Esc cancels with zero document change.
// =========================================================================

public final class PasteCommand: FeatureCommand {
    public enum Mode: Sendable {
        /// PASTECLIP: place the entry's entities loose.
        case clip
        /// PASTEBLOCK: bundle the entry into one anonymous *A block.
        case block
    }

    public var name: String { mode == .clip ? "PASTECLIP" : "PASTEBLOCK" }

    private let mode: Mode
    private var preview = BlockPreview()
    private var mouseWorldX: Double = 0
    private var mouseWorldY: Double = 0
    private var hasEntry = false

    public init(mode: Mode) {
        self.mode = mode
    }

    // MARK: - Lifecycle

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard let entry = processor.clipboard.entry,
              !entry.entities.isEmpty
        else {
            print("[CAD] Clipboard is empty. Use COPYCLIP or COPYBASE first.")
            hasEntry = false
            processor.commandPrompt = nil
            return
        }
        hasEntry = true
        preview = Self.bakePreview(entry: entry)
        mouseWorldX = 0
        mouseWorldY = 0
        let noun = mode == .clip
            ? "\(entry.entities.count) entities"
            : "block (\(entry.entities.count) entities)"
        processor.commandPrompt = "Specify insertion point for \(noun):"
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = false
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        preview = BlockPreview()
        hasEntry = false
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    // MARK: - Text input

    public func handleCommandText(
        _ text: String, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard hasEntry,
              let entry = processor.clipboard.entry
        else { return .finished }
        guard let point = InsertCommand.parsePoint(text) else {
            processor.commandPrompt =
                "Point or option keyword required. Specify insertion point:"
            return .continue
        }
        commit(
            at: point, entry: entry, engine: engine, processor: processor)
        return .finished
    }

    // MARK: - Mouse

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard hasEntry,
              let entry = processor.clipboard.entry
        else { return .finished }
        commit(
            at: Vector3(x: worldX, y: worldY, z: 0),
            entry: entry, engine: engine, processor: processor)
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        mouseWorldX = worldX
        mouseWorldY = worldY
    }

    // MARK: - Preview (anchor-relative ghost at the cursor)

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard hasEntry, !preview.isEmpty else { return }
        let scale: Double
        if let entry = engine.commandProcessor.clipboard.entry {
            scale = CADModelSpaceBaker.unitScale(
                from: entry.sourceUnit, to: engine.document.unit)
        } else {
            scale = 1
        }
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(255, 217, 51, 230)
        for s in preview.segments {
            let ax = mouseWorldX + Double(s.x0) * scale
            let ay = mouseWorldY + Double(s.y0) * scale
            let bx = mouseWorldX + Double(s.x1) * scale
            let by = mouseWorldY + Double(s.y1) * scale
            let sa = EngineCameraManager.worldToScreen(
                worldX: ax, worldY: ay, cam: cam)
            let sb = EngineCameraManager.worldToScreen(
                worldX: bx, worldY: by, cam: cam)
            ImDrawListAddLine(
                drawList,
                ImVec2(x: sa.x, y: sa.y), ImVec2(x: sb.x, y: sb.y), color, 1.5)
        }
    }

    // MARK: - Commit

    private func commit(
        at point: Vector3, entry: CADClipboardEntry,
        engine: PhrostEngine, processor _: CADCommandProcessor
    ) {
        let result: ClipboardPasteResult
        switch mode {
        case .clip:
            result = engine.document.importClipboardEntry(
                entry, mode: .anchored(insertion: point))
        case .block:
            result = engine.document.importClipboardEntry(
                entry, mode: .block(insertion: point))
        }
        engine.cadSelection.clearSelection()
        for handle in result.handles {
            engine.cadSelection.addToSelection(handle)
        }
        if result.handles.isEmpty {
            print("[CAD] Paste produced no entities.")
        } else if mode == .block {
            print("[CAD] Pasted \(entry.entities.count) entities as block at (\(point.x), \(point.y)).")
        } else {
            print("[CAD] Pasted \(result.handles.count) entities at (\(point.x), \(point.y)).")
        }
    }

    /// Flatten the entry to anchor-relative linework (source units) for
    /// the cursor ghost. Mirrors the block-bake path minus styles.
    private static func bakePreview(entry: CADClipboardEntry) -> BlockPreview {
        let unbase = Transform3D.translated(by: Vector3(
            x: -entry.basePoint.x,
            y: -entry.basePoint.y,
            z: -entry.basePoint.z))
        var geometry: [CADPrimitive] = []
        for entity in entry.entities {
            let toLocal = unbase.multiplying(by: entity.transform)
            if let bid = entity.blockID,
               let block = entry.blocks[bid] {
                geometry.append(contentsOf:
                    CADGeometryMath.transformPrimitives(
                        block.geometry, by: toLocal))
            } else if let local = entity.localGeometry, !local.isEmpty {
                geometry.append(contentsOf:
                    CADGeometryMath.transformPrimitives(
                        local, by: toLocal))
            }
            if geometry.count > 20_000 { break }
        }
        return BlockPreview.build(geometry: geometry)
    }
}

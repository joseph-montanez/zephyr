// Sources/ZephyrCore/Commands/FieldCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// FIELD field-code evaluation (Phase 2.1). v1 codes are small typed
/// expressions stored in entity xdata (`field.expr`); the evaluated text
/// lives in the `.text` primitive (and `dxf.text`), so DXF export writes
/// the evaluated value automatically and the expression rides xdata
/// (EAB natively; DXF via the ZEPHYR_FIELD appID records).
///
/// Codes: `$DATE` (ISO local date), `$FILENAME` (opening file name),
/// `$TABNAME` (opening view name), `$AREA:<uuid>`, `$LENGTH:<uuid>`
/// (InquiryMath over the referenced entity, LUPREC formatting).
/// Unresolvable expressions keep their last text and report.
/// Layout/tab codes need the open-time identity `finalizeOpen` records;
/// without an open behind the document they report `<no file>`/`<no layout>`.
/// Regen-time re-evaluation is out of scope: fields refresh at FIELD time
/// and on open, never silently mid-session.
public enum FieldEval {

    public static let exprKey = "field.expr"
    public static let dxfAppID = "ZEPHYR_FIELD"

    /// Evaluates an expression against a document. Nil when the expression
    /// is unknown or its target is missing/unsupported.
    public static func evaluate(
        _ expression: String, in document: CADDocument
    ) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$") else { return nil }
        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard let rawName = parts.first else { return nil }
        switch rawName.uppercased() {
        case "DATE":
            return isoDate()
        case "FILENAME":
            return document.sourceFileName ?? "<no file>"
        case "TABNAME":
            return document.layoutName ?? "<no layout>"
        case "AREA":
            guard parts.count == 2,
                  let id = UUID(uuidString: parts[1]),
                  let entity = document.entity(for: id),
                  let area = InquiryMath.entityArea(entity) else {
                return nil
            }
            return InquiryMath.formatLength(area, precision: document.lengthPrecision)
        case "LENGTH":
            guard parts.count == 2,
                  let id = UUID(uuidString: parts[1]),
                  let entity = document.entity(for: id),
                  let length = InquiryMath.entityLength(entity) else {
                return nil
            }
            return InquiryMath.formatLength(length, precision: document.lengthPrecision)
        default:
            return nil
        }
    }

    /// Local ISO calendar date (YYYY-MM-DD), locale-independent.
    public static func isoDate(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// FIELD: insert a live-updating value as a single-line text entity, or
/// re-evaluate the field expression carried by the selected text entity.
@MainActor
public final class FieldCommand: FeatureCommand {

    private enum Phase {
        case code
        case pickObject
        case pickInsertion
    }

    private var phase = Phase.code
    private var code = ""
    private var targetHandle = UUID()
    private var insertPoint = Vector3(x: 0, y: 0, z: 0)

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .code
        code = ""
        // Adopt a selected field carrier for an in-place refresh.
        let handles = engine.cadSelection.selectedHandles
        if handles.count == 1,
           let first = handles.first,
           let entity = engine.document.entity(for: first),
           case .string(let expr) = entity.xdata[FieldEval.exprKey],
           let value = FieldEval.evaluate(expr, in: engine.document) {
            refresh(entity: entity, value: value, engine: engine)
            processor.commandPrompt = "Field updated: \(value)."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        processor.commandPrompt = "Field code [Date/Filename/Tabname/Area/Length]:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let picked = engine.snap.currentSnapResult?.worldPos
            ?? Vector3(x: worldX, y: worldY, z: 0)
        switch phase {
        case .code:
            return .continue
        case .pickObject:
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom)
            guard let handle = hitHandle,
                  engine.document.entity(for: handle) != nil else {
                processor.commandPrompt = "No object there. Select object for field:"
                return .continue
            }
            targetHandle = handle
            code += handle.uuidString
            phase = .pickInsertion
            processor.commandPrompt = "Specify insertion point:"
            return .continue
        case .pickInsertion:
            insertPoint = picked
            insert(engine: engine, processor: processor)
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .code else { return .continue }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "D", "DATE":
            code = "$DATE"
            phase = .pickInsertion
            processor.commandPrompt = "Specify insertion point:"
            return .continue
        case "F", "FILENAME":
            code = "$FILENAME"
            phase = .pickInsertion
            processor.commandPrompt = "Specify insertion point:"
            return .continue
        case "T", "TABNAME":
            code = "$TABNAME"
            phase = .pickInsertion
            processor.commandPrompt = "Specify insertion point:"
            return .continue
        case "A", "AREA":
            code = "$AREA:"
            phase = .pickObject
            processor.commandPrompt = "Select object for field:"
            return .continue
        case "L", "LENGTH":
            code = "$LENGTH:"
            phase = .pickObject
            processor.commandPrompt = "Select object for field:"
            return .continue
        default:
            processor.commandPrompt = "Field code [Date/Filename/Tabname/Area/Length]:"
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func insert(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard let value = FieldEval.evaluate(code, in: engine.document) else {
            processor.commandPrompt = "Field target missing or unsupported; nothing inserted."
            return
        }
        let style = engine.document.textStyle(named: "Standard") ?? .standard
        var entity = TextCommand.makeTextEntity(
            text: value,
            styleName: style.name,
            fontName: style.fontFile,
            height: style.fixedHeight > 0 ? style.fixedHeight : 2.5,
            rotation: 0,
            alignH: 0,
            alignV: 0,
            mtextWidth: 0,
            insertPos: insertPoint,
            layerID: engine.document.activeLayerID ?? UUID())
        entity.xdata[FieldEval.exprKey] = .string(code)
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        let message = "Field inserted: \(value)."
        print("[FIELD] \(message)")
        processor.commandPrompt = message
    }

    private func refresh(entity: CADEntity, value: String, engine: PhrostEngine) {
        guard var geom = entity.localGeometry else { return }
        for i in 0..<geom.count {
            guard case .text(
                let pos, _, let height, let rotation, let style,
                let alignH, let alignV, let mtextWidth, let color) = geom[i] else {
                continue
            }
            geom[i] = .text(
                position: pos, text: value, height: height, rotation: rotation,
                style: style, alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth, color: color)
            break
        }
        var updated = entity
        updated.localGeometry = geom
        updated.xdata["dxf.text"] = .string(value)
        let before = engine.document.snapshot()
        engine.document.updateEntityLive(updated)
        engine.document.invalidateEntityGrid()
        engine.document.pushUndo(before)
        engine.tabManager.markActiveDirty()
        print("[FIELD] Field updated: \(value).")
    }
}

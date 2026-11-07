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
    /// Sheet-set expressions (`%<\AcSm Sheet.Number>%` and friends)
    /// resolved against the open sets. Falls back to `$` evaluation;
    /// unknown or unresolvable expressions return nil so callers keep
    /// the cached text.
    public static func evaluate(
        _ expression: String, in document: CADDocument, store: SheetSetStore
    ) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") { return evaluate(trimmed, in: document) }
        guard let (field, format) = parseAcSmField(trimmed) else { return nil }
        guard let (set, sheet) = store.sheetContext(
            documentFile: document.sourceFileName,
            layoutName: document.layoutName) else { return nil }
        let raw: String?
        switch field {
        case .sheetNumber: raw = sheet.number
        case .sheetTitle: raw = sheet.title
        case .sheetDescription: raw = sheet.description
        case .sheetSetName: raw = set.name
        case .sheetSetDescription: raw = set.description
        case .sheetCustom(let name):
            raw = sheet.custom.first {
                $0.key.caseInsensitiveCompare(name) == .orderedSame
            }?.value
        case .setCustom(let name):
            raw = set.customSetProps.first {
                $0.key.caseInsensitiveCompare(name) == .orderedSame
            }?.value
        }
        guard let raw else { return nil }
        return applyFieldFormat(format, to: raw)
    }

    private enum AcSmField {
        case sheetNumber, sheetTitle, sheetDescription
        case sheetSetName, sheetSetDescription
        case sheetCustom(String), setCustom(String)
    }

    /// Parses `%<\AcSm <Category>.<Name>>%` with an optional LT `\f`
    /// format suffix (`\f "%tc1"` etc.). Returns the field plus the raw
    /// format string (nil when absent). Category match is
    /// case-insensitive; `Database.*` has no verified meaning here and
    /// is rejected.
    private static func parseAcSmField(_ expression: String) -> (AcSmField, String?)? {
        // Real syntax: `%<\AcSm Sheet.Number>%` — backslash-AcSm, space,
        // then Category.Name. Anything else (including dot-joined
        // `AcSm.Sheet.X`) is rejected.
        var body = expression
        guard body.hasPrefix("%<"), body.hasSuffix(">%") else { return nil }
        body = String(body.dropFirst(2).dropLast(2))
        var format: String? = nil
        if let fRange = body.range(of: "\\f") {
            format = String(body[fRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(body[..<fRange.lowerBound])
        }
        let rest = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.prefix(5).caseInsensitiveCompare("\\AcSm") == .orderedSame else { return nil }
        let after = rest.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = after.firstIndex(of: ".") else { return nil }
        let category = String(after[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(after[after.index(after: dot)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty, !name.isEmpty else { return nil }
        if category.caseInsensitiveCompare("Sheet") == .orderedSame {
            switch name.uppercased() {
            case "NUMBER": return (.sheetNumber, format)
            case "TITLE": return (.sheetTitle, format)
            case "DESCRIPTION", "DESC": return (.sheetDescription, format)
            default: return (.sheetCustom(name), format)
            }
        }
        if category.caseInsensitiveCompare("SheetSet") == .orderedSame {
            switch name.uppercased() {
            case "NAME": return (.sheetSetName, format)
            case "DESCRIPTION", "DESC": return (.sheetSetDescription, format)
            default: return (.setCustom(name), format)
            }
        }
        return nil
    }

    /// LT text-case format codes inside an `\f` suffix (public field-format
    /// documentation, corroborated by two independent sources: Autodesk
    /// forums `%tc1` UPPERCASE / `%tc2` lowercase / `%tc3` First capital /
    /// `%tc4` Title case, and matching TC1–TC4 tables). Only the first
    /// recognized code applies; anything else leaves the value unchanged.
    /// Conservative by design: `%tc3`/`%tc4` touch first letters only and
    /// never re-case the rest of a word.
    private static func applyFieldFormat(_ format: String?, to value: String) -> String {
        guard var format, !format.isEmpty else { return value }
        if format.hasPrefix("\""), format.hasSuffix("\""), format.count >= 2 {
            format = String(format.dropFirst().dropLast())
        }
        let upper = format.uppercased()
        guard let range = upper.range(of: "%TC1") ?? upper.range(of: "%TC2")
            ?? upper.range(of: "%TC3") ?? upper.range(of: "%TC4") else { return value }
        switch String(upper[range]) {
        case "%TC1": return value.uppercased()
        case "%TC2": return value.lowercased()
        case "%TC3": return firstCapitalized(value)
        default: return titleCased(value)
        }
    }

    /// Uppercase the first letter, leave everything else untouched.
    private static func firstCapitalized(_ value: String) -> String {
        guard let idx = value.firstIndex(where: { $0.isLetter }) else { return value }
        var out = value
        out.replaceSubrange(idx...idx, with: String(value[idx]).uppercased())
        return out
    }

    /// Uppercase the first letter of each whitespace-separated word,
    /// leave everything else untouched.
    private static func titleCased(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var atWordStart = true
        for ch in value {
            if ch.isWhitespace {
                atWordStart = true
                result.append(ch)
            } else if atWordStart, ch.isLetter {
                result += String(ch).uppercased()
                atWordStart = false
            } else {
                atWordStart = false
                result.append(ch)
            }
        }
        return result
    }

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
        case sheetCode
        case sheetCustomName
        case pickObject
        case pickInsertion
    }

    private var phase = Phase.code
    private var code = ""
    private var customScopeIsSet = false
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
           let value = FieldEval.evaluate(expr, in: engine.document, store: processor.sheetSetStore) {
            refresh(entity: entity, value: value, engine: engine)
            processor.commandPrompt = "Field updated: \(value)."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        processor.commandPrompt = "Field code [Date/Filename/Tabname/Area/Length/Sheet]:"
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
        case .code, .sheetCode, .sheetCustomName:
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
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if phase == .sheetCode {
            switch word.uppercased() {
            case "N", "NUMBER":
                code = "%<\\AcSm Sheet.Number>%"
            case "T", "TITLE":
                code = "%<\\AcSm Sheet.Title>%"
            case "D", "DESCRIPTION", "DESC":
                code = "%<\\AcSm Sheet.Description>%"
            case "SN", "SETNAME":
                code = "%<\\AcSm SheetSet.Name>%"
            case "SD", "SETDESC":
                code = "%<\\AcSm SheetSet.Description>%"
            case "C", "CUSTOM":
                customScopeIsSet = false
                phase = .sheetCustomName
                processor.commandPrompt = "Sheet custom property name:"
                return .continue
            case "SC", "SETCUSTOM":
                customScopeIsSet = true
                phase = .sheetCustomName
                processor.commandPrompt = "Set custom property name:"
                return .continue
            default:
                processor.commandPrompt = "Sheet field [Number/Title/Description/Setname/Setdesc/Custom/Setcustom]:"
                return .continue
            }
            phase = .pickInsertion
            processor.commandPrompt = "Specify insertion point:"
            return .continue
        }
        if phase == .sheetCustomName {
            guard !word.isEmpty else {
                processor.commandPrompt = "Custom property name:"
                return .continue
            }
            code = customScopeIsSet
                ? "%<\\AcSm SheetSet.\(word)>%"
                : "%<\\AcSm Sheet.\(word)>%"
            phase = .pickInsertion
            processor.commandPrompt = "Specify insertion point:"
            return .continue
        }
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
        case "S", "SHEET":
            phase = .sheetCode
            processor.commandPrompt = "Sheet field [Number/Title/Description/Setname/Setdesc/Custom/Setcustom]:"
            return .continue
        default:
            processor.commandPrompt = "Field code [Date/Filename/Tabname/Area/Length/Sheet]:"
            return .continue
        }
    }

    /// Chips for the field-code question (`.code`) and the sheet-field
    /// follow-up (`.sheetCode`); other phases take free input or picks.
    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        switch phase {
        case .code:
            return [
                FeatureCommandTextOption(value: "Date", title: "Date", aliases: ["D"], description: "Current date field"),
                FeatureCommandTextOption(value: "Filename", title: "Filename", aliases: ["F"], description: "Drawing filename field"),
                FeatureCommandTextOption(value: "Tabname", title: "Tabname", aliases: ["T"], description: "Layout tab name field"),
                FeatureCommandTextOption(value: "Area", title: "Area", aliases: ["A"], description: "Area of a picked object"),
                FeatureCommandTextOption(value: "Length", title: "Length", aliases: ["L"], description: "Length of a picked object"),
                FeatureCommandTextOption(value: "Sheet", title: "Sheet", aliases: ["S"], description: "Sheet-set field"),
            ].filter { $0.matches(input) }
        case .sheetCode:
            return [
                FeatureCommandTextOption(value: "Number", title: "Number", aliases: ["N"], description: "Sheet number"),
                FeatureCommandTextOption(value: "Title", title: "Title", aliases: ["T"], description: "Sheet title"),
                FeatureCommandTextOption(value: "Description", title: "Description", aliases: ["D", "DESC"], description: "Sheet description"),
                FeatureCommandTextOption(value: "Setname", title: "Setname", aliases: ["SN"], description: "Sheet-set name"),
                FeatureCommandTextOption(value: "Setdesc", title: "Setdesc", aliases: ["SD"], description: "Sheet-set description"),
                FeatureCommandTextOption(value: "Custom", title: "Custom", aliases: ["C"], description: "Custom sheet property"),
                FeatureCommandTextOption(value: "Setcustom", title: "Setcustom", aliases: ["SC"], description: "Custom sheet-set property"),
            ].filter { $0.matches(input) }
        default:
            return []
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func insert(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard let value = FieldEval.evaluate(code, in: engine.document, store: processor.sheetSetStore) else {
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

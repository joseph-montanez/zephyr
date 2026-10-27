// Sources/ZephyrCore/Commands/FindCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// FIND, Phase 2.1: command-line search and replace across entity-level
/// TEXT/MTEXT strings (including ATTRIB/ATTDEF `.text` primitives, which
/// import as entities), multileader text and block-attribute strings, and
/// TABLE string cells. Dimension text overrides are out of scope; shared
/// block-definition ATTDEF templates are out of scope (editing a shared
/// definition from FIND would surprise every insert).
///
/// Flow is the FIND dialog flattened to the command line: find string,
/// replace string (empty = find-only), case and whole-word options, then a
/// per-match walk with zoom-to. Replace decisions collect during the walk
/// and apply at the end in ONE undo entry (snapshot-before pattern from
/// LeaderCommands): per-match Yes, No, All, or Done.
@MainActor
public final class FindCommand: FeatureCommand {

    public struct Options {
        var caseSensitive = false
        var wholeWord = false
    }

    public enum MatchKind {
        case textPrim(index: Int)
        case leaderText
        case leaderAttribute(index: Int)
        case tableCell(row: Int, col: Int)
    }

    public struct Match {
        var handle: UUID
        var kind: MatchKind
        var sourceLabel: String
    }

    private enum Phase {
        case findString
        case replaceString
        case caseOption
        case wholeWordOption
        case review
    }

    private var phase = Phase.findString
    private var findText = ""
    private var replaceText = ""
    private var options = Options()
    private var matches: [Match] = []
    private var cursor = 0
    private var replaceAll = false
    private var marked: Set<Int> = []

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .findString
        findText = ""
        replaceText = ""
        options = Options()
        matches = []
        cursor = 0
        replaceAll = false
        marked = []
        processor.commandPrompt = "Find what:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
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
            if phase == .review { applyCollected(engine: engine, processor: processor) }
            return .finished
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return handleCommandText("", engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .findString:
            guard !trimmed.isEmpty else {
                processor.commandPrompt = "Find what:"
                return .continue
            }
            findText = trimmed
            phase = .replaceString
            processor.commandPrompt = "Replace with (Enter for find-only):"
            return .continue

        case .replaceString:
            replaceText = text.trimmingCharacters(in: .newlines)
            phase = .caseOption
            processor.commandPrompt = "Case-sensitive? [Yes/No] <No>:"
            return .continue

        case .caseOption:
            options.caseSensitive = trimmed.uppercased() == "Y" || trimmed.uppercased() == "YES"
            phase = .wholeWordOption
            processor.commandPrompt = "Whole word? [Yes/No] <No>:"
            return .continue

        case .wholeWordOption:
            options.wholeWord = trimmed.uppercased() == "Y" || trimmed.uppercased() == "YES"
            beginReview(engine: engine, processor: processor)
            return .continue

        case .review:
            return reviewInput(trimmed, engine: engine, processor: processor)
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure search/replace (nonisolated: no actor state, test-callable)

    /// All non-overlapping match ranges, in order.
    nonisolated static func ranges(
        in subject: String, find: String, options: Options
    ) -> [Range<String.Index>] {
        guard !find.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = subject.startIndex
        let compare: String.CompareOptions = options.caseSensitive ? [] : .caseInsensitive
        while from < subject.endIndex,
              let range = subject.range(
                  of: find, options: compare,
                  range: from..<subject.endIndex) {
            if options.wholeWord {
                let beforeOK = range.lowerBound == subject.startIndex
                    || !isWordChar(subject[subject.index(before: range.lowerBound)])
                let afterOK = range.upperBound == subject.endIndex
                    || !isWordChar(subject[range.upperBound])
                if beforeOK && afterOK { out.append(range) }
            } else {
                out.append(range)
            }
            from = range.upperBound
            if range.isEmpty { break }
        }
        return out
    }

    nonisolated static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Returns the replaced string plus the number of replacements.
    nonisolated static func replacing(
        _ subject: String, find: String, with replacement: String, options: Options
    ) -> (String, Int) {
        let hits = ranges(in: subject, find: find, options: options)
        guard !hits.isEmpty else { return (subject, 0) }
        var result = ""
        var cursor = subject.startIndex
        for hit in hits {
            result += subject[cursor..<hit.lowerBound]
            result += replacement
            cursor = hit.upperBound
        }
        result += subject[cursor...]
        return (result, hits.count)
    }

    /// Short context around the first match for prompt display.
    nonisolated static func preview(
        _ subject: String, find: String, options: Options, radius: Int = 20
    ) -> String {
        guard let first = ranges(in: subject, find: find, options: options).first else {
            return String(subject.prefix(40))
        }
        let lo = subject.index(
            first.lowerBound, offsetBy: -radius, limitedBy: subject.startIndex)
            ?? subject.startIndex
        let hi = subject.index(
            first.upperBound, offsetBy: radius, limitedBy: subject.endIndex)
            ?? subject.endIndex
        return (lo > subject.startIndex ? "..." : "") + subject[lo..<hi]
            + (hi < subject.endIndex ? "..." : "")
    }

    // MARK: - Private

    private func stringForMatch(_ match: Match, engine: PhrostEngine) -> String? {
        guard let entity = engine.document.entity(for: match.handle) else { return nil }
        switch match.kind {
        case .textPrim(let index):
            guard let geom = entity.localGeometry,
                  geom.indices.contains(index),
                  case .text(_, let text, _, _, _, _, _, _, _) = geom[index] else {
                return nil
            }
            return text
        case .leaderText:
            return entity.leaderData?.value.text
        case .leaderAttribute(let index):
            guard let attrs = entity.leaderData?.value.blockAttributes,
                  attrs.indices.contains(index) else {
                return nil
            }
            return attrs[index].text
        case .tableCell(let row, let col):
            return tableCellString(entity: entity, row: row, col: col)
        }
    }

    private func tableCellString(entity: CADEntity, row: Int, col: Int) -> String? {
        guard let geom = entity.localGeometry else { return nil }
        for prim in geom {
            guard case .table(let data, _, _) = prim,
                  data.rows.indices.contains(row),
                  data.rows[row].cells.indices.contains(col),
                  case .string(let value) = data.rows[row].cells[col].value else {
                continue
            }
            return value
        }
        return nil
    }

    private func collectMatches(engine: PhrostEngine) {
        matches = []
        let entities = engine.document.allEntities.sorted {
            $0.handle.uuidString < $1.handle.uuidString
        }
        for entity in entities {
            if let geom = entity.localGeometry {
                for (index, prim) in geom.enumerated() {
                    switch prim {
                    case .text(_, let text, _, _, _, _, _, _, _):
                        if !Self.ranges(in: text, find: findText, options: options).isEmpty {
                            matches.append(Match(
                                handle: entity.handle,
                                kind: .textPrim(index: index),
                                sourceLabel: "TEXT"))
                        }
                    case .table(let data, _, _):
                        for (r, row) in data.rows.enumerated() {
                            for (c, cell) in row.cells.enumerated() {
                                guard case .string(let value) = cell.value,
                                      !Self.ranges(
                                          in: value, find: findText,
                                          options: options).isEmpty else {
                                    continue
                                }
                                matches.append(Match(
                                    handle: entity.handle,
                                    kind: .tableCell(row: r, col: c),
                                    sourceLabel: "TABLE"))
                            }
                        }
                    default:
                        break
                    }
                }
            }
            if let leader = entity.leaderData?.value {
                if !Self.ranges(in: leader.text, find: findText, options: options).isEmpty {
                    matches.append(Match(
                        handle: entity.handle, kind: .leaderText,
                        sourceLabel: "MLEADER"))
                }
                if let attrs = leader.blockAttributes {
                    for (index, attr) in attrs.enumerated() {
                        if !Self.ranges(
                            in: attr.text, find: findText,
                            options: options).isEmpty {
                            matches.append(Match(
                                handle: entity.handle,
                                kind: .leaderAttribute(index: index),
                                sourceLabel: "MLEADER-ATTR"))
                        }
                    }
                }
            }
        }
    }

    private func beginReview(engine: PhrostEngine, processor: CADCommandProcessor) {
        collectMatches(engine: engine)
        cursor = 0
        replaceAll = false
        marked = []
        guard !matches.isEmpty else {
            processor.commandPrompt = "No matches found."
            phase = .findString
            return
        }
        phase = .review
        zoomToCursor(engine: engine)
        processor.commandPrompt = reviewPrompt(engine: engine)
    }

    private func zoomToCursor(engine: PhrostEngine) {
        guard matches.indices.contains(cursor),
              let entity = engine.document.entity(for: matches[cursor].handle),
              let bb = entity.worldBoundingBox else {
            return
        }
        engine.camera.pushViewState()
        engine.camera.offset = (
            (bb.min.x + bb.max.x) / 2.0,
            (bb.min.y + bb.max.y) / 2.0)
    }

    private func reviewPrompt(engine: PhrostEngine) -> String {
        guard matches.indices.contains(cursor),
              let current = stringForMatch(matches[cursor], engine: engine) else {
            return "Match changed; ending review."
        }
        let context = Self.preview(current, find: findText, options: options)
        let head = "Match \(cursor + 1)/\(matches.count)"
            + " [\(matches[cursor].sourceLabel)]: \(context)"
        if replaceText.isEmpty {
            return head + " (Enter for next, Esc to finish):"
        }
        return head + " Replace? [Yes/No/All/Done]:"
    }

    private func reviewInput(
        _ trimmed: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard matches.indices.contains(cursor) else {
            applyCollected(engine: engine, processor: processor)
            return .finished
        }
        guard stringForMatch(matches[cursor], engine: engine) != nil else {
            // Entity changed under review; skip the stale match.
            return advance(engine: engine, processor: processor)
        }
        if replaceText.isEmpty {
            if trimmed.uppercased() == "DONE" {
                return .finished
            }
            return advance(engine: engine, processor: processor)
        }
        switch trimmed.uppercased() {
        case "Y", "YES":
            marked.insert(cursor)
            return advance(engine: engine, processor: processor)
        case "N", "NO":
            return advance(engine: engine, processor: processor)
        case "A", "ALL":
            for i in cursor..<matches.count { marked.insert(i) }
            applyCollected(engine: engine, processor: processor)
            return .finished
        case "D", "DONE":
            applyCollected(engine: engine, processor: processor)
            return .finished
        default:
            processor.commandPrompt = reviewPrompt(engine: engine)
            return .continue
        }
    }

    private func advance(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        cursor += 1
        if cursor >= matches.count {
            applyCollected(engine: engine, processor: processor)
            return .finished
        }
        zoomToCursor(engine: engine)
        processor.commandPrompt = reviewPrompt(engine: engine)
        return .continue
    }

    private func applyCollected(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard !marked.isEmpty else {
            if !replaceText.isEmpty {
                processor.commandPrompt = "No replacements made."
            }
            return
        }
        let before = engine.document.snapshot()
        var replacedOccurrences = 0
        var touchedEntities = Set<UUID>()
        for index in marked.sorted() {
            guard matches.indices.contains(index) else { continue }
            let match = matches[index]
            guard let entity = engine.document.entity(for: match.handle) else { continue }
            let (updated, count) = applyReplacement(
                to: entity, match: match, engine: engine)
            guard count > 0, let updated else { continue }
            replacedOccurrences += count
            touchedEntities.insert(match.handle)
            engine.document.updateEntityLive(updated)
        }
        engine.document.invalidateEntityGrid()
        engine.document.pushUndo(before)
        engine.tabManager.markActiveDirty()
        let message = "Replaced \(replacedOccurrences) occurrence(s)"
            + " in \(touchedEntities.count) entit\(touchedEntities.count == 1 ? "y" : "ies")"
            + " (one undo entry)."
        print("[FIND] \(message)")
        processor.commandPrompt = message
    }

    /// Returns the mutated entity plus replaced-occurrence count.
    private func applyReplacement(
        to entity: CADEntity, match: Match, engine: PhrostEngine
    ) -> (CADEntity?, Int) {
        var updated = entity
        switch match.kind {
        case .textPrim(let index):
            guard var geom = updated.localGeometry,
                  geom.indices.contains(index),
                  case .text(
                      let pos, let text, let height, let rotation, let style,
                      let alignH, let alignV, let mtextWidth, let color) = geom[index] else {
                return (nil, 0)
            }
            let (next, count) = Self.replacing(
                text, find: findText, with: replaceText, options: options)
            guard count > 0 else { return (nil, 0) }
            geom[index] = .text(
                position: pos, text: next, height: height, rotation: rotation,
                style: style, alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth, color: color)
            updated.localGeometry = geom
            updated.xdata["dxf.text"] = .string(next)
            return (updated, count)

        case .leaderText:
            guard var data = updated.leaderData?.value else { return (nil, 0) }
            let (next, count) = Self.replacing(
                data.text, find: findText, with: replaceText, options: options)
            guard count > 0 else { return (nil, 0) }
            data.text = next
            updated.leaderData = CADLeaderDataBox(data)
            updated = engine.document.regeneratedLeaderEntity(updated)
            return (updated, count)

        case .leaderAttribute(let index):
            guard var data = updated.leaderData?.value,
                  var attrs = data.blockAttributes,
                  attrs.indices.contains(index) else {
                return (nil, 0)
            }
            let (next, count) = Self.replacing(
                attrs[index].text, find: findText, with: replaceText,
                options: options)
            guard count > 0 else { return (nil, 0) }
            attrs[index].text = next
            data.blockAttributes = attrs
            updated.leaderData = CADLeaderDataBox(data)
            updated = engine.document.regeneratedLeaderEntity(updated)
            return (updated, count)

        case .tableCell(let row, let col):
            guard var geom = updated.localGeometry else { return (nil, 0) }
            var count = 0
            for i in 0..<geom.count {
                guard case .table(var data, let origin, let color) = geom[i],
                      data.rows.indices.contains(row),
                      data.rows[row].cells.indices.contains(col),
                      case .string(let value) = data.rows[row].cells[col].value else {
                    continue
                }
                let (next, cellCount) = Self.replacing(
                    value, find: findText, with: replaceText, options: options)
                guard cellCount > 0 else { continue }
                data.rows[row].cells[col].value = .string(next)
                geom[i] = .table(data: data, origin: origin, color: color)
                count += cellCount
            }
            guard count > 0 else { return (nil, 0) }
            updated.localGeometry = geom
            return (updated, count)
        }
    }
}

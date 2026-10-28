// Sources/ZephyrCore/Commands/AuditCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// AUDIT and RECOVER, Phase 2.2d: drawing validation with safe fixes plus
/// open-with-audit recovery.
///
/// `AuditEngine` is the pure validation/fix core shared by both commands:
/// - `validate(document:)` scans every entity for dangling references
///   (missing layer, missing block, missing dim/leader/text style), empty
///   geometry, and non-finite coordinates. Style lookups are
///   case-insensitive so the stock "STANDARD" rows always resolve.
/// - `applyFixes(report:to:)` applies the safe fixes through a single
///   `replaceEntities` batch, which is exactly one undo entry:
///   missing layers move to "0", missing styles rewrite to "Standard",
///   and entities whose geometry is unrecoverable (dangling block, empty
///   or non-finite geometry) are removed.
///
/// AUDIT reports the validation, confirms fixes (LT "Fix any errors
/// detected?"), then offers the -P audit-purge sweep by reusing the 2.2c
/// `purgeableDefinitions`/`applyPurge` pair. RECOVER prompts for a drawing
/// file, opens it in a new tab, routes DXF files through `DXFReader`
/// diagnostics (version, pair and unknown-type counts), then validates and
/// auto-applies the safe fixes like LT RECOVER.
public enum AuditIssueKind: String, CaseIterable, Sendable {
    case missingLayer
    case danglingBlock
    case missingDimStyle
    case missingLeaderStyle
    case missingTextStyle
    case emptyGeometry
    case nonFiniteGeometry

    /// Issues of these kinds delete the entity; the rest rewrite it.
    var isDeletion: Bool {
        switch self {
        case .danglingBlock, .emptyGeometry, .nonFiniteGeometry:
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .missingLayer: return "missing layer"
        case .danglingBlock: return "dangling block reference"
        case .missingDimStyle: return "missing dimension style"
        case .missingLeaderStyle: return "missing leader style"
        case .missingTextStyle: return "missing text style"
        case .emptyGeometry: return "empty geometry"
        case .nonFiniteGeometry: return "non-finite geometry"
        }
    }
}

public struct AuditIssue: Sendable {
    public var kind: AuditIssueKind
    public var entityID: UUID?
    public var detail: String
}

public struct AuditReport: Sendable {
    public var issues: [AuditIssue]

    public var errorCount: Int { issues.count }

    public func count(for kind: AuditIssueKind) -> Int {
        issues.filter { $0.kind == kind }.count
    }

    /// One-line per-kind breakdown, e.g. "2 missing layer, 1 dangling block".
    public var breakdown: String {
        AuditIssueKind.allCases.compactMap { kind in
            let count = count(for: kind)
            return count > 0 ? "\(count) \(kind.label)" : nil
        }.joined(separator: ", ")
    }
}

@MainActor
public enum AuditEngine {

    public static func validate(document: CADDocument) -> AuditReport {
        var issues: [AuditIssue] = []
        for entity in document.allEntities {
            if document.layer(for: entity.layerID) == nil {
                issues.append(AuditIssue(
                    kind: .missingLayer, entityID: entity.handle,
                    detail: "Entity references a layer that no longer exists."))
            }
            if let blockID = entity.blockID,
               document.block(for: blockID) == nil {
                issues.append(AuditIssue(
                    kind: .danglingBlock, entityID: entity.handle,
                    detail: "Entity references block \(blockID) which no longer exists."))
            }
            if let styleName = entity.dimensionMetadata?.value.styleName,
               !contains(styleName, in: document.dimensionStyles.keys) {
                issues.append(AuditIssue(
                    kind: .missingDimStyle, entityID: entity.handle,
                    detail: "Dimension style '\(styleName)' is not defined."))
            }
            if let styleName = entity.leaderData?.value.styleName,
               !contains(styleName, in: document.leaderStyles.keys) {
                issues.append(AuditIssue(
                    kind: .missingLeaderStyle, entityID: entity.handle,
                    detail: "Leader style '\(styleName)' is not defined."))
            }
            let prims = entity.localGeometry ?? []
            var flaggedTextStyle = false
            for prim in prims {
                if case .text(_, _, _, _, let styleOpt, _, _, _, _) = prim,
                   !flaggedTextStyle,
                   let style = styleOpt,
                   !contains(style, in: document.textStyles.keys) {
                    flaggedTextStyle = true
                    issues.append(AuditIssue(
                        kind: .missingTextStyle, entityID: entity.handle,
                        detail: "Text style '\(style)' is not defined."))
                }
            }
            if case .string(let style) = entity.xdata["dxf.textStyle"],
               !flaggedTextStyle,
               !contains(style, in: document.textStyles.keys) {
                issues.append(AuditIssue(
                    kind: .missingTextStyle, entityID: entity.handle,
                    detail: "Text style '\(style)' is not defined."))
            }
            if prims.isEmpty && entity.blockID == nil
                && entity.dimensionMetadata == nil && entity.leaderData == nil {
                issues.append(AuditIssue(
                    kind: .emptyGeometry, entityID: entity.handle,
                    detail: "Entity carries no geometry and no block reference."))
            } else if !prims.isEmpty {
                let box = CADBlock.computeBoundingBox(from: prims)
                if !isFinite(box.min) || !isFinite(box.max) {
                    issues.append(AuditIssue(
                        kind: .nonFiniteGeometry, entityID: entity.handle,
                        detail: "Entity geometry contains NaN or infinite coordinates."))
                }
            }
        }
        return AuditReport(issues: issues)
    }

    /// Applies every safe fix in one `replaceEntities` batch (one undo).
    /// - Returns: number of entities fixed or removed.
    @discardableResult
    public static func applyFixes(
        report: AuditReport, to document: CADDocument
    ) -> Int {
        let doomed = Set(report.issues.filter(\.kind.isDeletion)
            .compactMap(\.entityID))
        guard let zeroID = document.findLayer(named: "0")?.handle else {
            return 0
        }
        // Group rewrite issues per entity so one entity with several
        // problems (e.g. missing layer *and* missing text style) gets every
        // applicable fix. Deletions always win over rewrites.
        var updatesByID: [UUID: CADEntity] = [:]
        var order: [UUID] = []
        for issue in report.issues {
            guard let id = issue.entityID, !doomed.contains(id) else { continue }
            if updatesByID[id] == nil {
                guard let entity = document.entity(for: id) else { continue }
                updatesByID[id] = entity
                order.append(id)
            }
            guard var entity = updatesByID[id] else { continue }
            switch issue.kind {
            case .missingLayer:
                entity.layerID = zeroID
            case .missingDimStyle:
                guard let metadata = entity.dimensionMetadata?.value else { continue }
                var pointed = metadata.withStyleName("Standard")
                pointed.styleOverrides = nil
                entity.dimensionMetadata = CADDimensionMetadataBox(pointed)
            case .missingLeaderStyle:
                guard var leader = entity.leaderData?.value else { continue }
                leader.styleName = "Standard"
                entity.leaderData = CADLeaderDataBox(leader)
            case .missingTextStyle:
                entity.localGeometry = (entity.localGeometry ?? []).map { prim in
                    guard case .text(let pos, let text, let height, let rotation,
                                     let styleOpt, let ah, let av, let width, let color) = prim,
                          let style = styleOpt,
                          !contains(style, in: document.textStyles.keys)
                    else { return prim }
                    return .text(position: pos, text: text, height: height,
                                 rotation: rotation, style: "Standard",
                                 alignH: ah, alignV: av, mtextWidth: width, color: color)
                }
                if case .string(let style) = entity.xdata["dxf.textStyle"],
                   !contains(style, in: document.textStyles.keys) {
                    entity.xdata["dxf.textStyle"] = .string("Standard")
                }
            case .danglingBlock, .emptyGeometry, .nonFiniteGeometry:
                continue
            }
            updatesByID[id] = entity
        }
        let updates = order.compactMap { updatesByID[$0] }
        document.replaceEntities(remove: doomed, add: updates)
        return doomed.count + updates.count
    }

    // MARK: - Private

    private static func contains<Keys: Sequence>(
        _ name: String, in keys: Keys
    ) -> Bool where Keys.Element == String {
        keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func isFinite(_ point: Vector3) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}

/// AUDIT command: validates the current drawing, confirms safe fixes, then
/// offers the audit-purge sweep over unused definitions.
@MainActor
public final class AuditCommand: FeatureCommand {

    private enum Step {
        case fix
        case purge
    }

    private var report: AuditReport?
    private var purgeReport: PurgeReport?
    private var step: Step = .fix

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let found = AuditEngine.validate(document: engine.document)
        guard found.errorCount > 0 else {
            offerPurge(engine: engine, processor: processor,
                       prefix: "Audit complete: no errors found.")
            return
        }
        report = found
        step = .fix
        processor.commandPrompt =
            "Audit found \(found.errorCount) errors (\(found.breakdown)). " +
            "Fix any errors detected? [Yes/No] <No>:"
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
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch step {
        case .fix:
            guard let found = report else { return .finished }
            let prefix: String
            if answer == "Y" || answer == "YES" {
                let fixed = AuditEngine.applyFixes(
                    report: found, to: engine.document)
                engine.tabManager.markActiveDirty()
                prefix = "Fixed \(fixed) of \(found.errorCount) errors."
            } else {
                prefix = "Audit found \(found.errorCount) errors; nothing fixed."
            }
            let awaitingPurge = offerPurge(
                engine: engine, processor: processor, prefix: prefix)
            return awaitingPurge ? .continue : .finished
        case .purge:
            guard let found = purgeReport else { return .finished }
            if answer == "Y" || answer == "YES" {
                let removed = engine.document.applyPurge(found)
                let total = removed.values.reduce(0, +)
                engine.tabManager.markActiveDirty()
                processor.commandPrompt =
                    "Purged \(total) unused definition\(total == 1 ? "" : "s")."
            } else {
                processor.commandPrompt = "Purge skipped; nothing removed."
            }
            purgeReport = nil
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    /// - Returns: true when a purge question is now pending.
    @discardableResult
    private func offerPurge(
        engine: PhrostEngine, processor: CADCommandProcessor, prefix: String
    ) -> Bool {
        let found = engine.document.purgeableDefinitions(
            currentTextStyle: Self.currentTextStyle(
                engine: engine, processor: processor))
        guard found.total > 0 else {
            processor.commandPrompt = "\(prefix) Nothing to purge."
            processor.finishFeatureCommand(engine: engine)
            return false
        }
        purgeReport = found
        step = .purge
        processor.commandPrompt =
            "\(prefix) Purge \(found.total) unused definition" +
            "\(found.total == 1 ? "" : "s")? [Yes/No] <No>:"
        return true
    }

    private static func currentTextStyle(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> String {
        if case .string(let name) = processor.lispVars.get(
            "TEXTSTYLE", document: engine.document, activeCommand: nil),
           !name.isEmpty {
            return name
        }
        return "Standard"
    }
}

/// RECOVER command: opens a drawing file in a new tab, then validates and
/// auto-applies the safe fixes. DXF files additionally route through
/// `DXFReader` diagnostics so unreadable structure is reported instead of
/// silently dropped.
@MainActor
public final class RecoverCommand: FeatureCommand {

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Drawing file to recover:"
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
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !raw.isEmpty else {
            processor.commandPrompt = "Command cancelled."
            return .finished
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded).path
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["dxf", "dwg", "eab"].contains(ext) else {
            processor.commandPrompt =
                "Recover supports .dxf, .dwg and .eab files."
            return .finished
        }
        guard FileManager.default.fileExists(atPath: path) else {
            processor.commandPrompt = "File not found: \(raw)"
            return .finished
        }
        var diagnostics = ""
        if ext == "dxf" {
            do {
                let reader = try DXFReader().readFile(at: path)
                let unknown = reader.entities.filter {
                    $0.eType == .uNKNOWN
                }.count
                let version = reader.versionRaw.isEmpty
                    ? "unknown version" : reader.versionRaw
                diagnostics =
                    "Read DXF \(version) (\(reader.pairCount) pairs, " +
                    "\(reader.entities.count) entities, \(unknown) unknown). "
            } catch {
                processor.commandPrompt = "Recover failed to read file: \(error)"
                return .finished
            }
        }
        let index: Int
        do {
            index = try engine.tabManager.openTab(
                url: URL(fileURLWithPath: path))
        } catch {
            processor.commandPrompt = "Recover failed to open file: \(error)"
            return .finished
        }
        let document = engine.tabManager.tabs[index].document
        let found = AuditEngine.validate(document: document)
        let fixed = found.errorCount > 0
            ? AuditEngine.applyFixes(report: found, to: document) : 0
        if fixed > 0 {
            engine.tabManager.markActiveDirty()
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        processor.commandPrompt =
            "\(diagnostics)Recovered '\(name)': \(document.allEntities.count) " +
            "entities, \(found.errorCount) errors, \(fixed) fixed."
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

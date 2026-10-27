// Sources/ZephyrCore/Commands/PurgeCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// PURGE (PU) and -PURGE, Phase 2.2c: reachability sweep over the named
/// tables, reporting counts and confirming removal (PURGE) or applying
/// directly (scripted -PURGE, which never confirms). One undo entry covers
/// every removal. Never drops: referenced definitions, layer "0", the
/// current layer, "Standard" styles, current styles, "CONTINUOUS", xref
/// blocks, or xref-dependent layers.
public enum PurgeKind: String, CaseIterable {
    case layer
    case block
    case textStyle
    case dimStyle
    case leaderStyle
    case linetype
}

public struct PurgeItem {
    public var kind: PurgeKind
    /// Layer/block handle, or the table key for named styles/patterns.
    public var key: String
    public var displayName: String
}

public struct PurgeReport {
    public var items: [PurgeItem]
    /// Definitions kept, by kind (referenced/protected/current).
    public var protectedCounts: [PurgeKind: Int]

    public func count(for kind: PurgeKind) -> Int {
        items.filter { $0.kind == kind }.count
    }

    public var total: Int { items.count }
}

/// PURGE / -PURGE command. Mode selects confirm (dialog-equivalent prompt)
/// versus scripted apply-all.
@MainActor
public final class PurgeCommand: FeatureCommand {

    public enum Mode {
        case confirm
        case scripted
    }

    private let mode: Mode
    private var report: PurgeReport?

    public init(mode: Mode) {
        self.mode = mode
    }

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let currentTextStyle = Self.currentTextStyle(
            engine: engine, processor: processor)
        let found = engine.document.purgeableDefinitions(
            currentTextStyle: currentTextStyle)
        guard found.total > 0 else {
            processor.commandPrompt = "Nothing to purge."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        if mode == .scripted {
            apply(found, engine: engine, processor: processor)
            processor.finishFeatureCommand(engine: engine)
            return
        }
        report = found
        processor.commandPrompt = confirmPrompt(for: found)
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
        guard mode == .confirm, let found = report else { return .finished }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "Y", "YES":
            apply(found, engine: engine, processor: processor)
            return .finished
        default:
            processor.commandPrompt = "Purge cancelled; nothing removed."
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

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

    private func confirmPrompt(for report: PurgeReport) -> String {
        var parts: [String] = []
        for kind in PurgeKind.allCases {
            let count = report.count(for: kind)
            if count > 0 {
                parts.append("\(count) \(kind.rawValue)\(count == 1 ? "" : "s")")
            }
        }
        return "Purge \(parts.joined(separator: ", "))? [Yes/No]:"
    }

    private func apply(
        _ report: PurgeReport, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let removed = engine.document.applyPurge(report)
        var parts: [String] = []
        for kind in PurgeKind.allCases {
            let count = removed[kind] ?? 0
            if count > 0 {
                parts.append("\(count) \(kind.rawValue)\(count == 1 ? "" : "s")")
            }
        }
        let kept = report.protectedCounts.values.reduce(0, +)
        let message = parts.isEmpty
            ? "Nothing purged. \(kept) referenced or protected definition(s) kept."
            : "Purged \(parts.joined(separator: ", "))."
                + " \(kept) referenced or protected definition(s) kept (one undo entry)."
        print("[PURGE] \(message)")
        processor.commandPrompt = message
        engine.tabManager.markActiveDirty()
    }
}

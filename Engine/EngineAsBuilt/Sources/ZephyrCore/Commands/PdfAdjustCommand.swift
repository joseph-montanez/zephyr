// Sources/ZephyrCore/Commands/PdfAdjustCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// PDFADJUST, Phase 2.3b: per-instance PDF underlay contrast/fade/
/// monochrome over `CADPdfUnderlayMetadata` (the same params DXF
/// round-trips). Ranges mirror the type docs: contrast 20...100, fade
/// 0...80. One `updateEntities` batch = one undo entry. Pre-selection is
/// filtered to PDF underlays; an empty pick loop collects them.
@MainActor
public final class PdfAdjustCommand: FeatureCommand {

    private enum Phase {
        case pick
        case option
        case value
    }

    private var phase: Phase = .pick
    private var picked: [UUID] = []
    private var option = ""

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        picked = engine.cadSelection.selectedHandles.compactMap { handle in
            guard let entity = engine.document.entity(for: handle),
                  CADClipMetadata.kind(of: entity) == .pdf else { return nil }
            return handle
        }
        if !picked.isEmpty {
            phase = .option
            processor.commandPrompt =
                "Enter option [Contrast/Fade/Monochrome]:"
        } else {
            phase = .pick
            processor.commandPrompt =
                "Select PDF underlays to adjust, then press Enter:"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard phase == .pick else { return .continue }
        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX, worldY: worldY, document: engine.document,
            threshold: threshold, simplifyComplexBlocks: false),
              let entity = engine.document.entity(for: handle),
              CADClipMetadata.kind(of: entity) == .pdf else {
            return .handled
        }
        if !picked.contains(handle) { picked.append(handle) }
        processor.commandPrompt =
            "Select PDF underlays to adjust, then press Enter (\(picked.count) selected)"
        return .handled
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .pick:
            guard trimmed.isEmpty else { return .continue }
            guard !picked.isEmpty else {
                processor.commandPrompt = "Nothing selected; nothing changed."
                return .finished
            }
            phase = .option
            processor.commandPrompt = "Enter option [Contrast/Fade/Monochrome]:"
            return .continue
        case .option:
            let upper = trimmed.uppercased()
            guard ["C", "CONTRAST", "F", "FADE", "M", "MONOCHROME"].contains(upper)
            else {
                processor.commandPrompt =
                    "Unknown option '\(trimmed)'. Enter option [Contrast/Fade/Monochrome]:"
                return .continue
            }
            option = upper.hasPrefix("C") ? "Contrast"
                : upper.hasPrefix("F") ? "Fade" : "Monochrome"
            phase = .value
            processor.commandPrompt = option == "Contrast"
                ? "Enter contrast (20-100):"
                : option == "Fade" ? "Enter fade (0-80):"
                : "Monochrome? [Yes/No]:"
            return .continue
        case .value:
            if option == "Monochrome" {
                let upper = trimmed.uppercased()
                guard ["Y", "YES", "N", "NO"].contains(upper) else {
                    processor.commandPrompt = "Monochrome? [Yes/No]:"
                    return .continue
                }
                return apply(
                    engine: engine, processor: processor,
                    edit: { $0.monochrome = upper.hasPrefix("Y") })
            }
            guard let value = Int(trimmed) else {
                processor.commandPrompt = option == "Contrast"
                    ? "Enter contrast (20-100):" : "Enter fade (0-80):"
                return .continue
            }
            let range = option == "Contrast" ? 20...100 : 0...80
            guard range.contains(value) else {
                processor.commandPrompt = option == "Contrast"
                    ? "Enter contrast (20-100):" : "Enter fade (0-80):"
                return .continue
            }
            let captured = value
            let isContrast = option == "Contrast"
            return apply(
                engine: engine, processor: processor,
                edit: {
                    if isContrast { $0.contrast = captured }
                    else { $0.fade = captured }
                })
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func apply(
        engine: PhrostEngine, processor: CADCommandProcessor,
        edit: (inout CADPdfUnderlayParams) -> Void
    ) -> CommandResult {
        var updated: [CADEntity] = []
        for handle in picked {
            guard var entity = engine.document.entity(for: handle),
                  var params = CADPdfUnderlayMetadata.value(from: entity)
            else { continue }
            edit(&params)
            CADPdfUnderlayMetadata.set(params, on: &entity)
            updated.append(entity)
        }
        guard !updated.isEmpty else {
            processor.commandPrompt = "Nothing adjusted."
            return .finished
        }
        engine.document.updateEntities(updated)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt =
            "Adjusted \(updated.count) underlay\(updated.count == 1 ? "" : "s")."
        return .finished
    }
}

// Sources/ZephyrCore/Commands/ImageAdjustCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// IMAGEADJUST (IAD), Phase 2.3b: per-instance raster fade/contrast/
/// brightness over `CADImageAdjustMetadata` xdata (`image.adjust`).
///
/// Fade is honored by the renderer (sprite alpha via the bridge
/// `imageFade` channel); brightness/contrast persist and round-trip
/// through DXF IMAGE 281/282/283, with render approximation noted on the
/// type. One `updateEntities` batch = one undo entry. Pre-selection is
/// filtered to image instances; an empty pick loop collects them.
@MainActor
public final class ImageAdjustCommand: FeatureCommand {

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
                  CADClipMetadata.kind(of: entity) == .image else { return nil }
            return handle
        }
        if !picked.isEmpty {
            phase = .option
            processor.commandPrompt =
                "Enter option [Fade/Contrast/Brightness]:"
        } else {
            phase = .pick
            processor.commandPrompt = "Select images to adjust, then press Enter:"
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
              CADClipMetadata.kind(of: entity) == .image else {
            return .handled
        }
        if !picked.contains(handle) { picked.append(handle) }
        processor.commandPrompt =
            "Select images to adjust, then press Enter (\(picked.count) selected)"
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
            processor.commandPrompt = "Enter option [Fade/Contrast/Brightness]:"
            return .continue
        case .option:
            let upper = trimmed.uppercased()
            let valid = ["F", "FADE", "C", "CONTRAST", "B", "BRIGHTNESS"]
            guard valid.contains(upper) else {
                processor.commandPrompt =
                    "Unknown option '\(trimmed)'. Enter option [Fade/Contrast/Brightness]:"
                return .continue
            }
            option = upper.hasPrefix("F") ? "Fade"
                : upper.hasPrefix("C") ? "Contrast" : "Brightness"
            phase = .value
            processor.commandPrompt = "Enter \(option.lowercased()) value " +
                (option == "Fade" ? "(0-100):" : "(0-100, default 50):")
            return .continue
        case .value:
            guard let value = Int(trimmed), (0...100).contains(value) else {
                processor.commandPrompt =
                    "Enter \(option.lowercased()) value (0-100):"
                return .continue
            }
            var updated: [CADEntity] = []
            for handle in picked {
                guard var entity = engine.document.entity(for: handle) else { continue }
                var adjust = CADImageAdjustMetadata.value(from: entity)
                    ?? CADImageAdjust()
                switch option {
                case "Fade": adjust.fade = value
                case "Contrast": adjust.contrast = value
                default: adjust.brightness = value
                }
                CADImageAdjustMetadata.set(adjust, on: &entity)
                updated.append(entity)
            }
            guard !updated.isEmpty else {
                processor.commandPrompt = "Nothing adjusted."
                return .finished
            }
            engine.document.updateEntities(updated)
            engine.tabManager.markActiveDirty()
            processor.commandPrompt =
                "Adjusted \(updated.count) image\(updated.count == 1 ? "" : "s")."
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

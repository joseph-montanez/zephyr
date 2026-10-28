// Sources/ZephyrCore/Commands/Txt2MtxtCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// TXT2MTXT, Phase 2.1: merge selected single-line texts in reading order
/// into one MTEXT. Eligible sources are entities whose local geometry is
/// exactly one `.text` primitive with no `mtextWidth`; anything else is
/// refused at pick time with a message. The merged entity goes through the
/// shared `TextCommand.makeTextEntity` helper, so it is an ordinary editable
/// mtext (TEXTEDIT works on the result). Height, style, alignment, rotation,
/// and layer follow the topmost source; width fits the widest source so no
/// line wraps. One undo entry via `replaceEntities`.
@MainActor
public final class Txt2MtxtCommand: FeatureCommand {

    struct Source {
        var handle: UUID
        var text: String
        var height: Double
        var rotation: Double
        var style: String?
        var alignH: Int
        var alignV: Int
        var worldInsertion: Vector3
        var width: Double
        var layerID: UUID
    }

    private var targets: [UUID] = []

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        targets = []
        adoptSelectionTexts(engine: engine)
        processor.commandPrompt = targets.isEmpty
            ? "Select single-line text objects (Enter when done):"
            : "Select single-line text objects (\(targets.count) selected, Enter when done):"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let hitHandle = engine.cadSelection.hitTest(
            worldX: worldX, worldY: worldY,
            document: engine.document,
            threshold: 12.0 / engine.camera.zoom)
        if let handle = hitHandle,
           let entity = engine.document.entity(for: handle),
           !targets.contains(handle) {
            if Self.sourceText(in: entity) != nil {
                targets.append(handle)
            } else {
                processor.commandPrompt = "Only single-line text objects merge."
                    + (targets.isEmpty ? " Select single-line text objects (Enter when done):"
                                       : " (\(targets.count) selected, Enter when done):")
                return .continue
            }
        }
        processor.commandPrompt = targets.isEmpty
            ? "Select single-line text objects (Enter when done):"
            : "Select single-line text objects (\(targets.count) selected, Enter when done):"
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
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            guard !targets.isEmpty else { return .finished }
            merge(engine: engine, processor: processor)
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .continue
        }
        guard !targets.isEmpty else { return .finished }
        merge(engine: engine, processor: processor)
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure merge assembly (nonisolated: no actor state, test-callable)

    /// Sorts sources into reading order: top to bottom, then left to right.
    nonisolated static func readingOrder(_ sources: [Source]) -> [Source] {
        sources.sorted {
            if abs($0.worldInsertion.y - $1.worldInsertion.y) > 1e-9 {
                return $0.worldInsertion.y > $1.worldInsertion.y
            }
            return $0.worldInsertion.x < $1.worldInsertion.x
        }
    }

    /// Eligible single-line text: exactly one `.text` primitive with no
    /// `mtextWidth`. Returns its fields plus world insertion and width.
    nonisolated static func sourceText(in entity: CADEntity) -> Source? {
        guard let geom = entity.localGeometry,
              geom.count == 1,
              case .text(
                  let position, let text, let height, let rotation, let style,
                  let alignH, let alignV, let mtextWidth, _) = geom[0],
              mtextWidth == nil else {
            return nil
        }
        let bounds = CADEntity.estimateTextLocalBounds(
            text: text, height: height, alignH: alignH, alignV: alignV,
            mtextWidth: nil)
        return Source(
            handle: entity.handle,
            text: text,
            height: height,
            rotation: rotation + entity.transform.rotation,
            style: style,
            alignH: alignH,
            alignV: alignV,
            worldInsertion: entity.transform.transformPoint(position),
            width: max(0, bounds.maxX - bounds.minX),
            layerID: entity.layerID)
    }

    // MARK: - Private

    private func adoptSelectionTexts(engine: PhrostEngine) {
        for handle in engine.cadSelection.selectedHandles {
            guard let entity = engine.document.entity(for: handle),
                  Self.sourceText(in: entity) != nil,
                  !targets.contains(handle) else {
                continue
            }
            targets.append(handle)
        }
    }

    private func merge(engine: PhrostEngine, processor: CADCommandProcessor) {
        var sources: [Source] = []
        for handle in targets {
            guard let entity = engine.document.entity(for: handle),
                  let source = Self.sourceText(in: entity) else {
                continue
            }
            sources.append(source)
        }
        guard sources.count >= 2 else {
            processor.commandPrompt = "Select at least two single-line text objects."
            return
        }
        let ordered = Self.readingOrder(sources)
        let merged = ordered.map(\.text).joined(separator: "\n")
        guard !merged.isEmpty else {
            processor.commandPrompt = "Nothing to merge (all empty)."
            return
        }
        let first = ordered[0]
        let width = max(
            ordered.map(\.width).max() ?? first.height,
            first.height * 0.6)
        let styleName: String
        let fontName: String
        if let reference = first.style,
           let matched = engine.document.textStyle(named: reference)
               ?? engine.document.textStyles.values.first(
                   where: { $0.fontFile.caseInsensitiveCompare(reference) == .orderedSame }) {
            styleName = matched.name
            fontName = matched.fontFile
        } else {
            styleName = "Standard"
            fontName = engine.document.textStyle(named: "Standard")?.fontFile ?? "STANDARD"
        }
        let mergedEntity = TextCommand.makeTextEntity(
            text: merged,
            styleName: styleName,
            fontName: fontName,
            height: max(first.height, 1e-9),
            rotation: first.rotation,
            alignH: first.alignH,
            alignV: first.alignV,
            mtextWidth: width,
            insertPos: first.worldInsertion,
            layerID: first.layerID)
        engine.document.replaceEntities(
            remove: Set(ordered.map(\.handle)), add: [mergedEntity])
        engine.tabManager.markActiveDirty()
        let message = "Merged \(ordered.count) text objects into one mtext."
        print("[TXT2MTXT] \(message)")
        processor.commandPrompt = message
    }
}

// Sources/ZephyrCore/Commands/DimReassociateCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// DIMREASSOCIATE, Phase 2.1: re-point a linear or aligned dimension at two
/// new extension origins and re-measure it through the shared
/// DimChainMath.continueNext path, then rebuild the block with the
/// PropertiesPanel persistence pattern (updateDimensionBlock + updateEntity).
///
/// Spike verdict: re-point + re-measure is fully supported — the regen path
/// reads measurement from metadata, so adopting new defpoints and
/// recomputing is honest. Persistent associativity (the dimension following
/// later geometry edits) is NOT built: metadata stores raw points with no
/// entity linkage, and tracking would need reference fields plus change
/// notifications. The command says so when it finishes.
@MainActor
public final class DimReassociateCommand: FeatureCommand {

    private enum State {
        case pickDimension
        case pickFirstOrigin
        case pickSecondOrigin
    }

    private var state = State.pickDimension
    private var targetHandle: UUID?
    private var firstOrigin: Vector3?

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .pickDimension
        targetHandle = nil
        firstOrigin = nil
        if adoptSingleDimension(engine: engine) {
            state = .pickFirstOrigin
            processor.commandPrompt = "Specify new first extension origin:"
            return
        }
        processor.commandPrompt = "Select dimension to reassociate:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .pickDimension:
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom)
            guard let handle = hitHandle,
                  let entity = engine.document.entity(for: handle),
                  let box = entity.dimensionMetadata else {
                processor.commandPrompt = "No dimension there. Select dimension to reassociate:"
                return .continue
            }
            guard Self.isReassociable(box.value) else {
                processor.commandPrompt = "Only linear and aligned dimensions can be reassociated. Select dimension to reassociate:"
                return .continue
            }
            targetHandle = handle
            state = .pickFirstOrigin
            processor.commandPrompt = "Specify new first extension origin:"
            return .continue

        case .pickFirstOrigin:
            firstOrigin = engine.snap.currentSnapResult?.worldPos
                ?? Vector3(x: worldX, y: worldY, z: 0)
            state = .pickSecondOrigin
            processor.commandPrompt = "Specify new second extension origin:"
            return .continue

        case .pickSecondOrigin:
            let second = engine.snap.currentSnapResult?.worldPos
                ?? Vector3(x: worldX, y: worldY, z: 0)
            guard let handle = targetHandle,
                  let p1 = firstOrigin,
                  let entity = engine.document.entity(for: handle),
                  let box = entity.dimensionMetadata,
                  let newMeta = Self.reassociated(box.value, firstOrigin: p1, secondOrigin: second) else {
                processor.commandPrompt = "Origins coincide or dimension changed. Specify new second extension origin:"
                return .continue
            }
            var updated = entity
            updated.dimensionMetadata = CADDimensionMetadataBox(newMeta)
            DimensionPrimitives.updateDimensionBlock(for: &updated, in: engine.document)
            engine.document.updateEntity(updated)
            engine.tabManager.markActiveDirty()
            let style = engine.document.resolvedDimensionStyle(for: newMeta)
            print("[DIMREASSOCIATE] New measurement: \(style.formatMeasurement(newMeta.measurement)) (re-point only; the dimension does not track later geometry edits.)")
            targetHandle = nil
            firstOrigin = nil
            state = .pickDimension
            processor.commandPrompt = "Select dimension to reassociate:"
            return .continue
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
        case SDL_SCANCODE_ESCAPE, SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure re-measure (nonisolated: no actor state, test-callable)

    /// Nil unless the metadata is linear or aligned.
    nonisolated static func isReassociable(_ metadata: CADDimensionMetadata) -> Bool {
        metadata.type == .linearOrRotated || metadata.type == .aligned
    }

    /// Returns a copy of `metadata` re-pointed at the new origins with a
    /// recomputed measurement and text midpoint. The dimline position,
    /// angle, style, and text override are kept. Nil for non-linear/aligned
    /// types or a coincident pick (mirrors DimChainMath.continueNext).
    nonisolated static func reassociated(
        _ metadata: CADDimensionMetadata,
        firstOrigin: Vector3,
        secondOrigin: Vector3
    ) -> CADDimensionMetadata? {
        guard isReassociable(metadata) else { return nil }
        let source = DimChainMath.SourceChain(
            baseOrigin: firstOrigin,
            prevOrigin: firstOrigin,
            dimLinePos: metadata.defPoint,
            angle: metadata.rotationAngle,
            isLinear: metadata.type == .linearOrRotated)
        guard let chained = DimChainMath.continueNext(from: source, picked: secondOrigin) else {
            return nil
        }
        var next = metadata
        next.defPoint2 = chained.p1
        next.defPoint3 = chained.p2
        next.measurement = chained.measurement
        next.textMidpoint = chained.textMidpoint
        return next
    }

    // MARK: - Private

    /// Adopts the selection when it is exactly one reassociable dimension.
    private func adoptSingleDimension(engine: PhrostEngine) -> Bool {
        let handles = engine.cadSelection.selectedHandles
        guard handles.count == 1,
              let first = handles.first,
              let entity = engine.document.entity(for: first),
              let box = entity.dimensionMetadata,
              Self.isReassociable(box.value) else {
            return false
        }
        targetHandle = first
        return true
    }
}

/// DIMDISASSOCIATE (DDA), Phase 2.1: the honest sibling of DIMREASSOCIATE.
/// Zephyr dimensions store snapshot definition points with no entity linkage
/// (see the DIMREASSOCIATE spike verdict above), so there is never anything
/// to unlink. The command still accepts LT muscle memory: each picked
/// dimension is counted, and Enter reports that nothing changed instead of
/// erroring on an unknown command.
@MainActor
public final class DimDisassociateCommand: FeatureCommand {

    private var count = 0

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        count = 0
        processor.commandPrompt = "Select dimensions to disassociate (Enter when done):"
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
           entity.dimensionMetadata != nil {
            count += 1
        }
        processor.commandPrompt = "Select dimensions to disassociate (Enter when done):"
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
            print("[DIMDISASSOCIATE] \(count) dimension(s) checked; none carry associative links, nothing changed.")
            processor.commandPrompt = "\(count) dimension(s) checked; nothing changed."
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("[DIMDISASSOCIATE] \(count) dimension(s) checked; none carry associative links, nothing changed.")
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

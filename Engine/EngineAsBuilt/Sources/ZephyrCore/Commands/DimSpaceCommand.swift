// Sources/ZephyrCore/Commands/DimSpaceCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// DIMSPACE, Phase 2.1: equalize the dimension-line offsets of parallel
/// linear or aligned dimensions. Pick the base dimension (it stays put),
/// pick the dimensions to space, then type the spacing; 0 aligns every
/// dimline onto the base. Order along the offset normal is preserved.
/// Each target shifts its defPoint and textMidpoint by the same delta and
/// persists with the PropertiesPanel pattern (updateDimensionBlock +
/// updateEntity, one undo entry per dimension).
@MainActor
public final class DimSpaceCommand: FeatureCommand {

    private enum Phase {
        case pickBase
        case pickOthers
        case spacing
    }

    /// Parallel tolerance in radians for the base/others angle check.
    nonisolated static let angleTolerance = 1e-3

    private var phase = Phase.pickBase
    private var baseHandle: UUID?
    private var otherHandles: [UUID] = []

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .pickBase
        baseHandle = nil
        otherHandles = []
        processor.commandPrompt = "Select base dimension:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch phase {
        case .pickBase:
            guard let (handle, _) = pickParallelDimension(
                worldX: worldX, worldY: worldY,
                engine: engine, baseAngle: nil) else {
                processor.commandPrompt = "No linear or aligned dimension there. Select base dimension:"
                return .continue
            }
            baseHandle = handle
            phase = .pickOthers
            processor.commandPrompt = "Select dimensions to space (Enter when done):"
            return .continue

        case .pickOthers:
            guard let base = baseHandle,
                  let baseEntity = engine.document.entity(for: base),
                  let baseBox = baseEntity.dimensionMetadata else {
                phase = .pickBase
                baseHandle = nil
                otherHandles = []
                processor.commandPrompt = "Select base dimension:"
                return .continue
            }
            guard let (handle, _) = pickParallelDimension(
                worldX: worldX, worldY: worldY,
                engine: engine, baseAngle: baseBox.value.rotationAngle) else {
                processor.commandPrompt = "Only dimensions parallel to the base apply. Select dimensions to space (\(otherHandles.count) selected, Enter when done):"
                return .continue
            }
            if handle != base, !otherHandles.contains(handle) {
                otherHandles.append(handle)
            }
            processor.commandPrompt = otherHandles.isEmpty
                ? "Select dimensions to space (Enter when done):"
                : "Select dimensions to space (\(otherHandles.count) selected, Enter when done):"
            return .continue

        case .spacing:
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
        case SDL_SCANCODE_ESCAPE:
            return .finished
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return handleEnter(engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .pickBase, .pickOthers:
            if !trimmed.isEmpty { return .continue }
            return handleEnter(engine: engine, processor: processor)
        case .spacing:
            guard let spacing = Self.parseSpacing(trimmed) else {
                processor.commandPrompt = "Enter spacing (0 to align):"
                return .continue
            }
            apply(spacing: spacing, engine: engine, processor: processor)
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure spacing math (nonisolated: no actor state, test-callable)

    /// Nil unless every angle is parallel (modulo pi) within tolerance.
    nonisolated static func isParallel(_ a: Double, _ b: Double, tolerance: Double = angleTolerance) -> Bool {
        let diff = abs(a - b).truncatingRemainder(dividingBy: .pi)
        return diff < tolerance || .pi - diff < tolerance
    }

    /// New defPoints for `others` (input order) that place every dimline —
    /// base included — at multiples of `spacing` along the base normal,
    /// preserving order with the base fixed. Nil on any angle mismatch.
    nonisolated static func spacedDefPoints(
        base: CADDimensionMetadata, others: [CADDimensionMetadata], spacing: Double
    ) -> [Vector3]? {
        for other in others {
            guard isParallel(base.rotationAngle, other.rotationAngle) else {
                return nil
            }
        }
        let n = Vector3(
            x: -sin(base.rotationAngle), y: cos(base.rotationAngle), z: 0)
        struct Rank {
            var index: Int // -1 for the base, else others index
            var dist: Double
        }
        var ranks: [Rank] = [Rank(index: -1, dist: 0)]
        for (i, other) in others.enumerated() {
            let d = (other.defPoint.x - base.defPoint.x) * n.x
                + (other.defPoint.y - base.defPoint.y) * n.y
            ranks.append(Rank(index: i, dist: d))
        }
        ranks.sort { $0.dist < $1.dist }
        guard let baseRank = ranks.firstIndex(where: { $0.index == -1 }) else {
            return nil
        }
        var result = Array(repeating: base.defPoint, count: others.count)
        for (rank, entry) in ranks.enumerated() {
            guard entry.index >= 0 else { continue }
            let offset = Double(rank - baseRank) * spacing
            result[entry.index] = Vector3(
                x: base.defPoint.x + n.x * offset,
                y: base.defPoint.y + n.y * offset,
                z: base.defPoint.z)
        }
        return result
    }

    /// Finite, non-negative spacing. Nil for anything else.
    nonisolated static func parseSpacing(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed),
              value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    // MARK: - Private

    /// Hit-tests a linear/aligned dimension, optionally requiring
    /// parallelism to a base angle. Returns handle plus metadata.
    private func pickParallelDimension(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, baseAngle: Double?
    ) -> (UUID, CADDimensionMetadata)? {
        let hitHandle = engine.cadSelection.hitTest(
            worldX: worldX, worldY: worldY,
            document: engine.document,
            threshold: 12.0 / engine.camera.zoom)
        guard let handle = hitHandle,
              let entity = engine.document.entity(for: handle),
              let box = entity.dimensionMetadata,
              DimEditCommand.placementChain(for: box.value) != nil else {
            return nil
        }
        if let baseAngle,
           !Self.isParallel(baseAngle, box.value.rotationAngle) {
            return nil
        }
        return (handle, box.value)
    }

    private func handleEnter(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard phase == .pickOthers else { return .continue }
        guard !otherHandles.isEmpty else {
            processor.commandPrompt = "Select dimensions to space (Enter when done):"
            return .continue
        }
        phase = .spacing
        processor.commandPrompt = "Enter spacing (0 to align):"
        return .continue
    }

    private func apply(spacing: Double, engine: PhrostEngine, processor: CADCommandProcessor) {
        guard let base = baseHandle,
              let baseEntity = engine.document.entity(for: base),
              let baseBox = baseEntity.dimensionMetadata else {
            processor.commandPrompt = "Base dimension changed; nothing spaced."
            return
        }
        var otherMetas: [CADDimensionMetadata] = []
        var otherEntities: [CADEntity] = []
        for handle in otherHandles {
            guard let entity = engine.document.entity(for: handle),
                  let box = entity.dimensionMetadata else {
                continue
            }
            otherMetas.append(box.value)
            otherEntities.append(entity)
        }
        guard let newDefPoints = Self.spacedDefPoints(
            base: baseBox.value, others: otherMetas, spacing: spacing),
              newDefPoints.count == otherEntities.count else {
            processor.commandPrompt = "Dimensions are not parallel; nothing spaced."
            return
        }
        var applied = 0
        for (entity, newDefPoint) in zip(otherEntities, newDefPoints) {
            guard let box = entity.dimensionMetadata else { continue }
            var meta = box.value
            let delta = Vector3(
                x: newDefPoint.x - meta.defPoint.x,
                y: newDefPoint.y - meta.defPoint.y,
                z: newDefPoint.z - meta.defPoint.z)
            meta.defPoint = newDefPoint
            meta.textMidpoint = Vector3(
                x: meta.textMidpoint.x + delta.x,
                y: meta.textMidpoint.y + delta.y,
                z: meta.textMidpoint.z + delta.z)
            var updated = entity
            updated.dimensionMetadata = CADDimensionMetadataBox(meta)
            DimensionPrimitives.updateDimensionBlock(for: &updated, in: engine.document)
            engine.document.updateEntity(updated)
            applied += 1
        }
        engine.tabManager.markActiveDirty()
        let message = spacing == 0
            ? "Aligned \(applied) dimension(s) onto the base."
            : "Spaced \(applied) dimension(s) at \(spacing)."
        print("[DIMSPACE] \(message)")
        processor.commandPrompt = message
    }
}

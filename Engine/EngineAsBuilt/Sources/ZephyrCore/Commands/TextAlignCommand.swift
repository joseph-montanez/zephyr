// Sources/ZephyrCore/Commands/TextAlignCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// TEXTALIGN (TA), Phase 2.1: align or distribute text origins along a
/// picked baseline. Adopts every text entity in the selection, or picks
/// until Enter; option Align projects each world insertion onto the line,
/// Distribute additionally respreads them evenly between the extreme
/// projections. Rotations are preserved; only the insertion moves, via a
/// world-space delta pre-multiplied onto the entity transform.
@MainActor
public final class TextAlignCommand: FeatureCommand {

    private enum Phase {
        case collect
        case option
        case pickFirst
        case pickSecond
    }

    private enum PendingOption {
        case align
        case distribute
    }

    private var phase = Phase.collect
    private var targets: [UUID] = []
    private var pendingOption = PendingOption.align
    private var firstPoint: Vector3?

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .collect
        targets = []
        pendingOption = .align
        firstPoint = nil
        adoptSelectionTexts(engine: engine)
        if targets.isEmpty {
            processor.commandPrompt = "Select text objects (Enter when done):"
        } else {
            phase = .option
            processor.commandPrompt = "Enter option [Align/Distribute]:"
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
        let picked = engine.snap.currentSnapResult?.worldPos
            ?? Vector3(x: worldX, y: worldY, z: 0)
        switch phase {
        case .collect:
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom)
            if let handle = hitHandle,
               Self.textPrimPosition(
                   in: engine.document.entity(for: handle)) != nil,
               !targets.contains(handle) {
                targets.append(handle)
            }
            processor.commandPrompt = targets.isEmpty
                ? "Select text objects (Enter when done):"
                : "Select text objects (\(targets.count) selected, Enter when done):"
            return .continue

        case .option:
            return .continue

        case .pickFirst:
            firstPoint = picked
            phase = .pickSecond
            processor.commandPrompt = "Specify second baseline point:"
            return .continue

        case .pickSecond:
            guard let pointA = firstPoint else {
                phase = .pickFirst
                processor.commandPrompt = "Specify first baseline point:"
                return .continue
            }
            if hypot(picked.x - pointA.x, picked.y - pointA.y) < 1e-9 {
                processor.commandPrompt = "Points coincide. Specify second baseline point:"
                return .continue
            }
            apply(lineA: pointA, lineB: picked, engine: engine, processor: processor)
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
        case .collect:
            if !trimmed.isEmpty { return .continue }
            return handleEnter(engine: engine, processor: processor)
        case .option:
            switch trimmed.uppercased() {
            case "A", "ALIGN":
                pendingOption = .align
                phase = .pickFirst
                processor.commandPrompt = "Specify first baseline point:"
                return .continue
            case "D", "DISTRIBUTE":
                pendingOption = .distribute
                phase = .pickFirst
                processor.commandPrompt = "Specify first baseline point:"
                return .continue
            default:
                processor.commandPrompt = "Enter option [Align/Distribute]:"
                return .continue
            }
        case .pickFirst, .pickSecond:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure alignment math (nonisolated: no actor state, test-callable)

    /// Projects a world point onto the baseline; returns the projected
    /// point plus its distance along the baseline from lineA.
    nonisolated static func projected(
        point: Vector3, lineA: Vector3, lineB: Vector3
    ) -> (point: Vector3, along: Double)? {
        let dx = lineB.x - lineA.x
        let dy = lineB.y - lineA.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-18 else { return nil }
        let t = ((point.x - lineA.x) * dx + (point.y - lineA.y) * dy) / lenSq
        return (
            point: Vector3(
                x: lineA.x + dx * t, y: lineA.y + dy * t, z: point.z),
            along: t * sqrt(lenSq))
    }

    /// New positions for origins in input order: projected onto the
    /// baseline, respread evenly between the extreme projections. A single
    /// origin just projects ( Align behavior).
    nonisolated static func distributed(
        origins: [Vector3], lineA: Vector3, lineB: Vector3
    ) -> [Vector3]? {
        guard !origins.isEmpty else { return [] }
        var slots: [(along: Double, z: Double)] = []
        for origin in origins {
            guard let hit = projected(point: origin, lineA: lineA, lineB: lineB) else {
                return nil
            }
            slots.append((along: hit.along, z: origin.z))
        }
        let order = slots.indices.sorted { slots[$0].along < slots[$1].along }
        let minAlong = slots[order.first!].along
        let maxAlong = slots[order.last!].along
        let dx = lineB.x - lineA.x
        let dy = lineB.y - lineA.y
        let len = hypot(dx, dy)
        guard len > 1e-9 else { return nil }
        let ux = dx / len
        let uy = dy / len
        var result = origins
        for (rank, sourceIndex) in order.enumerated() {
            let along: Double
            if order.count == 1 {
                along = slots[sourceIndex].along
            } else {
                along = minAlong + (maxAlong - minAlong)
                    * Double(rank) / Double(order.count - 1)
            }
            result[sourceIndex] = Vector3(
                x: lineA.x + ux * along, y: lineA.y + uy * along,
                z: slots[sourceIndex].z)
        }
        return result
    }

    /// Local position of the first `.text` primitive, or nil when the
    /// entity holds no text.
    nonisolated static func textPrimPosition(in entity: CADEntity?) -> Vector3? {
        guard let geom = entity?.localGeometry else { return nil }
        for prim in geom {
            if case .text(let position, _, _, _, _, _, _, _, _) = prim {
                return position
            }
        }
        return nil
    }

    // MARK: - Private

    private func adoptSelectionTexts(engine: PhrostEngine) {
        for handle in engine.cadSelection.selectedHandles {
            guard let entity = engine.document.entity(for: handle),
                  Self.textPrimPosition(in: entity) != nil,
                  !targets.contains(handle) else {
                continue
            }
            targets.append(handle)
        }
    }

    private func handleEnter(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard phase == .collect else { return .continue }
        guard !targets.isEmpty else { return .finished }
        phase = .option
        processor.commandPrompt = "Enter option [Align/Distribute]:"
        return .continue
    }

    private func apply(
        lineA: Vector3, lineB: Vector3,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        var origins: [Vector3] = []
        var entities: [CADEntity] = []
        for handle in targets {
            guard let entity = engine.document.entity(for: handle),
                  let local = Self.textPrimPosition(in: entity) else {
                continue
            }
            origins.append(entity.transform.transformPoint(local))
            entities.append(entity)
        }
        guard !entities.isEmpty else {
            processor.commandPrompt = "No text objects remain; nothing aligned."
            return
        }
        let placed: [Vector3]?
        switch pendingOption {
        case .align:
            placed = origins.compactMap {
                Self.projected(point: $0, lineA: lineA, lineB: lineB)?.point
            }
            guard placed?.count == origins.count else {
                processor.commandPrompt = "Baseline degenerate; nothing aligned."
                return
            }
        case .distribute:
            placed = Self.distributed(origins: origins, lineA: lineA, lineB: lineB)
            guard placed != nil else {
                processor.commandPrompt = "Baseline degenerate; nothing aligned."
                return
            }
        }
        var applied = 0
        for (entity, destination) in zip(entities, placed!) {
            guard let local = Self.textPrimPosition(in: entity) else { continue }
            let current = entity.transform.transformPoint(local)
            let delta = Vector3(
                x: destination.x - current.x,
                y: destination.y - current.y,
                z: destination.z - current.z)
            var updated = entity
            updated.transform = Transform3D.translated(by: delta)
                .multiplying(by: entity.transform)
            engine.document.updateEntity(updated)
            applied += 1
        }
        engine.tabManager.markActiveDirty()
        let what = pendingOption == .align ? "Aligned" : "Distributed"
        let message = "\(what) \(applied) text object(s)."
        print("[TEXTALIGN] \(message)")
        processor.commandPrompt = message
    }
}

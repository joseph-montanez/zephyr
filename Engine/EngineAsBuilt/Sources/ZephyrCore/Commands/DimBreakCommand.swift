// Sources/ZephyrCore/Commands/DimBreakCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL
import ZephyrKernel

/// DIMBREAK, Phase 2.1: cut gaps in a linear or aligned dimension's
/// extension and dimension lines. Manual picks two points; Auto intersects
/// user-picked cutting objects against the exact drawn segments with the
/// kernel solver (in the cutter's local frame, so arcs, circles, and
/// scaled blocks intersect exactly); Remove clears stored breaks.
///
/// Gaps store as fractions along each regenerated line (DimBreak), so they
/// survive MOVE and re-measure. Each commit persists with the PropertiesPanel
/// pattern (updateDimensionBlock + updateEntity). Breaks are session-only:
/// EAB and DXF export do not persist them.
@MainActor
public final class DimBreakCommand: FeatureCommand {

    private enum Phase {
        case pickDimension
        case option
        case pickFirst
        case pickSecond
        case pickCutters
    }

    private enum PendingOption {
        case manual
        case auto
        case remove
    }

    private var phase = Phase.pickDimension
    private var targetHandle: UUID?
    private var firstPoint: Vector3?
    private var cutterHandles: [UUID] = []

    public init() {}

    public var isSnappingEnabled: Bool { true }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .pickDimension
        targetHandle = nil
        firstPoint = nil
        cutterHandles = []
        if adoptSingleDimension(engine: engine) {
            phase = .option
            processor.commandPrompt = "Enter option [Manual/Auto/Remove]:"
            return
        }
        processor.commandPrompt = "Select dimension to break:"
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
        case .pickDimension:
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom)
            guard let handle = hitHandle,
                  let entity = engine.document.entity(for: handle),
                  let box = entity.dimensionMetadata,
                  DimEditCommand.placementChain(for: box.value) != nil else {
                processor.commandPrompt = "No linear or aligned dimension there. Select dimension to break:"
                return .continue
            }
            targetHandle = handle
            phase = .option
            processor.commandPrompt = "Enter option [Manual/Auto/Remove]:"
            return .continue

        case .option:
            return .continue

        case .pickFirst:
            firstPoint = picked
            phase = .pickSecond
            processor.commandPrompt = "Specify second break point:"
            return .continue

        case .pickSecond:
            guard let handle = targetHandle,
                  let pointA = firstPoint,
                  let entity = engine.document.entity(for: handle),
                  let box = entity.dimensionMetadata else {
                processor.commandPrompt = "Dimension changed. Specify second break point:"
                return .continue
            }
            let style = engine.document.resolvedDimensionStyle(for: box.value)
            guard let chained = DimEditCommand.placementChain(for: box.value) else {
                processor.commandPrompt = "Dimension changed. Select dimension to break:"
                resetToPickDimension()
                return .continue
            }
            let newBreaks = Self.manualBreaks(
                dimStart: chained.dimStart, dimEnd: chained.dimEnd,
                defPoint2: box.value.defPoint2,
                defPoint3: chained.p2,
                pointA: pointA, pointB: picked,
                style: style, obliqueAngle: box.value.obliqueAngle)
            guard !newBreaks.isEmpty else {
                processor.commandPrompt = "Points do not cross the dimension lines. Specify second break point:"
                return .continue
            }
            var meta = box.value
            meta.dimBreaks += newBreaks
            persist(meta, handle: handle, entity: entity, engine: engine)
            print("[DIMBREAK] Manual break added (\(newBreaks.count) gap(s)).")
            resetToPickDimension()
            processor.commandPrompt = "Select dimension to break:"
            return .continue

        case .pickCutters:
            let hitHandle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY,
                document: engine.document,
                threshold: 12.0 / engine.camera.zoom)
            if let handle = hitHandle,
               handle != targetHandle,
               engine.document.entity(for: handle) != nil,
               !cutterHandles.contains(handle) {
                cutterHandles.append(handle)
            }
            processor.commandPrompt = cutterHandles.isEmpty
                ? "Select objects to break around (Enter when done):"
                : "Select objects to break around (\(cutterHandles.count) selected, Enter when done):"
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
        case .pickCutters:
            if !trimmed.isEmpty { return .continue }
            return handleEnter(engine: engine, processor: processor)
        case .option:
            switch trimmed.uppercased() {
            case "M", "MANUAL":
                firstPoint = nil
                phase = .pickFirst
                processor.commandPrompt = "Specify first break point:"
                return .continue
            case "A", "AUTO":
                cutterHandles = []
                phase = .pickCutters
                processor.commandPrompt = "Select objects to break around (Enter when done):"
                return .continue
            case "R", "REMOVE":
                guard let handle = targetHandle,
                      let entity = engine.document.entity(for: handle),
                      let box = entity.dimensionMetadata else {
                    resetToPickDimension()
                    processor.commandPrompt = "Select dimension to break:"
                    return .continue
                }
                var meta = box.value
                let removed = meta.dimBreaks.count
                meta.dimBreaks = []
                persist(meta, handle: handle, entity: entity, engine: engine)
                print("[DIMBREAK] Removed \(removed) break(s).")
                resetToPickDimension()
                processor.commandPrompt = "Select dimension to break:"
                return .continue
            default:
                processor.commandPrompt = "Enter option [Manual/Auto/Remove]:"
                return .continue
            }
        case .pickDimension, .pickFirst, .pickSecond:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure break math (nonisolated: no actor state, test-callable)

    /// Fractional gap where two picked points cross one drawn segment.
    /// Points project onto the segment; both must land within the span
    /// (plus margin) or there is no gap. Nil for a miss or empty span.
    nonisolated static func projectedGap(
        segStart: Vector3, segEnd: Vector3,
        pointA: Vector3, pointB: Vector3, margin: Double
    ) -> (Double, Double)? {
        let dx = segEnd.x - segStart.x
        let dy = segEnd.y - segStart.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-18 else { return nil }
        let len = sqrt(lenSq)
        func project(_ p: Vector3) -> (t: Double, dist: Double) {
            let t = ((p.x - segStart.x) * dx + (p.y - segStart.y) * dy) / lenSq
            let cx = segStart.x + dx * t
            let cy = segStart.y + dy * t
            return (t, hypot(p.x - cx, p.y - cy))
        }
        let pa = project(pointA)
        let pb = project(pointB)
        guard pa.dist <= margin, pb.dist <= margin else { return nil }
        let tol = margin / len
        let lo = max(0, min(pa.t, pb.t))
        let hi = min(1, max(pa.t, pb.t))
        guard lo <= 1 + tol, hi >= 0 - tol, hi - lo > 1e-9 else { return nil }
        return (max(0, lo), min(1, hi))
    }

    /// Manual gaps over the three drawn segments of a linear/aligned dim.
    nonisolated static func manualBreaks(
        dimStart: Vector3, dimEnd: Vector3,
        defPoint2: Vector3, defPoint3: Vector3,
        pointA: Vector3, pointB: Vector3,
        style: CADDimensionStyle, obliqueAngle: Double?
    ) -> [DimBreak] {
        let along = DimensionPrimitives.dimLineDirection(from: dimStart, to: dimEnd)
        let margin = max(style.extensionLineExtend, 1e-6)
        var out: [DimBreak] = []
        let sides: [(DimBreakLine, Vector3, Vector3, Bool)] = [
            (.firstExtension, defPoint2, dimStart, style.suppressFirstExtension),
            (.secondExtension, defPoint3, dimEnd, style.suppressSecondExtension),
        ]
        for (line, feature, dimPoint, suppressed) in sides {
            if suppressed { continue }
            guard let ends = DimensionPrimitives.extensionEndpoints(
                feature: feature, dimPoint: dimPoint, along: along,
                style: style, obliqueAngle: obliqueAngle),
                  let gap = projectedGap(
                      segStart: ends.start, segEnd: ends.end,
                      pointA: pointA, pointB: pointB, margin: margin) else {
                continue
            }
            out.append(DimBreak(line: line, t0: gap.0, t1: gap.1))
        }
        if let gap = projectedGap(
            segStart: dimStart, segEnd: dimEnd,
            pointA: pointA, pointB: pointB, margin: margin) {
            out.append(DimBreak(line: .dimension, t0: gap.0, t1: gap.1))
        }
        return out
    }

    /// Widens one kernel crossing parameter into a clamped gap. Nil when
    /// the widened span is empty.
    nonisolated static func widenedGap(param: Double, halfWidth: Double) -> (Double, Double)? {
        let lo = max(0, param - halfWidth)
        let hi = min(1, param + halfWidth)
        guard hi - lo > 1e-9 else { return nil }
        return (lo, hi)
    }

    // MARK: - Private

    private func resetToPickDimension() {
        phase = .pickDimension
        targetHandle = nil
        firstPoint = nil
        cutterHandles = []
    }

    private func adoptSingleDimension(engine: PhrostEngine) -> Bool {
        let handles = engine.cadSelection.selectedHandles
        guard handles.count == 1,
              let first = handles.first,
              let entity = engine.document.entity(for: first),
              let box = entity.dimensionMetadata,
              DimEditCommand.placementChain(for: box.value) != nil else {
            return false
        }
        targetHandle = first
        return true
    }

    private func persist(
        _ meta: CADDimensionMetadata, handle: UUID, entity: CADEntity, engine: PhrostEngine
    ) {
        var updated = entity
        updated.dimensionMetadata = CADDimensionMetadataBox(meta)
        DimensionPrimitives.updateDimensionBlock(for: &updated, in: engine.document)
        engine.document.updateEntity(updated)
        engine.tabManager.markActiveDirty()
    }

    private func handleEnter(engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard phase == .pickCutters else {
            return .continue
        }
        guard let handle = targetHandle,
              let entity = engine.document.entity(for: handle),
              let box = entity.dimensionMetadata,
              let chained = DimEditCommand.placementChain(for: box.value) else {
            resetToPickDimension()
            processor.commandPrompt = "Select dimension to break:"
            return .continue
        }
        guard !cutterHandles.isEmpty else {
            processor.commandPrompt = "Select objects to break around (Enter when done):"
            return .continue
        }
        let style = engine.document.resolvedDimensionStyle(for: box.value)
        let newBreaks = Self.autoBreaks(
            dimStart: chained.dimStart, dimEnd: chained.dimEnd,
            defPoint2: box.value.defPoint2, defPoint3: chained.p2,
            style: style, obliqueAngle: box.value.obliqueAngle,
            cutters: cutterHandles, engine: engine)
        var meta = box.value
        meta.dimBreaks += newBreaks
        persist(meta, handle: handle, entity: entity, engine: engine)
        print("[DIMBREAK] Auto break added (\(newBreaks.count) gap(s)) around \(cutterHandles.count) object(s).")
        resetToPickDimension()
        processor.commandPrompt = "Select dimension to break:"
        return .continue
    }

    /// Auto gaps: the three drawn segments, expressed in each cutter's
    /// local frame, intersected with the cutter's kernel curves. Fractional
    /// parameters are affine-invariant, so local-frame hits map straight
    /// back onto the world segments.
    private static func autoBreaks(
        dimStart: Vector3, dimEnd: Vector3,
        defPoint2: Vector3, defPoint3: Vector3,
        style: CADDimensionStyle, obliqueAngle: Double?,
        cutters: [UUID], engine: PhrostEngine
    ) -> [DimBreak] {
        let along = DimensionPrimitives.dimLineDirection(from: dimStart, to: dimEnd)
        let marginWorld = max(style.extensionLineExtend, 1e-6)
        var segments: [(DimBreakLine, Vector3, Vector3, Bool)] = []
        if let first = DimensionPrimitives.extensionEndpoints(
            feature: defPoint2, dimPoint: dimStart, along: along,
            style: style, obliqueAngle: obliqueAngle) {
            segments.append((.firstExtension, first.start, first.end, style.suppressFirstExtension))
        }
        if let second = DimensionPrimitives.extensionEndpoints(
            feature: defPoint3, dimPoint: dimEnd, along: along,
            style: style, obliqueAngle: obliqueAngle) {
            segments.append((.secondExtension, second.start, second.end, style.suppressSecondExtension))
        }
        segments.append((.dimension, dimStart, dimEnd, false))

        var out: [DimBreak] = []
        for cutterHandle in cutters {
            guard let cutter = engine.document.entity(for: cutterHandle),
                  let geom = cutter.resolvedGeometry(in: engine.document) else {
                continue
            }
            let toLocal = cutter.transform.inverse()
            for (line, worldA, worldB, suppressed) in segments {
                if suppressed { continue }
                let localA = toLocal.transformPoint(worldA)
                let localB = toLocal.transformPoint(worldB)
                // Fractions ride affine maps unchanged, but the margin is
                // world-sized, so normalize by the world length.
                let worldLen = hypot(worldB.x - worldA.x, worldB.y - worldA.y)
                guard worldLen > 1e-9 else { continue }
                let localSeg = LineSeg2d(start: localA.point2d, end: localB.point2d)
                let halfWidth = marginWorld / worldLen
                for prim in geom {
                    for cutterCurve in prim.toKernelCurves() {
                        let hits = Intersector2D.intersect(
                            .line(localSeg), cutterCurve,
                            extendA: false, extendB: false)
                        for hit in hits {
                            guard let gap = widenedGap(param: hit.paramA, halfWidth: halfWidth) else {
                                continue
                            }
                            out.append(DimBreak(line: line, t0: gap.0, t1: gap.1))
                        }
                    }
                }
            }
        }
        return out
    }
}

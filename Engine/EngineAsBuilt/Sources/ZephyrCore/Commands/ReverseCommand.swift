// Sources/ZephyrCore/Commands/ReverseCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// REVERSE, Phase 2.2g: flips the direction of lines, polylines, and
/// splines in the selection (or a click-pick loop when empty).
///
/// - Line: swaps start/end.
/// - Polyline: reverses vertex order. Bulges negate and shift with their
///   segment (vertex *i* carries the bulge of segment *i*→*i+1*, so the
///   reversed vertex *j* takes −bulge of the mirrored segment); segment
///   widths travel the same way without negation. Closed polylines keep
///   vertex 0 fixed and reverse the rest, so reversing twice restores the
///   original exactly (covered by test).
/// - Spline: reverses control points and weights; knots mirror
///   (`first+last−k`) so the vector stays non-decreasing.
/// One `replaceEntities` batch = one undo entry. Entities with no
/// reversible primitive are counted as skipped, never touched.
@MainActor
public final class ReverseCommand: FeatureCommand {

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if !engine.cadSelection.selectedHandles.isEmpty {
            apply(engine: engine, processor: processor)
            processor.finishFeatureCommand(engine: engine)
        } else {
            processor.commandPrompt = "Select objects to reverse, then press Enter:"
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
        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks
        ) else {
            return .handled
        }
        let shiftHeld = engine.io?.pointee.KeyShift ?? false
        if shiftHeld {
            engine.cadSelection.removeFromSelection(handle)
        } else {
            engine.cadSelection.addToSelection(handle)
        }
        processor.commandPrompt =
            "Select objects to reverse, then press Enter " +
            "(\(engine.cadSelection.selectedCount) selected)"
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
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .continue }
        apply(engine: engine, processor: processor)
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func apply(engine: PhrostEngine, processor: CADCommandProcessor) {
        let handles = engine.cadSelection.selectedHandles
        guard !handles.isEmpty else {
            processor.commandPrompt = "Nothing selected; nothing changed."
            return
        }
        var updated: [CADEntity] = []
        var skipped = 0
        for handle in handles {
            guard var entity = engine.document.entity(for: handle),
                  let prims = entity.localGeometry
            else { skipped += 1; continue }
            var reversedAny = false
            entity.localGeometry = prims.map { prim in
                guard let flipped = Self.reversed(prim) else { return prim }
                reversedAny = true
                return flipped
            }
            if reversedAny {
                updated.append(entity)
            } else {
                skipped += 1
            }
        }
        guard !updated.isEmpty else {
            processor.commandPrompt =
                "No reversible geometry in selection; nothing changed."
            return
        }
        engine.document.replaceEntities(remove: [], add: updated)
        engine.tabManager.markActiveDirty()
        var message = "Reversed \(updated.count) object\(updated.count == 1 ? "" : "s")."
        if skipped > 0 {
            message += " \(skipped) skipped (no line, polyline, or spline geometry)."
        }
        processor.commandPrompt = message
    }

    /// Returns the direction-flipped primitive, or nil when the primitive
    /// has no reversible direction.
    static func reversed(_ prim: CADPrimitive) -> CADPrimitive? {
        switch prim {
        case .line(let start, let end, let color):
            return .line(start: end, end: start, color: color)
        case .polyline(let path, let color):
            return .polyline(path: reversed(path), color: color)
        case .spline(let points, let knots, let degree, let weights, let color):
            let flippedPoints = points.reversed()
            let flippedWeights = weights.map { Array($0.reversed()) }
            let mirroredKnots: [Double]
            if let first = knots.first, let last = knots.last {
                mirroredKnots = knots.reversed().map { first + last - $0 }
            } else {
                mirroredKnots = knots
            }
            return .spline(
                controlPoints: Array(flippedPoints), knots: mirroredKnots,
                degree: degree, weights: flippedWeights, color: color)
        default:
            return nil
        }
    }

    static func reversed(_ path: CADPolyline) -> CADPolyline {
        let vertices = path.vertices
        guard vertices.count > 1 else { return path }
        if path.isClosed {
            // Keep the start vertex fixed, reverse the rest: new vertex 0
            // is v0, new vertex j≥1 is old v(n+1−j). New segment j is the
            // reverse of old segment (closing segment for j=0, segment
            // n+1−j otherwise): bulges negate, widths swap.
            let count = vertices.count
            var flipped: [CADPolylineVertex] = []
            flipped.reserveCapacity(count)
            flipped.append(vertices[0])
            for j in 1..<count {
                // New segment j runs old v(oldIndex)→v(oldIndex−1): the
                // reverse of old segment (oldIndex−1).
                let oldIndex = count - j
                let sourceSegment = vertices[oldIndex - 1]
                var vertex = vertices[oldIndex]
                vertex.bulge = -sourceSegment.bulge
                vertex.startWidth = sourceSegment.endWidth
                vertex.endWidth = sourceSegment.startWidth
                flipped.append(vertex)
            }
            // New vertex 0 leaves along the reversed closing segment.
            flipped[0].bulge = -vertices[count - 1].bulge
            flipped[0].startWidth = vertices[count - 1].endWidth
            flipped[0].endWidth = vertices[count - 1].startWidth
            var result = path
            result.vertices = flipped
            return result
        }
        // Open: full reversal. New vertex j takes the reversed segment
        // n−1−j (bulge negated, widths swapped); the new last vertex
        // carries no outgoing segment.
        let count = vertices.count
        var flipped: [CADPolylineVertex] = []
        flipped.reserveCapacity(count)
        for j in 0..<count {
            var vertex = vertices[count - 1 - j]
            if j < count - 1 {
                let source = vertices[count - 2 - j]
                vertex.bulge = -source.bulge
                vertex.startWidth = source.endWidth
                vertex.endWidth = source.startWidth
            } else {
                // New last vertex has no outgoing segment: carry the old
                // tail values verbatim so double-reverse is exact.
                let tail = vertices[count - 1]
                vertex.bulge = tail.bulge
                vertex.startWidth = tail.startWidth
                vertex.endWidth = tail.endWidth
            }
            flipped.append(vertex)
        }
        var result = path
        result.vertices = flipped
        return result
    }
}

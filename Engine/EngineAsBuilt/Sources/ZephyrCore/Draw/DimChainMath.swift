// Sources/ZephyrCore/Draw/DimChainMath.swift
import Foundation

/// Pure chaining math for DIMCONTINUE (DCO) and DIMBASELINE (DBA).
/// A chain anchors on one source dimension's stored definition points:
/// defPoint is the source dimline position, defPoint2/defPoint3 are the
/// first/second extension origins, rotationAngle is the measured direction
/// (0 or pi/2 for linear, arbitrary for aligned). The general projection
/// form below degenerates exactly to DimLinearCommand's axis math, so
/// chained linear dims match hand-placed ones.
public enum DimChainMath {
    public struct SourceChain: Sendable, Hashable {
        /// Source defPoint2. Baseline chains always measure from here.
        public var baseOrigin: Vector3
        /// Source defPoint3. Continue chains measure from here, then advance
        /// it to each newly picked origin.
        public var prevOrigin: Vector3
        /// Source defPoint: the shared dimline position.
        public var dimLinePos: Vector3
        /// Source rotationAngle: measured direction.
        public var angle: Double
        /// False for aligned sources (full distance), true for linear
        /// (projected distance, mirroring DimLinearCommand).
        public var isLinear: Bool
    }

    public struct ChainedDim {
        public var p1: Vector3
        public var p2: Vector3
        public var dimLinePos: Vector3
        public var dimStart: Vector3
        public var dimEnd: Vector3
        public var textMidpoint: Vector3
        public var measurement: Double
        public var angle: Double
        public var type: CADDimensionType
    }

    /// Nil unless the metadata is a linear or aligned dimension with
    /// distinct extension origins.
    public static func resolveSource(from metadata: CADDimensionMetadata) -> SourceChain? {
        guard metadata.type == .linearOrRotated || metadata.type == .aligned else {
            return nil
        }
        guard let d3 = metadata.defPoint3 else { return nil }
        let dx = d3.x - metadata.defPoint2.x
        let dy = d3.y - metadata.defPoint2.y
        guard hypot(dx, dy) > 0 else { return nil }
        return SourceChain(
            baseOrigin: metadata.defPoint2,
            prevOrigin: d3,
            dimLinePos: metadata.defPoint,
            angle: metadata.rotationAngle,
            isLinear: metadata.type == .linearOrRotated)
    }

    /// Next continue dimension: first origin is the previous second
    /// origin, dimline unchanged. Nil for a coincident pick.
    public static func continueNext(
        from state: SourceChain, picked: Vector3
    ) -> ChainedDim? {
        build(
            p1: state.prevOrigin, p2: picked, dimLinePos: state.dimLinePos,
            angle: state.angle, isLinear: state.isLinear)
    }

    /// Next baseline dimension: first origin stays at the base, dimline
    /// stacks outward by spacing per step (1-based). Nil for a coincident
    /// pick. Spacing is the scaled DIMDLI value.
    public static func baselineNext(
        from state: SourceChain, picked: Vector3,
        stackIndex: Int, spacing: Double
    ) -> ChainedDim? {
        let u = Vector3(x: cos(state.angle), y: sin(state.angle), z: 0)
        let n = Vector3(x: -u.y, y: u.x, z: 0)
        let toFeature = Vector3(
            x: state.dimLinePos.x - state.baseOrigin.x,
            y: state.dimLinePos.y - state.baseOrigin.y, z: 0)
        let sign = (toFeature.x * n.x + toFeature.y * n.y) < 0 ? -1.0 : 1.0
        let stacked = Vector3(
            x: state.dimLinePos.x + n.x * sign * spacing * Double(stackIndex),
            y: state.dimLinePos.y + n.y * sign * spacing * Double(stackIndex), z: 0)
        return build(
            p1: state.baseOrigin, p2: picked, dimLinePos: stacked,
            angle: state.angle, isLinear: state.isLinear)
    }

    /// Primitives for a chained dim, mirroring DimLinearCommand's assembly.
    /// MainActor like the DimensionPrimitives builders it calls; the pure
    /// math above stays nonisolated so tests call it directly.
    @MainActor
    public static func buildPrimitives(
        _ chained: ChainedDim, style: CADDimensionStyle, color: ColorRGBA
    ) -> [CADPrimitive] {
        let valueStr = style.formatMeasurement(chained.measurement)
        var primitives: [CADPrimitive] = []
        primitives.append(contentsOf: DimensionPrimitives.extensionLines(
            feature1: chained.p1, feature2: chained.p2,
            dimLineStart: chained.dimStart, dimLineEnd: chained.dimEnd,
            style: style, color: color))
        primitives.append(contentsOf: DimensionPrimitives.dimensionLine(
            from: chained.dimStart, to: chained.dimEnd,
            arrowAtStart: true, arrowAtEnd: true, style: style, color: color))
        primitives.append(DimensionPrimitives.dimensionText(
            position: chained.textMidpoint, value: valueStr,
            rotation: chained.angle, style: style, color: color))
        return primitives
    }

    private static func build(
        p1: Vector3, p2: Vector3, dimLinePos: Vector3,
        angle: Double, isLinear: Bool
    ) -> ChainedDim? {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        guard hypot(dx, dy) > 0 else { return nil }
        let u = Vector3(x: cos(angle), y: sin(angle), z: 0)
        let n = Vector3(x: -u.y, y: u.x, z: 0)
        let v = Vector3(x: dimLinePos.x - p1.x, y: dimLinePos.y - p1.y, z: 0)
        let offset = v.x * n.x + v.y * n.y
        let dimStart = Vector3(x: p1.x + n.x * offset, y: p1.y + n.y * offset, z: 0)
        let dimEnd = Vector3(x: p2.x + n.x * offset, y: p2.y + n.y * offset, z: 0)
        let measurement = isLinear ? abs(dx * u.x + dy * u.y) : hypot(dx, dy)
        return ChainedDim(
            p1: p1, p2: p2, dimLinePos: dimLinePos,
            dimStart: dimStart, dimEnd: dimEnd,
            textMidpoint: Vector3(
                x: (dimStart.x + dimEnd.x) / 2.0,
                y: (dimStart.y + dimEnd.y) / 2.0, z: 0),
            measurement: measurement, angle: angle,
            type: isLinear ? .linearOrRotated : .aligned)
    }
}

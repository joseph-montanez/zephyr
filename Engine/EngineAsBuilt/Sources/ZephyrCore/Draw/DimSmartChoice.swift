// Sources/ZephyrCore/Draw/DimSmartChoice.swift
import Foundation

/// Pure selection analysis for smart DIM (Phase 2.1). Chooses the dimension
/// type from the selection/context; the command announces the pick with a
/// result line (kind + evidence) and transfers to that type's normal flow,
/// so a wrong guess is visible and overridable instead of silent.
public enum DimSmartKind: Sendable, Hashable {
    case diameter
    case radius
    case linear
    case aligned
    case angular
    case cont
}

public struct DimSmartChoice: Sendable, Hashable {
    public var kind: DimSmartKind
    /// Evidence fragment, e.g. "circle (radius 5.000)".
    public var detail: String

    /// Canonical transfer target for the choice.
    public var targetCommand: String {
        switch kind {
        case .diameter: return "DIMDIAMETER"
        case .radius: return "DIMRADIUS"
        case .linear: return "DIMLINEAR"
        case .aligned: return "DIMALIGNED"
        case .angular: return "DIMANGULAR"
        case .cont: return "DIMCONTINUE"
        }
    }

    /// The contradicting-but-confirming line: names the chosen type and the
    /// evidence behind it.
    public func resultLine() -> String {
        let label: String
        switch kind {
        case .diameter: label = "Diameter"
        case .radius: label = "Radius"
        case .linear: label = "Linear"
        case .aligned: label = "Aligned"
        case .angular: label = "Angular"
        case .cont: label = "Continue"
        }
        return "[CAD] DIM: \(label) from \(detail)."
    }

    /// Nil when the selection is empty or ambiguous. A lone dimension
    /// entity chains; block references never count as raw geometry.
    public static func resolve(
        entities: [CADEntity], in document: CADDocument
    ) -> DimSmartChoice? {
        guard !entities.isEmpty else { return nil }
        if entities.count == 1,
           entities[0].dimensionMetadata != nil {
            return DimSmartChoice(kind: .cont, detail: "selected dimension")
        }
        var circles: [(center: Vector3, radius: Double)] = []
        var arcs: [(center: Vector3, radius: Double)] = []
        var lines: [(start: Vector3, end: Vector3)] = []
        for entity in entities {
            guard entity.blockID == nil else { return nil }
            guard let geometry = entity.resolvedGeometry(in: document) else { return nil }
            for prim in geometry {
                switch prim {
                case .circle(let center, let radius, _):
                    circles.append((center, radius))
                case .arc(let center, let radius, _, _, _):
                    arcs.append((center, radius))
                case .line(let start, let end, _):
                    lines.append((start, end))
                default:
                    return nil
                }
            }
        }
        let style = document.currentDimensionStyle()
        if circles.count == 1, arcs.isEmpty, lines.isEmpty {
            let radius = circles[0].radius
            return DimSmartChoice(
                kind: .diameter,
                detail: "circle (radius \(style.formatMeasurement(radius)))")
        }
        if arcs.count == 1, circles.isEmpty, lines.isEmpty {
            let radius = arcs[0].radius
            return DimSmartChoice(
                kind: .radius,
                detail: "arc (radius \(style.formatMeasurement(radius)))")
        }
        if lines.count == 1, circles.isEmpty, arcs.isEmpty {
            let line = lines[0]
            let dx = line.end.x - line.start.x
            let dy = line.end.y - line.start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return nil }
            let kind: DimSmartKind = (dx == 0 || dy == 0) ? .linear : .aligned
            let label = kind == .linear ? "line" : "angled line"
            return DimSmartChoice(
                kind: kind,
                detail: "\(label) (length \(style.formatMeasurement(length)))")
        }
        if lines.count == 2, circles.isEmpty, arcs.isEmpty {
            return DimSmartChoice(kind: .angular, detail: "2 lines")
        }
        return nil
    }
}

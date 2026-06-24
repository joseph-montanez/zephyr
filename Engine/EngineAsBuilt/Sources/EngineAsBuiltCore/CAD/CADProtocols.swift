import Foundation

// =========================================================================
// MARK: - CADProtocols
//
// Shared protocol types used across the CAD subsystem:
//   - AnchorPoint: Local-space snap anchor definitions (vertex, midpoint,
//     center, insertion, quadrant, nearest). Used by SnapEngine and
//     CADSelectionManager for precision cursor snapping and grip editing.
//   - CADStyle: Entity drawing style (color, weight, line type, draw order).
//   - SnapResult: The result of a snap query — the nearest anchor point
//     to the cursor within the snap threshold.
//   - Layer, CADBlock, CADConstraint, CADUnit: Supporting value types.

// =========================================================================
// MARK: - AnchorPoint
// =========================================================================

/// All positions are stored in **local space** (relative to entity origin / block origin).
/// The snap engine applies `entity.transform.transformPoint()` to get world-space on the fly.
/// This keeps transactions instant — moving an entity never requires recalculating anchors.
public enum AnchorPoint: Hashable, Sendable {
    case center(localPosition: Vector3)
    case vertex(localPosition: Vector3, index: Int)
    case midpoint(localPosition: Vector3, segmentIndex: Int)
    case insertionPoint(localPosition: Vector3)
    case quadrant(localPosition: Vector3, index: Int)
    /// Nearest point ON a curve (arc, circle, ellipse, spline) to the cursor.
    /// Unlike the other cases this is never cached on the entity — it is
    /// computed per-frame by the snap engine, since the position depends on
    /// where the cursor is.
    case nearest(localPosition: Vector3)

    /// World-space position for this anchor given an entity's transform.
    public func worldPosition(transform: Transform3D) -> Vector3 {
        let local: Vector3
        switch self {
        case .center(let p):        local = p
        case .vertex(let p, _):     local = p
        case .midpoint(let p, _):   local = p
        case .insertionPoint(let p): local = p
        case .quadrant(let p, _):   local = p
        case .nearest(let p):       local = p
        }
        return transform.transformPoint(local)
    }
}

// =========================================================================
// MARK: - XDataValue
// =========================================================================

/// Schema-based metadata dictionary value for "as-built" tracking.
public enum XDataValue: Hashable, Sendable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case date(Date)
}

// =========================================================================
// MARK: - Entity Protocol
// =========================================================================

/// Core protocol for all CAD entities. Does **not** require AnyObject —
/// CADEntity is a struct so snapshots capture independent value copies.
public protocol Entity {
    /// Immutable cross-referencing handle.
    var handle: UUID { get }
    /// References the global LayerTable for visibility, line weight, and color state.
    var layerID: UUID { get set }
    /// World-space position, orientation, and scale.
    var transform: Transform3D { get set }
}

// =========================================================================
// MARK: - Snappable Protocol
// =========================================================================

/// Entities that provide anchor points for precision drafting snapping.
public protocol Snappable {
    /// Cached anchor points in local space.
    var anchorPoints: [AnchorPoint] { get }
    /// Recompute anchor points from the entity's geometry.
    mutating func updateAnchorCache()
}

// =========================================================================
// MARK: - AttributeAttachable Protocol
// =========================================================================

/// Entities that carry "As-Built" metadata (serial numbers, install dates, contractor notes, etc.).
public protocol AttributeAttachable {
    /// Schema-based dictionary for extensible metadata.
    var xdata: [String: XDataValue] { get set }
}
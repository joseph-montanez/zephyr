import Foundation

// =========================================================================
// MARK: - CADConstraint
//
// Represents geometric and dimensional constraints between CAD entities.
// Supports parametric sketching with constraint types like horizontal,
// vertical, parallel, perpendicular, tangent, coincident, and
// dimensional constraints (distance, angle, radius).
//
// Constraints are solved via a numerical solver; the results are cached
// as solvedTransforms in the CADDocument.

// =========================================================================
// MARK: - ConstraintType
// =========================================================================

/// The kind of geometric or dimensional constraint.
@frozen
public enum ConstraintType: UInt8, Sendable, CaseIterable {
    case coincident    = 0
    case parallel      = 1
    case perpendicular = 2
    case tangent       = 3
    case concentric    = 4
    case horizontal    = 5
    case vertical      = 6
    case equal         = 7
    case distance      = 8
    case angle         = 9
    case fix           = 10
    case midpoint      = 11
    case collinear     = 12
    case symmetric     = 13
    case offset        = 14
}

// =========================================================================
// MARK: - ConstraintSubEntity
// =========================================================================

/// Which sub-part of an entity a constraint targets.
@frozen
public enum ConstraintSubEntity: UInt8, Sendable, CaseIterable {
    case entire       = 0
    case point        = 1
    case line         = 2
    case circleOrArc  = 3
    case center       = 4
}

// =========================================================================
// MARK: - CADConstraint
// =========================================================================

/// A geometric or dimensional constraint between one or two entities.
/// Stored separately from entities so the constraint graph persists across
/// save/load and the solver can work with solved-state transforms independently.
public struct CADConstraint: Hashable, Sendable {
    /// Immutable handle for cross-referencing.
    public let handle: UUID
    /// The type of constraint (coincident, distance, parallel, etc.).
    public var type: ConstraintType
    /// Primary entity handle. Always required.
    public var entityA: UUID
    /// Secondary entity handle. Nil for unary constraints (fix, horizontal, vertical).
    public var entityB: UUID?
    /// Which sub-part of entity A is constrained.
    public var subEntityA: ConstraintSubEntity
    /// Anchor/vertex index within entity A's sub-part (0 if entire).
    public var subIndexA: UInt8
    /// Which sub-part of entity B is constrained.
    public var subEntityB: ConstraintSubEntity
    /// Anchor/vertex index within entity B's sub-part.
    public var subIndexB: UInt8
    /// Dimensional parameters (e.g. [distanceValue] for distance, [angleRadians] for angle).
    public var params: [Double]
    /// Whether this constraint is currently active in the solver.
    public var isEnabled: Bool
    /// When true this is a driven/reference dimension (not enforced).
    public var isDriven: Bool

    public init(
        handle: UUID = UUID(),
        type: ConstraintType,
        entityA: UUID,
        entityB: UUID? = nil,
        subEntityA: ConstraintSubEntity = .entire,
        subIndexA: UInt8 = 0,
        subEntityB: ConstraintSubEntity = .entire,
        subIndexB: UInt8 = 0,
        params: [Double] = [],
        isEnabled: Bool = true,
        isDriven: Bool = false
    ) {
        self.handle = handle
        self.type = type
        self.entityA = entityA
        self.entityB = entityB
        self.subEntityA = subEntityA
        self.subIndexA = subIndexA
        self.subEntityB = subEntityB
        self.subIndexB = subIndexB
        self.params = params
        self.isEnabled = isEnabled
        self.isDriven = isDriven
    }

    /// Returns true if this is a unary constraint (operates on a single entity).
    public var isUnary: Bool {
        switch type {
        case .fix, .horizontal, .vertical: return true
        default: return entityB == nil
        }
    }
}

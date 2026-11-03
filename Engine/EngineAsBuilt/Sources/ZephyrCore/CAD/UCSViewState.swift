import Foundation
import ZephyrKernel

// =========================================================================
// MARK: - UCSViewState (planar, per drawing view)
//
// Session state for one drawing view's user coordinate system. The stored
// frame is always planar: origin plus a canonical CCW angle in the WCS XY
// plane (see `UCSDefinition`). Undo, persistence, sysvars, named UCS
// records, and per-pane overrides are intentionally later work; this type
// only owns the live frame plus a bounded previous-UCS stack.
// =========================================================================

/// One saved UCS frame on the previous-UCS stack.
public struct UCSBookmark: Sendable, Equatable {
    public var definition: UCSDefinition
    public var name: String

    public init(definition: UCSDefinition = .identity, name: String = "*WORLD*") {
        self.definition = definition
        self.name = name
    }
}

public struct UCSViewState: Sendable, Equatable {
    /// AutoCAD keeps at least ten previous UCS definitions available.
    public static let maxPreviousDepth = 10

    public var definition: UCSDefinition
    public var name: String
    public var previous: [UCSBookmark]

    public init(
        definition: UCSDefinition = .identity,
        name: String = "*WORLD*",
        previous: [UCSBookmark] = []
    ) {
        self.definition = definition
        self.name = name
        self.previous = previous
    }

    public static let world = UCSViewState()

    /// Replace the current frame, pushing the displaced frame first.
    public mutating func commit(definition: UCSDefinition, name: String) {
        previous.append(UCSBookmark(definition: self.definition, name: self.name))
        if previous.count > Self.maxPreviousDepth {
            previous.removeFirst(previous.count - Self.maxPreviousDepth)
        }
        self.definition = definition
        self.name = name
    }

    /// Restore the most recent previous frame. False when the stack is empty.
    @discardableResult
    public mutating func restorePrevious() -> Bool {
        guard let bookmark = previous.popLast() else { return false }
        definition = bookmark.definition
        name = bookmark.name
        return true
    }

    // MARK: - Typed points in the current UCS

    /// Convert frame-free parsed user input into a WCS point.
    ///
    /// Absolute coordinates are interpreted in the current UCS: the XY
    /// components ride the UCS axes and an explicit Z rides the shared
    /// world axis above the UCS origin. Relative and polar inputs are
    /// displacements from the UCS origin under the supplied convention.
    public func worldOrigin(
        from input: UserPointInput,
        convention: AngleConvention = .default
    ) -> Point3d {
        switch input {
        case .absolute(let x, let y, let z):
            let planar = definition.toWorld(Point2d(x: x, y: y))
            return Point3d(x: planar.x, y: planar.y, z: definition.origin.z + (z ?? 0))
        case .relative(let dx, let dy, let dz):
            let displacement = definition.toWorld(direction: Vec2d(x: dx, y: dy))
            return Point3d(
                x: definition.origin.x + displacement.x,
                y: definition.origin.y + displacement.y,
                z: definition.origin.z + (dz ?? 0))
        case .polar(let distance, let userDegrees):
            let canonical = convention.canonicalOrientation(
                fromUser: userDegrees * .pi / 180.0)
            let displacement = definition.toWorld(
                direction: Vec2d(x: distance * cos(canonical), y: distance * sin(canonical)))
            return Point3d(
                x: definition.origin.x + displacement.x,
                y: definition.origin.y + displacement.y,
                z: definition.origin.z)
        }
    }

    // MARK: - Planar three-point validation

    /// Normalized sine of origin -> xPoint versus origin -> yPoint.
    /// Positive means yPoint lies on the positive-Y side of the X axis.
    public static func planarSine(
        origin: Point3d,
        xPoint: Point3d,
        yPoint: Point3d
    ) -> Double? {
        let ex = Vec2d(x: xPoint.x - origin.x, y: xPoint.y - origin.y)
        let ey = Vec2d(x: yPoint.x - origin.x, y: yPoint.y - origin.y)
        let exLen = ex.length
        let eyLen = ey.length
        guard exLen >= KernelTolerance.linear, eyLen >= KernelTolerance.linear else {
            return nil
        }
        return ex.cross(ey) / (exLen * eyLen)
    }

    /// AutoCAD-style planar acceptance: non-degenerate and on the
    /// positive-Y side of the X axis.
    public static func acceptsThreePoints(
        origin: Point3d,
        xPoint: Point3d,
        yPoint: Point3d
    ) -> Bool {
        guard UCSDefinition.validateThreePoints(
            origin: origin, xPoint: xPoint, yPoint: yPoint
        ) else {
            return false
        }
        guard let sine = planarSine(origin: origin, xPoint: xPoint, yPoint: yPoint) else {
            return false
        }
        return sine > 1e-9
    }
}

import Foundation

// =========================================================================
// MARK: - CADSnapTracking
//
// Object Snap Tracking (OTRACK) engine. Acquires temporary tracking points
// by hovering over entity snap points, then provides alignment-line
// intersection snapping as the cursor moves.
//
// **Acquisition (time-based dwell):**
//   - Hover cursor over a discrete snap point (endpoint, midpoint, center, etc.)
//     for `dwellTimeMs` (default 500ms) → the point is "acquired" and
//     a `+` marker appears at its world position.
//   - Hovering over an already-acquired tracking point for 500ms → toggles it OFF.
//   - Max 7 tracking points (AutoCAD convention).
//   - All tracking points are cleared on mouse click or Escape.
//
// **Alignment snapping:**
//   - From each tracking point, alignment lines are cast at polar angle increments.
//   - When cursor approaches an alignment line, it snaps to the projection.
//   - When cursor is near the intersection of two alignment lines, it snaps to 
//     the intersection (higher priority than single-line projection).
// =========================================================================

/// Represents a single acquired tracking point in world space.
public struct TrackingPoint: Hashable, Sendable {
    /// The exact world coordinate of the snapped geometry vertex/center.
    public let worldPos: Vector3
    /// The UUID of the entity this point belongs to (useful for highlighting/references).
    public let entityHandle: UUID
    /// The exact tick time this point was locked in.
    public let acquiredAt: UInt64

    public init(worldPos: Vector3, entityHandle: UUID, acquiredAt: UInt64) {
        self.worldPos = worldPos
        self.entityHandle = entityHandle
        self.acquiredAt = acquiredAt
    }
}

public final class SnapTrackingEngine {
    // AutoCAD traditionally limits OTRACK points to 7 to prevent visual clutter
    // and mathematical combinatorial explosion during intersection checks.
    public static let maxTrackingPoints = 7
    
    // How long the user must hold the mouse perfectly still over a vertex to acquire it.
    public var dwellTimeMs: UInt64 = 500
    
    // The currently active list of points we are projecting tracking lines from.
    public private(set) var trackingPoints: [TrackingPoint] = []

    // MARK: - Hover State Machine Variables
    // These track the cursor's behavior while hovering over a potential point
    // to determine if the user is intentionally lingering to acquire it.
    
    /// The geometric snap point the cursor is currently resting on.
    private var pendingSnap: SnapResult? = nil
    /// The timestamp when the cursor first rested on `pendingSnap`.
    private var pendingSince: UInt64 = 0
    /// The exact world X coordinate where the dwell timer started.
    private var pendingCursorX: Double = 0
    /// The exact world Y coordinate where the dwell timer started.
    private var pendingCursorY: Double = 0
    public init() {}

    // MARK: - Main Update Loop

    /// Called every frame to evaluate hover timers and compute tracking alignments.
    /// - Parameters:
    ///   - currentSnap: The Tier 1/2 discrete snap found by `CADSnapEngine` this frame.
    ///   - cursorWorld: The actual world coordinates of the mouse cursor.
    ///   - polarIncrementDeg: The angle step (e.g., 45, 90) to cast tracking lines at.
    ///   - snapThresholdWorld: The viewport-scaled distance (in world units) to trigger a snap.
    ///   - nowTicks: The current SDL frame time.
    /// - Returns: A new `SnapResult` if the cursor should be hijacked by an OTRACK line/intersection.
    public func update(
        currentSnap: SnapResult?,
        cursorWorld: Vector3,
        polarIncrementDeg: Double,
        snapThresholdWorld: Double,
        wiggleThresholdWorld: Double,
        nowTicks: UInt64
    ) -> SnapResult? {
        
        // Step 1: Manage the 500ms hover timers (adding/removing tracking points)
        updateAcquisition(currentSnap: currentSnap, cursorWorld: cursorWorld, wiggleThresholdWorld: wiggleThresholdWorld, nowTicks: nowTicks)
        
        // Step 2: If we have points, do the heavy math to see if the cursor is near any projected lines
        guard !trackingPoints.isEmpty else { return nil }
        return computeAlignmentSnap(
            cursor: cursorWorld, 
            polarIncrementDeg: polarIncrementDeg, 
            threshold: snapThresholdWorld
        )
    }

    /// Manually bypasses the timer and injects a tracking point immediately.
    public func acquire(worldPos: Vector3, entityHandle: UUID, nowTicks: UInt64) {
        guard trackingPoints.count < Self.maxTrackingPoints else { return }
        
        // Prevent duplicate tracking points at the exact same spatial location
        for tp in trackingPoints {
            if (tp.worldPos - worldPos).magnitude < 1e-6 { return }
        }
        trackingPoints.append(TrackingPoint(worldPos: worldPos, entityHandle: entityHandle, acquiredAt: nowTicks))
    }

    /// Wipes all tracking state. Called when the user clicks to place a point, or hits Escape.
    public func clear() {
        trackingPoints.removeAll()
        pendingSnap = nil
        pendingSince = 0
    }

    // MARK: - Acquisition Logic (The Dwell Timer)

    /// Updates the state machine that decides when to add or remove a tracking point.
    private func updateAcquisition(currentSnap: SnapResult?, cursorWorld: Vector3, wiggleThresholdWorld: Double, nowTicks: UInt64) {
        
        // If the cursor is floating in empty space, kill the hover timer.
        guard let snap = currentSnap else {
            pendingSnap = nil
            pendingSince = 0
            return
        }

        // We ONLY allow tracking from discrete geometry points. 
        // We do NOT allow tracking from a "nearest on curve" point, as that would be chaotic.
        switch snap.anchor {
        case .vertex, .midpoint, .center, .insertionPoint, .quadrant: 
            break // Valid targets
        case .nearest:
            pendingSnap = nil
            pendingSince = 0
            return
        }

        // Check if we are currently dwelling on the SAME point as the previous frame
        if let pending = pendingSnap, pending.worldPos == snap.worldPos {
            
            // Calculate how far the user has physically moved the mouse since the timer started.
            let dx = cursorWorld.x - pendingCursorX
            let dy = cursorWorld.y - pendingCursorY
            let moveDist = sqrt(dx * dx + dy * dy)
            
            // If they are jittering the mouse outside the allowed pixel radius, 
            // reset the timer but keep tracking this point as the target.
            if moveDist > wiggleThresholdWorld {
                pendingSince = nowTicks
                pendingCursorX = cursorWorld.x
                pendingCursorY = cursorWorld.y
                return
            }
            
            // THE TIMER CHECK: Has the cursor remained still for >= 500ms?
            if nowTicks - pendingSince >= dwellTimeMs {
                
                // Toggle Logic: 
                // Does this exact coordinate already exist in our tracking list?
                if let idx = trackingPoints.firstIndex(where: { ($0.worldPos - snap.worldPos).magnitude < 2.0 }) {
                    // It exists! The user hovered over it again to turn it OFF.
                    trackingPoints.remove(at: idx)
                } else {
                    // It doesn't exist! The user wants to turn it ON.
                    if trackingPoints.count < Self.maxTrackingPoints {
                        trackingPoints.append(
                            TrackingPoint(worldPos: snap.worldPos, entityHandle: snap.entityHandle, acquiredAt: nowTicks)
                        )
                    }
                }
                
                // Reset the pending state completely so the user is required to 
                // move away and come back (or sit for another full 500ms) to toggle it again.
                pendingSnap = nil
                pendingSince = 0
            }
        } else {
            // The cursor just landed on a new, valid snap point.
            // Start a fresh 500ms countdown timer right now.
            pendingSnap = snap
            pendingSince = nowTicks
            pendingCursorX = cursorWorld.x
            pendingCursorY = cursorWorld.y
        }
    }

    // MARK: - Mathematical Projection Logic

    /// Computes the closest alignment line or line intersection to the cursor.
    private func computeAlignmentSnap(cursor: Vector3, polarIncrementDeg: Double, threshold: Double) -> SnapResult? {
        // Convert our polar increment (e.g. 45 degrees) into an array of radians [0, π/4, π/2, ...]
        let angles = PolarTracking.polarAnglesRad(incrementDeg: polarIncrementDeg)
        
        // ...and the best two-line intersection (Intersections always win over single lines)
        var bestIntersection: SnapResult? = nil
        var bestInterDist = threshold

        // ---------------------------------------------------------------------
        // Pass 1: Intersection of Two Tracking Lines
        // If we have >= 2 tracking points, cast rays from ALL of them and find 
        // where they cross. If the cursor is near a crossing, snap to it.
        // ---------------------------------------------------------------------
        if trackingPoints.count >= 2 {
            // Loop through every unique pair of tracking points
            for i in 0..<(trackingPoints.count - 1) {
                for j in (i + 1)..<trackingPoints.count {
                    
                    // For point A, check every angle...
                    for a1 in angles {
                        // For point B, check every angle...
                        for a2 in angles {
                            
                            // Direction vectors for ray 1 (from point A) and ray 2 (from point B)
                            let d1x = cos(a1), d1y = sin(a1)
                            let d2x = cos(a2), d2y = sin(a2)

                            // Cross product of the two direction vectors.
                            // If cross product is 0 (or close to it), the lines are parallel and never intersect.
                            let crossProd = d1x * d2y - d1y * d2x
                            guard abs(crossProd) > 1e-9 else { continue }
                            
                            let p1 = trackingPoints[i].worldPos
                            let p2 = trackingPoints[j].worldPos
                            
                            // Solve the linear system to find the intersection using Cramer's rule.
                            // t1 is the distance along ray 1 where they cross.
                            // t2 is the distance along ray 2 where they cross.
                            let dx = p2.x - p1.x
                            let dy = p2.y - p1.y
                            let t1 = (dx * d2y - dy * d2x) / crossProd
                            let t2 = (dx * d1y - dy * d1x) / crossProd
                            
                            // The intersection MUST be geometrically ahead of both origin points
                            // (We only cast rays outward, not infinitely in both directions)
                            guard t1 > 0, t2 > 0 else { continue }
                            
                            // Calculate the exact (X,Y) world coordinate of the intersection
                            let ix = p1.x + t1 * d1x
                            let iy = p1.y + t1 * d1y
                            
                            // How close is the cursor to this exact intersection?
                            // Euclidean distance — use hypot for numeric stability.
                            let interDist = hypot(cursor.x - ix, cursor.y - iy)
                            
                            if interDist < bestInterDist {
                                bestInterDist = interDist
                                // Intersections use the entity handle of the first point 
                                // (AutoCAD convention mostly uses this for grouping)
                                bestIntersection = SnapResult(
                                    entityHandle: trackingPoints[i].entityHandle, 
                                    anchor: .nearest(localPosition: Vector3(x: ix, y: iy, z: 0)), 
                                    worldPos: Vector3(x: ix, y: iy, z: 0)
                                )
                            }
                        }
                    }
                }
            }
        }
        
        // ---------------------------------------------------------------------
        // Pass 2: Single Line Snap (Only if no intersection was found)
        // Check if the cursor is currently aligned with ANY of the tracking 
        // points along one of the polar increment angles.
        // ---------------------------------------------------------------------
        if bestIntersection == nil {
            var bestSingle: SnapResult? = nil
            var bestSingleDist = threshold
            
            for tp in trackingPoints {
                // The position of the tracking point we are checking
                let originX = tp.worldPos.x
                let originY = tp.worldPos.y
                
                // Difference between cursor and this tracking point
                let dx = cursor.x - originX
                let dy = cursor.y - originY
                let distToOrigin = hypot(dx, dy)
                
                // If the cursor is exactly ON the origin point, we don't snap to an angle
                guard distToOrigin > 1e-9 else { continue }
                
                // What angle is the cursor currently at relative to the origin?
                let currentAngle = atan2(dy, dx)
                
                // For every valid polar tracking angle (e.g. 0, 45, 90, 135...)
                for targetAngle in angles {
                    // Compute the angular difference, normalized between -pi and pi
                    var diff = currentAngle - targetAngle
                    while diff < -.pi { diff += 2 * .pi }
                    while diff > .pi { diff -= 2 * .pi }
                    
                    // We only care if the cursor is somewhat close to the tracking angle
                    // (Checking within +/- 20 degrees to optimize performance)
                    if abs(diff) < 20.0 * .pi / 180.0 {
                        
                        // Perpendicular distance from the cursor to the infinite tracking line
                        let perpDist = distToOrigin * sin(abs(diff))
                        
                        // If the cursor is close enough to the line to "snap" to it
                        if perpDist < bestSingleDist {
                            bestSingleDist = perpDist
                            
                            // Project the cursor's position directly onto the tracking line
                            let projDist = distToOrigin * cos(diff)
                            let projX = originX + cos(targetAngle) * projDist
                            let projY = originY + sin(targetAngle) * projDist
                            
                            bestSingle = SnapResult(
                                entityHandle: tp.entityHandle,
                                anchor: .nearest(localPosition: Vector3(x: projX, y: projY, z: 0)),
                                worldPos: Vector3(x: projX, y: projY, z: 0)
                            )
                        }
                    }
                }
            }
            return bestSingle
        }
        
        return bestIntersection
    }
}
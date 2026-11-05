import Foundation

// =========================================================================
// MARK: - CADSelectionDisplayPolicy
//
// How a selection set is *displayed*, following AutoCAD:
//
// - GRIPOBJLIMIT: when the selection exceeds the limit, grip generation
//   is suppressed entirely. Entities stay highlighted by their geometry;
//   grips are never replaced with per-entity bounding boxes.
// - SELECTIONPREVIEWLIMIT: when a window/crossing preview exceeds the
//   limit, real-time preview highlighting is disabled for the whole set.
// - GROUPDISPLAYMODE: a group collapses to a single frame around the
//   union of its members' bounds (see `unionBounds(of:)`), never one
//   frame per member. Multiple groups each get their own frame.
// - Block references / xrefs and images may show their own bounding
//   frame (images have no line segments; complex blocks are too dense
//   to redraw as segments every frame).
//
// Pure value logic: renderers ask the policy what to draw.
// =========================================================================

public enum CADSelectionDisplayPolicy {

    public enum HighlightStyle: Equatable, Sendable {
        /// Redraw the entity's geometry segments in the highlight color.
        case geometry
        /// Draw the entity's world bounding box as a frame.
        case boundingFrame
    }

    /// AutoCAD GRIPOBJLIMIT default.
    public static let defaultGripObjectLimit = 100

    /// Engine default for SELECTIONPREVIEWLIMIT (entity count). Above
    /// this the rect-select live preview draws no highlight at all.
    public static let defaultSelectionPreviewLimit = 2000

    /// Block references with more primitives than this highlight as a
    /// frame instead of redrawing every segment.
    public static let complexBlockPrimitiveThreshold = 50

    // MARK: - GRIPOBJLIMIT

    public static func gripsSuppressed(
        selectedCount: Int, gripObjectLimit: Int
    ) -> Bool {
        selectedCount > gripObjectLimit
    }

    /// Handles eligible for grip generation: empty when suppressed, so
    /// no grips are generated, drawn, hovered, or dragged.
    public static func gripHandles(
        selectedHandles: Set<UUID>, gripObjectLimit: Int
    ) -> Set<UUID> {
        gripsSuppressed(
            selectedCount: selectedHandles.count,
            gripObjectLimit: gripObjectLimit) ? [] : selectedHandles
    }

    // MARK: - SELECTIONPREVIEWLIMIT

    public static func previewSuppressed(
        previewCount: Int, selectionPreviewLimit: Int
    ) -> Bool {
        previewCount > selectionPreviewLimit
    }

    // MARK: - Per-entity highlight

    /// Loose entities always highlight by geometry, regardless of
    /// primitive count or grip-limit state — AutoCAD never substitutes
    /// a wireframe box for a loose entity. Only images (no segments)
    /// and complex block/xref references use a frame.
    public static func highlightStyle(
        isImage: Bool, isBlockReference: Bool, primitiveCount: Int
    ) -> HighlightStyle {
        if isImage { return .boundingFrame }
        if isBlockReference && primitiveCount > complexBlockPrimitiveThreshold {
            return .boundingFrame
        }
        return .geometry
    }

    // MARK: - Hatch boundary highlight

    /// Boundary outline loops (outer + holes, model space, closed) for
    /// pattern-hatch primitives. Selecting a hatch highlights only its
    /// boundary outline in the selection color — the pattern lines keep
    /// their own colors (AutoCAD shows grips on the boundary, not a
    /// re-tinted fill). Returns [] when the geometry has no `.hatch` /
    /// `.hatchPath` content. Loops shorter than 2 points are dropped;
    /// closed loops repeat their first point at the end.
    public static func hatchBoundaryLoops(in geometry: [CADPrimitive]) -> [[Vector3]] {
        var loops: [[Vector3]] = []
        for primitive in geometry {
            switch primitive {
            case .hatchPath(let boundary, let holes, _, _, _, _, _):
                if let outer = closedLoop(boundary.tessellatedPoints()) {
                    loops.append(outer)
                }
                for hole in holes {
                    if let loop = closedLoop(hole.tessellatedPoints()) {
                        loops.append(loop)
                    }
                }
            case .hatch(let boundary, _, _, _, _, _):
                let split = CADPrimitiveGenerator.splitConnectedHatchBoundary(boundary)
                if let outer = closedLoop(split.outer) {
                    loops.append(outer)
                }
                for hole in split.holes {
                    if let loop = closedLoop(hole) {
                        loops.append(loop)
                    }
                }
            default:
                break
            }
        }
        return loops
    }

    /// A drawable closed loop, or nil when the points cannot form one.
    private static func closedLoop(_ points: [Vector3]) -> [Vector3]? {
        guard points.count >= 2 else { return nil }
        guard points.count >= 3,
              let first = points.first,
              let last = points.last
        else { return points }
        let dx = first.x - last.x
        let dy = first.y - last.y
        let dz = first.z - last.z
        if dx * dx + dy * dy + dz * dz < 1e-12 { return points }
        return points + [first]
    }

    // MARK: - GROUPDISPLAYMODE

    /// The single frame for one group: union of all member bounds.
    /// `nil` for an empty group. One frame per group — call once per
    /// distinct group, never per member.
    public static func unionBounds(of boxes: [BoundingBox3D]) -> BoundingBox3D? {
        guard var result = boxes.first else { return nil }
        for box in boxes.dropFirst() {
            result = result.union(with: box)
        }
        return result
    }
}

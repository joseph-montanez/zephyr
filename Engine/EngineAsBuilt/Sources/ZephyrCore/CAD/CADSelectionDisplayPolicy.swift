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

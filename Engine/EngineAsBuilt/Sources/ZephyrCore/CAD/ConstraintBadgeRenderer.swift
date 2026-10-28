import Foundation
import ImGui

// =========================================================================
// MARK: - ConstraintBadgeRenderer (Phase 2.4)
// =========================================================================
//
// CONSTRAINTBAR overlay: one diamond badge per constrained entity at the
// top-center of its world bounding box. Anchors are a pure function of
// the document (tested directly); drawing follows the selection-highlight
// collaborator pattern. Hidden entities never get badges.
//

@MainActor
public enum ConstraintBadgeRenderer {

    /// Badge anchors: top-center of every visible constrained entity's
    /// world box, with its constraint count. Deterministic order.
    public static func badgeAnchors(
        document: CADDocument
    ) -> [(x: Double, y: Double, count: Int)] {
        var handles = Set<UUID>()
        for constraint in document.allConstraints {
            handles.insert(constraint.entityA)
            if let b = constraint.entityB { handles.insert(b) }
        }
        var out: [(x: Double, y: Double, count: Int)] = []
        for handle in handles.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entity = document.entity(for: handle),
                  let layer = document.layer(for: entity.layerID),
                  layer.isVisible,
                  let wbb = entity.worldBoundingBox else { continue }
            let count = document.constraintsAffecting(handle).count
            guard count > 0 else { continue }
            out.append((
                x: (wbb.min.x + wbb.max.x) / 2, y: wbb.max.y, count: count))
        }
        return out
    }

    /// Draws one diamond per anchor. No-op unless the document flag is on.
    public static func drawBadges(
        document: CADDocument,
        cam: CameraTransform,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) {
        guard document.showConstraintBadges else { return }
        let color = makeCol32(0, 200, 255, 255)
        let radius: Float = 6
        for anchor in badgeAnchors(document: document) {
            let center = EngineCameraManager.worldToScreen(
                worldX: anchor.x, worldY: anchor.y, cam: cam)
            let top = ImVec2(x: center.x, y: center.y - radius)
            let right = ImVec2(x: center.x + radius, y: center.y)
            let bottom = ImVec2(x: center.x, y: center.y + radius)
            let left = ImVec2(x: center.x - radius, y: center.y)
            ImDrawListAddLine(drawList, top, right, color, 2.0)
            ImDrawListAddLine(drawList, right, bottom, color, 2.0)
            ImDrawListAddLine(drawList, bottom, left, color, 2.0)
            ImDrawListAddLine(drawList, left, top, color, 2.0)
        }
    }
}

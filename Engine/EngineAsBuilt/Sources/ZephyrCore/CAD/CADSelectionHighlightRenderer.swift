import Foundation
import SwiftSDL
import ImGui

// =========================================================================
// MARK: - CADSelectionHighlightRenderer
//
// AutoCAD-style selection-highlight drawing shared by the primary and
// secondary overlays (new rendering responsibilities live in collaborators,
// not in `EngineRenderer`).
//
// Rules (see `CADSelectionDisplayPolicy`):
// - Selected entities stay highlighted by their own geometry. Grips are
//   suppressed over GRIPOBJLIMIT, but the highlight remains.
// - Loose entities never get per-entity wireframe boxes.
// - Images and complex block/xref references highlight as one bounding
//   frame each (images have no line segments; complex blocks are too
//   dense to redraw as segments every frame).
// =========================================================================

@MainActor
public enum CADSelectionHighlightRenderer {

    /// Draws gold geometry segments for every selected entity whose policy
    /// style is `.geometry`. Entities styled `.boundingFrame` are skipped
    /// for the caller's frame path. Drawing stops at `maxSegments`
    /// (AutoCAD never substitutes boxes when the budget runs out).
    public static func drawGeometryHighlights(
        handles: Set<UUID>,
        document: CADDocument,
        cam: CameraTransform,
        vertexEditor: CADVertexEditor,
        geometry: GeometryManager,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        color: UInt32,
        lineWidth: Float,
        maxSegments: Int,
        segmentsDrawn: inout Int
    ) {
        for handle in handles {
            guard segmentsDrawn < maxSegments else { break }
            guard let entity = document.entity(for: handle),
                  let layer = document.layer(for: entity.layerID), layer.isVisible,
                  let geom = entity.localGeometry ?? document.resolvedGeometry(for: entity)
            else { continue }
            let isImage = geom.contains(where: { if case .image = $0 { return true }; return false })
            guard CADSelectionDisplayPolicy.highlightStyle(
                isImage: isImage,
                isBlockReference: entity.blockID != nil,
                primitiveCount: geom.count) == .geometry
            else { continue }
            segmentsDrawn += vertexEditor.forEachWorldSegment(
                handle: handle, in: geometry,
                maxSegments: maxSegments - segmentsDrawn
            ) { x1, y1, x2, y2 in
                let s0 = EngineCameraManager.worldToScreen(worldX: x1, worldY: y1, cam: cam)
                let s1 = EngineCameraManager.worldToScreen(worldX: x2, worldY: y2, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), color, lineWidth)
            }
        }
    }

    /// Whether the entity still needs a bounding-frame highlight after
    /// geometry highlights are drawn: true for images and complex block
    /// references (policy `.boundingFrame`), false for loose entities.
    /// Pure lookup used to gate legacy box paths; tested directly.
    public static func frameRequired(handle: UUID, document: CADDocument) -> Bool {
        guard let entity = document.entity(for: handle),
              let geom = entity.localGeometry ?? document.resolvedGeometry(for: entity)
        else { return false }
        let isImage = geom.contains(where: { if case .image = $0 { return true }; return false })
        return CADSelectionDisplayPolicy.highlightStyle(
            isImage: isImage,
            isBlockReference: entity.blockID != nil,
            primitiveCount: geom.count) == .boundingFrame
    }

    /// Draws one gold selection frame around the entity's world bounding
    /// box. No-op when the entity has no bounding box. Adds 8 to `estimate`.
    public static func drawFrame(
        entity: CADEntity,
        cam: CameraTransform,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        color: UInt32,
        lineWidth: Float,
        estimate: inout Int
    ) {
        guard let wbb = entity.worldBoundingBox else { return }
        let s0 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.min.y, cam: cam)
        let s1 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.min.y, cam: cam)
        let s2 = EngineCameraManager.worldToScreen(worldX: wbb.max.x, worldY: wbb.max.y, cam: cam)
        let s3 = EngineCameraManager.worldToScreen(worldX: wbb.min.x, worldY: wbb.max.y, cam: cam)
        ImDrawListAddLine(drawList, ImVec2(x: s0.x, y: s0.y), ImVec2(x: s1.x, y: s1.y), color, lineWidth)
        ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), color, lineWidth)
        ImDrawListAddLine(drawList, ImVec2(x: s2.x, y: s2.y), ImVec2(x: s3.x, y: s3.y), color, lineWidth)
        ImDrawListAddLine(drawList, ImVec2(x: s3.x, y: s3.y), ImVec2(x: s0.x, y: s0.y), color, lineWidth)
        estimate += 8
    }
}

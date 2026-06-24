import Foundation
import SwiftSDL

/// Applies temporary world-space translations to rendered CAD resources.
///
/// This service owns the mechanical render-cache mutation used during drag
/// previews. It deliberately does not update `CADDocument`; the caller remains
/// responsible for committing model transforms when the interaction finishes.
@MainActor
final class CADDirectPrimitiveMover {
    func move(
        handles: Set<UUID>,
        by delta: (Double, Double),
        primitiveIDs: [UUID: [SpriteID]],
        spriteIDs: [UUID: [SpriteID]],
        geometryManager: GeometryManager,
        spriteManager: SpriteManager?
    ) {
        let dx = Float(delta.0)
        let dy = Float(delta.1)

        for handle in handles {
            moveSprites(
                spriteIDs[handle] ?? [],
                dx: Double(dx),
                dy: Double(dy),
                spriteManager: spriteManager)

            for id in primitiveIDs[handle] ?? [] {
                guard let primitive = geometryManager.getPrimitive(id: id) else { continue }
                translate(&primitive.points, dx: dx, dy: dy)
                translate(&primitive.corners, dx: dx, dy: dy)

                for index in primitive.rects.indices {
                    primitive.rects[index].x += dx
                    primitive.rects[index].y += dy
                }

                if let minX = primitive.worldMinX {
                    primitive.worldMinX = minX + delta.0
                    primitive.worldMinY = primitive.worldMinY.map { $0 + delta.1 }
                    primitive.worldMaxX = primitive.worldMaxX.map { $0 + delta.0 }
                    primitive.worldMaxY = primitive.worldMaxY.map { $0 + delta.1 }
                }

                primitive.cameraGenerationPoints = -1
                primitive.cameraGenerationRects = -1
                primitive.cameraGenerationCorners = -1
            }
        }
    }

    private func moveSprites(
        _ ids: [SpriteID],
        dx: Double,
        dy: Double,
        spriteManager: SpriteManager?
    ) {
        guard let spriteManager else { return }
        for id in ids {
            guard let sprite = spriteManager.getSprite(for: id) else { continue }
            sprite.position.0 += dx
            sprite.position.1 += dy
        }
    }

    private func translate(
        _ points: inout [SDL_FPoint],
        dx: Float,
        dy: Float
    ) {
        for index in points.indices {
            points[index].x += dx
            points[index].y += dy
        }
    }
}

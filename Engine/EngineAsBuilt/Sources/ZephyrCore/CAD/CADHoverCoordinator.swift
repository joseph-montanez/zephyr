import Foundation

/// Updates grip and entity hover state for pointer motion.
///
/// The loop controller supplies timing and event order; this collaborator owns
/// hit-test throttling and the details of translating pointer state into hover
/// state on `EngineInteractionManager`.
@MainActor
final class CADHoverCoordinator {
    private unowned let engine: PhrostEngine

    init(engine: PhrostEngine) {
        self.engine = engine
    }

    func update(worldX: Double, worldY: Double, screenX: Float, screenY: Float) {
        updateGrip(screenX: screenX, screenY: screenY)
        updateEntity(worldX: worldX, worldY: worldY)
    }

    private func updateGrip(screenX: Float, screenY: Float) {
        let interaction = engine.interaction
        let camera = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        let hit = engine.cadSelection.gripHitTest(
            screenX: screenX,
            screenY: screenY,
            document: engine.document,
            cam: camera,
            simplifyComplexBlocks: engine.simplifyComplexBlocks)
        interaction.hoveredGrip = hit?.grip
        interaction.hoveredGripHandle = hit?.handle
    }

    private func updateEntity(worldX: Double, worldY: Double) {
        let interaction = engine.interaction
        let threshold = 6.0 / engine.camera.zoom
        let distance = hypot(
            worldX - interaction.lastHoverTestWorldX,
            worldY - interaction.lastHoverTestWorldY)
        guard distance > threshold * 0.5 || interaction.hoveredEntityHandle == nil else {
            return
        }

        interaction.hoveredEntityHandle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks)
        interaction.lastHoverTestWorldX = worldX
        interaction.lastHoverTestWorldY = worldY
    }
}

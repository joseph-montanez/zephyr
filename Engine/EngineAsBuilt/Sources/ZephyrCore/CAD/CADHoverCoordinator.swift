import Foundation
import SwiftSDL

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

    /// Minimum ms between CPU hover hit-tests during a mouse-move burst.
    /// The distance gate still applies; the GPU pick pass keeps hover
    /// fresh between CPU runs.
    static let hoverRetestIntervalTicks: UInt64 = 8

    /// Pure throttle decision for CPU hover hit-tests. With no current
    /// hover target the test always runs so the first highlight appears
    /// promptly; otherwise bursts are coalesced to one test per interval.
    static func shouldRunHoverTest(
        moveDistance: Double,
        threshold: Double,
        hasHoverTarget: Bool,
        ticksSinceLastTest: UInt64
    ) -> Bool {
        guard hasHoverTarget else { return true }
        if ticksSinceLastTest < hoverRetestIntervalTicks { return false }
        return moveDistance > threshold * 0.5
    }

    func update(worldX: Double, worldY: Double, screenX: Float, screenY: Float) {
        updateGrip(screenX: screenX, screenY: screenY)
        updateEntity(worldX: worldX, worldY: worldY)
    }

    private func updateGrip(screenX: Float, screenY: Float) {
        let interaction = engine.interaction
        // No grips can exist without a selection or above GRIPOBJLIMIT
        // (`getAllGrips` returns [] in both cases) -- skip the O(selected)
        // regeneration entirely instead of proving it empty per event.
        let selected = engine.cadSelection.selectedHandles
        guard !selected.isEmpty,
              !CADSelectionDisplayPolicy.gripsSuppressed(
                  selectedCount: selected.count,
                  gripObjectLimit: engine.gripObjectMax)
        else {
            interaction.hoveredGrip = nil
            interaction.hoveredGripHandle = nil
            return
        }
        let camera = engine.camera.currentTransform(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        let hit = engine.cadSelection.gripHitTest(
            screenX: screenX,
            screenY: screenY,
            document: engine.document,
            cam: camera,
            simplifyComplexBlocks: engine.simplifyComplexBlocks,
            gripObjectLimit: engine.gripObjectMax)
        interaction.hoveredGrip = hit?.grip
        interaction.hoveredGripHandle = hit?.handle
    }

    private func updateEntity(worldX: Double, worldY: Double) {
        let interaction = engine.interaction
        let threshold = 6.0 / engine.camera.zoom
        let nowTicks = SDL_GetTicks()
        let distance = hypot(
            worldX - interaction.lastHoverTestWorldX,
            worldY - interaction.lastHoverTestWorldY)
        guard Self.shouldRunHoverTest(
            moveDistance: distance,
            threshold: threshold,
            hasHoverTarget: interaction.hoveredEntityHandle != nil,
            ticksSinceLastTest: nowTicks &- interaction.lastHoverTestTicks
        ) else {
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
        interaction.lastHoverTestTicks = nowTicks
    }
}

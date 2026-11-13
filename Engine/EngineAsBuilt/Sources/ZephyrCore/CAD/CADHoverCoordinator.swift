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

    /// Above this screen speed (px/sec) the hover highlight is suppressed:
    /// nobody aims at geometry mid-gesture, and the hit-test is pure
    /// overhead. Snap keeps running - drafting commands need it at speed.
    static let hoverWhipSpeedPxPerSec: Double = 1500
    /// Below this speed a suppressed highlight re-arms. The gap between
    /// the two thresholds is hysteresis against edge-speed flapping.
    static let hoverReacquireSpeedPxPerSec: Double = 600

    /// Pure whip decision with hysteresis: fast always suppresses, slow
    /// always re-arms, and speeds in between hold the current state.
    static func shouldSuppressHover(
        speedPxPerSec: Double,
        currentlySuppressed: Bool
    ) -> Bool {
        if speedPxPerSec >= hoverWhipSpeedPxPerSec { return true }
        if speedPxPerSec <= hoverReacquireSpeedPxPerSec { return false }
        return currentlySuppressed
    }

    /// Clears auto hover state (highlight, grip hover, cycling pile) while
    /// preserving an explicitly armed Shift+Space cycle.
    static func clearAutoHover(in interaction: EngineInteractionManager) {
        guard !interaction.hasActiveHoverCycle else { return }
        interaction.hoveredEntityHandle = nil
        interaction.hoveredGrip = nil
        interaction.hoveredGripHandle = nil
        interaction.clearHoverCycle()
    }

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
        trackSpeed(screenX: screenX, screenY: screenY)
        let interaction = engine.interaction
        let suppress = Self.shouldSuppressHover(
            speedPxPerSec: interaction.hoverSpeedPxPerSec,
            currentlySuppressed: interaction.hoverWhipSuppressed)
        if suppress {
            if !interaction.hoverWhipSuppressed {
                interaction.hoverWhipSuppressed = true
                Self.clearAutoHover(in: interaction)
            }
            return
        }
        interaction.hoverWhipSuppressed = false
        updateGrip(screenX: screenX, screenY: screenY)
        updateEntity(worldX: worldX, worldY: worldY)
    }

    /// Samples pointer speed once per frame (motion is already coalesced,
    /// so one sample per rendered frame). An exponential moving average
    /// smooths polling jitter; teleport jumps are clamped so one jump
    /// cannot pin suppression on.
    private func trackSpeed(screenX: Float, screenY: Float) {
        let interaction = engine.interaction
        let nowTicks = SDL_GetTicks()
        let dtMs = Double(nowTicks &- interaction.lastHoverSpeedTicks)
        if interaction.lastHoverSpeedTicks != 0, dtMs > 0 {
            let dx = Double(screenX - interaction.lastHoverSpeedScreenX)
            let dy = Double(screenY - interaction.lastHoverSpeedScreenY)
            let instant = min(hypot(dx, dy) / (dtMs / 1000.0), 20000.0)
            interaction.hoverSpeedPxPerSec =
                interaction.hoverSpeedPxPerSec * 0.65 + instant * 0.35
        }
        interaction.lastHoverSpeedScreenX = screenX
        interaction.lastHoverSpeedScreenY = screenY
        interaction.lastHoverSpeedTicks = nowTicks
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
        // An armed Shift+Space cycle owns the hover highlight while the
        // cursor stays inside the pile's pickbox; mousemove must not
        // overwrite the user's explicit choice.
        if interaction.hasActiveHoverCycle {
            let anchorDist = hypot(worldX - interaction.hoverCycleAnchorX,
                                   worldY - interaction.hoverCycleAnchorY)
            if anchorDist <= threshold { return }
            interaction.clearHoverCycle()
        }
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

        // Single document walk yields both the highlight target and the
        // cycling pile (shared pick order), replacing three walks.
        let scan = engine.cadSelection.hoverScan(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks,
            blockLOD: BlockLOD.liveContext(
                zoom: engine.camera.zoom,
                scaleX: Double(engine.scaleX),
                scaleY: Double(engine.scaleY),
                autoEnabled: engine.autoCollapseSmallBlocks))
        interaction.hoveredEntityHandle = scan.best
        interaction.lastHoverTestWorldX = worldX
        interaction.lastHoverTestWorldY = worldY
        interaction.lastHoverTestTicks = nowTicks
        refreshHoverCycle(pile: scan.pile, worldX: worldX, worldY: worldY, threshold: threshold)
    }

    /// Rebuilds the hover pile after each hover test. Clears the cycle when
    /// the cursor leaves geometry or cycling is disabled.
    private func refreshHoverCycle(pile: [UUID], worldX: Double, worldY: Double, threshold: Double) {
        let interaction = engine.interaction
        guard SelectionCyclingSettings.isEnabled,
              interaction.hoveredEntityHandle != nil,
              pile.count >= 2
        else {
            interaction.clearHoverCycle()
            return
        }
        // Keep the current pile while the cursor stays inside it and the
        // hover target is still a member; otherwise re-enumerate.
        let anchorDist = hypot(worldX - interaction.hoverCycleAnchorX,
                               worldY - interaction.hoverCycleAnchorY)
        if !interaction.hoverCycleHandles.isEmpty,
           anchorDist <= threshold,
           let hovered = interaction.hoveredEntityHandle,
           interaction.hoverCycleHandles.contains(hovered) {
            return
        }
        interaction.hoverCycleHandles = pile
        interaction.hoverCycleIndex = 0
        interaction.hasActiveHoverCycle = false
        interaction.hoverCycleAnchorX = worldX
        interaction.hoverCycleAnchorY = worldY
    }

    /// Advances the hover pile (Shift+Space). Returns true when a cycle
    /// step ran; the next click then takes the cycled entity directly.
    @discardableResult
    func advanceCycle() -> Bool {
        let interaction = engine.interaction
        guard SelectionCyclingSettings.isEnabled,
              interaction.hoverCycleHandles.count >= 2 else { return false }
        interaction.hasActiveHoverCycle = true
        interaction.hoverCycleIndex = (interaction.hoverCycleIndex + 1) % interaction.hoverCycleHandles.count
        if let handle = interaction.cycledHandle {
            interaction.hoveredEntityHandle = handle
        }
        return true
    }

}
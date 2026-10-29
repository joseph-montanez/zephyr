import Foundation
import CSDL3
import ImGui

// =========================================================================
// CONSTRAINTBAR (CBAR) — toggles the constraint-badge overlay: one
// diamond per constrained entity while the flag is on. The flag is
// session-only view state on the document (never snapshotted or saved),
// so toggling is not an undo entry.
// =========================================================================

@MainActor
public final class ConstraintbarCommand: FeatureCommand {
    public var name: String { "CONSTRAINTBAR" }

    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = false
        engine.document.showConstraintBadges.toggle()
        report(engine: engine, processor: processor)
        // Explicit SHOW/HIDE buttons only render while the command line
        // is open (AutoContrastCommand pattern).
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = true
        processor.commandLineActive = false
        processor.commandBuffer = ""
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch upper {
        case "SHOW", "ON":
            engine.document.showConstraintBadges = true
        case "HIDE", "OFF":
            engine.document.showConstraintBadges = false
        default:
            engine.document.showConstraintBadges.toggle()
        }
        // Finishing clears the prompt, so also print: this is the only
        // record of an explicit SHOW/HIDE choice.
        print("[CAD] \(reportMessage(engine: engine))")
        report(engine: engine, processor: processor)
        finished = true
        return .finished
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        [
            .init(value: "SHOW", title: "Show", aliases: ["ON"],
                  description: "Show constraint badges"),
            .init(value: "HIDE", title: "Hide", aliases: ["OFF"],
                  description: "Hide constraint badges"),
        ].filter { $0.matches(input) }
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // Click dismisses the toggle report; close the option palette
        // with it so no empty command line lingers.
        processor.commandLineActive = false
        processor.commandBuffer = ""
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func reportMessage(engine: PhrostEngine) -> String {
        let entities = Set(
            engine.document.allConstraints.flatMap { [$0.entityA, $0.entityB] }
                .compactMap { $0 }).count
        return engine.document.showConstraintBadges
            ? "Constraint bars shown (\(engine.document.constraintCount) constraint(s) on \(entities) object(s))."
            : "Constraint bars hidden."
    }

    private func report(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = reportMessage(engine: engine)
    }
}

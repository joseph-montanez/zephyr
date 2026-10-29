import Foundation
import CSDL3
import ImGui

// =========================================================================
// AUTOCONSTRAIN — infers HORIZONTAL/VERTICAL/COINCIDENT/PARALLEL/
// PERPENDICULAR/EQUAL over every solver-eligible line, stores the rows,
// and solves immediately. Detection is the pure `AutoConstrain.detect`
// (tested directly); this command only gathers, stores, solves, reports.
// =========================================================================

@MainActor
public final class AutoconstrainCommand: FeatureCommand {
    public var name: String { "AUTOCONSTRAIN" }

    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = false
        let world = engine.document.solvableLines()
        guard !world.isEmpty else {
            // Done synchronously: release residency first so the message
            // persists as a passive prompt and the next click draws.
            processor.finishFeatureCommand(engine: engine)
            processor.commandPrompt = "Nothing to constrain (needs loose lines)."
            finished = true
            return
        }
        let inputs = world.map { AutoConstrain.LineInput(
            handle: $0.key, a: $0.value.a, b: $0.value.b) }
        let detected = AutoConstrain.detect(lines: inputs)
        guard !detected.isEmpty else {
            processor.finishFeatureCommand(engine: engine)
            processor.commandPrompt =
                "No constraints inferred from \(world.count) line(s)."
            finished = true
            return
        }
        for constraint in detected {
            engine.document.addConstraint(constraint)
        }
        let outcome = engine.document.solveConstraints()
        engine.tabManager.markActiveDirty()
        let bad = outcome.satisfied.values.filter { !$0 }.count
        var summary: [String] = []
        for type in [.horizontal, .vertical, .coincident, .parallel,
                     .perpendicular, .equal] as [ConstraintType] {
            let n = detected.filter { $0.type == type }.count
            if n > 0 { summary.append("\(n) \(String(describing: type).lowercased())") }
        }
        var message =
            "Applied \(detected.count) constraint(s) (\(summary.joined(separator: ", ")))."
        if bad > 0 {
            message += " \(bad) conflicting — solve left them unsatisfied."
        }
        processor.finishFeatureCommand(engine: engine)
        processor.commandPrompt = message
        finished = true
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = true
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

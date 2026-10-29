import Foundation
import CSDL3
import ImGui

// =========================================================================
// GEOMCONSTRAINT (GCON) — option dispatcher for the solver-backed
// geometric subset: Horizontal, Vertical, Coincident, Parallel,
// Perpendicular, Equal, Fix. Picks are validated as loose single lines
// (block inserts and baked runs are refused, never half-moved); each
// application solves immediately and reports conflicts by type.
// Unsupported types (Tangent, Concentric, ...) stay unregistered per
// the Phase 2.4 hard rule: no stub commands.
// =========================================================================

@MainActor
public final class GeomconstraintCommand: FeatureCommand {
    public var name: String { "GEOMCONSTRAINT" }

    private enum Kind {
        case horizontal, vertical, coincident, parallel, perpendicular,
             equal, fix

        var needsTwo: Bool {
            switch self {
            case .horizontal, .vertical, .fix: return false
            default: return true
            }
        }

        var label: String {
            switch self {
            case .horizontal: return "Horizontal"
            case .vertical: return "Vertical"
            case .coincident: return "Coincident"
            case .parallel: return "Parallel"
            case .perpendicular: return "Perpendicular"
            case .equal: return "Equal"
            case .fix: return "Fix"
            }
        }

        var constraintType: ConstraintType {
            switch self {
            case .horizontal: return .horizontal
            case .vertical: return .vertical
            case .coincident: return .coincident
            case .parallel: return .parallel
            case .perpendicular: return .perpendicular
            case .equal: return .equal
            case .fix: return .fix
            }
        }
    }

    private var kind: Kind?
    private var first: (entity: CADEntity, endIndex: UInt8)?

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        kind = nil
        first = nil
        promptKind(processor: processor)
        // The first step needs typed input (H/V/C/P/PE/E/F) and the
        // clickable option palette only renders while the command line
        // is open — typing alone cannot open it mid-command.
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        kind = nil
        first = nil
        processor.commandLineActive = false
        processor.commandBuffer = ""
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        ([
            .init(value: "H", title: "Horizontal", aliases: ["HORIZONTAL"],
                  description: "Constrain a line horizontal"),
            .init(value: "V", title: "Vertical", aliases: ["VERTICAL"],
                  description: "Constrain a line vertical"),
            .init(value: "C", title: "Coincident", aliases: ["COINCIDENT"],
                  description: "Join two line endpoints"),
            .init(value: "P", title: "Parallel", aliases: ["PARALLEL"],
                  description: "Make two lines parallel"),
            .init(value: "PE", title: "Perpendicular", aliases: ["PERPENDICULAR", "PERP"],
                  description: "Make two lines perpendicular"),
            .init(value: "E", title: "Equal", aliases: ["EQUAL"],
                  description: "Make two lines equal length"),
            .init(value: "F", title: "Fix", aliases: ["FIX"],
                  description: "Pin a line so solving never moves it"),
        ] as [FeatureCommandTextOption]).filter { $0.matches(input) }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let next: Kind?
        switch upper {
        case "H", "HORIZONTAL": next = .horizontal
        case "V", "VERTICAL": next = .vertical
        case "C", "COINCIDENT": next = .coincident
        case "P", "PARALLEL": next = .parallel
        case "PE", "PERP", "PERPENDICULAR": next = .perpendicular
        case "E", "EQUAL": next = .equal
        case "F", "FIX": next = .fix
        default: next = nil
        }
        guard let next else {
            processor.commandPrompt =
                "Unknown option '\(text)'. Choose [Horizontal/Vertical/Coincident/Parallel/Perpendicular(pE)/Equal/Fix]."
            processor.commandLineActive = true
            processor.commandBuffer = ""
            return .handled
        }
        kind = next
        first = nil
        promptPick(processor: processor)
        // Type chosen: move to graphical picking (OffsetCommand pattern).
        processor.commandLineActive = false
        processor.commandBuffer = ""
        return .handled
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let kind else {
            promptKind(processor: processor)
            // No type chosen yet and the option palette is closed
            // (e.g. command line dismissed): reopen it so picking
            // cannot strand the command with no way to answer.
            processor.commandLineActive = true
            processor.commandBuffer = ""
            return .continue
        }
        guard let hit = CADHitTesting.nestedHitTest(
            worldX: worldX, worldY: worldY, document: engine.document),
              let ends = ConstraintSupport.worldEnds(of: hit.entity) else {
            processor.commandPrompt =
                "Requires a loose line. \(pickPrompt(kind: kind, haveFirst: first != nil))"
            return .continue
        }
        let pick = Vector3(x: worldX, y: worldY, z: 0)
        let endIndex: UInt8 =
            pick.distance(to: ends.a) <= pick.distance(to: ends.b) ? 0 : 1
        if !kind.needsTwo {
            apply(kind: kind, engine: engine, processor: processor,
                  first: (hit.entity, endIndex), second: nil)
            first = nil
            promptPick(processor: processor)
            return .continue
        }
        guard let stored = first else {
            first = (hit.entity, endIndex)
            processor.commandPrompt = "Select second object:"
            return .continue
        }
        if stored.entity.handle == hit.entity.handle {
            processor.commandPrompt =
                "Select a different object for the second pick:"
            return .continue
        }
        apply(kind: kind, engine: engine, processor: processor,
              first: stored, second: (hit.entity, endIndex))
        first = nil
        promptPick(processor: processor)
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Apply

    private func apply(
        kind: Kind, engine: PhrostEngine, processor: CADCommandProcessor,
        first: (entity: CADEntity, endIndex: UInt8),
        second: (entity: CADEntity, endIndex: UInt8)?
    ) {
        let constraint: CADConstraint
        switch kind {
        case .coincident:
            guard let second else { return }
            constraint = CADConstraint(
                type: .coincident, entityA: first.entity.handle,
                entityB: second.entity.handle,
                subIndexA: first.endIndex, subIndexB: second.endIndex)
        default:
            constraint = CADConstraint(
                type: kind.constraintType, entityA: first.entity.handle,
                entityB: second?.entity.handle)
        }
        engine.document.addConstraint(constraint)
        let outcome = engine.document.solveConstraints()
        engine.tabManager.markActiveDirty()
        let bad = outcome.satisfied.values.filter { !$0 }.count
        var message =
            "\(kind.label) constraint applied (\(engine.document.constraintCount) total)."
        if bad > 0 {
            message += " \(bad) conflicting constraint(s) — solve left them unsatisfied."
        }
        processor.commandPrompt = message
    }

    private func promptKind(processor: CADCommandProcessor) {
        processor.commandPrompt =
            "Select constraint type [Horizontal/Vertical/Coincident/Parallel/Perpendicular(pE)/Equal/Fix] (Esc to cancel)."
    }

    private func promptPick(processor: CADCommandProcessor) {
        guard let kind else { promptKind(processor: processor); return }
        processor.commandPrompt = pickPrompt(kind: kind, haveFirst: first != nil)
    }

    private func pickPrompt(kind: Kind, haveFirst: Bool) -> String {
        if kind.needsTwo {
            return haveFirst ? "Select second object:" : "Select first object:"
        }
        return "Select object for \(kind.label):"
    }
}

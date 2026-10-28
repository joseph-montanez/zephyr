// Sources/ZephyrCore/Commands/SelectFilterCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// QSELECT and FILTER (FI), Phase 2.2b: one command class with a mode
/// (mirroring DimEditCommand) over the shared EntityFilter predicate core.
/// The LT dialogs are flattened to stepped command-line prompts (the FIND
/// precedent): QSELECT takes an object-type pre-filter plus one property
/// criterion with include/exclude and an all/current scope; FILTER takes
/// any number of property criteria with an AND/OR/NOT combinator and an
/// all/current scope (include semantics). Both respect the on/off
/// visibility model; frozen/locked layers do not exist in the model yet.
///
/// The Lisp ssget filter (`LispCADHost.makeFilter`) is intentionally NOT
/// refactored onto this core: it pins exact-case layer matching and a
/// four-code subset that Lisp suites assert, while commands use
/// case-insensitive matching plus wildcards and comparisons. Property
/// accessors (type/layer/ACI) are shared through LispEntityAdapter.
@MainActor
public final class SelectFilterCommand: FeatureCommand {

    public enum Mode {
        case qselect
        case filter
    }

    public enum Scope {
        case all
        case current
    }

    private enum Phase {
        case type
        case property
        case op
        case value
        case more
        case combine
        case applyTo
        case howTo
    }

    private let mode: Mode
    private var phase: Phase
    private var typeFilter: String?
    private var criteria: [EntityFilter.FilterCriterion] = []
    private var pendingProperty = EntityFilter.FilterProperty.layer
    private var pendingOp = EntityFilter.FilterOperator.equals
    private var combinator = EntityFilter.FilterCombine.and
    private var scope = Scope.all
    private var exclude = false

    public init(mode: Mode) {
        self.mode = mode
        self.phase = mode == .qselect ? .type : .property
    }

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        typeFilter = nil
        criteria = []
        combinator = .and
        scope = .all
        exclude = false
        if mode == .qselect {
            phase = .type
            processor.commandPrompt = "Object type [All/\(EntityFilter.knownTypes.joined(separator: "/"))]:"
        } else {
            phase = .property
            processor.commandPrompt = propertyPrompt()
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .type:
            guard !trimmed.isEmpty else {
                processor.commandPrompt = "Object type [All/\(EntityFilter.knownTypes.joined(separator: "/"))]:"
                return .continue
            }
            let upper = trimmed.uppercased()
            if upper == "ALL" || upper == "A" {
                typeFilter = nil
            } else if EntityFilter.knownTypes.contains(upper) {
                typeFilter = upper
            } else {
                processor.commandPrompt = "Unknown type '\(trimmed)'."
                    + " Object type [All/\(EntityFilter.knownTypes.joined(separator: "/"))]:"
                return .continue
            }
            phase = .property
            processor.commandPrompt = propertyPrompt()
            return .continue

        case .property:
            guard let property = Self.parseProperty(
                trimmed, allowType: mode == .filter) else {
                processor.commandPrompt = propertyPrompt()
                return .continue
            }
            pendingProperty = property
            phase = .op
            processor.commandPrompt = operatorPrompt(for: property)
            return .continue

        case .op:
            guard let op = Self.parseOperator(
                trimmed, for: pendingProperty) else {
                processor.commandPrompt = operatorPrompt(for: pendingProperty)
                return .continue
            }
            pendingOp = op
            phase = .value
            processor.commandPrompt = valuePrompt(for: pendingProperty)
            return .continue

        case .value:
            guard let value = Self.parseValue(
                trimmed, for: pendingProperty) else {
                processor.commandPrompt = valuePrompt(for: pendingProperty)
                return .continue
            }
            criteria.append(EntityFilter.FilterCriterion(
                property: pendingProperty, op: pendingOp, value: value))
            if mode == .qselect {
                phase = .applyTo
                processor.commandPrompt = "Apply to [All/Current]:"
            } else {
                phase = .more
                processor.commandPrompt = "Add another criterion? [Yes/No]:"
            }
            return .continue

        case .more:
            switch trimmed.uppercased() {
            case "Y", "YES":
                phase = .property
                processor.commandPrompt = propertyPrompt()
                return .continue
            case "N", "NO":
                phase = .combine
                processor.commandPrompt = "Combine criteria [And/Or/Not]:"
                return .continue
            default:
                processor.commandPrompt = "Add another criterion? [Yes/No]:"
                return .continue
            }

        case .combine:
            guard let combine = Self.parseCombine(trimmed) else {
                processor.commandPrompt = "Combine criteria [And/Or/Not]:"
                return .continue
            }
            combinator = combine
            phase = .applyTo
            processor.commandPrompt = "Apply to [All/Current]:"
            return .continue

        case .applyTo:
            switch trimmed.uppercased() {
            case "A", "ALL":
                scope = .all
            case "C", "CURRENT":
                scope = .current
            default:
                processor.commandPrompt = "Apply to [All/Current]:"
                return .continue
            }
            if mode == .qselect {
                phase = .howTo
                processor.commandPrompt = "How to apply [Include/Exclude]:"
                return .continue
            }
            apply(engine: engine, processor: processor)
            return .finished

        case .howTo:
            switch trimmed.uppercased() {
            case "I", "INCLUDE":
                exclude = false
            case "E", "EXCLUDE":
                exclude = true
            default:
                processor.commandPrompt = "How to apply [Include/Exclude]:"
                return .continue
            }
            apply(engine: engine, processor: processor)
            return .finished
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Pure prompt parsing (nonisolated: test-callable)

    /// Unambiguous prefix match (case-insensitive) over the offered
    /// properties. Nil when empty or ambiguous.
    nonisolated static func parseProperty(
        _ text: String, allowType: Bool
    ) -> EntityFilter.FilterProperty? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }
        var offered: [(EntityFilter.FilterProperty, [String])] = [
            (.layer, ["LAYER"]),
            (.color, ["COLOR"]),
            (.linetype, ["LINETYPE"]),
            (.lineweight, ["LINEWEIGHT"]),
            (.handle, ["HANDLE"]),
        ]
        if allowType {
            offered.append((.objectType, ["OBJECTTYPE", "TYPE"]))
        }
        let hits = offered.filter { (_, aliases) in
            aliases.contains { $0.hasPrefix(key) }
        }
        return hits.count == 1 ? hits[0].0 : nil
    }

    /// Operator keywords; comparisons only offered for numeric properties.
    nonisolated static func parseOperator(
        _ text: String, for property: EntityFilter.FilterProperty
    ) -> EntityFilter.FilterOperator? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch key {
        case "E", "EQUALS", "=", "EQ":
            return .equals
        case "NE", "NOTEQUALS", "NOT EQUALS", "<>", "!=":
            return .notEquals
        case "LT", "LESSTHAN", "<":
            return EntityFilter.isNumericProperty(property) ? .lessThan : nil
        case "LE", "LESSOREQUAL", "<=":
            return EntityFilter.isNumericProperty(property) ? .lessThanOrEqual : nil
        case "GT", "GREATERTHAN", ">":
            return EntityFilter.isNumericProperty(property) ? .greaterThan : nil
        case "GE", "GREATEROREQUAL", ">=":
            return EntityFilter.isNumericProperty(property) ? .greaterThanOrEqual : nil
        default:
            return nil
        }
    }

    nonisolated static func parseCombine(_ text: String) -> EntityFilter.FilterCombine? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "AND": return .and
        case "OR": return .or
        case "NOT": return .not
        default: return nil
        }
    }

    /// Validates a criterion value: non-empty strings, known type names
    /// for the type property, range-checked numbers otherwise. Nil rejects.
    nonisolated static func parseValue(
        _ text: String, for property: EntityFilter.FilterProperty
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if property == .objectType {
            guard EntityFilter.knownTypes.contains(trimmed.uppercased()) else {
                return nil
            }
            return trimmed.uppercased()
        }
        if EntityFilter.isNumericProperty(property) {
            guard EntityFilter.parseNumericValue(property, trimmed) != nil else {
                return nil
            }
            return trimmed
        }
        return trimmed
    }

    // MARK: - Private

    private func propertyPrompt() -> String {
        mode == .qselect
            ? "Property [Layer/Color/Linetype/Lineweight/Handle]:"
            : "Property [ObjectType/Layer/Color/Linetype/Lineweight/Handle]:"
    }

    private func operatorPrompt(for property: EntityFilter.FilterProperty) -> String {
        EntityFilter.isNumericProperty(property)
            ? "Operator [Equals/Not equals/Less than/Less or equal/Greater than/Greater or equal]:"
            : "Operator [Equals/Not equals]:"
    }

    private func valuePrompt(for property: EntityFilter.FilterProperty) -> String {
        switch property {
        case .objectType:
            return "Type value [\(EntityFilter.knownTypes.joined(separator: "/"))]:"
        case .color:
            return "Color value (ACI 0-256):"
        case .lineweight:
            return "Lineweight value (mm):"
        case .layer:
            return "Layer value (wildcards * ? allowed):"
        case .linetype, .handle:
            return "\(property == .linetype ? "Linetype" : "Handle") value:"
        }
    }

    private func effectiveCriteria() -> [EntityFilter.FilterCriterion] {
        var all = criteria
        if let typeFilter {
            all.insert(EntityFilter.FilterCriterion(
                property: .objectType, op: .equals, value: typeFilter), at: 0)
        }
        return all
    }

    private func scopeEntities(engine: PhrostEngine) -> [CADEntity] {
        switch scope {
        case .all:
            return engine.document.allEntities.sorted {
                $0.handle.uuidString < $1.handle.uuidString
            }
        case .current:
            let handles = engine.cadSelection.selectedHandles
            return handles.compactMap { engine.document.entity(for: $0) }
                .sorted { $0.handle.uuidString < $1.handle.uuidString }
        }
    }

    private func apply(engine: PhrostEngine, processor: CADCommandProcessor) {
        let candidates = scopeEntities(engine: engine)
        let combine: EntityFilter.FilterCombine =
            mode == .qselect ? .and : combinator
        let matched = EntityFilter.filter(
            candidates, criteria: effectiveCriteria(),
            using: combine, in: engine.document)
        let matchedSet = Set(matched.map(\.handle))
        let result: [UUID]
        if exclude {
            let scopeSet = Set(candidates.map(\.handle))
            result = scopeSet.subtracting(matchedSet).sorted {
                $0.uuidString < $1.uuidString
            }
        } else {
            result = matched.map(\.handle)
        }
        engine.cadSelection.selectedHandles = Set(result)
        engine.cadSelection.lastSelectedHandle = result.first
        let name = mode == .qselect ? "QSELECT" : "FILTER"
        let message = "\(name): \(result.count) object(s) selected"
            + " (\(matched.count) matched of \(candidates.count) in scope)."
        print("[\(name)] \(message)")
        processor.commandPrompt = message
    }
}

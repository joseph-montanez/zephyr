import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - ChangePropertiesCommand (CHPROP / CHANGE)
// =========================================================================

/// Interactive `CHPROP` (and legacy `CHANGE`, same prompter): change color,
/// layer, linetype, linetype scale, or lineweight of the current selection.
///
/// Storage semantics mirror the scripted `(command "CHPROP" ...)` path
/// (`runChprop` in LispScriptedCommands): `dxf.colorIndex` for ACI colors,
/// `dxf.color24` + `dxf.isTrueColor` for R,G,B, key removal for
/// BYLAYER/BYBLOCK, `layerID` reassignment for layers, and the `dxf.lineType`,
/// `dxf.lineTypeScale`, `dxf.lineWeight` keys. Every application is exactly
/// one undo step (`pushUndo` + `applyLiveEntityEdits`), no matter how many
/// entities change. After each application the command loops back for another
/// property (AutoCAD behavior); empty input or eXit finishes.
@MainActor
public final class ChangePropertiesCommand: FeatureCommand {

    /// One property assignment, resolved from prompts before applying.
    public enum PropertyChange {
        case color(PropColor)
        case layer(UUID)
        case lineType(String?)
        case lineTypeScale(Double)
        case lineWeight(Double?)
    }

    /// Color value mirroring the scripted CHPROP operand protocol.
    public enum PropColor {
        case byLayer
        case aci(Int32)
        case rgb(ColorRGBA)
    }

    private enum Step {
        case property
        case value(Property)
    }

    private enum Property {
        case color
        case layer
        case lineType
        case lineTypeScale
        case lineWeight
    }

    private var step: Step = .property

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard engine.cadSelection.hasSelection else {
            processor.commandPrompt = "No entities selected. Select entities first, then run CHPROP."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        step = .property
        processor.commandPrompt = "Change what [Color/LAyer/LType/LTScale/LWeight/eXit]:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        guard case .property = step else { return [] }
        return [
            .init(value: "C", title: "Color", aliases: ["COLOR"]),
            .init(value: "LA", title: "LAyer", aliases: ["LAYER"]),
            .init(value: "LT", title: "LType", aliases: ["LTYPE"]),
            .init(value: "S", title: "LTScale", aliases: ["LTSCALE"]),
            .init(value: "W", title: "LWeight", aliases: ["LWEIGHT"]),
            .init(value: "X", title: "eXit", aliases: ["EXIT"]),
        ]
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch step {
        case .property:
            switch input {
            case "C", "COLOR":
                step = .value(.color)
                processor.commandPrompt = "New color (BYLAYER, BYBLOCK, ACI 1-255, or R,G,B):"
            case "LA", "LAYER":
                step = .value(.layer)
                processor.commandPrompt = "New layer name:"
            case "LT", "LTYPE":
                step = .value(.lineType)
                processor.commandPrompt = "New linetype (BYLAYER clears override):"
            case "S", "LTSCALE":
                step = .value(.lineTypeScale)
                processor.commandPrompt = "New linetype scale:"
            case "W", "LWEIGHT":
                step = .value(.lineWeight)
                processor.commandPrompt = "New lineweight in mm (negative clears):"
            case "X", "EXIT", "":
                return .finished
            default:
                processor.commandPrompt = "Unknown property. Change what [Color/LAyer/LType/LTScale/LWeight/eXit]:"
            }
            return .handled
        case .value(let property):
            guard applyPromptedValue(property, input: input, engine: engine, processor: processor) else {
                return .handled
            }
            guard engine.cadSelection.hasSelection else {
                processor.commandPrompt = "Selection empty; CHPROP finished."
                return .finished
            }
            step = .property
            processor.commandPrompt = "Change what [Color/LAyer/LType/LTScale/LWeight/eXit]:"
            return .handled
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Prompted application

    /// Parse one prompted value, apply it, and report. Returns false when the
    /// value was invalid (caller re-prompts, staying on the same property).
    private func applyPromptedValue(
        _ property: Property,
        input: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> Bool {
        let handles = engine.cadSelection.selectedHandles
        switch property {
        case .color:
            guard let color = Self.parseColor(input) else {
                processor.commandPrompt = "Invalid color. New color (BYLAYER, BYBLOCK, ACI 1-255, or R,G,B):"
                return false
            }
            let count = Self.apply(.color(color), to: handles, in: engine.document)
            processor.commandPrompt = "\(count) entit\(count == 1 ? "y" : "ies") color updated."
            return true
        case .layer:
            guard let layer = engine.document.findLayer(named: input) else {
                processor.commandPrompt = "Layer '\(input)' not found. New layer name:"
                return false
            }
            let count = Self.apply(.layer(layer.handle), to: handles, in: engine.document)
            processor.commandPrompt = "\(count) entit\(count == 1 ? "y" : "ies") moved to layer '\(layer.name)'."
            return true
        case .lineType:
            let canonical = input.uppercased()
            let value: String? = (canonical == "BYLAYER" || canonical.isEmpty) ? nil : canonical
            let count = Self.apply(.lineType(value), to: handles, in: engine.document)
            processor.commandPrompt = "\(count) entit\(count == 1 ? "y" : "ies") linetype updated."
            return true
        case .lineTypeScale:
            guard let scale = Double(input), scale > 0 else {
                processor.commandPrompt = "Invalid scale. New linetype scale:"
                return false
            }
            let count = Self.apply(.lineTypeScale(scale), to: handles, in: engine.document)
            processor.commandPrompt = "\(count) entit\(count == 1 ? "y" : "ies") linetype scale updated."
            return true
        case .lineWeight:
            guard let lw = Double(input) else {
                processor.commandPrompt = "Invalid lineweight. New lineweight in mm (negative clears):"
                return false
            }
            let count = Self.apply(.lineWeight(lw < 0 ? nil : lw), to: handles, in: engine.document)
            processor.commandPrompt = "\(count) entit\(count == 1 ? "y" : "ies") lineweight updated."
            return true
        }
    }

    // MARK: - Parsing and application (headless-testable)

    /// Parse a CHPROP color token: BYLAYER, BYBLOCK, ACI 1-255, or R,G,B.
    /// Mirrors the scripted operand protocol (BYLAYER/BYBLOCK both clear).
    public static func parseColor(_ input: String) -> PropColor? {
        let upper = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper == "BYLAYER" || upper == "BYBLOCK" { return .byLayer }
        if upper.contains(",") {
            let parts = upper.split(separator: ",").compactMap {
                UInt8($0.trimmingCharacters(in: .whitespaces))
            }
            guard parts.count == 3 else { return nil }
            return .rgb(ColorRGBA(r: parts[0], g: parts[1], b: parts[2]))
        }
        guard let aci = Int32(upper), aci >= 1, aci <= 255 else { return nil }
        return .aci(aci)
    }

    /// Apply one property change to every handle in exactly one undo step.
    /// Returns the number of entities updated.
    @discardableResult
    public static func apply(
        _ change: PropertyChange,
        to handles: Set<UUID>,
        in document: CADDocument
    ) -> Int {
        var updated: [CADEntity] = []
        for handle in handles {
            guard var entity = document.entity(for: handle) else { continue }
            switch change {
            case .color(let color):
                applyColorValue(color, to: &entity)
            case .layer(let layerID):
                entity.layerID = layerID
            case .lineType(let name):
                if let name, !name.isEmpty {
                    entity.xdata["dxf.lineType"] = .string(name)
                } else {
                    entity.xdata.removeValue(forKey: "dxf.lineType")
                }
            case .lineTypeScale(let scale):
                entity.xdata["dxf.lineTypeScale"] = .double(scale)
            case .lineWeight(let lw):
                if let lw {
                    entity.xdata["dxf.lineWeight"] = .double(lw)
                } else {
                    entity.xdata.removeValue(forKey: "dxf.lineWeight")
                }
            }
            updated.append(entity)
        }
        guard !updated.isEmpty else { return 0 }
        document.pushUndo()
        document.applyLiveEntityEdits(removing: [], updating: updated)
        return updated.count
    }

    private static func applyColorValue(_ color: PropColor, to entity: inout CADEntity) {
        switch color {
        case .byLayer:
            entity.xdata.removeValue(forKey: "dxf.color")
            entity.xdata.removeValue(forKey: "dxf.color24")
            entity.xdata.removeValue(forKey: "dxf.colorIndex")
            entity.xdata.removeValue(forKey: "dxf.isTrueColor")
        case .aci(let aci):
            entity.xdata["dxf.colorIndex"] = .int(Int(aci))
            entity.xdata.removeValue(forKey: "dxf.color24")
            entity.xdata.removeValue(forKey: "dxf.isTrueColor")
        case .rgb(let c):
            let rgb = (Int(c.r) << 16) | (Int(c.g) << 8) | Int(c.b)
            entity.xdata["dxf.color24"] = .int(rgb)
            entity.xdata["dxf.isTrueColor"] = .int(1)
            entity.xdata.removeValue(forKey: "dxf.colorIndex")
        }
    }
}

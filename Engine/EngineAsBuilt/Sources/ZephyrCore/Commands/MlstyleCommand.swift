import Foundation
import CSDL3
import ImGui

// =========================================================================
// MLSTYLE — minimal multiline-style manager (CLI): list styles, create
// one from comma offsets, set the current style (CMLSTYLE), delete.
// Standard is protected. Element colors/linetypes stay BYLAYER in v1;
// per-element overrides ride the DXF group path on import.
// =========================================================================

@MainActor
public final class MlstyleCommand: FeatureCommand {
    public var name: String { "MLSTYLE" }

    private enum Stage {
        case menu
        case newName
        case newOffsets
        case setName
        case deleteName
        case done
    }

    private var stage: Stage = .menu
    private var pendingName = ""

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        stage = .menu
        openTextPrompt(
            "Multiline styles [New/Set/Delete/List] <List>:", processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        stage = .done
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage {
        case .menu:
            switch input.uppercased() {
            case "", "L", "LIST":
                processor.commandPrompt = listStyles(engine: engine)
                stage = .done
                return .finished
            case "N", "NEW":
                stage = .newName
                openTextPrompt("New style name:", processor: processor)
                return .continue
            case "S", "SET":
                stage = .setName
                openTextPrompt(
                    "Current style <\(engine.document.currentMlineStyleName)>:",
                    processor: processor)
                return .continue
            case "D", "DELETE":
                stage = .deleteName
                openTextPrompt("Style name to delete:", processor: processor)
                return .continue
            default:
                openTextPrompt(
                    "Multiline styles [New/Set/Delete/List] <List>:",
                    processor: processor)
                return .continue
            }
        case .newName:
            guard !input.isEmpty else {
                openTextPrompt("New style name:", processor: processor)
                return .continue
            }
            pendingName = input
            stage = .newOffsets
            openTextPrompt(
                "Element offsets, comma-separated (e.g. 0.5,-0.5):",
                processor: processor)
            return .continue
        case .newOffsets:
            let offsets = input.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard !offsets.isEmpty else {
                openTextPrompt(
                    "Element offsets, comma-separated (e.g. 0.5,-0.5):",
                    processor: processor)
                return .continue
            }
            let style = CADMlineStyle(
                name: pendingName,
                elements: offsets.map { CADMlineElement(offset: $0) })
            engine.document.setMlineStyle(style)
            engine.document.currentMlineStyleName = style.name
            engine.tabManager.markActiveDirty()
            processor.commandPrompt =
                "Style \"\(style.name)\" created with \(offsets.count) elements and set current."
            stage = .done
            return .finished
        case .setName:
            let wanted = input.isEmpty
                ? engine.document.currentMlineStyleName : input
            let resolved = engine.document.mlineStyle(named: wanted)
            engine.document.currentMlineStyleName = resolved.name
            processor.commandPrompt = "Current multiline style: \(resolved.name)."
            stage = .done
            return .finished
        case .deleteName:
            guard !input.isEmpty else {
                stage = .done
                return .finished
            }
            if engine.document.deleteMlineStyle(named: input) {
                engine.tabManager.markActiveDirty()
                processor.commandPrompt = "Style \"\(input)\" deleted."
            } else {
                processor.commandPrompt =
                    "Cannot delete \"\(input)\" (Standard or unknown)."
            }
            stage = .done
            return .finished
        case .done:
            return .finished
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        stage == .done ? .finished : .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func listStyles(engine: PhrostEngine) -> String {
        let names = engine.document.mlineStyles.keys.sorted()
        let current = engine.document.currentMlineStyleName
        let rows = names.map { name -> String in
            let style = engine.document.mlineStyles[name]!
            let offsets = style.elements.map { String($0.offset) }.joined(separator: ",")
            let mark = name.caseInsensitiveCompare(current) == .orderedSame ? "*" : " "
            return "\(mark)\(name) [\(offsets)]"
        }
        return "Multiline styles: " + rows.joined(separator: "; ")
    }

    private func openTextPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }
}

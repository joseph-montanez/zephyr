import Foundation
import CSDL3
import ImGui

// =========================================================================
// ATTDEF — define a block attribute: tag → prompt → default → height →
// flags → target block → definition point. The point is picked in model
// space and carried into block space through the first insert's inverse
// transform (identity when the block has no inserts yet), matching how
// the importer derives definition placement from baked ATTDEF text.
// New definitions apply to future ATTSYNC runs; existing inserts are
// left untouched per AutoCAD behavior.
// =========================================================================

@MainActor
public final class AttdefCommand: FeatureCommand {
    public var name: String { "ATTDEF" }

    private enum Stage {
        case tag
        case prompt
        case `default`
        case height
        case invisible
        case constant
        case block
        case point
        case done
    }

    private var stage: Stage = .tag
    private var tag = ""
    private var promptText = ""
    private var defaultValue = ""
    private var height = 2.5
    private var flags = 0
    private var blockHandle: UUID?
    private var blockName = ""

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        // Default target: the block of the first selected insert.
        for handle in engine.cadSelection.selectedHandles {
            if let entity = engine.document.entity(for: handle),
               let bid = entity.blockID,
               let block = engine.document.block(for: bid),
               !block.isXref {
                blockHandle = bid
                blockName = block.name
                break
            }
        }
        stage = .tag
        openTextPrompt("Enter attribute tag:", processor: processor)
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
        case .tag:
            guard !input.isEmpty else {
                openTextPrompt("Enter attribute tag:", processor: processor)
                return .continue
            }
            tag = input
            stage = .prompt
            openTextPrompt("Enter attribute prompt <\(tag)>:", processor: processor)
            return .continue
        case .prompt:
            promptText = input.isEmpty ? tag : input
            stage = .default
            openTextPrompt("Enter default value:", processor: processor)
            return .continue
        case .default:
            defaultValue = input
            stage = .height
            openTextPrompt("Specify text height <2.5>:", processor: processor)
            return .continue
        case .height:
            if let h = Double(input), h > 0 { height = h }
            stage = .invisible
            openTextPrompt("Invisible? [Yes/No] <No>:", processor: processor)
            return .continue
        case .invisible:
            if input.uppercased() == "Y" || input.uppercased() == "YES" { flags |= 1 }
            stage = .constant
            openTextPrompt("Constant? [Yes/No] <No>:", processor: processor)
            return .continue
        case .constant:
            if input.uppercased() == "Y" || input.uppercased() == "YES" { flags |= 2 }
            stage = .block
            if blockName.isEmpty {
                openTextPrompt("Enter block name:", processor: processor)
            } else {
                openTextPrompt(
                    "Enter block name <\(blockName)>:", processor: processor)
            }
            return .continue
        case .block:
            let wanted = input.isEmpty ? blockName : input
            guard let block = engine.document.allBlocks.first(where: {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                    && !$0.isXref
            }) else {
                openTextPrompt(
                    "Block \"\(wanted)\" not found. Enter block name:", processor: processor)
                return .continue
            }
            blockHandle = block.handle
            blockName = block.name
            stage = .point
            showCanvasPrompt(
                "Specify definition point for \"\(tag)\":", processor: processor)
            return .continue
        case .point, .done:
            return stage == .done ? .finished : .continue
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard stage == .point, let blockHandle else {
            return stage == .done ? .finished : .continue
        }
        let world = Vector3(x: worldX, y: worldY, z: 0)
        // First insert carries model space into block space; with no
        // inserts yet the pick is already block-space.
        let local: Vector3
        if let insert = engine.document.allEntities.first(where: { $0.blockID == blockHandle }) {
            local = insert.transform.inverse().transformPoint(world)
        } else {
            local = world
        }
        let definition = CADAttributeDefinition(
            tag: tag,
            prompt: promptText,
            defaultValue: defaultValue,
            position: local,
            height: height,
            flags: flags)
        guard engine.document.addAttributeDefinition(definition, to: blockHandle) else {
            processor.commandPrompt = "Tag \"\(tag)\" already exists in \"\(blockName)\"."
            stage = .done
            return .finished
        }
        engine.tabManager.markActiveDirty()
        processor.commandPrompt =
            "Attribute \"\(tag)\" defined in \"\(blockName)\". Run ATTSYNC to update existing inserts."
        stage = .done
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func openTextPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }

    private func showCanvasPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = false
    }
}

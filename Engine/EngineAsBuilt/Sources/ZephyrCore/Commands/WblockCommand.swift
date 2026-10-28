// Sources/ZephyrCore/Commands/WblockCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

/// WBLOCK / -WBLOCK, Phase 2.3a: writes a block, the selection, or the
/// entire drawing to a DXF file through `DXFExporter`, with a base-point
/// prompt feeding DXF `$INSBASE`.
///
/// - Block: the definition's geometry is exploded to loose model-space
///   entities (block-local coords become world coords) via
///   `explodeEntities`, then the helper INSERT and definition are removed,
///   so the file carries just the entities like LT.
/// - Objects: selected (or picked) entities plus the full definition
///   tables. `Retain? No` deletes them from the source drawing — the
///   deletion flows through `removeEntities`, so it is OOPS-restorable
///   (the LT Retain/Delete/Oops equivalent).
/// - Entire drawing: faithful copy of entities and tables.
/// Both spellings share one factory: there is no dialog to suppress, so
/// the prompt flow already is the `-WBLOCK` command-line form.
@MainActor
public final class WblockCommand: FeatureCommand {

    enum Source {
        case block
        case objects
        case entire
    }

    private enum Phase {
        case source
        case blockName
        case pick
        case base
        case file
        case retain
    }

    private var phase: Phase = .source
    private var source: Source = .objects
    private var blockName = ""
    private var basePoint = Vector3(x: 0, y: 0, z: 0)

    public init() {}

    public var isSnappingEnabled: Bool { false }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .source
        processor.commandPrompt =
            "Source [Block/Objects/Entire drawing] <Objects>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Command cancelled."
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch phase {
        case .pick:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX, worldY: worldY, document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks)
            else { return .handled }
            let shiftHeld = engine.io?.pointee.KeyShift ?? false
            if shiftHeld {
                engine.cadSelection.removeFromSelection(handle)
            } else {
                engine.cadSelection.addToSelection(handle)
            }
            processor.commandPrompt =
                "Select objects, then press Enter " +
                "(\(engine.cadSelection.selectedCount) selected)"
            return .handled
        case .base:
            basePoint = Vector3(x: worldX, y: worldY, z: 0)
            phase = .file
            processor.commandPrompt = "File path:"
            return .handled
        default:
            return .continue
        }
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
        case .source:
            return readSource(trimmed, engine: engine, processor: processor)
        case .blockName:
            guard !trimmed.isEmpty else {
                processor.commandPrompt = "Block name cannot be blank. Enter block name:"
                return .continue
            }
            guard engine.document.allBlocks.contains(where: {
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else {
                processor.commandPrompt =
                    "Block '\(trimmed)' not found. Enter block name:"
                return .continue
            }
            blockName = trimmed
            return askBase(engine: engine, processor: processor)
        case .pick:
            guard trimmed.isEmpty else { return .continue }
            guard !engine.cadSelection.selectedHandles.isEmpty else {
                processor.commandPrompt = "Nothing selected; nothing written."
                return .finished
            }
            return askBase(engine: engine, processor: processor)
        case .base:
            if !trimmed.isEmpty {
                guard let point = Self.parsePoint(trimmed) else {
                    processor.commandPrompt =
                        "Enter base point as x,y[,z] or pick a point:"
                    return .continue
                }
                basePoint = point
            }
            phase = .file
            processor.commandPrompt = "File path:"
            return .continue
        case .file:
            guard !trimmed.isEmpty else {
                processor.commandPrompt = "File path cannot be blank. File path:"
                return .continue
            }
            if source == .objects {
                phase = .retain
                processor.commandPrompt = "Retain objects? [Yes/No] <Yes>:"
                // Stash the path in blockName (reused as scratch: pick and
                // block phases are over).
                blockName = trimmed
                return .continue
            }
            return write(
                filePath: trimmed, retain: true,
                engine: engine, processor: processor)
        case .retain:
            let answer = trimmed.uppercased()
            let retain = answer.isEmpty || answer == "Y" || answer == "YES"
            return write(
                filePath: blockName, retain: retain,
                engine: engine, processor: processor)
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Private

    private func readSource(
        _ trimmed: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = trimmed.uppercased()
        if trimmed.isEmpty || upper == "O" || upper == "OBJECTS" {
            source = .objects
            if !engine.cadSelection.selectedHandles.isEmpty {
                return askBase(engine: engine, processor: processor)
            }
            phase = .pick
            processor.commandPrompt = "Select objects, then press Enter:"
            return .continue
        }
        if upper == "B" || upper == "BLOCK" {
            source = .block
            phase = .blockName
            processor.commandPrompt = "Enter block name:"
            return .continue
        }
        if upper == "E" || upper == "ENTIRE" || upper == "ENTIRE DRAWING" {
            source = .entire
            return askBase(engine: engine, processor: processor)
        }
        processor.commandPrompt =
            "Unknown source '\(trimmed)'. Source [Block/Objects/Entire drawing] <Objects>:"
        return .continue
    }

    private func askBase(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        phase = .base
        basePoint = engine.document.insertionBase
        processor.commandPrompt =
            "Base point <\(fmt(basePoint))> (type x,y[,z] or pick):"
        return .continue
    }

    private func write(
        filePath: String, retain: Bool,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let path = (filePath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let target = url.pathExtension.isEmpty
            ? url.appendingPathExtension("dxf") : url
        // Capture the doomed handles before export: a Delete disposition
        // clears the selection, and export must not mutate the source.
        let doomed = (source == .objects && !retain)
            ? engine.cadSelection.selectedHandles : Set<UUID>()
        do {
            let temp = try Self.exportDocument(
                source, blockName: blockName, basePoint: basePoint,
                handles: engine.cadSelection.selectedHandles,
                from: engine.document)
            try DXFExporter.export(document: temp, to: target)
            if !doomed.isEmpty {
                engine.document.removeEntities(handles: doomed)
                engine.cadSelection.clearSelection()
                engine.tabManager.markActiveDirty()
            }
            let count = temp.allEntities.count
            processor.commandPrompt =
                "Wrote \(count) object\(count == 1 ? "" : "s") to \(target.lastPathComponent)."
        } catch {
            processor.commandPrompt = "Write failed: \(error)"
        }
        return .finished
    }

    /// Builds the export document for a source (never mutates the source).
    static func exportDocument(
        _ source: Source, blockName: String, basePoint: Vector3,
        handles: Set<UUID>, from document: CADDocument
    ) throws -> CADDocument {
        let temp = CADDocument()
        temp.importLayersBlocksEntities(
            layers: document.allLayers,
            blocks: document.allBlocks,
            entities: [])
        temp.textStyles = document.textStyles
        temp.dimensionStyles = document.dimensionStyles
        temp.leaderStyles = document.leaderStyles
        temp.linetypePatterns = document.linetypePatterns
        temp.currentLeaderStyleName = document.currentLeaderStyleName
        temp.unit = document.unit
        temp.insertionBase = basePoint
        switch source {
        case .entire:
            temp.importLayersBlocksEntities(
                layers: [], blocks: [], entities: document.allEntities)
        case .objects:
            temp.importLayersBlocksEntities(
                layers: [], blocks: [],
                entities: document.allEntities.filter { handles.contains($0.handle) })
        case .block:
            guard let block = document.allBlocks.first(where: {
                $0.name.caseInsensitiveCompare(blockName) == .orderedSame
            }) else {
                throw WblockError.blockNotFound(blockName)
            }
            // Explode one helper INSERT at identity so block-local coords
            // become world coords, then drop the helper + definition.
            let zeroID = temp.findLayer(named: "0")?.handle
                ?? temp.allLayers.first?.handle ?? UUID()
            let helper = CADEntity(
                layerID: zeroID, blockID: block.handle, transform: .identity)
            temp.addEntity(helper)
            _ = temp.explodeEntities(handles: [helper.handle])
            temp.removeEntities(handles: [helper.handle])
            temp.removeBlock(handle: block.handle)
        }
        return temp
    }

    private enum WblockError: Error {
        case blockNotFound(String)
    }

    static func parsePoint(_ text: String) -> Vector3? {
        let parts = text.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return Vector3(x: parts[0], y: parts[1], z: parts.count == 3 ? parts[2] : 0)
    }

    private func fmt(_ point: Vector3) -> String {
        "\(point.x),\(point.y),\(point.z)"
    }
}

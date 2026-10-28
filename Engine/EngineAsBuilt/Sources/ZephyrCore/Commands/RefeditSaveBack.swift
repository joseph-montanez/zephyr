import Foundation

// =========================================================================
// REFEDIT save-back: reloads the xref file, swaps its model-space
// entities for the edited set (layers/blocks/text styles mapped by name,
// missing ones carried over from the host), and writes it back.
// The host shadow refreshes through the normal reload path afterwards,
// so no manual shadow surgery is needed here.
// =========================================================================

public enum RefeditSaveBack {
    /// Block-editor bookkeeping keys that must not leak into the xref file.
    private static let scratchKeys: Set<String> = [
        "zephyr.blockEditor.hadPrimitiveStyle",
        "zephyr.blockEditor.colorByBlock",
        "zephyr.blockEditor.lineTypeByBlock",
        "zephyr.blockEditor.lineWeightByBlock",
    ]

    /// Saves `tempEntities` (a block-editor session's loose entities,
    /// block-space) into the drawing at `fileURL`. Returns the number of
    /// entities written.
    @MainActor
    public static func save(
        tempEntities: [CADEntity],
        hostDocument: CADDocument,
        to fileURL: URL
    ) throws -> Int {
        let fileDoc = CADDocument()
        try fileDoc.importDXF(url: fileURL)

        let ordered = tempEntities.sorted {
            if $0.drawOrder != $1.drawOrder { return $0.drawOrder < $1.drawOrder }
            return $0.handle.uuidString < $1.handle.uuidString
        }

        // Layers by name (create missing from host properties).
        var layerByUpper: [String: UUID] = [:]
        for layer in fileDoc.allLayers {
            layerByUpper[layer.name.uppercased()] = layer.handle
        }
        func fileLayerID(for hostLayerID: UUID) -> UUID {
            guard let hostLayer = hostDocument.layer(for: hostLayerID) else {
                return fileDoc.allLayers.first?.handle ?? UUID()
            }
            let key = hostLayer.name.uppercased()
            if let existing = layerByUpper[key] { return existing }
            // Handles are session-local UUIDs; the freshly imported file
            // cannot collide, so the host layer carries over untouched.
            fileDoc.addLayer(hostLayer)
            layerByUpper[key] = hostLayer.handle
            return hostLayer.handle
        }

        // Blocks by name (copy missing host definitions wholesale;
        // block-space geometry holds no nested references).
        var blockByUpper: [String: UUID] = [:]
        for block in fileDoc.allBlocks {
            blockByUpper[block.name.uppercased()] = block.handle
        }
        func fileBlockID(for hostBlockID: UUID) -> UUID? {
            guard let hostBlock = hostDocument.block(for: hostBlockID) else {
                return nil
            }
            let key = hostBlock.name.uppercased()
            if let existing = blockByUpper[key] { return existing }
            fileDoc.addBlock(hostBlock)
            blockByUpper[key] = hostBlock.handle
            return hostBlock.handle
        }

        // Text styles referenced by the edited set (copied by name).
        var neededStyles = Set<String>()
        for entity in ordered {
            guard let geometry = entity.localGeometry else { continue }
            for prim in geometry {
                if case .text(_, _, _, _, let style, _, _, _, _) = prim,
                   let style, !style.isEmpty {
                    neededStyles.insert(style)
                }
            }
            if case .string(let name) = entity.xdata["dxf.textStyle"],
               !name.isEmpty {
                neededStyles.insert(name)
            }
        }
        for name in neededStyles where fileDoc.textStyles[name] == nil {
            if let host = hostDocument.textStyles[name] {
                fileDoc.textStyles[name] = host
            }
        }

        var mapped: [CADEntity] = []
        mapped.reserveCapacity(ordered.count)
        for entity in ordered {
            var copy = entity
            copy.layerID = fileLayerID(for: entity.layerID)
            if let hostBlockID = entity.blockID {
                guard let fileBlockID = fileBlockID(for: hostBlockID) else {
                    continue
                }
                copy.blockID = fileBlockID
            }
            for key in scratchKeys { copy.xdata.removeValue(forKey: key) }
            copy.xdata.removeValue(forKey: "dxf.handle")
            mapped.append(copy)
        }

        let doomed = Set(fileDoc.allEntities.map(\.handle))
        fileDoc.replaceEntities(remove: doomed, add: mapped)
        try DXFExporter.export(document: fileDoc, to: fileURL)
        return mapped.count
    }
}

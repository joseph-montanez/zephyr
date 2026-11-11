import Foundation

// =========================================================================
// MARK: - CADClipboardImport
//
// The single commit path for clipboard paste (PASTECLIP, PASTEORIG,
// PASTEBLOCK). Capture snapshots a self-contained bundle from the source
// document; import remaps it into the target document by NAME:
//
//   - Layers: source layer name → target layer with the same name
//     (case-insensitive; target wins). Missing layers are imported.
//   - Blocks: named definitions resolve by name (target wins, AutoCAD
//     rule for `Door_36`-style collisions). Anonymous `*…` definitions
//     (dimensions, hatches) are always cloned — their geometry is
//     per-instance. Xrefs re-reference by name, else import as-is.
//   - Styles/linetypes: merged skip-if-exists (same rule as
//     DrawingFileInsert.mergeBundleSymbols).
//   - Images: assets + media definitions carried by name.
//
// Units follow INSUNITS: geometry scales once at commit via
// CADModelSpaceBaker.unitScale. Coordinates are WCS; the active UCS is
// ignored, exactly like PASTEORIG.
//
// The whole commit runs inside one undo group so one paste is one Undo.
// =========================================================================

public enum ClipboardPasteMode: Sendable {
    /// Place so the entry anchor lands at `insertion` (PASTECLIP).
    case anchored(insertion: Vector3)
    /// Keep (unit-scaled) original coordinates (PASTEORIG).
    case original
    /// Bundle into one anonymous block placed at `insertion` (PASTEBLOCK).
    case block(insertion: Vector3)
}

public struct ClipboardPasteResult: Sendable {
    /// Handles of the new entities (selected after paste).
    public var handles: [UUID]
    /// The new anonymous block for `.block` mode, else nil.
    public var blockHandle: UUID?

    public init(handles: [UUID] = [], blockHandle: UUID? = nil) {
        self.handles = handles
        self.blockHandle = blockHandle
    }
}

// MARK: - Capture

public enum CADClipboardCapture {
    /// Snapshot `handles` from `document` into a self-contained entry.
    /// Returns nil when nothing usable was selected. Viewport-projected
    /// copies are skipped (render-only, like duplicateEntities).
    /// - Parameters:
    ///   - basePointOverride: COPYBASE pick. Nil (COPYCLIP) anchors at the
    ///     lower-left of the selection bounds.
    public static func capture(
        from document: CADDocument,
        handles: Set<UUID>,
        basePointOverride: Vector3? = nil
    ) -> CADClipboardEntry? {
        var entities: [CADEntity] = []
        var blocks: [UUID: CADBlock] = [:]
        var layers: [UUID: Layer] = [:]
        var textStyleNames = Set<String>()
        var dimStyleNames = Set<String>()
        var leaderStyleNames = Set<String>()
        var linetypeNames = Set<String>()
        var imageNames = Set<String>()

        for handle in handles {
            guard let entity = document.entity(for: handle) else { continue }
            guard entity.isViewportProjected != true else { continue }
            entities.append(entity)
            if let bid = entity.blockID,
               let block = document.block(for: bid) {
                blocks[bid] = block
                collectBlockRefs(
                    block, textStyleNames: &textStyleNames,
                    linetypeNames: &linetypeNames, imageNames: &imageNames)
            }
            if let geom = entity.localGeometry {
                collectGeometryRefs(
                    geom, textStyleNames: &textStyleNames,
                    imageNames: &imageNames)
            }
            if let layer = document.layer(for: entity.layerID) {
                layers[layer.handle] = layer
                linetypeNames.insert(layer.lineType.uppercased())
            }
            if case .string(let style) = entity.xdata["dxf.textStyle"],
               !style.isEmpty {
                textStyleNames.insert(style)
            }
            if case .string(let name) = entity.xdata["dxf.lineType"],
               !name.isEmpty {
                linetypeNames.insert(name.uppercased())
            }
            if let box = entity.dimensionMetadata {
                dimStyleNames.insert(box.value.styleName)
            }
            if let leader = entity.leaderData?.value {
                leaderStyleNames.insert(leader.styleName)
            }
        }

        guard !entities.isEmpty else { return nil }

        // Layers named by block primitive styles must exist in the target.
        let styleLayerNames = Set(blocks.values.flatMap { block in
            block.primitiveStyles.values.compactMap { $0.effectiveLayerName }
        })
        if !styleLayerNames.isEmpty {
            let byUpper = Dictionary(
                uniqueKeysWithValues:
                    document.allLayers.map { ($0.name.uppercased(), $0) })
            for name in styleLayerNames where layers.values.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) == nil {
                if let layer = byUpper[name.uppercased()] {
                    layers[layer.handle] = layer
                }
            }
        }

        let anchor: Vector3
        if let basePointOverride {
            anchor = basePointOverride
        } else {
            var minX = Double.infinity, minY = Double.infinity
            for entity in entities {
                if let bb = entity.worldBoundingBox {
                    minX = min(minX, bb.min.x)
                    minY = min(minY, bb.min.y)
                }
            }
            anchor = minX.isFinite
                ? Vector3(x: minX, y: minY, z: 0) : .zero
        }

        return CADClipboardEntry(
            entities: entities,
            blocks: blocks,
            layers: layers,
            textStyles: pickStyles(
                document.textStyles, names: textStyleNames),
            dimensionStyles: pickStyles(
                document.dimensionStyles, names: dimStyleNames),
            leaderStyles: pickStyles(
                document.leaderStyles, names: leaderStyleNames),
            linetypePatterns: pickLinetypes(
                document.linetypePatterns, names: linetypeNames),
            imageAssets: pickImageAssets(document, names: imageNames),
            imageDefinitions: pickDefs(
                document.imageDefinitions, names: imageNames),
            pdfDefinitions: pickDefs(
                document.pdfDefinitions, names: imageNames),
            sourceUnit: document.unit,
            basePoint: anchor
        )
    }

    // MARK: - Reference collectors

    private static func collectBlockRefs(
        _ block: CADBlock,
        textStyleNames: inout Set<String>,
        linetypeNames: inout Set<String>,
        imageNames: inout Set<String>
    ) {
        for prim in block.geometry {
            if case .text(_, _, _, _, let style, _, _, _, _) = prim,
               let style, !style.isEmpty {
                textStyleNames.insert(style)
            }
            if case .image(_, _, _, let name, _, _) = prim {
                imageNames.insert(name)
            }
        }
        for style in block.primitiveStyles.values {
            if let lt = style.lineType, !lt.isEmpty {
                linetypeNames.insert(lt.uppercased())
            }
        }
    }

    private static func collectGeometryRefs(
        _ geom: [CADPrimitive],
        textStyleNames: inout Set<String>,
        imageNames: inout Set<String>
    ) {
        for prim in geom {
            if case .text(_, _, _, _, let style, _, _, _, _) = prim,
               let style, !style.isEmpty {
                textStyleNames.insert(style)
            }
            if case .image(_, _, _, let name, _, _) = prim {
                imageNames.insert(name)
            }
        }
    }

    private static func pickStyles<V>(
        _ table: [String: V], names: Set<String>
    ) -> [String: V] {
        var out: [String: V] = [:]
        for name in names {
            if let key = table.keys.first(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }), let value = table[key] {
                out[key] = value
            }
        }
        // "Standard" is the fallback every document resolves; carry it so
        // the target never renders an unresolvable default.
        if let key = table.keys.first(where: {
            $0.caseInsensitiveCompare("Standard") == .orderedSame
        }), let value = table[key], out[key] == nil {
            out[key] = value
        }
        return out
    }

    private static func pickLinetypes(
        _ table: [String: [Double]], names: Set<String>
    ) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for name in names {
            let upper = name.uppercased()
            if upper.isEmpty || upper == "CONTINUOUS" { continue }
            if let value = table[upper] {
                out[upper] = value
            } else if let key = table.keys.first(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }), let value = table[key] {
                out[key] = value
            }
        }
        return out
    }

    private static func pickImageAssets(
        _ document: CADDocument, names: Set<String>
    ) -> [String: CADImageAsset] {
        var out: [String: CADImageAsset] = [:]
        for name in names {
            if let asset = document.imageStore[name] {
                out[name] = asset
            }
        }
        return out
    }

    private static func pickDefs<V>(
        _ table: [String: V], names: Set<String>
    ) -> [String: V] {
        var out: [String: V] = [:]
        for name in names {
            if let key = table.keys.first(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }), let value = table[key] {
                out[key] = value
            } else if let value = table[name] {
                out[name] = value
            }
        }
        return out
    }
}

// MARK: - Import

extension CADDocument {
    /// Paste a clipboard entry into this document (possibly a different
    /// tab's document than the capture source). One undo group; returns
    /// the new entity handles for selection. Empty entry → no-op.
    @discardableResult
    public func importClipboardEntry(
        _ entry: CADClipboardEntry,
        mode: ClipboardPasteMode
    ) -> ClipboardPasteResult {
        guard !entry.entities.isEmpty else { return ClipboardPasteResult() }
        let scale = CADModelSpaceBaker.unitScale(
            from: entry.sourceUnit, to: unit)

        undoManager.beginUndoGroup()
        defer {
            if undoManager.endUndoGroup() == false { /* no pushes: nothing */ }
        }

        let layerRemap = remapClipboardLayers(entry.layers)
        let blockRemap = remapClipboardBlocks(entry.blocks)
        mergeClipboardSymbols(entry)

        switch mode {
        case .anchored(let insertion):
            let offset = Vector3(
                x: insertion.x - entry.basePoint.x * scale,
                y: insertion.y - entry.basePoint.y * scale,
                z: insertion.z - entry.basePoint.z * scale)
            let handles = placeClipboardEntities(
                entry, layerRemap: layerRemap, blockRemap: blockRemap,
                scale: scale, offset: offset)
            return ClipboardPasteResult(handles: handles)
        case .original:
            let handles = placeClipboardEntities(
                entry, layerRemap: layerRemap, blockRemap: blockRemap,
                scale: scale, offset: .zero)
            return ClipboardPasteResult(handles: handles)
        case .block(let insertion):
            return placeClipboardBlock(
                entry, layerRemap: layerRemap, blockRemap: blockRemap,
                scale: scale, insertion: insertion)
        }
    }

    // MARK: - Symbol remap (target wins by name)

    /// Remap source layers to target layers by name. Missing layers are
    /// imported (handle preserved when free). Never removes anything.
    private func remapClipboardLayers(
        _ source: [UUID: Layer]
    ) -> [UUID: UUID] {
        var remap: [UUID: UUID] = [:]
        var byName = Dictionary(
            uniqueKeysWithValues: allLayers.map {
                ($0.name.uppercased(), $0.handle)
            })
        for (sourceHandle, sourceLayer) in source {
            let upper = sourceLayer.name.uppercased()
            if let targetHandle = byName[upper] {
                remap[sourceHandle] = targetHandle
                continue
            }
            var imported = sourceLayer
            if layer(for: sourceHandle) != nil {
                // Handle taken by a different layer: mint a fresh one.
                imported = Layer(
                    handle: UUID(),
                    name: sourceLayer.name,
                    isVisible: sourceLayer.isVisible,
                    isFrozen: sourceLayer.isFrozen,
                    freezeInNewViewports: sourceLayer.freezeInNewViewports,
                    isLocked: sourceLayer.isLocked,
                    layerDescription: sourceLayer.layerDescription,
                    transparency: sourceLayer.transparency,
                    lineWeight: sourceLayer.lineWeight,
                    color: sourceLayer.color,
                    lineType: sourceLayer.lineType,
                    isPlottable: sourceLayer.isPlottable,
                    plotStyleName: sourceLayer.plotStyleName)
            }
            addLayer(imported)
            byName[upper] = imported.handle
            remap[sourceHandle] = imported.handle
        }
        return remap
    }

    /// Remap source blocks to target blocks. Named definitions resolve by
    /// name (target wins — AutoCAD collision rule). Anonymous `*…`
    /// definitions always clone. Xrefs re-reference by name when present.
    private func remapClipboardBlocks(
        _ source: [UUID: CADBlock]
    ) -> [UUID: UUID] {
        var remap: [UUID: UUID] = [:]
        for (sourceHandle, sourceBlock) in source {
            if sourceBlock.isXref {
                if let resident = allBlocks.first(where: {
                    $0.name.caseInsensitiveCompare(sourceBlock.name)
                        == .orderedSame
                }) {
                    remap[sourceHandle] = resident.handle
                } else {
                    let handle = block(for: sourceHandle) == nil
                        ? sourceHandle : UUID()
                    var imported = sourceBlock
                    if handle != sourceBlock.handle {
                        imported = CADBlock(
                            handle: handle,
                            name: sourceBlock.name,
                            geometry: sourceBlock.geometry,
                            primitiveStyles: sourceBlock.primitiveStyles,
                            primitiveXData: sourceBlock.primitiveXData,
                            dxfFlags: sourceBlock.dxfFlags,
                            attributeDefinitions:
                                sourceBlock.attributeDefinitions)
                        imported.xrefDescriptor =
                            sourceBlock.xrefDescriptor
                    }
                    addBlock(imported)
                    remap[sourceHandle] = imported.handle
                }
                continue
            }
            if sourceBlock.name.hasPrefix("*") {
                let clone = CADBlock(
                    handle: UUID(),
                    name: sourceBlock.name,
                    geometry: sourceBlock.geometry,
                    primitiveStyles: sourceBlock.primitiveStyles,
                    primitiveXData: sourceBlock.primitiveXData,
                    dxfFlags: sourceBlock.dxfFlags,
                    attributeDefinitions:
                        sourceBlock.attributeDefinitions)
                addBlock(clone)
                remap[sourceHandle] = clone.handle
                continue
            }
            if let resident = allBlocks.first(where: {
                $0.name.caseInsensitiveCompare(sourceBlock.name)
                    == .orderedSame
            }) {
                remap[sourceHandle] = resident.handle
            } else {
                let handle = block(for: sourceHandle) == nil
                    ? sourceHandle : UUID()
                let imported = CADBlock(
                    handle: handle,
                    name: sourceBlock.name,
                    geometry: sourceBlock.geometry,
                    primitiveStyles: sourceBlock.primitiveStyles,
                    primitiveXData: sourceBlock.primitiveXData,
                    dxfFlags: sourceBlock.dxfFlags,
                    attributeDefinitions:
                        sourceBlock.attributeDefinitions)
                addBlock(imported)
                remap[sourceHandle] = imported.handle
            }
        }
        return remap
    }

    /// Merge entry styles, linetypes, and media into the target,
    /// skip-if-exists (same rule as mergeBundleSymbols).
    private func mergeClipboardSymbols(_ entry: CADClipboardEntry) {
        for (key, value) in entry.textStyles {
            let exists = textStyles.keys.contains(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            })
            if !exists { textStyles[key] = value }
        }
        for (key, value) in entry.dimensionStyles {
            let exists = dimensionStyles.keys.contains(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            })
            if !exists { dimensionStyles[key] = value }
        }
        for (key, value) in entry.leaderStyles {
            let exists = leaderStyles.keys.contains(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            })
            if !exists { leaderStyles[key] = value }
        }
        for (key, value) in entry.linetypePatterns {
            if linetypePatterns[key] == nil,
               linetypePatterns.keys.first(where: {
                   $0.caseInsensitiveCompare(key) == .orderedSame
               }) == nil {
                linetypePatterns[key] = value
            }
        }
        for (name, asset) in entry.imageAssets where imageStore[name] == nil {
            addImageAsset(asset)
        }
        for (name, def) in entry.imageDefinitions
            where imageDefinition(named: name) == nil {
            imageDefinitions[name] = def
        }
        for (name, def) in entry.pdfDefinitions
            where pdfDefinition(named: name) == nil {
            pdfDefinitions[name] = def
        }
    }

    // MARK: - Entity placement

    /// Clone entry entities into this document with unit scale + offset.
    /// Internal array-path references (path entity also copied) are
    /// remapped; external ones are left as-is (documented v1 limit).
    private func placeClipboardEntities(
        _ entry: CADClipboardEntry,
        layerRemap: [UUID: UUID],
        blockRemap: [UUID: UUID],
        scale: Double,
        offset: Vector3
    ) -> [UUID] {
        let scaleT = Transform3D.scaled(
            by: Vector3(x: scale, y: scale, z: scale))
        let offsetT = Transform3D.translated(by: offset)
        let mapT = offsetT.multiplying(by: scaleT)
        let fallbackLayer = activeLayerID
            ?? allLayers.first(where: {
                $0.name.caseInsensitiveCompare("0") == .orderedSame
            })?.handle ?? allLayers.first?.handle

        var handleMap: [UUID: UUID] = [:]
        handleMap.reserveCapacity(entry.entities.count)
        for source in entry.entities {
            handleMap[source.handle] = UUID()
        }

        var staged: [CADEntity] = []
        staged.reserveCapacity(entry.entities.count)
        for source in entry.entities {
            let layerID = layerRemap[source.layerID] ?? fallbackLayer
            guard let layerID else { continue }
            var blockID = source.blockID
            if let bid = blockID {
                blockID = blockRemap[bid] ?? bid
                if block(for: blockID!) == nil { blockID = nil }
                guard blockID != nil || source.localGeometry != nil
                else { continue }
            }
            var arrayData = source.arrayData
            if let path = arrayData?.pathEntityHandle,
               let mapped = handleMap[path] {
                arrayData?.pathEntityHandle = mapped
                arrayData?.cachedPath = []
            }
            var entity = CADEntity(
                handle: handleMap[source.handle]!,
                layerID: layerID,
                blockID: blockID,
                localGeometry: source.localGeometry,
                dimensionMetadata: source.dimensionMetadata,
                leaderData: source.leaderData,
                arrayData: arrayData,
                transform: mapT.multiplying(by: source.transform),
                xdata: source.xdata,
                attributeValues: source.attributeValues,
                drawOrder: source.drawOrder)
            // Re-derive cached bounds/anchors for the target document.
            if let bid = blockID, let block = block(for: bid) {
                entity.localBoundingBox = block.localBoundingBox
                entity.updateAnchorCache(from: block.geometry)
            }
            staged.append(entity)
        }
        guard !staged.isEmpty else { return [] }
        addEntities(staged)
        return staged.map(\.handle)
    }

    /// Bundle the entry into one anonymous `*A` block at `insertion`.
    /// Loose entities bake with their entity-layer style; nested block
    /// content keeps its per-primitive styles (layer names remapped to
    /// the target). Attributes union to defaults (per-insert variance
    /// cannot survive flattening — v1 limit, same as WBLOCK of inserts).
    private func placeClipboardBlock(
        _ entry: CADClipboardEntry,
        layerRemap: [UUID: UUID],
        blockRemap _: [UUID: UUID],
        scale: Double,
        insertion: Vector3
    ) -> ClipboardPasteResult {
        let scaledBase = Vector3(
            x: entry.basePoint.x * scale,
            y: entry.basePoint.y * scale,
            z: entry.basePoint.z * scale)
        let unbase = Transform3D.translated(by: Vector3(
            x: -scaledBase.x, y: -scaledBase.y, z: -scaledBase.z))
        let scaleT = Transform3D.scaled(
            by: Vector3(x: scale, y: scale, z: scale))

        // Source layer name → target layer name for style remap.
        var layerNameMap: [String: String] = [:]
        for (sourceHandle, targetHandle) in layerRemap {
            if let source = entry.layers[sourceHandle],
               let target = layer(for: targetHandle) {
                layerNameMap[source.name.uppercased()] = target.name
            }
        }

        var geometry: [CADPrimitive] = []
        var styles: [Int: CADPrimitiveStyle] = [:]
        var xdata: [Int: [String: XDataValue]] = [:]
        var attrDefs: [CADAttributeDefinition] = []
        var seenTags = Set<String>()

        for entity in entry.entities {
            let toLocal = unbase.multiplying(by: scaleT)
                .multiplying(by: entity.transform)
            if let bid = entity.blockID,
               let block = entry.blocks[bid] {
                let transformed = CADGeometryMath.transformPrimitives(
                    block.geometry, by: toLocal)
                let base = geometry.count
                geometry.append(contentsOf: transformed)
                for (index, style) in block.primitiveStyles {
                    var remapped = style
                    if let name = style.layerName,
                       let mapped = layerNameMap[name.uppercased()] {
                        remapped.layerName = mapped
                    }
                    styles[base + index] = remapped
                }
                for (index, xd) in block.primitiveXData where !xd.isEmpty {
                    xdata[base + index] = xd
                }
                for def in block.attributeDefinitions
                    where seenTags.insert(def.key).inserted {
                    var scaled = def
                    scaled.position = toLocal.transformPoint(def.position)
                    scaled.height = def.height * scale
                    attrDefs.append(scaled)
                }
            } else if let local = entity.localGeometry, !local.isEmpty {
                let transformed = CADGeometryMath.transformPrimitives(
                    local, by: toLocal)
                let base = geometry.count
                geometry.append(contentsOf: transformed)
                let layerName: String? = {
                    if let target = layer(for: layerRemap[entity.layerID]
                        ?? entity.layerID) {
                        return target.name
                    }
                    return nil
                }()
                var style = CADPrimitiveStyle(layerName: layerName)
                if case .string(let hex) = entity.xdata["dxf.color"] {
                    style.color = ColorRGBA(hex: hex)
                }
                if case .string(let lt) = entity.xdata["dxf.lineType"] {
                    style.lineType = lt
                }
                if case .double(let lw) = entity.xdata["dxf.lineWeight"],
                   lw >= 0 {
                    style.lineWeight = lw
                }
                if case .double(let lts) = entity.xdata["dxf.lineTypeScale"] {
                    style.lineTypeScale = lts
                }
                if case .double(let op) = entity.xdata["dxf.opacity"] {
                    style.opacity = max(0.0, min(1.0, op))
                }
                for index in local.indices {
                    styles[base + index] = style
                    if !entity.xdata.isEmpty {
                        xdata[base + index] = entity.xdata
                    }
                }
            }
        }

        guard !geometry.isEmpty else { return ClipboardPasteResult() }

        var blockName = "*A" + UUID().uuidString.prefix(8).uppercased()
        while allBlocks.contains(where: {
            $0.name.caseInsensitiveCompare(blockName) == .orderedSame
        }) {
            blockName = "*A" + UUID().uuidString.prefix(8).uppercased()
        }
        var block = CADBlock(
            name: String(blockName),
            geometry: geometry,
            primitiveStyles: styles,
            primitiveXData: xdata,
            attributeDefinitions: attrDefs)
        block.updateBoundingBox()
        addBlock(block)

        let layerID = activeLayerID
            ?? allLayers.first(where: {
                $0.name.caseInsensitiveCompare("0") == .orderedSame
            })?.handle ?? allLayers.first?.handle ?? UUID()
        var instance = CADEntity(
            layerID: layerID,
            blockID: block.handle,
            localGeometry: nil,
            transform: Transform3D.translated(by: insertion))
        instance.attributeValues = CADAttributeSync.apply(
            definitions: attrDefs, to: [:])
        addEntities([instance])
        return ClipboardPasteResult(
            handles: [instance.handle], blockHandle: block.handle)
    }
}

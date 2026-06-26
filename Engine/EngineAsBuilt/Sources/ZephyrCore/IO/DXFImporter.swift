import Foundation

// =========================================================================
// MARK: - DXFImporter
//
// Parses AutoCAD DXF (Drawing Exchange Format) files and produces
// Zephyr CAD document entities. Supports DXF versions R12 through
// latest, including:
//   - Basic entities: LINE, CIRCLE, ARC, POLYLINE, LWPOLYLINE, TEXT, MTEXT
//   - Blocks and INSERT references with nested transforms
//   - Layers with color, line type, and visibility
//   - Splines, ellipses, hatches, and rays
//   - Text styles and SHX/TTF font references
//
// The importer produces layers, blocks, and entities arrays that are
// consumed by CADDocument.importLayersBlocksEntities().

import CDXFRW

public enum DXFDrawingViewKind: Sendable, Equatable {
    case model
    case sheet
}

public struct DXFDrawingView: Sendable {
    public let name: String
    public let kind: DXFDrawingViewKind
    public let entities: [CADEntity]

    public init(name: String, kind: DXFDrawingViewKind, entities: [CADEntity]) {
        self.name = name
        self.kind = kind
        self.entities = entities
    }
}

public struct DXFImportResult: Sendable {
    public let layers: [Layer]
    public let blocks: [CADBlock]
    public let entities: [CADEntity]
    public let textStyleFonts: [String: String]
    public let linetypePatterns: [String: [Double]]
    public let views: [DXFDrawingView]
}

// =========================================================================
// MARK: - DXFImporter
// =========================================================================

/// Converts DXF data (via the libdxfrw C++ bridge) into the engine's
/// native CAD types: `Layer`, `CADBlock`, `CADPrimitive`, and `CADEntity`.
public enum DXFImporter {

    // MARK: - Public API

    /// Parse a DXF file at `filePath` and return native CAD types.
    /// - Returns: Tuple of layers, blocks, entities, text style fonts, and linetype patterns ready to be added to a `CADDocument`.
    @MainActor
    public static func importDXF(filePath: String) throws -> (layers: [Layer], blocks: [CADBlock], entities: [CADEntity], textStyleFonts: [String: String], linetypePatterns: [String: [Double]]) {
        let result = try importDXFViews(filePath: filePath)
        return (result.layers, result.blocks, result.entities, result.textStyleFonts, result.linetypePatterns)
    }

    /// Parse a DXF and preserve its model-space and paper-space layout views.
    @MainActor
    public static func importDXFViews(filePath: String) throws -> DXFImportResult {

        var result = DXFRW_Result()
        let ok = filePath.withCString { pathPtr in
            dxfrw_read(pathPtr, &result)
        }

        guard ok != 0, result.success != 0 else {
            let msg = result.errorMessage.map { String(cString: $0) } ?? "Unknown DXF parse error"
            defer { dxfrw_result_free(&result) }
            throw DXFImportError.parseFailed(msg)
        }

        defer { dxfrw_result_free(&result) }

        // 1. Convert layers
        var layers: [Layer] = []
        var layerNameToID: [String: UUID] = [:]
        // Per-layer style lookup used to resolve BYLAYER color/linetype for
        // entities inside block definitions (their geometry is flattened into
        // CADPrimitives, so the render path can no longer resolve BYLAYER
        // against the sub-entity's own layer — only the INSERT's layer survives).
        var layerStyleByName: [String: Layer] = [:]

        for i in 0..<Int(result.layerCount) {
            let src = result.layers[i]
            let handle = UUID()
            let name = src.name.map { String(cString: $0) } ?? "Layer\(i)"
            layerNameToID[name] = handle

            let layerColorIndex = abs(src.color)
            let color = DXFColorTable.aciToRGBA(layerColorIndex, color24: src.color24)
            let lineType = src.lineTypeName.map { String(cString: $0) } ?? "CONTINUOUS"
            let opacity = DXFColorTable.transparencyToOpacity(src.transparency)
            if src.transparency >= 0 && opacity < 1.0 {
                print("[DXFImport] Layer \"\(name)\": DXF transparency=\(src.transparency) → opacity=\(String(format: "%.2f", opacity))")
            }
            let layer = Layer(
                handle: handle,
                name: name,
                isVisible: src.color >= 0,
                lineWeight: DXFColorTable.lineWeightToMM(src.lineWeight),
                color: color,
                lineType: lineType,
                opacity: opacity
            )
            layers.append(layer)
            layerStyleByName[name] = layer
        }

        // Ensure a default "0" layer always exists (DXF standard)
        if layerNameToID["0"] == nil {
            let handle = UUID()
            layerNameToID["0"] = handle
            let zeroLayer = Layer(handle: handle, name: "0", isVisible: true, lineWeight: 0.25, color: .white)
            layers.append(zeroLayer)
            layerStyleByName["0"] = zeroLayer
        }

        // 1b. Parse the linetype table — real dash patterns in drawing units.
        // DXF group-49 convention: > 0 = dash (pen down), < 0 = gap (pen up),
        // 0 = dot. Continuous linetypes have no elements and are omitted, so a
        // miss in this map means "no dashing defined in the file" and the
        // name-based heuristic in CADPrimitiveGenerator is the fallback.
        var linetypePatterns: [String: [Double]] = [:]
        for i in 0..<Int(result.linetypeCount) {
            let src = result.linetypes[i]
            guard let namePtr = src.name, src.patternCount > 0, let patPtr = src.pattern else { continue }
            let name = String(cString: namePtr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            var pattern: [Double] = []
            pattern.reserveCapacity(Int(src.patternCount))
            for j in 0..<Int(src.patternCount) {
                pattern.append(patPtr[j])
            }
            // Skip degenerate all-zero patterns — treat as continuous
            if pattern.reduce(0.0, { $0 + abs($1) }) > 1e-9 {
                linetypePatterns[name] = pattern
            }
        }

        // 2. Convert blocks
        var blocks: [CADBlock] = []
        var blockNameToID: [String: UUID] = [:]
        var blockOwnerHandleToName: [UInt32: String] = [:]
        // Block base points (DXF group codes 10/20/30 on the BLOCK record), stored
        // in the engine's Y-flipped space (i.e. F·base). AutoCAD places a block so
        // its base point lands on the INSERT's insertion point, so when expanding an
        // INSERT we must draw geometry relative to (local - base). See makeEntity().
        var blockNameToBase: [String: Vector3] = [:]

        for i in 0..<Int(result.blockCount) {
            let src = result.blocks[i]
            let handle = UUID()
            let name = src.name.map { String(cString: $0) } ?? "Block\(i)"
            blockNameToID[name] = handle
            if let metadata = result.blockMetadata {
                let ownerHandle = metadata[i].ownerHandle
                if ownerHandle != 0 {
                    blockOwnerHandleToName[UInt32(ownerHandle)] = name
                }
            }
            blockNameToBase[name] = toVector(src.basePoint)

            // Block geometry is stored as entities with blockName = this block's name
            // We'll populate geometry in a second pass
            blocks.append(CADBlock(handle: handle, name: name, geometry: []))
        }

        // 3. Collect entity data from the raw result, grouped by block membership
        // Entities inside a block definition have `blockName` set to the parent block name.
        // Entities NOT inside a block have `blockName == nil`.
        var blockGeometries: [String: [CADPrimitive]] = [:]
        // Nested INSERTs found inside block definitions (e.g. dimension arrowheads, or
        // sub-blocks of a symbol). Recorded per parent block so they can be flattened
        // (inlined as transformed geometry) below — block definitions can't hold a live
        // block reference, so their geometry must be baked in.
        var blockNestedInserts: [String: [(refBlock: String, transform: Transform3D)]] = [:]
        var paperViewports: [String: [DXFViewportDefinition]] = [:]
        var looseEntities: [(entity: CADEntity, layerName: String)] = []
        var entityHandleToOwner: [UInt32: UInt32] = [:]
        let asciiEntitySpaces = parseASCIIEntitySpaces(filePath: filePath)
        if let metadata = result.entityMetadata {
            for i in 0..<Int(result.entityCount) {
                if metadata[i].handle != 0 {
                    entityHandleToOwner[UInt32(metadata[i].handle)] =
                        UInt32(metadata[i].ownerHandle)
                }
            }
        }

        func owningBlockName(for ownerHandle: UInt32) -> String? {
            var handle = ownerHandle
            var visited: Set<UInt32> = []
            while handle != 0, visited.insert(handle).inserted {
                if let blockName = blockOwnerHandleToName[handle] {
                    return blockName
                }
                guard let parent = entityHandleToOwner[handle] else { return nil }
                handle = parent
            }
            return nil
        }

        // Find a uniform arrow size for all leaders in the drawing
        var leaderHeights: [Double] = []
        for i in 0..<Int(result.entityCount) {
            let src = result.entities[i]
            if src.type == DXFRW_ET_LEADER && src.textHeight > 0 {
                leaderHeights.append(src.textHeight)
            }
        }
        
        let baseLeaderHeight = max(0.05, leaderHeights.min() ?? 2.5)
        let drawingArrowSize = baseLeaderHeight * 1.5

        // Parse text styles BEFORE entity creation so makeEntity can resolve
        // default font names when parsing MTEXT formatting codes.
        var textStyleFonts: [String: String] = [:]
        for i in 0..<Int(result.textStyleCount) {
            let src = result.textStyles[i]
            if let namePtr = src.name, let fontPtr = src.primaryFont {
                let name = String(cString: namePtr)
                let fontName = String(cString: fontPtr)
                textStyleFonts[name] = fontName
            }
        }

        // Main pass: Collect entity data
        for i in 0..<Int(result.entityCount) {
            let src = result.entities[i]
            let metadata = result.entityMetadata?[i]

            let explicitParentBlockName = src.parentBlockName.map { String(cString: $0) }
            let entityHandle = UInt32(metadata?.handle ?? 0)
            let asciiSpace = entityHandle == 0 ? nil : asciiEntitySpaces[entityHandle]
            let ownerHandle = UInt32(metadata?.ownerHandle ?? 0)
            let ownerBlockName = ownerHandle == 0
                ? nil
                : owningBlockName(for: ownerHandle)
            let parentBlockName = explicitParentBlockName ?? ownerBlockName
            
            let isModelSpaceEntity = parentBlockName?.uppercased() == "*MODEL_SPACE"
                || (parentBlockName == nil && asciiSpace == .model)
                || (parentBlockName == nil && asciiSpace == nil && (metadata?.space ?? 0) == 0)
            
            let isPaperSpaceEntity = parentBlockName?.uppercased().hasPrefix("*PAPER_SPACE") == true
                || (parentBlockName == nil && asciiSpace == .paper)
                || (parentBlockName == nil && asciiSpace == nil && metadata?.space == 1)

            if let bn = parentBlockName, !bn.isEmpty, !isModelSpaceEntity {
                if src.type == DXFRW_ET_VIEWPORT {
                    paperViewports[bn, default: []].append(DXFViewportDefinition(src))
                    continue
                }
                // This entity belongs to a block definition's geometry.
                if src.type == DXFRW_ET_INSERT, let refPtr = src.blockName {
                    // Nested block reference: record it for flattening rather than dropping
                    // it (this is how dimension arrowheads and other sub-blocks survive).
                    let refName = String(cString: refPtr)
                    let t = insertTransform(from: src, blockNameToBase: blockNameToBase)
                    blockNestedInserts[bn, default: []].append((refName, t))
                } else if src.type == DXFRW_ET_DIMENSION, let refPtr = src.blockName {
                    // DIMENSION geometry is stored in an anonymous *D block. Its
                    // primitives are already expressed in the owning space's
                    // coordinates, so inline that block with an identity transform.
                    let refName = String(cString: refPtr)
                    blockNestedInserts[bn, default: []].append((refName, .identity))
                } else {
                    // Block geometry is flattened into CADPrimitives, which only carry
                    // an optional per-primitive color — the sub-entity's layer and
                    // linetype don't survive into the render path (the INSERT's layer
                    // gets applied to the whole block there). Per the DXF model,
                    // BYLAYER attributes of block sub-entities resolve against the
                    // SUB-ENTITY's own layer, not the INSERT's, so resolve and bake
                    // them here. Exception: layer "0" inside a block means "inherit
                    // from the INSERT", which is exactly what the render path already
                    // does, so leave those untouched (nil color, no baked dashes).
                    let subLayerName = src.layerName.map { String(cString: $0) } ?? "0"
                    let subLayer = layerStyleByName[subLayerName]

                    // A sub-entity on a frozen/off layer is invisible regardless of
                    // the INSERT's layer — drop it instead of rendering it in the
                    // INSERT's style.
                    if let sl = subLayer, !sl.isVisible {
                        continue
                    }

                    let bylayerColor: ColorRGBA? = (subLayerName != "0") ? subLayer?.color : nil
                    var primitives = DXFEntityConverter.convertEntityToPrimitives(
                        src, arrowSize: drawingArrowSize, bylayerColor: bylayerColor)

                    // Resolve the sub-entity's effective linetype and, if it's a
                    // dashed pattern, bake the dashes into the geometry now (in
                    // block-local drawing units — the same units the render path's
                    // dash generator works in, so appearance is identical).
                    // Prefer the file's own LTYPE table pattern; fall back to the
                    // name-based heuristic (converted to signed dash/gap form)
                    // only when the file doesn't define the linetype.
                    if let effectiveLT = resolveBlockSubEntityLinetype(
                            entityLinetype: src.lineTypeName.map { String(cString: $0) },
                            layerName: subLayerName,
                            layerLinetype: subLayer?.lineType) {
                        let key = effectiveLT
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .uppercased()
                        let pattern: [Double]?
                        if let real = linetypePatterns[key] {
                            pattern = real
                        } else if let heuristic = CADPrimitiveGenerator.dashPattern(for: effectiveLT) {
                            // Heuristic patterns are unsigned alternating
                            // [draw, gap, ...] — convert to signed group-49 form.
                            pattern = heuristic.enumerated().map { idx, len in
                                idx % 2 == 0 ? len : -len
                            }
                        } else {
                            pattern = nil // continuous — nothing to bake
                        }
                        if let pattern {
                            let globalScale = result.globalLinetypeScale > 0 ? result.globalLinetypeScale : 1.0
                            let ltScale = (src.lineTypeScale > 0 ? src.lineTypeScale : 1.0) * globalScale
                            primitives = bakeDashedLinetype(primitives, pattern: pattern, scale: ltScale)
                        }
                    }

                    blockGeometries[bn, default: []].append(contentsOf: primitives)
                    if primitives.count > 1000 {
                        let typeStr = src.type == DXFRW_ET_LWPOLYLINE ? "LWPOLYLINE(\(primitives.count)segs)" :
                                      src.type == DXFRW_ET_POLYLINE ? "POLYLINE(\(primitives.count)segs)" :
                                      src.type == DXFRW_ET_HATCH ? "HATCH" :
                                      src.type == DXFRW_ET_TEXT || src.type == DXFRW_ET_MTEXT ? "TEXT" :
                                      src.type == DXFRW_ET_SPLINE ? "SPLINE" :
                                      src.type == DXFRW_ET_INSERT ? "INSERT" : "other"
                        print("[DXFImport] Block '\(bn)' entity #\(i): \(typeStr)")
                    }
                }
            } else if isModelSpaceEntity
                        || (!isPaperSpaceEntity && (metadata?.space ?? 0) == 0) {
                // Top-level entity
                let primitives = DXFEntityConverter.convertEntityToPrimitives(src, arrowSize: drawingArrowSize)
                let layerName = src.layerName.map { String(cString: $0) } ?? "0"
                let layerID = layerNameToID[layerName] ?? layerNameToID["0"]!

                let entity = makeEntity(
                    from: src,
                    primitives: primitives,
                    layerID: layerID,
                    blockNameToID: blockNameToID,
                    blockNameToBase: blockNameToBase,
                    drawOrder: i,
                    globalLinetypeScale: result.globalLinetypeScale,
                    textStyleFonts: textStyleFonts
                )
                looseEntities.append((entity, layerName))
            }
        }

        // 3b. Flatten block geometry: each block's own primitives plus the (recursively
        // flattened) geometry of any nested INSERTs, transformed into the parent's space.
        // Memoized; guards against cyclic block references.
        var flattenedCache: [String: [CADPrimitive]] = [:]
        var flattenVisiting: Set<String> = []
        func flattenBlock(_ name: String) -> [CADPrimitive] {
            if let cached = flattenedCache[name] { return cached }
            if flattenVisiting.contains(name) { return blockGeometries[name] ?? [] }
            flattenVisiting.insert(name)
            var geom = blockGeometries[name] ?? []
            for nested in blockNestedInserts[name] ?? [] {
                let sub = flattenBlock(nested.refBlock)
                if !sub.isEmpty {
                    geom.append(contentsOf: transformPrimitives(sub, by: nested.transform))
                }
            }
            flattenVisiting.remove(name)
            flattenedCache[name] = geom
            return geom
        }

        // 4. Update block geometries (using flattened geometry)
        var finalBlocks: [CADBlock] = []
        for var block in blocks {
            let geoms = flattenBlock(block.name)
            if !geoms.isEmpty {
                block.geometry = geoms
                block.updateBoundingBox()
            }
            if block.geometry.count > 100000 {
                let box = block.localBoundingBox
                let bb = "(\(box.min.x),\(box.min.y))-(\(box.max.x),\(box.max.y))"
                print("[DXFImport] Large block '\(block.name)' has \(block.geometry.count) primitives (bbox=\(bb))")
            }
            finalBlocks.append(block)
        }

        // 5. Convert loose entities to final CADEntity list
        var entities: [CADEntity] = []
        for (var entity, _) in looseEntities {
            // If entity references a block, pull its bounding box
            if let bid = entity.blockID, let block = finalBlocks.first(where: { $0.handle == bid }) {
                entity.localBoundingBox = block.localBoundingBox
                entity.updateAnchorCache()
            }
            entities.append(entity)
        }

        var maxWeight = 0.0
        for i in 0..<Int(result.entityCount) {
            let src = result.entities[i]
            if src.lineWeight > maxWeight {
                maxWeight = src.lineWeight
            }
        }
        print("MAX LINEWEIGHT READ FROM DXF: \(maxWeight)")

        let layoutInfo = parseASCIILayouts(filePath: filePath)
        var views = [DXFDrawingView(name: "Model", kind: .model, entities: entities)]
        let paperBlocks = finalBlocks
            .filter { $0.name.hasPrefix("*Paper_Space") }
            .sorted {
                let lhs = layoutInfo[$0.name]?.order ?? Int.max
                let rhs = layoutInfo[$1.name]?.order ?? Int.max
                return lhs == rhs ? $0.name < $1.name : lhs < rhs
            }

        for block in paperBlocks {
            let name = layoutInfo[block.name]?.name ?? block.name
            var sheetEntities: [CADEntity] = []
            if !block.geometry.isEmpty {
                sheetEntities.append(CADEntity(
                    layerID: layerNameToID["0"]!,
                    blockID: block.handle,
                    transform: .identity,
                    drawOrder: 0,
                    localBoundingBox: block.localBoundingBox
                ))
            }

            for viewport in paperViewports[block.name] ?? [] where viewport.isModelViewport {
                let projection = viewport.modelToPaperTransform
                for modelEntity in entities where viewport.intersectsModelEntity(modelEntity) {
                    var projected = modelEntity
                    let projectedDrawOrder = projected.drawOrder == Int.max
                        ? Int.max
                        : projected.drawOrder + 1
                    projected = CADEntity(
                        layerID: projected.layerID,
                        blockID: projected.blockID,
                        localGeometry: projected.localGeometry,
                        transform: projection.multiplying(by: projected.transform),
                        xdata: projected.xdata,
                        drawOrder: projectedDrawOrder,
                        localBoundingBox: projected.localBoundingBox,
                        anchorPoints: projected.anchorPoints
                    )
                    sheetEntities.append(projected)
                }
            }
            views.append(DXFDrawingView(name: name, kind: .sheet, entities: sheetEntities))
        }

        return DXFImportResult(
            layers: layers,
            blocks: finalBlocks,
            entities: entities,
            textStyleFonts: textStyleFonts,
            linetypePatterns: linetypePatterns,
            views: views
        )
    }

    private struct DXFViewportDefinition {
        let paperCenterX: Double
        let paperCenterY: Double
        let paperWidth: Double
        let paperHeight: Double
        let status: Int
        let id: Int
        let viewCenterX: Double
        let viewCenterY: Double
        let viewTargetX: Double
        let viewTargetY: Double
        let viewHeight: Double
        let twistAngle: Double

        init(_ src: DXFRW_EntityData) {
            paperCenterX = src.basePoint.x
            paperCenterY = src.basePoint.y
            paperWidth = src.viewportWidth
            paperHeight = src.viewportHeight
            status = Int(src.viewportStatus)
            id = Int(src.viewportID)
            viewCenterX = src.viewportViewCenterX
            viewCenterY = src.viewportViewCenterY
            viewTargetX = src.viewportViewTarget.x
            viewTargetY = src.viewportViewTarget.y
            viewHeight = src.viewportViewHeight
            twistAngle = src.viewportTwistAngle
        }

        var isModelViewport: Bool {
            // In AutoCAD, the viewport that represents the paper space layout boundaries
            // itself usually has ID == 1. Model viewports have ID > 1.
            // Some files (e.g. older DXFs) don't emit ID (which parses as -1 or 0),
            // in which case the paper boundary viewport usually has status == 1.
            let isLayoutViewport = (id > 0) ? (id == 1) : (status == 1)
            
            // We ignore the layout viewport because it is just a background
            // paper-space bookkeeping viewport. Mechanical drawings commonly
            // make it larger than the sheet, so AutoCAD shows contextual model
            // geometry beyond the white paper boundary while still in PAPER.
            return status > 0 && !isLayoutViewport && paperHeight > 1e-9 && viewHeight > 1e-9
        }

        var modelToPaperTransform: Transform3D {
            let scale = paperHeight / viewHeight
            let centerX = viewTargetX + viewCenterX
            let centerY = viewTargetY + viewCenterY
            return Transform3D.translated(by: Vector3(x: paperCenterX, y: -paperCenterY, z: 0))
                .multiplying(by: .rotated(by: twistAngle))
                .multiplying(by: .scaled(by: Vector3(x: scale, y: scale, z: 1)))
                .multiplying(by: .translated(by: Vector3(x: -centerX, y: centerY, z: 0)))
        }

        func intersectsModelEntity(_ entity: CADEntity) -> Bool {
            guard let box = entity.worldBoundingBox else { return false }
            let scale = paperHeight / viewHeight
            let modelWidth = paperWidth / scale
            let centerX = viewTargetX + viewCenterX
            let centerY = -(viewTargetY + viewCenterY)
            let minX = centerX - modelWidth / 2
            let maxX = centerX + modelWidth / 2
            let minY = centerY - viewHeight / 2
            let maxY = centerY + viewHeight / 2
            // Text is not currently GPU-clipped to the viewport rectangle.
            // Requiring its full estimated bounds to fit prevents labels at a
            // viewport edge from rendering outside the paper-space window.
            if entity.xdata["dxf.text"] != nil {
                return box.min.x >= minX && box.max.x <= maxX
                    && box.min.y >= minY && box.max.y <= maxY
            }
            return box.max.x >= minX && box.min.x <= maxX
                && box.max.y >= minY && box.min.y <= maxY
        }
    }

    private struct DXFLayoutInfo {
        let name: String
        let order: Int
    }

    private enum ASCIIEntitySpace {
        case model
        case paper
    }

    /// Classifies top-level ASCII DXF entities from the source records.
    /// Many exporters omit both owner (330) and space (67) in ENTITIES; DXF
    /// defines that omission as model space. This source-level classification
    /// avoids relying on parser defaults that vary between libdxfrw versions.
    private static func parseASCIIEntitySpaces(
        filePath: String
    ) -> [UInt32: ASCIIEntitySpace] {
        guard let data = FileManager.default.contents(atPath: filePath) else { return [:] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
        guard let text, !text.contains("\0") else { return [:] }
        let lines = text.components(separatedBy: .newlines)

        var blockRecordNames: [String: String] = [:]
        var section = ""
        var recordType = ""
        var recordPairs: [(Int, String)] = []
        var result: [UInt32: ASCIIEntitySpace] = [:]

        func finishRecord() {
            guard !recordType.isEmpty else { return }
            if section == "TABLES", recordType == "BLOCK_RECORD",
               let handle = recordPairs.first(where: { $0.0 == 5 })?.1,
               let name = recordPairs.first(where: { $0.0 == 2 })?.1 {
                blockRecordNames[handle.uppercased()] = name
            } else if section == "ENTITIES",
                      let handleText = recordPairs.first(where: { $0.0 == 5 })?.1,
                      let handle = UInt32(handleText, radix: 16) {
                let explicitPaper = recordPairs.first(where: { $0.0 == 67 })?.1 == "1"
                let owner = recordPairs.first(where: { $0.0 == 330 })?.1.uppercased()
                let ownerName = owner.flatMap { blockRecordNames[$0] }
                let paperOwner = ownerName?.hasPrefix("*Paper_Space") == true
                result[handle] = (explicitPaper || paperOwner) ? .paper : .model
            }
        }

        var index = 0
        while index + 1 < lines.count {
            let code = Int(lines[index].trimmingCharacters(in: .whitespaces)) ?? -1
            let value = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0 {
                finishRecord()
                recordType = value
                recordPairs.removeAll(keepingCapacity: true)
                if value == "ENDSEC" { section = "" }
            } else {
                recordPairs.append((code, value))
                if recordType == "SECTION", code == 2 { section = value }
            }
            index += 2
        }
        finishRecord()
        return result
    }

    /// libdxfrw exposes paper-space blocks and viewport entities but not LAYOUT
    /// objects. Read the small amount of ASCII metadata needed to attach the
    /// user-facing layout name and tab order to each *Paper_Space block.
    private static func parseASCIILayouts(filePath: String) -> [String: DXFLayoutInfo] {
        guard let data = FileManager.default.contents(atPath: filePath) else { return [:] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
        guard let text, !text.contains("\0") else { return [:] }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return [:] }

        struct Record {
            var type: String
            var pairs: [(Int, String)]
        }
        var records: [Record] = []
        var current: Record?
        var index = 0
        while index + 1 < lines.count {
            let code = Int(lines[index].trimmingCharacters(in: .whitespaces)) ?? -1
            let value = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0 {
                if let current { records.append(current) }
                current = Record(type: value, pairs: [])
            } else {
                current?.pairs.append((code, value))
            }
            index += 2
        }
        if let current { records.append(current) }

        var blockNameByOwner: [String: String] = [:]
        for record in records where record.type == "BLOCK" {
            guard let owner = record.pairs.first(where: { $0.0 == 330 })?.1,
                  let name = record.pairs.first(where: { $0.0 == 2 })?.1,
                  name.hasPrefix("*Paper_Space") else { continue }
            blockNameByOwner[owner.uppercased()] = name
        }

        var result: [String: DXFLayoutInfo] = [:]
        for record in records where record.type == "LAYOUT" {
            guard let subclassIndex = record.pairs.firstIndex(where: {
                $0.0 == 100 && $0.1 == "AcDbLayout"
            }) else { continue }
            let layoutPairs = record.pairs[record.pairs.index(after: subclassIndex)...]
            guard let name = layoutPairs.first(where: { $0.0 == 1 })?.1,
                  name.caseInsensitiveCompare("Model") != .orderedSame,
                  let owner = layoutPairs.last(where: { $0.0 == 330 })?.1,
                  let blockName = blockNameByOwner[owner.uppercased()] else { continue }
            let order = Int(layoutPairs.first(where: { $0.0 == 71 })?.1 ?? "") ?? Int.max
            result[blockName] = DXFLayoutInfo(name: name, order: order)
        }
        return result
    }

    // MARK: - Entity Conversion




    // MARK: - Leader conversion


    // MARK: - Polyline conversion


    // MARK: - Ellipse conversion (approximate)


    // MARK: - Entity creation

    /// Build the Transform3D for an INSERT (or a nested INSERT inside a block).
    ///
    /// The insertion point, rotation and scale live in the entity's Object Coordinate
    /// System, defined by its extrusion vector (group code 210). Default (0,0,1) means
    /// OCS == WCS; mirrored (0,0,-1) is how AutoCAD encodes a mirrored placement and
    /// negates the OCS X axis. Converting OCS→WCS and composing with the engine's Y-flip
    /// (toVector) gives the two cases below; the mirror is carried as a negative Y scale,
    /// which the 4x4 Transform3D applies correctly through transformPoint.
    ///
    /// IMPORTANT: the bridge delivers insertAngle already in RADIANS (libdxfrw's
    /// DRW_Insert::angle, passed through raw). Do NOT convert from degrees.
    private static func insertTransform(
        from src: DXFRW_EntityData, blockNameToBase: [String: Vector3]
    ) -> Transform3D {
        let angle = src.insertAngle
        let mirrored = src.extrusion.z < 0

        let pos: Vector3
        let rotation: Double
        let scale: Vector3
        if mirrored {
            pos = Vector3(x: -src.basePoint.x, y: -src.basePoint.y, z: -src.basePoint.z)
            rotation = angle + .pi
            scale = Vector3(x: src.xscale, y: -src.yscale, z: src.zscale)
        } else {
            pos = toVector(src.basePoint)
            rotation = -angle
            scale = Vector3(x: src.xscale, y: src.yscale, z: src.zscale)
        }

        var transform = Transform3D.translated(by: pos)
        if rotation != 0 {
            transform = transform.multiplying(by: .rotated(by: rotation))
        }
        transform = transform.multiplying(by: .scaled(by: scale))

        // Account for the referenced block's base point: geometry is stored relative to
        // (local - base), stored as F·base, so pre-translate by -F·base. No-op for the
        // common zero base point.
        if let refName = src.blockName.map({ String(cString: $0) }),
           let fb = blockNameToBase[refName],
           fb.x != 0 || fb.y != 0 || fb.z != 0 {
            transform = transform.multiplying(by: .translated(by: Vector3(
                x: -fb.x, y: -fb.y, z: -fb.z)))
        }
        return transform
    }

    /// Apply a Transform3D to a list of primitives, returning a transformed copy. Used to
    /// inline (flatten) a nested block's geometry into its parent. Arcs and circles are
    /// tessellated to line segments first so the result is correct under any rotation,
    /// scale, or reflection without needing to re-derive arc parameters.
    private static func transformPrimitives(
        _ prims: [CADPrimitive], by t: Transform3D
    ) -> [CADPrimitive] {
        func tp(_ v: Vector3) -> Vector3 { t.transformPoint(v) }
        func corners(_ o: Vector3, _ s: Vector3) -> [Vector3] {
            [o,
             Vector3(x: o.x + s.x, y: o.y, z: o.z),
             Vector3(x: o.x + s.x, y: o.y + s.y, z: o.z),
             Vector3(x: o.x, y: o.y + s.y, z: o.z)]
        }
        _ = abs(t.scale.x)
        let rot = t.rotation
        var out: [CADPrimitive] = []
        for p in prims {
            switch p {
            case let .point(position, color):
                out.append(.point(position: tp(position), color: color))
            case let .line(start, end, color):
                out.append(.line(start: tp(start), end: tp(end), color: color))
            case let .rect(origin, size, color):
                out.append(.polygon(points: corners(origin, size).map(tp), color: color))
            case let .fillRect(origin, size, color):
                out.append(.fillPolygon(points: corners(origin, size).map(tp), color: color))
            case let .polygon(points, color):
                out.append(.polygon(points: points.map(tp), color: color))
            case let .polyline(path, color):
                let nonUniformScale = abs(abs(t.scale.x) - abs(t.scale.y)) > 1e-9
                if path.hasBulges && nonUniformScale {
                    var transformed = path.tessellatedPoints().map(tp)
                    if path.isClosed, transformed.count > 1 { transformed.removeLast() }
                    out.append(.polyline(
                        path: CADPolyline(
                            points: transformed,
                            isClosed: path.isClosed,
                            lineTypeGenerationEnabled: path.lineTypeGenerationEnabled),
                        color: color))
                } else {
                    out.append(.polyline(path: path.transformed(by: t), color: color))
                }
            case let .fillPolygon(points, color):
                out.append(.fillPolygon(points: points.map(tp), color: color))
            case let .fillComplexPolygon(outer, holes, color):
                out.append(.fillComplexPolygon(outer: outer.map(tp),
                                               holes: holes.map { $0.map(tp) }, color: color))
            case let .gradient(outer, holes, name, angle, c1, c2):
                out.append(.gradient(outer: outer.map(tp),
                                     holes: holes.map { $0.map(tp) },
                                     gradientName: name,
                                     angle: angle + rot,
                                     color1: c1, color2: c2))
            case let .circle(center, radius, color):
                let seg = 48
                var pts: [Vector3] = []
                for i in 0..<seg {
                    let a = 2.0 * Double.pi * Double(i) / Double(seg)
                    pts.append(tp(Vector3(x: center.x + cos(a) * radius,
                                          y: center.y + sin(a) * radius, z: center.z)))
                }
                out.append(.polygon(points: pts, color: color))
            case let .arc(center, radius, startAngle, endAngle, color):
                var span = endAngle - startAngle
                if span < 0 { span += 2.0 * Double.pi }
                let seg = max(2, Int((span / (Double.pi / 24.0)).rounded(.up)))
                var prev = tp(Vector3(x: center.x + cos(startAngle) * radius,
                                      y: center.y + sin(startAngle) * radius, z: center.z))
                for i in 1...seg {
                    let a = startAngle + span * Double(i) / Double(seg)
                    let cur = tp(Vector3(x: center.x + cos(a) * radius,
                                         y: center.y + sin(a) * radius, z: center.z))
                    out.append(.line(start: prev, end: cur, color: color))
                    prev = cur
                }
            case let .text(position, text, height, rotation, style, alignH, alignV, mtextWidth, color):
                let origin = tp(position)
                let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
                let localY = Vector3(x: -sin(rotation), y: cos(rotation), z: 0)
                let worldX = tp(position + localX) - origin
                let worldY = tp(position + localY) - origin

                let finalRotation = atan2(worldX.y, worldX.x)
                let heightScale = max(worldY.magnitude, 1e-12)
                let widthScale = max(worldX.magnitude, 1e-12)

                out.append(.text(
                    position: origin,
                    text: text,
                    height: height * heightScale,
                    rotation: finalRotation,
                    style: style,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: mtextWidth.map { $0 * widthScale },
                    color: color
                ))
            case let .spline(controlPoints, knots, degree, weights, color):
                // Transform control points through the block transform
                let newCPs = controlPoints.map(tp)
                out.append(.spline(controlPoints: newCPs, knots: knots,
                                   degree: degree, weights: weights, color: color))
            case let .ellipse(center, majorAxis, minorRatio, color):
                out.append(.ellipse(center: tp(center), majorAxis: tp(majorAxis), minorRatio: minorRatio, color: color))
            case let .hatch(boundary, pattern, scale, angle, color):
                out.append(.hatch(boundary: boundary.map(tp), pattern: pattern, scale: scale, angle: angle + rot, color: color))
            case let .ray(start, direction, color):
                out.append(.ray(start: tp(start), direction: tp(direction), color: color))
            case let .image(insertion, uAxis, vAxis, imageName, clipBoundary, tint):
                out.append(.image(insertion: tp(insertion), uAxis: tp(uAxis), vAxis: tp(vAxis),
                                  imageName: imageName, clipBoundary: clipBoundary, tint: tint))
            }
        }
        return out
    }

    // MARK: - Block sub-entity linetype baking

    /// Resolves the effective linetype name for an entity inside a block
    /// definition, following the DXF inheritance rules:
    /// - Explicit linetype on the entity → that linetype.
    /// - BYBLOCK → inherit from the INSERT at render time → nil (no baking;
    ///   the render path already applies the INSERT's linetype to all block
    ///   primitives, which is the correct behavior for BYBLOCK).
    /// - BYLAYER (or absent) → the SUB-ENTITY's own layer's linetype, except
    ///   layer "0", which inside a block means "inherit from the INSERT" → nil.
    /// Returns nil when the render path's existing INSERT-level handling is
    /// already correct and nothing needs baking.
    private static func resolveBlockSubEntityLinetype(
        entityLinetype: String?,
        layerName: String,
        layerLinetype: String?
    ) -> String? {
        let lt = entityLinetype?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let upper = lt.uppercased()
        if upper == "BYBLOCK" {
            return nil
        }
        if !lt.isEmpty && upper != "BYLAYER" {
            return lt
        }
        // BYLAYER: resolve against the sub-entity's own layer
        if layerName == "0" {
            return nil
        }
        return layerLinetype
    }

    /// Bakes a dash pattern into stroke primitives, replacing each dashed
    /// curve with the individual `.line` segments of its drawn dashes.
    /// `pattern` uses the DXF group-49 convention: > 0 = dash (pen down),
    /// < 0 = gap (pen up), 0 = dot (baked as a very short dash).
    /// Coordinates stay in block-local drawing units, which is the same space
    /// the render path's dash generator works in (dash lengths are world-unit
    /// based, not screen based), so the on-screen result matches what the
    /// renderer would produce had it known the per-sub-entity linetype.
    /// Fill, text, hatch, gradient, point, and ray primitives pass through
    /// unchanged.
    /// Sampling densities match CADPrimitiveGenerator.computePrimitiveSpecs
    /// (circle/ellipse 64, arc 32, spline 48) so curvature fidelity is the
    /// same as a live-rendered dashed entity.
    internal static func bakeDashedLinetype(
        _ primitives: [CADPrimitive],
        pattern: [Double],
        scale: Double
    ) -> [CADPrimitive] {
        var out: [CADPrimitive] = []
        out.reserveCapacity(primitives.count)

        for prim in primitives {
            switch prim {
            case let .line(start, end, color):
                appendDashes(path: [start, end], pattern: pattern, scale: scale, color: color, into: &out)

            case let .rect(origin, size, color):
                let c1 = origin
                let c2 = Vector3(x: origin.x + size.x, y: origin.y, z: origin.z)
                let c3 = Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z)
                let c4 = Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)
                appendDashes(path: [c1, c2, c3, c4, c1], pattern: pattern, scale: scale, color: color, into: &out)

            case let .polygon(points, color):
                guard points.count >= 2 else { out.append(prim); continue }
                var path = points
                if let first = path.first { path.append(first) }
                appendDashes(path: path, pattern: pattern, scale: scale, color: color, into: &out)

            case let .polyline(path, color):
                let points = path.tessellatedPoints()
                guard points.count >= 2 else { out.append(prim); continue }
                appendDashes(path: points, pattern: pattern, scale: scale, color: color, into: &out)

            case let .circle(center, radius, color):
                let segments = 64
                var path: [Vector3] = []
                path.reserveCapacity(segments + 1)
                for i in 0...segments {
                    let angle = Double(i) * 2.0 * .pi / Double(segments)
                    path.append(Vector3(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius,
                        z: center.z))
                }
                appendDashes(path: path, pattern: pattern, scale: scale, color: color, into: &out)

            case let .arc(center, radius, startAngle, endAngle, color):
                let segments = 32
                // Same span normalization as the render path: positive CCW sweep
                var span = endAngle - startAngle
                if span < 0 { span += 2.0 * .pi }
                var path: [Vector3] = []
                path.reserveCapacity(segments + 1)
                for i in 0...segments {
                    let t = Double(i) / Double(segments)
                    let angle = startAngle + span * t
                    path.append(Vector3(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius,
                        z: center.z))
                }
                appendDashes(path: path, pattern: pattern, scale: scale, color: color, into: &out)

            case let .ellipse(center, majorAxis, minorRatio, color):
                let majorLen = majorAxis.magnitude
                let minorLen = majorLen * minorRatio
                guard majorLen > 1e-12, minorLen > 1e-12 else { out.append(prim); continue }
                let rotation = atan2(majorAxis.y, majorAxis.x)
                let cosRot = cos(rotation)
                let sinRot = sin(rotation)
                let segments = 64
                var path: [Vector3] = []
                path.reserveCapacity(segments + 1)
                for i in 0...segments {
                    let t = Double(i) * 2.0 * .pi / Double(segments)
                    let px = majorLen * cos(t)
                    let py = minorLen * sin(t)
                    path.append(Vector3(
                        x: px * cosRot - py * sinRot + center.x,
                        y: px * sinRot + py * cosRot + center.y,
                        z: center.z))
                }
                appendDashes(path: path, pattern: pattern, scale: scale, color: color, into: &out)

            case let .spline(controlPoints, knots, degree, weights, color):
                let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
                let evaluated = NURBSEvaluator.evaluate(
                    degree: degree,
                    knots: knots,
                    controlPoints: controlPoints,
                    weights: w,
                    segments: 48)
                guard evaluated.count >= 2 else { out.append(prim); continue }
                appendDashes(path: evaluated, pattern: pattern, scale: scale, color: color, into: &out)

            default:
                // Fills, text, hatches, gradients, points, rays: linetype
                // doesn't apply (or isn't rendered dashed) — pass through.
                out.append(prim)
            }
        }
        return out
    }

    /// Walks a polyline path with a signed DXF dash pattern (> 0 = dash,
    /// < 0 = gap, 0 = dot; lengths in drawing units, scaled by the entity's
    /// LTSCALE) and appends a `.line` primitive for every pen-down step.
    /// The pattern phase is carried continuously across path vertices, the
    /// same way the render path's makePathSpecs dash walk behaves.
    private static func appendDashes(
        path: [Vector3],
        pattern: [Double],
        scale: Double,
        color: ColorRGBA?,
        into out: inout [CADPrimitive]
    ) {
        guard path.count >= 2 else { return }

        let absTotal = pattern.reduce(0.0) { $0 + abs($1) } * scale
        guard absTotal > 1e-9 else {
            // Degenerate pattern: draw the path solid rather than dropping it
            for i in 0..<(path.count - 1) {
                out.append(.line(start: path[i], end: path[i + 1], color: color))
            }
            return
        }

        // Convert the signed pattern into explicit (length, penDown) steps.
        // Dots (0) become very short dashes proportional to the pattern length.
        let dotLength = max(absTotal * 0.01, 1e-6)
        var steps: [(len: Double, draw: Bool)] = []
        steps.reserveCapacity(pattern.count)
        for v in pattern {
            if v > 0 {
                steps.append((v * scale, true))
            } else if v < 0 {
                steps.append((-v * scale, false))
            } else {
                steps.append((dotLength, true))
            }
        }

        var stepIndex = 0
        var remaining = steps[0].len
        var drawing = steps[0].draw

        for i in 0..<(path.count - 1) {
            var a = path[i]
            let b = path[i + 1]

            while true {
                let d = b - a
                let len = d.magnitude
                if len <= 1e-12 { break }

                if remaining <= 1e-12 {
                    stepIndex = (stepIndex + 1) % steps.count
                    remaining = steps[stepIndex].len
                    drawing = steps[stepIndex].draw
                    continue
                }

                let step = min(remaining, len)
                let next = a + d * (step / len)
                if drawing {
                    out.append(.line(start: a, end: next, color: color))
                }
                a = next
                remaining -= step
            }
        }
    }

    @MainActor
    private static func makeEntity(
        from src: DXFRW_EntityData,
        primitives: [CADPrimitive],
        layerID: UUID,
        blockNameToID: [String: UUID],
        blockNameToBase: [String: Vector3],
        drawOrder: Int,
        globalLinetypeScale: Double,
        textStyleFonts: [String: String] = [:]
    ) -> CADEntity {

        var blockID: UUID? = nil
        var localGeom: [CADPrimitive]? = nil

        if src.type == DXFRW_ET_INSERT {
            // INSERT references a block
            if let bn = src.blockName {
                let name = String(cString: bn)
                blockID = blockNameToID[name]

                let transform = insertTransform(from: src, blockNameToBase: blockNameToBase)

                // For INSERT entities, we don't set local geometry — the block definition provides it
                var entity = CADEntity(
                    handle: UUID(),
                    layerID: layerID,
                    blockID: blockID,
                    localGeometry: nil,
                    transform: transform
                )
                entity.drawOrder = drawOrder
                if src.color24 >= 0 || (src.color > 0 && src.color < 256) {
                    let color = DXFColorTable.aciToRGBA(src.color, color24: src.color24)
                    let hexStr = String(format: "#%02X%02X%02X", color.r, color.g, color.b)
                    entity.xdata["dxf.color"] = .string(hexStr)
                }
                return entity
            }
        }

        // DIMENSION entities reference an anonymous geometry block (e.g. *D93) that
        // AutoCAD has already populated with the extension lines, dimension line,
        // arrowhead INSERTs, and the MTEXT label — all in absolute model coordinates.
        // Render that block directly (identity transform); the nested arrowhead INSERTs
        // are inlined when block geometry is flattened (see importDXF). Without this a
        // dimension would only draw a single def→text line and show no text or arrows.
        if src.type == DXFRW_ET_DIMENSION, let bn = src.blockName {
            print("DIM blockName =", src.blockName.map { String(cString: $0) } ?? "nil")
            let name = String(cString: bn)
            if let bid = blockNameToID[name] {
                var entity = CADEntity(
                    handle: UUID(),
                    layerID: layerID,
                    blockID: bid,
                    localGeometry: nil,
                    transform: .identity
                )
                entity.drawOrder = drawOrder
                if src.color24 >= 0 || (src.color > 0 && src.color < 256) {
                    let color = DXFColorTable.aciToRGBA(src.color, color24: src.color24)
                    let hexStr = String(format: "#%02X%02X%02X", color.r, color.g, color.b)
                    entity.xdata["dxf.color"] = .string(hexStr)
                }
                return entity
            }
        }

        // Non-INSERT entities use local geometry
        if !primitives.isEmpty {
            localGeom = primitives
        }

        var transform = Transform3D.identity
        if src.type == DXFRW_ET_TEXT || src.type == DXFRW_ET_MTEXT {
            let pos: Vector3
            if src.type == DXFRW_ET_TEXT && (src.alignH != 0 || src.alignV != 0) {
                pos = toVector(src.secPoint)
            } else {
                pos = toVector(src.basePoint)
            }
            let angle = -src.textAngle * .pi / 180.0
            transform = Transform3D.translated(by: pos)
            if angle != 0 {
                transform = transform.multiplying(by: .rotated(by: angle))
            }

            // Adjust the local primitive so that its position is .zero and rotation is 0.0,
            // mapping coordinate transformations entirely to the entity transform.
            if let geom = localGeom {
                localGeom = geom.map { prim in
                    if case .text(_, let text, let height, _, let style, let alignH, let alignV, let mtextWidth, let color) = prim {
                        return .text(
                            position: .zero,
                            text: text,
                            height: height,
                            rotation: 0.0,
                            style: style,
                            alignH: alignH,
                            alignV: alignV,
                            mtextWidth: mtextWidth,
                            color: color
                        )
                    }
                    return prim
                }
            }
        }

        var entity = CADEntity(
            handle: UUID(),
            layerID: layerID,
            blockID: blockID,
            localGeometry: localGeom,
            transform: transform
        )
        entity.drawOrder = drawOrder

        if let ltPtr = src.lineTypeName {
            entity.xdata["dxf.lineType"] = .string(String(cString: ltPtr))
        } else {
            entity.xdata["dxf.lineType"] = .string("BYLAYER")
        }
        // Only store explicit line weights. ByLayer (-1) and ByBlock (-2) should
        // fall through to the layer's actual weight in computeSpecs.
        if src.lineWeight >= 0 {
            entity.xdata["dxf.lineWeight"] = .double(DXFColorTable.lineWeightToMM(src.lineWeight))
        }
        
        let globalScale = globalLinetypeScale > 0 ? globalLinetypeScale : 1.0
        let ltScale = (src.lineTypeScale > 0 ? src.lineTypeScale : 1.0) * globalScale
        if ltScale != 1.0 {
            entity.xdata["dxf.lineTypeScale"] = .double(ltScale)
        }

        if (src.type == DXFRW_ET_LWPOLYLINE || src.type == DXFRW_ET_POLYLINE),
           let verts = src.vertices, src.vertexCount > 0 {
            var maxW = 0.0
            for idx in 0..<Int(src.vertexCount) {
                let w = verts[idx].startWidth
                if w > maxW {
                    maxW = w
                }
            }
            if maxW > 0.0 {
                entity.xdata["dxf.polylineWidth"] = .double(maxW)
            }
        }

        // Store text as xdata if present
        if src.type == DXFRW_ET_TEXT || src.type == DXFRW_ET_MTEXT {
            if let textPtr = src.textValue {
                let rawText = String(cString: textPtr)
                let cleaned = DXFEntityConverter.cleanMTextFormatting(rawText)
                entity.xdata["dxf.text"] = .string(cleaned)

                // Preserve raw MTEXT string for perfect round-trip when text is not edited.
                if src.type == DXFRW_ET_MTEXT {
                    entity.xdata["dxf.mtextRaw"] = .string(rawText)
                }

                // Parse MTEXT formatting codes into structured FormattedText.
                let defaultFont: String
                if let stylePtr = src.textStyle {
                    let styleName = String(cString: stylePtr)
                    defaultFont = textStyleFonts[styleName] ?? "simplex.shx"
                } else {
                    defaultFont = "simplex.shx"
                }
                let defaultHeight = src.textHeight > 0 ? src.textHeight : 2.5

                let formatted = MTEXTFormatter.parse(
                    rawText,
                    defaultFont: defaultFont,
                    defaultHeight: defaultHeight
                )

                // Encode FormattedText as JSON and store in xdata.
                if let jsonData = try? JSONEncoder().encode(formatted),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    entity.xdata["dxf.formattedText"] = .string(jsonStr)
                }
            }
            if src.textHeight > 0 {
                entity.xdata["dxf.textHeight"] = .double(src.textHeight)
            }
            if let stylePtr = src.textStyle {
                entity.xdata["dxf.textStyle"] = .string(String(cString: stylePtr))
            }
            entity.xdata["dxf.alignH"] = .int(Int(src.alignH))
            entity.xdata["dxf.alignV"] = .int(Int(src.alignV))
            if src.type == DXFRW_ET_MTEXT && src.textWidthScale > 0 {
                entity.xdata["dxf.mtextWidth"] = .double(src.textWidthScale)
            }
        }

        if src.type == DXFRW_ET_HATCH {
            let patternName = src.hatchPatternName.map { String(cString: $0) } ?? (src.hatchSolid == 1 ? "SOLID" : "")
            let scale = src.hatchScale > 0.0 ? src.hatchScale : 1.0
            let angle = src.hatchAngle

            entity.xdata["dxf.hatchPatternName"] = .string(patternName.isEmpty ? "SOLID" : patternName)
            entity.xdata["dxf.hatchPatternType"] = .string(DXFHatchGenerator.patternKindName(for: patternName))
            entity.xdata["dxf.hatchScale"] = .double(scale)
            entity.xdata["dxf.hatchAngle"] = .double(angle)
            entity.xdata["dxf.hatchSpacing"] = .double(DXFHatchGenerator.effectiveSpacing(patternName: patternName, scale: scale))
            entity.xdata["dxf.hatchAssociative"] = .bool(false)
        }

        if src.color24 >= 0 || (src.color > 0 && src.color < 256) {
            let color = DXFColorTable.aciToRGBA(src.color, color24: src.color24)
            let hexStr = String(format: "#%02X%02X%02X", color.r, color.g, color.b)
            entity.xdata["dxf.color"] = .string(hexStr)
        }

        return entity
    }


    // MARK: - Helpers

    /// Converts a libdxfrw coordinate (Y-up) to the engine's Y-flipped
    /// coordinate space. All DXF geometry passes through this transform.
    internal static func toVector(_ c: DXFRW_Coord) -> Vector3 {
        Vector3(x: c.x, y: -c.y, z: c.z)
    }
}

// =========================================================================
// MARK: - DXFImportError
// =========================================================================

public enum DXFImportError: Error {
    case parseFailed(String)
    case fileNotFound(String)
}

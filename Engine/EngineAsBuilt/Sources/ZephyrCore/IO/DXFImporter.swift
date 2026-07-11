import Foundation

// =========================================================================
// MARK: - DXFImporter
// Pure Swift DXF import.
// =========================================================================

public enum DXFDrawingViewKind: Sendable, Equatable { case model, sheet }

public struct DXFDrawingView: Sendable {
    public let name: String; public let kind: DXFDrawingViewKind; public let entities: [CADEntity]
    public init(name: String, kind: DXFDrawingViewKind, entities: [CADEntity]) {
        self.name = name; self.kind = kind; self.entities = entities
    }
}

public struct DXFImportResult: Sendable {
    public let layers: [Layer]; public let blocks: [CADBlock]; public let entities: [CADEntity]
    public let textStyleFonts: [String: String]; public let linetypePatterns: [String: [Double]]
    public let dimensionStyles: [String: CADDimensionStyle]
    public let views: [DXFDrawingView]
    public init(layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
                textStyleFonts: [String: String], linetypePatterns: [String: [Double]],
                dimensionStyles: [String: CADDimensionStyle], views: [DXFDrawingView]) {
        self.layers = layers; self.blocks = blocks; self.entities = entities
        self.textStyleFonts = textStyleFonts; self.linetypePatterns = linetypePatterns
        self.dimensionStyles = dimensionStyles
        self.views = views
    }
}

public enum DXFImporter {

    private struct StyledPrimitive {
        var primitive: CADPrimitive
        var style: CADPrimitiveStyle?
    }

    private struct SheetViewport {
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

        init(_ source: DXFViewportEntity) {
            paperCenterX = source.basePoint.x
            paperCenterY = source.basePoint.y
            paperWidth = source.psWidth
            paperHeight = source.psHeight
            status = source.vpStatus
            id = source.vpID
            viewCenterX = source.centerPX
            viewCenterY = source.centerPY
            viewTargetX = source.viewTarget.x
            viewTargetY = source.viewTarget.y
            viewHeight = source.viewHeight
            twistAngle = source.twistAngle * .pi / 180.0
        }

        var isModelViewport: Bool {
            let isLayoutViewport = id > 0 ? id == 1 : status == 1
            return status > 0 && !isLayoutViewport
                && paperWidth > 1e-9 && paperHeight > 1e-9 && viewHeight > 1e-9
        }

        var modelToPaperTransform: Transform3D {
            let scale = paperHeight / viewHeight
            let centerX = viewTargetX + viewCenterX
            let centerY = viewTargetY + viewCenterY
            return Transform3D
                .translated(by: Vector3(x: paperCenterX, y: -paperCenterY, z: 0))
                .multiplying(by: .rotated(by: twistAngle))
                .multiplying(by: .scaled(by: Vector3(x: scale, y: scale, z: 1)))
                .multiplying(by: .translated(by: Vector3(x: -centerX, y: centerY, z: 0)))
        }

        func intersects(_ entity: CADEntity) -> Bool {
            guard let box = entity.worldBoundingBox else { return false }
            let scale = paperHeight / viewHeight
            let modelWidth = paperWidth / scale
            let centerX = viewTargetX + viewCenterX
            let centerY = -(viewTargetY + viewCenterY)
            let minX = centerX - modelWidth / 2.0
            let maxX = centerX + modelWidth / 2.0
            let minY = centerY - viewHeight / 2.0
            let maxY = centerY + viewHeight / 2.0
            return box.max.x >= minX && box.min.x <= maxX
                && box.max.y >= minY && box.min.y <= maxY
        }
    }

    public static func importDXF(filePath: String) throws -> (layers: [Layer], blocks: [CADBlock], entities: [CADEntity], textStyleFonts: [String: String], linetypePatterns: [String: [Double]], dimensionStyles: [String: CADDimensionStyle]) {
        let result = try importDXFViews(filePath: filePath)
        return (result.layers, result.blocks, result.entities, result.textStyleFonts, result.linetypePatterns, result.dimensionStyles)
    }

    public static func importDXFViews(filePath: String) throws -> DXFImportResult {
        let reader = DXFReader()
        _ = try reader.readFile(at: filePath)
        return convertDXFToCAD(reader: reader)
    }

    private static func convertDXFToCAD(reader: DXFReader) -> DXFImportResult {
        let entityCount = reader.entities.count
        let blockCount = reader.blocks.count
        let totalBlockEntities = reader.blocks.reduce(0) { $0 + $1.entities.count }
        print("[DXFImporter] Converting: \(entityCount) entities, \(blockCount) blocks (\(totalBlockEntities) sub-entities), \(reader.layers.count) layers")

        // Guard against pathological data
        guard entityCount < 10_000_000 else {
            print("[DXFImporter] ERROR: \(entityCount) entities exceeds safety limit")
            return DXFImportResult(layers: [], blocks: [], entities: [], textStyleFonts: [:], linetypePatterns: [:], dimensionStyles: [:], views: [])
        }

        let globalLineTypeScale = reader.header.ltScale > 0 ? reader.header.ltScale : 1.0
        var layers: [Layer] = []
        var layerNameToID: [String: UUID] = [:]

        for table in reader.layers {
            let handle = UUID()
            let name = table.name.isEmpty ? "0" : table.name
            layerNameToID[name] = handle
            let color = DXFColorTable.aciToRGBA(table.color, color24: table.color24)
            let layer = Layer(handle: handle,
                              name: name,
                              isVisible: (table.color >= 0),
                              lineWeight: DXFColorTable.lineWeightToMM(Double(table.lWeight.dxfInt)),
                              color: color,
                              lineType: table.lineType.isEmpty ? "CONTINUOUS" : table.lineType,
                              isPlottable: table.plotFlag,
                              plotStyleHandle: table.plotStyleHandle == 0
                                  ? nil
                                  : String(table.plotStyleHandle, radix: 16).uppercased(),
                              opacity: DXFColorTable.transparencyToOpacity(table.transparency))
            layers.append(layer)
        }
        if layerNameToID["0"] == nil {
            let handle = UUID()
            layerNameToID["0"] = handle
            let layer = Layer(handle: handle, name: "0", isVisible: true, lineWeight: 0.25, color: .white)
            layers.append(layer)
        }

        func layerID(for entity: DXFEntity) -> UUID {
            let name = entity.layer.isEmpty ? "0" : entity.layer
            return layerNameToID[name] ?? layerNameToID["0"]!
        }

        var sourceEntityByHandle: [UInt32: DXFEntity] = [:]
        for entity in reader.entities where entity.handle != 0 {
            sourceEntityByHandle[entity.handle] = entity
        }
        for block in reader.blocks {
            for entity in block.entities where entity.handle != 0 {
                sourceEntityByHandle[entity.handle] = entity
            }
        }
        resolveAssociativeHatchBoundaries(
            in: reader.entities,
            sourceEntityByHandle: sourceEntityByHandle)
        for block in reader.blocks {
            resolveAssociativeHatchBoundaries(
                in: block.entities,
                sourceEntityByHandle: sourceEntityByHandle)
        }


        var blockByName: [String: DXFBlockEntity] = [:]
        for block in reader.blocks where !block.name.isEmpty { blockByName[block.name] = block }
        var blockNameToID: [String: UUID] = [:]
        var blockBaseByName: [String: Vector3] = [:]
        for block in reader.blocks where !block.name.isEmpty {
            blockNameToID[block.name] = UUID()
            blockBaseByName[block.name] = Self.cadPoint(block.basePoint)
        }

        var blockNameByHandle: [UInt32: String] = [:]
        for record in reader.blockRecords where record.handle != 0 && !record.name.isEmpty {
            blockNameByHandle[record.handle] = record.name
        }
        var textStyleNameByHandle: [UInt32: String] = [:]
        for textStyle in reader.textstyles where textStyle.handle != 0 && !textStyle.name.isEmpty {
            textStyleNameByHandle[textStyle.handle] = textStyle.name
        }
        let dimensionStyles = Self.convertDimensionStyles(
            reader.dimstyles,
            blockNameByHandle: blockNameByHandle,
            textStyleNameByHandle: textStyleNameByHandle)

        var blockGeometryCache: [String: [StyledPrimitive]] = [:]

        func convertBlockGeometry(named name: String, visited: Set<String> = []) -> [StyledPrimitive] {
            if let cached = blockGeometryCache[name] { return cached }
            guard let block = blockByName[name], !visited.contains(name) else { return [] }

            var nextVisited = visited
            nextVisited.insert(name)
            var geometry: [StyledPrimitive] = []

            for entity in block.entities {
                guard Self.shouldRenderAttributeEntity(entity, insideBlockDefinition: true) else { continue }

                if let insert = entity as? DXFInsertEntity, blockByName[insert.name] != nil {
                    let child = convertBlockGeometry(named: insert.name, visited: nextVisited)
                    guard !child.isEmpty else { continue }
                    let columns = max(1, insert.colCount)
                    let rows = max(1, insert.rowCount)
                    let base = blockBaseByName[insert.name] ?? .zero
                    for row in 0..<rows {
                        for column in 0..<columns {
                            let transform = Self.insertTransform(insert, blockBase: base, column: column, row: row)
                            geometry.append(contentsOf: Self.transformStyledPrimitives(
                                child,
                                by: transform,
                                nestedInsertStyle: Self.primitiveStyle(from: insert)))
                        }
                    }
                    for attribute in insert.attributes
                        where Self.shouldRenderAttributeEntity(attribute) {
                        let values = DXFEntityConverter.convertEntityToPrimitives(
                            attribute,
                            bylayerColor: nil).map {
                                StyledPrimitive(
                                    primitive: $0,
                                    style: Self.primitiveStyle(from: attribute))
                            }
                        geometry.append(contentsOf: Self.transformStyledPrimitives(
                            values,
                            by: .identity,
                            nestedInsertStyle: Self.primitiveStyle(from: insert)))
                    }
                    continue
                }

                if let dimension = entity as? DXFDimensionEntity,
                   blockByName[dimension.name] != nil {
                    geometry.append(contentsOf: convertBlockGeometry(named: dimension.name, visited: nextVisited))
                    continue
                }

                let style = Self.primitiveStyle(from: entity)
                let primitives = DXFEntityConverter.convertEntityToPrimitives(entity, bylayerColor: nil)
                geometry.append(contentsOf: primitives.map {
                    StyledPrimitive(primitive: $0, style: style)
                })
            }

            blockGeometryCache[name] = geometry
            return geometry
        }

        var blocks: [CADBlock] = []
        var blockByID: [UUID: CADBlock] = [:]
        for block in reader.blocks {
            guard let handle = blockNameToID[block.name] else { continue }
            let styledGeometry = convertBlockGeometry(named: block.name)
            let cadBlock = CADBlock(
                handle: handle,
                name: block.name,
                geometry: styledGeometry.map(\.primitive),
                primitiveStyles: Dictionary(uniqueKeysWithValues:
                    styledGeometry.enumerated().compactMap { index, item in
                        guard let style = item.style else { return nil }
                        return (index, style)
                    }),
                isInternalTableDisplayBlock: block.name.hasPrefix("*T"))
            blocks.append(cadBlock)
            blockByID[handle] = cadBlock
        }

        func convertEntities(_ sourceEntities: [DXFEntity]) -> [CADEntity] {
            var converted: [CADEntity] = []
            converted.reserveCapacity(sourceEntities.count)

            for (drawOrder, entity) in sourceEntities.enumerated() {
                guard Self.shouldRenderAttributeEntity(entity) else { continue }

                if let insert = entity as? DXFInsertEntity,
                   let blockID = blockNameToID[insert.name],
                   let block = blockByID[blockID] {
                    let columns = max(1, insert.colCount)
                    let rows = max(1, insert.rowCount)
                    let blockBase = blockBaseByName[insert.name] ?? .zero
                    for row in 0..<rows {
                        for column in 0..<columns {
                            var cadEnt = CADEntity(
                                handle: UUID(),
                                layerID: layerID(for: entity),
                                blockID: blockID,
                                localGeometry: nil,
                                transform: Self.insertTransform(
                                    insert,
                                    blockBase: blockBase,
                                    column: column,
                                    row: row),
                                xdata: Self.entityStyleXData(
                                    from: entity,
                                    globalLineTypeScale: globalLineTypeScale),
                                drawOrder: drawOrder,
                                localBoundingBox: block.localBoundingBox)
                            cadEnt.drawOrder = drawOrder
                            converted.append(cadEnt)
                        }
                    }

                    for attribute in insert.attributes
                        where Self.shouldRenderAttributeEntity(attribute) {
                        let primitives = DXFEntityConverter.convertEntityToPrimitives(
                            attribute,
                            bylayerColor: nil)
                        guard !primitives.isEmpty else { continue }
                        let attributeLayerID = attribute.layer.isEmpty
                            || attribute.layer == "0"
                            ? layerID(for: insert)
                            : layerID(for: attribute)
                        var attributeEntity = CADEntity(
                            handle: UUID(),
                            layerID: attributeLayerID,
                            blockID: nil,
                            localGeometry: primitives,
                            transform: .identity,
                            xdata: Self.attributeStyleXData(
                                from: attribute,
                                insert: insert,
                                globalLineTypeScale: globalLineTypeScale),
                            drawOrder: drawOrder)
                        attributeEntity.drawOrder = drawOrder
                        converted.append(attributeEntity)
                    }
                    continue
                }

                if let dimension = entity as? DXFDimensionEntity {
                    var metadata = Self.dimensionMetadata(from: dimension)
                    if let blockID = blockNameToID[dimension.name],
                       let block = blockByID[blockID] {
                        metadata = Self.preservingCachedDimensionText(
                            metadata,
                            block: block,
                            dimensionStyles: dimensionStyles)
                        var cadEnt = CADEntity(
                            handle: UUID(),
                            layerID: layerID(for: entity),
                            blockID: blockID,
                            localGeometry: nil,
                            transform: .identity,
                            xdata: Self.entityStyleXData(
                                from: entity,
                                globalLineTypeScale: globalLineTypeScale),
                            drawOrder: drawOrder,
                            localBoundingBox: block.localBoundingBox)
                        cadEnt.dimensionMetadata = metadata.map(CADDimensionMetadataBox.init)
                        cadEnt.drawOrder = drawOrder
                        converted.append(cadEnt)
                        continue
                    }

                    let primitives = DXFEntityConverter.convertEntityToPrimitives(
                        entity,
                        bylayerColor: nil)
                    var cadEnt = CADEntity(
                        handle: UUID(),
                        layerID: layerID(for: entity),
                        blockID: nil,
                        localGeometry: primitives,
                        transform: .identity,
                        xdata: Self.entityStyleXData(
                            from: entity,
                            globalLineTypeScale: globalLineTypeScale))
                    cadEnt.dimensionMetadata = metadata.map(CADDimensionMetadataBox.init)
                    cadEnt.drawOrder = drawOrder
                    converted.append(cadEnt)
                    continue
                }

                let primitives = DXFEntityConverter.convertEntityToPrimitives(
                    entity,
                    bylayerColor: nil,
                    showAttributeDefinitionTagWhenEmpty: entity.eType == .aTTDEF)
                guard !primitives.isEmpty || entity.eType == .pOINT else { continue }
                var cadEnt = CADEntity(
                    handle: UUID(),
                    layerID: layerID(for: entity),
                    blockID: nil,
                    localGeometry: primitives,
                    transform: .identity,
                    xdata: Self.entityStyleXData(
                        from: entity,
                        globalLineTypeScale: globalLineTypeScale))
                cadEnt.drawOrder = drawOrder
                converted.append(cadEnt)
            }

            return converted
        }

        func entitiesOwned(by ownerHandle: UInt32) -> [DXFEntity] {
            guard ownerHandle != 0 else { return [] }
            var acceptedOwners: Set<UInt32> = [ownerHandle]
            var includedIndices: Set<Int> = []
            var addedEntity = true

            while addedEntity {
                addedEntity = false
                for (index, entity) in reader.entities.enumerated()
                    where !includedIndices.contains(index)
                        && acceptedOwners.contains(entity.parentHandle) {
                    includedIndices.insert(index)
                    if entity.handle != 0 { acceptedOwners.insert(entity.handle) }
                    addedEntity = true
                }
            }

            return reader.entities.enumerated().compactMap { index, entity in
                includedIndices.contains(index) ? entity : nil
            }
        }

        func sourceEntities(for layout: DXFLayoutEntry) -> [DXFEntity] {
            let owned = entitiesOwned(by: layout.blockRecordHandle)
            if !owned.isEmpty { return owned }
            guard let blockName = blockNameByHandle[layout.blockRecordHandle],
                  let block = blockByName[blockName] else { return [] }
            return block.entities
        }

        var textStyleFonts: [String: String] = [:]
        for style in reader.textstyles where !style.name.isEmpty {
            if !style.font.isEmpty { textStyleFonts[style.name] = style.font }
        }

        var linetypePatterns: [String: [Double]] = [:]
        for ltype in reader.ltypes {
            let key = ltype.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if !key.isEmpty {
                linetypePatterns[key] = ltype.path
            }
        }

        let modelEntities: [CADEntity]
        let views: [DXFDrawingView]

        if reader.layouts.isEmpty {
            modelEntities = convertEntities(reader.entities)
            views = [DXFDrawingView(
                name: "Model",
                kind: .model,
                entities: modelEntities)]
        } else {
            let orderedLayouts = reader.layouts.sorted { lhs, rhs in
                if lhs.tabOrder != rhs.tabOrder { return lhs.tabOrder < rhs.tabOrder }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            let modelLayout = orderedLayouts.first {
                $0.name.caseInsensitiveCompare("Model") == .orderedSame
            }

            let modelSource: [DXFEntity]
            if let modelLayout {
                let layoutSource = sourceEntities(for: modelLayout)
                modelSource = layoutSource.isEmpty
                    ? reader.entities.filter { $0.space == 0 }
                    : layoutSource
            } else {
                modelSource = reader.entities.filter { $0.space == 0 }
            }
            modelEntities = convertEntities(modelSource)

            var importedViews: [DXFDrawingView] = [DXFDrawingView(
                name: modelLayout?.name ?? "Model",
                kind: .model,
                entities: modelEntities)]

            for layout in orderedLayouts where
                layout.name.caseInsensitiveCompare("Model") != .orderedSame {
                let paperSource = sourceEntities(for: layout)
                var paperEntities = convertEntities(paperSource)
                let paperDrawOrderOffset = modelEntities.count + 1
                for index in paperEntities.indices where paperEntities[index].drawOrder != Int.max {
                    paperEntities[index].drawOrder += paperDrawOrderOffset
                }

                var projectedEntities: [CADEntity] = []
                let viewports = paperSource.compactMap { $0 as? DXFViewportEntity }
                    .map(SheetViewport.init)
                    .filter(\.isModelViewport)

                for viewport in viewports {
                    let projection = viewport.modelToPaperTransform
                    for modelEntity in modelEntities where viewport.intersects(modelEntity) {
                        let projectedDrawOrder = modelEntity.drawOrder == Int.max
                            ? Int.max
                            : modelEntity.drawOrder + 1
                        projectedEntities.append(CADEntity(
                            layerID: modelEntity.layerID,
                            blockID: modelEntity.blockID,
                            localGeometry: modelEntity.localGeometry,
                            dimensionMetadata: modelEntity.dimensionMetadata,
                            transform: projection.multiplying(by: modelEntity.transform),
                            xdata: modelEntity.xdata,
                            drawOrder: projectedDrawOrder,
                            localBoundingBox: modelEntity.localBoundingBox,
                            anchorPoints: modelEntity.anchorPoints))
                    }
                }

                importedViews.append(DXFDrawingView(
                    name: layout.name,
                    kind: .sheet,
                    entities: projectedEntities + paperEntities))
            }
            views = importedViews
        }

        return DXFImportResult(
            layers: layers,
            blocks: blocks,
            entities: modelEntities,
            textStyleFonts: textStyleFonts,
            linetypePatterns: linetypePatterns,
            dimensionStyles: dimensionStyles,
            views: views)
    }

    private static func entityStyleXData(
        from entity: DXFEntity,
        globalLineTypeScale: Double
    ) -> [String: XDataValue] {
        var xdata: [String: XDataValue] = [:]

        if entity.color24 >= 0 || (entity.color > 0 && entity.color < 256) {
            let color = DXFColorTable.aciToRGBA(entity.color, color24: entity.color24)
            xdata["dxf.color"] = .string(String(
                format: "#%02X%02X%02X", color.r, color.g, color.b))
        }
        if entity.transparency >= 0 {
            xdata["dxf.opacity"] = .double(
                DXFColorTable.transparencyToOpacity(entity.transparency))
        }

        let lineType = entity.lineType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lineType.isEmpty {
            xdata["dxf.lineType"] = .string(lineType)
        }

        if entity.lWeight.dxfInt >= 0 {
            xdata["dxf.lineWeight"] = .double(
                DXFColorTable.lineWeightToMM(Double(entity.lWeight.dxfInt)))
        }

        let entityLineTypeScale = entity.ltypeScale > 0 ? entity.ltypeScale : 1.0
        xdata["dxf.lineTypeScale"] = .double(entityLineTypeScale * globalLineTypeScale)

        if let width = Self.polylineDisplayWidth(from: entity) {
            xdata["dxf.polylineWidth"] = .double(width)
        }

        if entity.plotStyleHandle != 0 {
            xdata["dxf.plotStyleHandle"] = .string(
                String(entity.plotStyleHandle, radix: 16).uppercased())
        }
        if !entity.colorName.isEmpty {
            xdata["dxf.colorName"] = .string(entity.colorName)
        }

        if let text = entity as? DXFTextEntity,
           text.eType == .aTTRIB || text.eType == .aTTDEF {
            xdata["dxf.attributeType"] = .string(
                text.eType == .aTTRIB ? "ATTRIB" : "ATTDEF")
            xdata["dxf.attributeFlags"] = .int(text.attributeFlags)
            if !text.attributeTag.isEmpty {
                xdata["dxf.attributeTag"] = .string(text.attributeTag)
            }
        }

        if let mtext = entity as? DXFMTextEntity,
           (mtext.backgroundFillFlags & 1) != 0 {
            xdata["dxf.mtextBackgroundScale"] = .double(max(1.0, mtext.backgroundScale))
            let usesViewportColor = (mtext.backgroundFillFlags & 2) != 0
            xdata["dxf.mtextBackgroundUsesViewportColor"] = .int(usesViewportColor ? 1 : 0)
            if !usesViewportColor {
                let background = DXFColorTable.aciToRGBA(
                    Int32(mtext.backgroundColor),
                    color24: Int32(mtext.backgroundColor24))
                xdata["dxf.mtextBackgroundColor"] = .string(String(
                    format: "#%02X%02X%02X", background.r, background.g, background.b))
                if mtext.backgroundTransparency >= 0 {
                    xdata["dxf.mtextBackgroundOpacity"] = .double(
                        DXFColorTable.transparencyToOpacity(Int32(mtext.backgroundTransparency)))
                }
            }
        }
        for (key, value) in DXFEntityConverter.hatchXData(from: entity) {
            xdata[key] = value
        }
        return xdata
    }

    private static func shouldRenderAttributeEntity(
        _ entity: DXFEntity,
        insideBlockDefinition: Bool = false
    ) -> Bool {
        guard let text = entity as? DXFTextEntity else { return true }

        let invisibleFlag = 1
        let constantFlag = 2
        switch text.eType {
        case .aTTRIB:
            return text.visible
                && (text.attributeFlags & invisibleFlag) == 0
                && !text.text.isEmpty
        case .aTTDEF:
            guard text.visible, (text.attributeFlags & invisibleFlag) == 0 else {
                return false
            }
            if insideBlockDefinition,
               (text.attributeFlags & constantFlag) == 0 {
                return false
            }
            return !text.text.isEmpty || !text.attributeTag.isEmpty
        default:
            return true
        }
    }

    private static func attributeStyleXData(
        from attribute: DXFTextEntity,
        insert: DXFInsertEntity,
        globalLineTypeScale: Double
    ) -> [String: XDataValue] {
        var xdata = entityStyleXData(
            from: attribute,
            globalLineTypeScale: globalLineTypeScale)

        if attribute.color == 0 {
            if insert.color24 >= 0 || (insert.color > 0 && insert.color < 256) {
                let color = DXFColorTable.aciToRGBA(
                    insert.color,
                    color24: insert.color24)
                xdata["dxf.color"] = .string(String(
                    format: "#%02X%02X%02X", color.r, color.g, color.b))
            }
        }

        if attribute.lineType.uppercased() == "BYBLOCK", !insert.lineType.isEmpty {
            xdata["dxf.lineType"] = .string(insert.lineType)
        }
        if attribute.lWeight == .byBlock, insert.lWeight.dxfInt >= 0 {
            xdata["dxf.lineWeight"] = .double(
                DXFColorTable.lineWeightToMM(Double(insert.lWeight.dxfInt)))
        }

        return xdata
    }

    private static func primitiveStyle(from entity: DXFEntity) -> CADPrimitiveStyle {
        let explicitColor: ColorRGBA?
        if entity.color24 >= 0 || (entity.color > 0 && entity.color < 256) {
            explicitColor = DXFColorTable.aciToRGBA(entity.color, color24: entity.color24)
        } else {
            explicitColor = nil
        }

        let rawLineType = entity.lineType.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineType = rawLineType.isEmpty ? "BYLAYER" : rawLineType

        let explicitLineWeight: Double?
        if entity.lWeight.dxfInt >= 0 {
            explicitLineWeight = DXFColorTable.lineWeightToMM(Double(entity.lWeight.dxfInt))
        } else {
            explicitLineWeight = nil
        }

        let geomWidth = Self.polylineDisplayWidth(from: entity)

        var textBackgroundScale: Double?
        var textBackgroundColor: ColorRGBA?
        var textBackgroundUsesViewportColor = false
        if let mtext = entity as? DXFMTextEntity,
           (mtext.backgroundFillFlags & 1) != 0 {
            textBackgroundScale = max(1.0, mtext.backgroundScale)
            textBackgroundUsesViewportColor = (mtext.backgroundFillFlags & 2) != 0
            if !textBackgroundUsesViewportColor {
                var background = DXFColorTable.aciToRGBA(
                    Int32(mtext.backgroundColor),
                    color24: Int32(mtext.backgroundColor24))
                if mtext.backgroundTransparency >= 0 {
                    let opacity = DXFColorTable.transparencyToOpacity(
                        Int32(mtext.backgroundTransparency))
                    background = ColorRGBA(
                        r: background.r,
                        g: background.g,
                        b: background.b,
                        a: UInt8(min(255.0, Double(background.a) * opacity)))
                }
                textBackgroundColor = background
            }
        }

        return CADPrimitiveStyle(
            layerName: entity.layer.isEmpty ? "0" : entity.layer,
            color: explicitColor,
            isColorByBlock: entity.color == 0,
            lineType: lineType,
            isLineTypeByBlock: lineType.uppercased() == "BYBLOCK",
            lineWeight: explicitLineWeight,
            isLineWeightByBlock: entity.lWeight == .byBlock,
            lineTypeScale: entity.ltypeScale > 0 ? entity.ltypeScale : nil,
            geomWidth: geomWidth,
            opacity: entity.transparency >= 0
                ? DXFColorTable.transparencyToOpacity(entity.transparency)
                : nil,
            plotStyleHandle: entity.plotStyleHandle == 0
                ? nil
                : String(entity.plotStyleHandle, radix: 16).uppercased(),
            textBackgroundScale: textBackgroundScale,
            textBackgroundColor: textBackgroundColor,
            textBackgroundUsesViewportColor: textBackgroundUsesViewportColor)
    }

    private static func polylineDisplayWidth(from entity: DXFEntity) -> Double? {
        if let lw = entity as? DXFLWPolylineEntity {
            let vertexWidth = lw.vertices.reduce(0.0) { current, vertex in
                max(current, max(abs(vertex.startWidth), abs(vertex.endWidth)))
            }
            let width = max(abs(lw.width), vertexWidth)
            return width > 0 ? width : nil
        }

        if let poly = entity as? DXFPolylineEntity {
            let vertexWidth = poly.vertices.reduce(0.0) { current, vertex in
                max(current, max(abs(vertex.startWidth), abs(vertex.endWidth)))
            }
            let defaultWidth = max(abs(poly.defStartWidth), abs(poly.defEndWidth))
            let width = max(defaultWidth, vertexWidth)
            return width > 0 ? width : nil
        }

        return nil
    }

    private static func resolveAssociativeHatchBoundaries(
        in entities: [DXFEntity],
        sourceEntityByHandle: [UInt32: DXFEntity]
    ) {
        for entity in entities {
            guard let hatch = entity as? DXFHatchEntity,
                  hatch.associative != 0 else { continue }

            for loop in hatch.loops where !loop.sourceBoundaryHandles.isEmpty {
                let resolved = loop.sourceBoundaryHandles.compactMap {
                    sourceEntityByHandle[$0]
                }
                guard resolved.count == loop.sourceBoundaryHandles.count,
                      resolved.allSatisfy(isSupportedHatchBoundarySource) else { continue }

                let sourceHasAnalyticCurve = resolved.contains {
                    $0 is DXFEllipseEntity
                        || $0 is DXFSplineEntity
                        || $0 is DXFArcEntity
                        || $0 is DXFCircleEntity
                }
                let storedBoundaryIsLinearized = loop.entities.isEmpty
                    || loop.entities.allSatisfy {
                        $0 is DXFLWPolylineEntity || $0 is DXFPolylineEntity
                    }

                if sourceHasAnalyticCurve && storedBoundaryIsLinearized {
                    loop.sourceBoundaryEntities = resolved
                }
            }
        }
    }

    private static func isSupportedHatchBoundarySource(_ entity: DXFEntity) -> Bool {
        entity is DXFLineEntity
            || entity is DXFArcEntity
            || entity is DXFCircleEntity
            || entity is DXFEllipseEntity
            || entity is DXFSplineEntity
            || entity is DXFLWPolylineEntity
            || entity is DXFPolylineEntity
    }

    private static func convertDimensionStyles(
        _ source: [DXFDimstyleEntry],
        blockNameByHandle: [UInt32: String],
        textStyleNameByHandle: [UInt32: String]
    ) -> [String: CADDimensionStyle] {
        var result: [String: CADDimensionStyle] = [:]

        for dimstyle in source where !dimstyle.name.isEmpty {
            var style = CADDimensionStyle()
            let scale = dimstyle.dimscale == 0 ? 1.0 : abs(dimstyle.dimscale)

            style.arrowSize = max(0, dimstyle.dimasz * scale)
            style.textHeight = max(0, dimstyle.dimtxt * scale)
            style.textOffset = abs(dimstyle.dimgap * scale)
            style.extensionLineOffset = max(0, dimstyle.dimexo * scale)
            style.extensionLineExtend = max(0, dimstyle.dimexe * scale)
            style.dimLineOffset = max(0, dimstyle.dimdli * scale)
            style.tickSize = max(0, dimstyle.dimtsz * scale)
            style.unitsFormat = DimUnitsFormat(rawValue: dimstyle.dimlunit) ?? .decimal
            style.unitsPrecision = max(0, dimstyle.dimdec)
            style.angleFormat = DimAngleFormat(rawValue: dimstyle.dimaunit) ?? .decimalDegrees
            style.anglePrecision = max(0, dimstyle.dimadec)
            style.linearScaleFactor = dimstyle.dimlfac
            style.zeroSuppression = dimstyle.dimzin
            style.suppressFirstExtension = dimstyle.dimse1 != 0
            style.suppressSecondExtension = dimstyle.dimse2 != 0
            style.suppressFirstDimLine = dimstyle.dimsd1 != 0
            style.suppressSecondDimLine = dimstyle.dimsd2 != 0

            if let textStyle = textStyleNameByHandle[dimstyle.dimtxstyHandle] {
                style.textStyle = textStyle
            } else if !dimstyle.dimtxsty.isEmpty {
                style.textStyle = dimstyle.dimtxsty
            }

            if let markerRange = dimstyle.dimpost.range(of: "<>") {
                let prefix = String(dimstyle.dimpost[..<markerRange.lowerBound])
                let suffix = String(dimstyle.dimpost[markerRange.upperBound...])
                style.dimensionPrefix = prefix.isEmpty ? nil : prefix
                style.dimensionSuffix = suffix.isEmpty ? nil : suffix
            } else if !dimstyle.dimpost.isEmpty {
                style.dimensionSuffix = dimstyle.dimpost
            }

            let generalArrowName = blockNameByHandle[dimstyle.dimblkHandle] ?? dimstyle.dimblk
            let firstArrowName: String
            let secondArrowName: String
            if dimstyle.dimsah != 0 {
                firstArrowName = blockNameByHandle[dimstyle.dimblk1Handle] ?? dimstyle.dimblk1
                secondArrowName = blockNameByHandle[dimstyle.dimblk2Handle] ?? dimstyle.dimblk2
            } else {
                firstArrowName = generalArrowName
                secondArrowName = generalArrowName
            }

            if style.tickSize > 0 {
                style.firstArrowhead = .architecturalTick
                style.secondArrowhead = .architecturalTick
            } else {
                style.firstArrowhead = CADDimensionArrowhead.fromDXFBlockName(firstArrowName)
                style.secondArrowhead = CADDimensionArrowhead.fromDXFBlockName(secondArrowName)
            }
            style.firstArrowBlockName = firstArrowName.isEmpty ? nil : firstArrowName
            style.secondArrowBlockName = secondArrowName.isEmpty ? nil : secondArrowName
            result[dimstyle.name] = style
        }

        if result["STANDARD"] == nil {
            result["STANDARD"] = .default
        }
        return result
    }

    private static func dimensionMetadata(from dimension: DXFDimensionEntity) -> CADDimensionMetadata? {
        let baseType = dimension.type & 0x0F
        let type: CADDimensionType
        switch baseType {
        case 0: type = .linearOrRotated
        case 1: type = .aligned
        case 2: type = .angular
        case 3: type = .diameter
        case 4: type = .radius
        case 5: type = .angular3Point
        case 6: type = .ordinate
        case 8: type = .arcLength
        default: return nil
        }

        let definition = cadPoint(dimension.defPoint)
        let point13 = cadPoint(dimension.def1)
        let point14 = cadPoint(dimension.def2)
        let point15 = cadPoint(dimension.circlePoint)
        let point16 = cadPoint(dimension.arcPoint)
        let textMidpoint = cadPoint(dimension.textPoint, extrusion: dimension.extPoint)
        let rotation: Double
        if type == .aligned {
            rotation = atan2(point14.y - point13.y, point14.x - point13.x)
        } else {
            rotation = -dimension.angle_p * .pi / 180.0
        }

        let measurement: Double
        if dimension.measurement.isFinite {
            measurement = dimension.measurement
        } else {
            measurement = fallbackDimensionMeasurement(
                type: type,
                definition: definition,
                point13: point13,
                point14: point14,
                point15: point15,
                rotation: rotation)
        }

        let text = dimension.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let textOverride = text.isEmpty || text == "<>" ? nil : dimension.text
        let flags = (dimension.type & ~0x0F) & ~32
        let styleName = dimension.style.isEmpty ? "STANDARD" : dimension.style

        switch type {
        case .linearOrRotated, .aligned:
            return CADDimensionMetadata(
                styleName: styleName,
                type: type,
                measurement: measurement,
                defPoint: definition,
                defPoint2: point13,
                defPoint3: point14,
                textMidpoint: textMidpoint,
                textOverride: textOverride,
                rotationAngle: rotation,
                textRotationAngle: dimension.hasTextRotation
                    ? -dimension.rot * .pi / 180.0
                    : nil,
                flags: flags)

        case .angular:
            let center = lineIntersection(point13, point14, point15, point16) ?? point15
            return CADDimensionMetadata(
                styleName: styleName,
                type: type,
                measurement: measurement,
                defPoint: definition,
                defPoint2: point14,
                defPoint3: point16,
                defPoint4: center,
                textMidpoint: textMidpoint,
                textOverride: textOverride,
                rotationAngle: rotation,
                textRotationAngle: dimension.hasTextRotation
                    ? -dimension.rot * .pi / 180.0
                    : nil,
                flags: flags)

        case .angular3Point:
            return CADDimensionMetadata(
                styleName: styleName,
                type: type,
                measurement: measurement,
                defPoint: definition,
                defPoint2: point13,
                defPoint3: point14,
                defPoint4: point15,
                textMidpoint: textMidpoint,
                textOverride: textOverride,
                rotationAngle: rotation,
                textRotationAngle: dimension.hasTextRotation
                    ? -dimension.rot * .pi / 180.0
                    : nil,
                flags: flags)

        case .diameter:
            return CADDimensionMetadata(
                styleName: styleName,
                type: type,
                measurement: measurement,
                defPoint: definition,
                defPoint2: point15,
                textMidpoint: textMidpoint,
                textOverride: textOverride,
                rotationAngle: rotation,
                textRotationAngle: dimension.hasTextRotation
                    ? -dimension.rot * .pi / 180.0
                    : nil,
                flags: flags)

        case .radius:
            return CADDimensionMetadata(
                styleName: styleName,
                type: type,
                measurement: measurement,
                defPoint: point15,
                defPoint2: definition,
                textMidpoint: textMidpoint,
                textOverride: textOverride,
                rotationAngle: rotation,
                textRotationAngle: dimension.hasTextRotation
                    ? -dimension.rot * .pi / 180.0
                    : nil,
                flags: flags)

        case .ordinate:
            return CADDimensionMetadata(
                styleName: styleName,
                type: type,
                measurement: measurement,
                defPoint: definition,
                defPoint2: point13,
                defPoint3: point14,
                textMidpoint: textMidpoint,
                textOverride: textOverride,
                rotationAngle: rotation,
                textRotationAngle: dimension.hasTextRotation
                    ? -dimension.rot * .pi / 180.0
                    : nil,
                flags: flags)

        case .arcLength:
            return CADDimensionMetadata(
                styleName: styleName,
                type: type,
                measurement: measurement,
                defPoint: definition,
                defPoint2: point13,
                defPoint3: point14,
                defPoint4: point15,
                defPoint5: point16,
                textMidpoint: textMidpoint,
                textOverride: textOverride,
                rotationAngle: rotation,
                textRotationAngle: dimension.hasTextRotation
                    ? -dimension.rot * .pi / 180.0
                    : nil,
                flags: flags)

        case .jogged:
            return nil
        }
    }

    private static func preservingCachedDimensionText(
        _ metadata: CADDimensionMetadata?,
        block: CADBlock,
        dimensionStyles: [String: CADDimensionStyle]
    ) -> CADDimensionMetadata? {
        guard var metadata else { return nil }

        for primitive in block.geometry {
            guard case .text(
                let position, _, let height, let rotation, let textStyle,
                _, _, _, _
            ) = primitive else { continue }

            metadata.textMidpoint = position
            metadata.textRotationAngle = rotation

            var style = metadata.styleOverrides
                ?? dimensionStyles[metadata.styleName]
                ?? CADDimensionStyle.default
            style.textHeight = height
            style.textStyle = textStyle
            metadata.styleOverrides = style
            break
        }

        return metadata
    }

    private static func fallbackDimensionMeasurement(
        type: CADDimensionType,
        definition: Vector3,
        point13: Vector3,
        point14: Vector3,
        point15: Vector3,
        rotation: Double
    ) -> Double {
        switch type {
        case .linearOrRotated:
            let dir = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
            return abs((point14.x - point13.x) * dir.x + (point14.y - point13.y) * dir.y)
        case .aligned:
            return hypot(point14.x - point13.x, point14.y - point13.y)
        case .diameter:
            return hypot(point15.x - definition.x, point15.y - definition.y)
        case .radius:
            return hypot(point15.x - definition.x, point15.y - definition.y)
        case .angular, .angular3Point:
            let a1 = atan2(point13.y - point15.y, point13.x - point15.x)
            let a2 = atan2(point14.y - point15.y, point14.x - point15.x)
            return abs(a2 - a1)
        default:
            return 0
        }
    }

    private static func lineIntersection(
        _ a1: Vector3,
        _ a2: Vector3,
        _ b1: Vector3,
        _ b2: Vector3
    ) -> Vector3? {
        let dax = a2.x - a1.x
        let day = a2.y - a1.y
        let dbx = b2.x - b1.x
        let dby = b2.y - b1.y
        let denominator = dax * dby - day * dbx
        guard abs(denominator) > 1e-12 else { return nil }
        let t = ((b1.x - a1.x) * dby - (b1.y - a1.y) * dbx) / denominator
        return Vector3(x: a1.x + dax * t, y: a1.y + day * t, z: a1.z)
    }

    private static func cadPoint(_ point: Vector3) -> Vector3 {
        Vector3(x: point.x, y: -point.y, z: point.z)
    }

    private static func cadPoint(_ point: Vector3, extrusion: Vector3?) -> Vector3 {
        guard let extrusion, !isDefaultExtrusion(extrusion) else { return cadPoint(point) }
        return cadPoint(ocsToWcs(point, extrusion: extrusion))
    }

    private static func insertTransform(_ insert: DXFInsertEntity, blockBase: Vector3, column: Int = 0, row: Int = 0) -> Transform3D {
        let sx = insert.xScale == 0 ? 1.0 : insert.xScale
        let sy = insert.yScale == 0 ? 1.0 : insert.yScale
        let sz = insert.zScale == 0 ? 1.0 : insert.zScale
        let mirrored = insert.haveExtrusion && insert.extrusion.z < 0

        let insertion: Vector3
        let rotation: Double
        let scaleVector: Vector3

        if mirrored {
            insertion = Vector3(
                x: -insert.basePoint.x,
                y: -insert.basePoint.y,
                z: -insert.basePoint.z)
            rotation = insert.angle + .pi
            scaleVector = Vector3(x: sx, y: -sy, z: sz)
        } else {
            insertion = Self.cadPoint(
                insert.basePoint,
                extrusion: insert.haveExtrusion ? insert.extrusion : nil)
            rotation = -insert.angle
            scaleVector = Vector3(x: sx, y: sy, z: sz)
        }

        let translate = Transform3D.translated(by: insertion)
        let rotate = Transform3D.rotated(by: rotation)
        let arrayOffset = Transform3D.translated(by: Vector3(
            x: Double(column) * insert.colSpace,
            y: -Double(row) * insert.rowSpace,
            z: 0))
        let scale = Transform3D.scaled(by: scaleVector)
        let base = Transform3D.translated(by: Vector3(x: -blockBase.x, y: -blockBase.y, z: -blockBase.z))
        return translate
            .multiplying(by: rotate)
            .multiplying(by: arrayOffset)
            .multiplying(by: scale)
            .multiplying(by: base)
    }

    private static func isDefaultExtrusion(_ n: Vector3) -> Bool {
        abs(n.x) < 1e-12 && abs(n.y) < 1e-12 && abs(n.z - 1.0) < 1e-12
    }

    private static func ocsToWcs(_ point: Vector3, extrusion n: Vector3) -> Vector3 {
        var az = n
        var mag = sqrt(az.x * az.x + az.y * az.y + az.z * az.z)
        if mag < 1e-12 {
            az = Vector3(x: 0, y: 0, z: 1)
            mag = 1.0
        }
        az.x /= mag; az.y /= mag; az.z /= mag

        var ax: Vector3
        if abs(az.x) < 0.015625 && abs(az.y) < 0.015625 {
            ax = Vector3(x: az.z, y: 0, z: -az.x)
        } else {
            ax = Vector3(x: -az.y, y: az.x, z: 0)
        }
        mag = sqrt(ax.x * ax.x + ax.y * ax.y + ax.z * ax.z)
        if mag > 1e-12 { ax.x /= mag; ax.y /= mag; ax.z /= mag }

        var ay = Vector3(
            x: az.y * ax.z - az.z * ax.y,
            y: az.z * ax.x - az.x * ax.z,
            z: az.x * ax.y - az.y * ax.x)
        mag = sqrt(ay.x * ay.x + ay.y * ay.y + ay.z * ay.z)
        if mag > 1e-12 { ay.x /= mag; ay.y /= mag; ay.z /= mag }

        return Vector3(
            x: ax.x * point.x + ay.x * point.y + az.x * point.z,
            y: ax.y * point.x + ay.y * point.y + az.y * point.z,
            z: ax.z * point.x + ay.z * point.y + az.z * point.z)
    }

    private static func transformStyledPrimitives(
        _ values: [StyledPrimitive],
        by transform: Transform3D,
        nestedInsertStyle: CADPrimitiveStyle
    ) -> [StyledPrimitive] {
        values.map { item in
            var style = item.style
            if style?.isColorByBlock == true {
                style?.color = nestedInsertStyle.color
                style?.isColorByBlock = nestedInsertStyle.isColorByBlock
                if style?.color == nil && !nestedInsertStyle.isColorByBlock {
                    style?.layerName = nestedInsertStyle.layerName
                }
            }
            if style?.isLineTypeByBlock == true {
                style?.lineType = nestedInsertStyle.lineType
                style?.isLineTypeByBlock = nestedInsertStyle.isLineTypeByBlock
                let nestedLineType = nestedInsertStyle.lineType?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() ?? "BYLAYER"
                if !nestedInsertStyle.isLineTypeByBlock
                    && (nestedLineType.isEmpty || nestedLineType == "BYLAYER") {
                    style?.layerName = nestedInsertStyle.layerName
                }
            }
            if style?.isLineWeightByBlock == true {
                style?.lineWeight = nestedInsertStyle.lineWeight
                style?.isLineWeightByBlock = nestedInsertStyle.isLineWeightByBlock
                if style?.lineWeight == nil && !nestedInsertStyle.isLineWeightByBlock {
                    style?.layerName = nestedInsertStyle.layerName
                }
            }
            if let nestedScale = nestedInsertStyle.lineTypeScale {
                let currentScale = style?.lineTypeScale ?? 1.0
                style?.lineTypeScale = currentScale * nestedScale
            }
            if let nestedOpacity = nestedInsertStyle.opacity {
                let currentOpacity = style?.opacity ?? 1.0
                style?.opacity = currentOpacity * nestedOpacity
            }
            return StyledPrimitive(
                primitive: transformPrimitive(item.primitive, by: transform),
                style: style)
        }
    }

    private static func transformPrimitive(_ primitive: CADPrimitive, by transform: Transform3D) -> CADPrimitive {
        func p(_ value: Vector3) -> Vector3 { transform.transformPoint(value) }
        func v(_ value: Vector3) -> Vector3 { transform.transformPoint(value) - transform.transformPoint(.zero) }
        func scalar(_ value: Double) -> Double {
            let s = transform.scale
            return value * (abs(s.x) + abs(s.y)) * 0.5
        }

        switch primitive {
        case .point(let position, let color):
            return .point(position: p(position), color: color)
        case .line(let start, let end, let color):
            return .line(start: p(start), end: p(end), color: color)
        case .rect(let origin, let size, let color):
            return .polygon(points: [origin, Vector3(x: origin.x + size.x, y: origin.y, z: origin.z), origin + size, Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)].map(p), color: color)
        case .fillRect(let origin, let size, let color):
            return .fillPolygon(points: [origin, Vector3(x: origin.x + size.x, y: origin.y, z: origin.z), origin + size, Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)].map(p), color: color)
        case .polygon(let points, let color):
            return .polygon(points: points.map(p), color: color)
        case .fillPolygon(let points, let color):
            return .fillPolygon(points: points.map(p), color: color)
        case .fillComplexPolygon(let outer, let holes, let color):
            return .fillComplexPolygon(outer: outer.map(p), holes: holes.map { $0.map(p) }, color: color)
        case .gradient(let outer, let holes, let gradientName, let angle, let color1, let color2):
            return .gradient(outer: outer.map(p), holes: holes.map { $0.map(p) }, gradientName: gradientName, angle: angle + transform.rotation, color1: color1, color2: color2)
        case .polyline(let path, let color):
            return .polyline(path: transformPolyline(path, by: transform), color: color)
        case .circle(let center, let radius, let color):
            return .circle(center: p(center), radius: scalar(radius), color: color)
        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            return .arc(center: p(center), radius: scalar(radius), startAngle: startAngle + transform.rotation, endAngle: endAngle + transform.rotation, color: color)
        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            return .spline(controlPoints: controlPoints.map(p), knots: knots, degree: degree, weights: weights, color: color)
        case .text(let position, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, let color):
            return .text(position: p(position), text: text, height: scalar(height), rotation: rotation + transform.rotation, style: style, alignH: alignH, alignV: alignV, mtextWidth: mtextWidth.map(scalar), color: color)
        case .ellipse(let center, let majorAxis, let minorRatio, let color):
            return .ellipse(center: p(center), majorAxis: v(majorAxis), minorRatio: minorRatio, color: color)
        case .hatch(let boundary, let pattern, let scale, let angle, let color, let backgroundColor):
            return .hatch(boundary: boundary.map(p), pattern: pattern, scale: scalar(scale), angle: angle + transform.rotation, color: color, backgroundColor: backgroundColor)
        case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let color, let backgroundColor):
            return .hatchPath(boundary: transformPolyline(boundary, by: transform), holes: holes.map { transformPolyline($0, by: transform) }, pattern: pattern, scale: scalar(scale), angle: angle + transform.rotation, color: color, backgroundColor: backgroundColor)
        case .ray(let start, let direction, let color):
            return .ray(start: p(start), direction: v(direction), color: color)
        case .image(let insertion, let uAxis, let vAxis, let imageName, let clipBoundary, let tint):
            return .image(insertion: p(insertion), uAxis: v(uAxis), vAxis: v(vAxis), imageName: imageName, clipBoundary: clipBoundary?.map(p), tint: tint)
        case .table(let data, let origin, let color):
            return .table(data: data, origin: p(origin), color: color)
        }
    }

    private static func transformPolyline(_ path: CADPolyline, by transform: Transform3D) -> CADPolyline {
        path.transformed(by: transform)
    }
}

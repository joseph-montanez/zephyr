import Foundation

// =========================================================================
// MARK: - DXFImporter
// Pure Swift DXF import.
// =========================================================================

public enum DXFDrawingViewKind: Sendable, Equatable { case model, sheet }

public struct DXFDrawingView: Sendable {
    public let name: String
    public let kind: DXFDrawingViewKind
    public let entities: [CADEntity]
    public let backgroundColor: ColorRGBA?

    public init(
        name: String,
        kind: DXFDrawingViewKind,
        entities: [CADEntity],
        backgroundColor: ColorRGBA? = nil
    ) {
        self.name = name
        self.kind = kind
        self.entities = entities
        self.backgroundColor = backgroundColor
    }
}

public struct DXFImportResult: Sendable {
    public let layers: [Layer]; public let blocks: [CADBlock]; public let entities: [CADEntity]
    public let textStyles: [String: CADTextStyle]; public let linetypePatterns: [String: [Double]]
    public var textStyleFonts: [String: String] {
        Dictionary(textStyles.values.map { ($0.name, $0.fontFile) }, uniquingKeysWith: { first, _ in first })
    }
    public let dimensionStyles: [String: CADDimensionStyle]
    public let views: [DXFDrawingView]
    public init(layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
                textStyles: [String: CADTextStyle], linetypePatterns: [String: [Double]],
                dimensionStyles: [String: CADDimensionStyle], views: [DXFDrawingView]) {
        self.layers = layers; self.blocks = blocks; self.entities = entities
        self.textStyles = textStyles; self.linetypePatterns = linetypePatterns
        self.dimensionStyles = dimensionStyles
        self.views = views
    }

    public init(layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
                textStyleFonts: [String: String], linetypePatterns: [String: [Double]],
                dimensionStyles: [String: CADDimensionStyle], views: [DXFDrawingView]) {
        let styles = Dictionary(uniqueKeysWithValues: textStyleFonts.map { name, font in
            (name, CADTextStyle(name: name, fontFile: font).normalized)
        })
        self.init(
            layers: layers,
            blocks: blocks,
            entities: entities,
            textStyles: styles.isEmpty ? ["Standard": .standard] : styles,
            linetypePatterns: linetypePatterns,
            dimensionStyles: dimensionStyles,
            views: views)
    }
}

public enum DXFImporter {

    private struct StyledPrimitive {
        var primitive: CADPrimitive
        var style: CADPrimitiveStyle?
        var xdata: [String: XDataValue]
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
        let layerName: String

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
            layerName = source.layer
        }

        var isUsable: Bool {
            status != 0
                && paperWidth > 1e-9
                && paperHeight > 1e-9
                && viewHeight > 1e-9
        }

        var isSystemViewport: Bool {
            id > 0 ? id == 1 : status == 1
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

        func projectedXData(_ source: [String: XDataValue]) -> [String: XDataValue] {
            var result = source
            result["dxf.viewport.projected"] = .bool(true)
            result["dxf.viewport.paperCenterX"] = .double(paperCenterX)
            result["dxf.viewport.paperCenterY"] = .double(paperCenterY)
            result["dxf.viewport.paperWidth"] = .double(paperWidth)
            result["dxf.viewport.paperHeight"] = .double(paperHeight)
            result["dxf.viewport.status"] = .int(status)
            result["dxf.viewport.id"] = .int(id)
            result["dxf.viewport.viewCenterX"] = .double(viewCenterX)
            result["dxf.viewport.viewCenterY"] = .double(viewCenterY)
            result["dxf.viewport.viewTargetX"] = .double(viewTargetX)
            result["dxf.viewport.viewTargetY"] = .double(viewTargetY)
            result["dxf.viewport.viewHeight"] = .double(viewHeight)
            result["dxf.viewport.twistDegrees"] = .double(twistAngle * 180.0 / .pi)
            result["dxf.viewport.layer"] = .string(layerName)
            return result
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

    private static func defaultLayoutProjection(
        layout: DXFLayoutEntry,
        modelEntities: [CADEntity],
        header: DXFHeaderData
    ) -> Transform3D? {
        let epsilon = 1e-9
        let coordinateLimit = 1e18

        func validRange(_ minimum: Double, _ maximum: Double) -> Bool {
            minimum.isFinite && maximum.isFinite
                && abs(minimum) < coordinateLimit
                && abs(maximum) < coordinateLimit
                && maximum - minimum > epsilon
        }

        var modelBounds: BoundingBox3D?
        if validRange(header.extMin.x, header.extMax.x),
           validRange(header.extMin.y, header.extMax.y) {
            let first = Self.cadPoint(header.extMin)
            let second = Self.cadPoint(header.extMax)
            modelBounds = BoundingBox3D(
                min: Vector3(
                    x: min(first.x, second.x),
                    y: min(first.y, second.y),
                    z: min(first.z, second.z)),
                max: Vector3(
                    x: max(first.x, second.x),
                    y: max(first.y, second.y),
                    z: max(first.z, second.z)))
        }

        if modelBounds == nil {
            for entity in modelEntities {
                guard let bounds = entity.worldBoundingBox else { continue }
                modelBounds = modelBounds.map { $0.union(with: bounds) } ?? bounds
            }
        }

        guard let modelBounds,
              validRange(modelBounds.min.x, modelBounds.max.x),
              validRange(modelBounds.min.y, modelBounds.max.y) else {
            return nil
        }

        var paperMinX = layout.minimumLimits.x
        var paperMinY = layout.minimumLimits.y
        var paperMaxX = layout.maximumLimits.x
        var paperMaxY = layout.maximumLimits.y
        if !validRange(paperMinX, paperMaxX) || !validRange(paperMinY, paperMaxY) {
            paperMinX = 0
            paperMinY = 0
            paperMaxX = 12
            paperMaxY = 9
        }

        let paperWidth = paperMaxX - paperMinX
        let paperHeight = paperMaxY - paperMinY
        let modelWidth = modelBounds.max.x - modelBounds.min.x
        let modelHeight = modelBounds.max.y - modelBounds.min.y
        let scale = min(paperWidth / modelWidth, paperHeight / modelHeight) * 0.9
        guard scale.isFinite, scale > epsilon else { return nil }

        let paperCenter = Vector3(
            x: (paperMinX + paperMaxX) * 0.5,
            y: -(paperMinY + paperMaxY) * 0.5,
            z: 0)
        let modelCenter = modelBounds.center

        return Transform3D
            .translated(by: paperCenter)
            .multiplying(by: .scaled(by: Vector3(x: scale, y: scale, z: 1)))
            .multiplying(by: .translated(by: Vector3(
                x: -modelCenter.x,
                y: -modelCenter.y,
                z: -modelCenter.z)))
    }

    private static func syntheticViewportXData(
        _ source: [String: XDataValue],
        projection: Transform3D
    ) -> [String: XDataValue] {
        var result = source
        result["dxf.viewport.projected"] = .bool(true)
        result["dxf.viewport.synthetic"] = .bool(true)
        result["dxf.viewport.projection"] = .string(
            projection.rawElements.map { String(format: "%.17g", $0) }.joined(separator: ","))
        return result
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
            return DXFImportResult(layers: [], blocks: [], entities: [], textStyles: ["Standard": .standard], linetypePatterns: [:], dimensionStyles: [:], views: [])
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
        var blockHandleByName: [String: UInt32] = [:]
        for record in reader.blockRecords where record.handle != 0 && !record.name.isEmpty {
            blockNameByHandle[record.handle] = record.name
            blockHandleByName[record.name.uppercased()] = record.handle
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
                                    style: Self.primitiveStyle(from: attribute),
                                    xdata: Self.entityStyleXData(
                                        from: attribute,
                                        globalLineTypeScale: globalLineTypeScale))
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
                let xdata = Self.entityStyleXData(
                    from: entity,
                    globalLineTypeScale: globalLineTypeScale)
                let primitives = DXFEntityConverter.convertEntityToPrimitives(entity, bylayerColor: nil)
                geometry.append(contentsOf: primitives.map {
                    StyledPrimitive(primitive: $0, style: style, xdata: xdata)
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
                primitiveXData: Dictionary(uniqueKeysWithValues:
                    styledGeometry.enumerated().compactMap { index, item in
                        guard !item.xdata.isEmpty else { return nil }
                        return (index, item.xdata)
                    }),
                dxfFlags: block.flags,
                isInternalTableDisplayBlock: block.name.hasPrefix("*T"))
            blocks.append(cadBlock)
            blockByID[handle] = cadBlock
        }

        let sortEntsFlags: Int = {
            if let value = reader.header.headerVars["$SORTENTS"] as? Int { return value }
            if let value = reader.header.headerVars["$SORTENTS"] as? Int32 { return Int(value) }
            return 127
        }()
        let sortEntsRegenEnabled = (sortEntsFlags & 16) != 0

        func drawOrderedEntities(
            _ sourceEntities: [DXFEntity],
            ownerHandle preferredOwnerHandle: UInt32
        ) -> [DXFEntity] {
            guard sortEntsRegenEnabled, sourceEntities.count > 1 else {
                return sourceEntities
            }

            let ownerHandle: UInt32 = {
                if preferredOwnerHandle != 0 { return preferredOwnerHandle }
                var counts: [UInt32: Int] = [:]
                for entity in sourceEntities where entity.parentHandle != 0 {
                    counts[entity.parentHandle, default: 0] += 1
                }
                return counts.max { lhs, rhs in lhs.value < rhs.value }?.key ?? 0
            }()
            guard ownerHandle != 0 else { return sourceEntities }

            var sortHandlesByEntity: [UInt32: UInt32] = [:]
            for table in reader.sortEntsTables where table.ownerHandle == ownerHandle {
                sortHandlesByEntity.merge(
                    table.sortHandlesByEntity,
                    uniquingKeysWith: { _, replacement in replacement })
            }
            guard !sortHandlesByEntity.isEmpty else { return sourceEntities }

            return sourceEntities.enumerated().sorted { lhs, rhs in
                let lhsHandle = lhs.element.handle
                let rhsHandle = rhs.element.handle
                let lhsSortHandle: UInt32?
                if let mapped = sortHandlesByEntity[lhsHandle] {
                    lhsSortHandle = mapped
                } else {
                    lhsSortHandle = lhsHandle == 0 ? nil : lhsHandle
                }
                let rhsSortHandle: UInt32?
                if let mapped = sortHandlesByEntity[rhsHandle] {
                    rhsSortHandle = mapped
                } else {
                    rhsSortHandle = rhsHandle == 0 ? nil : rhsHandle
                }
                let lhsKey = lhsSortHandle.map(UInt64.init) ?? UInt64.max
                let rhsKey = rhsSortHandle.map(UInt64.init) ?? UInt64.max
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                return lhs.offset < rhs.offset
            }.map { $0.element }
        }

        func convertEntities(
            _ sourceEntities: [DXFEntity],
            ownerHandle: UInt32 = 0
        ) -> [CADEntity] {
            let orderedEntities = drawOrderedEntities(
                sourceEntities,
                ownerHandle: ownerHandle)
            var converted: [CADEntity] = []
            converted.reserveCapacity(orderedEntities.count)
            var seenArrayGroups = Set<UUID>()

            for (drawOrder, entity) in orderedEntities.enumerated() {
                guard Self.shouldRenderAttributeEntity(entity) else { continue }

                if let insert = entity as? DXFInsertEntity,
                   let blockID = blockNameToID[insert.name],
                   let block = blockByID[blockID] {
                    let columns = max(1, insert.colCount)
                    let rows = max(1, insert.rowCount)
                    let blockBase = blockBaseByName[insert.name] ?? .zero
                    let arrayXData = Self.arrayXData(from: insert)
                    if let groupID = arrayXData.groupID {
                        if arrayXData.role == "I" || seenArrayGroups.contains(groupID) {
                            continue
                        }
                        if arrayXData.role == "M",
                           let payload = CADArrayDXFCodec.decode(arrayXData.payloadChunks),
                           let containerTransform = payload.transform {
                            seenArrayGroups.insert(groupID)
                            var arrayData = payload.data
                            arrayData.pathEntityHandle = nil
                            var cadEnt = CADEntity(
                                handle: UUID(),
                                layerID: layerID(for: entity),
                                blockID: blockID,
                                arrayData: arrayData,
                                transform: containerTransform,
                                xdata: Self.entityStyleXData(
                                    from: entity,
                                    globalLineTypeScale: globalLineTypeScale),
                                drawOrder: drawOrder,
                                localBoundingBox: arrayData.localBoundingBox(
                                    source: block.localBoundingBox,
                                    pathPoints: arrayData.cachedPath))
                            cadEnt.drawOrder = drawOrder
                            converted.append(cadEnt)
                            continue
                        }
                    }

                    if columns > 1 || rows > 1 {
                        let sx = abs(insert.xScale) > 1e-12 ? insert.xScale : 1.0
                        let rawSY = abs(insert.yScale) > 1e-12 ? insert.yScale : 1.0
                        let effectiveSY = insert.haveExtrusion && insert.extrusion.z < 0 ? -rawSY : rawSY
                        let transform = Self.insertTransform(
                            insert,
                            blockBase: blockBase)
                        let arrayData = CADArrayData.rectangular(
                            columns: columns,
                            rows: rows,
                            columnSpacing: insert.colSpace / sx,
                            rowSpacing: -insert.rowSpace / effectiveSY)
                        var cadEnt = CADEntity(
                            handle: UUID(),
                            layerID: layerID(for: entity),
                            blockID: blockID,
                            arrayData: arrayData,
                            transform: transform,
                            xdata: Self.entityStyleXData(
                                from: entity,
                                globalLineTypeScale: globalLineTypeScale),
                            drawOrder: drawOrder,
                            localBoundingBox: arrayData.localBoundingBox(
                                source: block.localBoundingBox))
                        cadEnt.drawOrder = drawOrder
                        converted.append(cadEnt)
                    } else {
                        var cadEnt = CADEntity(
                            handle: UUID(),
                            layerID: layerID(for: entity),
                            blockID: blockID,
                            localGeometry: nil,
                            transform: Self.insertTransform(
                                insert,
                                blockBase: blockBase),
                            xdata: Self.entityStyleXData(
                                from: entity,
                                globalLineTypeScale: globalLineTypeScale),
                            drawOrder: drawOrder,
                            localBoundingBox: block.localBoundingBox)
                        cadEnt.drawOrder = drawOrder
                        converted.append(cadEnt)
                    }

                    for attribute in insert.attributes
                        where Self.shouldRenderAttributeEntity(attribute) {
                        let primitives = DXFEntityConverter.convertEntityToPrimitives(
                            attribute,
                            bylayerColor: nil)
                        guard !primitives.isEmpty else { continue }
                        let normalized = Self.normalizedStandaloneTextGeometry(primitives)
                        let attributeLayerID = attribute.layer.isEmpty
                            || attribute.layer == "0"
                            ? layerID(for: insert)
                            : layerID(for: attribute)
                        var attributeEntity = CADEntity(
                            handle: UUID(),
                            layerID: attributeLayerID,
                            blockID: nil,
                            localGeometry: normalized.geometry,
                            transform: normalized.transform,
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
                let normalized = Self.normalizedStandaloneTextGeometry(primitives)
                var cadEnt = CADEntity(
                    handle: UUID(),
                    layerID: layerID(for: entity),
                    blockID: nil,
                    localGeometry: normalized.geometry,
                    transform: normalized.transform,
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
            var result: [DXFEntity] = []
            var seenHandles: Set<UInt32> = []
            var seenObjects: Set<ObjectIdentifier> = []

            func appendUnique(_ entities: [DXFEntity]) {
                for entity in entities {
                    if entity.handle != 0 {
                        guard seenHandles.insert(entity.handle).inserted else { continue }
                    } else {
                        guard seenObjects.insert(ObjectIdentifier(entity)).inserted else { continue }
                    }
                    result.append(entity)
                }
            }

            appendUnique(entitiesOwned(by: layout.blockRecordHandle))

            let blockName = blockNameByHandle[layout.blockRecordHandle]
            if let blockName, let block = blockByName[blockName] {
                appendUnique(block.entities)
            }

            if layout.name.caseInsensitiveCompare("Model") != .orderedSame,
               blockName?.caseInsensitiveCompare("*Paper_Space") == .orderedSame {
                appendUnique(reader.entities.filter { $0.space == 1 })
            }

            return result
        }

        var textStyles: [String: CADTextStyle] = ["Standard": .standard]
        for entry in reader.textstyles where !entry.name.isEmpty {
            let style = CADTextStyle(
                name: entry.name,
                fontFile: entry.font.isEmpty ? "simplex.shx" : entry.font,
                fixedHeight: entry.height,
                widthFactor: entry.width == 0 ? 1 : entry.width,
                obliqueAngle: entry.oblique,
                isAnnotative: false
            ).normalized
            textStyles[style.name] = style
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
            let modelOwnerHandle = blockHandleByName["*MODEL_SPACE"] ?? 0
            modelEntities = convertEntities(
                reader.entities,
                ownerHandle: modelOwnerHandle)
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
            modelEntities = convertEntities(
                modelSource,
                ownerHandle: modelLayout?.blockRecordHandle
                    ?? blockHandleByName["*MODEL_SPACE"]
                    ?? 0)

            var importedViews: [DXFDrawingView] = [DXFDrawingView(
                name: modelLayout?.name ?? "Model",
                kind: .model,
                entities: modelEntities)]

            for layout in orderedLayouts where
                layout.name.caseInsensitiveCompare("Model") != .orderedSame {
                let paperSource = sourceEntities(for: layout)
                var paperEntities = convertEntities(
                    paperSource,
                    ownerHandle: layout.blockRecordHandle)
                let paperDrawOrderOffset = modelEntities.count + 1
                for index in paperEntities.indices where paperEntities[index].drawOrder != Int.max {
                    paperEntities[index].drawOrder += paperDrawOrderOffset
                }

                var projectedEntities: [CADEntity] = []
                let usableViewports = paperSource.compactMap { $0 as? DXFViewportEntity }
                    .map(SheetViewport.init)
                    .filter(\.isUsable)
                let hasUserViewport = usableViewports.contains { !$0.isSystemViewport }
                let viewports = hasUserViewport
                    ? usableViewports.filter { !$0.isSystemViewport }
                    : usableViewports

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
                            arrayData: modelEntity.arrayData,
                            transform: projection.multiplying(by: modelEntity.transform),
                            xdata: viewport.projectedXData(modelEntity.xdata),
                            drawOrder: projectedDrawOrder,
                            localBoundingBox: modelEntity.localBoundingBox,
                            anchorPoints: modelEntity.anchorPoints))
                    }
                }

                if viewports.isEmpty,
                   let projection = Self.defaultLayoutProjection(
                    layout: layout,
                    modelEntities: modelEntities,
                    header: reader.header) {
                    for modelEntity in modelEntities {
                        let projectedDrawOrder = modelEntity.drawOrder == Int.max
                            ? Int.max
                            : modelEntity.drawOrder + 1
                        projectedEntities.append(CADEntity(
                            layerID: modelEntity.layerID,
                            blockID: modelEntity.blockID,
                            localGeometry: modelEntity.localGeometry,
                            dimensionMetadata: modelEntity.dimensionMetadata,
                            arrayData: modelEntity.arrayData,
                            transform: projection.multiplying(by: modelEntity.transform),
                            xdata: syntheticViewportXData(modelEntity.xdata, projection: projection),
                            drawOrder: projectedDrawOrder,
                            localBoundingBox: modelEntity.localBoundingBox,
                            anchorPoints: modelEntity.anchorPoints))
                    }
                }

                importedViews.append(DXFDrawingView(
                    name: layout.name,
                    kind: .sheet,
                    entities: projectedEntities + paperEntities,
                    backgroundColor: .white))
            }
            views = importedViews
        }

        return DXFImportResult(
            layers: layers,
            blocks: blocks,
            entities: modelEntities,
            textStyles: textStyles,
            linetypePatterns: linetypePatterns,
            dimensionStyles: dimensionStyles,
            views: views)
    }

    private static func arrayXData(
        from entity: DXFEntity
    ) -> (groupID: UUID?, role: String?, payloadChunks: [String]) {
        var active = false
        var values: [String] = []
        for pair in entity.extendedData {
            if pair.code == 1001 {
                active = (pair.value as? String)?.caseInsensitiveCompare(
                    CADArrayDXFCodec.appID) == .orderedSame
                continue
            }
            if active, pair.code == 1000, let value = pair.value as? String {
                values.append(value)
            }
        }
        guard values.contains(CADArrayDXFCodec.marker) else { return (nil, nil, []) }
        let groupID = values.first(where: { $0.hasPrefix("G:") })
            .flatMap { UUID(uuidString: String($0.dropFirst(2))) }
        let role = values.first(where: { $0.hasPrefix("R:") })
            .map { String($0.dropFirst(2)) }
        return (groupID, role, values.filter { $0.hasPrefix("D:") })
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
        if let opacity = DXFColorTable.explicitTransparencyToOpacity(entity.transparency) {
            xdata["dxf.opacity"] = .double(opacity)
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

        if let text = entity as? DXFTextEntity {
            xdata["dxf.text"] = .string(
                DXFEntityConverter.cleanMTextFormatting(text.text))
            xdata["dxf.textEntityType"] = .string(text.eType.rawValue)
            xdata["dxf.textHeight"] = .double(text.height)
            xdata["dxf.textStyle"] = .string(text.style)
            xdata["dxf.alignH"] = .int(text.alignH)
            xdata["dxf.alignV"] = .int(text.alignV)
            xdata["dxf.textWidthScale"] = .double(text.widthScale)
            xdata["dxf.textOblique"] = .double(text.oblique)
            xdata["dxf.textGenerationFlags"] = .int(text.textGen)
            if text.eType == .mTEXT {
                xdata["dxf.mtextRaw"] = .string(text.text)
                xdata["dxf.mtextWidth"] = .double(text.widthScale)
                let formatted = MTEXTFormatter.parse(
                    text.text,
                    defaultFont: text.style.isEmpty ? "STANDARD" : text.style,
                    defaultHeight: text.height > 0 ? text.height : 2.5)
                if let data = try? JSONEncoder().encode(formatted),
                   let json = String(data: data, encoding: .utf8) {
                    xdata["dxf.formattedText"] = .string(json)
                }
                if let mtext = text as? DXFMTextEntity {
                    xdata["dxf.mtextLineSpacing"] = .double(mtext.interlin)
                    xdata["dxf.mtextLineSpacingStyle"] = .int(mtext.lineSpacingStyle)
                }
            }
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
                if let opacity = DXFColorTable.explicitTransparencyToOpacity(
                    Int32(mtext.backgroundTransparency)) {
                    xdata["dxf.mtextBackgroundOpacity"] = .double(opacity)
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
        guard entity.visible else { return false }
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

    private static func normalizedStandaloneTextGeometry(
        _ primitives: [CADPrimitive]
    ) -> (geometry: [CADPrimitive], transform: Transform3D) {
        guard primitives.count == 1,
              case .text(
                let position, let text, let height, let rotation, let style,
                let alignH, let alignV, let mtextWidth, let color
              ) = primitives[0]
        else {
            return (primitives, .identity)
        }

        var transform = Transform3D.translated(by: position)
        if abs(rotation) > 1e-12 {
            transform = transform.multiplying(by: .rotated(by: rotation))
        }

        let localText = CADPrimitive.text(
            position: .zero,
            text: text,
            height: height,
            rotation: 0,
            style: style,
            alignH: alignH,
            alignV: alignV,
            mtextWidth: mtextWidth,
            color: color)
        return ([localText], transform)
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
                if let opacity = DXFColorTable.explicitTransparencyToOpacity(
                    Int32(mtext.backgroundTransparency)) {
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
            opacity: DXFColorTable.explicitTransparencyToOpacity(entity.transparency),
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

        for (primitiveIndex, primitive) in block.geometry.enumerated() {
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
            if let primitiveStyle = block.primitiveStyles[primitiveIndex],
               primitiveStyle.textBackgroundScale != nil {
                style.textBackgroundScale = primitiveStyle.textBackgroundScale
                style.textBackgroundColor = primitiveStyle.textBackgroundColor
                style.textBackgroundUsesViewportColor =
                    primitiveStyle.textBackgroundUsesViewportColor
            }
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
                style: style,
                xdata: transformedPrimitiveXData(item.xdata, by: transform))
        }
    }

    private static func transformedPrimitiveXData(
        _ source: [String: XDataValue],
        by transform: Transform3D
    ) -> [String: XDataValue] {
        guard transform != .identity else { return source }
        var result = source
        result.removeValue(forKey: "dxf.hatchScale")
        result.removeValue(forKey: "dxf.hatchAngle")
        result.removeValue(forKey: "dxf.hatchPatternLines")
        return result
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

import Foundation

/// Converts Zephyr CAD types to DXF format using pure Swift DXFWriter.
public enum DXFWriterBridge {

    public static let defaultExportVersion: DXFVersion = .defaultExport

    private struct ExportViewData {
        var name: String
        var kind: DXFDrawingViewKind
        var layers: [Layer]
        var blocks: [CADBlock]
        var entities: [CADEntity]
        var textStyles: [String: CADTextStyle]
        var linetypePatterns: [String: [Double]]
        var unit: CADUnit
    }


    private struct ProjectionXDataPair: Hashable {
        var key: String
        var value: XDataValue
    }

    private struct ProjectionEntityKey: Hashable {
        var layerID: UUID
        var blockID: UUID?
        var geometry: [CADPrimitive]?
        var arrayData: CADArrayData?
        var xdata: [ProjectionXDataPair]
    }

    private struct SheetExportPlan {
        var entities: [CADEntity]
        var viewports: [DXFViewportEntity]
        var minimumLimits: Vector3
        var maximumLimits: Vector3
    }

    public static func export(
        document: CADDocument,
        to url: URL,
        dxfVersion: DXFVersion = .defaultExport
    ) throws {
        let view = ExportViewData(
            name: "Model",
            kind: .model,
            layers: document.allLayers,
            blocks: document.allBlocks,
            entities: document.allEntities,
            textStyles: document.textStyles,
            linetypePatterns: document.linetypePatterns,
            unit: document.unit)
        try exportToDXF(views: [view], filePath: url.path, dxfVersion: dxfVersion)
    }

    public static func export(
        views: [DrawingView],
        to url: URL,
        dxfVersion: DXFVersion = .defaultExport
    ) throws {
        let exportViews = views.map {
            ExportViewData(
                name: $0.name,
                kind: $0.kind,
                layers: $0.document.allLayers,
                blocks: $0.document.allBlocks,
                entities: $0.document.allEntities,
                textStyles: $0.document.textStyles,
                linetypePatterns: $0.document.linetypePatterns,
                unit: $0.document.unit)
        }
        try exportToDXF(views: exportViews, filePath: url.path, dxfVersion: dxfVersion)
    }

    public static func exportToDXF(
        layers: [Layer],
        blocks: [CADBlock],
        entities: [CADEntity],
        textStyleFonts: [String: String] = [:],
        linetypePatterns: [String: [Double]] = [:],
        filePath: String,
        dxfVersion: DXFVersion = .defaultExport
    ) throws {
        let view = ExportViewData(
            name: "Model",
            kind: .model,
            layers: layers,
            blocks: blocks,
            entities: entities,
            textStyles: Dictionary(uniqueKeysWithValues: textStyleFonts.map { name, font in
                (name, CADTextStyle(name: name, fontFile: font))
            }),
            linetypePatterns: linetypePatterns,
            unit: .millimeter)
        try exportToDXF(views: [view], filePath: filePath, dxfVersion: dxfVersion)
    }

    private static func exportToDXF(
        views sourceViews: [ExportViewData],
        filePath: String,
        dxfVersion: DXFVersion = .defaultExport
    ) throws {
        guard !sourceViews.isEmpty else {
            throw DXFWriter.WriterError.invalidEntity("Cannot export a DXF without a drawing view")
        }

        let modelView = sourceViews.first(where: { $0.kind == .model }) ?? sourceViews[0]
        var orderedViews = [modelView]
        for view in sourceViews where view.kind == .sheet {
            orderedViews.append(view)
        }

        let writer = DXFWriter()
        writer.version = dxfVersion
        writer.codePage = "ANSI_1252"
        writer.headerVars["$INSUNITS"] = modelView.unit.dxfINSUNITS
        let arrayAppID = DXFAppIdEntry()
        arrayAppID.name = CADArrayDXFCodec.appID
        writer.addAppId(arrayAppID)

        addHeaderExtents(entities: modelView.entities, to: writer)

        var linetypes: [String: [Double]] = [:]
        var linetypeNames = Set<String>()
        var textStyles: [String: CADTextStyle] = [:]
        var textStyleNames = Set<String>()
        for view in orderedViews {
            for (name, pattern) in view.linetypePatterns {
                let key = name.uppercased()
                if linetypeNames.insert(key).inserted { linetypes[name] = pattern }
            }
            for style in view.textStyles.values {
                let key = style.name.uppercased()
                if textStyleNames.insert(key).inserted { textStyles[style.name] = style }
            }
        }
        if textStyleNames.contains("STANDARD") == false {
            textStyles["Standard"] = .standard
        }
        addLinetypes(linetypes, to: writer)
        addTextStyles(textStyles, to: writer)

        var layerNames = Set<String>()
        for view in orderedViews {
            for layer in view.layers {
                let key = layer.name.uppercased()
                guard !key.isEmpty, layerNames.insert(key).inserted else { continue }
                let entry = DXFLayerEntry()
                entry.name = layer.name
                entry.lineType = layer.lineType.isEmpty ? "CONTINUOUS" : layer.lineType
                entry.plotFlag = layer.isPlottable
                entry.color = layer.isVisible
                    ? DXFColorTable.rgbaToACI(layer.color)
                    : -abs(DXFColorTable.rgbaToACI(layer.color))
                entry.color24 = DXFColorTable.rgbaToTrueColor(layer.color) ?? -1
                entry.lWeight = DXFLineWidth.fromDXF(Int((layer.lineWeight * 100.0).rounded()))
                entry.transparency = DXFColorTable.opacityToTransparency(layer.opacity)
                writer.addLayer(entry)
            }
        }

        var blockNameByID: [UUID: String] = [:]
        var exportedBlockNames = Set<String>()
        for view in orderedViews {
            for block in view.blocks where !block.name.isEmpty && !isSpaceBlockName(block.name) {
                blockNameByID[block.handle] = block.name
                let key = block.name.uppercased()
                guard exportedBlockNames.insert(key).inserted else { continue }

                let record = DXFBlockRecordEntry()
                record.name = block.name
                writer.addBlockRecord(record)

                let exported = DXFBlockEntity()
                exported.name = block.name
                exported.basePoint = .zero
                exported.flags = block.dxfFlags
                if block.isInternalTableDisplayBlock {
                    exported.flags |= 1
                }

                let blockHatches = hatchEntities(
                    primitives: block.geometry,
                    primitiveStyles: block.primitiveStyles,
                    primitiveXData: block.primitiveXData,
                    xdata: [:],
                    transform: .identity)
                var consumedHatchIndices = Set<Int>()
                for hatchExport in blockHatches {
                    let hatch = hatchExport.entity
                    applyPrimitiveStyle(hatchExport.style, to: hatch)
                    if hatch.layer.isEmpty { hatch.layer = "0" }
                    exported.entities.append(hatch)
                    consumedHatchIndices.formUnion(hatchExport.primitiveIndices)
                }

                for (index, primitive) in block.geometry.enumerated() {
                    if consumedHatchIndices.contains(index) { continue }
                    guard let entity = primitiveToEntity(
                        primitive,
                        transform: .identity,
                        xdata: block.primitiveXData[index] ?? [:]) else { continue }
                    applyPrimitiveStyle(block.primitiveStyles[index], to: entity)
                    if entity.layer.isEmpty { entity.layer = "0" }
                    exported.entities.append(entity)
                }
                writer.addBlock(exported)
            }
        }

        var sheetPlans: [Int: SheetExportPlan] = [:]
        if orderedViews.count > 1 {
            for viewIndex in 1..<orderedViews.count {
                sheetPlans[viewIndex] = sheetExportPlan(
                    view: orderedViews[viewIndex],
                    modelEntities: modelView.entities)
            }
        }

        writer.addLayout(DXFLayoutDefinition(
            name: "Model",
            blockName: "*Model_Space",
            tabOrder: 0))

        var ownerBlockNames: [String] = ["*Model_Space"]
        for sheetIndex in 0..<max(0, orderedViews.count - 1) {
            let blockName = sheetIndex == 0 ? "*Paper_Space" : "*Paper_Space\(sheetIndex - 1)"
            let viewIndex = sheetIndex + 1
            let view = orderedViews[viewIndex]
            let plan = sheetPlans[viewIndex]
            let limits = plan.map { ($0.minimumLimits, $0.maximumLimits) }
                ?? drawingLimits(for: view.entities)
            writer.addLayout(DXFLayoutDefinition(
                name: view.name.isEmpty ? "Layout\(sheetIndex + 1)" : view.name,
                blockName: blockName,
                tabOrder: sheetIndex + 1,
                minimumLimits: limits.0,
                maximumLimits: limits.1))
            ownerBlockNames.append(blockName)
        }

        for (viewIndex, view) in orderedViews.enumerated() {
            let ownerBlockName = ownerBlockNames[min(viewIndex, ownerBlockNames.count - 1)]
            let isPaperSpace = viewIndex > 0
            let layerNameByID = Dictionary(uniqueKeysWithValues: view.layers.map { ($0.handle, $0.name) })
            let exportEntities = isPaperSpace
                ? (sheetPlans[viewIndex]?.entities ?? view.entities)
                : view.entities

            for entity in exportEntities {
                let layerName = layerNameByID[entity.layerID] ?? "0"

                if let blockID = entity.blockID,
                   let blockName = blockNameByID[blockID] {
                    if let array = entity.arrayData {
                        let groupID = UUID()
                        let payload = CADArrayDXFPayload(
                            groupID: groupID,
                            containerTransform: entity.transform,
                            data: array)
                        let payloadChunks = CADArrayDXFCodec.encode(payload)

                        if canExportAsMInsert(array: array, transform: entity.transform) {
                            let insert = makeInsert(
                                blockName: blockName,
                                layerName: layerName,
                                paperSpace: isPaperSpace,
                                transform: entity.transform)
                            insert.colCount = max(1, array.columns)
                            insert.rowCount = max(1, array.rows)
                            insert.colSpace = array.columnSpacing * insert.xScale
                            insert.rowSpace = -array.rowSpacing * insert.yScale
                            applyEntityStyle(entity.xdata, to: insert)
                            appendArrayXData(
                                to: insert,
                                groupID: groupID,
                                role: "M",
                                payloadChunks: payloadChunks)
                            writer.addEntity(insert, ownerBlockName: ownerBlockName)
                        } else {
                            let instances = array.evaluatedInstances(pathPoints: array.cachedPath)
                            if instances.isEmpty {
                                let insert = makeInsert(
                                    blockName: blockName,
                                    layerName: layerName,
                                    paperSpace: isPaperSpace,
                                    transform: entity.transform)
                                insert.visible = false
                                applyEntityStyle(entity.xdata, to: insert)
                                appendArrayXData(
                                    to: insert,
                                    groupID: groupID,
                                    role: "M",
                                    payloadChunks: payloadChunks)
                                writer.addEntity(insert, ownerBlockName: ownerBlockName)
                            } else {
                                for (instanceIndex, instance) in instances.enumerated() {
                                    let transform = entity.transform.multiplying(by: instance.transform)
                                    let insert = makeInsert(
                                        blockName: blockName,
                                        layerName: layerName,
                                        paperSpace: isPaperSpace,
                                        transform: transform)
                                    applyEntityStyle(entity.xdata, to: insert)
                                    appendArrayXData(
                                        to: insert,
                                        groupID: groupID,
                                        role: instanceIndex == 0 ? "M" : "I",
                                        payloadChunks: instanceIndex == 0 ? payloadChunks : [])
                                    writer.addEntity(insert, ownerBlockName: ownerBlockName)
                                }
                            }
                        }
                    } else {
                        let insert = makeInsert(
                            blockName: blockName,
                            layerName: layerName,
                            paperSpace: isPaperSpace,
                            transform: entity.transform)
                        applyEntityStyle(entity.xdata, to: insert)
                        writer.addEntity(insert, ownerBlockName: ownerBlockName)
                    }
                    continue
                }

                guard let primitives = entity.localGeometry else { continue }
                let hatchExports = hatchEntities(
                    primitives: primitives,
                    primitiveStyles: [:],
                    primitiveXData: [:],
                    xdata: entity.xdata,
                    transform: entity.transform)

                var consumedHatchIndices = Set<Int>()
                for hatchExport in hatchExports {
                    let hatch = hatchExport.entity
                    hatch.layer = layerName
                    hatch.space = isPaperSpace ? 1 : 0
                    applyEntityStyle(entity.xdata, to: hatch)
                    writer.addEntity(hatch, ownerBlockName: ownerBlockName)
                    consumedHatchIndices.formUnion(hatchExport.primitiveIndices)
                }

                for (primitiveIndex, primitive) in primitives.enumerated() {
                    if consumedHatchIndices.contains(primitiveIndex) { continue }
                    guard let exported = primitiveToEntity(
                        primitive,
                        transform: entity.transform,
                        xdata: entity.xdata) else { continue }
                    exported.layer = layerName
                    exported.space = isPaperSpace ? 1 : 0
                    applyEntityStyle(entity.xdata, to: exported)
                    writer.addEntity(exported, ownerBlockName: ownerBlockName)
                }
            }

            if isPaperSpace, let plan = sheetPlans[viewIndex] {
                for viewport in plan.viewports {
                    viewport.space = 1
                    writer.addEntity(viewport, ownerBlockName: ownerBlockName)
                }
            }
        }

        let content = normalizeLinetypeRecords(
            writer.writeToString(),
            includeElementType: dxfVersion != .r10 && dxfVersion != .r12
        )
        let encoding: String.Encoding = writer.codePage == "UTF-8" ? .utf8 : .isoLatin1
        guard let data = content.data(using: encoding, allowLossyConversion: false) else {
            throw DXFWriter.WriterError.writeError(
                "Cannot encode DXF using \(writer.codePage)"
            )
        }
        try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    private static func normalizeLinetypeRecords(
        _ content: String,
        includeElementType: Bool
    ) -> String {
        var lines = content.components(separatedBy: "\r\n")
        guard lines.count > 2 else { return content }

        let hasTrailingLineBreak = lines.last?.isEmpty == true
        if hasTrailingLineBreak {
            lines.removeLast()
        }

        var output: [String] = []
        output.reserveCapacity(lines.count + 64)

        var index = 0
        while index + 1 < lines.count {
            let codeLine = lines[index]
            let valueLine = lines[index + 1]
            let code = Int(codeLine.trimmingCharacters(in: .whitespaces))

            guard code == 0,
                  valueLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("LTYPE") == .orderedSame else {
                output.append(codeLine)
                output.append(valueLine)
                index += 2
                continue
            }

            var record: [(code: String, value: String)] = [(codeLine, valueLine)]
            index += 2
            while index + 1 < lines.count {
                let nextCode = Int(lines[index].trimmingCharacters(in: .whitespaces))
                if nextCode == 0 { break }
                record.append((lines[index], lines[index + 1]))
                index += 2
            }

            let hasDescription = record.contains {
                Int($0.code.trimmingCharacters(in: .whitespaces)) == 3
            }
            var descriptionInserted = hasDescription

            for recordIndex in record.indices {
                let pair = record[recordIndex]
                let pairCode = Int(pair.code.trimmingCharacters(in: .whitespaces))

                if pairCode == 72, !descriptionInserted {
                    output.append("  3")
                    output.append("")
                    descriptionInserted = true
                }

                output.append(pair.code)
                output.append(pair.value)

                if includeElementType, pairCode == 49 {
                    let nextPairCode: Int? = recordIndex + 1 < record.count
                        ? Int(record[recordIndex + 1].code.trimmingCharacters(in: .whitespaces))
                        : nil
                    if nextPairCode != 74 {
                        output.append(" 74")
                        output.append("0")
                    }
                }
            }
        }

        if index < lines.count {
            output.append(contentsOf: lines[index...])
        }

        var normalized = output.joined(separator: "\r\n")
        if hasTrailingLineBreak {
            normalized += "\r\n"
        }
        return normalized
    }

    private static func sheetExportPlan(
        view: ExportViewData,
        modelEntities: [CADEntity]
    ) -> SheetExportPlan {
        let markedIndices = Set(view.entities.indices.filter {
            xdataInt(view.entities[$0].xdata, "dxf.viewport.projected") == 1
        })

        var projectedIndices = markedIndices
        var viewports = exactViewports(from: markedIndices.map { view.entities[$0] })

        if projectedIndices.isEmpty,
           let inferred = inferProjectedEntities(
            sheetEntities: view.entities,
            modelEntities: modelEntities) {
            projectedIndices = inferred.indices
            viewports = [makeViewport(
                projection: inferred.projection,
                projectedEntities: inferred.indices.map { view.entities[$0] },
                layerNames: Set(view.layers.map { $0.name.uppercased() }))]
        } else if viewports.isEmpty,
                  let projection = projectionFromMarkedEntities(
                    markedIndices.map { view.entities[$0] },
                    modelEntities: modelEntities) {
            viewports = [makeViewport(
                projection: projection,
                projectedEntities: markedIndices.map { view.entities[$0] },
                layerNames: Set(view.layers.map { $0.name.uppercased() }))]
        }

        let paperEntities = view.entities.enumerated().compactMap {
            projectedIndices.contains($0.offset) ? nil : $0.element
        }

        if !viewports.isEmpty {
            let systemViewport = makeSystemViewport(
                userViewports: viewports,
                paperEntities: paperEntities)
            viewports.insert(systemViewport, at: 0)
        }

        let limits = sheetLimits(
            paperEntities: paperEntities,
            viewports: viewports)
        return SheetExportPlan(
            entities: paperEntities,
            viewports: viewports,
            minimumLimits: limits.min,
            maximumLimits: limits.max)
    }

    private static func exactViewports(from entities: [CADEntity]) -> [DXFViewportEntity] {
        var result: [DXFViewportEntity] = []
        var signatures = Set<String>()

        for entity in entities {
            let xdata = entity.xdata
            guard xdataInt(xdata, "dxf.viewport.synthetic") != 1,
                  let paperCenterX = xdataDouble(xdata, "dxf.viewport.paperCenterX"),
                  let paperCenterY = xdataDouble(xdata, "dxf.viewport.paperCenterY"),
                  let paperWidth = xdataDouble(xdata, "dxf.viewport.paperWidth"),
                  let paperHeight = xdataDouble(xdata, "dxf.viewport.paperHeight"),
                  let viewCenterX = xdataDouble(xdata, "dxf.viewport.viewCenterX"),
                  let viewCenterY = xdataDouble(xdata, "dxf.viewport.viewCenterY"),
                  let viewTargetX = xdataDouble(xdata, "dxf.viewport.viewTargetX"),
                  let viewTargetY = xdataDouble(xdata, "dxf.viewport.viewTargetY"),
                  let viewHeight = xdataDouble(xdata, "dxf.viewport.viewHeight") else {
                continue
            }

            let id = xdataInt(xdata, "dxf.viewport.id") ?? 2
            let status = xdataInt(xdata, "dxf.viewport.status") ?? max(2, id)
            let twist = xdataDouble(xdata, "dxf.viewport.twistDegrees") ?? 0
            let signature = [
                String(id), String(status),
                String(format: "%.12g", paperCenterX),
                String(format: "%.12g", paperCenterY),
                String(format: "%.12g", paperWidth),
                String(format: "%.12g", paperHeight),
                String(format: "%.12g", viewCenterX),
                String(format: "%.12g", viewCenterY),
                String(format: "%.12g", viewTargetX),
                String(format: "%.12g", viewTargetY),
                String(format: "%.12g", viewHeight),
                String(format: "%.12g", twist)
            ].joined(separator: "|")
            guard signatures.insert(signature).inserted else { continue }

            let viewport = DXFViewportEntity()
            viewport.layer = xdataString(xdata, "dxf.viewport.layer") ?? "MODEL"
            viewport.space = 1
            viewport.basePoint = Vector3(x: paperCenterX, y: paperCenterY, z: 0)
            viewport.psWidth = max(abs(paperWidth), 1e-9)
            viewport.psHeight = max(abs(paperHeight), 1e-9)
            viewport.vpStatus = status
            viewport.vpID = id
            viewport.centerPX = viewCenterX
            viewport.centerPY = viewCenterY
            viewport.viewTarget = Vector3(x: viewTargetX, y: viewTargetY, z: 0)
            viewport.viewHeight = max(abs(viewHeight), 1e-9)
            viewport.twistAngle = twist
            result.append(viewport)
        }

        return result.sorted { lhs, rhs in
            if lhs.vpID != rhs.vpID { return lhs.vpID < rhs.vpID }
            return lhs.vpStatus < rhs.vpStatus
        }
    }

    private static func projectionFromMarkedEntities(
        _ sheetEntities: [CADEntity],
        modelEntities: [CADEntity]
    ) -> Transform3D? {
        if let raw = sheetEntities.compactMap({
            xdataString($0.xdata, "dxf.viewport.projection")
        }).first,
           let projection = transformFromString(raw) {
            return projection
        }
        return inferProjectedEntities(
            sheetEntities: sheetEntities,
            modelEntities: modelEntities)?.projection
    }

    private static func transformFromString(_ value: String) -> Transform3D? {
        let values = value.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard values.count == 16 else { return nil }
        return Transform3D(raw: values)
    }

    private static func projectionKey(_ entity: CADEntity) -> ProjectionEntityKey {
        let metadata = entity.xdata
            .filter { !$0.key.hasPrefix("dxf.viewport.") }
            .map { ProjectionXDataPair(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
        return ProjectionEntityKey(
            layerID: entity.layerID,
            blockID: entity.blockID,
            geometry: entity.localGeometry,
            arrayData: entity.arrayData,
            xdata: metadata)
    }

    private static func inferProjectedEntities(
        sheetEntities: [CADEntity],
        modelEntities: [CADEntity]
    ) -> (indices: Set<Int>, projection: Transform3D)? {
        guard !sheetEntities.isEmpty, !modelEntities.isEmpty else { return nil }

        var modelByKey: [ProjectionEntityKey: [Int]] = [:]
        for (index, entity) in modelEntities.enumerated() {
            modelByKey[projectionKey(entity), default: []].append(index)
        }
        var sheetByKey: [ProjectionEntityKey: [Int]] = [:]
        for (index, entity) in sheetEntities.enumerated() {
            sheetByKey[projectionKey(entity), default: []].append(index)
        }

        var representatives: [String: (count: Int, projection: Transform3D)] = [:]
        for (key, sheetIndices) in sheetByKey {
            guard sheetIndices.count == 1,
                  let modelIndices = modelByKey[key], modelIndices.count == 1 else { continue }
            let projection = sheetEntities[sheetIndices[0]].transform
                .multiplying(by: modelEntities[modelIndices[0]].transform.inverse())
            let fingerprint = transformFingerprint(projection)
            if var existing = representatives[fingerprint] {
                existing.count += 1
                representatives[fingerprint] = existing
            } else {
                representatives[fingerprint] = (1, projection)
            }
        }

        guard let dominant = representatives.values.max(by: { $0.count < $1.count }),
              dominant.count >= 8 else { return nil }
        let projection = dominant.projection

        var projected = Set<Int>()
        for (key, sheetIndices) in sheetByKey {
            guard let modelIndices = modelByKey[key] else { continue }
            for sheetIndex in sheetIndices {
                let sheetTransform = sheetEntities[sheetIndex].transform
                if modelIndices.contains(where: { modelIndex in
                    let candidate = sheetTransform.multiplying(
                        by: modelEntities[modelIndex].transform.inverse())
                    return transformsNearlyEqual(candidate, projection)
                }) {
                    projected.insert(sheetIndex)
                }
            }
        }

        guard projected.count >= max(20, dominant.count) else { return nil }
        return (projected, projection)
    }

    private static func transformFingerprint(_ transform: Transform3D) -> String {
        transform.rawElements.map {
            String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), $0)
        }.joined(separator: ",")
    }

    private static func transformsNearlyEqual(
        _ lhs: Transform3D,
        _ rhs: Transform3D
    ) -> Bool {
        let a = lhs.rawElements
        let b = rhs.rawElements
        for index in 0..<16 {
            let scale = max(1.0, max(abs(a[index]), abs(b[index])))
            if abs(a[index] - b[index]) > scale * 2e-7 { return false }
        }
        return true
    }

    private static func makeViewport(
        projection: Transform3D,
        projectedEntities: [CADEntity],
        layerNames: Set<String>
    ) -> DXFViewportEntity {
        let bounds = entityBounds(projectedEntities)
            ?? BoundingBox3D(min: .zero, max: Vector3(x: 12, y: 9, z: 0))
        let rawSize = bounds.size
        let margin = max(max(abs(rawSize.x), abs(rawSize.y)) * 0.02, 1e-3)
        let paperBounds = bounds.expanded(by: margin)
        let paperCenter = paperBounds.center
        let paperWidth = max(abs(paperBounds.size.x), 1e-6)
        let paperHeight = max(abs(paperBounds.size.y), 1e-6)
        let xScale = transformedVector(Vector3(x: 1, y: 0, z: 0), by: projection).magnitude
        let yScale = transformedVector(Vector3(x: 0, y: 1, z: 0), by: projection).magnitude
        let scale = max((xScale + yScale) * 0.5, 1e-12)
        let modelCenter = projection.inverse().transformPoint(paperCenter)

        let viewport = DXFViewportEntity()
        viewport.layer = layerNames.contains("MODEL") ? "MODEL" : "0"
        viewport.space = 1
        viewport.basePoint = toDXF(paperCenter)
        viewport.psWidth = paperWidth
        viewport.psHeight = paperHeight
        viewport.vpStatus = 2
        viewport.vpID = 2
        viewport.centerPX = modelCenter.x
        viewport.centerPY = -modelCenter.y
        viewport.viewTarget = .zero
        viewport.viewHeight = paperHeight / scale
        viewport.twistAngle = projection.rotation * 180.0 / .pi
        return viewport
    }

    private static func makeSystemViewport(
        userViewports: [DXFViewportEntity],
        paperEntities: [CADEntity]
    ) -> DXFViewportEntity {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for viewport in userViewports {
            minX = min(minX, viewport.basePoint.x - viewport.psWidth * 0.5)
            minY = min(minY, viewport.basePoint.y - viewport.psHeight * 0.5)
            maxX = max(maxX, viewport.basePoint.x + viewport.psWidth * 0.5)
            maxY = max(maxY, viewport.basePoint.y + viewport.psHeight * 0.5)
        }
        let paperLimits = drawingLimits(for: paperEntities)
        if !paperEntities.isEmpty {
            minX = min(minX, paperLimits.min.x)
            minY = min(minY, paperLimits.min.y)
            maxX = max(maxX, paperLimits.max.x)
            maxY = max(maxY, paperLimits.max.y)
        }
        if !minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite {
            minX = 0; minY = 0; maxX = 12; maxY = 9
        }

        let width = max(maxX - minX, 1e-6)
        let height = max(maxY - minY, 1e-6)
        let viewport = DXFViewportEntity()
        viewport.layer = "0"
        viewport.space = 1
        viewport.basePoint = Vector3(
            x: (minX + maxX) * 0.5,
            y: (minY + maxY) * 0.5,
            z: 0)
        viewport.psWidth = width
        viewport.psHeight = height
        viewport.vpStatus = 1
        viewport.vpID = 1
        viewport.centerPX = viewport.basePoint.x
        viewport.centerPY = viewport.basePoint.y
        viewport.viewTarget = .zero
        viewport.viewHeight = height
        viewport.twistAngle = 0
        return viewport
    }

    private static func sheetLimits(
        paperEntities: [CADEntity],
        viewports: [DXFViewportEntity]
    ) -> (min: Vector3, max: Vector3) {
        var result = drawingLimits(for: paperEntities)
        if paperEntities.isEmpty {
            result = (.zero, Vector3(x: 12, y: 9, z: 0))
        }
        for viewport in viewports {
            let minimum = Vector3(
                x: viewport.basePoint.x - viewport.psWidth * 0.5,
                y: viewport.basePoint.y - viewport.psHeight * 0.5,
                z: 0)
            let maximum = Vector3(
                x: viewport.basePoint.x + viewport.psWidth * 0.5,
                y: viewport.basePoint.y + viewport.psHeight * 0.5,
                z: 0)
            result.min.x = min(result.min.x, minimum.x)
            result.min.y = min(result.min.y, minimum.y)
            result.max.x = max(result.max.x, maximum.x)
            result.max.y = max(result.max.y, maximum.y)
        }
        return result
    }

    private static func entityBounds(_ entities: [CADEntity]) -> BoundingBox3D? {
        var result: BoundingBox3D?
        for entity in entities {
            guard let bounds = entity.worldBoundingBox else { continue }
            result = result.map { $0.union(with: bounds) } ?? bounds
        }
        return result
    }

    private static func isSpaceBlockName(_ name: String) -> Bool {
        let value = name.uppercased()
        return value == "*MODEL_SPACE" || value.hasPrefix("*PAPER_SPACE")
    }

    private static func drawingLimits(for entities: [CADEntity]) -> (min: Vector3, max: Vector3) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        for entity in entities {
            guard let bounds = entity.worldBoundingBox else { continue }
            minX = min(minX, bounds.min.x)
            minY = min(minY, -bounds.max.y)
            maxX = max(maxX, bounds.max.x)
            maxY = max(maxY, -bounds.min.y)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else {
            return (.zero, Vector3(x: 12, y: 9, z: 0))
        }
        return (
            Vector3(x: minX, y: minY, z: 0),
            Vector3(x: maxX, y: maxY, z: 0))
    }

    private static func addHeaderExtents(entities: [CADEntity], to writer: DXFWriter) {
        var minX = Double.infinity
        var minY = Double.infinity
        var minZ = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var maxZ = -Double.infinity

        for entity in entities {
            guard let box = entity.worldBoundingBox else { continue }
            minX = min(minX, box.min.x)
            minY = min(minY, box.min.y)
            minZ = min(minZ, box.min.z)
            maxX = max(maxX, box.max.x)
            maxY = max(maxY, box.max.y)
            maxZ = max(maxZ, box.max.z)
        }

        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return }
        writer.headerVars["$EXTMIN"] = Vector3(x: minX, y: -maxY, z: minZ.isFinite ? minZ : 0)
        writer.headerVars["$EXTMAX"] = Vector3(x: maxX, y: -minY, z: maxZ.isFinite ? maxZ : 0)
    }

    private static func addLinetypes(_ patterns: [String: [Double]], to writer: DXFWriter) {
        for (name, path) in patterns where !name.isEmpty {
            let entry = DXFLTypeEntry()
            entry.name = name
            entry.path = path
            entry.size = path.count
            entry.length = path.reduce(0) { $0 + abs($1) }
            writer.addLType(entry)
        }
    }

    private static func addTextStyles(_ styles: [String: CADTextStyle], to writer: DXFWriter) {
        for style in styles.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) where !style.name.isEmpty {
            let normalized = style.normalized
            let entry = DXFStyleEntry()
            entry.name = normalized.name
            entry.font = normalized.fontFile
            entry.height = normalized.fixedHeight
            entry.width = normalized.widthFactor
            entry.oblique = normalized.obliqueAngle
            entry.lastHeight = normalized.fixedHeight > 0 ? normalized.fixedHeight : 2.5
            writer.addTextStyle(entry)
        }
    }



    private struct HatchRegion {
        var outer: CADPolyline
        var holes: [CADPolyline]
    }

    private struct HatchEntityExport {
        var entity: DXFHatchEntity
        var primitiveIndices: [Int]
        var style: CADPrimitiveStyle?
    }

    private enum HatchGroupKey: Hashable {
        case path(String, Double, Double, ColorRGBA?, ColorRGBA?, CADPrimitiveStyle?)
        case legacy(String, Double, Double, ColorRGBA?, ColorRGBA?, CADPrimitiveStyle?)
        case solid(ColorRGBA?, CADPrimitiveStyle?)
        case gradient(String, Double, ColorRGBA, ColorRGBA, CADPrimitiveStyle?)
    }

    private static func hatchEntities(
        primitives: [CADPrimitive],
        primitiveStyles: [Int: CADPrimitiveStyle],
        primitiveXData: [Int: [String: XDataValue]],
        xdata: [String: XDataValue],
        transform: Transform3D
    ) -> [HatchEntityExport] {
        var result: [HatchEntityExport] = []
        var index = 0

        while index < primitives.count {
            let style = primitiveStyles[index]
            guard let key = hatchGroupKey(primitives[index], style: style) else {
                index += 1
                continue
            }
            let groupXData = primitiveXData[index] ?? xdata

            var groupedPrimitives = [primitives[index]]
            var groupedIndices = [index]
            var sawBoundaryCarrier = false
            index += 1

            while index < primitives.count {
                let primitive = primitives[index]
                if isHatchBoundaryCarrier(primitive) {
                    groupedPrimitives.append(primitive)
                    groupedIndices.append(index)
                    sawBoundaryCarrier = true
                    index += 1
                    continue
                }

                guard let nextKey = hatchGroupKey(
                    primitive,
                    style: primitiveStyles[index]) else { break }
                guard !sawBoundaryCarrier,
                      nextKey == key,
                      (primitiveXData[index] ?? xdata) == groupXData else { break }

                groupedPrimitives.append(primitive)
                groupedIndices.append(index)
                index += 1
            }

            if let hatch = combinedHatchEntity(
                primitives: groupedPrimitives,
                xdata: groupXData,
                transform: transform) {
                result.append(HatchEntityExport(
                    entity: hatch,
                    primitiveIndices: groupedIndices,
                    style: style))
            }
        }

        return result
    }

    private static func hatchGroupKey(
        _ primitive: CADPrimitive,
        style: CADPrimitiveStyle?
    ) -> HatchGroupKey? {
        switch primitive {
        case .hatchPath(_, _, let pattern, let scale, let angle, let color, let background):
            return .path(pattern, scale, angle, color, background, style)
        case .hatch(_, let pattern, let scale, let angle, let color, let background):
            return .legacy(pattern, scale, angle, color, background, style)
        case .fillComplexPolygon(_, _, let color):
            return .solid(color, style)
        case .gradient(_, _, let name, let angle, let color1, let color2):
            return .gradient(name, angle, color1, color2, style)
        default:
            return nil
        }
    }

    private static func isHatchBoundaryCarrier(_ primitive: CADPrimitive) -> Bool {
        guard case .polyline(let path, _) = primitive else { return false }
        return path.isHatchBoundaryCarrier
    }

    private static func combinedHatchEntity(
        primitives: [CADPrimitive],
        xdata: [String: XDataValue],
        transform: Transform3D
    ) -> DXFHatchEntity? {
        let hatchPaths = primitives.compactMap { primitive -> (region: HatchRegion, pattern: String, scale: Double, angle: Double, color: ColorRGBA?, background: ColorRGBA?)? in
            guard case .hatchPath(let outer, let holes, let pattern, let scale, let angle, let color, let background) = primitive else {
                return nil
            }
            return (HatchRegion(outer: outer, holes: holes), pattern, scale, angle, color, background)
        }

        let legacyHatches = primitives.compactMap { primitive -> (region: HatchRegion, pattern: String, scale: Double, angle: Double, color: ColorRGBA?, background: ColorRGBA?)? in
            guard case .hatch(let boundary, let pattern, let scale, let angle, let color, let background) = primitive else {
                return nil
            }
            return (
                splitConnectedHatchBoundary(boundary),
                pattern, scale, angle, color, background)
        }

        let gradients = primitives.compactMap { primitive -> (outer: [Vector3], holes: [[Vector3]], name: String, angle: Double, color1: ColorRGBA, color2: ColorRGBA)? in
            guard case .gradient(let outer, let holes, let name, let angle, let color1, let color2) = primitive else {
                return nil
            }
            return (outer, holes, name, angle, color1, color2)
        }

        let carriers = primitives.compactMap { primitive -> CADPolyline? in
            guard case .polyline(let path, _) = primitive, path.isHatchBoundaryCarrier else { return nil }
            return path
        }

        let solidRegions = primitives.compactMap { primitive -> (outer: [Vector3], holes: [[Vector3]], color: ColorRGBA?)? in
            guard case .fillComplexPolygon(let outer, let holes, let color) = primitive else { return nil }
            return (outer, holes, color)
        }

        let hatch = DXFHatchEntity()
        hatch.associative = xdataInt(xdata, "dxf.hatchAssociative") ?? 0
        hatch.hStyle = xdataInt(xdata, "dxf.hatchStyle") ?? 0
        hatch.hPattern = xdataInt(xdata, "dxf.hatchPatternDefinitionType") ?? 1
        hatch.doubleFlag = xdataInt(xdata, "dxf.hatchDouble") ?? 0
        hatch.patternLines = patternLines(from: xdata)

        var regions: [HatchRegion] = []
        var primaryColor: ColorRGBA?
        var patternDefinitionName: String?

        if let firstGradient = gradients.first {
            hatch.name = "SOLID"
            hatch.solid = 1
            hatch.isGradient = 1
            hatch.gradientName = xdataString(xdata, "dxf.hatchGradientName")
                ?? (firstGradient.name.isEmpty ? "LINEAR" : firstGradient.name)
            let gradientAngleRadians = xdataDouble(xdata, "dxf.hatchGradientAngle") ?? firstGradient.angle
            hatch.gradientAngle = -gradientAngleRadians * 180.0 / .pi
            hatch.gradientShift = xdataDouble(xdata, "dxf.hatchGradientShift") ?? 0.0
            hatch.gradientTint = xdataDouble(xdata, "dxf.hatchGradientTint") ?? 0.0
            hatch.singleColorGrad = xdataInt(xdata, "dxf.hatchGradientSingleColor") ?? 0
            hatch.gradientColors = gradientStops(from: xdata)
            if hatch.gradientColors.isEmpty {
                hatch.gradientColors = [
                    gradientStop(position: 0.0, color: firstGradient.color1),
                    gradientStop(position: 1.0, color: firstGradient.color2)
                ]
            }
            primaryColor = firstGradient.color1
            if !carriers.isEmpty {
                regions = classifyHatchPaths(carriers)
            } else {
                regions = gradients.map {
                    HatchRegion(
                        outer: CADPolyline(points: $0.outer, isClosed: true),
                        holes: $0.holes.map { CADPolyline(points: $0, isClosed: true) })
                }
            }
        } else if let first = hatchPaths.first {
            hatch.name = xdataString(xdata, "dxf.hatchPatternName")
                ?? (first.pattern.isEmpty ? "SOLID" : first.pattern)
            hatch.solid = hatch.name.uppercased() == "SOLID" ? 1 : 0
            hatch.scale = xdataDouble(xdata, "dxf.hatchScale") ?? first.scale
            let hatchAngleRadians = xdataDouble(xdata, "dxf.hatchAngle") ?? first.angle
            hatch.angle_p = -hatchAngleRadians * 180.0 / .pi
            if xdata["dxf.hatchPatternDefinitionType"] == nil {
                hatch.hPattern = DXFHatchGenerator.predefinedPatterns[hatch.name.uppercased()] == nil ? 0 : 1
            }
            if let background = first.background ?? solidRegions.first?.color {
                hatch.bgColor = DXFColorTable.rgbaToACI(background)
            }
            primaryColor = first.color
            patternDefinitionName = first.pattern
            regions = hatchPaths.map(\.region)
        } else if let first = legacyHatches.first {
            hatch.name = xdataString(xdata, "dxf.hatchPatternName")
                ?? (first.pattern.isEmpty ? "SOLID" : first.pattern)
            hatch.solid = hatch.name.uppercased() == "SOLID" ? 1 : 0
            hatch.scale = xdataDouble(xdata, "dxf.hatchScale") ?? first.scale
            let hatchAngleRadians = xdataDouble(xdata, "dxf.hatchAngle") ?? first.angle
            hatch.angle_p = -hatchAngleRadians * 180.0 / .pi
            if xdata["dxf.hatchPatternDefinitionType"] == nil {
                hatch.hPattern = DXFHatchGenerator.predefinedPatterns[hatch.name.uppercased()] == nil ? 0 : 1
            }
            if let background = first.background { hatch.bgColor = DXFColorTable.rgbaToACI(background) }
            primaryColor = first.color
            patternDefinitionName = first.pattern
            regions = legacyHatches.map(\.region)
        } else if !solidRegions.isEmpty {
            hatch.name = "SOLID"
            hatch.solid = 1
            primaryColor = solidRegions.first?.color
            if !carriers.isEmpty {
                regions = classifyHatchPaths(carriers)
            } else {
                regions = solidRegions.map {
                    HatchRegion(
                        outer: CADPolyline(points: $0.outer, isClosed: true),
                        holes: $0.holes.map { CADPolyline(points: $0, isClosed: true) })
                }
            }
        } else {
            return nil
        }

        if hatch.solid == 0,
           let definition = DXFHatchGenerator.patternDefinition(
                for: patternDefinitionName ?? hatch.name),
           !definition.lines.isEmpty {
            hatch.patternLines = serializedPatternLines(
                definition.lines,
                scale: hatch.scale,
                hatchAngleDegrees: hatch.angle_p)
        }

        for region in regions {
            if let outerLoop = makeHatchLoop(path: region.outer, isOuter: true, transform: transform) {
                hatch.loops.append(outerLoop)
            }
            for hole in region.holes {
                if let holeLoop = makeHatchLoop(path: hole, isOuter: false, transform: transform) {
                    hatch.loops.append(holeLoop)
                }
            }
        }
        guard !hatch.loops.isEmpty else { return nil }
        hatch.loopsNum = hatch.loops.count
        applyColor(primaryColor, to: hatch)
        return hatch
    }

    private static func isHatchComponent(_ primitive: CADPrimitive) -> Bool {
        switch primitive {
        case .hatch, .hatchPath, .gradient, .fillComplexPolygon:
            return true
        case .polyline(let path, _):
            return path.isHatchBoundaryCarrier
        default:
            return false
        }
    }

    private static func makeHatchLoop(
        path: CADPolyline,
        isOuter: Bool,
        transform: Transform3D
    ) -> DXFHatchLoop? {
        if !path.hatchEdges.isEmpty {
            let entities = path.hatchEdges.compactMap { hatchEdgeEntity($0, transform: transform) }
            if entities.count == path.hatchEdges.count {
                let loopType = (path.hatchLoopType ?? (isOuter ? 1 : 0)) & ~2
                let loop = DXFHatchLoop(type: loopType)
                loop.entities = entities
                loop.numEdges = entities.count
                return loop
            }
        }

        let sourcePath: CADPolyline
        if !path.hatchEdges.isEmpty {
            let points = cleanLoop(path.tessellatedPoints()).map { transform.transformPoint($0) }
            sourcePath = CADPolyline(points: points, isClosed: true)
        } else {
            sourcePath = path.transformed(by: transform)
        }
        guard sourcePath.vertices.count >= 2 else { return nil }

        let loop = DXFHatchLoop(type: (path.hatchLoopType ?? (isOuter ? 1 : 0)) | 2)
        let polyline = DXFLWPolylineEntity()
        polyline.flags = sourcePath.isClosed ? 1 : 0
        polyline.vertexCount = sourcePath.vertices.count
        for vertex in sourcePath.vertices {
            let value = DXFVertex2D()
            let point = toDXF(vertex.position)
            value.x = point.x
            value.y = point.y
            value.bulge = -vertex.bulge
            value.startWidth = vertex.startWidth
            value.endWidth = vertex.endWidth
            polyline.vertices.append(value)
        }
        loop.entities = [polyline]
        loop.numEdges = sourcePath.vertices.count
        return loop
    }

    private static func hatchEdgeEntity(_ edge: CADHatchEdge, transform: Transform3D) -> DXFEntity? {
        let world = transformedHatchEdge(edge, by: transform)
        switch world {
        case .line(let start, let end):
            let line = DXFLineEntity()
            line.basePoint = toDXF(start)
            line.secPoint = toDXF(end)
            return line

        case .circularArc(let center, let radius, let startAngle, let sweep):
            guard radius > 1e-12, abs(sweep) > 1e-12 else { return nil }
            let arc = DXFArcEntity()
            arc.basePoint = toDXF(center)
            arc.radius = radius
            let cadStart = Vector3(
                x: center.x + radius * cos(startAngle),
                y: center.y + radius * sin(startAngle),
                z: center.z)
            let cadEnd = Vector3(
                x: center.x + radius * cos(startAngle + sweep),
                y: center.y + radius * sin(startAngle + sweep),
                z: center.z)
            let dxfStart = toDXF(cadStart) - arc.basePoint
            let dxfEnd = toDXF(cadEnd) - arc.basePoint
            arc.startAngle = atan2(dxfStart.y, dxfStart.x)
            arc.endAngle = atan2(dxfEnd.y, dxfEnd.x)
            arc.isCCW = sweep >= 0 ? 0 : 1
            return arc

        case .ellipticalArc(let center, let axisU, let axisV, let startParam, let sweep):
            let uLength = axisU.magnitude
            let vLength = axisV.magnitude
            let denominator = max(uLength * vLength, 1e-12)
            guard uLength > 1e-12, vLength > 1e-12,
                  abs(axisU.dot(axisV)) / denominator < 1e-5 else { return nil }
            let ellipse = DXFEllipseEntity()
            ellipse.basePoint = toDXF(center)
            ellipse.secPoint = toDXFVector(axisU)
            ellipse.ratio = vLength / uLength
            ellipse.startParam = startParam
            ellipse.endParam = startParam + sweep
            ellipse.isCCW = sweep >= 0 ? 0 : 1
            return ellipse

        case .spline(let controlPoints, let knots, let degree, let weights, let closed, let periodic):
            guard controlPoints.count >= 2 else { return nil }
            let spline = DXFSplineEntity()
            spline.controlPoints = controlPoints.map(toDXF)
            spline.knots = knots
            spline.degree = degree
            spline.weights = weights ?? []
            spline.flags = (closed ? 1 : 0) | (periodic ? 2 : 0) | (weights == nil ? 0 : 4)
            spline.nControl = Int32(controlPoints.count)
            spline.nKnots = Int32(knots.count)
            return spline
        }
    }

    private static func transformedHatchEdge(_ edge: CADHatchEdge, by transform: Transform3D) -> CADHatchEdge {
        switch edge {
        case .circularArc(let center, let radius, let startAngle, let sweep):
            let worldCenter = transform.transformPoint(center)
            let axisU = transform.transformPoint(center + Vector3(x: radius, y: 0, z: 0)) - worldCenter
            let axisV = transform.transformPoint(center + Vector3(x: 0, y: radius, z: 0)) - worldCenter
            let lengthU = axisU.magnitude
            let lengthV = axisV.magnitude
            let denominator = max(lengthU * lengthV, 1e-12)
            if abs(lengthU - lengthV) <= max(lengthU, lengthV) * 1e-6,
               abs(axisU.dot(axisV)) / denominator < 1e-6 {
                let sourceStart = Vector3(
                    x: center.x + cos(startAngle) * radius,
                    y: center.y + sin(startAngle) * radius,
                    z: center.z)
                let worldStart = transform.transformPoint(sourceStart)
                let transformedStart = atan2(worldStart.y - worldCenter.y, worldStart.x - worldCenter.x)
                let orientation = axisU.cross(axisV).z >= 0 ? 1.0 : -1.0
                return .circularArc(
                    center: worldCenter,
                    radius: (lengthU + lengthV) * 0.5,
                    startAngle: transformedStart,
                    sweep: sweep * orientation)
            }
            return .ellipticalArc(
                center: worldCenter,
                axisU: axisU,
                axisV: axisV,
                startParam: startAngle,
                sweep: sweep)

        default:
            return transform == .identity ? edge : edge.transformed(by: transform)
        }
    }

    private static func classifyHatchPaths(_ paths: [CADPolyline]) -> [HatchRegion] {
        let candidates = paths.compactMap { path -> (path: CADPolyline, points: [Vector3], area: Double)? in
            let points = cleanLoop(path.tessellatedPoints())
            guard points.count >= 3 else { return nil }
            return (path, points, abs(signedArea(points)))
        }
        guard !candidates.isEmpty else { return [] }

        var parent = Array<Int?>(repeating: nil, count: candidates.count)
        for child in candidates.indices {
            let probe = loopProbe(candidates[child].points)
            var bestParent: Int?
            var bestArea = Double.infinity
            for possibleParent in candidates.indices where possibleParent != child {
                guard candidates[possibleParent].area > candidates[child].area + 1e-9 else { continue }
                let parentPoints = candidates[possibleParent].points
                guard pointInPolygon(probe, parentPoints)
                    || candidates[child].points.contains(where: { pointInPolygon($0, parentPoints) }) else { continue }
                if candidates[possibleParent].area < bestArea {
                    bestParent = possibleParent
                    bestArea = candidates[possibleParent].area
                }
            }
            parent[child] = bestParent
        }

        func depth(_ index: Int) -> Int {
            var value = 0
            var cursor = parent[index]
            var visited = Set<Int>()
            while let current = cursor, visited.insert(current).inserted {
                value += 1
                cursor = parent[current]
            }
            return value
        }

        let depths = candidates.indices.map(depth)
        var children = Array(repeating: [Int](), count: candidates.count)
        for index in candidates.indices {
            if let p = parent[index] { children[p].append(index) }
        }

        return candidates.indices
            .filter { depths[$0] % 2 == 0 }
            .sorted { candidates[$0].area > candidates[$1].area }
            .map { outerIndex in
                let holes = children[outerIndex]
                    .filter { depths[$0] == depths[outerIndex] + 1 }
                    .sorted { candidates[$0].area > candidates[$1].area }
                    .map { candidates[$0].path }
                return HatchRegion(outer: candidates[outerIndex].path, holes: holes)
            }
    }

    private static func serializedPatternLines(
        _ lines: [DXFHatchPatternLine],
        scale: Double,
        hatchAngleDegrees: Double
    ) -> [DXFHatchPatternLineData] {
        let safeScale = scale > 0.0 ? scale : 1.0
        let hatchAngle = -hatchAngleDegrees * .pi / 180.0

        return lines.map { line in
            let lineAngle = hatchAngle + line.angleDegrees * .pi / 180.0
            let cosA = cos(lineAngle)
            let sinA = sin(lineAngle)

            func toDXFPatternSpace(_ value: Vector3) -> Vector3 {
                let x = value.x * safeScale
                let y = value.y * safeScale
                let cadX = x * cosA - y * sinA
                let cadY = x * sinA + y * cosA
                return Vector3(x: cadX, y: -cadY, z: value.z * safeScale)
            }

            return DXFHatchPatternLineData(
                angle: -lineAngle * 180.0 / .pi,
                base: toDXFPatternSpace(line.base),
                offset: toDXFPatternSpace(line.offset),
                dashes: line.dashes.map { $0 * safeScale })
        }
    }

    private static func patternLines(from xdata: [String: XDataValue]) -> [DXFHatchPatternLineData] {
        guard let json = xdataString(xdata, "dxf.hatchPatternLines"),
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return values.compactMap { value in
            guard let angle = (value["angle"] as? NSNumber)?.doubleValue,
                  let baseX = (value["baseX"] as? NSNumber)?.doubleValue,
                  let baseY = (value["baseY"] as? NSNumber)?.doubleValue,
                  let offsetX = (value["offsetX"] as? NSNumber)?.doubleValue,
                  let offsetY = (value["offsetY"] as? NSNumber)?.doubleValue else {
                return nil
            }
            let dashes = (value["dashes"] as? [NSNumber])?.map(\.doubleValue) ?? []
            return DXFHatchPatternLineData(
                angle: angle,
                base: Vector3(x: baseX, y: baseY, z: 0),
                offset: Vector3(x: offsetX, y: offsetY, z: 0),
                dashes: dashes)
        }
    }

    private static func gradientStops(from xdata: [String: XDataValue]) -> [(position: Double, aci: UInt16, rgb: Int32)] {
        guard let json = xdataString(xdata, "dxf.hatchGradientStops"),
              let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return values.compactMap { value in
            guard let position = (value["position"] as? NSNumber)?.doubleValue else { return nil }
            let aci = UInt16(clamping: (value["aci"] as? NSNumber)?.intValue ?? 0)
            let rgb = Int32((value["rgb"] as? NSNumber)?.intValue ?? -1)
            return (position, aci, rgb)
        }
    }

    private static func gradientStop(
        position: Double,
        color: ColorRGBA
    ) -> (position: Double, aci: UInt16, rgb: Int32) {
        let aciValue = DXFColorTable.rgbaToACI(color)
        return (
            position,
            UInt16(clamping: Int(aciValue)),
            DXFColorTable.rgbaToTrueColor(color) ?? -1)
    }

    private static func applyColor(_ color: ColorRGBA?, to entity: DXFEntity) {
        guard let color else { return }
        entity.color = DXFColorTable.rgbaToACI(color)
        entity.color24 = DXFColorTable.rgbaToTrueColor(color) ?? -1
    }

    private static func xdataString(_ xdata: [String: XDataValue], _ key: String) -> String? {
        guard case .string(let value)? = xdata[key] else { return nil }
        return value
    }

    private static func xdataDouble(_ xdata: [String: XDataValue], _ key: String) -> Double? {
        guard let value = xdata[key] else { return nil }
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }

    private static func xdataInt(_ xdata: [String: XDataValue], _ key: String) -> Int? {
        guard let value = xdata[key] else { return nil }
        switch value {
        case .int(let number): return number
        case .double(let number): return Int(number)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    private static func splitConnectedHatchBoundary(_ boundary: [Vector3]) -> HatchRegion {
        var outer = cleanLoop(boundary)
        var holes: [CADPolyline] = []

        while outer.count >= 7 {
            var bridge: (start: Int, close: Int)?

            for start in 1..<(outer.count - 2) {
                let minimumClose = start + 3
                guard minimumClose < outer.count - 1 else { continue }

                for close in minimumClose..<(outer.count - 1) {
                    guard outer[start].distance(to: outer[close]) <= 1e-9,
                          outer[start - 1].distance(to: outer[close + 1]) <= 1e-9 else {
                        continue
                    }
                    bridge = (start, close)
                    break
                }
                if bridge != nil { break }
            }

            guard let bridge else { break }

            let hole = cleanLoop(Array(outer[bridge.start..<bridge.close]))
            if hole.count >= 3 {
                holes.append(CADPolyline(points: hole, isClosed: true))
            }
            outer.removeSubrange(bridge.start...(bridge.close + 1))
            outer = cleanLoop(outer)
        }

        return HatchRegion(
            outer: CADPolyline(points: cleanLoop(outer), isClosed: true),
            holes: holes)
    }

    private static func cleanLoop(_ points: [Vector3]) -> [Vector3] {
        var result: [Vector3] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last, last.distance(to: point) <= 1e-9 { continue }
            result.append(point)
        }
        if result.count > 2, let first = result.first, let last = result.last,
           first.distance(to: last) <= 1e-9 {
            result.removeLast()
        }
        return result
    }

    private static func signedArea(_ points: [Vector3]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = (index + 1) % points.count
            area += points[index].x * points[next].y - points[next].x * points[index].y
        }
        return area * 0.5
    }

    private static func loopProbe(_ points: [Vector3]) -> Vector3 {
        guard let first = points.first else { return .zero }
        let center = points.reduce(Vector3.zero, +) / Double(points.count)
        if pointInPolygon(center, points) { return center }
        guard points.count > 1 else { return first }
        return Vector3(
            x: first.x + (points[1].x - first.x) * 1e-6,
            y: first.y + (points[1].y - first.y) * 1e-6,
            z: first.z)
    }

    private static func pointInPolygon(_ point: Vector3, _ polygon: [Vector3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let denominator = abs(b.y - a.y) < 1e-15 ? 1e-15 : b.y - a.y
                let x = (b.x - a.x) * (point.y - a.y) / denominator + a.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    // MARK: - Primitive → DXFEntity

    private static func primitiveToEntity(
        _ primitive: CADPrimitive,
        transform: Transform3D,
        xdata: [String: XDataValue]
    ) -> DXFEntity? {
        switch primitive {
        case .point(let position, let color):
            let entity = DXFPointEntity()
            entity.basePoint = toDXF(transform.transformPoint(position))
            applyColor(color, to: entity)
            return entity

        case .line(let start, let end, let color):
            let entity = DXFLineEntity()
            entity.basePoint = toDXF(transform.transformPoint(start))
            entity.secPoint = toDXF(transform.transformPoint(end))
            applyColor(color, to: entity)
            return entity

        case .rect(let origin, let size, let color):
            let path = CADPolyline(
                points: [
                    origin,
                    Vector3(x: origin.x + size.x, y: origin.y, z: origin.z),
                    Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z),
                    Vector3(x: origin.x, y: origin.y + size.y, z: origin.z)
                ],
                isClosed: true)
            return polylineEntity(path, color: color, transform: transform)

        case .fillRect(let origin, let size, let color):
            let entity = DXFSolidEntity()
            entity.basePoint = toDXF(transform.transformPoint(origin))
            entity.secPoint = toDXF(transform.transformPoint(Vector3(
                x: origin.x + size.x, y: origin.y, z: origin.z)))
            entity.thirdPoint = toDXF(transform.transformPoint(Vector3(
                x: origin.x, y: origin.y + size.y, z: origin.z)))
            entity.fourPoint = toDXF(transform.transformPoint(Vector3(
                x: origin.x + size.x, y: origin.y + size.y, z: origin.z)))
            applyColor(color, to: entity)
            return entity

        case .polygon(let points, let color):
            return polylineEntity(
                CADPolyline(points: points, isClosed: true),
                color: color,
                transform: transform)

        case .polyline(let path, let color):
            guard !path.isHatchBoundaryCarrier else { return nil }
            return polylineEntity(path, color: color, transform: transform)

        case .fillPolygon(let points, let color):
            guard !points.isEmpty else { return nil }
            guard points.count <= 4 else { return nil }
            let entity = DXFSolidEntity()
            let padded = points + Array(repeating: points.last!, count: max(0, 4 - points.count))
            entity.basePoint = toDXF(transform.transformPoint(padded[0]))
            entity.secPoint = toDXF(transform.transformPoint(padded[1]))
            entity.thirdPoint = toDXF(transform.transformPoint(padded[2]))
            entity.fourPoint = toDXF(transform.transformPoint(padded[3]))
            applyColor(color, to: entity)
            return entity

        case .circle(let center, let radius, let color):
            let xAxis = transformedVector(Vector3(x: radius, y: 0, z: 0), by: transform)
            let yAxis = transformedVector(Vector3(x: 0, y: radius, z: 0), by: transform)
            let xLength = xAxis.magnitude
            let yLength = yAxis.magnitude
            if abs(xLength - yLength) <= max(xLength, yLength) * 1e-9 {
                let entity = DXFCircleEntity()
                entity.basePoint = toDXF(transform.transformPoint(center))
                entity.radius = (xLength + yLength) * 0.5
                applyColor(color, to: entity)
                return entity
            }
            let entity = DXFEllipseEntity()
            entity.basePoint = toDXF(transform.transformPoint(center))
            if xLength >= yLength {
                entity.secPoint = toDXFVector(xAxis)
                entity.ratio = yLength / max(xLength, 1e-12)
            } else {
                entity.secPoint = toDXFVector(yAxis)
                entity.ratio = xLength / max(yLength, 1e-12)
            }
            entity.startParam = 0
            entity.endParam = 2 * .pi
            applyColor(color, to: entity)
            return entity

        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            let worldCenter = transform.transformPoint(center)
            let startPoint = transform.transformPoint(Vector3(
                x: center.x + radius * cos(startAngle),
                y: center.y + radius * sin(startAngle),
                z: center.z))
            let endPoint = transform.transformPoint(Vector3(
                x: center.x + radius * cos(endAngle),
                y: center.y + radius * sin(endAngle),
                z: center.z))
            let dx = transformedVector(Vector3(x: radius, y: 0, z: 0), by: transform).magnitude
            let dy = transformedVector(Vector3(x: 0, y: radius, z: 0), by: transform).magnitude
            let entity = DXFArcEntity()
            entity.basePoint = toDXF(worldCenter)
            entity.radius = (dx + dy) * 0.5
            let dxfStartVector = toDXF(endPoint) - entity.basePoint
            let dxfEndVector = toDXF(startPoint) - entity.basePoint
            entity.startAngle = atan2(dxfStartVector.y, dxfStartVector.x)
            entity.endAngle = atan2(dxfEndVector.y, dxfEndVector.x)
            entity.isCCW = 1
            applyColor(color, to: entity)
            return entity

        case .spline(let controlPoints, let knots, let degree, let weights, let color):
            let exportedControlPoints = controlPoints.map {
                toDXF(transform.transformPoint($0))
            }
            if let weights,
               let ellipse = ellipseFromRationalQuadraticSpline(
                controlPoints: exportedControlPoints,
                degree: degree,
                weights: weights) {
                applyColor(color, to: ellipse)
                return ellipse
            }

            let entity = DXFSplineEntity()
            entity.controlPoints = exportedControlPoints
            entity.knots = knots
            entity.degree = degree
            entity.weights = weights ?? []
            entity.nControl = Int32(entity.controlPoints.count)
            entity.nKnots = Int32(entity.knots.count)
            if !entity.weights.isEmpty { entity.flags |= 4 }
            applyColor(color, to: entity)
            return entity

        case .text(
            let position, let text, let height, let rotation, let style,
            let alignH, let alignV, let mtextWidth, let color
        ):
            let worldPosition = transform.transformPoint(position)
            let direction = transformedVector(Vector3(
                x: cos(rotation), y: sin(rotation), z: 0), by: transform)
            let worldRotation = direction.magnitude > 1e-12
                ? atan2(direction.y, direction.x)
                : rotation
            let xScale = transformedVector(Vector3(x: 1, y: 0, z: 0), by: transform).magnitude
            let yScale = transformedVector(Vector3(x: 0, y: 1, z: 0), by: transform).magnitude
            let exportedHeight = height * max(yScale, 1e-12)
            let rawMText = xdataString(xdata, "dxf.mtextRaw")
            let shouldUseMText = mtextWidth != nil
                || rawMText != nil
                || text.contains("\n")
                || text.contains("\\P")
                || xdataString(xdata, "dxf.textEntityType")?.uppercased() == "MTEXT"

            if shouldUseMText {
                let entity = DXFMTextEntity()
                entity.basePoint = toDXF(worldPosition)
                entity.text = rawMText ?? text
                    .replacingOccurrences(of: "\r\n", with: "\\P")
                    .replacingOccurrences(of: "\n", with: "\\P")
                    .replacingOccurrences(of: "\r", with: "\\P")
                entity.height = exportedHeight
                entity.widthScale = (mtextWidth ?? xdataDouble(xdata, "dxf.mtextWidth") ?? 0)
                    * max(xScale, 1e-12)
                entity.angle_p = -worldRotation * 180.0 / .pi
                entity.style = style ?? xdataString(xdata, "dxf.textStyle") ?? "STANDARD"
                entity.textGen = mtextAttachment(alignH: alignH, alignV: alignV)
                entity.interlin = xdataDouble(xdata, "dxf.mtextLineSpacing") ?? 1.0
                entity.lineSpacingStyle = xdataInt(
                    xdata, "dxf.mtextLineSpacingStyle") == 2 ? 2 : 1
                applyMTextBackground(xdata, to: entity)
                applyColor(color, to: entity)
                return entity
            }

            let entity = DXFTextEntity()
            entity.basePoint = toDXF(worldPosition)
            entity.secPoint = entity.basePoint
            entity.text = text
            entity.height = exportedHeight
            entity.angle_p = -worldRotation * 180.0 / .pi
            entity.style = style ?? xdataString(xdata, "dxf.textStyle") ?? "STANDARD"
            entity.alignH = alignH
            entity.alignV = alignV
            entity.widthScale = xdataDouble(xdata, "dxf.textWidthScale") ?? 1.0
            entity.oblique = xdataDouble(xdata, "dxf.textOblique") ?? 0.0
            entity.textGen = xdataInt(xdata, "dxf.textGenerationFlags") ?? 0
            applyColor(color, to: entity)
            return entity

        case .ellipse(let center, let majorAxis, let minorRatio, let color):
            let worldMajor = transformedVector(majorAxis, by: transform)
            let localMinor = Vector3(
                x: -majorAxis.y * minorRatio,
                y: majorAxis.x * minorRatio,
                z: 0)
            let worldMinor = transformedVector(localMinor, by: transform)
            let majorLength = worldMajor.magnitude
            let minorLength = worldMinor.magnitude
            guard majorLength > 1e-12, minorLength > 1e-12 else { return nil }
            let entity = DXFEllipseEntity()
            entity.basePoint = toDXF(transform.transformPoint(center))
            if majorLength >= minorLength {
                entity.secPoint = toDXFVector(worldMajor)
                entity.ratio = minorLength / majorLength
            } else {
                entity.secPoint = toDXFVector(worldMinor)
                entity.ratio = majorLength / minorLength
            }
            entity.startParam = 0
            entity.endParam = 2 * .pi
            applyColor(color, to: entity)
            return entity

        case .ray(let start, let direction, let color):
            let entity = DXFRayEntity()
            entity.basePoint = toDXF(transform.transformPoint(start))
            entity.secPoint = toDXFVector(transformedVector(direction, by: transform))
            applyColor(color, to: entity)
            return entity

        case .hatch, .hatchPath, .fillComplexPolygon, .gradient, .image, .table:
            return nil
        }
    }

    private static func ellipseFromRationalQuadraticSpline(
        controlPoints: [Vector3],
        degree: Int,
        weights: [Double]
    ) -> DXFEllipseEntity? {
        guard degree == 2,
              controlPoints.count >= 3,
              controlPoints.count % 2 == 1,
              weights.count == controlPoints.count else { return nil }

        for index in stride(from: 0, to: weights.count, by: 2) {
            guard abs(weights[index] - 1.0) <= 1e-4 else { return nil }
        }

        let segmentCount = (controlPoints.count - 1) / 2
        var sourceSegment: Int?
        for segment in 0..<segmentCount {
            let weight = weights[segment * 2 + 1]
            guard weight > 0, weight <= 1.0 + 1e-8 else { return nil }
            if weight < 1.0 - 1e-9, sourceSegment == nil {
                sourceSegment = segment
            }
        }
        guard let sourceSegment else { return nil }

        let firstIndex = sourceSegment * 2
        let p0 = controlPoints[firstIndex]
        let p1 = controlPoints[firstIndex + 1]
        let p2 = controlPoints[firstIndex + 2]
        let weight = min(1.0, weights[firstIndex + 1])
        let weightSquared = weight * weight
        let denominator = 1.0 - weightSquared
        guard denominator > 1e-12 else { return nil }

        let midpoint = (p0 + p2) * 0.5
        let center = midpoint - (p1 - midpoint) * (weightSquared / denominator)
        let delta = 2.0 * acos(max(-1.0, min(1.0, weight)))
        let sinDelta = sin(delta)
        guard abs(sinDelta) > 1e-12 else { return nil }

        let axisAtStart = p0 - center
        let axisDerivative = (p2 - center - axisAtStart * cos(delta)) / sinDelta
        let sxx = axisAtStart.x * axisAtStart.x
            + axisDerivative.x * axisDerivative.x
        let sxy = axisAtStart.x * axisAtStart.y
            + axisDerivative.x * axisDerivative.y
        let syy = axisAtStart.y * axisAtStart.y
            + axisDerivative.y * axisDerivative.y
        let trace = sxx + syy
        let discriminant = hypot(sxx - syy, 2.0 * sxy)
        let majorSquared = (trace + discriminant) * 0.5
        let minorSquared = (trace - discriminant) * 0.5
        guard majorSquared > 1e-18, minorSquared > 1e-18 else { return nil }

        var majorDirection: Vector3
        if abs(sxy) > 1e-14 {
            majorDirection = Vector3(x: majorSquared - syy, y: sxy, z: 0).normalized
        } else if sxx >= syy {
            majorDirection = Vector3(x: 1, y: 0, z: 0)
        } else {
            majorDirection = Vector3(x: 0, y: 1, z: 0)
        }
        guard majorDirection.magnitude > 1e-12 else { return nil }

        let majorLength = sqrt(majorSquared)
        let minorLength = sqrt(minorSquared)
        let majorAxis = majorDirection * majorLength
        let minorDirection = Vector3(
            x: -majorDirection.y,
            y: majorDirection.x,
            z: 0)
        let minorAxis = minorDirection * minorLength

        func parameter(for point: Vector3) -> Double {
            let offset = point - center
            let cosine = offset.dot(majorAxis) / majorSquared
            let sine = offset.dot(minorAxis) / minorSquared
            return atan2(sine, cosine)
        }

        let firstParameter = parameter(for: controlPoints[0])
        let increasingDerivative = majorAxis * (-sin(firstParameter))
            + minorAxis * cos(firstParameter)
        let orientation = (controlPoints[1] - controlPoints[0])
            .dot(increasingDerivative) >= 0 ? 1.0 : -1.0

        var accumulatedSweep = 0.0
        var maximumError = 0.0
        for segment in 0..<segmentCount {
            let sourceWeight = min(1.0, weights[segment * 2 + 1])
            let segmentSweep = 2.0 * acos(max(-1.0, min(1.0, sourceWeight)))
            let start = firstParameter + orientation * accumulatedSweep
            let middle = start + orientation * segmentSweep * 0.5
            let end = start + orientation * segmentSweep

            let expectedStart = center
                + majorAxis * cos(start)
                + minorAxis * sin(start)
            let expectedMiddle = center
                + (majorAxis * cos(middle) + minorAxis * sin(middle)) / sourceWeight
            let expectedEnd = center
                + majorAxis * cos(end)
                + minorAxis * sin(end)
            maximumError = max(
                maximumError,
                max(
                    controlPoints[segment * 2].distance(to: expectedStart),
                    max(
                        controlPoints[segment * 2 + 1].distance(to: expectedMiddle),
                        controlPoints[segment * 2 + 2].distance(to: expectedEnd))))
            accumulatedSweep += segmentSweep
        }

        let tolerance = max(1.0, max(majorLength, minorLength)) * 5e-5
        guard maximumError <= tolerance,
              accumulatedSweep > 1e-9,
              accumulatedSweep <= 2.0 * .pi + 1e-6 else { return nil }

        var startParameter = orientation > 0
            ? firstParameter
            : firstParameter - accumulatedSweep
        while startParameter < 0 { startParameter += 2.0 * .pi }
        while startParameter >= 2.0 * .pi { startParameter -= 2.0 * .pi }

        let ellipse = DXFEllipseEntity()
        ellipse.basePoint = center
        ellipse.secPoint = majorAxis
        ellipse.ratio = minorLength / majorLength
        ellipse.startParam = startParameter
        ellipse.endParam = startParameter + accumulatedSweep
        ellipse.isCCW = 1
        return ellipse
    }

    private static func polylineEntity(
        _ path: CADPolyline,
        color: ColorRGBA?,
        transform: Transform3D
    ) -> DXFLWPolylineEntity {
        let entity = DXFLWPolylineEntity()
        let xAxis = transformedVector(Vector3(x: 1, y: 0, z: 0), by: transform)
        let yAxis = transformedVector(Vector3(x: 0, y: 1, z: 0), by: transform)
        let reversesOrientation = xAxis.x * yAxis.y - xAxis.y * yAxis.x < 0
        let widthScale = (xAxis.magnitude + yAxis.magnitude) * 0.5
        for vertex in path.vertices {
            let exported = DXFVertex2D()
            let point = toDXF(transform.transformPoint(vertex.position))
            exported.x = point.x
            exported.y = point.y
            let transformedBulge = reversesOrientation ? -vertex.bulge : vertex.bulge
            exported.bulge = -transformedBulge
            exported.startWidth = vertex.startWidth * widthScale
            exported.endWidth = vertex.endWidth * widthScale
            entity.vertices.append(exported)
        }
        entity.flags = path.isClosed ? 1 : 0
        if path.lineTypeGenerationEnabled { entity.flags |= 0x80 }
        applyColor(color, to: entity)
        return entity
    }

    private static func applyEntityStyle(
        _ xdata: [String: XDataValue],
        to entity: DXFEntity
    ) {
        if let color = colorFromHex(xdataString(xdata, "dxf.color")) {
            applyColor(color, to: entity)
        }
        if let opacity = xdataDouble(xdata, "dxf.opacity") {
            entity.transparency = DXFColorTable.opacityToTransparency(opacity)
        }
        if let lineType = xdataString(xdata, "dxf.lineType"), !lineType.isEmpty {
            entity.lineType = lineType
        }
        if let lineWeight = xdataDouble(xdata, "dxf.lineWeight") {
            entity.lWeight = DXFLineWidth.fromDXF(Int((lineWeight * 100.0).rounded()))
        }
        if let lineTypeScale = xdataDouble(xdata, "dxf.lineTypeScale") {
            entity.ltypeScale = lineTypeScale
        }
        if let plotStyle = xdataString(xdata, "dxf.plotStyleHandle"),
           let value = UInt32(plotStyle, radix: 16) {
            entity.plotStyleHandle = value
        }
        if let colorName = xdataString(xdata, "dxf.colorName") {
            entity.colorName = colorName
        }
    }

    private static func applyPrimitiveStyle(
        _ style: CADPrimitiveStyle?,
        to entity: DXFEntity
    ) {
        guard let style else { return }
        if let layerName = style.layerName, !layerName.isEmpty {
            entity.layer = layerName
        }
        if style.isColorByBlock {
            entity.color = 0
            entity.color24 = -1
        } else if let color = style.color {
            applyColor(color, to: entity)
        }
        if style.isLineTypeByBlock {
            entity.lineType = "BYBLOCK"
        } else if let lineType = style.lineType, !lineType.isEmpty {
            entity.lineType = lineType
        }
        if style.isLineWeightByBlock {
            entity.lWeight = .byBlock
        } else if let lineWeight = style.lineWeight {
            entity.lWeight = DXFLineWidth.fromDXF(Int((lineWeight * 100.0).rounded()))
        }
        if let lineTypeScale = style.lineTypeScale {
            entity.ltypeScale = lineTypeScale
        }
        if let opacity = style.opacity {
            entity.transparency = DXFColorTable.opacityToTransparency(opacity)
        }
        if let handle = style.plotStyleHandle,
           let value = UInt32(handle, radix: 16) {
            entity.plotStyleHandle = value
        }
        if let mtext = entity as? DXFMTextEntity {
            if let scale = style.textBackgroundScale {
                mtext.backgroundFillFlags |= 1
                mtext.backgroundScale = scale
            }
            if style.textBackgroundUsesViewportColor {
                mtext.backgroundFillFlags |= 3
            } else if let color = style.textBackgroundColor {
                mtext.backgroundFillFlags |= 1
                mtext.backgroundColor = Int(DXFColorTable.rgbaToACI(color))
                mtext.backgroundColor24 = Int(DXFColorTable.rgbaToTrueColor(color) ?? -1)
                mtext.backgroundTransparency = Int(DXFColorTable.opacityToTransparency(Double(color.a) / 255.0))
            }
        }
    }

    private static func applyMTextBackground(
        _ xdata: [String: XDataValue],
        to entity: DXFMTextEntity
    ) {
        guard let scale = xdataDouble(xdata, "dxf.mtextBackgroundScale") else { return }
        entity.backgroundFillFlags = 1
        entity.backgroundScale = max(1.0, scale)
        if xdataInt(xdata, "dxf.mtextBackgroundUsesViewportColor") == 1 {
            entity.backgroundFillFlags |= 2
            return
        }
        if let color = colorFromHex(xdataString(xdata, "dxf.mtextBackgroundColor")) {
            entity.backgroundColor = Int(DXFColorTable.rgbaToACI(color))
            entity.backgroundColor24 = Int(DXFColorTable.rgbaToTrueColor(color) ?? -1)
        }
        if let opacity = xdataDouble(xdata, "dxf.mtextBackgroundOpacity") {
            entity.backgroundTransparency = Int(DXFColorTable.opacityToTransparency(opacity))
        }
    }

    private static func mtextAttachment(alignH: Int, alignV: Int) -> Int {
        let column = min(max(alignH, 0), 2)
        switch alignV {
        case 1: return 7 + column
        case 2: return 4 + column
        default: return 1 + column
        }
    }

    private static func colorFromHex(_ value: String?) -> ColorRGBA? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return ColorRGBA(
            r: UInt8((rgb >> 16) & 0xFF),
            g: UInt8((rgb >> 8) & 0xFF),
            b: UInt8(rgb & 0xFF))
    }

    private static func canExportAsMInsert(
        array: CADArrayData,
        transform: Transform3D
    ) -> Bool {
        guard array.kind == .rectangular,
              array.levels == 1,
              abs(array.axisAngle) <= 1e-10,
              abs(array.columnElevationIncrement) <= 1e-10,
              abs(array.rowElevationIncrement) <= 1e-10,
              array.hiddenItems.isEmpty
        else { return false }

        let origin = transform.transformPoint(.zero)
        let x = transform.transformPoint(Vector3(x: 1, y: 0, z: 0)) - origin
        let y = transform.transformPoint(Vector3(x: 0, y: 1, z: 0)) - origin
        let determinant = x.x * y.y - x.y * y.x
        let orthogonality = abs(x.x * y.x + x.y * y.y)
        return determinant > 1e-12
            && orthogonality <= 1e-9 * max(1.0, x.magnitude * y.magnitude)
    }

    private static func appendArrayXData(
        to entity: DXFEntity,
        groupID: UUID,
        role: String,
        payloadChunks: [String]
    ) {
        entity.extendedData.append((1001, CADArrayDXFCodec.appID))
        entity.extendedData.append((1000, CADArrayDXFCodec.marker))
        entity.extendedData.append((1000, "G:\(groupID.uuidString)"))
        entity.extendedData.append((1000, "R:\(role)"))
        for chunk in payloadChunks { entity.extendedData.append((1000, chunk)) }
    }

    private static func makeInsert(
        blockName: String,
        layerName: String,
        paperSpace: Bool,
        transform: Transform3D
    ) -> DXFInsertEntity {
        let insert = DXFInsertEntity()
        insert.name = blockName
        insert.layer = layerName
        insert.space = paperSpace ? 1 : 0
        let origin = transform.transformPoint(.zero)
        let xAxis = transformedVector(Vector3(x: 1, y: 0, z: 0), by: transform)
        let yAxis = transformedVector(Vector3(x: 0, y: 1, z: 0), by: transform)
        let zAxis = transformedVector(Vector3(x: 0, y: 0, z: 1), by: transform)
        insert.basePoint = toDXF(origin)
        insert.xScale = max(xAxis.magnitude, 1e-12)
        insert.yScale = max(yAxis.magnitude, 1e-12)
        insert.zScale = max(zAxis.magnitude, 1e-12)
        insert.angle = -atan2(xAxis.y, xAxis.x)
        return insert
    }

    private static func transformedVector(_ vector: Vector3, by transform: Transform3D) -> Vector3 {
        transform.transformPoint(vector) - transform.transformPoint(.zero)
    }

    private static func toDXF(_ point: Vector3) -> Vector3 {
        Vector3(x: point.x, y: -point.y, z: point.z)
    }

    private static func toDXFVector(_ vector: Vector3) -> Vector3 {
        Vector3(x: vector.x, y: -vector.y, z: vector.z)
    }
}

// MARK: - Helper: configurable entity
private protocol With {}
extension DXFEntity: With {}
extension With where Self: DXFEntity {
    func with(_ configure: (inout Self) -> Void) -> Self {
        var copy = self; configure(&copy); return copy
    }
}
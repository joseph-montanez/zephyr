import Foundation
import SwiftDXFrw

// =========================================================================
// MARK: - DXFImporter
// Pure Swift DXF import via SwiftDXFrw.
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
    public let views: [DXFDrawingView]
    public init(layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
                textStyleFonts: [String: String], linetypePatterns: [String: [Double]],
                views: [DXFDrawingView]) {
        self.layers = layers; self.blocks = blocks; self.entities = entities
        self.textStyleFonts = textStyleFonts; self.linetypePatterns = linetypePatterns
        self.views = views
    }
}

public enum DXFImporter {

    private struct StyledPrimitive {
        var primitive: CADPrimitive
        var style: CADPrimitiveStyle?
    }

    public static func importDXF(filePath: String) throws -> (layers: [Layer], blocks: [CADBlock], entities: [CADEntity], textStyleFonts: [String: String], linetypePatterns: [String: [Double]]) {
        let result = try importDXFViews(filePath: filePath)
        return (result.layers, result.blocks, result.entities, result.textStyleFonts, result.linetypePatterns)
    }

    public static func importDXFViews(filePath: String) throws -> DXFImportResult {
        let reader = DXFReader()
        _ = try reader.readFile(at: filePath)
        return convertDXFToCAD(reader: reader)
    }

    private static func convertDXFToCAD(reader: DXFReader) -> DXFImportResult {
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


        var blockByName: [String: DXFBlockEntity] = [:]
        for block in reader.blocks where !block.name.isEmpty { blockByName[block.name] = block }
        var blockNameToID: [String: UUID] = [:]
        var blockBaseByName: [String: Vector3] = [:]
        for block in reader.blocks where !block.name.isEmpty {
            blockNameToID[block.name] = UUID()
            blockBaseByName[block.name] = Self.cadPoint(block.basePoint)
        }

        var blockGeometryCache: [String: [StyledPrimitive]] = [:]

        func convertBlockGeometry(named name: String, visited: Set<String> = []) -> [StyledPrimitive] {
            if let cached = blockGeometryCache[name] { return cached }
            guard let block = blockByName[name], !visited.contains(name) else { return [] }

            var nextVisited = visited
            nextVisited.insert(name)
            var geometry: [StyledPrimitive] = []

            for entity in block.entities {
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

        var looseEntities: [CADEntity] = []
        for (drawOrder, entity) in reader.entities.enumerated() {
            if let insert = entity as? DXFInsertEntity,
               let blockID = blockNameToID[insert.name],
               let block = blockByID[blockID] {
                let columns = max(1, insert.colCount)
                let rows = max(1, insert.rowCount)
                let blockBase = blockBaseByName[insert.name] ?? .zero
                for row in 0..<rows {
                    for column in 0..<columns {
                        var cadEnt = CADEntity(handle: UUID(),
                                               layerID: layerID(for: entity),
                                               blockID: blockID,
                                               localGeometry: nil,
                                               transform: Self.insertTransform(insert, blockBase: blockBase, column: column, row: row),
                                               xdata: Self.entityStyleXData(from: entity, globalLineTypeScale: globalLineTypeScale),
                                               drawOrder: drawOrder,
                                               localBoundingBox: block.localBoundingBox)
                        cadEnt.drawOrder = drawOrder
                        looseEntities.append(cadEnt)
                    }
                }
                continue
            }

            if let dimension = entity as? DXFDimensionEntity,
               let blockID = blockNameToID[dimension.name],
               let block = blockByID[blockID] {
                var cadEnt = CADEntity(handle: UUID(),
                                       layerID: layerID(for: entity),
                                       blockID: blockID,
                                       localGeometry: nil,
                                       transform: .identity,
                                       xdata: Self.entityStyleXData(from: entity, globalLineTypeScale: globalLineTypeScale),
                                       drawOrder: drawOrder,
                                       localBoundingBox: block.localBoundingBox)
                cadEnt.drawOrder = drawOrder
                looseEntities.append(cadEnt)
                continue
            }

            let prims = DXFEntityConverter.convertEntityToPrimitives(entity, bylayerColor: nil)
            guard !prims.isEmpty || entity.eType == .pOINT else { continue }
            var cadEnt = CADEntity(handle: UUID(),
                                   layerID: layerID(for: entity),
                                   blockID: nil,
                                   localGeometry: prims,
                                   transform: .identity,
                                   xdata: Self.entityStyleXData(from: entity, globalLineTypeScale: globalLineTypeScale))
            cadEnt.drawOrder = drawOrder
            looseEntities.append(cadEnt)
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

        return DXFImportResult(layers: layers, blocks: blocks, entities: looseEntities,
                              textStyleFonts: textStyleFonts, linetypePatterns: linetypePatterns,
                              views: [DXFDrawingView(name: "Model", kind: .model, entities: looseEntities)])
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

    private static func cadPoint(_ point: SwiftDXFrw.Vector3) -> Vector3 {
        Vector3(x: point.x, y: -point.y, z: point.z)
    }

    private static func cadPoint(_ point: SwiftDXFrw.Vector3, extrusion: SwiftDXFrw.Vector3?) -> Vector3 {
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

    private static func isDefaultExtrusion(_ n: SwiftDXFrw.Vector3) -> Bool {
        abs(n.x) < 1e-12 && abs(n.y) < 1e-12 && abs(n.z - 1.0) < 1e-12
    }

    private static func ocsToWcs(_ point: SwiftDXFrw.Vector3, extrusion n: SwiftDXFrw.Vector3) -> SwiftDXFrw.Vector3 {
        var az = n
        var mag = sqrt(az.x * az.x + az.y * az.y + az.z * az.z)
        if mag < 1e-12 {
            az = SwiftDXFrw.Vector3(x: 0, y: 0, z: 1)
            mag = 1.0
        }
        az.x /= mag; az.y /= mag; az.z /= mag

        var ax: SwiftDXFrw.Vector3
        if abs(az.x) < 0.015625 && abs(az.y) < 0.015625 {
            ax = SwiftDXFrw.Vector3(x: az.z, y: 0, z: -az.x)
        } else {
            ax = SwiftDXFrw.Vector3(x: -az.y, y: az.x, z: 0)
        }
        mag = sqrt(ax.x * ax.x + ax.y * ax.y + ax.z * ax.z)
        if mag > 1e-12 { ax.x /= mag; ax.y /= mag; ax.z /= mag }

        var ay = SwiftDXFrw.Vector3(
            x: az.y * ax.z - az.z * ax.y,
            y: az.z * ax.x - az.x * ax.z,
            z: az.x * ax.y - az.y * ax.x)
        mag = sqrt(ay.x * ay.x + ay.y * ay.y + ay.z * ay.z)
        if mag > 1e-12 { ay.x /= mag; ay.y /= mag; ay.z /= mag }

        return SwiftDXFrw.Vector3(
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
        let raw = transform.rawElements
        let reversesOrientation = raw[0] * raw[5] - raw[1] * raw[4] < 0
        let s = transform.scale
        let widthScale = (abs(s.x) + abs(s.y)) * 0.5
        var out = path
        for index in out.vertices.indices {
            out.vertices[index].position = transform.transformPoint(out.vertices[index].position)
            out.vertices[index].startWidth *= widthScale
            out.vertices[index].endWidth *= widthScale
            if reversesOrientation { out.vertices[index].bulge = -out.vertices[index].bulge }
        }
        return out
    }
}
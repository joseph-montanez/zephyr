// Sources/ZephyrCore/Draw/DimensionPrimitives.swift
import Foundation

@MainActor
public enum DimensionPrimitives {
    
    /// Generates arrowhead primitives.
    public static func arrowhead(tip: Vector3, direction: Vector3, size: Double, color: ColorRGBA) -> [CADPrimitive] {
        let dir = direction.normalized
        // The back of the arrow is 'size' units away from the tip in the negative direction
        let backCenter = Vector3(x: tip.x - dir.x * size,
                                 y: tip.y - dir.y * size,
                                 z: tip.z - dir.z * size)
        
        // The half-width is size * 0.25 (typical 1:4 ratio)
        let halfWidth = size * 0.25
        let perp = Vector3(x: -dir.y, y: dir.x, z: 0) // perpendicular in 2D
        
        let p1 = Vector3(x: backCenter.x + perp.x * halfWidth,
                         y: backCenter.y + perp.y * halfWidth,
                         z: backCenter.z)
        let p2 = Vector3(x: backCenter.x - perp.x * halfWidth,
                         y: backCenter.y - perp.y * halfWidth,
                         z: backCenter.z)
        
        let poly = CADPrimitive.fillPolygon(points: [tip, p1, p2], color: color)
        let line = CADPrimitive.line(start: backCenter, end: tip, color: color)
        return [poly, line]
    }
    
    /// Generates an oblique tick mark primitive.
    public static func tickMark(at: Vector3, direction: Vector3, size: Double, color: ColorRGBA) -> CADPrimitive {
        let dir = direction.normalized
        // Tick is usually 45 degrees, but specification says perpendicular to direction.
        // Let's make it a 45 degree line for architectural ticks.
        // Wait, typical architectural tick is 45 degrees to the dimension line.
        // Let's rotate 'dir' by 45 degrees (pi/4).
        let angle = .pi / 4.0
        let cosA = cos(angle)
        let sinA = sin(angle)
        let dx = dir.x * cosA - dir.y * sinA
        let dy = dir.x * sinA + dir.y * cosA
        let tickDir = Vector3(x: dx, y: dy, z: 0)
        
        let halfSize = size * 0.5
        let start = Vector3(x: at.x - tickDir.x * halfSize,
                            y: at.y - tickDir.y * halfSize,
                            z: at.z)
        let end = Vector3(x: at.x + tickDir.x * halfSize,
                          y: at.y + tickDir.y * halfSize,
                          z: at.z)
        return .line(start: start, end: end, color: color)
    }
    
    /// Generates two extension lines.
    public static func extensionLines(feature1: Vector3, feature2: Vector3, dimLineStart: Vector3, dimLineEnd: Vector3, style: CADDimensionStyle, color: ColorRGBA) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        
        let dir1 = Vector3(x: dimLineStart.x - feature1.x, y: dimLineStart.y - feature1.y, z: dimLineStart.z - feature1.z)
        let len1 = sqrt(dir1.x * dir1.x + dir1.y * dir1.y + dir1.z * dir1.z)
        if !style.suppressFirstExtension && len1 > 0 {
            let n1 = dir1.normalized
            let start = Vector3(x: feature1.x + n1.x * style.extensionLineOffset,
                                y: feature1.y + n1.y * style.extensionLineOffset,
                                z: feature1.z)
            let end = Vector3(x: dimLineStart.x + n1.x * style.extensionLineExtend,
                              y: dimLineStart.y + n1.y * style.extensionLineExtend,
                              z: dimLineStart.z)
            primitives.append(.line(start: start, end: end, color: color))
        }
        
        let dir2 = Vector3(x: dimLineEnd.x - feature2.x, y: dimLineEnd.y - feature2.y, z: dimLineEnd.z - feature2.z)
        let len2 = sqrt(dir2.x * dir2.x + dir2.y * dir2.y + dir2.z * dir2.z)
        if !style.suppressSecondExtension && len2 > 0 {
            let n2 = dir2.normalized
            let start = Vector3(x: feature2.x + n2.x * style.extensionLineOffset,
                                y: feature2.y + n2.y * style.extensionLineOffset,
                                z: feature2.z)
            let end = Vector3(x: dimLineEnd.x + n2.x * style.extensionLineExtend,
                              y: dimLineEnd.y + n2.y * style.extensionLineExtend,
                              z: dimLineEnd.z)
            primitives.append(.line(start: start, end: end, color: color))
        }
        
        return primitives
    }
    
    /// Generates dimension line with arrows/ticks.
    public static func dimensionLine(from: Vector3, to: Vector3, arrowAtStart: Bool, arrowAtEnd: Bool, style: CADDimensionStyle, color: ColorRGBA) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        let dir = Vector3(x: to.x - from.x, y: to.y - from.y, z: to.z - from.z).normalized
        
        // Add arrows or ticks
        let lineStart = from
        let lineEnd = to
        
        if arrowAtStart {
            if style.tickSize > 0 {
                primitives.append(tickMark(at: from, direction: dir, size: style.tickSize, color: color))
            } else {
                primitives.append(contentsOf: arrowhead(tip: from, direction: dir, size: style.arrowSize, color: color))
            }
        }
        if arrowAtEnd {
            if style.tickSize > 0 {
                primitives.append(tickMark(at: to, direction: Vector3(x: -dir.x, y: -dir.y, z: -dir.z), size: style.tickSize, color: color))
            } else {
                primitives.append(contentsOf: arrowhead(tip: to, direction: Vector3(x: -dir.x, y: -dir.y, z: -dir.z), size: style.arrowSize, color: color))
            }
        }
        
        if !style.suppressFirstDimLine || !style.suppressSecondDimLine {
            // For simplicity, we just draw the whole line if either is not suppressed
            // Realistically we'd split the line at the text midpoint, but for now we draw a single line
            primitives.append(.line(start: lineStart, end: lineEnd, color: color))
        }
        
        return primitives
    }
    
    /// Generates dimension text primitive.
    public static func dimensionText(position: Vector3, value: String, rotation: Double, style: CADDimensionStyle, color: ColorRGBA) -> CADPrimitive {
        return .text(
            position: position,
            text: value,
            height: style.textHeight,
            rotation: rotation,
            style: style.textStyle,
            alignH: 4, // Center Middle
            alignV: 2, // Middle
            mtextWidth: nil,
            color: color
        )
    }
    
    /// Commits the dimension to the document as a block + block reference entity.
    public static func commitDimension(primitives: [CADPrimitive], metadata: CADDimensionMetadata, layerID: UUID, document: CADDocument) {
        let blockName = "*D" + UUID().uuidString.prefix(8)
        let block = CADBlock(name: blockName, geometry: primitives)
        document.addBlock(block)
        
        var entity = CADEntity(layerID: layerID)
        entity.blockID = block.handle
        entity.dimensionMetadata = CADDimensionMetadataBox(metadata)
        
        document.addEntities([entity])
    }
    
    /// Re-generates all primitives for a dimension based on its metadata and style.
    public static func generatePrimitives(for metadata: CADDimensionMetadata, style: CADDimensionStyle, color: ColorRGBA) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        let valueStr = metadata.textOverride ?? style.formatMeasurement(metadata.measurement)
        
        switch metadata.type {
        case .linearOrRotated:
            guard let p2 = metadata.defPoint3 else { return [] }
            let p1 = metadata.defPoint2
            let dimLinePos = metadata.defPoint
            
            let midX = (p1.x + p2.x) / 2.0
            let midY = (p1.y + p2.y) / 2.0
            let dx = abs(dimLinePos.x - midX)
            let dy = abs(dimLinePos.y - midY)
            let isHorizontal = dy > dx
            
            let dimStart: Vector3
            let dimEnd: Vector3
            let angle: Double
            
            if isHorizontal {
                dimStart = Vector3(x: p1.x, y: dimLinePos.y, z: 0)
                dimEnd = Vector3(x: p2.x, y: dimLinePos.y, z: 0)
                angle = 0
            } else {
                dimStart = Vector3(x: dimLinePos.x, y: p1.y, z: 0)
                dimEnd = Vector3(x: dimLinePos.x, y: p2.y, z: 0)
                angle = .pi / 2
            }
            
            primitives.append(contentsOf: extensionLines(feature1: p1, feature2: p2, dimLineStart: dimStart, dimLineEnd: dimEnd, style: style, color: color))
            primitives.append(contentsOf: dimensionLine(from: dimStart, to: dimEnd, arrowAtStart: true, arrowAtEnd: true, style: style, color: color))
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: angle, style: style, color: color))
            
        case .aligned:
            guard let p2 = metadata.defPoint3 else { return [] }
            let p1 = metadata.defPoint2
            let dimLinePos = metadata.defPoint
            
            let angle = metadata.rotationAngle
            let dir = Vector3(x: cos(angle), y: sin(angle), z: 0)
            
            let v = Vector3(x: dimLinePos.x - p1.x, y: dimLinePos.y - p1.y, z: 0)
            let perp = Vector3(x: -dir.y, y: dir.x, z: 0).normalized
            let offset = v.x * perp.x + v.y * perp.y
            
            let dimStart = Vector3(x: p1.x + perp.x * offset, y: p1.y + perp.y * offset, z: 0)
            let dimEnd = Vector3(x: p2.x + perp.x * offset, y: p2.y + perp.y * offset, z: 0)
            
            primitives.append(contentsOf: extensionLines(feature1: p1, feature2: p2, dimLineStart: dimStart, dimLineEnd: dimEnd, style: style, color: color))
            primitives.append(contentsOf: dimensionLine(from: dimStart, to: dimEnd, arrowAtStart: true, arrowAtEnd: true, style: style, color: color))
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: angle, style: style, color: color))
            
        case .angular:
            guard let p2 = metadata.defPoint3, let center = metadata.defPoint4 else { return [] }
            let p1 = metadata.defPoint2
            let dimPos = metadata.defPoint
            
            let radius = hypot(dimPos.x - center.x, dimPos.y - center.y)
            let a1 = atan2(p1.y - center.y, p1.x - center.x)
            let a2 = atan2(p2.y - center.y, p2.x - center.x)
            
            primitives.append(.arc(center: center, radius: radius, startAngle: a1, endAngle: a2, color: color))
            
            let a1Dir = Vector3(x: -sin(a1), y: cos(a1), z: 0)
            let a2Dir = Vector3(x: sin(a2), y: -cos(a2), z: 0)
            let ap1 = Vector3(x: center.x + cos(a1)*radius, y: center.y + sin(a1)*radius, z: 0)
            let ap2 = Vector3(x: center.x + cos(a2)*radius, y: center.y + sin(a2)*radius, z: 0)
            
            primitives.append(contentsOf: arrowhead(tip: ap1, direction: a1Dir, size: style.arrowSize, color: color))
            primitives.append(contentsOf: arrowhead(tip: ap2, direction: a2Dir, size: style.arrowSize, color: color))
            
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: 0, style: style, color: color))
            
        case .diameter, .radius:
            let center = metadata.defPoint2
            let dimPos = metadata.defPoint
            
            let p1 = center
            let p2 = Vector3(x: dimPos.x, y: dimPos.y, z: 0)
            
            primitives.append(contentsOf: dimensionLine(from: p1, to: p2, arrowAtStart: false, arrowAtEnd: true, style: style, color: color))
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: 0, style: style, color: color))
            
        default:
            // Fallback just draws text
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: metadata.rotationAngle, style: style, color: color))
        }
        
        return primitives
    }
    
    /// Re-evaluates geometry for a dimension and updates the document block in place.
    public static func updateDimensionBlock(for entity: inout CADEntity, in document: CADDocument) {
        guard let box = entity.dimensionMetadata else { return }
        let metadata = box.value
        let style = metadata.styleOverrides ?? document.dimensionStyles[metadata.styleName] ?? CADDimensionStyle.default
        let color = ColorRGBA.white // Assuming white for now if color is not explicitly on entity
        
        let newPrimitives = generatePrimitives(for: metadata, style: style, color: color)
        
        // Overwrite the block
        if let blockID = entity.blockID, var block = document.block(for: blockID) {
            block.geometry = newPrimitives
            document.addBlock(block)
        }
    }
}


// Sources/ZephyrCore/Draw/DimensionPrimitives.swift
import Foundation

@MainActor
public enum DimensionPrimitives {
    
    /// Generates AutoCAD-compatible dimension arrowhead primitives.
    public static func arrowhead(
        tip: Vector3,
        direction: Vector3,
        size: Double,
        color: ColorRGBA,
        type: CADDimensionArrowhead = .closedFilled
    ) -> [CADPrimitive] {
        guard size > 0 else { return [] }
        let dir = direction.normalized
        let perp = Vector3(x: -dir.y, y: dir.x, z: 0)

        func point(_ back: Double, _ side: Double = 0) -> Vector3 {
            Vector3(
                x: tip.x - dir.x * back + perp.x * side,
                y: tip.y - dir.y * back + perp.y * side,
                z: tip.z - dir.z * back
            )
        }

        func triangle(width: Double, filled: Bool, includeBase: Bool) -> [CADPrimitive] {
            let p1 = point(size, width * 0.5)
            let p2 = point(size, -width * 0.5)
            if filled {
                return [.fillPolygon(points: [tip, p1, p2], color: color)]
            }
            if includeBase {
                return [.polygon(points: [tip, p1, p2], color: color)]
            }
            return [
                .line(start: tip, end: p1, color: color),
                .line(start: tip, end: p2, color: color)
            ]
        }

        func circle(radius: Double, filled: Bool, centerBack: Double) -> [CADPrimitive] {
            let center = point(centerBack)
            if !filled { return [.circle(center: center, radius: radius, color: color)] }
            let segments = 20
            let points = (0..<segments).map { index -> Vector3 in
                let angle = Double(index) * 2.0 * .pi / Double(segments)
                return Vector3(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius,
                    z: center.z
                )
            }
            return [.fillPolygon(points: points, color: color)]
        }

        func box(filled: Bool) -> [CADPrimitive] {
            let half = size * 0.22
            let center = point(size * 0.25)
            let p1 = Vector3(x: center.x + dir.x * half + perp.x * half, y: center.y + dir.y * half + perp.y * half, z: center.z)
            let p2 = Vector3(x: center.x + dir.x * half - perp.x * half, y: center.y + dir.y * half - perp.y * half, z: center.z)
            let p3 = Vector3(x: center.x - dir.x * half - perp.x * half, y: center.y - dir.y * half - perp.y * half, z: center.z)
            let p4 = Vector3(x: center.x - dir.x * half + perp.x * half, y: center.y - dir.y * half + perp.y * half, z: center.z)
            return filled
                ? [.fillPolygon(points: [p1, p2, p3, p4], color: color)]
                : [.polygon(points: [p1, p2, p3, p4], color: color)]
        }

        switch type {
        case .closedFilled:
            return triangle(width: size * 0.5, filled: true, includeBase: true)
        case .closedBlank:
            return triangle(width: size * 0.5, filled: false, includeBase: true)
        case .closed:
            return triangle(width: size * 0.5, filled: false, includeBase: true)
        case .open:
            return triangle(width: size * 0.5, filled: false, includeBase: false)
        case .open30:
            return triangle(width: size * 0.28, filled: false, includeBase: false)
        case .architecturalTick:
            return [tickMark(at: tip, direction: dir, size: size * sqrt(2.0), color: color, angle: -.pi / 4.0)]
        case .oblique:
            return [tickMark(at: tip, direction: dir, size: size, color: color, angle: .pi / 3.0)]
        case .dot:
            return circle(radius: size * 0.25, filled: true, centerBack: 0)
        case .dotSmall:
            return circle(radius: size * 0.14, filled: true, centerBack: 0)
        case .dotBlank:
            return circle(radius: size * 0.25, filled: false, centerBack: 0)
        case .dotSmallBlank:
            return circle(radius: size * 0.14, filled: false, centerBack: 0)
        case .box:
            return box(filled: false)
        case .boxFilled:
            return box(filled: true)
        case .datumTriangle:
            return triangle(width: size * 0.85, filled: false, includeBase: true)
        case .datumTriangleFilled:
            return triangle(width: size * 0.85, filled: true, includeBase: true)
        case .originIndicator, .originIndicator2:
            var result = circle(radius: size * 0.24, filled: false, centerBack: size * 0.24)
            let center = point(size * 0.24)
            result.append(.line(start: point(size * 0.52), end: tip, color: color))
            if type == .originIndicator2 {
                result.append(.line(
                    start: Vector3(x: center.x - perp.x * size * 0.24, y: center.y - perp.y * size * 0.24, z: center.z),
                    end: Vector3(x: center.x + perp.x * size * 0.24, y: center.y + perp.y * size * 0.24, z: center.z),
                    color: color))
            }
            return result
        case .rightAngle:
            let corner = point(size * 0.5)
            return [
                .line(start: tip, end: corner, color: color),
                .line(start: corner, end: Vector3(x: corner.x + perp.x * size * 0.5, y: corner.y + perp.y * size * 0.5, z: corner.z), color: color)
            ]
        case .integral:
            let points = [
                point(size * 0.9, -size * 0.18),
                point(size * 0.7, size * 0.18),
                point(size * 0.45, size * 0.18),
                point(size * 0.2, -size * 0.18),
                point(0, size * 0.18)
            ]
            return [.polyline(points: points, color: color)]
        case .none:
            return []
        case .userArrow:
            return triangle(width: size * 0.5, filled: true, includeBase: true)
        }
    }

    public static func tickMark(
        at: Vector3,
        direction: Vector3,
        size: Double,
        color: ColorRGBA,
        angle: Double = .pi / 4.0
    ) -> CADPrimitive {
        let dir = direction.normalized
        let cosA = cos(angle)
        let sinA = sin(angle)
        let tickDir = Vector3(
            x: dir.x * cosA - dir.y * sinA,
            y: dir.x * sinA + dir.y * cosA,
            z: 0
        )
        let halfSize = size * 0.5
        return .line(
            start: Vector3(x: at.x - tickDir.x * halfSize, y: at.y - tickDir.y * halfSize, z: at.z),
            end: Vector3(x: at.x + tickDir.x * halfSize, y: at.y + tickDir.y * halfSize, z: at.z),
            color: color
        )
    }

    /// Generates two extension lines. With an obliquing angle (radians from
    /// the dimension-line direction, nil = perpendicular) both lines slant
    /// in parallel toward the dimension-line direction. Nil reproduces the
    /// historical perpendicular behavior exactly.
    public nonisolated static func extensionLines(feature1: Vector3, feature2: Vector3, dimLineStart: Vector3, dimLineEnd: Vector3, style: CADDimensionStyle, color: ColorRGBA, obliqueAngle: Double? = nil) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []

        let span = Vector3(x: dimLineEnd.x - dimLineStart.x, y: dimLineEnd.y - dimLineStart.y, z: 0)
        let spanLen = hypot(span.x, span.y)
        let along: Vector3? = spanLen > 0 ? Vector3(x: span.x / spanLen, y: span.y / spanLen, z: 0) : nil

        /// Extension direction for one side: the 3D feature-to-dimline ray by
        /// default (historical behavior), slanted in-plane toward the
        /// dimension-line direction under oblique (obliquing assumes planar
        /// dimensions, which is all the builders produce).
        func extDir(feature: Vector3, dimPoint: Vector3) -> Vector3? {
            let dx = dimPoint.x - feature.x
            let dy = dimPoint.y - feature.y
            let dz = dimPoint.z - feature.z
            let len = sqrt(dx * dx + dy * dy + dz * dz)
            guard len > 0 else { return nil }
            let straight = Vector3(x: dx / len, y: dy / len, z: dz / len)
            guard let phi = obliqueAngle, let u = along else { return straight }
            var n = Vector3(x: -u.y, y: u.x, z: 0)
            if n.x * straight.x + n.y * straight.y < 0 { n = Vector3(x: -n.x, y: -n.y, z: 0) }
            let slanted = Vector3(x: u.x * cos(phi) + n.x * sin(phi), y: u.y * cos(phi) + n.y * sin(phi), z: 0)
            let slantedLen = hypot(slanted.x, slanted.y)
            guard slantedLen > 0 else { return straight }
            return Vector3(x: slanted.x / slantedLen, y: slanted.y / slantedLen, z: 0)
        }

        if !style.suppressFirstExtension, let n1 = extDir(feature: feature1, dimPoint: dimLineStart) {
            let start = Vector3(x: feature1.x + n1.x * style.extensionLineOffset,
                                y: feature1.y + n1.y * style.extensionLineOffset,
                                z: feature1.z)
            let end = Vector3(x: dimLineStart.x + n1.x * style.extensionLineExtend,
                              y: dimLineStart.y + n1.y * style.extensionLineExtend,
                              z: dimLineStart.z)
            primitives.append(.line(start: start, end: end, color: color))
        }

        if !style.suppressSecondExtension, let n2 = extDir(feature: feature2, dimPoint: dimLineEnd) {
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
            let type = style.resolvedFirstArrowhead
            let size = type == .architecturalTick && style.tickSize > 0 ? style.tickSize : style.arrowSize
            primitives.append(contentsOf: arrowhead(tip: from, direction: dir, size: size, color: color, type: type))
        }
        if arrowAtEnd {
            let type = style.resolvedSecondArrowhead
            let size = type == .architecturalTick && style.tickSize > 0 ? style.tickSize : style.arrowSize
            primitives.append(contentsOf: arrowhead(
                tip: to,
                direction: Vector3(x: -dir.x, y: -dir.y, z: -dir.z),
                size: size,
                color: color,
                type: type))
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
            alignH: 1, // Center
            alignV: 2, // Middle
            mtextWidth: nil,
            color: color
        )
    }
    
    private static func primitiveStyles(
        for primitives: [CADPrimitive],
        dimensionStyle: CADDimensionStyle
    ) -> [Int: CADPrimitiveStyle] {
        guard dimensionStyle.textBackgroundScale != nil else { return [:] }

        var result: [Int: CADPrimitiveStyle] = [:]
        for (index, primitive) in primitives.enumerated() {
            guard case .text = primitive else { continue }
            result[index] = CADPrimitiveStyle(
                textBackgroundScale: dimensionStyle.textBackgroundScale,
                textBackgroundColor: dimensionStyle.textBackgroundColor,
                textBackgroundUsesViewportColor:
                    dimensionStyle.textBackgroundUsesViewportColor)
        }
        return result
    }

    /// Commits the dimension to the document as a block + block reference entity.
    public static func commitDimension(primitives: [CADPrimitive], metadata: CADDimensionMetadata, layerID: UUID, document: CADDocument) {
        let blockName = "*D" + UUID().uuidString.prefix(8)
        let style = document.resolvedDimensionStyle(for: metadata)
        let block = CADBlock(
            name: blockName,
            geometry: primitives,
            primitiveStyles: primitiveStyles(
                for: primitives,
                dimensionStyle: style))
        document.addBlock(block)
        
        var entity = CADEntity(layerID: layerID)
        entity.blockID = block.handle
        entity.dimensionMetadata = CADDimensionMetadataBox(metadata)
        
        document.addEntities([entity])
    }
    
    public static func resolvedColor(for entity: CADEntity, in document: CADDocument) -> ColorRGBA {
        if case .string(let hex) = entity.xdata["dxf.color"],
           let color = ColorRGBA(hex: hex) {
            return color
        }
        return document.layer(for: entity.layerID)?.color ?? .white
    }

    private static func readableTextRotation(_ angle: Double) -> Double {
        var normalized = angle.truncatingRemainder(dividingBy: 2.0 * .pi)
        if normalized > .pi { normalized -= 2.0 * .pi }
        if normalized <= -.pi { normalized += 2.0 * .pi }
        if normalized > .pi / 2.0 { normalized -= .pi }
        if normalized < -.pi / 2.0 { normalized += .pi }
        return normalized
    }

    private static func textRotation(for metadata: CADDimensionMetadata, fallback: Double) -> Double {
        metadata.textRotationAngle ?? readableTextRotation(fallback)
    }

    /// Re-generates all primitives for a dimension based on its metadata and style.
    public static func generatePrimitives(for metadata: CADDimensionMetadata, style: CADDimensionStyle, color: ColorRGBA) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        let valueStr: String
        if let override = metadata.textOverride {
            valueStr = override
        } else if metadata.type == .angular || metadata.type == .angular3Point {
            valueStr = style.formatAngle(metadata.measurement)
        } else {
            valueStr = style.formatMeasurement(metadata.measurement)
        }
        
        switch metadata.type {
        case .linearOrRotated:
            guard let p2 = metadata.defPoint3 else { return [] }
            let p1 = metadata.defPoint2
            let dimLinePos = metadata.defPoint
            
            let angle = metadata.rotationAngle
            let dir = Vector3(x: cos(angle), y: sin(angle), z: 0)
            let perp = Vector3(x: -dir.y, y: dir.x, z: 0)
            let p1Along = p1.x * dir.x + p1.y * dir.y
            let p2Along = p2.x * dir.x + p2.y * dir.y
            let lineOffset = dimLinePos.x * perp.x + dimLinePos.y * perp.y
            let dimStart = Vector3(
                x: dir.x * p1Along + perp.x * lineOffset,
                y: dir.y * p1Along + perp.y * lineOffset,
                z: dimLinePos.z)
            let dimEnd = Vector3(
                x: dir.x * p2Along + perp.x * lineOffset,
                y: dir.y * p2Along + perp.y * lineOffset,
                z: dimLinePos.z)
            
            primitives.append(contentsOf: extensionLines(feature1: p1, feature2: p2, dimLineStart: dimStart, dimLineEnd: dimEnd, style: style, color: color, obliqueAngle: metadata.obliqueAngle))
            primitives.append(contentsOf: dimensionLine(from: dimStart, to: dimEnd, arrowAtStart: true, arrowAtEnd: true, style: style, color: color))
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: textRotation(for: metadata, fallback: angle), style: style, color: color))

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
            
            primitives.append(contentsOf: extensionLines(feature1: p1, feature2: p2, dimLineStart: dimStart, dimLineEnd: dimEnd, style: style, color: color, obliqueAngle: metadata.obliqueAngle))
            primitives.append(contentsOf: dimensionLine(from: dimStart, to: dimEnd, arrowAtStart: true, arrowAtEnd: true, style: style, color: color))
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: textRotation(for: metadata, fallback: angle), style: style, color: color))

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
            
            primitives.append(contentsOf: arrowhead(tip: ap1, direction: a1Dir, size: style.arrowSize, color: color, type: style.resolvedFirstArrowhead))
            primitives.append(contentsOf: arrowhead(tip: ap2, direction: a2Dir, size: style.arrowSize, color: color, type: style.resolvedSecondArrowhead))
            
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: textRotation(for: metadata, fallback: 0), style: style, color: color))
            
        case .diameter, .radius:
            // For radius:  defPoint = center,  defPoint2 = arcPoint
            // For diameter: defPoint = one end of diameter line, defPoint2 = other end
            let isRadius = metadata.type == .radius
            let center: Vector3
            let arcPoint: Vector3
            if isRadius {
                center = metadata.defPoint
                arcPoint = metadata.defPoint2
            } else {
                // Diameter: compute center as midpoint
                let p1 = metadata.defPoint
                let p2 = metadata.defPoint2
                center = Vector3(x: (p1.x + p2.x) / 2.0, y: (p1.y + p2.y) / 2.0, z: 0)
                arcPoint = p2
            }
            
            let n = Vector3(x: arcPoint.x - center.x, y: arcPoint.y - center.y, z: 0).normalized
            let textLoc = metadata.textMidpoint
            let prefix = isRadius ? "R" : "\u{2300}"
            let valueStr = metadata.textOverride ?? style.formatMeasurement(metadata.measurement, prefix: prefix)
            
            if isRadius {
                // Leader line from arc point to text location
                primitives.append(.line(start: arcPoint, end: textLoc, color: color))
                // Arrowhead at arc point pointing towards center
                primitives.append(contentsOf: arrowhead(tip: arcPoint, direction: Vector3(x: -n.x, y: -n.y, z: 0), size: style.arrowSize, color: color, type: style.resolvedFirstArrowhead))
            } else {
                // Diameter line across the circle
                let p1 = metadata.defPoint
                let p2 = metadata.defPoint2
                primitives.append(.line(start: p1, end: p2, color: color))
                // Leader line from p2 to text
                primitives.append(.line(start: p2, end: textLoc, color: color))
                // Arrowheads at both ends
                primitives.append(contentsOf: arrowhead(tip: p1, direction: n, size: style.arrowSize, color: color, type: style.resolvedFirstArrowhead))
                primitives.append(contentsOf: arrowhead(tip: p2, direction: Vector3(x: -n.x, y: -n.y, z: 0), size: style.arrowSize, color: color, type: style.resolvedSecondArrowhead))
            }
            
            // Horizontal text tail
            let textTailLength: Double = 5.0
            let tailEnd = Vector3(x: textLoc.x + (n.x >= 0 ? textTailLength : -textTailLength), y: textLoc.y, z: 0)
            primitives.append(.line(start: textLoc, end: tailEnd, color: color))
            
            // Text positioned near the tail
            let textPos = Vector3(x: textLoc.x + (n.x >= 0 ? textTailLength / 2 : -textTailLength / 2), y: textLoc.y + style.textOffset, z: 0)
            primitives.append(dimensionText(position: textPos, value: valueStr, rotation: textRotation(for: metadata, fallback: 0), style: style, color: color))
            
            return primitives
            
        case .arcLength:
            // defPoint = dimPos, defPoint2/3 = arc start/end, defPoint4 = center
            guard let originalStart = metadata.defPoint2 as Vector3?,
                  let originalEnd = metadata.defPoint3,
                  let center = metadata.defPoint4 else { return [] }
            let dimPos = metadata.defPoint
            
            let startAngle = atan2(originalStart.y - center.y, originalStart.x - center.x)
            let endAngle = atan2(originalEnd.y - center.y, originalEnd.x - center.x)
            let dimRadius = hypot(dimPos.x - center.x, dimPos.y - center.y)
            
            // Dimension arc at dimRadius
            primitives.append(.arc(center: center, radius: dimRadius, startAngle: startAngle, endAngle: endAngle, color: color))
            
            // Extension lines from original arc to dimension arc
            let d1 = Vector3(x: center.x + cos(startAngle) * dimRadius, y: center.y + sin(startAngle) * dimRadius, z: 0)
            let d2 = Vector3(x: center.x + cos(endAngle) * dimRadius, y: center.y + sin(endAngle) * dimRadius, z: 0)
            primitives.append(.line(start: originalStart, end: d1, color: color))
            primitives.append(.line(start: originalEnd, end: d2, color: color))
            
            // Arrowheads pointing along tangent
            let sweep = endAngle - startAngle
            let a1Dir = Vector3(x: -sin(startAngle), y: cos(startAngle), z: 0)
            let a2Dir = Vector3(x: sin(endAngle), y: -cos(endAngle), z: 0)
            let sweepSign: Double = sweep >= 0 ? 1.0 : -1.0
            primitives.append(contentsOf: arrowhead(tip: d1, direction: Vector3(x: a1Dir.x * sweepSign, y: a1Dir.y * sweepSign, z: 0), size: style.arrowSize, color: color, type: style.resolvedFirstArrowhead))
            primitives.append(contentsOf: arrowhead(tip: d2, direction: Vector3(x: a2Dir.x * (-sweepSign), y: a2Dir.y * (-sweepSign), z: 0), size: style.arrowSize, color: color, type: style.resolvedSecondArrowhead))
            
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: textRotation(for: metadata, fallback: 0), style: style, color: color))
            
            return primitives
            
        default:
            // Fallback just draws text
            primitives.append(dimensionText(position: metadata.textMidpoint, value: valueStr, rotation: textRotation(for: metadata, fallback: metadata.rotationAngle), style: style, color: color))
        }
        
        return primitives
    }
    
    /// Re-evaluates geometry for a dimension and updates the document block in place.
    public static func updateDimensionBlock(for entity: inout CADEntity, in document: CADDocument) {
        guard let box = entity.dimensionMetadata else { return }
        let metadata = box.value
        let style = document.resolvedDimensionStyle(for: metadata)
        let color = resolvedColor(for: entity, in: document)
        
        let newPrimitives = generatePrimitives(for: metadata, style: style, color: color)
        
        // Overwrite the block
        if let blockID = entity.blockID, var block = document.block(for: blockID) {
            block.geometry = newPrimitives
            block.primitiveStyles = primitiveStyles(
                for: newPrimitives,
                dimensionStyle: style)
            block.primitiveXData.removeAll(keepingCapacity: false)
            block.updateBoundingBox()
            document.addBlock(block)
            entity.localBoundingBox = block.localBoundingBox
            entity.updateAnchorCache(from: newPrimitives)
        }
    }
}


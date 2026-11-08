// Sources/ZephyrCore/Draw/DimLinearCommand.swift
import Foundation
import CSDL3
import ImGui
import SwiftSDL

@MainActor
public final class DimLinearCommand: TwoPointDimensionCommand {

    public override init() {}

    public override func dimensionEndpoints(p1: Vector3, p2: Vector3, dimLinePos: Vector3) -> (Vector3, Vector3)? {
        // Auto-detect horizontal vs vertical
        let midX = (p1.x + p2.x) / 2.0
        let midY = (p1.y + p2.y) / 2.0
        let dx = abs(dimLinePos.x - midX)
        let dy = abs(dimLinePos.y - midY)
        let isHorizontal = dy > dx

        if isHorizontal {
            return (Vector3(x: p1.x, y: dimLinePos.y, z: 0),
                    Vector3(x: p2.x, y: dimLinePos.y, z: 0))
        } else {
            return (Vector3(x: dimLinePos.x, y: p1.y, z: 0),
                    Vector3(x: dimLinePos.x, y: p2.y, z: 0))
        }
    }

    public override func commitDimension(p1: Vector3, p2: Vector3, dimLinePos: Vector3, engine: PhrostEngine, processor: CADCommandProcessor) {
        let midX = (p1.x + p2.x) / 2.0
        let midY = (p1.y + p2.y) / 2.0
        let dx = abs(dimLinePos.x - midX)
        let dy = abs(dimLinePos.y - midY)
        let isHorizontal = dy > dx

        let dimStart: Vector3
        let dimEnd: Vector3
        let dist: Double
        let angle: Double

        if isHorizontal {
            dimStart = Vector3(x: p1.x, y: dimLinePos.y, z: 0)
            dimEnd = Vector3(x: p2.x, y: dimLinePos.y, z: 0)
            dist = abs(p2.x - p1.x)
            angle = 0
        } else {
            dimStart = Vector3(x: dimLinePos.x, y: p1.y, z: 0)
            dimEnd = Vector3(x: dimLinePos.x, y: p2.y, z: 0)
            dist = abs(p2.y - p1.y)
            angle = .pi / 2
        }

        let textMidpoint = Vector3(x: (dimStart.x + dimEnd.x) / 2.0, y: (dimStart.y + dimEnd.y) / 2.0, z: 0)
        let style = engine.document.currentDimensionStyle()
        let color: ColorRGBA = .white
        let valueStr = style.formatMeasurement(dist)

        let metadata = CADDimensionMetadata(
            styleName: engine.document.currentDimensionStyleName,
            type: .linearOrRotated,
            measurement: dist,
            defPoint: dimLinePos,
            defPoint2: p1,
            defPoint3: p2,
            textMidpoint: textMidpoint,
            rotationAngle: angle
        )

        var primitives: [CADPrimitive] = []
        primitives.append(contentsOf: DimensionPrimitives.extensionLines(feature1: p1, feature2: p2, dimLineStart: dimStart, dimLineEnd: dimEnd, style: style, color: color))
        primitives.append(contentsOf: DimensionPrimitives.dimensionLine(from: dimStart, to: dimEnd, arrowAtStart: true, arrowAtEnd: true, style: style, color: color))
        primitives.append(DimensionPrimitives.dimensionText(position: textMidpoint, value: valueStr, rotation: angle, style: style, color: color))

        DimensionPrimitives.commitDimension(primitives: primitives, metadata: metadata, layerID: engine.document.activeLayerID ?? UUID(), document: engine.document)
    }
}

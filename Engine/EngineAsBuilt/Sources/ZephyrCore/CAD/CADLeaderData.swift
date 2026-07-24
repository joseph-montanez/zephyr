import Foundation

public enum CADLeaderPathType: Int, Sendable, Hashable, Codable, CaseIterable {
    case straight = 0
    case spline = 1
    case none = 2
}

public enum CADLeaderContentType: Int, Sendable, Hashable, Codable, CaseIterable {
    case none = 0
    case mtext = 1
    case block = 2
}

public enum CADLeaderArrowhead: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    case closedFilled
    case closedBlank
    case open
    case dot
    case dotBlank
    case architecturalTick
    case oblique
    case originIndicator
    case boxFilled
    case boxBlank
    case custom
}

public enum CADLeaderTextAlignment: Int, Sendable, Hashable, Codable, CaseIterable {
    case left = 0
    case center = 1
    case right = 2
}

public enum CADLeaderTextAngleType: Int, Sendable, Hashable, Codable, CaseIterable {
    case insertAngle = 0
    case horizontal = 1
    case alwaysRightReading = 2
}

public enum CADLeaderTextAttachmentDirection: Int, Sendable, Hashable, Codable, CaseIterable {
    case horizontal = 0
    case vertical = 1
}

public enum CADLeaderTextAttachment: Int, Sendable, Hashable, Codable, CaseIterable {
    case topOfTop = 0
    case middleOfTop = 1
    case middle = 2
    case middleOfBottom = 3
    case bottomOfBottom = 4
    case bottomLine = 5
    case bottomOfTopLine = 6
    case bottomOfTop = 7
    case allLine = 8
    case center = 9
    case linedCenter = 10
}

public struct CADLeaderStyle: Sendable, Hashable, Codable {
    public var name: String
    public var pathType: CADLeaderPathType
    public var arrowEnabled: Bool
    public var arrowSize: Double
    public var arrowhead: CADLeaderArrowhead?
    public var arrowBlockName: String?
    public var landingEnabled: Bool
    public var doglegEnabled: Bool
    public var doglegLength: Double
    public var contentGap: Double
    public var textHeight: Double
    public var textStyleName: String
    public var textFrameEnabled: Bool
    public var textAlignment: CADLeaderTextAlignment?
    public var textAngleType: CADLeaderTextAngleType?
    public var textAttachmentDirection: CADLeaderTextAttachmentDirection?
    public var leftAttachment: CADLeaderTextAttachment?
    public var rightAttachment: CADLeaderTextAttachment?
    public var topAttachment: CADLeaderTextAttachment?
    public var bottomAttachment: CADLeaderTextAttachment?
    public var alwaysLeftJustify: Bool?
    public var extendLeaderToText: Bool?
    public var maxLeaderPoints: Int
    public var blockScale: Double
    public var blockRotation: Double

    public init(
        name: String = "Standard",
        pathType: CADLeaderPathType = .straight,
        arrowEnabled: Bool = true,
        arrowSize: Double = 2.5,
        arrowhead: CADLeaderArrowhead? = nil,
        arrowBlockName: String? = nil,
        landingEnabled: Bool = true,
        doglegEnabled: Bool = true,
        doglegLength: Double = 8.0,
        contentGap: Double = 1.25,
        textHeight: Double = 2.5,
        textStyleName: String = "Standard",
        textFrameEnabled: Bool = false,
        textAlignment: CADLeaderTextAlignment? = nil,
        textAngleType: CADLeaderTextAngleType? = nil,
        textAttachmentDirection: CADLeaderTextAttachmentDirection? = nil,
        leftAttachment: CADLeaderTextAttachment? = nil,
        rightAttachment: CADLeaderTextAttachment? = nil,
        topAttachment: CADLeaderTextAttachment? = nil,
        bottomAttachment: CADLeaderTextAttachment? = nil,
        alwaysLeftJustify: Bool? = nil,
        extendLeaderToText: Bool? = nil,
        maxLeaderPoints: Int = 2,
        blockScale: Double = 1.0,
        blockRotation: Double = 0.0
    ) {
        self.name = name
        self.pathType = pathType
        self.arrowEnabled = arrowEnabled
        self.arrowSize = max(0, arrowSize)
        self.arrowhead = arrowhead
        self.arrowBlockName = arrowBlockName
        self.landingEnabled = landingEnabled
        self.doglegEnabled = doglegEnabled
        self.doglegLength = max(0, doglegLength)
        self.contentGap = max(0, contentGap)
        self.textHeight = max(0.0001, textHeight)
        self.textStyleName = textStyleName
        self.textFrameEnabled = textFrameEnabled
        self.textAlignment = textAlignment
        self.textAngleType = textAngleType
        self.textAttachmentDirection = textAttachmentDirection
        self.leftAttachment = leftAttachment
        self.rightAttachment = rightAttachment
        self.topAttachment = topAttachment
        self.bottomAttachment = bottomAttachment
        self.alwaysLeftJustify = alwaysLeftJustify
        self.extendLeaderToText = extendLeaderToText
        self.maxLeaderPoints = max(2, maxLeaderPoints)
        self.blockScale = max(0.0001, blockScale)
        self.blockRotation = blockRotation
    }

    public static let standard = CADLeaderStyle()
}

public struct CADLeaderBranch: Sendable, Hashable, Codable {
    public var vertices: [Vector3]
    public var doglegDirection: Vector3?
    public var doglegLength: Double?
    public var leaderLineIndex: Int?
    public var arrowhead: CADLeaderArrowhead?
    public var arrowBlockName: String?

    public init(
        vertices: [Vector3],
        doglegDirection: Vector3? = nil,
        doglegLength: Double? = nil,
        leaderLineIndex: Int? = nil,
        arrowhead: CADLeaderArrowhead? = nil,
        arrowBlockName: String? = nil
    ) {
        self.vertices = vertices
        self.doglegDirection = doglegDirection
        self.doglegLength = doglegLength
        self.leaderLineIndex = leaderLineIndex
        self.arrowhead = arrowhead
        self.arrowBlockName = arrowBlockName
    }
}

public struct CADLeaderBlockAttribute: Sendable, Hashable, Codable {
    public var definitionHandle: UInt32?
    public var tag: String
    public var text: String
    public var position: Vector3
    public var height: Double
    public var rotation: Double
    public var styleName: String
    public var alignH: Int
    public var alignV: Int
    public var index: Int
    public var width: Double

    public init(
        definitionHandle: UInt32? = nil,
        tag: String = "",
        text: String,
        position: Vector3,
        height: Double,
        rotation: Double = 0,
        styleName: String = "Standard",
        alignH: Int = 0,
        alignV: Int = 0,
        index: Int = 0,
        width: Double = 0
    ) {
        self.definitionHandle = definitionHandle
        self.tag = tag
        self.text = text
        self.position = position
        self.height = max(height, 0.0001)
        self.rotation = rotation
        self.styleName = styleName
        self.alignH = alignH
        self.alignV = alignV
        self.index = index
        self.width = width
    }
}

public struct CADLeaderData: Sendable, Hashable, Codable {
    public var styleName: String
    public var branches: [CADLeaderBranch]
    public var contentType: CADLeaderContentType
    public var text: String
    public var sourceText: String?
    public var blockName: String?
    public var collectedBlockNames: [String]
    public var contentPosition: Vector3
    public var contentBasePosition: Vector3?
    public var contentRotation: Double
    public var textWidth: Double?
    public var textDirection: Vector3?
    public var textDirectionNegative: Bool?
    public var textAttachmentPoint: Int?
    public var textAttachment: CADLeaderTextAttachment?
    public var textFlowDirection: Int?
    public var blockAttributes: [CADLeaderBlockAttribute]?
    public var isLegacyLeader: Bool
    public var styleOverrides: CADLeaderStyle?

    public init(
        styleName: String = "Standard",
        branches: [CADLeaderBranch],
        contentType: CADLeaderContentType = .mtext,
        text: String = "",
        sourceText: String? = nil,
        blockName: String? = nil,
        collectedBlockNames: [String] = [],
        contentPosition: Vector3,
        contentBasePosition: Vector3? = nil,
        contentRotation: Double = 0,
        textWidth: Double? = nil,
        textDirection: Vector3? = nil,
        textDirectionNegative: Bool? = nil,
        textAttachmentPoint: Int? = nil,
        textAttachment: CADLeaderTextAttachment? = nil,
        textFlowDirection: Int? = nil,
        blockAttributes: [CADLeaderBlockAttribute]? = nil,
        isLegacyLeader: Bool = false,
        styleOverrides: CADLeaderStyle? = nil
    ) {
        self.styleName = styleName
        self.branches = branches
        self.contentType = contentType
        self.text = text
        self.sourceText = sourceText
        self.blockName = blockName
        self.collectedBlockNames = collectedBlockNames
        self.contentPosition = contentPosition
        self.contentBasePosition = contentBasePosition
        self.contentRotation = contentRotation
        self.textWidth = textWidth
        self.textDirection = textDirection
        self.textDirectionNegative = textDirectionNegative
        self.textAttachmentPoint = textAttachmentPoint
        self.textAttachment = textAttachment
        self.textFlowDirection = textFlowDirection
        self.blockAttributes = blockAttributes
        self.isLegacyLeader = isLegacyLeader
        self.styleOverrides = styleOverrides
    }
}

public final class CADLeaderDataBox: Sendable, Hashable, Codable {
    public let value: CADLeaderData

    public init(_ value: CADLeaderData) {
        self.value = value
    }

    public static func == (lhs: CADLeaderDataBox, rhs: CADLeaderDataBox) -> Bool {
        lhs.value == rhs.value
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }

    public required init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(CADLeaderData.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum CADLeaderGripTarget: Sendable, Hashable {
    case content
    case vertex(branchIndex: Int, vertexIndex: Int)
}

public enum CADLeaderGripIndex {
    public static let content = 2000
    private static let branchBase = 3000
    private static let branchStride = 4096

    public static func vertex(branchIndex: Int, vertexIndex: Int) -> Int {
        branchBase + branchIndex * branchStride + vertexIndex
    }

    public static func target(for index: Int) -> CADLeaderGripTarget? {
        if index == content { return .content }
        guard index >= branchBase else { return nil }
        let offset = index - branchBase
        return .vertex(
            branchIndex: offset / branchStride,
            vertexIndex: offset % branchStride)
    }
}

public enum CADLeaderGeometry {
    public static func build(
        data: CADLeaderData,
        style: CADLeaderStyle,
        blockResolver: (String) -> CADBlock?
    ) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        for branch in data.branches where branch.vertices.count >= 2 {
            appendBranch(
                branch,
                data: data,
                style: style,
                blockResolver: blockResolver,
                to: &primitives)
        }
        appendContent(data: data, style: style, blockResolver: blockResolver, to: &primitives)
        return primitives
    }

    public static func resolvedArrowhead(
        style: CADLeaderStyle,
        branch: CADLeaderBranch? = nil
    ) -> CADLeaderArrowhead {
        guard style.arrowEnabled, style.arrowSize > 1e-9 else { return .none }
        return branch?.arrowhead ?? style.arrowhead ?? .closedFilled
    }

    public static func resolvedTextHorizontalAlignment(
        data: CADLeaderData,
        style: CADLeaderStyle
    ) -> Int {
        if style.alwaysLeftJustify == true { return 0 }
        if let attachmentPoint = data.textAttachmentPoint,
           let alignment = horizontalAlignment(forAttachmentPoint: attachmentPoint) {
            return alignment
        }
        switch style.textAlignment ?? .left {
        case .left: return 0
        case .center: return 1
        case .right: return 2
        }
    }

    public static func resolvedTextRotation(
        data: CADLeaderData,
        style: CADLeaderStyle
    ) -> Double {
        switch style.textAngleType ?? .insertAngle {
        case .insertAngle:
            return data.contentRotation
        case .horizontal:
            return 0
        case .alwaysRightReading:
            var angle = data.contentRotation.truncatingRemainder(dividingBy: 2 * Double.pi)
            if angle < 0 { angle += 2 * Double.pi }
            if angle > Double.pi / 2 && angle < 3 * Double.pi / 2 {
                angle += Double.pi
            }
            return angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        }
    }

    public static func resolvedTextVerticalAlignment(
        data: CADLeaderData,
        style: CADLeaderStyle
    ) -> Int {
        if let attachmentPoint = data.textAttachmentPoint,
           let alignment = verticalAlignment(forAttachmentPoint: attachmentPoint) {
            return alignment
        }
        let attachment: CADLeaderTextAttachment = data.textAttachment ?? {
            let base = data.contentBasePosition ?? data.contentPosition
            if style.textAttachmentDirection == .vertical {
                return base.y <= data.contentPosition.y
                    ? (style.bottomAttachment ?? .middle)
                    : (style.topAttachment ?? .middle)
            }
            let direction = data.textDirection?.normalized ?? Vector3(x: 1, y: 0, z: 0)
            let offset = data.contentPosition - base
            return offset.dot(direction) >= 0
                ? (style.leftAttachment ?? .middleOfTop)
                : (style.rightAttachment ?? .middleOfTop)
        }()
        switch attachment {
        case .topOfTop, .middleOfTop, .bottomOfTopLine, .bottomOfTop:
            return 3
        case .middle, .center, .linedCenter:
            return 2
        case .middleOfBottom, .bottomOfBottom, .bottomLine, .allLine:
            return 1
        }
    }

    private static func horizontalAlignment(forAttachmentPoint value: Int) -> Int? {
        switch value {
        case 1, 4, 7, 10: return 0
        case 2, 5, 8, 11: return 1
        case 3, 6, 9, 12: return 2
        default: return nil
        }
    }

    private static func verticalAlignment(forAttachmentPoint value: Int) -> Int? {
        switch value {
        case 1, 2, 3, 16, 20, 24: return 3
        case 4, 5, 6, 15, 19, 23: return 2
        case 7, 8, 9, 14, 18, 22: return 1
        case 10, 11, 12, 13, 17, 21: return 0
        default: return nil
        }
    }

    private static func appendBranch(
        _ branch: CADLeaderBranch,
        data: CADLeaderData,
        style: CADLeaderStyle,
        blockResolver: (String) -> CADBlock?,
        to primitives: inout [CADPrimitive]
    ) {
        let points = branch.vertices
        guard points.count >= 2 else { return }
        let requestedArrowhead = resolvedArrowhead(style: style, branch: branch)
        let arrowSize = style.arrowSize
        let arrowhead = points[0].distance(to: points[1]) + 1e-9 < arrowSize * 2
            ? .none
            : requestedArrowhead
        let direction = (points[1] - points[0]).normalized
        let trimDistance = arrowTrimDistance(for: arrowhead, size: arrowSize)

        switch style.pathType {
        case .none:
            break
        case .straight:
            for index in 0..<(points.count - 1) {
                var start = points[index]
                if index == 0, direction.magnitudeSquared > 1e-18, trimDistance > 0 {
                    start = points[0] + direction * trimDistance
                }
                primitives.append(.line(start: start, end: points[index + 1]))
            }
        case .spline:
            var controlPoints = points
            if direction.magnitudeSquared > 1e-18, trimDistance > 0 {
                controlPoints[0] = points[0] + direction * trimDistance
            }
            let degree = min(3, controlPoints.count - 1)
            primitives.append(.spline(
                controlPoints: controlPoints,
                knots: clampedUniformKnots(controlPointCount: controlPoints.count, degree: degree),
                degree: degree,
                weights: nil))
        }

        appendArrowhead(
            arrowhead,
            tip: points[0],
            direction: direction,
            size: arrowSize,
            blockName: branch.arrowBlockName ?? style.arrowBlockName,
            blockResolver: blockResolver,
            to: &primitives)

        guard style.landingEnabled, let last = points.last else { return }
        var landingDirection = branch.doglegDirection?.normalized ?? Vector3(
            x: data.contentPosition.x >= last.x ? 1 : -1,
            y: 0,
            z: 0)
        if landingDirection.magnitudeSquared <= 1e-18 {
            landingDirection = Vector3(x: 1, y: 0, z: 0)
        }
        let doglegLength = branch.doglegLength ?? style.doglegLength
        let doglegEnd = style.doglegEnabled ? last + landingDirection * doglegLength : last
        if style.doglegEnabled, doglegLength > 1e-9 {
            primitives.append(.line(start: last, end: doglegEnd))
        }
        if style.extendLeaderToText == true {
            let contentEdge = Vector3(
                x: data.contentPosition.x - landingDirection.x * style.contentGap,
                y: data.contentPosition.y - landingDirection.y * style.contentGap,
                z: data.contentPosition.z)
            if doglegEnd.distance(to: contentEdge) > 1e-9 {
                primitives.append(.line(start: doglegEnd, end: contentEdge))
            }
        }
    }

    private static func arrowTrimDistance(
        for arrowhead: CADLeaderArrowhead,
        size: Double
    ) -> Double {
        switch arrowhead {
        case .closedFilled, .closedBlank, .dot, .dotBlank, .boxFilled, .boxBlank:
            return size * 0.82
        case .none, .open, .architecturalTick, .oblique, .originIndicator, .custom:
            return 0
        }
    }

    private static func appendArrowhead(
        _ arrowhead: CADLeaderArrowhead,
        tip: Vector3,
        direction: Vector3,
        size: Double,
        blockName: String?,
        blockResolver: (String) -> CADBlock?,
        to primitives: inout [CADPrimitive]
    ) {
        guard arrowhead != .none, size > 1e-9, direction.magnitudeSquared > 1e-18 else { return }
        let perpendicular = Vector3(x: -direction.y, y: direction.x, z: 0)
        let base = tip + direction * size
        let halfWidth = size * 0.38
        let left = base + perpendicular * halfWidth
        let right = base - perpendicular * halfWidth

        switch arrowhead {
        case .none:
            break
        case .closedFilled:
            primitives.append(.fillPolygon(points: [tip, left, right]))
        case .closedBlank:
            primitives.append(.polygon(points: [tip, left, right]))
        case .open:
            primitives.append(.line(start: tip, end: left))
            primitives.append(.line(start: tip, end: right))
        case .dot:
            primitives.append(.circle(center: tip + direction * size * 0.5, radius: size * 0.5))
            let segments = 20
            let center = tip + direction * size * 0.5
            let points = (0..<segments).map { index -> Vector3 in
                let angle = Double(index) * 2 * Double.pi / Double(segments)
                return center + Vector3(x: cos(angle), y: sin(angle), z: 0) * (size * 0.5)
            }
            primitives.append(.fillPolygon(points: points))
        case .dotBlank:
            primitives.append(.circle(center: tip + direction * size * 0.5, radius: size * 0.5))
        case .architecturalTick, .oblique:
            let center = tip + direction * size * 0.35
            let along = direction * size * 0.55
            let across = perpendicular * size * 0.55
            primitives.append(.line(start: center - along - across, end: center + along + across))
        case .originIndicator:
            let center = tip + direction * size * 0.5
            primitives.append(.circle(center: center, radius: size * 0.45))
            primitives.append(.line(
                start: center - perpendicular * size * 0.45,
                end: center + perpendicular * size * 0.45))
        case .boxFilled, .boxBlank:
            let center = tip + direction * size * 0.5
            let half = size * 0.42
            let corners = [
                center - direction * half - perpendicular * half,
                center + direction * half - perpendicular * half,
                center + direction * half + perpendicular * half,
                center - direction * half + perpendicular * half
            ]
            if arrowhead == .boxFilled {
                primitives.append(.fillPolygon(points: corners))
            } else {
                primitives.append(.polygon(points: corners))
            }
        case .custom:
            guard let blockName,
                  let block = blockResolver(blockName) else {
                primitives.append(.fillPolygon(points: [tip, left, right]))
                return
            }
            let bounds = block.localBoundingBox
            let extent = max(
                max(
                    abs(bounds.max.x - bounds.min.x),
                    abs(bounds.max.y - bounds.min.y)),
                1e-9)
            let scale = size / extent
            let angle = atan2(direction.y, direction.x)
            let transform = Transform3D.translated(by: tip)
                .multiplying(by: .rotated(by: angle))
                .multiplying(by: .scaled(by: Vector3(x: scale, y: scale, z: scale)))
            primitives.append(contentsOf: CADGeometryMath.transformPrimitives(block.geometry, by: transform))
        }
    }

    public static func contentHitTest(
        data: CADLeaderData,
        style: CADLeaderStyle,
        localPoint: Vector3,
        tolerance: Double,
        blockResolver: (String) -> CADBlock?
    ) -> Bool {
        switch data.contentType {
        case .none:
            return false

        case .mtext:
            let alignH = resolvedTextHorizontalAlignment(data: data, style: style)
            let alignV = resolvedTextVerticalAlignment(data: data, style: style)
            let bounds = CADEntity.estimateTextLocalBounds(
                text: data.text,
                height: style.textHeight,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: data.textWidth)
            let dx = localPoint.x - data.contentPosition.x
            let dy = localPoint.y - data.contentPosition.y
            let textRotation = resolvedTextRotation(data: data, style: style)
            let c = cos(-textRotation)
            let s = sin(-textRotation)
            let x = dx * c - dy * s
            let y = dx * s + dy * c
            return x >= bounds.minX - tolerance
                && x <= bounds.maxX + tolerance
                && y >= bounds.minY - tolerance
                && y <= bounds.maxY + tolerance

        case .block:
            let names = data.collectedBlockNames.isEmpty
                ? data.blockName.map { [$0] } ?? []
                : data.collectedBlockNames
            guard !names.isEmpty else { return false }
            let dx = localPoint.x - data.contentPosition.x
            let dy = localPoint.y - data.contentPosition.y
            let rotation = -(style.blockRotation + data.contentRotation)
            let c = cos(rotation)
            let s = sin(rotation)
            var localX = (dx * c - dy * s) / max(style.blockScale, 0.0001)
            let localY = (dx * s + dy * c) / max(style.blockScale, 0.0001)
            let localTolerance = tolerance / max(style.blockScale, 0.0001)
            for name in names {
                guard let block = blockResolver(name) else { continue }
                let bounds = block.localBoundingBox
                if localX >= bounds.min.x - localTolerance
                    && localX <= bounds.max.x + localTolerance
                    && localY >= bounds.min.y - localTolerance
                    && localY <= bounds.max.y + localTolerance {
                    return true
                }
                localX -= max(bounds.max.x - bounds.min.x, style.textHeight)
                    + style.contentGap / max(style.blockScale, 0.0001)
            }
            return false
        }
    }

    private static func appendContent(
        data: CADLeaderData,
        style: CADLeaderStyle,
        blockResolver: (String) -> CADBlock?,
        to primitives: inout [CADPrimitive]
    ) {
        switch data.contentType {
        case .none:
            return
        case .mtext:
            let alignH = resolvedTextHorizontalAlignment(data: data, style: style)
            let alignV = resolvedTextVerticalAlignment(data: data, style: style)
            primitives.append(.text(
                position: data.contentPosition,
                text: data.text,
                height: style.textHeight,
                rotation: resolvedTextRotation(data: data, style: style),
                style: style.textStyleName,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: data.textWidth))
            if style.textFrameEnabled, !data.text.isEmpty {
                let bounds = CADEntity.estimateTextLocalBounds(
                    text: data.text,
                    height: style.textHeight,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: data.textWidth)
                let padding = style.contentGap * 0.5
                primitives.append(.rect(
                    origin: Vector3(
                        x: data.contentPosition.x + bounds.minX - padding,
                        y: data.contentPosition.y + bounds.minY - padding,
                        z: data.contentPosition.z),
                    size: Vector3(
                        x: bounds.maxX - bounds.minX + padding * 2,
                        y: bounds.maxY - bounds.minY + padding * 2,
                        z: 0)))
            }
        case .block:
            var names = data.collectedBlockNames
            if names.isEmpty, let name = data.blockName { names = [name] }
            var offset = 0.0
            for name in names {
                guard let block = blockResolver(name) else { continue }
                let scale = style.blockScale
                let transform = Transform3D.translated(by: Vector3(
                    x: data.contentPosition.x + offset,
                    y: data.contentPosition.y,
                    z: data.contentPosition.z))
                    .multiplying(by: Transform3D.rotated(by: style.blockRotation + data.contentRotation))
                    .multiplying(by: Transform3D.scaled(by: Vector3(x: scale, y: scale, z: scale)))
                primitives.append(contentsOf: CADGeometryMath.transformPrimitives(block.geometry, by: transform))
                if name.caseInsensitiveCompare(data.blockName ?? "") == .orderedSame,
                   let attributes = data.blockAttributes {
                    let attributePrimitives = attributes.compactMap { attribute -> CADPrimitive? in
                        guard !attribute.text.isEmpty else { return nil }
                        return .text(
                            position: attribute.position,
                            text: attribute.text,
                            height: attribute.height,
                            rotation: attribute.rotation,
                            style: attribute.styleName,
                            alignH: attribute.alignH,
                            alignV: attribute.alignV,
                            mtextWidth: nil)
                    }
                    primitives.append(contentsOf: CADGeometryMath.transformPrimitives(
                        attributePrimitives,
                        by: transform))
                }
                let width = max(block.localBoundingBox.max.x - block.localBoundingBox.min.x, style.textHeight)
                offset += width * scale + style.contentGap
            }
        }
    }

    private static func clampedUniformKnots(controlPointCount: Int, degree: Int) -> [Double] {
        let knotCount = controlPointCount + degree + 1
        let interiorCount = max(0, knotCount - 2 * (degree + 1))
        var knots = Array(repeating: 0.0, count: degree + 1)
        if interiorCount > 0 {
            for index in 1...interiorCount {
                knots.append(Double(index) / Double(interiorCount + 1))
            }
        }
        knots.append(contentsOf: Array(repeating: 1.0, count: degree + 1))
        return knots
    }
}

public extension CADDocument {
    func leaderStyle(named name: String) -> CADLeaderStyle? {
        if let exact = leaderStyles[name] { return exact }
        return leaderStyles.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func resolvedLeaderStyleName(_ name: String) -> String {
        leaderStyle(named: name)?.name ?? leaderStyle(named: "Standard")?.name ?? "Standard"
    }

    @discardableResult
    func applyLeaderStyle(_ style: CADLeaderStyle, replacing oldName: String? = nil) -> Bool {
        let trimmed = style.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let collision = leaderStyles.keys.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
                && (oldName == nil || $0.caseInsensitiveCompare(oldName!) != .orderedSame)
        }) { _ = collision; return false }

        pushUndo()
        let previousName = oldName ?? trimmed
        if let oldName,
           let storedKey = leaderStyles.keys.first(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame }) {
            leaderStyles.removeValue(forKey: storedKey)
        }
        var normalized = style
        normalized.name = trimmed
        leaderStyles[trimmed] = normalized
        if currentLeaderStyleName.caseInsensitiveCompare(previousName) == .orderedSame {
            currentLeaderStyleName = trimmed
        }

        for handle in allEntities.compactMap({ entity -> UUID? in
            guard let data = entity.leaderData?.value,
                  data.styleOverrides == nil,
                  data.styleName.caseInsensitiveCompare(previousName) == .orderedSame else { return nil }
            return entity.handle
        }) {
            guard var entity = entity(for: handle), var data = entity.leaderData?.value else { continue }
            data.styleName = trimmed
            entity.leaderData = CADLeaderDataBox(data)
            updateEntityLive(regeneratedLeaderEntity(entity))
        }
        markEdited(regenerate: true)
        return true
    }

    @discardableResult
    func deleteLeaderStyle(named name: String) -> Bool {
        guard name.caseInsensitiveCompare("Standard") != .orderedSame,
              let key = leaderStyles.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        pushUndo()
        leaderStyles.removeValue(forKey: key)
        if currentLeaderStyleName.caseInsensitiveCompare(name) == .orderedSame {
            currentLeaderStyleName = "Standard"
        }
        for handle in allEntities.compactMap({ entity -> UUID? in
            entity.leaderData?.value.styleName.caseInsensitiveCompare(name) == .orderedSame ? entity.handle : nil
        }) {
            guard var entity = entity(for: handle), var data = entity.leaderData?.value else { continue }
            data.styleName = "Standard"
            data.styleOverrides = nil
            entity.leaderData = CADLeaderDataBox(data)
            entity.localGeometry = CADLeaderGeometry.build(
                data: data,
                style: leaderStyle(named: "Standard") ?? .standard,
                blockResolver: { blockName in self.allBlocks.first { $0.name.caseInsensitiveCompare(blockName) == .orderedSame } })
            updateEntityLive(entity)
        }
        markEdited(regenerate: true)
        return true
    }

    func regeneratedLeaderEntity(_ entity: CADEntity) -> CADEntity {
        guard let box = entity.leaderData else { return entity }
        var result = entity
        let data = box.value
        let style = data.styleOverrides ?? leaderStyle(named: data.styleName) ?? .standard
        result.localGeometry = CADLeaderGeometry.build(
            data: data,
            style: style,
            blockResolver: { blockName in
                self.allBlocks.first { $0.name.caseInsensitiveCompare(blockName) == .orderedSame }
            })
        result.localBoundingBox = CADEntity.computeLocalBoundingBox(
            blockID: result.blockID,
            localGeometry: result.localGeometry)
        result.updateAnchorCache()
        return result
    }

    func regenerateLeadersUsingStyle(named name: String) {
        for handle in allEntities.compactMap({ entity -> UUID? in
            guard let data = entity.leaderData?.value, data.styleOverrides == nil,
                  data.styleName.caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return entity.handle
        }) {
            if let entity = entity(for: handle) {
                updateEntityLive(regeneratedLeaderEntity(entity))
            }
        }
    }
}

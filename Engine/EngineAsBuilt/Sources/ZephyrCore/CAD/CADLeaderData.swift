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

public struct CADLeaderStyle: Sendable, Hashable, Codable {
    public var name: String
    public var pathType: CADLeaderPathType
    public var arrowEnabled: Bool
    public var arrowSize: Double
    public var landingEnabled: Bool
    public var doglegEnabled: Bool
    public var doglegLength: Double
    public var contentGap: Double
    public var textHeight: Double
    public var textStyleName: String
    public var textFrameEnabled: Bool
    public var maxLeaderPoints: Int
    public var blockScale: Double
    public var blockRotation: Double

    public init(
        name: String = "Standard",
        pathType: CADLeaderPathType = .straight,
        arrowEnabled: Bool = true,
        arrowSize: Double = 2.5,
        landingEnabled: Bool = true,
        doglegEnabled: Bool = true,
        doglegLength: Double = 8.0,
        contentGap: Double = 1.25,
        textHeight: Double = 2.5,
        textStyleName: String = "Standard",
        textFrameEnabled: Bool = false,
        maxLeaderPoints: Int = 2,
        blockScale: Double = 1.0,
        blockRotation: Double = 0.0
    ) {
        self.name = name
        self.pathType = pathType
        self.arrowEnabled = arrowEnabled
        self.arrowSize = max(0, arrowSize)
        self.landingEnabled = landingEnabled
        self.doglegEnabled = doglegEnabled
        self.doglegLength = max(0, doglegLength)
        self.contentGap = max(0, contentGap)
        self.textHeight = max(0.0001, textHeight)
        self.textStyleName = textStyleName
        self.textFrameEnabled = textFrameEnabled
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

    public init(
        vertices: [Vector3],
        doglegDirection: Vector3? = nil,
        doglegLength: Double? = nil
    ) {
        self.vertices = vertices
        self.doglegDirection = doglegDirection
        self.doglegLength = doglegLength
    }
}

public struct CADLeaderData: Sendable, Hashable, Codable {
    public var styleName: String
    public var branches: [CADLeaderBranch]
    public var contentType: CADLeaderContentType
    public var text: String
    public var blockName: String?
    public var collectedBlockNames: [String]
    public var contentPosition: Vector3
    public var contentRotation: Double
    public var textWidth: Double?
    public var isLegacyLeader: Bool
    public var styleOverrides: CADLeaderStyle?

    public init(
        styleName: String = "Standard",
        branches: [CADLeaderBranch],
        contentType: CADLeaderContentType = .mtext,
        text: String = "",
        blockName: String? = nil,
        collectedBlockNames: [String] = [],
        contentPosition: Vector3,
        contentRotation: Double = 0,
        textWidth: Double? = nil,
        isLegacyLeader: Bool = false,
        styleOverrides: CADLeaderStyle? = nil
    ) {
        self.styleName = styleName
        self.branches = branches
        self.contentType = contentType
        self.text = text
        self.blockName = blockName
        self.collectedBlockNames = collectedBlockNames
        self.contentPosition = contentPosition
        self.contentRotation = contentRotation
        self.textWidth = textWidth
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

public enum CADLeaderGeometry {
    public static func build(
        data: CADLeaderData,
        style: CADLeaderStyle,
        blockResolver: (String) -> CADBlock?
    ) -> [CADPrimitive] {
        var primitives: [CADPrimitive] = []
        for branch in data.branches where branch.vertices.count >= 2 {
            appendBranch(branch, data: data, style: style, to: &primitives)
        }
        appendContent(data: data, style: style, blockResolver: blockResolver, to: &primitives)
        return primitives
    }

    private static func appendBranch(
        _ branch: CADLeaderBranch,
        data: CADLeaderData,
        style: CADLeaderStyle,
        to primitives: inout [CADPrimitive]
    ) {
        let points = branch.vertices
        if style.arrowEnabled, style.arrowSize > 1e-9 {
            let direction = (points[1] - points[0]).normalized
            if direction.magnitudeSquared > 1e-18 {
                let perpendicular = Vector3(x: -direction.y, y: direction.x, z: 0)
                let base = points[0] + direction * style.arrowSize
                let halfWidth = style.arrowSize * 0.38
                primitives.append(.fillPolygon(points: [
                    points[0],
                    base + perpendicular * halfWidth,
                    base - perpendicular * halfWidth
                ]))
            }
        }

        switch style.pathType {
        case .none:
            break
        case .straight:
            for index in 0..<(points.count - 1) {
                primitives.append(.line(start: points[index], end: points[index + 1]))
            }
        case .spline:
            let degree = min(3, points.count - 1)
            primitives.append(.spline(
                controlPoints: points,
                knots: clampedUniformKnots(controlPointCount: points.count, degree: degree),
                degree: degree,
                weights: nil))
        }

        guard style.landingEnabled, let last = points.last else { return }
        var direction = branch.doglegDirection?.normalized ?? Vector3(
            x: data.contentPosition.x >= last.x ? 1 : -1,
            y: 0,
            z: 0)
        if abs(direction.x) < 1e-9 && abs(direction.y) < 1e-9 {
            direction = Vector3(x: 1, y: 0, z: 0)
        }
        let doglegLength = branch.doglegLength ?? style.doglegLength
        let doglegEnd = style.doglegEnabled ? last + direction * doglegLength : last
        if style.doglegEnabled, doglegLength > 1e-9 {
            primitives.append(.line(start: last, end: doglegEnd))
        }
        let contentEdge = Vector3(x: data.contentPosition.x - direction.x * style.contentGap,
                                  y: data.contentPosition.y - direction.y * style.contentGap,
                                  z: data.contentPosition.z)
        if doglegEnd.distance(to: contentEdge) > 1e-9 {
            primitives.append(.line(start: doglegEnd, end: contentEdge))
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
            let rightToLeft = data.branches.first?.vertices.last.map {
                data.contentPosition.x < $0.x
            } ?? false
            let alignH = rightToLeft ? 2 : 0
            primitives.append(.text(
                position: data.contentPosition,
                text: data.text,
                height: style.textHeight,
                rotation: data.contentRotation,
                style: style.textStyleName,
                alignH: alignH,
                alignV: 2,
                mtextWidth: data.textWidth))
            if style.textFrameEnabled, !data.text.isEmpty {
                let bounds = CADEntity.estimateTextLocalBounds(
                    text: data.text,
                    height: style.textHeight,
                    alignH: alignH,
                    alignV: 2,
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

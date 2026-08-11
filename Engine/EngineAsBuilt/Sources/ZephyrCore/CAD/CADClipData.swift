import Foundation

public struct CADClipData: Codable, Hashable, Sendable {
    public var boundary: [Vector3]
    public var isEnabled: Bool
    public var isInverted: Bool
    public var frontDepth: Double?
    public var backDepth: Double?

    public init(
        boundary: [Vector3],
        isEnabled: Bool = true,
        isInverted: Bool = false,
        frontDepth: Double? = nil,
        backDepth: Double? = nil
    ) {
        self.boundary = boundary
        self.isEnabled = isEnabled
        self.isInverted = isInverted
        self.frontDepth = frontDepth
        self.backDepth = backDepth
    }
}

public enum CADClipMetadata {
    public static let key = "zephyr.clip.data"
    public static let underlayTypeKey = "zephyr.underlay.type"

    public static func value(from entity: CADEntity) -> CADClipData? {
        guard case .string(let string) = entity.xdata[key],
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CADClipData.self, from: data)
    }

    public static func set(_ value: CADClipData?, on entity: inout CADEntity) {
        guard let value else {
            entity.xdata.removeValue(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return }
        entity.xdata[key] = .string(string)
    }

    public static func accepts(worldPoint point: Vector3, entity: CADEntity) -> Bool {
        guard let clip = value(from: entity), clip.isEnabled, clip.boundary.count >= 3 else { return true }
        let local = entity.transform.inverse().transformPoint(point)
        let inside = contains(local, polygon: clip.boundary)
        return clip.isInverted ? !inside : inside
    }

    public static func contains(_ point: Vector3, polygon: [Vector3]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            let crosses = (a.y > point.y) != (b.y > point.y)
            if crosses {
                let x = (b.x - a.x) * (point.y - a.y) / ((b.y - a.y) == 0 ? 1e-20 : (b.y - a.y)) + a.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func boundaryDistanceSquared(worldPoint point: Vector3, entity: CADEntity) -> Double? {
        guard let clip = value(from: entity), clip.boundary.count >= 3 else { return nil }
        let world = clip.boundary.map(entity.transform.transformPoint)
        var best = Double.infinity
        for i in world.indices {
            best = min(best, CADGeometryMath.pointToSegmentDistSq(
                point, world[i], world[(i + 1) % world.count]))
        }
        return best.isFinite ? best : nil
    }

    public static func isSupportedTarget(_ entity: CADEntity) -> Bool {
        if entity.blockID != nil { return true }
        if entity.localGeometry?.contains(where: {
            if case .image = $0 { return true }
            return false
        }) == true { return true }
        if case .string(let type) = entity.xdata[underlayTypeKey], !type.isEmpty { return true }
        return false
    }

    public static func frameVariableName(for entity: CADEntity) -> String {
        if case .string(let type) = entity.xdata[underlayTypeKey], type.uppercased() == "PDF" {
            return "PDFFRAME"
        }
        if entity.localGeometry?.contains(where: {
            if case .image = $0 { return true }
            return false
        }) == true {
            return "IMAGEFRAME"
        }
        return "XCLIPFRAME"
    }
}

public enum CADClipFrameSettings {
    private static let prefix = "Zephyr.CAD."

    public static func value(_ name: String) -> Int {
        let key = prefix + name.uppercased()
        if UserDefaults.standard.object(forKey: key) == nil { return 2 }
        return max(0, min(2, UserDefaults.standard.integer(forKey: key)))
    }

    public static func set(_ name: String, value: Int) {
        UserDefaults.standard.set(max(0, min(2, value)), forKey: prefix + name.uppercased())
    }

    public static func isVisible(for entity: CADEntity) -> Bool {
        let master = value("FRAME")
        guard master != 0 else { return false }
        return value(CADClipMetadata.frameVariableName(for: entity)) != 0
    }
}

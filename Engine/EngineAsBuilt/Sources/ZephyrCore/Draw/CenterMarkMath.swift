// Sources/ZephyrCore/Draw/CenterMarkMath.swift
import Foundation

/// Linkage keys for associative-lite center marks/lines (Phase 2.1).
/// Marks carry their source circle/arc handle; centerlines carry both
/// source line handles. Values live in entity xdata so they persist with
/// the drawing; MOVE fans out through centerLinkedHandles(following:).
public enum CenterMarkLink {
    /// xdata key holding one source-handle uuidString (center crosses).
    public static let markSourceKey = "centermark.source"
    /// xdata key holding comma-joined source-handle uuidStrings (centerlines).
    public static let lineSourcesKey = "centerline.sources"
}

/// Pure geometry for CENTERMARK/DIMCENTER/CENTERLINE (Phase 2.1).
public enum CenterMarkMath {
    /// Four cross endpoints for a center mark. Half-size comes from the
    /// scaled current style's extensionLineExtend (CENTEREXE-style sizing).
    public static func crossArms(
        center: Vector3, halfSize: Double
    ) -> (Vector3, Vector3, Vector3, Vector3) {
        let h = max(0, halfSize)
        return (
            Vector3(x: center.x - h, y: center.y, z: center.z),
            Vector3(x: center.x + h, y: center.y, z: center.z),
            Vector3(x: center.x, y: center.y - h, z: center.z),
            Vector3(x: center.x, y: center.y + h, z: center.z))
    }

    /// Midline segment between two parallel lines: parallel to both,
    /// midway between the segment midpoints, spanning the combined
    /// projected extent. Nil for degenerate inputs or non-parallel lines.
    public static func midline(
        a1: Vector3, a2: Vector3, b1: Vector3, b2: Vector3
    ) -> (Vector3, Vector3)? {
        let dax = a2.x - a1.x, day = a2.y - a1.y
        let dbx = b2.x - b1.x, dby = b2.y - b1.y
        let la = hypot(dax, day), lb = hypot(dbx, dby)
        guard la > 0, lb > 0 else { return nil }
        let dot = abs((dax * dbx + day * dby) / (la * lb))
        guard dot > 1 - 1e-9 else { return nil }
        let ux = dax / la, uy = day / la
        let mid = Vector3(
            x: (a1.x + a2.x + b1.x + b2.x) / 4.0,
            y: (a1.y + a2.y + b1.y + b2.y) / 4.0, z: 0)
        var tmin = Double.greatestFiniteMagnitude
        var tmax = -Double.greatestFiniteMagnitude
        for p in [a1, a2, b1, b2] {
            let t = (p.x - mid.x) * ux + (p.y - mid.y) * uy
            tmin = min(tmin, t)
            tmax = max(tmax, t)
        }
        return (
            Vector3(x: mid.x + ux * tmin, y: mid.y + uy * tmin, z: 0),
            Vector3(x: mid.x + ux * tmax, y: mid.y + uy * tmax, z: 0))
    }
}

public extension CADDocument {
    /// Union of `handles` with every center mark/line linked at them:
    /// marks whose markSourceKey names a handled source, centerlines
    /// naming any handled source. Malformed links are ignored. MOVE fans
    /// out through here so marks travel with their circles (v1
    /// associative-lite; re-measurement waits for DIMREASSOCIATE).
    func centerLinkedHandles(following handles: Set<UUID>) -> Set<UUID> {
        guard !handles.isEmpty else { return handles }
        let wanted = Set(handles.map { $0.uuidString })
        var out = handles
        for entity in allEntities {
            var follows = false
            if case .string(let raw) = entity.xdata[CenterMarkLink.markSourceKey],
               wanted.contains(raw) {
                follows = true
            }
            if !follows,
               case .string(let raw) = entity.xdata[CenterMarkLink.lineSourcesKey] {
                let names = raw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                follows = names.contains(where: { wanted.contains($0) })
            }
            if follows { out.insert(entity.handle) }
        }
        return out
    }
}

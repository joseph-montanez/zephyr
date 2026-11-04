import Foundation

// MARK: - SheetSetLocks
//
// Lock preflight for transmit/publish scope: is this file safe to copy
// right now? Rules mirror the repo's stated semantics (`SheetSetStore`):
// a `.dbl` beside the `.dst` means another session holds the set; for a
// member drawing the OS open probe is truth and `.dwl`/`.dwl2` sidecars add
// the editor signal with an owner excerpt for `.dwl` (plain text) only.
// Platform caveat: POSIX locks are advisory, so on macOS/Linux the OS
// probe usually succeeds even when another editor has the file open —
// there the `.dwl` sidecar (which AutoCAD always writes) is the signal
// that fires. On Windows a deny-write open fails the probe directly.

public enum SheetSetLocks {
    /// Preflight outcome for one member drawing.
    public enum MemberLock: Sendable, Equatable {
        case available
        case missing
        case locked(detail: String)
    }

    /// Preflight for one member drawing path (absolute, or already resolved
    /// against the `.dst` folder by the caller). Set-level locking stays
    /// with `SheetSetStore.lockStatus` (single source of truth).
    public static func memberLock(drawingPath: String) -> MemberLock {
        guard !drawingPath.isEmpty else { return .missing }
        let url = URL(fileURLWithPath: drawingPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return .missing }
        let base = url.deletingPathExtension()
        let dwl = base.appendingPathExtension("dwl").path
        if FileManager.default.fileExists(atPath: dwl) {
            return .locked(detail: ownerExcerpt(dwl) ?? "editor lock file present (.dwl)")
        }
        let dwl2 = base.appendingPathExtension("dwl2").path
        if FileManager.default.fileExists(atPath: dwl2) {
            return .locked(detail: "editor lock file present (.dwl2)")
        }
        do {
            let handle = try FileHandle(forUpdating: url)
            try handle.close()
            return .available
        } catch {
            return .locked(detail: "file is open in another process")
        }
    }

    /// First line of the `.dwl` sidecar (username/machine/timestamp as
    /// AutoCAD writes it), capped for tooltips and reports. Nil when the
    /// file is unreadable or blank.
    private static func ownerExcerpt(_ dwlPath: String) -> String? {
        guard let text = try? String(contentsOfFile: dwlPath, encoding: .utf8) else { return nil }
        let first = text.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else { return nil }
        return String(first.prefix(200))
    }
}

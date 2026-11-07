import Foundation

// =========================================================================
// MARK: - BlockLibraryPolicy
//
// Shared predicate for user-insertable block definitions (Blocks palette
// tabs, INSERT name resolution, library recording). One definition so the
// palette and the command can never disagree about what is insertable.
//
// Excluded:
//   - `*...` names: model/paper space, anonymous (`*U`), dimension (`*D`),
//     table display (`*T`) and other internal records.
//   - `Xref|Block` names: xref-dependent sub-blocks rewritten by
//     XrefLoader.rewriteDependentNames (only the root xref block carries
//     an xrefDescriptor).
//   - Xref root definitions: geometry lives in the runtime store, never
//     insertable as a plain block.
// =========================================================================

public enum BlockLibraryPolicy {
    public static func isUserInsertable(_ block: CADBlock) -> Bool {
        guard !block.name.hasPrefix("*") else { return false }
        guard !block.name.contains("|") else { return false }
        guard block.xrefDescriptor == nil else { return false }
        return true
    }

    /// LRU bookkeeping for Recent (cap 50, most-recent first, deduped).
    public static func recordRecent(
        _ ref: BlockLibraryRef, into recent: inout [BlockLibraryRef], cap: Int = 50
    ) {
        recent.removeAll {
            $0.kind == ref.kind && $0.path == ref.path && $0.block == ref.block
        }
        var stored = ref
        stored.lastUsed = Date()
        recent.insert(stored, at: 0)
        if recent.count > cap {
            recent = Array(recent.prefix(cap))
        }
    }
}

/// Persisted reference to a library source: a whole file (root entity) or
/// one container block. In-drawing blocks are promoted to `.container`
/// with the document's path when recorded (see the Blocks palette); unsaved
/// documents keep session-only names instead (never persisted).
public struct BlockLibraryRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case container
    }

    public var kind: Kind
    public var path: String
    /// Container block name; nil for whole-file refs.
    public var block: String?
    public var lastUsed: Date

    public init(kind: Kind, path: String, block: String? = nil, lastUsed: Date = Date()) {
        self.kind = kind
        self.path = path
        self.block = block
        self.lastUsed = lastUsed
    }

    public var displayName: String {
        let file = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        switch kind {
        case .file:
            return file
        case .container:
            return block ?? file
        }
    }
}

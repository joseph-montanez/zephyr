// Sources/ZephyrCore/CAD/CADGroup.swift
import Foundation

/// Named selection groups (GROUP/UNGROUP/PICKSTYLE), Phase 2.2f.
///
/// A group is document model data: creation and removal push undo, the
/// table rides `CADDocumentSnapshot` (undo/redo), DXF (via `ZEPHYR_GROUP`
/// appID extendedData on member entities, rebuilt on import), and EAB (own
/// section). Anonymous groups take LT-style `*A<n>` names.
///
/// Pick behavior lives in `CADDocument.selectionExpansion(for:)` + the
/// `CADSelectionManager.groupExpansionProvider` hook: with PICKSTYLE bit 0
/// set, adding one member selects every member of each selectable group
/// containing it.
public struct CADGroup: Hashable, Sendable, Codable {
    /// DXF appID carrying membership (one 1000 payload = group name).
    public static let dxfAppID = "ZEPHYR_GROUP"
    /// Import-staging xdata key prefix (`group.member.<name>`).
    public static let stagingPrefix = "group.member."

    public var name: String
    public var members: [UUID]
    /// LT per-group selectable flag (DXF group code 70 bit 0). Members of
    /// an unselectable group pick individually under PICKSTYLE.
    public var isSelectable: Bool

    public init(name: String, members: [UUID], isSelectable: Bool = true) {
        self.name = name
        self.members = members
        self.isSelectable = isSelectable
    }
}

extension CADDocument {

    /// Groups selectable under the current PICKSTYLE containing a handle.
    public func selectableGroups(containing handle: UUID) -> [CADGroup] {
        guard pickStyle & 1 != 0 else { return [] }
        return groups.values.filter { group in
            group.isSelectable && group.members.contains(handle)
        }
    }

    /// Handles one add-to-selection expands to under PICKSTYLE: the union
    /// of every selectable group containing the handle, restricted to
    /// members that still exist. Without the PICKSTYLE group bit, or when
    /// no selectable group contains the handle, the handle alone.
    public func selectionExpansion(for handle: UUID) -> Set<UUID> {
        let containing = selectableGroups(containing: handle)
        guard !containing.isEmpty else { return [handle] }
        var expanded: Set<UUID> = [handle]
        for group in containing {
            for member in group.members where entity(for: member) != nil {
                expanded.insert(member)
            }
        }
        return expanded
    }

    /// Next LT-style anonymous group name (`*A<n>` over the max in use).
    public func nextAnonymousGroupName() -> String {
        var maxNumber = 0
        for name in groups.keys where name.hasPrefix("*A") {
            if let number = Int(name.dropFirst(2)) {
                maxNumber = max(maxNumber, number)
            }
        }
        return "*A\(maxNumber + 1)"
    }

    /// Creates a named group over existing entities. Members that name no
    /// entity are dropped; needs at least one live member. Pushes undo.
    @discardableResult
    public func createGroup(named name: String, members: [UUID]) -> CADGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let live = members.filter { entity(for: $0) != nil }
        guard !live.isEmpty else { return nil }
        pushUndo()
        var seen = Set<UUID>()
        let group = CADGroup(
            name: trimmed, members: live.filter { seen.insert($0).inserted })
        groups[trimmed] = group
        markEdited(regenerate: true)
        return group
    }

    /// Removes the named group (members stay). Pushes undo. False when
    /// no group of that name exists (case-insensitive).
    @discardableResult
    public func ungroup(named name: String) -> Bool {
        guard let key = groups.keys.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) else { return false }
        pushUndo()
        groups.removeValue(forKey: key)
        markEdited(regenerate: true)
        return true
    }
}

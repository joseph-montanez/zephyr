// Sources/ZephyrCore/CAD/CADDimensionStyleTable.swift
import Foundation

/// Named dimension-style table helpers on CADDocument (Phase 2.1 DIMSTYLE).
/// Mirrors the text-style helpers in CADDocument.swift and the leader-style
/// helpers in CADLeaderData.swift: case-insensitive lookup, Standard
/// protection, entity metadata rewrite on rename/delete, and an undoable
/// current-style selection that Dim* commands read when committing.
public extension CADDocument {
    /// Case-insensitive lookup with a Standard fallback, mirroring
    /// textStyle(named:) / leaderStyle(named:).
    func dimensionStyle(named name: String) -> CADDimensionStyle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = dimensionStyles.keys.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return dimensionStyles[key] ?? .default
        }
        return .default
    }

    /// Canonical stored key for a name, or "Standard" when absent.
    func resolvedDimensionStyleName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return dimensionStyles.keys.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) ?? "Standard"
    }

    /// The style Dim* commands build with: the current selection,
    /// pre-scaled by its DIMSCALE factor (see CADDimensionStyle.scaled()).
    func currentDimensionStyle() -> CADDimensionStyle {
        dimensionStyle(named: currentDimensionStyleName).scaled()
    }

    /// Single choke point for every geometry/display path that resolves a
    /// dimension's style: per-entity overrides win, then the named table
    /// style (case-insensitive), then Standard — always pre-scaled.
    /// Use this instead of subscripting dimensionStyles directly so the
    /// stored raw values can never leak unscaled into geometry.
    func resolvedDimensionStyle(for metadata: CADDimensionMetadata) -> CADDimensionStyle {
        (metadata.styleOverrides ?? dimensionStyle(named: metadata.styleName)).scaled()
    }

    /// Undoable current-style selection. Returns false when the name is
    /// unknown. Mirrors the leader manager's Set Current (pushUndo +
    /// markEdited without regen — selection alone changes no geometry).
    @discardableResult
    func setCurrentDimensionStyle(named name: String) -> Bool {
        let key = dimensionStyles.keys.first(where: {
            $0.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        })
        guard let key else { return false }
        pushUndo()
        currentDimensionStyleName = key
        markEdited(regenerate: false)
        return true
    }

    /// Insert or replace a style, rewriting entity references on rename.
    /// Returns false for blank names. Mirrors applyTextStyle/applyLeaderStyle.
    @discardableResult
    func applyDimensionStyle(_ style: CADDimensionStyle, replacing originalName: String? = nil) -> Bool {
        let trimmed = style.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var style = style
        style.name = trimmed
        pushUndo()
        if let originalName, !originalName.isEmpty,
           originalName.caseInsensitiveCompare(trimmed) != .orderedSame {
            rewriteDimensionStyleReferences(from: originalName, to: trimmed)
            if let doomed = dimensionStyles.keys.first(where: {
                $0.caseInsensitiveCompare(originalName) == .orderedSame
            }) {
                dimensionStyles.removeValue(forKey: doomed)
            }
            if currentDimensionStyleName.caseInsensitiveCompare(originalName) == .orderedSame {
                currentDimensionStyleName = trimmed
            }
        }
        dimensionStyles[trimmed] = style
        markEdited(regenerate: true)
        return true
    }

    /// Delete a style, re-pointing its dimensions at Standard. Standard
    /// itself is protected. Mirrors deleteTextStyle/deleteLeaderStyle.
    @discardableResult
    func deleteDimensionStyle(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("Standard") != .orderedSame,
              let key = dimensionStyles.keys.first(where: {
                  $0.caseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return false }
        pushUndo()
        rewriteDimensionStyleReferences(from: key, to: "Standard")
        dimensionStyles.removeValue(forKey: key)
        if currentDimensionStyleName.caseInsensitiveCompare(key) == .orderedSame {
            currentDimensionStyleName = "Standard"
        }
        markEdited(regenerate: true)
        return true
    }

    /// -DIMSTYLE Apply: point every listed dimension at the named style,
    /// clearing per-entity overrides so the table governs. Returns the
    /// applied count, or nil when the style is unknown.
    @discardableResult
    func applyDimensionStyleToEntities(named name: String, handles: Set<UUID>) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = dimensionStyles.keys.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return nil }
        pushUndo()
        var count = 0
        for handle in handles {
            guard var entity = entity(for: handle),
                  let metadata = entity.dimensionMetadata?.value else { continue }
            var pointed = metadata.withStyleName(key)
            pointed.styleOverrides = nil
            entity.dimensionMetadata = CADDimensionMetadataBox(pointed)
            updateEntityLive(entity)
            count += 1
        }
        markEdited(regenerate: true)
        return count
    }

    /// Re-point every dimension whose metadata names `from` at `to`,
    /// clearing per-entity overrides so the table value governs again
    /// (same contract as the leader/text reference rewrites).
    func rewriteDimensionStyleReferences(from previousName: String, to newName: String) {
        for var entity in allEntities {
            guard let metadata = entity.dimensionMetadata?.value,
                  metadata.styleName.caseInsensitiveCompare(previousName) == .orderedSame
            else { continue }
            var pointed = metadata.withStyleName(newName)
            pointed.styleOverrides = nil
            entity.dimensionMetadata = CADDimensionMetadataBox(pointed)
            updateEntityLive(entity)
        }
    }
}

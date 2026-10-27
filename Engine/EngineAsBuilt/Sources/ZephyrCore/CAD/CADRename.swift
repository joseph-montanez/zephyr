// Sources/ZephyrCore/CAD/CADRename.swift
import Foundation

/// RENAME target types, Phase 2.2g. Each rename validates, rewrites
/// references, and lands in exactly one undo entry by reusing the table
/// apply paths (`applyTextStyle`/`applyDimensionStyle`/`applyLeaderStyle`
/// rekey + rewrite on `replacing:`; layers and blocks rename in place
/// since entities reference them by handle ID).
public enum CADRename {

    /// LT illegal name characters.
    public static let illegalCharacters = CharacterSet(
        charactersIn: "\\/:;\"?*|=`<>")

    public enum Kind: String, CaseIterable {
        case block = "Block"
        case dimstyle = "Dimstyle"
        case layer = "Layer"
        case linetype = "Linetype"
        case textStyle = "Text style"
        case leaderStyle = "Leader style"

        /// Full-name case-insensitive match for the RENAME type prompt.
        public static func match(_ text: String) -> Kind? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return allCases.first {
                $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
            }
        }
    }

    /// Shared new-name validation. Nil when the name is usable.
    public static func newNameError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name cannot be blank." }
        if trimmed.rangeOfCharacter(from: illegalCharacters) != nil {
            return "Name contains illegal characters (\\ / : ; \" ? * | = ` < >)."
        }
        return nil
    }
}

extension CADDocument {

    /// Rename a named object. Returns nil on success, else a message for
    /// the command prompt. One undo entry per successful rename.
    public func rename(
        kind: CADRename.Kind, from oldName: String, to newName: String
    ) -> String? {
        let oldTrimmed = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty else { return "Old name cannot be blank." }
        if let error = CADRename.newNameError(newName) { return error }
        guard oldTrimmed != newTrimmed else {
            return "Old and new names are the same."
        }
        switch kind {
        case .block: return renameBlockDefinition(from: oldTrimmed, to: newTrimmed)
        case .dimstyle: return renameDimensionStyleDefinition(from: oldTrimmed, to: newTrimmed)
        case .layer: return renameLayerByName(from: oldTrimmed, to: newTrimmed)
        case .linetype: return renameLinetypeDefinition(from: oldTrimmed, to: newTrimmed)
        case .textStyle: return renameTextStyleDefinition(from: oldTrimmed, to: newTrimmed)
        case .leaderStyle: return renameLeaderStyleDefinition(from: oldTrimmed, to: newTrimmed)
        }
    }

}

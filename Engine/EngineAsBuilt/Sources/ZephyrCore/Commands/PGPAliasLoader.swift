import Foundation

// =========================================================================
// PGP user-alias loader: parses acadlt.pgp-syntax alias files
// (`ALIAS, *COMMAND`, `;` comments) from the app support directory.
// User aliases win over built-ins; collisions are reported, never silent.
// The LT-shipped PGP is the format reference; no alias file ships with
// the repo — ALIASEDIT creates the user's own on first run.
// =========================================================================

public enum PGPAliasLoader {
    /// User alias file inside the app support directory.
    public static let fileName = "zephyr.pgp"

    public static func supportURL() -> URL {
        (UserSettings.appSupportDirectory() ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(fileName)
    }

    /// Parses PGP alias lines. Returns accepted pairs plus warnings for
    /// malformed lines (bad lines never abort the load).
    public static func parse(
        contents: String
    ) -> (aliases: [(alias: String, command: String)], warnings: [String]) {
        var aliases: [(alias: String, command: String)] = []
        var warnings: [String] = []
        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            let parts = line.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                warnings.append("line \(index + 1): expected 'ALIAS, *COMMAND'")
                continue
            }
            var command = parts[1].uppercased()
            if command.hasPrefix("*") { command.removeFirst() }
            command = command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else {
                warnings.append("line \(index + 1): missing command name")
                continue
            }
            aliases.append((alias: parts[0].uppercased(), command: command))
        }
        return (aliases, warnings)
    }

    /// Loads the user file into the processor when present. Missing file
    /// is not an error (first run). Returns loaded/warning counts.
    @discardableResult
    @MainActor
    public static func loadIfPresent(
        into processor: CADCommandProcessor
    ) -> (loaded: Int, warnings: [String]) {
        let url = supportURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (0, [])
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return (0, ["cannot read \(url.path)"])
        }
        return load(contents: contents, into: processor)
    }

    /// Parses and registers, returning counts for reporting.
    @MainActor
    public static func load(
        contents: String, into processor: CADCommandProcessor
    ) -> (loaded: Int, warnings: [String]) {
        let parsed = parse(contents: contents)
        var loaded = 0
        var warnings = parsed.warnings
        for pair in parsed.aliases {
            if let warning = processor.registerUserAlias(
                pair.alias, for: pair.command) {
                warnings.append(warning)
            } else {
                loaded += 1
            }
        }
        return (loaded, warnings)
    }

    /// Starter file content for ALIASEDIT's first run.
    public static func templateContents() -> String {
        """
        ; Zephyr user command aliases (acadlt.pgp syntax).
        ; One per line: ALIAS, *COMMAND  (alias first, comma, star, command).
        ; Lines starting with ; are comments. User aliases win over built-ins.
        ; After editing, re-run ALIASEDIT to reload.
        ;
        ; Examples (commented out):
        ; AA, *AREA
        ; T, *MTEXT

        """
    }
}

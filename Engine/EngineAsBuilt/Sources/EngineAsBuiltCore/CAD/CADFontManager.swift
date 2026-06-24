import Foundation

// =========================================================================
// MARK: - CADFontManager
//
// Central font lookup and caching for the CAD text rendering pipeline.
// Manages loading of TTF and SHX (AutoCAD shape) fonts used for rendering
// DXF text entities. Provides debugFontLookup to aid in diagnosing
// missing-font issues.

public enum CADFontManager {

    internal nonisolated static let cacheLock = NSRecursiveLock()
    internal static nonisolated(unsafe) var shxFontCache: [String: SHXShapeFont] = [:]

    public static func getOrLoadSHXFont(filename: String) -> SHXShapeFont? {
        let rawName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let normName = rawName.lowercased()

        if normName.hasSuffix(".ttf") || normName.hasSuffix(".otf") {
            return nil
        }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = shxFontCache[normName] {
            return cached
        }

        let exeDir = URL(fileURLWithPath: Bundle.main.executablePath ?? ".")
            .deletingLastPathComponent()

        let fontDirectories = [
            exeDir.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Fonts"),
            exeDir,
            URL(fileURLWithPath: ".")
        ]

        var fileNamesToTry: [String] = []

        func add(_ name: String) {
            guard !name.isEmpty else { return }
            if !fileNamesToTry.contains(name) {
                fileNamesToTry.append(name)
            }
        }

        add(rawName)
        add(normName)

        if !normName.hasSuffix(".shx") {
            add(rawName + ".shx")
            add(rawName + ".SHX")
            add(normName + ".shx")
        }

        for dir in fontDirectories {
            for name in fileNamesToTry {
                let fileURL = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        let resolvedPath = fileURL.path.lowercased()
                        let resolvedName = fileURL.lastPathComponent.lowercased()
                        if let cached = shxFontCache[resolvedPath] ?? shxFontCache[resolvedName] {
                            shxFontCache[normName] = cached
                            return cached
                        }

                        let font = try SHXShapeFont(url: fileURL)
                        guard font.isUsable else {
                            print("[CADFontManager] SHX font has no drawable glyphs, using fallback: \(fileURL.path)")
                            continue
                        }
                        print("[CADFontManager] Loaded SHX font: \(fileURL.path)")
                        shxFontCache[normName] = font
                        shxFontCache[resolvedName] = font
                        shxFontCache[resolvedPath] = font
                        return font
                    } catch {
                        print("[CADFontManager] SHX load error for \(fileURL.path): \(error)")
                    }
                }
            }
        }

        if normName != "simplex.shx" {
            return getOrLoadSHXFont(filename: "simplex.shx")
        }

        return nil
    }


    public static func getTTFEquivalent(filename: String) -> String? {
        let rawName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let normName = rawName.lowercased()

        if normName.hasSuffix(".shx") {
            return nil
        }

        let exeDir = URL(fileURLWithPath: Bundle.main.executablePath ?? ".")
            .deletingLastPathComponent()

        let fontDirectories = [
            exeDir.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Fonts"),
            exeDir,
            URL(fileURLWithPath: "."),
            URL(fileURLWithPath: "/System/Library/Fonts"),
            URL(fileURLWithPath: "/System/Library/Fonts/Supplemental"),
            URL(fileURLWithPath: "/Library/Fonts"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts")
        ]

        var candidates: [String] = []

        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }
        }

        add(rawName)
        add(normName)
        add(rawName.uppercased())

        if !normName.hasSuffix(".ttf") && !normName.hasSuffix(".otf") && !normName.hasSuffix(".ttc") {
            add(rawName + ".ttf")
            add(rawName + ".TTF")
            add(normName + ".ttf")
            add(rawName + ".otf")
            add(rawName + ".OTF")
            add(normName + ".otf")
        }

        if normName.contains("arialn") {
            add("ARIALN.TTF")
            add("arialn.ttf")
            add("Arial Narrow.ttf")
            add("ArialNarrow.ttf")
            add("Arial.ttf")
        } else if normName.contains("lucon") {
            add("lucon.TTF")
            add("lucon.ttf")
            add("LUCON.TTF")
            add("Lucida Console.ttf")
            add("LucidaConsole.ttf")
            add("Menlo.ttc")
            add("Monaco.ttf")
        } else if normName.contains("romans") || normName.contains("simplex") || normName.contains("isocp") {
            add("RomanS.ttf")
            add("Arial.ttf")
            add("Helvetica.ttc")
        }

        add("Arial.ttf")
        add("Helvetica.ttc")
        add("Menlo.ttc")
        add("Monaco.ttf")

        for dir in fontDirectories {
            for name in candidates {
                let lowerName = name.lowercased()
                guard lowerName.hasSuffix(".ttf") || lowerName.hasSuffix(".otf") || lowerName.hasSuffix(".ttc") else {
                    continue
                }
                let fileURL = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    print("[CADFontManager] Using TTF font '\(name)' for DXF font '\(filename)': \(fileURL.path)")
                    return fileURL.path
                }
            }
        }

        print("[CADFontManager] No TTF font found for DXF font '\(filename)'")
        return nil
    }

    /// Font type for UI categorization.
    public enum FontType: String, Sendable, CaseIterable {
        case shxShape = "SHX"
        case truetype = "TTF"
    }

    /// Result type for available fonts listing.
    public struct AvailableFont: Sendable {
        public let name: String
        public let path: String
        public let type: FontType

        public init(name: String, path: String, type: FontType) {
            self.name = name
            self.path = path
            self.type = type
        }
    }

    /// Returns all available fonts from the Fonts/ directory.
    /// Scans for both .shx shape fonts and .ttf/.otf/.ttc TrueType fonts.
    /// Results are cached for the session.
    public static func availableFonts() -> [AvailableFont] {
        struct Cache { nonisolated(unsafe) static var fonts: [AvailableFont]? = nil }
        if let cached = Cache.fonts { return cached }

        var fonts: [AvailableFont] = []
        var seen: Set<String> = []

        let exeDir = URL(fileURLWithPath: Bundle.main.executablePath ?? ".")
            .deletingLastPathComponent()

        let fontDirectories = [
            exeDir.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Fonts"),
        ]

        for dir in fontDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            for case let url as URL in enumerator {
                // Only top-level, skip subdirectories
                if url.deletingLastPathComponent() != dir { continue }

                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent
                let lowerName = name.lowercased()

                guard !seen.contains(lowerName) else { continue }

                if ext == "shx" {
                    seen.insert(lowerName)
                    fonts.append(AvailableFont(name: name, path: url.path, type: .shxShape))
                } else if ext == "ttf" || ext == "otf" || ext == "ttc" {
                    seen.insert(lowerName)
                    fonts.append(AvailableFont(name: name, path: url.path, type: .truetype))
                }
            }
        }

        // Sort: SHX first, then TTF, both alphabetically
        fonts.sort { a, b in
            if a.type != b.type { return a.type == .shxShape }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        Cache.fonts = fonts
        return fonts
    }

    public static func debugFontLookup(_ filename: String) {
        let rawName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let exeDir = URL(fileURLWithPath: Bundle.main.executablePath ?? ".")
            .deletingLastPathComponent()

        let dirs = [
            exeDir.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Fonts"),
            exeDir,
            URL(fileURLWithPath: ".")
        ]

        print("[CADFontManager] lookup '\(filename)'")
        for dir in dirs {
            let url = dir.appendingPathComponent(rawName)
            print("[CADFontManager]   \(url.path) exists=\(FileManager.default.fileExists(atPath: url.path))")
        }
    }
}

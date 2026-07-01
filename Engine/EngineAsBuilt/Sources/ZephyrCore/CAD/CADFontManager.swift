import Foundation
#if os(Windows)
import WinSDK
#endif

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


#if os(Windows)
    /// Lazily builds and caches a mapping from font names to filenames
    /// by reading the Windows font registry.
    /// Keys are lowercased: both display names (stripped of "(TrueType)" etc.)
    /// and bare filenames are indexed.
    private static func windowsFontRegistryMap() -> [String: String]? {
        struct RegCache { nonisolated(unsafe) static var map: [String: String]? = nil }
        if let cached = RegCache.map { return cached }

        var map: [String: String] = [:]
        let subKey = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
        var hKey: HKEY?
        let status = subKey.withCString(encodedAs: UTF16.self) { lpSubKey in
            RegOpenKeyExW(HKEY_LOCAL_MACHINE, lpSubKey, 0, 0x20019, &hKey)
        }
        guard status == ERROR_SUCCESS, let hKey = hKey else {
            print("[CADFontManager] Failed to open Windows font registry key (status=\(status))")
            RegCache.map = [:]
            return nil
        }
        defer { RegCloseKey(hKey) }

        var index: DWORD = 0
        while true {
            let maxLen = 256
            var nameBuf = [WCHAR](repeating: 0, count: maxLen)
            var dataBuf = [WCHAR](repeating: 0, count: maxLen)
            var nameLen: DWORD = DWORD(maxLen)
            var dataLen: DWORD = DWORD(maxLen)
            var valueType: DWORD = 0
            let enumStatus = RegEnumValueW(hKey, index, &nameBuf, &nameLen, nil, &valueType, &dataBuf, &dataLen)
            if enumStatus == ERROR_NO_MORE_ITEMS { break }
            if enumStatus != ERROR_SUCCESS || valueType != REG_SZ || nameLen == 0 || dataLen == 0 {
                index += 1; continue
            }
            let displayName = nameBuf.withUnsafeBufferPointer { buf -> String in
                let end = buf.firstIndex(of: 0) ?? buf.count
                return String(decoding: buf[0..<end], as: UTF16.self)
            }
            let fileName = dataBuf.withUnsafeBufferPointer { buf -> String in
                let end = buf.firstIndex(of: 0) ?? buf.count
                return String(decoding: buf[0..<end], as: UTF16.self)
            }
            let normalized = displayName
                .replacingOccurrences(of: " (TrueType)", with: "")
                .replacingOccurrences(of: " (OpenType)", with: "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let fileLower = fileName.lowercased()
            if !normalized.isEmpty { map[normalized] = fileName }
            map[fileLower] = fileName
            // Also index without extension
            let nameNoExt = (normalized as NSString).deletingPathExtension
            if !nameNoExt.isEmpty, nameNoExt != normalized { map[nameNoExt] = fileName }
            let fileNoExt = (fileLower as NSString).deletingPathExtension
            if !fileNoExt.isEmpty, fileNoExt != fileLower { map[fileNoExt] = fileName }
            index += 1
        }
        RegCache.map = map
        print("[CADFontManager] Indexed \(map.count) entries from Windows font registry")
        return map
    }
#endif

    public static func getTTFEquivalent(filename: String) -> String? {
        let rawName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let normName = rawName.lowercased()

        if normName.hasSuffix(".shx") {
            return nil
        }

        let exeDir = URL(fileURLWithPath: Bundle.main.executablePath ?? ".")
            .deletingLastPathComponent()

        var fontDirectories: [URL] = [
            exeDir.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Fonts"),
            exeDir,
            URL(fileURLWithPath: "."),
            URL(fileURLWithPath: "/System/Library/Fonts"),
            URL(fileURLWithPath: "/System/Library/Fonts/Supplemental"),
            URL(fileURLWithPath: "/Library/Fonts"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts")
        ]
#if os(Windows)
        fontDirectories.append(URL(fileURLWithPath: "C:/Windows/Fonts"))
#endif

        var specificCandidates: [String] = []
        var fallbackCandidates: [String] = []

        func addSpecific(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !specificCandidates.contains(trimmed) {
                specificCandidates.append(trimmed)
            }
        }

        func addFallback(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !fallbackCandidates.contains(trimmed) {
                fallbackCandidates.append(trimmed)
            }
        }

        addSpecific(rawName)
        addSpecific(normName)
        addSpecific(rawName.uppercased())

        if !normName.hasSuffix(".ttf") && !normName.hasSuffix(".otf") && !normName.hasSuffix(".ttc") {
            addSpecific(rawName + ".ttf")
            addSpecific(rawName + ".TTF")
            addSpecific(normName + ".ttf")
            addSpecific(rawName + ".otf")
            addSpecific(rawName + ".OTF")
            addSpecific(normName + ".otf")
        }

        if normName.contains("arialn") {
            addSpecific("ARIALN.TTF")
            addSpecific("arialn.ttf")
            addSpecific("Arial Narrow.ttf")
            addSpecific("ArialNarrow.ttf")
        } else if normName.contains("lucon") {
            addSpecific("lucon.TTF")
            addSpecific("lucon.ttf")
            addSpecific("LUCON.TTF")
            addSpecific("Lucida Console.ttf")
            addSpecific("LucidaConsole.ttf")
        } else if normName.contains("romans") || normName.contains("simplex") || normName.contains("isocp") {
            addSpecific("RomanS.ttf")
        }

        addFallback("Arial.ttf")
        addFallback("Helvetica.ttc")
        addFallback("Menlo.ttc")
        addFallback("Monaco.ttf")

        /// Helper to search a list of candidates across all font directories.
        func search(_ candidates: [String], label: String) -> String? {
            for dir in fontDirectories {
                for name in candidates {
                    let lowerName = name.lowercased()
                    guard lowerName.hasSuffix(".ttf") || lowerName.hasSuffix(".otf") || lowerName.hasSuffix(".ttc") else {
                        continue
                    }
                    let fileURL = dir.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        print("[CADFontManager] Using TTF font '\(name)' (\(label)) for DXF font '\(filename)': \(fileURL.path)")
                        return fileURL.path
                    }
                }
            }
            return nil
        }

        // Phase 1: search for the exact requested font name in all directories.
        if let found = search(specificCandidates, label: "specific") {
            return found
        }

#if os(Windows)
        // Phase 2: Windows registry fallback — resolve display name → filename.
        if let regMap = windowsFontRegistryMap(),
           let resolvedName = regMap[normName] ?? regMap[rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
            let windowsDir = URL(fileURLWithPath: "C:/Windows/Fonts")
            for name in [resolvedName, resolvedName.lowercased()] {
                let url = windowsDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    print("[CADFontManager] Using TTF font '\(resolvedName)' (from registry) for DXF font '\(filename)': \(url.path)")
                    return url.path
                }
            }
        }
#endif

        // Phase 3: fall back to generic fonts (Arial, Helvetica, etc.).
        if let found = search(fallbackCandidates, label: "fallback") {
            return found
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

        var fontDirectories = [
            exeDir.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Fonts"),
        ]
#if os(Windows)
        fontDirectories.append(URL(fileURLWithPath: "C:/Windows/Fonts"))
#endif

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

        var dirs = [
            exeDir.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: "Fonts"),
            exeDir,
            URL(fileURLWithPath: ".")
        ]
#if os(Windows)
        dirs.append(URL(fileURLWithPath: "C:/Windows/Fonts"))
#endif

        print("[CADFontManager] lookup '\(filename)'")
        for dir in dirs {
            let url = dir.appendingPathComponent(rawName)
            print("[CADFontManager]   \(url.path) exists=\(FileManager.default.fileExists(atPath: url.path))")
        }
    }
}

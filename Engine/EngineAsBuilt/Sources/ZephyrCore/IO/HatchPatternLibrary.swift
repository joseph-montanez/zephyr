import Foundation

public struct HatchPatternCatalogEntry: Hashable, Sendable {
    public var key: String
    public var name: String
    public var description: String
    public var sourceName: String
    public var definition: DXFHatchPatternDefinition

    public init(
        key: String,
        name: String,
        description: String,
        sourceName: String,
        definition: DXFHatchPatternDefinition
    ) {
        self.key = key
        self.name = name
        self.description = description
        self.sourceName = sourceName
        self.definition = definition
    }
}

public enum HatchPatternFileParser {
    public struct ParsedPattern: Hashable, Sendable {
        public var name: String
        public var description: String
        public var lines: [DXFHatchPatternLine]

        public init(name: String, description: String, lines: [DXFHatchPatternLine]) {
            self.name = name
            self.description = description
            self.lines = lines
        }
    }

    public static func parse(contents: String) -> [ParsedPattern] {
        var result: [ParsedPattern] = []
        var currentName: String?
        var currentDescription = ""
        var currentLines: [DXFHatchPatternLine] = []

        func finishCurrent() {
            guard let name = currentName, !name.isEmpty else { return }
            result.append(ParsedPattern(
                name: name,
                description: currentDescription,
                lines: currentLines))
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty || line.hasPrefix(";") { continue }

            if line.hasPrefix("*") {
                finishCurrent()
                currentLines.removeAll(keepingCapacity: true)

                let header = String(line.dropFirst())
                let parts = header.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                currentName = parts.first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                currentDescription = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                continue
            }

            guard currentName != nil else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }

            var values: [Double] = []
            values.reserveCapacity(fields.count)
            var valid = true
            for field in fields {
                let valueText = field.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !valueText.isEmpty, let value = Double(valueText), value.isFinite else {
                    valid = false
                    break
                }
                values.append(value)
            }
            guard valid, values.count >= 5 else { continue }

            currentLines.append(DXFHatchPatternLine(
                angleDegrees: values[0],
                base: Vector3(x: values[1], y: values[2], z: 0),
                offset: Vector3(x: values[3], y: values[4], z: 0),
                dashes: Array(values.dropFirst(5))))
        }

        finishCurrent()
        return result
    }

    public static func parse(data: Data) -> [ParsedPattern] {
        let contents = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return parse(contents: contents)
    }
}

public enum HatchPatternLibrary {
    private struct Snapshot {
        var entries: [HatchPatternCatalogEntry]
        var byKey: [String: HatchPatternCatalogEntry]
        var loadedFiles: [URL]

        static let empty = Snapshot(entries: [], byKey: [:], loadedFiles: [])
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot = Snapshot.empty
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var loading = false

    public static func ensureLoaded() {
        while true {
            lock.lock()
            if loaded {
                lock.unlock()
                return
            }
            if !loading {
                loading = true
                lock.unlock()
                break
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
        }

        let newSnapshot = loadSnapshot()

        lock.lock()
        snapshot = newSnapshot
        loaded = true
        loading = false
        lock.unlock()
    }

    public static func reload() {
        lock.lock()
        loaded = false
        loading = false
        snapshot = .empty
        lock.unlock()
        ensureLoaded()
    }

    public static var allPatterns: [HatchPatternCatalogEntry] {
        ensureLoaded()
        lock.lock()
        let value = snapshot.entries
        lock.unlock()
        return value
    }

    public static var loadedFiles: [URL] {
        ensureLoaded()
        lock.lock()
        let value = snapshot.loadedFiles
        lock.unlock()
        return value
    }

    public static func entry(forKey key: String) -> HatchPatternCatalogEntry? {
        ensureLoaded()
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        lock.lock()
        let value = snapshot.byKey[normalized]
        lock.unlock()
        return value
    }

    public static func search(_ query: String) -> [HatchPatternCatalogEntry] {
        let entries = allPatterns
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return entries }

        return entries.filter { entry in
            let haystack = "\(entry.name) \(entry.description) \(entry.sourceName)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    public static func candidateDirectories() -> [URL] {
        var candidates: [URL] = []
        let fm = FileManager.default

        if let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true) {
            candidates.append(support
                .appendingPathComponent("Zephyr", isDirectory: true)
                .appendingPathComponent("Patterns", isDirectory: true))
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Patterns", isDirectory: true))
        candidates.append(cwd
            .appendingPathComponent("Engine", isDirectory: true)
            .appendingPathComponent("EngineAsBuilt", isDirectory: true)
            .appendingPathComponent("Patterns", isDirectory: true))

        if let executable = ProcessInfo.processInfo.arguments.first, !executable.isEmpty {
            let executableDirectory = URL(fileURLWithPath: executable)
                .standardizedFileURL
                .deletingLastPathComponent()
            candidates.append(executableDirectory.appendingPathComponent("Patterns", isDirectory: true))
            candidates.append(executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Patterns", isDirectory: true))
        }

        #if SWIFT_PACKAGE
        if let packageResources = Bundle.module.resourceURL {
            candidates.append(packageResources.appendingPathComponent("Patterns", isDirectory: true))
        }
        #endif

        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Patterns", isDirectory: true))
        }

        var seen = Set<String>()
        return candidates.filter {
            let key = $0.standardizedFileURL.path.lowercased()
            return seen.insert(key).inserted
        }
    }

    private static func loadSnapshot() -> Snapshot {
        let fm = FileManager.default
        var entries: [HatchPatternCatalogEntry] = []
        var loadedFiles: [URL] = []
        var loadedFileNames = Set<String>()

        for directory in candidateDirectories() {
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }

            for file in files
                .filter({ $0.pathExtension.caseInsensitiveCompare("pat") == .orderedSame })
                .sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                let fileNameKey = file.lastPathComponent.uppercased()
                guard loadedFileNames.insert(fileNameKey).inserted else { continue }
                guard let data = try? Data(contentsOf: file) else {
                    loadedFileNames.remove(fileNameKey)
                    continue
                }
                let parsed = HatchPatternFileParser.parse(data: data)
                guard !parsed.isEmpty else { continue }

                loadedFiles.append(file)
                let sourceName = file.deletingPathExtension().lastPathComponent
                let sourceKey = sourceName.uppercased()
                let kind: DXFHatchPatternDefinition.Kind =
                    sourceKey == "ACADLT" || sourceKey == "ACADLTISO"
                    ? .predefined
                    : .custom

                for pattern in parsed where pattern.name != "SOLID" && !pattern.lines.isEmpty {
                    let definition = DXFHatchPatternDefinition(
                        name: pattern.name,
                        kind: kind,
                        lines: pattern.lines)
                    let key = DXFHatchGenerator.registerPatternDefinition(
                        definition,
                        namespace: sourceKey)
                    entries.append(HatchPatternCatalogEntry(
                        key: key,
                        name: pattern.name,
                        description: pattern.description,
                        sourceName: sourceName,
                        definition: definition))
                }
            }
        }

        var uniqueEntries: [String: HatchPatternCatalogEntry] = [:]
        for entry in entries where uniqueEntries[entry.key.uppercased()] == nil {
            uniqueEntries[entry.key.uppercased()] = entry
        }
        entries = Array(uniqueEntries.values)

        var seenFiles = Set<String>()
        loadedFiles = loadedFiles.filter {
            seenFiles.insert($0.standardizedFileURL.path.lowercased()).inserted
        }

        let loadedNames = Set(entries.map { $0.name.uppercased() })
        for definition in DXFHatchGenerator.predefinedPatterns.values
            where !loadedNames.contains(definition.name.uppercased()) {
            entries.append(HatchPatternCatalogEntry(
                key: definition.name.uppercased(),
                name: definition.name,
                description: "Built-in hatch pattern",
                sourceName: "Built-in",
                definition: definition))
        }

        entries.sort {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending
        }

        var byKey: [String: HatchPatternCatalogEntry] = [:]
        for entry in entries { byKey[entry.key.uppercased()] = entry }
        return Snapshot(entries: entries, byKey: byKey, loadedFiles: loadedFiles)
    }
}

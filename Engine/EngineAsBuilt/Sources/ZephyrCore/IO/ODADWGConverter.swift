import Foundation

// =========================================================================
// MARK: - ODADWGConverter
//
// Wraps the ODA FileConverter CLI to convert between DWG and DXF formats.
// ODA FileConverter operates on directories, not individual files, so each
// conversion uses unique temp subfolders to isolate operations.
//
// Usage:
//   - Open DWG:  convert(input: dwgURL, output: tempDXFURL, toFormat: "DXF")
//   - Save as DWG: save DXF to temp, then convert(input: tempDXFURL, output: dwgURL, toFormat: "DWG")
// =========================================================================

// =========================================================================
// MARK: - ODADWGConvertError
// =========================================================================

public enum ODADWGConvertError: Error, LocalizedError {
    case converterNotFound
    case processFailed(exitCode: Int32, stderr: String)
    case outputMissing(expectedPath: String)
    case fileCopyFailed(Error)
    case tempDirFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .converterNotFound:
            return "ODA FileConverter not found. Run INSTALLODA to install it."
        case .processFailed(let exitCode, let stderr):
            return "ODA FileConverter failed (exit \(exitCode)): \(stderr)"
        case .outputMissing(let path):
            return "ODA FileConverter did not produce the expected output file at \(path)"
        case .fileCopyFailed(let err):
            return "File copy failed: \(err.localizedDescription)"
        case .tempDirFailed(let err):
            return "Failed to create temp directory: \(err.localizedDescription)"
        }
    }
}

// =========================================================================
// MARK: - ODADWGConverter
// =========================================================================

/// Stateless utility for DWG ↔ DXF conversion via ODA FileConverter CLI.
public enum ODADWGConverter {

    /// UserDefaults key where INSTALLODA stores the converter binary path.
    private static let pathDefaultsKey = "ODAFileConverterPath"

    // MARK: - Locate Converter

    /// Returns the path to the ODAFileConverter binary, or nil if not found.
    /// Search order:
    ///   1. UserDefaults (set by INSTALLODA)
    ///   2. User Application Support directory
    ///   3. macOS system /Applications (inside .app bundle)
    ///   4. Windows C:\Program Files\ODA\ (versioned subdirectory)
    public static func locateConverter() -> String? {
        let fm = FileManager.default

        // 1. UserDefaults override
        if let savedPath = UserDefaults.standard.string(forKey: pathDefaultsKey),
           fm.isExecutableFile(atPath: savedPath) {
            return savedPath
        }

        // 2. User Application Support (INSTALLODA target)
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let bundledPath = appSupport
                .appendingPathComponent("ODAFileConverter")
            #if os(Windows)
                .appendingPathComponent("ODAFileConverter.exe")
            #else
                .appendingPathComponent("ODAFileConverter.app/Contents/MacOS/ODAFileConverter")
            #endif
            if fm.isExecutableFile(atPath: bundledPath.path) {
                return bundledPath.path
            }
        }

        // 3. macOS: well-known /Applications path (binary inside .app bundle)
        #if os(macOS)
        let systemAppPath = "/Applications/ODAFileConverter.app/Contents/MacOS/ODAFileConverter"
        if fm.isExecutableFile(atPath: systemAppPath) {
            return systemAppPath
        }
        #endif

        // 4. Windows: enumerate C:\Program Files\ODA\ for versioned subdirs
        #if os(Windows)
        let programFilesODA = "C:\\Program Files\\ODA"
        if fm.fileExists(atPath: programFilesODA) {
            if let contents = try? fm.contentsOfDirectory(atPath: programFilesODA) {
                for dir in contents.sorted().reversed() {  // newest first
                    if dir.lowercased().hasPrefix("odafileconverter") {
                        let exePath = "\(programFilesODA)\\\(dir)\\ODAFileConverter.exe"
                        if fm.isExecutableFile(atPath: exePath) {
                            return exePath
                        }
                    }
                }
            }
        }
        #endif

        return nil
    }

    /// Whether the ODA FileConverter is installed and locatable.
    public static var isAvailable: Bool {
        locateConverter() != nil
    }

    // MARK: - Conversion

    /// Convert a DWG or DXF file to the opposite format via ODA FileConverter CLI.
    ///
    /// Because ODA FileConverter works on **directories** (not files), this method:
    /// 1. Creates unique temp input/output subfolders
    /// 2. Copies the source file into the input folder
    /// 3. Invokes the CLI on the folders (with an explicit input filter)
    /// 4. Locates the result by re-basing the filename extension
    /// 5. Moves the result to the target path
    /// 6. Cleans up both temp folders
    ///
    /// - Parameters:
    ///   - input: URL of the source file (.dwg or .dxf)
    ///   - output: URL where the converted file should be placed
    ///   - toFormat: "DXF" or "DWG"
    public static func convert(
        input: URL,
        output: URL,
        toFormat: String
    ) async throws {
        guard let converterPath = locateConverter() else {
            throw ODADWGConvertError.converterNotFound
        }

        let fm = FileManager.default
        let tmpBase = fm.temporaryDirectory
        let uid = UUID().uuidString

        let inputDir = tmpBase.appendingPathComponent("oda-in-\(uid)")
        let outputDir = tmpBase.appendingPathComponent("oda-out-\(uid)")

        // Ensure output parent directory exists
        let outputParent = output.deletingLastPathComponent()
        if !fm.fileExists(atPath: outputParent.path) {
            try fm.createDirectory(at: outputParent, withIntermediateDirectories: true)
        }

        do {
            // 1. Create temp directories
            try fm.createDirectory(at: inputDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

            // 2. Copy source file into input directory
            let sourceFilename = input.lastPathComponent
            let inputCopy = inputDir.appendingPathComponent(sourceFilename)
            do {
                try fm.copyItem(at: input, to: inputCopy)
            } catch {
                throw ODADWGConvertError.fileCopyFailed(error)
            }

            // 3. Run ODAFileConverter
            let version = "ACAD2018"
            let recursive = "0"
            let audit = "1"

            try await runConverter(
                path: converterPath,
                inputDir: inputDir.path,
                outputDir: outputDir.path,
                version: version,
                format: toFormat,
                recursive: recursive,
                audit: audit,
                filter: sourceFilename
            )

            // 4. Locate the result - same basename, swapped extension
            let targetExt = toFormat.lowercased()
            let resultBasename = input.deletingPathExtension().lastPathComponent
            let resultFilename = "\(resultBasename).\(targetExt)"
            let resultPath = outputDir.appendingPathComponent(resultFilename)

            guard fm.fileExists(atPath: resultPath.path) else {
                // List output dir contents for debugging
                let contents = (try? fm.contentsOfDirectory(atPath: outputDir.path)) ?? []
                print("[ODADWGConverter] Output dir contents: \(contents)")
                throw ODADWGConvertError.outputMissing(expectedPath: resultPath.path)
            }

            // 5. Move result to target path
            if fm.fileExists(atPath: output.path) {
                try fm.removeItem(at: output)
            }
            try fm.moveItem(at: resultPath, to: output)
        } catch let error as ODADWGConvertError {
            throw error
        } catch {
            throw ODADWGConvertError.processFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        // 6. Cleanup temp directories (best-effort)
        try? fm.removeItem(at: inputDir)
        try? fm.removeItem(at: outputDir)
    }

    // MARK: - Convert convenience

    /// Synchronous convenience (for sync TabManager methods).
    /// Wraps the async convert in a Task and blocks. Only use where async is not available.
    public static func convertSync(
        input: URL,
        output: URL,
        toFormat: String
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()

        Task { @Sendable [errorBox] in
            do {
                try await convert(input: input, output: output, toFormat: toFormat)
            } catch {
                errorBox.error = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        if let error = errorBox.error {
            throw error
        }
    }

    /// Thread-safe box for bridging errors across async/sync boundary.
    private final class ErrorBox: @unchecked Sendable {
        var error: (any Error)?
    }

    // MARK: - Private: Process Execution

    private static func runConverter(
        path: String,
        inputDir: String,
        outputDir: String,
        version: String,
        format: String,
        recursive: String,
        audit: String,
        filter: String
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [inputDir, outputDir, version, format, recursive, audit, filter]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startTime = Date()
        print("[ODADWGConverter] Running: \(path) \(process.arguments?.joined(separator: " ") ?? "")")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ODADWGConvertError.processFailed(
                exitCode: -1,
                stderr: "Failed to launch process: \(error.localizedDescription)"
            )
        }

        let elapsed = Date().timeIntervalSince(startTime)
        print("[ODADWGConverter] Completed in \(String(format: "%.1f", elapsed))s, exit code: \(process.terminationStatus)")

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "(no stderr)"
            throw ODADWGConvertError.processFailed(
                exitCode: process.terminationStatus,
                stderr: errorStr
            )
        }
    }
}

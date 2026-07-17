import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImGui
import SwiftSDL
import CSDL3


private struct ODADownloadUpdate: Sendable {
    let progress: Float?
    let downloadedBytes: Int64
    let expectedBytes: Int64
    let bytesPerSecond: Double
    let status: String?
}

private struct ODAInstallCompletion: Sendable {
    let success: Bool
    let message: String
    let installedPath: String?
}

private struct ODAInstallWorkerSnapshot: Sendable {
    let downloadUpdate: ODADownloadUpdate?
    let installStatus: String?
    let completion: ODAInstallCompletion?
}

private final class ODAInstallWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var latestDownloadUpdate: ODADownloadUpdate?
    private var latestInstallStatus: String?
    private var completion: ODAInstallCompletion?
    private var activeProcess: Process?
    private var cancelled = false

    func publishDownload(_ update: ODADownloadUpdate) {
        lock.withLock {
            guard !cancelled, completion == nil else { return }
            latestDownloadUpdate = update
        }
    }

    func publishInstallStatus(_ status: String) {
        lock.withLock {
            guard !cancelled, completion == nil else { return }
            latestInstallStatus = status
        }
    }

    func setActiveProcess(_ process: Process?) {
        let shouldTerminate = lock.withLock { () -> Bool in
            if cancelled {
                return process != nil
            }
            activeProcess = process
            return false
        }
        if shouldTerminate, let process, process.isRunning {
            process.terminate()
        }
    }

    func finish(success: Bool, message: String, installedPath: String? = nil) {
        lock.withLock {
            guard !cancelled, completion == nil else { return }
            activeProcess = nil
            completion = ODAInstallCompletion(
                success: success,
                message: message,
                installedPath: installedPath
            )
        }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            latestDownloadUpdate = nil
            latestInstallStatus = nil
            completion = nil
            let process = activeProcess
            activeProcess = nil
            return process
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func drain() -> ODAInstallWorkerSnapshot {
        lock.withLock {
            let snapshot = ODAInstallWorkerSnapshot(
                downloadUpdate: latestDownloadUpdate,
                installStatus: latestInstallStatus,
                completion: completion
            )
            latestDownloadUpdate = nil
            latestInstallStatus = nil
            completion = nil
            return snapshot
        }
    }
}

#if os(Windows)
private final class ODADownloadOperation: @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (ODADownloadUpdate) -> Void
    private let lock = NSLock()

    private var process: Process?

    init(
        destination: URL,
        onProgress: @escaping @Sendable (ODADownloadUpdate) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await performDownload(from: url)
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let process = lock.withLock { self.process }
        guard let process, process.isRunning else { return }

        process.terminate()

        let windowsDirectory = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        let taskkill = windowsDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            + "\\System32\\taskkill.exe"
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: taskkill)
        killer.arguments = [
            "/PID", String(process.processIdentifier),
            "/T", "/F",
        ]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
    }

    private func performDownload(from url: URL) async throws -> URL {
        let windowsDirectory = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        let curl = windowsDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            + "\\System32\\curl.exe"

        guard FileManager.default.fileExists(atPath: curl) else {
            throw NSError(
                domain: "InstallODA",
                code: -10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Windows curl.exe was not found at \(curl). The ODA installer cannot be downloaded."
                ]
            )
        }

        return try await performCurlDownload(from: url, curl: curl)
    }

    private func performCurlDownload(from url: URL, curl: String) async throws -> URL {
        let fileManager = FileManager.default
        let token = UUID().uuidString
        let headerFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).headers")
        let outputFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).out")
        let errorFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).err")

        try? fileManager.removeItem(at: destination)
        try? fileManager.removeItem(at: headerFile)

        guard fileManager.createFile(atPath: destination.path, contents: nil),
              fileManager.createFile(atPath: headerFile.path, contents: nil),
              fileManager.createFile(atPath: outputFile.path, contents: nil),
              fileManager.createFile(atPath: errorFile.path, contents: nil) else {
            throw NSError(
                domain: "InstallODA",
                code: -11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to create temporary downloader files."
                ]
            )
        }

        let outputHandle = try FileHandle(forWritingTo: outputFile)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? fileManager.removeItem(at: headerFile)
            try? fileManager.removeItem(at: outputFile)
            try? fileManager.removeItem(at: errorFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: curl)
        process.arguments = [
            "--location",
            "--fail",
            "--silent",
            "--show-error",
            "--compressed",
            "--tlsv1.2",
            "--connect-timeout", "20",
            "--max-time", "1800",
            "--speed-time", "60",
            "--speed-limit", "1",
            "--retry", "2",
            "--retry-delay", "1",
            "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ZephyrCAD/1.0",
            "--header", "Cache-Control: no-cache",
            "--header", "Pragma: no-cache",
            "--dump-header", headerFile.path,
            "--output", destination.path,
            "--write-out", "HTTP_CODE:%{http_code}\\nEFFECTIVE_URL:%{url_effective}\\nSIZE_DOWNLOAD:%{size_download}\\n",
            url.absoluteString,
        ]
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        lock.withLock {
            self.process = process
        }

        defer {
            lock.withLock {
                if self.process === process {
                    self.process = nil
                }
            }
        }

        print("[InstallODA] Windows downloader: \(curl)")

        onProgress(ODADownloadUpdate(
            progress: nil,
            downloadedBytes: 0,
            expectedBytes: -1,
            bytesPerSecond: 0,
            status: "Launching Windows curl downloader..."
        ))

        print("[InstallODA] Launching curl process...")
        do {
            try process.run()
            print("[InstallODA] curl started, PID=\(process.processIdentifier)")
        } catch {
            throw NSError(
                domain: "InstallODA",
                code: -12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to launch Windows curl: \(error.localizedDescription)"
                ]
            )
        }

        let startedAt = Date()
        var lastReportedBytes: Int64 = -1
        var lastSampleBytes: Int64 = 0
        var lastSampleDate = Date()
        var lastProgressUpdate = Date.distantPast
        var lastActivityDate = Date()
        var lastHeaderSignature = ""
        var calculatedSpeed = 0.0
        var expectedBytes: Int64 = -1
        var statusMessage = "Connecting to Open Design Alliance..."
        var receivedDownloadHeaders = false

        do {
            while process.isRunning {
                try Task.checkCancellation()

                let now = Date()
                let fileBytes = Self.fileSize(destination)
                let header = Self.readCurlHeaderState(headerFile, requestURL: url)

                if let header {
                    let signature = "\(header.statusCode)|\(header.host)|\(header.contentLength)"
                    if signature != lastHeaderSignature {
                        lastHeaderSignature = signature
                        lastActivityDate = now
                    }

                    if (200...299).contains(header.statusCode) {
                        receivedDownloadHeaders = true
                        if header.contentLength > 0 {
                            expectedBytes = header.contentLength
                        }
                        statusMessage = fileBytes > 0
                            ? "Downloading from \(header.host)..."
                            : "Connected to \(header.host). Waiting for download data..."
                    } else if (300...399).contains(header.statusCode) {
                        statusMessage = "Redirecting to \(header.host)..."
                    } else {
                        statusMessage = "Server returned HTTP \(header.statusCode) from \(header.host)."
                    }
                } else {
                    let elapsed = Int(now.timeIntervalSince(startedAt))
                    let remaining = max(0, 45 - elapsed)
                    statusMessage = "Connecting to Open Design Alliance... timeout in \(remaining)s"
                }

                if fileBytes > max(0, lastReportedBytes) {
                    lastActivityDate = now
                }

                let sampleElapsed = now.timeIntervalSince(lastSampleDate)
                if sampleElapsed >= 0.25 {
                    calculatedSpeed = Double(max(0, fileBytes - lastSampleBytes)) / sampleElapsed
                    lastSampleBytes = fileBytes
                    lastSampleDate = now
                }

                if !receivedDownloadHeaders,
                   now.timeIntervalSince(startedAt) >= 45 {
                    cancel()
                    try? fileManager.removeItem(at: destination)
                    throw NSError(
                        domain: "InstallODA",
                        code: -13,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Timed out waiting 45 seconds for Open Design Alliance to return download headers. Windows curl was terminated. Check firewall, proxy, DNS, and TLS inspection settings."
                        ]
                    )
                }

                if receivedDownloadHeaders,
                   now.timeIntervalSince(lastActivityDate) >= 60 {
                    cancel()
                    try? fileManager.removeItem(at: destination)
                    throw NSError(
                        domain: "InstallODA",
                        code: -14,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The ODA download made no progress for 60 seconds and was stopped. Check firewall, proxy, or antivirus HTTPS inspection settings."
                        ]
                    )
                }

                if now.timeIntervalSince(lastProgressUpdate) >= 0.20
                    || fileBytes != lastReportedBytes {
                    let progress: Float? = expectedBytes > 0
                        ? Float(Double(fileBytes) / Double(expectedBytes))
                        : nil

                    onProgress(ODADownloadUpdate(
                        progress: progress,
                        downloadedBytes: fileBytes,
                        expectedBytes: expectedBytes,
                        bytesPerSecond: calculatedSpeed,
                        status: statusMessage
                    ))

                    lastReportedBytes = fileBytes
                    lastProgressUpdate = now
                }

                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
        } catch {
            cancel()
            try? fileManager.removeItem(at: destination)
            throw error
        }

        try? outputHandle.synchronize()
        try? errorHandle.synchronize()
        try? outputHandle.close()
        try? errorHandle.close()

        let standardOutput = (try? String(
            contentsOf: outputFile,
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = (try? String(
            contentsOf: errorFile,
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destination)
            let processOutput = [errorOutput, standardOutput]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let message = processOutput.isEmpty
                ? "curl.exe exited with code \(process.terminationStatus)."
                : processOutput
            throw NSError(
                domain: "InstallODA",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let finalSize = Self.fileSize(destination)
        guard finalSize > 0 else {
            throw NSError(
                domain: "InstallODA",
                code: -15,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Windows curl completed without producing a file.\n\(standardOutput)"
                ]
            )
        }

        onProgress(ODADownloadUpdate(
            progress: 1,
            downloadedBytes: finalSize,
            expectedBytes: finalSize,
            bytesPerSecond: calculatedSpeed,
            status: "Download complete."
        ))

        return destination
    }

    private struct CurlHeaderState {
        let statusCode: Int
        let contentLength: Int64
        let host: String
    }

    private static func readCurlHeaderState(
        _ url: URL,
        requestURL: URL
    ) -> CurlHeaderState? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var currentHost = requestURL.host ?? "Open Design Alliance"
        var result: CurlHeaderState?

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard let statusLine = lines.first,
                  statusLine.hasPrefix("HTTP/") else {
                continue
            }

            let statusFields = statusLine.split(separator: " ")
            guard statusFields.count >= 2,
                  let statusCode = Int(statusFields[1]) else {
                continue
            }

            var contentLength: Int64 = -1
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = String(line[..<colon])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if name == "content-length" {
                    contentLength = Int64(value) ?? -1
                } else if name == "location",
                          let redirectURL = URL(string: value),
                          let redirectHost = redirectURL.host,
                          !redirectHost.isEmpty {
                    currentHost = redirectHost
                }
            }

            result = CurlHeaderState(
                statusCode: statusCode,
                contentLength: contentLength,
                host: currentHost
            )
        }

        return result
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else {
            return 0
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
#else
private final class ODADownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (ODADownloadUpdate) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloadedResult: Result<URL, Error>?
    private var completed = false
    private var lastBytes: Int64 = 0
    private var lastSpeed: Double = 0
    private var lastSample = Date()

    init(
        destination: URL,
        onProgress: @escaping @Sendable (ODADownloadUpdate) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if completed {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()

                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 60 * 30
                configuration.httpMaximumConnectionsPerHost = 2

                let delegateQueue = OperationQueue()
                delegateQueue.name = "Zephyr.ODADownload"
                delegateQueue.maxConcurrentOperationCount = 1

                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )

                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = 60
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                request.setValue("ZephyrCAD/1.0", forHTTPHeaderField: "User-Agent")

                let task = session.downloadTask(with: request)

                lock.lock()
                if completed {
                    lock.unlock()
                    task.cancel()
                    session.invalidateAndCancel()
                    return
                }
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let task = self.task
        let session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: destination)
        continuation?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()

        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed >= 0.20 {
            lastSpeed = Double(max(0, totalBytesWritten - lastBytes)) / elapsed
            lastBytes = totalBytesWritten
            lastSample = now
        }
        let speed = lastSpeed
        lock.unlock()

        let progress: Float? = totalBytesExpectedToWrite > 0
            ? Float(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : nil

        let update = ODADownloadUpdate(
            progress: progress,
            downloadedBytes: totalBytesWritten,
            expectedBytes: totalBytesExpectedToWrite,
            bytesPerSecond: speed,
            status: nil
        )

        onProgress(update)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            downloadedResult = .success(destination)
            lock.unlock()
        } catch {
            lock.lock()
            downloadedResult = .failure(error)
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        if let response = task.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(NSError(
                domain: "InstallODA",
                code: response.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "ODA download failed with HTTP status \(response.statusCode)."
                ]
            )))
            return
        }

        lock.lock()
        let result = downloadedResult
        lock.unlock()

        finish(result ?? .failure(NSError(
            domain: "InstallODA",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The ODA download ended without producing a file."
            ]
        )))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
#endif
@MainActor
public final class InstallODACommand: FeatureCommand {

    private enum State {
        case showingAgreement
        case downloading
        case installing
        case finished(success: Bool, message: String)
    }

    private var state: State = .showingAgreement
    private var agreed = false
    private var downloadProgress: Float = 0
    private var hasDeterminateProgress = false
    private var downloadSpeed = ""
    private var statusText = ""
    private var sourceURLText = ""
    private var operationStartedAt: Date?
    private var installTask: Task<Void, Never>?
    private var activeDownload: ODADownloadOperation?
    private var workerState: ODAInstallWorkerState?
    private var modalOpened = false

    private static let fallbackURLs: [String: String] = [
        "windows": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_vc16_amd64dll_27.1.msi",
        "macos_arm64": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_macOsX_arm64_15.0dll_27.1.dmg",
        "macos_x64": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_macOsX_x64_15.0dll_27.1.dmg",
    ]

    private static let agreementURL = "https://www.opendesign.com/agreements/2025/en/ODA%20Community%20User%20Agreement%2009-2025.pdf"

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        stopActiveInstall()
        state = .showingAgreement
        agreed = false
        downloadProgress = 0
        hasDeterminateProgress = false
        downloadSpeed = ""
        statusText = ""
        sourceURLText = ""
        operationStartedAt = nil
        modalOpened = false
        processor.commandPrompt = "ODA FileConverter installation."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        stopActiveInstall()
        state = .showingAgreement
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func renderImGui(engine: PhrostEngine) {
        drainWorkerState()

        let id = "ODA FileConverter##InstallODA"
        if !modalOpened {
            ImGuiOpenPopup(id, Int32(ImGuiPopupFlags_None.rawValue))
            modalOpened = true
        }

        let io = ImGuiGetIO()!
        let displayWidth = io.pointee.DisplaySize.x
        let displayHeight = io.pointee.DisplaySize.y
        let desiredSize: ImVec2

        switch state {
        case .showingAgreement:
            desiredSize = ImVec2(
                x: min(ImGuiGetFontSize() * 52, displayWidth * 0.70),
                y: min(ImGuiGetFontSize() * 34, displayHeight * 0.70)
            )
        case .downloading, .installing:
            desiredSize = ImVec2(
                x: min(ImGuiGetFontSize() * 48, displayWidth * 0.78),
                y: min(ImGuiGetFontSize() * 18, displayHeight * 0.74)
            )
        case .finished:
            desiredSize = ImVec2(
                x: min(ImGuiGetFontSize() * 42, displayWidth * 0.70),
                y: min(ImGuiGetFontSize() * 10, displayHeight * 0.70)
            )
        }

        ImGuiSetNextWindowPos(
            ImVec2(
                x: (displayWidth - desiredSize.x) * 0.5,
                y: (displayHeight - desiredSize.y) * 0.5
            ),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0)
        )
        ImGuiSetNextWindowSize(desiredSize, Int32(ImGuiCond_Always.rawValue))

        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
            | Int32(ImGuiWindowFlags_NoMove.rawValue)

        var open = true
        guard ImGuiBeginPopupModal(id, &open, flags) else { return }
        defer { ImGuiEndPopup() }

        if !open {
            stopActiveInstall()
            engine.commandProcessor.finishFeatureCommand(engine: engine)
            return
        }

        switch state {
        case .showingAgreement:
            renderAgreementContent()
        case .downloading:
            renderDownloadContent()
        case .installing:
            renderInstallContent()
        case .finished(let success, let message):
            renderFinishedContent(success: success, message: message, engine: engine)
        }
    }

    private func renderAgreementContent() {
        ImGuiTextV("ODA FileConverter Installation")
        ImGuiSpacing()
        ImGuiSeparator()
        ImGuiSpacing()
        ImGuiTextWrappedV("The ODA FileConverter converts between DWG and DXF formats. It is required to open and save AutoCAD DWG files.")
        ImGuiSpacing()
        ImGuiTextWrappedV("To use this software, you must accept the ODA Community User Agreement.")
        ImGuiSpacing()

        if ImGuiButton("View Agreement (opens in browser)", ImVec2(x: 0, y: 0)) {
            _ = Self.agreementURL.withCString { SDL_OpenURL($0) }
        }

        ImGuiSpacing()
        ImGuiSeparator()
        ImGuiSpacing()
        ImGuiCheckbox("I agree to the ODA Community User Agreement", &agreed)
        ImGuiSpacing()

        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ODAFileConverter")
            .path ?? "Application Support/ODAFileConverter"

        ImGuiTextV("Install location:")
        ImGuiSameLine(0, -1)
        ImGuiTextDisabledV(directory)
        ImGuiSpacing()
        ImGuiSeparator()
        ImGuiSpacing()

        if !agreed {
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_Alpha.rawValue), Float(0.5))
            ImGuiButton("Install", ImVec2(x: 120, y: 0))
            ImGuiPopStyleVar(1)
            ImGuiSameLine(0, -1)
            ImGuiTextDisabledV("(you must agree first)")
        } else if ImGuiButton("Install", ImVec2(x: 120, y: 0)) {
            startInstall()
        }

        ImGuiSameLine(0, -1)
        if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) {
            state = .finished(success: false, message: "Cancelled.")
        }
    }

    private func renderDownloadContent() {
        ImGuiTextV("Downloading ODA FileConverter...")
        ImGuiSpacing()

        if hasDeterminateProgress {
            ImGuiProgressBar(downloadProgress, ImVec2(x: 0, y: 0), nil)
        } else {
            ImGuiProgressBar(0, ImVec2(x: 0, y: 0), "Waiting for server response")
        }

        ImGuiSpacing()
        if !statusText.isEmpty { ImGuiTextWrappedV(statusText) }
        if !downloadSpeed.isEmpty { ImGuiTextV(downloadSpeed) }
        if let operationStartedAt {
            ImGuiTextDisabledV(
                "Elapsed: \(Self.formatDuration(Date().timeIntervalSince(operationStartedAt)))"
            )
        }
        if !sourceURLText.isEmpty {
            ImGuiSpacing()
            ImGuiTextV("Source URL:")
            ImGuiTextWrappedV(sourceURLText)
        }
        ImGuiSpacing()

        if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) {
            cancelInstallFromUI()
        }
    }

    private func renderInstallContent() {
        ImGuiTextV("Installing ODA FileConverter...")
        ImGuiSpacing()
        ImGuiProgressBar(Self.activityProgress(), ImVec2(x: 0, y: 0), "Installing")
        ImGuiSpacing()
        if !statusText.isEmpty { ImGuiTextWrappedV(statusText) }
        if let operationStartedAt {
            ImGuiTextDisabledV(
                "Elapsed: \(Self.formatDuration(Date().timeIntervalSince(operationStartedAt)))"
            )
        }
    }

    private func renderFinishedContent(
        success: Bool,
        message: String,
        engine: PhrostEngine
    ) {
        if success {
            ImGuiTextColoredV(
                ImVec4(x: 0.2, y: 0.9, z: 0.3, w: 1),
                "Installation Complete!"
            )
        } else if message == "Cancelled." {
            ImGuiTextColoredV(
                ImVec4(x: 0.9, y: 0.7, z: 0.2, w: 1),
                "Installation Cancelled"
            )
        } else {
            ImGuiTextColoredV(
                ImVec4(x: 0.9, y: 0.3, z: 0.3, w: 1),
                "Installation Failed"
            )
        }

        ImGuiSpacing()
        ImGuiTextWrappedV(message)
        ImGuiSpacing()
        ImGuiSpacing()

        if ImGuiButton("OK", ImVec2(x: 120, y: 0)) {
            stopActiveInstall()
            ImGuiCloseCurrentPopup()
            engine.commandProcessor.finishFeatureCommand(engine: engine)
        }
    }

    private func startInstall() {
        stopActiveInstall()

        let baseURL: URL
        do {
            baseURL = try resolveURL()
        } catch {
            state = .finished(success: false, message: error.localizedDescription)
            return
        }

        let requestURL = Self.cacheBustedURL(baseURL)
        let temporaryFile = Self.temporaryDownloadURL(for: baseURL)
        let workerState = ODAInstallWorkerState()
        self.workerState = workerState

        state = .downloading
        statusText = "Connecting to Open Design Alliance..."
        sourceURLText = requestURL.absoluteString
        operationStartedAt = Date()
        downloadProgress = 0
        hasDeterminateProgress = false
        downloadSpeed = ""

        let download = ODADownloadOperation(
            destination: temporaryFile,
            onProgress: { update in
                workerState.publishDownload(update)
            }
        )
        activeDownload = download

        print("[InstallODA] Downloading \(requestURL.absoluteString)")
        print("[InstallODA] To: \(temporaryFile.path)")

        installTask = Task.detached(priority: .userInitiated) { [download, workerState] in
            do {
                let file = try await download.download(from: requestURL)
                defer { try? FileManager.default.removeItem(at: file) }

                #if os(Windows)
                try Self.validateMSI(at: file)
                #endif

                try Task.checkCancellation()
                workerState.publishInstallStatus("Preparing installer...")

                let installedPath = try await Self.runInstall(
                    file: file,
                    onProcess: { process in
                        workerState.setActiveProcess(process)
                    },
                    onStatus: { status in
                        workerState.publishInstallStatus(status)
                    }
                )

                try Task.checkCancellation()
                workerState.finish(
                    success: true,
                    message: "ODA FileConverter installed. You can now open and save DWG files.",
                    installedPath: installedPath
                )
            } catch is CancellationError {
                workerState.finish(
                    success: false,
                    message: "Cancelled."
                )
            } catch {
                workerState.finish(
                    success: false,
                    message: Self.failureMessage(
                        error,
                        sourceURL: requestURL
                    )
                )
            }
        }
    }

    private func cancelInstallFromUI() {
        stopActiveInstall()
        statusText = ""
        downloadSpeed = ""
        operationStartedAt = nil
        state = .finished(success: false, message: "Cancelled.")
    }

    private func stopActiveInstall() {
        let workerState = self.workerState
        self.workerState = nil
        workerState?.cancel()

        let download = activeDownload
        activeDownload = nil
        download?.cancel()

        let task = installTask
        installTask = nil
        task?.cancel()
    }

    private func drainWorkerState() {
        guard let workerState else { return }
        let snapshot = workerState.drain()

        if let update = snapshot.downloadUpdate {
            applyDownloadUpdate(update)
        }

        if let status = snapshot.installStatus {
            if case .downloading = state {
                state = .installing
                operationStartedAt = Date()
                downloadSpeed = ""
            }
            statusText = status
        }

        if let completion = snapshot.completion {
            activeDownload = nil
            installTask = nil
            self.workerState = nil
            operationStartedAt = nil

            if completion.success, let installedPath = completion.installedPath {
                UserDefaults.standard.set(installedPath, forKey: "ODAFileConverterPath")
            }

            state = .finished(
                success: completion.success,
                message: completion.message
            )
        }
    }

    private func applyDownloadUpdate(_ update: ODADownloadUpdate) {
        if let progress = update.progress {
            hasDeterminateProgress = true
            downloadProgress = max(0, min(progress, 1))
        }

        if update.downloadedBytes == 0,
           let status = update.status,
           !status.isEmpty {
            statusText = status
        } else if update.expectedBytes > 0 {
            statusText = "\(Self.formatBytes(update.downloadedBytes)) of \(Self.formatBytes(update.expectedBytes))"
        } else {
            statusText = "\(Self.formatBytes(update.downloadedBytes)) downloaded"
        }
        if update.bytesPerSecond > 0 {
            downloadSpeed = Self.formatSpeed(update.bytesPerSecond)
        } else if update.downloadedBytes <= 0 {
            downloadSpeed = ""
        }
    }

    private func resolveURL() throws -> URL {
        #if os(Windows)
        let key = "windows"
        #elseif os(macOS)
        #if arch(arm64)
        let key = "macos_arm64"
        #else
        let key = "macos_x64"
        #endif
        #else
        throw NSError(
            domain: "InstallODA",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported platform"]
        )
        #endif

        guard let string = Self.fallbackURLs[key], let url = URL(string: string) else {
            throw NSError(
                domain: "InstallODA",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No download URL is configured for \(key)."]
            )
        }
        return url
    }

    nonisolated private static func cacheBustedURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll {
            $0.name.caseInsensitiveCompare("zephyrCacheBust") == .orderedSame
        }
        queryItems.append(URLQueryItem(
            name: "zephyrCacheBust",
            value: String(Int(Date().timeIntervalSince1970))
        ))
        components?.queryItems = queryItems
        return components?.url ?? url
    }

    nonisolated private static func temporaryDownloadURL(for url: URL) -> URL {
        let filename = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first {
                $0.name.caseInsensitiveCompare("filename") == .orderedSame
            }?
            .value ?? url.lastPathComponent
        let safeFilename = filename.isEmpty
            ? "ODAFileConverter.download"
            : filename
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeFilename)")
    }

    nonisolated private static func validateMSI(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        let expected = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

        guard header == expected else {
            throw NSError(
                domain: "InstallODA",
                code: -9,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Open Design Alliance returned a file that is not a valid MSI installer. The download may have been an expired redirect or an HTML error page."
                ]
            )
        }
    }


    nonisolated private static func runInstall(
        file: URL,
        onProcess: @escaping @Sendable (Process?) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NSError(
                domain: "InstallODA",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No Application Support directory is available."
                ]
            )
        }

        let target = applicationSupport.appendingPathComponent("ODAFileConverter")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )

        #if os(Windows)
        onStatus("Starting Windows Installer...")
        let windowsDirectory = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        let msiexec = windowsDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            + "\\System32\\msiexec.exe"
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let installerID = UUID().uuidString
        let installerLog = temporaryDirectory
            .appendingPathComponent("oda-msi-\(installerID).log")
        let installerScript = temporaryDirectory
            .appendingPathComponent("oda-msi-\(installerID).cmd")
        defer {
            try? FileManager.default.removeItem(at: installerLog)
            try? FileManager.default.removeItem(at: installerScript)
        }

        let cmd = windowsDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            + "\\System32\\cmd.exe"
        let nativeMSIPath = windowsNativePath(file.path)
        let nativeLogPath = windowsNativePath(installerLog.path)
        let nativeTargetPath = windowsNativePath(target.path)
        let nativeMSIExecPath = windowsNativePath(msiexec)

        let script = """
        @echo off
        "%ODA_MSIEXEC%" /a "%ODA_MSI_PACKAGE%" /qn /norestart /L*v "%ODA_MSI_LOG%" TARGETDIR="%ODA_MSI_TARGET%"
        exit /b %ERRORLEVEL%
        """
        try Data(script.utf8).write(to: installerScript, options: .atomic)

        print(
            "[InstallODA] msiexec /a \"\(nativeMSIPath)\" /qn "
                + "/norestart /L*v \"\(nativeLogPath)\" "
                + "TARGETDIR=\"\(nativeTargetPath)\""
        )

        _ = try await run(
            exe: cmd,
            args: ["/D", "/Q", "/C", installerScript.lastPathComponent],
            successfulExitCodes: [0, 1641, 3010],
            onProcess: onProcess,
            runningStatus: "Windows Installer is extracting ODA FileConverter",
            onStatus: onStatus,
            diagnosticFile: installerLog,
            environment: [
                "ODA_MSIEXEC": nativeMSIExecPath,
                "ODA_MSI_PACKAGE": nativeMSIPath,
                "ODA_MSI_LOG": nativeLogPath,
                "ODA_MSI_TARGET": nativeTargetPath,
            ],
            currentDirectoryURL: temporaryDirectory
        )

        guard let converter = findConverter(
            in: target,
            filename: "ODAFileConverter.exe"
        ) else {
            throw NSError(
                domain: "InstallODA",
                code: -7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The MSI completed, but ODAFileConverter.exe was not found under \(target.path)."
                ]
            )
        }
        return converter.path
        #elseif os(macOS)
        onStatus("Mounting disk image...")
        let output = try await run(
            exe: "/usr/bin/hdiutil",
            args: ["attach", file.path, "-nobrowse", "-plist"],
            onProcess: onProcess
        )

        let mountPoint: String
        if let data = output.data(using: .utf8),
           let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ) as? [String: Any],
           let entities = propertyList["system-entities"] as? [[String: Any]],
           let mounted = entities.compactMap({ $0["mount-point"] as? String }).first {
            mountPoint = mounted
        } else {
            mountPoint = "/Volumes/ODAFileConverter"
        }

        defer {
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountPoint]
            )
        }

        onStatus("Copying ODA FileConverter...")
        let source = URL(fileURLWithPath: "\(mountPoint)/ODAFileConverter.app")
        let destination = target.appendingPathComponent("ODAFileConverter.app")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)

        onStatus("Clearing quarantine...")
        _ = try? await run(
            exe: "/usr/bin/xattr",
            args: ["-r", "-d", "com.apple.quarantine", destination.path],
            onProcess: onProcess
        )
        return destination
            .appendingPathComponent("Contents/MacOS/ODAFileConverter")
            .path
        #else
        throw NSError(
            domain: "InstallODA",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported platform"]
        )
        #endif
    }


    nonisolated private static func windowsNativePath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "\\")
    }

    nonisolated private static func findConverter(
        in root: URL,
        filename: String
    ) -> URL? {
        let fileManager = FileManager.default
        if root.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame,
           fileManager.fileExists(atPath: root.path) {
            return root
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            if candidate.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame {
                matches.append(candidate)
            }
        }
        return matches.min { $0.path.count < $1.path.count }
    }

    @discardableResult
    nonisolated private static func run(
        exe: String,
        args: [String],
        successfulExitCodes: Set<Int32> = [0],
        onProcess: @escaping @Sendable (Process?) -> Void,
        runningStatus: String? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil,
        diagnosticFile: URL? = nil,
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil
    ) async throws -> String {
        let fileManager = FileManager.default
        let outputFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-process-\(UUID().uuidString).out")
        let errorFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-process-\(UUID().uuidString).err")

        guard fileManager.createFile(atPath: outputFile.path, contents: nil),
              fileManager.createFile(atPath: errorFile.path, contents: nil) else {
            throw NSError(
                domain: "InstallODA",
                code: -8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to create temporary process output files."
                ]
            )
        }

        let outputHandle = try FileHandle(forWritingTo: outputFile)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? fileManager.removeItem(at: outputFile)
            try? fileManager.removeItem(at: errorFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.currentDirectoryURL = currentDirectoryURL

        if let environment {
            var mergedEnvironment = ProcessInfo.processInfo.environment
            mergedEnvironment.merge(environment) { _, replacement in replacement }
            process.environment = mergedEnvironment
        }

        print("[InstallODA] \(exe) \(args.joined(separator: " "))")

        do {
            try process.run()
        } catch {
            throw NSError(
                domain: "InstallODA",
                code: -8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to launch \(exe): \(error.localizedDescription)"
                ]
            )
        }

        onProcess(process)

        do {
            let processStartedAt = Date()
            var lastStatusUpdate = Date.distantPast

            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            onProcess(nil)
            throw error
        }

        onProcess(nil)
        try? outputHandle.synchronize()
        try? errorHandle.synchronize()
        try? outputHandle.close()
        try? errorHandle.close()

        let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        let errorOutput = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""

        guard successfulExitCodes.contains(process.terminationStatus) else {
            let standardError = errorOutput.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let standardOutput = output.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let diagnostic = diagnosticFile
                .flatMap { Self.readDiagnosticTail($0) } ?? ""
            let detail = [standardError, standardOutput, diagnostic]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let message = detail.isEmpty
                ? "\(URL(fileURLWithPath: exe).lastPathComponent) exited with code \(process.terminationStatus)."
                : detail
            print("[InstallODA] FAILED: \(message)")
            throw NSError(
                domain: "InstallODA",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return output
    }

    nonisolated private static func failureMessage(
        _ error: Error,
        sourceURL: URL
    ) -> String {
        let description = error.localizedDescription
        return "\(description)\n\nSource URL:\n\(sourceURL.absoluteString)"
    }

    nonisolated private static func readDiagnosticTail(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }

        let maximumBytes = 16 * 1024
        let tail = data.suffix(maximumBytes)
        guard let text = String(data: tail, encoding: .utf8) else {
            return nil
        }

        let lines = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }

        let important = lines.filter {
            $0.localizedCaseInsensitiveContains("error")
                || $0.localizedCaseInsensitiveContains("return value 3")
        }
        return (important.isEmpty ? Array(lines.suffix(12)) : Array(important.suffix(12)))
            .joined(separator: "\n")
    }

    nonisolated private static func activityProgress() -> Float {
        let seconds = Date().timeIntervalSinceReferenceDate
        let phase = seconds.truncatingRemainder(dividingBy: 2.0) / 2.0
        let pulse = phase <= 0.5
            ? phase * 2.0
            : (1.0 - phase) * 2.0
        return Float(0.12 + pulse * 0.76)
    }

    nonisolated private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0
            ? String(format: "%d:%02d", minutes, seconds)
            : "\(seconds)s"
    }

    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        "\(formatBytes(Int64(bytesPerSecond)))/s"
    }
}

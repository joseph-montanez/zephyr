import Foundation
import ImGui
import SwiftSDL
import CSDL3

// =========================================================================
// MARK: - InstallODACommand
//
// Installs the ODA FileConverter CLI tool for DWG ↔ DXF conversion.
// =========================================================================

@MainActor
public final class InstallODACommand: FeatureCommand {

    private enum State {
        case showingAgreement
        case downloading
        case installing
        case finished(success: Bool, message: String)
    }

    private var state: State = .showingAgreement
    private var agreed: Bool = false
    private var downloadProgress: Float = 0.0
    private var downloadSpeed: String = ""
    private var statusText: String = ""
    private var installTask: Task<Void, Never>?
    private var popupOpened: Bool = false
    private var progressPopupOpened: Bool = false
    private var finishedPopupOpened: Bool = false
    private var okClicked: Bool = false

    private static let fallbackURLs: [String: String] = [
        "windows": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_vc16_amd64dll_27.1.msi",
        "macos_arm64": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_macOsX_arm64_15.0dll_27.1.dmg",
        "macos_x64": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_macOsX_x64_15.0dll_27.1.dmg",
    ]

    private static let agreementURL = "https://www.opendesign.com/agreements/2025/en/ODA%20Community%20User%20Agreement%2009-2025.pdf"

    public init() {}

    // MARK: - FeatureCommand

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .showingAgreement
        agreed = false
        downloadProgress = 0.0
        downloadSpeed = ""
        statusText = ""
        popupOpened = false
        progressPopupOpened = false
        finishedPopupOpened = false
        okClicked = false
        processor.commandPrompt = "ODA FileConverter installation."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        installTask?.cancel()
        installTask = nil
        state = .showingAgreement
        processor.commandPrompt = nil
    }

    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        if okClicked { okClicked = false; processor.commandPrompt = nil; return .finished }
        return .continue
    }

    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        if okClicked { okClicked = false; processor.commandPrompt = nil; return .finished }
        return .continue
    }
    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
    public func getDrawingSnapPoints() -> [Vector3] { [] }
    public func handleCommandText(_ text: String, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }

    public func renderImGui(engine: PhrostEngine) {
        switch state {
        case .showingAgreement: renderAgreementModal(engine: engine)
        case .downloading: renderProgressModal(engine: engine, title: "Downloading ODA FileConverter...", showCancel: true)
        case .installing: renderProgressModal(engine: engine, title: statusText.isEmpty ? "Installing ODA FileConverter..." : statusText, showCancel: false)
        case .finished(let s, let m): renderFinishedModal(engine: engine, success: s, message: m)
        }
    }

    // MARK: - Modals

    private func popup(_ id: String, size: (w: Float, h: Float), flags: Int32, body: () -> Void) {
        let io = ImGuiGetIO()!
        let dw = io.pointee.DisplaySize.x; let dh = io.pointee.DisplaySize.y
        let mw = min(size.w, dw * 0.70); let mh = min(size.h, dh * 0.70)
        ImGuiSetNextWindowPos(ImVec2(x: (dw - mw) * 0.5, y: (dh - mh) * 0.5), Int32(ImGuiCond_Appearing.rawValue), ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: mw, y: mh), Int32(ImGuiCond_Appearing.rawValue))
        var open = true
        if ImGuiBeginPopupModal(id, &open, flags) { defer { ImGuiEndPopup() }; body() }
    }

    private func renderAgreementModal(engine: PhrostEngine) {
        let id = "Install ODA FileConverter##InstallODA"
        if !popupOpened { ImGuiOpenPopup(id, Int32(ImGuiPopupFlags_None.rawValue)); popupOpened = true }
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue) | Int32(ImGuiWindowFlags_NoResize.rawValue) | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        popup(id, size: (ImGuiGetFontSize() * 52, ImGuiGetFontSize() * 34), flags: flags) {
            ImGuiTextV("ODA FileConverter Installation"); ImGuiSpacing(); ImGuiSeparator(); ImGuiSpacing()
            ImGuiTextWrappedV("The ODA FileConverter converts between DWG and DXF formats. It is required to open and save AutoCAD DWG files.")
            ImGuiSpacing()
            ImGuiTextWrappedV("To use this software, you must accept the ODA Community User Agreement.")
            ImGuiSpacing()
            if ImGuiButton("View Agreement (opens in browser)", ImVec2(x: 0, y: 0)) { _ = Self.agreementURL.withCString { SDL_OpenURL($0) } }
            ImGuiSpacing(); ImGuiSeparator(); ImGuiSpacing()
            ImGuiCheckbox("I agree to the ODA Community User Agreement", &agreed)
            ImGuiSpacing()
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("ODAFileConverter").path ?? "~/Library/Application Support/ODAFileConverter"
            ImGuiTextV("Install location:"); ImGuiSameLine(0, -1); ImGuiTextDisabledV(dir)
            ImGuiSpacing(); ImGuiSeparator(); ImGuiSpacing()
            if !agreed {
                ImGuiPushStyleVar(Int32(ImGuiStyleVar_Alpha.rawValue), Float(0.5))
                ImGuiButton("Install", ImVec2(x: 120, y: 0))
                ImGuiPopStyleVar(1); ImGuiSameLine(0, -1); ImGuiTextDisabledV("(you must agree first)")
            } else if ImGuiButton("Install", ImVec2(x: 120, y: 0)) { startInstall() }
            ImGuiSameLine(0, -1)
            if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) { state = .finished(success: false, message: "Cancelled.") }
        }
    }

    private func renderProgressModal(engine: PhrostEngine, title: String, showCancel: Bool) {
        let id = "Installing ODA FileConverter##InstallODA"
        if !progressPopupOpened { ImGuiOpenPopup(id, Int32(ImGuiPopupFlags_None.rawValue)); progressPopupOpened = true }
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue) | Int32(ImGuiWindowFlags_NoResize.rawValue) | Int32(ImGuiWindowFlags_NoCollapse.rawValue) | Int32(ImGuiWindowFlags_NoMove.rawValue)
        popup(id, size: (ImGuiGetFontSize() * 42, ImGuiGetFontSize() * 12), flags: flags) {
            ImGuiTextV(title); ImGuiSpacing()
            if case .downloading = state { ImGuiProgressBar(downloadProgress, ImVec2(x: 0, y: 0), nil) }
            else { ImGuiProgressBar(-1.0, ImVec2(x: 0, y: 0), nil) }
            ImGuiSpacing()
            if !statusText.isEmpty { ImGuiTextV(statusText) }
            if showCancel { ImGuiSpacing(); if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) { installTask?.cancel(); state = .finished(success: false, message: "Cancelled.") } }
        }
    }

    private func renderFinishedModal(engine: PhrostEngine, success: Bool, message: String) {
        let id = "ODA FileConverter##InstallODA"
        if !finishedPopupOpened { ImGuiOpenPopup(id, Int32(ImGuiPopupFlags_None.rawValue)); finishedPopupOpened = true }
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue) | Int32(ImGuiWindowFlags_NoResize.rawValue) | Int32(ImGuiWindowFlags_NoCollapse.rawValue) | Int32(ImGuiWindowFlags_NoMove.rawValue)
        popup(id, size: (ImGuiGetFontSize() * 42, ImGuiGetFontSize() * 10), flags: flags) {
            if success { ImGuiTextColoredV(ImVec4(x: 0.2, y: 0.9, z: 0.3, w: 1.0), "Installation Complete!") }
            else { ImGuiTextColoredV(ImVec4(x: 0.9, y: 0.3, z: 0.3, w: 1.0), "Installation Failed") }
            ImGuiSpacing(); ImGuiTextWrappedV(message); ImGuiSpacing(); ImGuiSpacing()
            if ImGuiButton("OK", ImVec2(x: 120, y: 0)) { okClicked = true; state = .showingAgreement; popupOpened = false }
        }
    }

    // MARK: - Install

    private func startInstall() {
        state = .downloading
        progressPopupOpened = false
        finishedPopupOpened = false
        statusText = "Starting download..."
        downloadProgress = 0.0
        downloadSpeed = ""

        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try self.resolveURL()
                let file = try await self.download(url: url)
                await MainActor.run { self.state = .installing; self.progressPopupOpened = false; self.statusText = "Running installer..." }
                try await self.runInstall(file: file)
                try? FileManager.default.removeItem(at: file)
                if let p = ODADWGConverter.locateConverter() { UserDefaults.standard.set(p, forKey: "ODAFileConverterPath") }
                await MainActor.run { self.state = .finished(success: true, message: "ODA FileConverter installed. You can now open and save DWG files."); self.progressPopupOpened = false }
            } catch is CancellationError {
                await MainActor.run { self.state = .finished(success: false, message: "Cancelled."); self.progressPopupOpened = false }
            } catch {
                await MainActor.run { self.state = .finished(success: false, message: error.localizedDescription); self.progressPopupOpened = false }
            }
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
        throw NSError(domain: "InstallODA", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported platform"])
        #endif
        guard let s = Self.fallbackURLs[key], let u = URL(string: s) else {
            throw NSError(domain: "InstallODA", code: -2, userInfo: [NSLocalizedDescriptionKey: "No URL for \(key)"])
        }
        return u
    }

    // MARK: - Download

    private func download(url: URL) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        let curlPath = "C:\\Windows\\System32\\curl.exe"
#if !os(Windows)
        let curlPath = "/usr/bin/curl"
#endif
        print("[InstallODA] Downloading \(url.absoluteString)")
        print("[InstallODA] To: \(tmp.path)")

        // Run curl synchronously - most reliable on Windows Swift
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: curlPath)
        proc.arguments = ["-L", "-s", "-S", "-o", tmp.path, url.absoluteString]

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            print("[InstallODA] Failed to launch curl: \(error)")
            throw NSError(domain: "InstallODA", code: -4, userInfo: [NSLocalizedDescriptionKey: "curl not found at \(curlPath)"])
        }

        // Show indeterminate progress while curl runs
        await MainActor.run { self.statusText = "Downloading... (this may take a few minutes)" }

        proc.waitUntilExit()

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        print("[InstallODA] curl exit: \(proc.terminationStatus)")
        if !errStr.isEmpty { print("[InstallODA] curl stderr: \(errStr)") }

        if proc.terminationStatus != 0 {
            let msg = errStr.isEmpty ? "curl exit code \(proc.terminationStatus)" : errStr
            throw NSError(domain: "InstallODA", code: -5, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard FileManager.default.fileExists(atPath: tmp.path) else {
            throw NSError(domain: "InstallODA", code: -6, userInfo: [NSLocalizedDescriptionKey: "Download completed but file not found at \(tmp.path)"])
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path)
        let size = attrs?[.size] as? Int64 ?? 0
        print("[InstallODA] Downloaded \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        await MainActor.run { self.downloadProgress = 1.0 }
        return tmp
    }

    // MARK: - Install

    private func runInstall(file: URL) async throws {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "InstallODA", code: -3, userInfo: [NSLocalizedDescriptionKey: "No Application Support dir"])
        }
        let target = appSupport.appendingPathComponent("ODAFileConverter")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

#if os(Windows)
        try await run(exe: "msiexec", args: ["/a", file.path, "/qb", "TARGETDIR=\(target.path)"])
#elseif os(macOS)
        await MainActor.run { self.statusText = "Mounting disk image..." }
        let out = try await run(exe: "/usr/bin/hdiutil", args: ["attach", file.path, "-nobrowse", "-plist"])
        let mp: String
        if let d = out.data(using: .utf8), let p = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any],
           let e = p["system-entities"] as? [[String: Any]], let f = e.first, let m = f["mount-point"] as? String { mp = m } else { mp = "/Volumes/ODAFileConverter" }
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mp]) }

        await MainActor.run { self.statusText = "Copying..." }
        let src = "\(mp)/ODAFileConverter.app"
        let dst = target.appendingPathComponent("ODAFileConverter.app")
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: dst)

        await MainActor.run { self.statusText = "Clearing quarantine..." }
        _ = try? await run(exe: "/usr/bin/xattr", args: ["-r", "-d", "com.apple.quarantine", dst.path])
#endif
    }

    @discardableResult
    private func run(exe: String, args: [String]) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        print("[InstallODA] \(exe) \(args.joined(separator: " "))")
        try p.run(); p.waitUntilExit()
        let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[InstallODA] FAILED: \(errStr)")
            throw NSError(domain: "InstallODA", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        return outStr
    }

    // Helpers unused now but kept for future
    private func formatBytes(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    private func formatSpeed(_ bps: Double) -> String { formatBytes(Int(bps)) + "/s" }
}

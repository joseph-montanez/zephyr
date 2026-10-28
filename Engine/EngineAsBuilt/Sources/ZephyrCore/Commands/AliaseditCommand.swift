import Foundation
import CSDL3
import ImGui

// =========================================================================
// ALIASEDIT — open the user's PGP alias file in the OS editor (created
// with a commented template on first run), then reload it. Edit, save,
// and the aliases apply immediately; collisions are reported, never
// silent. Also covers REINIT-style reload without opening the editor
// when invoked with text input "RELOAD".
// =========================================================================

@MainActor
public final class AliaseditCommand: FeatureCommand {
    public var name: String { "ALIASEDIT" }

    private var finished = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = false
        let url = PGPAliasLoader.supportURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try PGPAliasLoader.templateContents().write(
                    to: url, atomically: true, encoding: .utf8)
            } catch {
                processor.commandPrompt = "Cannot create \(url.path) (\(error))."
                finished = true
                return
            }
        }
        openInEditor(url: url)
        let result = PGPAliasLoader.loadIfPresent(
            into: engine.commandProcessor)
        var message =
            "Editing \(url.path). \(result.loaded) user alias(es) loaded."
        if !result.warnings.isEmpty {
            message += " Warnings: " + result.warnings.joined(separator: "; ")
        }
        message += " Re-run ALIASEDIT after saving to reload."
        processor.commandPrompt = message
        finished = true
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        finished = true
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .finished
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        finished ? .finished : .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    private func openInEditor(url: URL) {
        let process = Process()
        #if os(Windows)
        process.executableURL = URL(
            fileURLWithPath: "\(ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")\\System32\\cmd.exe")
        process.arguments = ["/c", "start", "", url.path]
        #elseif os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.path]
        #endif
        try? process.run()
    }
}

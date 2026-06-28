import Foundation
import CSDL3
import ImGui
import SwiftSDL
import SwiftSDL_image

// =========================================================================
// MARK: - ImageCommand
//
// Interactive image import command. Opens a file browser filtered to image
// types, then prompts the user to click a placement point. The image is
// loaded, hashed, deduplicated in the document imageStore, and placed at
// the click point with its natural aspect ratio maintained.
// =========================================================================
@MainActor
public final class ImageCommand: FeatureCommand {

    internal enum State {
        case selectingFile
        case placingImage(selectedURL: URL, assetName: String, pixelWidth: Int, pixelHeight: Int)
        case finished
    }

    internal var state: State = .selectingFile
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    /// Internal file browser for image selection.
    private var fileBrowser = ImGuiFileBrowser()
    /// True after the file browser popup has been opened (once per open).
    private var browserOpened: Bool = false
    /// Loaded image data ready for placement.
    private var loadedAssetName: String = ""
    private var loadedPixelWidth: Int = 0
    private var loadedPixelHeight: Int = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .selectingFile
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        browserOpened = false
        loadedAssetName = ""
        processor.commandPrompt = "Select an image file (Esc to cancel)."

        // Configure and open the file browser for image selection
        fileBrowser = ImGuiFileBrowser()
        fileBrowser.onFileSelected = { [weak self] url in
            self?.handleFileSelected(url: url, engine: engine, processor: processor)
        }
        fileBrowser.open(filterExtension: "png;jpg;jpeg;bmp;gif;webp;tiff;tif")
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .finished
        fileBrowser.close()
        browserOpened = false
    }

    // MARK: - File Selection

    private func handleFileSelected(url: URL, engine: PhrostEngine, processor: CADCommandProcessor) {
        let ext = url.pathExtension.lowercased()
        guard CADImageAsset.supportedExtensions.contains(ext) else {
            processor.commandPrompt = "Unsupported file type. Please select an image file."
            return
        }

        // Check file size
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize <= CADImageAsset.maxFileBytes else {
            processor.commandPrompt = "Image file too large (max 100 MB)."
            return
        }

        // Read file data
        guard let imageData = try? Data(contentsOf: url) else {
            processor.commandPrompt = "Failed to read image file."
            return
        }

        // Compute hash
        let hash = CADImageAsset.sha256Hex(imageData)
        let mimeType = CADImageAsset.mimeType(forExtension: ext)

        // Try to load to get pixel dimensions (using SDL_image via temp file)
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imgcmd_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try? imageData.write(to: tmpURL)

        guard let loadedSurface = tmpURL.path.withCString({ IMG_Load($0) }) else {
            let err = String(cString: SDL_GetError())
            print("[ImageCommand] Failed to decode image: \(err)")
            processor.commandPrompt = "Failed to decode image file. It may be corrupt."
            return
        }
        let pixelWidth = Int(loadedSurface.pointee.w)
        let pixelHeight = Int(loadedSurface.pointee.h)
        SDL_DestroySurface(loadedSurface)

        // Check pixel limits
        if pixelWidth * pixelHeight > CADImageAsset.maxDecodedPixels {
            processor.commandPrompt = "Image too large (\(pixelWidth)×\(pixelHeight) pixels). Max 100M pixels."
            return
        }

        // Create asset and store in document
        let asset = CADImageAsset(
            name: hash,
            originalFilename: url.lastPathComponent,
            mimeType: mimeType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            sha256: hash,
            data: imageData
        )
        engine.document.addImageAsset(asset)

        loadedAssetName = hash
        loadedPixelWidth = pixelWidth
        loadedPixelHeight = pixelHeight
        state = .placingImage(selectedURL: url, assetName: hash, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        fileBrowser.close()
        processor.commandPrompt = "Specify insertion point for image (Esc to cancel)."
    }

    // MARK: - Mouse Click

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .selectingFile:
            // User clicked while browser is open — ignore
            return .continue

        case .placingImage(_, let assetName, let pixelWidth, let pixelHeight):
            placeImage(at: worldX, worldY, assetName: assetName,
                       pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                       engine: engine, processor: processor)
            return .finished

        case .finished:
            return .finished
        }
    }

    private func placeImage(
        at worldX: Double, _ worldY: Double,
        assetName: String, pixelWidth: Int, pixelHeight: Int,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        // Default: 1 pixel = 1 drawing unit. Aspect ratio is preserved.
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)

        let layerID = engine.document.activeLayerID ?? engine.document.allLayers.first?.handle ?? UUID()

        let prim = CADPrimitive.image(
            center: Vector3(x: worldX, y: worldY, z: 0),
            width: width,
            height: height,
            rotation: 0,
            imageName: assetName
        )

        let entity = CADEntity(
            layerID: layerID,
            localGeometry: [prim],
            transform: .identity
        )

        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Image placed at (\(Int(worldX)), \(Int(worldY)))."
    }

    // MARK: - Mouse Motion

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    // MARK: - Key Down

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            fileBrowser.close()
            return .finished
        }
        return .continue
    }

    // MARK: - Overlay Preview

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard case .placingImage = state else { return }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(255, 255, 255, 180)

        let cx = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)

        // Draw crosshair at placement point
        let crossSize: Float = 12
        ImDrawListAddLine(drawList,
            ImVec2(x: cx.x - crossSize, y: cx.y),
            ImVec2(x: cx.x + crossSize, y: cx.y), col, 1.5)
        ImDrawListAddLine(drawList,
            ImVec2(x: cx.x, y: cx.y - crossSize),
            ImVec2(x: cx.x, y: cx.y + crossSize), col, 1.5)

        // Draw preview rectangle using screen-space corners
        let w = Double(loadedPixelWidth)
        let h = Double(loadedPixelHeight)
        let halfW = w / 2
        let halfH = h / 2

        let p0 = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX - halfW, worldY: currentMouseWorldY - halfH, cam: cam)
        let p1 = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX + halfW, worldY: currentMouseWorldY - halfH, cam: cam)
        let p2 = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX + halfW, worldY: currentMouseWorldY + halfH, cam: cam)
        let p3 = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX - halfW, worldY: currentMouseWorldY + halfH, cam: cam)

        let outlineCol = makeCol32(100, 200, 255, 150)
        ImDrawListAddQuad(drawList,
            ImVec2(x: p0.x, y: p0.y), ImVec2(x: p1.x, y: p1.y),
            ImVec2(x: p2.x, y: p2.y), ImVec2(x: p3.x, y: p3.y),
            outlineCol, 1.5)

        // Show dimensions
        let dimText = "\(loadedPixelWidth)×\(loadedPixelHeight) px"
        let textSz = ImGuiCalcTextSize(dimText, nil, false, -1)
        ImDrawListAddText(drawList,
            ImVec2(x: cx.x - textSz.x / 2, y: cx.y + crossSize + 4),
            col, dimText, nil)
    }

    // MARK: - ImGui Rendering (file browser)

    public func renderImGui(engine: PhrostEngine) {
        guard case .selectingFile = state else { return }
        fileBrowser.render(ui: engine.ui)

        // If the user closed the browser without selecting, cancel the command
        if !fileBrowser.isOpen && state.is(.selectingFile) {
            engine.commandProcessor.finishFeatureCommand(engine: engine)
        }
    }
}

// Helper for pattern matching state enum
extension ImageCommand.State {
    func `is`(_ other: ImageCommand.State) -> Bool {
        switch (self, other) {
        case (.selectingFile, .selectingFile): return true
        case (.placingImage, .placingImage): return true
        case (.finished, .finished): return true
        default: return false
        }
    }
}

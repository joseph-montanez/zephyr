import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PDFImportCommand
//
// Interactive PDF page import command. Opens a file browser filtered to PDF
// files, lets the user select a page (or auto-selects for single-page PDFs),
// renders the page to a high-DPI PNG bitmap using PDFPageRenderer, then
// prompts the user to click a placement point. The rendered image is stored
// as a CADImageAsset and placed as an image underlay entity.
//
// PDFPageRenderer is cross-platform:
//   - Apple platforms: uses PDFKit (native)
//   - Windows/Linux: uses PDFium (via the CPdfium C bridge)
//
// NOTE: `fileBrowser` is an ImGuiFileBrowser struct. To avoid Swift 6
// exclusive-access violations we never call mutating methods on the
// stored property directly. Instead we copy → mutate → write-back.
// =========================================================================
@MainActor
public final class PDFImportCommand: FeatureCommand {

    // ---------------------------------------------------------------------
    // MARK: - State
    // ---------------------------------------------------------------------

    internal enum State {
        case selectingFile
        case selectingPage(info: PDFInfo)
        case placingVector(page: PDFVectorPage)
        case placingImage(assetName: String, pixelWidth: Int, pixelHeight: Int)
        case finished
    }

    internal var state: State = .selectingFile
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0

    /// Internal file browser for PDF file selection.
    /// Always accessed via copy → mutate → write-back to avoid exclusive-access violations.
    private var fileBrowser = ImGuiFileBrowser()

    /// When in page-selector mode, the user's chosen page number (1-indexed).
    private var selectedPageNumber: Int32 = 1

    /// Loaded image data ready for placement.
    private var loadedAssetName: String = ""
    private var loadedPixelWidth: Int = 0
    private var loadedPixelHeight: Int = 0

    /// Rendering DPI (default 150 — configurable in the future).
    private let renderDPI: CGFloat = 150.0

    public init() {}

    // ---------------------------------------------------------------------
    // MARK: - FeatureCommand lifecycle
    // ---------------------------------------------------------------------

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .selectingFile
        currentMouseWorldX = 0
        currentMouseWorldY = 0
        selectedPageNumber = 1
        loadedAssetName = ""
        processor.commandPrompt = "Select a PDF file (Esc to cancel)."

        // Build the browser fully before assigning — avoids overlapping
        // mutations on self.fileBrowser.
        var fb = ImGuiFileBrowser()
        fb.onFileSelected = { [weak self] url in
            self?.handlePDFSelected(url: url, engine: engine, processor: processor)
        }
        fb.open(filterExtension: "pdf")
        fileBrowser = fb
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .finished
        var fb = fileBrowser
        fb.close()
        fileBrowser = fb
    }

    // ---------------------------------------------------------------------
    // MARK: - PDF file selection
    // ---------------------------------------------------------------------

    private func handlePDFSelected(url: URL, engine: PhrostEngine, processor: CADCommandProcessor) {
        // Close the browser via copy-mutate-writeback
        do {
            var fb = fileBrowser
            fb.close()
            fileBrowser = fb
        }

        guard PDFPageRenderer.isAvailable else {
            state = .selectingPage(info: PDFInfo(pageCount: 0, url: url))
            processor.commandPrompt = "PDF import not available."
            return
        }

        guard let info = PDFPageRenderer.openPDF(at: url) else {
            processor.commandPrompt = "Failed to open PDF file. It may be corrupt or password-protected."
            state = .finished
            return
        }

        selectedPageNumber = 1

        if info.pageCount == 1 {
            renderAndProceedToPlacement(
                info: info, pageIndex: 0,
                engine: engine, processor: processor)
        } else {
            state = .selectingPage(info: info)
            processor.commandPrompt = "Select page to import (1–\(info.pageCount))."
        }
    }

    // ---------------------------------------------------------------------
    // MARK: - Page → PNG rendering (via PDFPageRenderer)
    // ---------------------------------------------------------------------

    private func renderAndProceedToPlacement(
        info: PDFInfo, pageIndex: Int,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        if let vectorPage = PDFiumBridge.extractVectorPage(
            path: info.url.path, pageIndex: pageIndex
        ), !vectorPage.isEmpty {
            loadedPixelWidth = Int(vectorPage.width.rounded())
            loadedPixelHeight = Int(vectorPage.height.rounded())
            state = .placingVector(page: vectorPage)
            processor.commandPrompt =
                "Specify insertion point for vector PDF " +
                "(\(vectorPage.solidEntities.count) solid objects, " +
                "\(vectorPage.geometryEntities.count) geometry objects, " +
                "\(vectorPage.textEntities.count) text objects)."
            return
        }

        // Unsupported or fully raster PDF: preserve the existing bitmap fallback.
        guard let result = PDFPageRenderer.renderPage(
            at: info.url, pageIndex: pageIndex, dpi: renderDPI
        ) else {
            processor.commandPrompt = "Failed to render PDF page."
            state = .finished
            return
        }

        let hash = CADImageAsset.sha256Hex(result.pngData)
        let pageLabel = "\(info.url.lastPathComponent) (page \(pageIndex + 1))"
        let asset = CADImageAsset(
            name: hash,
            originalFilename: pageLabel,
            mimeType: "image/png",
            pixelWidth: result.pixelWidth,
            pixelHeight: result.pixelHeight,
            sha256: hash,
            data: result.pngData
        )
        engine.document.addImageAsset(asset)

        loadedAssetName = hash
        loadedPixelWidth = result.pixelWidth
        loadedPixelHeight = result.pixelHeight
        state = .placingImage(assetName: hash,
                               pixelWidth: result.pixelWidth,
                               pixelHeight: result.pixelHeight)
        processor.commandPrompt = "Specify insertion point for PDF underlay (Esc to cancel)."
    }

    // ---------------------------------------------------------------------
    // MARK: - Page selector modal (ImGui)
    // ---------------------------------------------------------------------

    private func renderPageSelector(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard case .selectingPage(let info) = state else { return }

        let io = ImGuiGetIO()!
        let displayW = io.pointee.DisplaySize.x
        let displayH = io.pointee.DisplaySize.y
        let modalW: Float = min(ImGuiGetFontSize() * 30, displayW * 0.6)
        let modalH: Float = min(ImGuiGetFontSize() * 18, displayH * 0.5)

        ImGuiSetNextWindowPos(
            ImVec2(x: (displayW - modalW) * 0.5, y: (displayH - modalH) * 0.5),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: modalW, y: modalH), Int32(ImGuiCond_Appearing.rawValue))

        if !ImGuiIsPopupOpen("Import PDF Page##PDFPageSelect", Int32(ImGuiPopupFlags_None.rawValue)) {
            ImGuiOpenPopup("Import PDF Page##PDFPageSelect", Int32(ImGuiPopupFlags_None.rawValue))
        }

        let flags: Int32 = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue) |
                            Int32(ImGuiWindowFlags_NoDocking.rawValue)

        var openFlag: Bool = true
        if ImGuiBeginPopupModal("Import PDF Page##PDFPageSelect", &openFlag, flags) {
            defer { ImGuiEndPopup() }

            if !openFlag {
                state = .finished
                return
            }

            // --- Error state: pageCount == 0 means PDF rendering is unavailable ---
            if info.pageCount == 0 {
                igSpacing()
                ImGuiPushStyleColor(
                    Int32(ImGuiCol_Text.rawValue),
                    ImVec4(x: 1, y: 0.3, z: 0.3, w: 1))
                ImGuiTextV("PDF rendering is not available on this platform.")
                ImGuiPopStyleColor(1)
                igSpacing()
                ImGuiTextV("On macOS: PDFKit is built-in and should work automatically.")
                ImGuiTextV("On Windows/Linux: install pdfium via:")
                igSpacing()
                ImGuiTextV("  Engine\\SwiftPdfium\\download_pdfium.ps1")
                igSpacing()
                igSeparator()
                igSpacing()
                if igSmallButton("Close") {
                    state = .finished
                    ImGuiCloseCurrentPopup()
                }
                return
            }

            igSpacing()
            ImGuiTextV("Import page from:")
            igSpacing()
            ImGuiTextV(info.url.lastPathComponent)
            igSpacing()
            igSeparator()
            igSpacing()

            ImGuiTextV("This PDF has \(info.pageCount) pages.")
            igSpacing()

            ImGuiTextV("Page:")
            ImGuiSameLine(0, 8)
            ImGuiPushItemWidth(80)

            if igSmallButton("-") {
                if selectedPageNumber > 1 { selectedPageNumber -= 1 }
            }
            ImGuiSameLine(0, 4)

            var pageInput = selectedPageNumber
            ImGuiSetNextItemWidth(60)
            if igInputInt("##PageNumber", &pageInput, 0, 0, ImGuiInputTextFlags(0)) {
                if pageInput >= 1 && pageInput <= Int32(info.pageCount) {
                    selectedPageNumber = pageInput
                }
            }
            ImGuiSameLine(0, 4)

            if igSmallButton("+") {
                if selectedPageNumber < Int32(info.pageCount) { selectedPageNumber += 1 }
            }

            if selectedPageNumber < 1 { selectedPageNumber = 1 }
            else if selectedPageNumber > Int32(info.pageCount) { selectedPageNumber = Int32(info.pageCount) }

            ImGuiPopItemWidth()

            igSpacing()
            igSpacing()
            ImGuiTextV("Page \(selectedPageNumber) of \(info.pageCount)")
            igSpacing()
            igSeparator()
            igSpacing()

            if igSmallButton("Cancel") {
                state = .finished
                ImGuiCloseCurrentPopup()
            }
            ImGuiSameLine(0, 16)

            if igSmallButton("Import") {
                let index = Int(selectedPageNumber) - 1
                renderAndProceedToPlacement(
                    info: info, pageIndex: index,
                    engine: engine, processor: processor)
                ImGuiCloseCurrentPopup()
            }

            if ImGuiIsKeyPressed(ImGuiKey(ImGuiKey_Enter.rawValue), false) {
                let index = Int(selectedPageNumber) - 1
                renderAndProceedToPlacement(
                    info: info, pageIndex: index,
                    engine: engine, processor: processor)
                ImGuiCloseCurrentPopup()
            }
        }
    }

    // ---------------------------------------------------------------------
    // MARK: - Mouse handlers
    // ---------------------------------------------------------------------

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch state {
        case .selectingFile, .selectingPage:
            return .continue

        case .placingVector(let page):
            placeVectorPage(
                page, at: worldX, worldY,
                engine: engine, processor: processor
            )
            return .finished

        case .placingImage(let assetName, let pixelWidth, let pixelHeight):
            placeImage(at: worldX, worldY, assetName: assetName,
                       pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                       engine: engine, processor: processor)
            return .finished

        case .finished:
            return .finished
        }
    }

    private func placeVectorPage(
        _ page: PDFVectorPage,
        at worldX: Double,
        _ worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        let document = engine.document
        document.textStyleFonts["PDF_TEXT"] = "arialmt.ttf"

        func layer(named name: String, color: ColorRGBA, lineWeight: Double) -> (Layer, Bool) {
            if let existing = document.allLayers.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return (existing, false)
            }
            return (
                Layer(name: name, lineWeight: lineWeight, color: color),
                true
            )
        }

        let (solidLayer, solidIsNew) = layer(
            named: "PDF_Solid Fills", color: .gray, lineWeight: 0.0
        )
        let (lineLayer, lineIsNew) = layer(
            named: "PDF_Geometry", color: .white, lineWeight: 0.25
        )
        let (textLayer, textIsNew) = layer(
            named: "PDF_Text", color: .white, lineWeight: 0.25
        )

        let placement = Transform3D.translated(
            by: Vector3(
                x: worldX - page.width / 2.0,
                y: worldY - page.height / 2.0,
                z: 0
            )
        )
        var entities: [CADEntity] = []
        entities.reserveCapacity(
            page.solidEntities.count +
            page.geometryEntities.count +
            page.textEntities.count
        )
        for primitives in page.solidEntities {
            entities.append(
                CADEntity(
                    layerID: solidLayer.handle,
                    localGeometry: primitives,
                    transform: placement
                )
            )
        }
        for primitives in page.geometryEntities {
            entities.append(
                CADEntity(
                    layerID: lineLayer.handle,
                    localGeometry: primitives,
                    transform: placement
                )
            )
        }
        for primitives in page.textEntities {
            entities.append(
                CADEntity(
                    layerID: textLayer.handle,
                    localGeometry: primitives,
                    transform: placement
                )
            )
        }

        var newLayers: [Layer] = []
        if solidIsNew && !page.solidEntities.isEmpty { newLayers.append(solidLayer) }
        if lineIsNew && !page.geometryEntities.isEmpty { newLayers.append(lineLayer) }
        if textIsNew && !page.textEntities.isEmpty { newLayers.append(textLayer) }
        document.pushUndo()
        document.importLayersBlocksEntities(
            layers: newLayers, blocks: [], entities: entities
        )
        engine.tabManager.markActiveDirty()
        processor.commandPrompt =
            "Vector PDF placed on PDF_Geometry, PDF_Solid Fills, and PDF_Text."
    }

    private func placeImage(
        at worldX: Double, _ worldY: Double,
        assetName: String, pixelWidth: Int, pixelHeight: Int,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
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
        processor.commandPrompt = "PDF page placed at (\(Int(worldX)), \(Int(worldY)))."
    }

    // ---------------------------------------------------------------------
    // MARK: - Mouse motion
    // ---------------------------------------------------------------------

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    // ---------------------------------------------------------------------
    // MARK: - Key handling
    // ---------------------------------------------------------------------

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            var fb = fileBrowser
            fb.close()
            fileBrowser = fb
            state = .finished
            return .finished
        default:
            return .continue
        }
    }

    // ---------------------------------------------------------------------
    // MARK: - Overlay preview (placement phase)
    // ---------------------------------------------------------------------

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let isVector: Bool
        switch state {
        case .placingVector:
            isVector = true
        case .placingImage:
            isVector = false
        default:
            return
        }

        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(255, 255, 255, 180)

        let cx = EngineCameraManager.worldToScreen(
            worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)

        let crossSize: Float = 12
        ImDrawListAddLine(drawList,
            ImVec2(x: cx.x - crossSize, y: cx.y),
            ImVec2(x: cx.x + crossSize, y: cx.y), col, 1.5)
        ImDrawListAddLine(drawList,
            ImVec2(x: cx.x, y: cx.y - crossSize),
            ImVec2(x: cx.x, y: cx.y + crossSize), col, 1.5)

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

        let unitLabel = isVector ? "pt" : "px"
        let dimText = "PDF page — \(loadedPixelWidth)×\(loadedPixelHeight) \(unitLabel)"
        let textSz = ImGuiCalcTextSize(dimText, nil, false, -1)
        ImDrawListAddText(drawList,
            ImVec2(x: cx.x - textSz.x / 2, y: cx.y + crossSize + 4),
            col, dimText, nil)
    }

    // ---------------------------------------------------------------------
    // MARK: - ImGui rendering
    // ---------------------------------------------------------------------

    public func renderImGui(engine: PhrostEngine) {
        switch state {
        case .selectingFile:
            // Copy → mutate → write-back to avoid exclusive-access violation
            // between render() and the subsequent .isOpen read.
            var fb = fileBrowser
            fb.render()
            let stillOpen = fb.isOpen
            fileBrowser = fb

            // Only finish if the user dismissed the browser WITHOUT selecting
            // a file. handlePDFSelected changes state to .selectingPage/.finished,
            // so we check state.is(.selectingFile) to avoid killing the command
            // right after a successful selection.
            if !stillOpen, state.is(.selectingFile) {
                engine.commandProcessor.finishFeatureCommand(engine: engine)
            }

        case .selectingPage:
            renderPageSelector(engine: engine, processor: engine.commandProcessor)

        case .placingVector, .placingImage:
            break

        case .finished:
            engine.commandProcessor.finishFeatureCommand(engine: engine)
        }
    }

    // ---------------------------------------------------------------------
    // MARK: - Snapping
    // ---------------------------------------------------------------------

    public var isSnappingEnabled: Bool {
        switch state {
        case .placingVector, .placingImage: return true
        default: return false
        }
    }
}

// ---------------------------------------------------------------------
// MARK: - State pattern matching helper
// ---------------------------------------------------------------------

extension PDFImportCommand.State {
    func `is`(_ other: PDFImportCommand.State) -> Bool {
        switch (self, other) {
        case (.selectingFile, .selectingFile): return true
        case (.selectingPage, .selectingPage): return true
        case (.placingVector, .placingVector): return true
        case (.placingImage, .placingImage): return true
        case (.finished, .finished): return true
        default: return false
        }
    }
}

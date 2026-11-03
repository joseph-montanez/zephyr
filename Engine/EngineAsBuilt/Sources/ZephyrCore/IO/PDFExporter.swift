import Foundation

// =========================================================================
// MARK: - PDFExporter
//
// Exports a CAD document to PDF format. Converts entities to PDF drawing
// operations using the PDFWriter and PDFPrimitives abstractions.
// Supports line weights, colors, and basic entity types.

// =========================================================================
// MARK: - PDFExporter
// =========================================================================

/// Exports a `CADDocument` as a PDF 1.7 file with vector geometry, FlateDecode
/// (zlib) content stream compression, and a /Measure dictionary for real-world
/// measurement tools (Bluebeam Revu compatible).
///
/// ## Coordinate convention (IMPORTANT)
/// The engine stores all geometry in **Y-down** space: `DXFImporter.toVector`
/// negates DXF Y on import, and the renderer draws in Y-down screen space.
/// PDF user space is **Y-up**. The page-level CTM therefore flips Y
/// (`s 0 0 -s tx ty cm`). Without this flip the entire drawing renders
/// vertically mirrored — flipped text, mirrored title block, items on the
/// wrong side. This was the primary export bug.
///
/// ## Draw order
/// Entities are sorted by `xdata["dxf.drawOrder"]` with the same comparator
/// as `CADRendererBridge.computeSpecs`, so PDF stacking matches the screen.
/// (The previous implementation iterated `allLayers` — an unordered
/// dictionary — producing nondeterministic stacking.)
///
/// ## Text entities
/// Standalone TEXT/MTEXT entities carry their position/rotation in BOTH
/// `entity.transform` AND the `.text` primitive in `localGeometry` (see
/// `DXFImporter` entity creation). The renderer draws these from xdata +
/// transform and *skips* the geometry (`CADRendererBridge` `continue`s).
/// The old PDF path rendered the geometry under the entity CTM — a double
/// transform that placed every label at 2× its distance from the origin.
/// This exporter mirrors the renderer: text entities are exploded through
/// the same SHX font path (`CADFontManager` + `SHXShapeFont.renderText`)
/// into world-space line primitives, which also makes alignment, MTEXT
/// wrapping, and mirrored-placement behavior identical to the screen.
public enum PDFExporter {

    /// Acrobat / Bluebeam Revu hard page-size limit (200 in = 14,400 pt).
    /// Pages larger than this are silently clipped or rejected by viewers.
    private static let maxPagePoints: Double = 14_400

    // ---------------------------------------------------------------------
    // MARK: Render items (pre-pass output)
    // ---------------------------------------------------------------------

    /// A drawable unit in screen-parity order.
    enum RenderItem {
        /// Geometry entity (lines, arcs, blocks, hatches, …) drawn under its
        /// full affine transform.
        case geometry(entity: CADEntity, color: ColorRGBA, lineWeightMM: Double)
        /// Standalone TEXT/MTEXT entity pre-exploded to world-space SHX
        /// stroke primitives (renderer parity).
        case textStrokes(prims: [CADPrimitive], color: ColorRGBA)
        /// Live TrueType text: laid out with TTF advances, emitted against
        /// embedded or referenced CID fonts.
        case embeddedText(PDFTextEmitter.EmbeddedItem)
        /// Invisible searchable text over SHX strokes (EPDFSHX equivalent).
        case hiddenText(text: String, position: Vector3, rotation: Double,
                        height: Double)
        /// Standalone TEXT/MTEXT entity for which no font at all could be
        /// loaded — emitted as a Standard-14 Helvetica text object.
        /// Last resort only; SHX and TTF paths are preferred.
        case textFallback(text: String, position: Vector3, rotation: Double,
                          height: Double, color: ColorRGBA)
    }

    // ---------------------------------------------------------------------
    // MARK: Public entry point
    // ---------------------------------------------------------------------

    /// Export the document to a PDF file. Page size is auto-computed from the
    /// drawing's bounding box and capped to the 14,400 pt viewer limit (the
    /// /Measure dictionary is kept consistent with the effective scale, so
    /// Bluebeam auto-calibration remains correct even when the page is
    /// fit-scaled down).
    public static func export(document: CADDocument, to url: URL, backgroundColor: ColorRGBA? = nil,
                              plotContext: PlotContext = .default,
                              options: PDFExportOptions = .default) throws {
        let pdfData = try generatePDF(document: document, backgroundColor: backgroundColor,
                                        plotContext: plotContext, options: options)
        try pdfData.write(to: url, options: .atomic)
    }

    /// Font handling for PDF text export (AutoCAD parity).
    ///
    /// - `captureFonts`: embed TTF subsets so text is live without local
    ///   fonts. Off = reference faces by name (viewer substitutes).
    /// - `convertAllTextToGeometry`: explode TTF glyphs to vector outlines.
    ///   Overrides `captureFonts`; text is no longer searchable.
    /// - `includeHiddenTextForSHX`: emit invisible searchable text over SHX
    ///   stroke geometry (EPDFSHX equivalent).
    public struct PDFExportOptions: Sendable {
        public var captureFonts: Bool
        public var convertAllTextToGeometry: Bool
        public var includeHiddenTextForSHX: Bool

        public init(captureFonts: Bool = true,
                    convertAllTextToGeometry: Bool = false,
                    includeHiddenTextForSHX: Bool = true) {
            self.captureFonts = captureFonts
            self.convertAllTextToGeometry = convertAllTextToGeometry
            self.includeHiddenTextForSHX = includeHiddenTextForSHX
        }

        public static let `default` = PDFExportOptions()

        private static let captureKey = "Zephyr.ExportPDF.CaptureFonts"
        private static let convertKey = "Zephyr.ExportPDF.ConvertAllTextToGeometry"
        private static let hiddenSHXKey = "Zephyr.ExportPDF.IncludeHiddenTextForSHX"
        private static let openViewerKey = "Zephyr.ExportPDF.OpenInViewer"

        /// Options persisted from the EXPORTPDF popup (AutoCAD defaults:
        /// capture on, convert off, SHX hidden text on).
        public static func loadPersisted() -> PDFExportOptions {
            let store = UserDefaults.standard
            var options = PDFExportOptions()
            if store.object(forKey: captureKey) != nil {
                options.captureFonts = store.bool(forKey: captureKey)
            }
            if store.object(forKey: convertKey) != nil {
                options.convertAllTextToGeometry = store.bool(forKey: convertKey)
            }
            if store.object(forKey: hiddenSHXKey) != nil {
                options.includeHiddenTextForSHX = store.bool(forKey: hiddenSHXKey)
            }
            return options
        }

        public func persist() {
            let store = UserDefaults.standard
            store.set(captureFonts, forKey: Self.captureKey)
            store.set(convertAllTextToGeometry, forKey: Self.convertKey)
            store.set(includeHiddenTextForSHX, forKey: Self.hiddenSHXKey)
        }

        /// "Open in viewer when done" is UI chrome, not an export input.
        public static func loadPersistedOpenInViewer() -> Bool {
            UserDefaults.standard.object(forKey: openViewerKey) as? Bool ?? false
        }

        public static func persistOpenInViewer(_ value: Bool) {
            UserDefaults.standard.set(value, forKey: openViewerKey)
        }
    }

    /// Background-save: export from a snapshot with progress and cancellation.
    public static func export(snapshot: CADDocumentSnapshot, to url: URL,
                               backgroundColor: ColorRGBA? = nil,
                               progress: ((Float) -> Void)? = nil,
                               options: PDFExportOptions = .default) throws {
        try Task.checkCancellation()
        let tempDoc = CADDocument()
        tempDoc.restore(from: snapshot)
        let pdfData = try generatePDF(document: tempDoc, backgroundColor: backgroundColor,
                                      options: options)
        try Task.checkCancellation()
        progress?(0.95)
        try atomicWrite(data: pdfData, to: url)
        progress?(0.99)
    }

    private static func atomicWrite(data: Data, to targetURL: URL) throws {
        let tmpURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try data.write(to: tmpURL, options: .atomic)

#if os(Windows)
        // replaceItemAt is not implemented in Foundation on Windows.
        // Fall back to remove-then-move (not atomic, but safe).
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: targetURL)
#else
        if FileManager.default.fileExists(atPath: targetURL.path) {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: targetURL)
        }
#endif
    }

    // ---------------------------------------------------------------------
    // MARK: Plot mode (Phase 3 step 20)
    // ---------------------------------------------------------------------

    /// Exact paper-space plot framing for a layout with plot settings.
    /// Nil when the document has no usable settings (legacy auto-fit path).
    /// Rotation (DXF 73) swaps page dims like the canvas sheet; content
    /// itself is not rotated (canvas and PDF share this model, so their
    /// framing matches exactly — full rotated-content plotting is deferred).
    struct PlotFrame: Sendable, Equatable {
        /// Page size in points (rotation-swapped).
        var pageW: Double
        var pageH: Double
        /// Points per paper-space unit (unit factor × plot scale factor).
        var scale: Double
        /// Page CTM translation (device = scale * world + t).
        var tx: Double
        var ty: Double
        /// Printable clip rect in paper-space (world) coords.
        var clipMinX: Double
        var clipMinY: Double
        var clipMaxX: Double
        var clipMaxY: Double
        /// Printable clip rect in PDF device points (emitted before cm).
        var clipPageX: Double?
        var clipPageY: Double?
        var clipPageW: Double?
        var clipPageH: Double?
    }

    /// Points per paper-space unit for a plot-paper-units code.
    static func pointsPerPaperUnit(_ units: Int) -> Double {
        switch units {
        case 0: return 72.0 // inches
        case 2: return 1.0 // pixels (≈1pt)
        default: return 72.0 / 25.4 // millimeters
        }
    }

    /// Compute exact plot framing. `transparencyOverride` mirrors
    /// PLOTTRANSPARENCYOVERRIDE (0 suppress, 1 per-setup, 2 force).
    /// `worldBounds` is the drawing's world bbox (Extents/Display source).
    /// `plotTable` is applied when the setup enables PlotPlotStyles (bit 32).
    static func plotFrame(
        settings: CADPlotSettings,
        worldBounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)?,
        transparencyOverride: Int = 1,
        plotTable: PlotStyleTable? = nil,
        plotOffset: Int = 0
    ) -> PlotFrame? {
        guard settings.paperWidthMM > 0, settings.paperHeightMM > 0 else { return nil }
        let ppu = pointsPerPaperUnit(settings.plotPaperUnits)
        let physSheet = PaperSheetGeometry.physicalSheetSize(for: settings)
        var pageW = physSheet.width * ppu
        var pageH = physSheet.height * ppu
        // Landscape swap is inside physicalSheetSize; guard degenerate sizes.
        pageW = max(pageW, 10.0)
        pageH = max(pageH, 10.0)

        // Plot scale factor (paper units per drawing unit).
        let factor: Double
        if settings.standardScaleType == 0 || !settings.useStandardScale,
           !settings.isCustomScale {
            factor = .nan // Scaled to Fit → computed below
        } else if settings.useStandardScale {
            factor = CADPlotSettings.standardScaleFactor(for: settings.standardScaleType)
                ?? settings.effectiveScaleFactor
        } else {
            factor = settings.effectiveScaleFactor
        }

        // Physical printable margins (paper units)
        let physM = PaperSheetGeometry.physicalPermutedMargins(for: settings)
        let printW = max(physSheet.width - physM.left - physM.right, 1e-9)
        let printH = max(physSheet.height - physM.bottom - physM.top, 1e-9)

        // Also compute scaled printable rect for backward-compatible clipMin/Max test assertions
        let printable = PaperSheetGeometry.printableRect(for: settings)
        let origin = PaperSheetGeometry.paperSpaceOrigin(for: settings, plotOffset: plotOffset)
        func shift(_ r: (minX: Double, minY: Double, maxX: Double, maxY: Double))
            -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
            (r.minX - origin.x, r.minY - origin.y, r.maxX - origin.x, r.maxY - origin.y)
        }
        let printPS = shift((printable.minX, printable.minY, printable.maxX, printable.maxY))

        // For plotType == 5 (Layout), map the paper frame directly to the PDF page:
        // DXF paper-space coordinates [minX, maxX] x [minY, maxY] map to [0, pageW] x [0, pageH].
        // This ensures what is shown on the canvas sheet overlay is exactly what prints to the PDF page.
        if settings.plotType == 5,
           let rects = PaperSheetGeometry.overlayRects(for: settings, plotOffset: plotOffset) {
            let paperW = max(rects.paper.maxX - rects.paper.minX, 1e-9)
            let paperH = max(rects.paper.maxY - rects.paper.minY, 1e-9)
            let scale = min(pageW / paperW, pageH / paperH)
            let tx = -scale * rects.paper.minX
            let ty = -scale * rects.paper.minY

            let clipPageX = (rects.printable.minX - rects.paper.minX) * scale
            let clipPageY = (rects.printable.minY - rects.paper.minY) * scale
            let clipPageW = (rects.printable.maxX - rects.printable.minX) * scale
            let clipPageH = (rects.printable.maxY - rects.printable.minY) * scale

            return PlotFrame(pageW: pageW, pageH: pageH, scale: scale,
                             tx: tx, ty: ty,
                             clipMinX: rects.printable.minX, clipMinY: rects.printable.minY,
                             clipMaxX: rects.printable.maxX, clipMaxY: rects.printable.maxY,
                             clipPageX: clipPageX, clipPageY: clipPageY,
                             clipPageW: clipPageW, clipPageH: clipPageH)
        }

        let areaPS: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
        switch settings.plotType {
        case 2: // Limits
            let l = PaperSheetGeometry.syncedLimits(for: settings)
            areaPS = (l.min.x, l.min.y, l.max.x, l.max.y)
        case 4: // Window
            areaPS = (settings.plotWindowMinX, settings.plotWindowMinY,
                        settings.plotWindowMaxX, settings.plotWindowMaxY)
        case 0, 1, 3: // Display / Extents / View (no named views in v1)
            if let wb = worldBounds {
                areaPS = wb
            } else {
                areaPS = printPS
            }
        default:
            areaPS = printPS
        }
        let area = areaPS ?? printPS
        let areaW = max(area.maxX - area.minX, 1e-9)
        let areaH = max(area.maxY - area.minY, 1e-9)

        let plotScale: Double
        if factor.isNaN {
            plotScale = min(printW / areaW, printH / areaH)
        } else {
            plotScale = factor.isFinite && factor > 0 ? factor : 1
        }
        let scale = ppu * plotScale

        // Offset: stored origin, or centered math when PlotCentered (bit 4).
        let ox: Double
        let oy: Double
        if settings.plotFlags & 4 != 0, settings.plotType != 5 {
            let m = PaperSheetGeometry.permutedMargins(for: settings)
            let c = PlotSettingsValidator.centeredOffset(
                printableWidth: printW, printableHeight: printH,
                plotAreaWidth: areaW, plotAreaHeight: areaH,
                scale: plotScale, plotOffset: plotOffset,
                marginLeft: m.left, marginBottom: m.bottom)
            ox = c.x
            oy = c.y
        } else {
            let div = PaperSheetGeometry.unitDivisor(for: settings)
            ox = settings.plotOriginXMM / div
            oy = settings.plotOriginYMM / div
        }
        // Map area origin to printable origin + offset (paper-space units).
        // Engine content is Y-down (import negates DXF Y) while the
        // printable rect is Y-up, so for Extents areas sourced from engine
        // worldBounds the Y offset must compose against the area bottom
        // (maxY, placed by ty below), not the area top: subtracting minY
        // inflates ty by a full area height and pushes the sheet off-page.
        // Window/Limits areas keep the legacy composition.
        let devOX = (printPS.minX + ox - area.minX) * scale
        let devOY = settings.plotType == 1
            ? (printPS.minY + oy) * scale
            : (printPS.minY + oy - area.minY) * scale
        // Y-flip CTM: device.y = -scale * world.y + ty with area bottom
        // at page bottom offset. In PDF points, printable box sits at
        // devOY from the bottom.
        let tx = devOX
        let ty = devOY + area.maxY * scale
        _ = (transparencyOverride, plotTable)

        let clipPageX = physM.left * ppu
        let clipPageY = physM.bottom * ppu
        let clipPageW = printW * ppu
        let clipPageH = printH * ppu

        return PlotFrame(pageW: pageW, pageH: pageH, scale: scale,
                         tx: tx, ty: ty,
                         clipMinX: printPS.minX, clipMinY: printPS.minY,
                         clipMaxX: printPS.maxX, clipMaxY: printPS.maxY,
                         clipPageX: clipPageX, clipPageY: clipPageY,
                         clipPageW: clipPageW, clipPageH: clipPageH)
    }

    /// Apply plot-style table mapping + lineweight/transparency policy to
    /// collected items. Returns items with resolved colors/lineweights.
    /// - transparencyOverride mirrors PLOTTRANSPARENCYOVERRIDE.
    static func applyPlotStyles(
        items: [RenderItem],
        document: CADDocument,
        settings: CADPlotSettings,
        plotTable: PlotStyleTable?,
        transparencyOverride: Int = 1
    ) -> [RenderItem] {
        let doStyles = settings.plotFlags & 32 != 0
        let printLW = settings.plotFlags & 128 != 0
        let scaleLW = settings.plotFlags & 64 != 0
        let plotScale = settings.effectiveScaleFactor.isFinite ? settings.effectiveScaleFactor : 1
        // Screening gate: 0 suppress, 2 force, else the setup checkbox.
        let screeningOn: Bool
        switch transparencyOverride {
        case 0: screeningOn = false
        case 2: screeningOn = true
        default: screeningOn = settings.plotTransparency
        }
        guard doStyles || !printLW || scaleLW || screeningOn else { return items }
        return items.map { item in
            switch item {
            case .geometry(let entity, let color, let lineWeightMM):
                // Raw (unadjusted) color + lineweight, mirroring collectItems
                // without displayAdjusted (plot works on true colors).
                let raw: ColorRGBA
                if let cv = entity.xdata["dxf.color"], case .string(let hex) = cv,
                   let c = ColorRGBA(hex: hex) {
                    raw = c
                } else if let layer = document.layer(for: entity.layerID) {
                    raw = layer.color
                } else {
                    raw = color
                }
                let lw0: Double
                if let lw = entity.xdata["dxf.lineWeight"], case .double(let v) = lw, v > 0 {
                    lw0 = v
                } else if let layer = document.layer(for: entity.layerID) {
                    lw0 = layer.lineWeight
                } else {
                    lw0 = lineWeightMM
                }
                let pen: PlotStylePen?
                if doStyles, let table = plotTable {
                    let aci = Int(DXFColorTable.rgbaToACI(raw))
                    pen = LayerAccess.plotPen(
                        layer: document.layer(for: entity.layerID),
                        objectACI: aci,
                        pstyleMode: document.pstyleMode,
                        table: table)
                } else {
                    pen = nil
                }
                let lwBase = printLW ? lw0 : 0
                let resolved = PlotPenApplication.resolve(
                    objectACI: nil,
                    objectRGB: (raw.r, raw.g, raw.b),
                    pen: pen,
                    objectLineweightMM: lwBase,
                    scaleLineweights: scaleLW, plotScale: plotScale)
                var rgb = (resolved.r, resolved.g, resolved.b)
                if screeningOn, resolved.screening01 < 1 {
                    // Screening = ink coverage: blend toward white paper.
                    let t = resolved.screening01
                    rgb = (UInt8((Double(rgb.0) * t + 255 * (1 - t)).rounded()),
                           UInt8((Double(rgb.1) * t + 255 * (1 - t)).rounded()),
                           UInt8((Double(rgb.2) * t + 255 * (1 - t)).rounded()))
                }
                return .geometry(
                    entity: entity,
                    color: ColorRGBA(r: rgb.0, g: rgb.1, b: rgb.2, a: color.a),
                    lineWeightMM: resolved.lineweightMM ?? lwBase)
            case .textStrokes(let prims, let color):
                if !screeningOn { return item }
                // Text strokes use the default color; screening applies
                // uniformly when the setup enables transparency.
                return .textStrokes(prims: prims, color: color)
            case .embeddedText, .hiddenText, .textFallback:
                // Live text keeps its resolved color (screening blends only
                // plot-mapped geometry pens, as with SHX text strokes).
                return item
            }
        }
    }

    /// DrawViewportsFirst (bit 512): viewport-projected content plots first
    /// (underneath), paper-space entities last. Stable within each group.
    static func orderForDrawViewportsFirst(_ items: [RenderItem], enabled: Bool) -> [RenderItem] {
        guard enabled else { return items }
        let projected = items.filter {
            if case .geometry(let e, _, _) = $0 { return e.isViewportProjected }
            return false
        }
        let paper = items.filter {
            if case .geometry(let e, _, _) = $0 { return !e.isViewportProjected }
            return true
        }
        return projected + paper
    }

    /// Plot-time host inputs (sysvars + CTB loader). Defaults preserve the
    /// legacy auto-fit path when no plot settings apply.
    public struct PlotContext: @unchecked Sendable {
        /// Mirrors PLOTTRANSPARENCYOVERRIDE (0 suppress, 1 per-setup, 2 force).
        public var transparencyOverride: Int
        /// Mirrors PLOTOFFSET (0 printable area, 1 paper edge).
        public var plotOffset: Int
        /// Resolves a style-sheet filename to a parsed table (CTB/STB).
        public var plotTableLoader: ((String) -> PlotStyleTable?)?

        public init(transparencyOverride: Int = 1, plotOffset: Int = 0,
                    plotTableLoader: ((String) -> PlotStyleTable?)? = nil) {
            self.transparencyOverride = transparencyOverride
            self.plotOffset = plotOffset
            self.plotTableLoader = plotTableLoader
        }

        public static let `default` = PlotContext()
    }

    /// Locate a plot-style file in the well-known support folders.
    public static func defaultPlotTableLoader(name: String) -> PlotStyleTable? {
        guard !name.isEmpty else { return nil }
        let dirs = ["Plot Styles", "./Plot Styles",
                    "Engine/EngineAsBuilt/Plot Styles"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if let table = try? PlotStyleTable.parse(url: url) { return table }
        }
        return nil
    }

    // ---------------------------------------------------------------------
    // MARK: Multi-page engine (Phase 2)
    // ---------------------------------------------------------------------

    /// Errors for multi-page PDF export.
    public enum PDFExportError: Error, Sendable {
        /// No page sources were supplied.
        case noPages
    }

    /// Sequential allocator for PDF object numbers. The assembler reserves
    /// every page/content object up front, then the shared font catalog
    /// numbers embedded faces from the first free number — so mixed page
    /// sizes and shared fonts never collide.
    public struct PDFObjectAllocator: Sendable {
        public var next: Int = 1
        public init() {}
        public mutating func allocate() -> Int {
            defer { next += 1 }
            return next
        }
    }

    /// One logical page for multi-page export: a rendering snapshot plus the
    /// resolved `CADPlotSettings` for that page (paper, framing, plot-style
    /// selection, PDF options). The exporter restores each snapshot into a
    /// throwaway document and applies the settings there, so the source
    /// drawings are never mutated.
    public struct PDFMultiPageSource: Sendable {
        public var snapshot: CADDocumentSnapshot
        public var plotSettings: CADPlotSettings?
        public var backgroundColor: ColorRGBA?

        public init(snapshot: CADDocumentSnapshot,
                    plotSettings: CADPlotSettings? = nil,
                    backgroundColor: ColorRGBA? = nil) {
            self.snapshot = snapshot
            self.plotSettings = plotSettings
            self.backgroundColor = backgroundColor
        }
    }

    /// One fully rendered page: baked content plus per-page size/measure
    /// metadata for the assembler. Each page keeps its own MediaBox and
    /// /Measure dictionary, so mixed page sizes stay exact.
    struct RenderedPage: Sendable {
        var pageW: Double
        var pageH: Double
        var contentData: Data
        var measureC: String
        var unitLabel: String
    }

    /// Resolve the effective text options for a page. `captureFonts` and
    /// `convertAllTextToGeometry` are wired from the resolved setup's PDF
    /// options (the PDF Options dialog). The remaining `PDFOptions` fields —
    /// `vectorDPI` / `rasterDPI`, `mergeControl`, `includeLayerInfo`, and
    /// `includeHyperlinks` — are parsed and persisted with the setup but
    /// currently inert: the exporter always emits vector geometry at paper
    /// scale, overwrites overlapping lines, and writes no OCG layer info or
    /// hyperlink annotations.
    static func effectiveOptions(base: PDFExportOptions,
                                 pdfOptions: PDFOptions?) -> PDFExportOptions {
        guard let pdfOptions else { return base }
        var out = base
        out.captureFonts = pdfOptions.captureFonts
        out.convertAllTextToGeometry = pdfOptions.convertTextToGeometry
        return out
    }

    /// Render one page (framing, fonts, draw order, plot styles) into a
    /// `RenderedPage`, registering any TrueType faces in the shared catalog.
    /// Called once per page; the assembler then writes the document.
    static func renderPage(document: CADDocument, backgroundColor: ColorRGBA?,
                            plotContext: PlotContext = .default,
                            options: PDFExportOptions = .default,
                           catalog: PDFTextEmitter.PDFFontCatalog) throws -> RenderedPage {
        // Background and contrast adjustment:
        // Default PDF page background in viewers is white.
        let options = Self.effectiveOptions(base: options, pdfOptions: document.plotSettings?.pdfOptions)
        let pageBg = backgroundColor ?? ColorRGBA.white
        let bgRf = Double(pageBg.r) / 255.0
        let bgGf = Double(pageBg.g) / 255.0
        let bgBf = Double(pageBg.b) / 255.0
        let bgLuminance = 0.2126 * bgRf + 0.7152 * bgGf + 0.0722 * bgBf
        let isLightBackground = bgLuminance >= 0.5

        // ---- Pre-pass: collect drawables in screen-parity order ----------
        var items = collectItems(document: document, isLightBackground: isLightBackground,
                                 options: options)

        // ---- World bounding box (engine Y-down space) ---------------------
        // Text-entity bounds come from the exploded glyph strokes; the cached
        // `worldBoundingBox` for those entities double-counts the position
        // (transform × absolute-position primitive) and would inflate the page.
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var hasGeom = false

        func grow(_ x: Double, _ y: Double) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            hasGeom = true
        }

        for item in items {
            switch item {
            case .geometry(let entity, _, _):
                if let bb = entity.worldBoundingBox {
                    grow(bb.min.x, bb.min.y); grow(bb.max.x, bb.max.y)
                }
            case .textStrokes(let prims, _):
                if let bb = primsBounds(prims) {
                    grow(bb.minX, bb.minY); grow(bb.maxX, bb.maxY)
                }
            case .embeddedText(let embedded):
                if let bb = embedded.bounds() {
                    grow(bb.minX, bb.minY); grow(bb.maxX, bb.maxY)
                }
            case .hiddenText:
                break // invisible: no page-fit contribution
            case .textFallback(let text, let position, _, let height, _):
                // Rough extent: baseline-left origin, ~0.6·h average advance.
                let w = Double(text.count) * height * 0.6
                grow(position.x, position.y - height)
                grow(position.x + w, position.y + height)
            }
        }
        if !hasGeom { minX = 0; minY = 0; maxX = 100; maxY = 100 }

        let worldW = max(maxX - minX, 1e-9)
        let worldH = max(maxY - minY, 1e-9)
        let scale: Double
        let pageW: Double
        let pageH: Double
        let margin: Double
        var plotClip: (Double, Double, Double, Double)? = nil
        var plotClipPage: (x: Double, y: Double, w: Double, h: Double)? = nil
        var plotTX: Double? = nil
        var plotTY: Double? = nil

        // Plot mode: exact paper size, scale, offset, and printable clip
        // from the layout's settings. Legacy auto-fit otherwise.
        let plotTable: PlotStyleTable?
        if let ps = document.plotSettings {
            plotTable = ps.styleSheet.isEmpty ? nil
                : (plotContext.plotTableLoader ?? Self.defaultPlotTableLoader)(ps.styleSheet)
        } else {
            plotTable = nil
        }
        if let ps = document.plotSettings,
           let frame = Self.plotFrame(
               settings: ps,
               worldBounds: hasGeom ? (minX, minY, maxX, maxY) : nil,
               transparencyOverride: plotContext.transparencyOverride,
               plotTable: plotTable,
               plotOffset: plotContext.plotOffset) {
            items = Self.orderForDrawViewportsFirst(
                items, enabled: ps.plotFlags & 512 != 0)
            items = Self.applyPlotStyles(
                items: items, document: document, settings: ps,
                plotTable: plotTable,
                transparencyOverride: plotContext.transparencyOverride)
            pageW = frame.pageW
            pageH = frame.pageH
            margin = 0.0
            scale = frame.scale
            plotTX = frame.tx
            plotTY = frame.ty
            plotClip = (frame.clipMinX, frame.clipMinY, frame.clipMaxX, frame.clipMaxY)
            if let cx = frame.clipPageX, let cy = frame.clipPageY,
               let cw = frame.clipPageW, let ch = frame.clipPageH {
                plotClipPage = (x: cx, y: cy, w: cw, h: ch)
            }
        } else if let layout = document.layoutSettings, layout.paperWidthMM > 0, layout.paperHeightMM > 0 {
            var pw = layout.paperWidthMM * 72.0 / 25.4
            var ph = layout.paperHeightMM * 72.0 / 25.4
            if layout.plotRotation == 1 || layout.plotRotation == 3 {
                swap(&pw, &ph)
            }
            pageW = max(pw, 10.0)
            pageH = max(ph, 10.0)
            margin = 0.0
            scale = min(pageW / worldW, pageH / worldH)
        } else {
            margin = 36.0
            (scale, pageW, pageH) = Self.pageScaleAndSize(
                worldW: worldW, worldH: worldH,
                pointsPerUnit: document.unit.pointsPerUnit, margin: margin)
        }
        // (Integer MediaBox dimensions are derived per page by the assembler.)

        // /Measure conversion: world units per point at the *effective* scale.
        let measC = String(format: "%.6f", 1.0 / scale)
        let unitLabel = document.unit.description

        // Content first: text emission registers TTF faces in the catalog,
        // whose numbers the page Resources dict must reference. Object
        // order in the file is arbitrary, so this is safe.
        // The shared catalog arrives from the caller (one per document). A
        // throwaway local catalog would drop embedded faces from the file.
        let content = PDFContentBuilder()
        if let bg = backgroundColor {
            content.raw("q\n")
            let r = Double(bg.r) / 255.0
            let g = Double(bg.g) / 255.0
            let b = Double(bg.b) / 255.0
            content.num(r); content.num(g); content.num(b); content.raw("rg\n")
            content.num(0); content.num(0); content.num(pageW); content.num(pageH); content.raw("re f\n")
            content.raw("Q\n")
        }
        writeContent(items: items, document: document, scale: scale, margin: margin,
                     minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                     pageW: pageW, pageH: pageH, isLightBackground: isLightBackground, to: content,
                     plotTX: plotTX, plotTY: plotTY, plotScale: plotTX == nil ? nil : scale,
                     clipWorld: plotClip, clipPageRect: plotClipPage,
                     options: options, catalog: catalog)
        let contentData = content.build()
        return RenderedPage(pageW: pageW, pageH: pageH, contentData: contentData,
                            measureC: measC, unitLabel: unitLabel)
    }

    /// Generate PDF data from a document (extracted for reuse by both sync and async paths).
    /// Single-page wrapper over the multi-page engine: renders one page and
    /// assembles a one-page document with the legacy object numbering
    /// (catalog 1, page 2, pages 3, content 4, standard fonts 5–6, embedded 7+).
    static func generatePDF(document: CADDocument, backgroundColor: ColorRGBA?,
                            plotContext: PlotContext = .default,
                            options: PDFExportOptions = .default) throws -> Data {
        var allocator = PDFObjectAllocator()
        let catalogObj = allocator.allocate()
        let pageObj = allocator.allocate()
        let pagesObj = allocator.allocate()
        let contentObj = allocator.allocate()
        let fontObjs = (allocator.allocate(), allocator.allocate())
        let catalog = PDFTextEmitter.PDFFontCatalog(firstNumber: allocator.next)
        let page = try renderPage(document: document, backgroundColor: backgroundColor,
                                  plotContext: plotContext, options: options,
                                  catalog: catalog)
        allocator.next = catalog.nextNumber
        return assembleDocument(pages: [page], catalog: catalog, catalogObj: catalogObj,
                                pageObjs: [pageObj], pagesObj: pagesObj,
                                contentObjs: [contentObj], fontObjs: fontObjs)
    }

    /// Generate a multi-page PDF from restored snapshots plus resolved plot
    /// settings, without mutating the source drawings. Each entry is restored
    /// into a throwaway document, its resolved settings applied there, and
    /// rendered through the same per-page path as single-page export — so
    /// framing, fonts, draw order, and plot-style behavior match page for
    /// page. Pages may use mixed sizes; each keeps its own MediaBox/Measure.
    public static func generateMultiPagePDF(
        sources: [PDFMultiPageSource],
        plotContext: PlotContext = .default,
        options: PDFExportOptions = .default
    ) throws -> Data {
        guard !sources.isEmpty else { throw PDFExportError.noPages }
        var allocator = PDFObjectAllocator()
        let catalogObj = allocator.allocate()
        let pageObjs = sources.map { _ in allocator.allocate() }
        let pagesObj = allocator.allocate()
        let contentObjs = sources.map { _ in allocator.allocate() }
        let fontObjs = (allocator.allocate(), allocator.allocate())
        let catalog = PDFTextEmitter.PDFFontCatalog(firstNumber: allocator.next)
        var pages: [RenderedPage] = []
        pages.reserveCapacity(sources.count)
        for source in sources {
            try Task.checkCancellation()
            let tempDoc = CADDocument()
            tempDoc.restore(from: source.snapshot)
            if let settings = source.plotSettings {
                tempDoc.plotSettings = settings
                tempDoc.layoutSettings = settings.layoutSettings
            }
            pages.append(try renderPage(document: tempDoc,
                                        backgroundColor: source.backgroundColor,
                                        plotContext: plotContext,
                                        options: options,
                                        catalog: catalog))
        }
        allocator.next = catalog.nextNumber
        return assembleDocument(pages: pages, catalog: catalog, catalogObj: catalogObj,
                                pageObjs: pageObjs, pagesObj: pagesObj,
                                contentObjs: contentObjs, fontObjs: fontObjs)
    }

    /// Multi-page file export with progress and cancellation, mirroring the
    /// single-snapshot `export(snapshot:to:)` path.
    public static func exportMultiPage(sources: [PDFMultiPageSource], to url: URL,
                                       plotContext: PlotContext = .default,
                                       options: PDFExportOptions = .default,
                                       progress: ((Float) -> Void)? = nil) throws {
        try Task.checkCancellation()
        let pdfData = try generateMultiPagePDF(sources: sources,
                                               plotContext: plotContext,
                                               options: options)
        try Task.checkCancellation()
        progress?(0.95)
        try atomicWrite(data: pdfData, to: url)
        progress?(0.99)
    }

    /// Assemble rendered pages plus the shared font catalog into a complete
    /// PDF 1.7 document. All object numbers arrive from the caller's
    /// `PDFObjectAllocator`; each page is written with its own MediaBox and
    /// /Measure dictionary so mixed page sizes stay exact.
    static func assembleDocument(pages: [RenderedPage],
                                 catalog: PDFTextEmitter.PDFFontCatalog,
                                 catalogObj: Int, pageObjs: [Int], pagesObj: Int,
                                 contentObjs: [Int], fontObjs: (Int, Int)) -> Data {
        let w = PDFByteWriter()

        // PDF 1.7 header with binary marker bytes (required per spec)
        w.write("%PDF-1.7\n")
        // At least 4 binary bytes with high bit set to flag binary content
        w.write("%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n")

        // Catalog with PDF 1.7 UseOutlines viewer preference
        w.beginObject(catalogObj)
        w.write("<< /Type /Catalog /Pages \(pagesObj) 0 R")
        w.write(" /ViewerPreferences << /PrintScaling /None /UseOutlines >> >>\n")
        w.endObject()

        // Pages (one dict per page: own MediaBox + Measure for mixed sizes)
        for (index, page) in pages.enumerated() {
            let pw = Int(round(page.pageW)); let ph = Int(round(page.pageH))
            w.beginObject(pageObjs[index])
            w.write("<< /Type /Page /Parent \(pagesObj) 0 R /MediaBox [0 0 \(pw) \(ph)]")
            w.write(" /VP [ << /Type /Viewport /BBox [0 0 \(pw) \(ph)]")
            w.write("   /Measure << /Type /Measure /Subtype /RL")
            w.write("     /R (\(page.unitLabel))")
            w.write("     /X [ << /Type /NumberFormat /U (\(page.unitLabel)) /C \(page.measureC) >> ]")
            w.write("   >> >> ]")
            w.write(" /Contents \(contentObjs[index]) 0 R")
            w.write(" /Resources << /Font << /F1 \(fontObjs.0) 0 R /F2 \(fontObjs.1) 0 R \(catalog.resourceString()) >> >> >>\n")
        w.endObject()

        }

        // Pages tree
        w.beginObject(pagesObj)
        w.write("<< /Type /Pages /Kids [\(pageObjs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>\n")
        w.endObject()

        // Content streams — FlateDecode compressed via zlib-ng
        for (index, page) in pages.enumerated() {
            w.beginObject(contentObjs[index])
            w.writeCompressedStream(page.contentData)
        w.endObject()

        }

        // Fonts — Standard 14 references
        writeFontRef(w, obj: fontObjs.0, name: "Helvetica")
        writeFontRef(w, obj: fontObjs.1, name: "Courier")
        // Embedded / referenced TTF faces (first free numbers onward).
        catalog.writeObjects(into: w)

        return w.finalize(rootObj: catalogObj)
    }

    // ---------------------------------------------------------------------
    // MARK: Page scale and size
    // ---------------------------------------------------------------------

    /// Page scale (points per world unit) and page size for a drawing extent.
    ///
    /// Starts at true unit scale (`pointsPerUnit`), scales DOWN so oversized
    /// drawings fit the viewer page limit, and scales UP so sub-letter
    /// drawings fill the minimum page instead of landing as a speck in the
    /// corner of a 612x792 sheet (paper-space layouts already at sheet size
    /// are unaffected — they already fill the page). Aspect ratio is always
    /// preserved; the `/Measure` dictionary is computed from the returned
    /// scale, so measurement calibration stays exact.
    static func pageScaleAndSize(worldW: Double, worldH: Double, pointsPerUnit: Double,
                                 margin: Double = 36)
        -> (scale: Double, pageW: Double, pageH: Double) {
        let minPageW = 612.0, minPageH = 792.0
        let w = max(worldW, 1e-9), h = max(worldH, 1e-9)
        var scale = pointsPerUnit
        if w * scale + margin * 2 > maxPagePoints || h * scale + margin * 2 > maxPagePoints {
            scale *= min((maxPagePoints - margin * 2) / (w * scale),
                         (maxPagePoints - margin * 2) / (h * scale))
        }
        if w * scale + margin * 2 < minPageW && h * scale + margin * 2 < minPageH {
            scale *= min((minPageW - margin * 2) / (w * scale),
                         (minPageH - margin * 2) / (h * scale))
        }
        return (scale,
                max(minPageW, w * scale + margin * 2),
                max(minPageH, h * scale + margin * 2))
    }

    // ---------------------------------------------------------------------
    // MARK: Pre-pass — entity collection (renderer parity)
    // ---------------------------------------------------------------------

    /// Sort entities exactly like `CADRendererBridge.computeSpecs`, resolve the
    /// per-entity color the same way (`dxf.color` xdata → layer color), and
    /// pre-explode text entities through the SHX path.
    static func collectItems(document: CADDocument, isLightBackground: Bool = false,
                             options: PDFExportOptions = .default) -> [RenderItem] {
        let sortedEntities = document.entitiesView.sorted { e1, e2 in
            let o1 = e1.drawOrder
            let o2 = e2.drawOrder
            if o1 != o2 { return o1 < o2 }
            return e1.handle.uuidString < e2.handle.uuidString
        }

        var items: [RenderItem] = []
        items.reserveCapacity(sortedEntities.count)

        for entity in sortedEntities {
            guard let baseLayer = document.layer(for: entity.layerID),
                  !LayerAccess.isFrozenInViewport(entity, in: document),
                  LayerAccess.isDrawn(baseLayer), LayerAccess.isPlottable(baseLayer)
            else { continue }
            let layer = LayerAccess.effectiveLayer(for: entity, in: document) ?? baseLayer

            // Entity color: explicit dxf.color override, else layer color.
            // (The old exporter scanned the first colored primitive — wrong
            // precedence, and wrong for multi-color blocks.)
            let rawColor: ColorRGBA
            if let cv = entity.xdata["dxf.color"], case .string(let hex) = cv,
               let c = ColorRGBA(hex: hex) {
                rawColor = c
            } else {
                rawColor = layer.color
            }
            let entityColor = rawColor.displayAdjusted(forLightBackground: isLightBackground)

            // Explicit entity lineweight (mm), else layer lineweight.
            let lineWeightMM: Double
            if let lw = entity.xdata["dxf.lineWeight"], case .double(let v) = lw, v > 0 {
                lineWeightMM = v
            } else {
                lineWeightMM = layer.lineWeight
            }

            // ---- Standalone TEXT/MTEXT entity (renderer's visibleText path) ----
            if let tv = entity.xdata["dxf.text"], case .string(let text) = tv, !text.isEmpty {
                let formatted: FormattedText?
                if let ftJSON = entity.xdata["dxf.formattedText"], case .string(let jsonStr) = ftJSON,
                   let jsonData = jsonStr.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(FormattedText.self, from: jsonData) {
                    formatted = decoded
                } else {
                    formatted = nil
                }
                let displayText = formatted?.toPlainText() ?? text
                let height: Double
                if let th = entity.xdata["dxf.textHeight"], case .double(let v) = th { height = v }
                else { height = 2.5 }

                let styleName: String?
                if let ts = entity.xdata["dxf.textStyle"], case .string(let value) = ts {
                    styleName = value
                } else {
                    styleName = nil
                }
                let textStyle = CADTextStyle.resolve(styleName, in: document.textStyles)
                let fontFile = CADFontManager.resolveTextStyleFont(
                    styleName: styleName,
                    textStyleFonts: document.textStyleFonts)
                let formattedTTFPath = CADFontManager.resolveFormattedTTFPath(
                    formatted,
                    styleName: styleName,
                    textStyleFonts: document.textStyleFonts)
                let formattedSHXFont = formattedTTFPath == nil
                    ? CADFontManager.resolveFormattedSHXFont(
                        formatted,
                        styleName: styleName,
                        textStyleFonts: document.textStyleFonts)
                    : nil
                let exactStyleSHXFont = CADFontManager.getOrLoadSHXFont(
                    filename: fontFile,
                    allowFallback: false)
                let shapeFont = formattedSHXFont
                    ?? (formattedTTFPath == nil ? exactStyleSHXFont : nil)
                    ?? CADFontManager.getOrLoadSHXFont(filename: fontFile)

                let alignH: Int
                if let ah = entity.xdata["dxf.alignH"], case .int(let v) = ah { alignH = v }
                else { alignH = 0 }
                let alignV: Int
                if let av = entity.xdata["dxf.alignV"], case .int(let v) = av { alignV = v }
                else { alignV = 0 }
                let mtextWidth: Double?
                if let mw = entity.xdata["dxf.mtextWidth"], case .double(let v) = mw { mtextWidth = v }
                else { mtextWidth = nil }

                // Basis vectors & scales from entity.transform (mirrors CADRendererBridge)
                let origin = entity.transform.position
                let localX = Vector3(x: 1, y: 0, z: 0)
                let localY = Vector3(x: 0, y: 1, z: 0)
                let worldX = entity.transform.transformPoint(localX) - origin
                let worldY = entity.transform.transformPoint(localY) - origin
                let heightScale = max(worldY.magnitude, 1e-12)
                let widthScale = max(worldX.magnitude, 1e-12)
                let worldRotation = atan2(worldX.y, worldX.x)

                let heightOverride: Bool
                if let value = entity.xdata["dxf.textHeightOverride"], case .int(let flag) = value {
                    heightOverride = flag != 0
                } else {
                    heightOverride = entity.xdata["dxf.textEntityType"] != nil
                }

                let isMTextEntity: Bool
                if let entityType = entity.xdata["dxf.textEntityType"], case .string(let value) = entityType {
                    isMTextEntity = value.uppercased() == "MTEXT"
                } else {
                    isMTextEntity = false
                }

                let widthFactor: Double
                if !isMTextEntity, let width = entity.xdata["dxf.textWidthScale"], case .double(let value) = width, value > 0 {
                    widthFactor = value
                } else {
                    widthFactor = 1.0
                }

                let widthFactorOverride: Bool
                if !isMTextEntity, let value = entity.xdata["dxf.textWidthScaleOverride"], case .int(let flag) = value {
                    widthFactorOverride = flag != 0
                } else {
                    widthFactorOverride = !isMTextEntity && abs(widthFactor - 1.0) > 1e-12
                }

                let oblique: Double
                if let value = entity.xdata["dxf.textOblique"], case .double(let angle) = value {
                    oblique = angle
                } else {
                    oblique = 0
                }

                let obliqueOverride: Bool
                if !isMTextEntity, let value = entity.xdata["dxf.textObliqueOverride"], case .int(let flag) = value {
                    obliqueOverride = flag != 0
                } else {
                    obliqueOverride = !isMTextEntity && abs(oblique) > 1e-12
                }

                let baseWidthFactor = widthFactorOverride ? widthFactor : textStyle.widthFactor
                let effectiveWidthFactor = baseWidthFactor * widthScale / heightScale
                let effectiveHeight = (heightOverride || textStyle.fixedHeight <= 0) ? height : textStyle.fixedHeight
                let worldHeight = effectiveHeight * heightScale
                let effectiveOblique = obliqueOverride ? oblique : textStyle.obliqueAngle
                let worldWidth = mtextWidth.map { $0 * widthScale }

                // ---- TTF route: live vector text (AutoCAD capture model) ----
                // Renderer parity: live text only when the screen would use
                // a TTF face too — an all-TTF formatted run set, or no
                // loadable SHX face for the style. SHX-backed styles
                // (romand, simplex, …) fall through to the stroke route even
                // when a TTF substitute file exists on disk.
                let rendererTTFPath = formattedTTFPath
                    ?? (exactStyleSHXFont == nil ? CADFontManager.getTTFEquivalent(filename: fontFile) : nil)
                // A resolvable TrueType face takes precedence over SHX: the
                // screen renders these styles through SDL_ttf, and the PDF
                // now measures with the same face's advances.
                let ttfBaseReference: String?
                if let formatted, !formatted.defaultFont.isEmpty {
                    ttfBaseReference = formatted.defaultFont
                } else {
                    ttfBaseReference = styleName
                }
                if let ttfBaseReference, rendererTTFPath != nil,
                   let baseFace = PDFTextEmitter.resolveBaseFace(
                       formatted: formatted, styleName: styleName,
                       textStyleFonts: document.textStyleFonts) {
                    let lineSpacingFactor: Double
                    if let spacing = entity.xdata["dxf.mtextLineSpacing"],
                       case .double(let value) = spacing,
                       value > 0 {
                        lineSpacingFactor = value
                    } else {
                        lineSpacingFactor = 1.0
                    }
                    let lineSpacingStyle: Int
                    if let style = entity.xdata["dxf.mtextLineSpacingStyle"],
                       case .int(let value) = style,
                       value == 2 {
                        lineSpacingStyle = 2
                    } else {
                        lineSpacingStyle = 1
                    }
                    let laid = PDFTextEmitter.layout(
                        formatted: formatted,
                        plainText: displayText,
                        origin: origin,
                        rotation: worldRotation,
                        heightWorld: worldHeight,
                        widthFactor: effectiveWidthFactor,
                        maxWidthWorld: worldWidth,
                        alignH: alignH,
                        alignV: alignV,
                        lineSpacingFactor: lineSpacingFactor,
                        lineSpacingStyle: lineSpacingStyle,
                        baseFace: baseFace)
                    if options.convertAllTextToGeometry, baseFace.font.hasGlyphOutlines {
                        items.append(.textStrokes(
                            prims: PDFTextEmitter.geometryOutlines(
                                laid, rotation: worldRotation,
                                widthFactor: effectiveWidthFactor,
                                obliqueDegrees: effectiveOblique),
                            color: entityColor))
                    } else {
                        let displayName: String
                        if let runFont = formatted?.paragraphs.first?.runs.first?.fontName,
                           !runFont.isEmpty {
                            displayName = runFont
                        } else {
                            displayName = ttfBaseReference
                        }
                        items.append(.embeddedText(PDFTextEmitter.EmbeddedItem(
                            laid: laid, displayName: displayName,
                            rotation: worldRotation,
                            widthFactor: effectiveWidthFactor,
                            obliqueDegrees: effectiveOblique,
                            color: entityColor)))
                    }
                    continue
                }

                if let font = shapeFont {
                    let lineSpacingFactor: Double
                    if let spacing = entity.xdata["dxf.mtextLineSpacing"],
                       case .double(let value) = spacing,
                       value > 0 {
                        lineSpacingFactor = value
                    } else {
                        lineSpacingFactor = 1.0
                    }
                    let lineSpacingStyle: Int
                    if let style = entity.xdata["dxf.mtextLineSpacingStyle"],
                       case .int(let value) = style,
                       value == 2 {
                        lineSpacingStyle = 2
                    } else {
                        lineSpacingStyle = 1
                    }
                    let prims: [CADPrimitive]
                    if var formatted {
                        let localHeightScale = effectiveHeight / max(height, 1e-12)
                        formatted.styleName = textStyle.name
                        formatted.defaultFont = fontFile
                        formatted.defaultHeight *= localHeightScale * heightScale
                        for paragraphIndex in formatted.paragraphs.indices {
                            for runIndex in formatted.paragraphs[paragraphIndex].runs.indices {
                                if let runHeight = formatted.paragraphs[paragraphIndex].runs[runIndex].height {
                                    formatted.paragraphs[paragraphIndex].runs[runIndex].height = runHeight * localHeightScale * heightScale
                                }
                                if formatted.paragraphs[paragraphIndex].runs[runIndex].oblique == nil {
                                    formatted.paragraphs[paragraphIndex].runs[runIndex].oblique = effectiveOblique
                                }
                            }
                        }
                        prims = font.renderFormattedText(
                            formatted,
                            origin: origin,
                            rotation: worldRotation,
                            alignH: alignH,
                            alignV: alignV,
                            widthFactor: effectiveWidthFactor,
                            maxWidth: worldWidth,
                            lineSpacingFactor: lineSpacingFactor,
                            lineSpacingStyle: lineSpacingStyle,
                            textStyleFonts: document.textStyleFonts)
                    } else {
                        prims = font.renderText(
                            displayText,
                            origin: origin,
                            height: worldHeight,
                            rotation: worldRotation,
                            alignH: alignH,
                            alignV: alignV,
                            widthFactor: effectiveWidthFactor,
                            obliqueAngle: effectiveOblique,
                            maxWidth: worldWidth)
                    }
                    items.append(.textStrokes(prims: prims, color: entityColor))
                    if options.includeHiddenTextForSHX {
                        items.append(.hiddenText(
                            text: displayText,
                            position: origin,
                            rotation: worldRotation,
                            height: worldHeight))
                    }
                } else {
                    items.append(.textFallback(
                        text: displayText,
                        position: origin,
                        rotation: worldRotation,
                        height: worldHeight,
                        color: entityColor))
                }
                continue   // NEVER fall through to geometry — the .text primitive
                           // in localGeometry duplicates position/rotation.
            }

            guard entity.resolvedGeometry(in: document)?.isEmpty == false else { continue }
            if let array = entity.arrayData {
                let path = CADArrayPathResolver.points(
                    for: array,
                    containerTransform: entity.transform,
                    document: document)
                let sourceBox = entity.blockID.flatMap { document.block(for: $0)?.localBoundingBox }
                for instance in array.evaluatedInstances(pathPoints: path) {
                    let virtual = CADEntity(
                        handle: entity.handle,
                        layerID: entity.layerID,
                        blockID: entity.blockID,
                        localGeometry: entity.localGeometry,
                        dimensionMetadata: entity.dimensionMetadata,
                        leaderData: entity.leaderData,
                        transform: entity.transform.multiplying(by: instance.transform),
                        xdata: entity.xdata,
                        drawOrder: entity.drawOrder,
                        localBoundingBox: sourceBox)
                    items.append(.geometry(
                        entity: virtual,
                        color: entityColor,
                        lineWeightMM: lineWeightMM))
                }
            } else {
                items.append(.geometry(entity: entity, color: entityColor, lineWeightMM: lineWeightMM))
            }
        }
        return items
    }

    // ---------------------------------------------------------------------
    // MARK: Content stream assembly
    // ---------------------------------------------------------------------

    static func writeContent(
        items: [RenderItem], document: CADDocument, scale: Double, margin: Double,
        minX: Double, maxX: Double = 0, minY: Double = 0, maxY: Double,
        pageW: Double = 0, pageH: Double = 0, isLightBackground: Bool = false,
        to cb: PDFContentBuilder,
        plotTX: Double? = nil, plotTY: Double? = nil, plotScale: Double? = nil,
        clipWorld: (Double, Double, Double, Double)? = nil,
        clipPageRect: (x: Double, y: Double, w: Double, h: Double)? = nil,
        options: PDFExportOptions = .default,
        catalog: PDFTextEmitter.PDFFontCatalog? = nil
    ) {
        // Y-FLIPPING page CTM: engine Y-down → PDF Y-up.
        //   device.x =  scale * world.x + tx
        //   device.y = -scale * world.y + ty
        // World maxY (engine "bottom" of bbox) maps to the page bottom margin.
        // Plot mode supplies an explicit CTM + printable-area clip instead.
        let tx: Double
        let ty: Double
        if let plotScale, let plotTX, let plotTY {
            tx = plotTX
            ty = plotTY
            if let clip = clipPageRect {
                cb.num(clip.x); cb.num(clip.y); cb.num(clip.w); cb.num(clip.h)
                cb.raw("re W n\n")
            }
            cb.num(plotScale); cb.num(0); cb.num(0); cb.num(-plotScale)
            cb.num(tx); cb.num(ty); cb.raw("cm\n")
            if clipPageRect == nil, let clipWorld {
                let cw = clipWorld.2 - clipWorld.0
                let ch = clipWorld.3 - clipWorld.1
                cb.num(clipWorld.0); cb.num(clipWorld.1); cb.num(cw); cb.num(ch)
                cb.raw("re W n\n")
            }
        } else {
            let contentW = (maxX - minX) * scale
            let contentH = (maxY - minY) * scale
            let offsetX = margin > 0 ? margin : max(0.0, (pageW - contentW) * 0.5)
            let offsetY = margin > 0 ? margin : max(0.0, (pageH - contentH) * 0.5)
            tx = offsetX - minX * scale
            ty = offsetY + maxY * scale
            cb.num(scale); cb.num(0); cb.num(0); cb.num(-scale); cb.num(tx); cb.num(ty); cb.raw("cm\n")
        }

        // A throwaway catalog keeps direct callers (tests) working; the real
        // export passes its own so font objects land in the file.
        let catalog = catalog ?? PDFTextEmitter.PDFFontCatalog()
        for item in items {
            switch item {
            case .geometry(let entity, let color, let lineWeightMM):
                PDFPrimitives.writeEntity(entity, in: document, entityColor: color,
                                          lineWeightMM: lineWeightMM, pageScale: scale,
                                          isLightBackground: isLightBackground, to: cb,
                                          options: options, catalog: catalog)
            case .textStrokes(let prims, let color):
                PDFPrimitives.writeWorldPrimitives(prims, defaultColor: color,
                                                   lineWeightMM: 0.25, pageScale: scale,
                                                   isLightBackground: isLightBackground, to: cb)
            case .embeddedText(let embedded):
                PDFTextEmitter.emit(
                    embedded.laid, displayName: embedded.displayName,
                    rotation: embedded.rotation, widthFactor: embedded.widthFactor,
                    obliqueDegrees: embedded.obliqueDegrees,
                    color: embedded.color.displayAdjusted(forLightBackground: isLightBackground),
                    options: options, catalog: catalog, to: cb)
            case .hiddenText(let text, let position, let rotation, let height):
                PDFTextEmitter.emitHiddenText(
                    text, position: position, rotation: rotation, height: height, to: cb)
            case .textFallback(let text, let position, let rotation, let height, let color):
                cb.raw("q\n")
                PDFPrimitives.setColor(color.displayAdjusted(forLightBackground: isLightBackground), to: cb)
                PDFPrimitives.writeFallbackText(text, position: position, rotation: rotation,
                                                height: height, to: cb)
                cb.raw("Q\n")
            }
        }
    }

    // ---------------------------------------------------------------------
    // MARK: Helpers
    // ---------------------------------------------------------------------

    /// Conservative world-space bounds over a primitive list. Used for
    /// exploded text strokes (lines / polygons / arcs).
    static func primsBounds(_ prims: [CADPrimitive])
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var any = false

        func grow(_ v: Vector3) {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minY = min(minY, v.y); maxY = max(maxY, v.y)
            any = true
        }

        for p in prims {
            switch p {
            case .point(let pos, _): grow(pos)
            case .line(let s, let e, _): grow(s); grow(e)
            case .rect(let o, let s, _), .fillRect(let o, let s, _):
                grow(o); grow(Vector3(x: o.x + s.x, y: o.y + s.y, z: o.z))
            case .polygon(let pts, _), .fillPolygon(let pts, _):
                for pt in pts { grow(pt) }
            case .polyline(let path, _):
                for point in path.boundingPoints() { grow(point) }
            case .fillComplexPolygon(let outer, let holes, _):
                for pt in outer { grow(pt) }
                for hole in holes { for pt in hole { grow(pt) } }
            case .circle(let c, let r, _), .arc(let c, let r, _, _, _):
                grow(Vector3(x: c.x - r, y: c.y - r, z: c.z))
                grow(Vector3(x: c.x + r, y: c.y + r, z: c.z))
            case .spline(let cps, _, _, _, _):
                for pt in cps { grow(pt) }
            case .penStroke(let vertices, _, _):
                for v in vertices { grow(v.position) }
            case .ellipse(let c, let major, _, _):
                let m = major.magnitude
                grow(Vector3(x: c.x - m, y: c.y - m, z: c.z))
                grow(Vector3(x: c.x + m, y: c.y + m, z: c.z))
            case .hatch(let boundary, _, _, _, _, _):
                for pt in boundary { grow(pt) }
            case .hatchPath(let boundary, let holes, _, _, _, _, _):
                for pt in boundary.boundingPoints() { grow(pt) }
                for hole in holes { for pt in hole.boundingPoints() { grow(pt) } }
            case .gradient(let outer, _, _, _, _, _):
                for pt in outer { grow(pt) }
            case .text(let pos, _, let h, _, _, _, _, _, _):
                grow(Vector3(x: pos.x - h, y: pos.y - h, z: pos.z))
                grow(Vector3(x: pos.x + h, y: pos.y + h, z: pos.z))
            case .ray(let start, _, _):
                grow(start)
            case .xline(let point, _, _):
                grow(point)
            case .table: break
            case .image(let insertion, let uAxis, let vAxis, _, _, _):
                grow(insertion)
                grow(Vector3(x: insertion.x + uAxis.x, y: insertion.y + uAxis.y, z: insertion.z + uAxis.z))
                grow(Vector3(x: insertion.x + uAxis.x + vAxis.x, y: insertion.y + uAxis.y + vAxis.y, z: insertion.z + uAxis.z + vAxis.z))
                grow(Vector3(x: insertion.x + vAxis.x, y: insertion.y + vAxis.y, z: insertion.z + vAxis.z))
            }
        }
        return any ? (minX, minY, maxX, maxY) : nil
    }

    private static func writeFontRef(_ w: PDFByteWriter, obj: Int, name: String) {
        w.beginObject(obj)
        w.write("<< /Type /Font /Subtype /Type1 /BaseFont /\(name) >>\n")
        w.endObject()
    }
}

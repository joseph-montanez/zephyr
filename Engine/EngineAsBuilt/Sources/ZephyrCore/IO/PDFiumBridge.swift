import Foundation
import CZLibNG

struct PDFVectorPage {
    let width: Double
    let height: Double
    let solidEntities: [[CADPrimitive]]
    let geometryEntities: [[CADPrimitive]]
    let textEntities: [[CADPrimitive]]

    var isEmpty: Bool {
        solidEntities.isEmpty && geometryEntities.isEmpty && textEntities.isEmpty
    }
}

// =========================================================================
// MARK: - PDFiumBridge
//
// Dynamically loads pdfium.dll at runtime via LoadLibrary/GetProcAddress
// (Windows) or dlopen/dlsym (macOS/Linux). All pdfium C API functions are
// resolved through function pointers — no C target in the SPM build graph.
//
// This avoids a Clang importer bug on Windows where adding a new C module
// causes SDL_SCANCODE_* constants to become invisible in Swift.
//
// Output is raw BGRA pixels (pdfium's native format). Use PNGEncoder to
// convert to PNG.
// =========================================================================

#if os(Windows)
@_silgen_name("LoadLibraryA")
private func win32_LoadLibraryA(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

@_silgen_name("GetProcAddress")
private func win32_GetProcAddress(_ hModule: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
#endif

enum PDFiumBridge {
    private struct PDFMatrix {
        var a: Float = 1
        var b: Float = 0
        var c: Float = 0
        var d: Float = 1
        var e: Float = 0
        var f: Float = 0

        static let identity = PDFMatrix()

        func applying(to point: (Double, Double)) -> (Double, Double) {
            (
                Double(a) * point.0 + Double(c) * point.1 + Double(e),
                Double(b) * point.0 + Double(d) * point.1 + Double(f)
            )
        }

        /// Returns `self * child`, matching PDF affine matrix composition.
        func concatenating(_ child: PDFMatrix) -> PDFMatrix {
            PDFMatrix(
                a: a * child.a + c * child.b,
                b: b * child.a + d * child.b,
                c: a * child.c + c * child.d,
                d: b * child.c + d * child.d,
                e: a * child.e + c * child.f + e,
                f: b * child.e + d * child.f + f
            )
        }
    }


    // ---- Library handle ----
    // nonisolated(unsafe) is required in Swift 6 because UnsafeMutableRawPointer
    // is not Sendable and static stored properties in a non-global-actor context
    // must be concurrency-safe.

#if os(Windows)
    private nonisolated(unsafe) static let dll: UnsafeMutableRawPointer? = {
        guard let h = win32_LoadLibraryA("pdfium.dll") else {
            print("[PDFiumBridge] pdfium.dll not found — PDF import unavailable.")
            return nil
        }
        return h
    }()
#else
    private nonisolated(unsafe) static let dll: UnsafeMutableRawPointer? = {
        let paths = [
            "libpdfium.dylib",
            "./libpdfium.dylib",
            "libpdfium.so"
        ]
        for path in paths {
            if let h = dlopen(path, RTLD_NOW) {
                return h
            }
        }
        print("[PDFiumBridge] libpdfium not found — PDF import unavailable.")
        return nil
    }()
#endif

    static var isAvailable: Bool { dll != nil }

    // ---- Function pointer resolution ----

    private static func resolve<T>(_ name: String) -> T? {
        guard let h = dll else { return nil }
#if os(Windows)
        guard let ptr = name.withCString({ win32_GetProcAddress(h, $0) }) else {
            print("[PDFiumBridge] missing symbol: \(name)")
            return nil
        }
#else
        guard let ptr = dlsym(h, name) else {
            print("[PDFiumBridge] missing symbol: \(name)")
            return nil
        }
#endif
        return unsafeBitCast(ptr, to: T.self)
    }

    // ---- pdfium C API typedefs ----

    private typealias f_void       = @convention(c) () -> Void
    private typealias f_LDoc       = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias f_CDoc       = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias f_GCount     = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_LPage      = @convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafeMutableRawPointer?
    private typealias f_CPage      = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias f_CreateBM   = @convention(c) (Int32, Int32, Int32, UnsafeMutableRawPointer?, Int32) -> UnsafeMutableRawPointer?
    private typealias f_DestroyBM  = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias f_FillBM     = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, UInt32) -> Void
    private typealias f_Render     = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, Int32, Int32) -> Void
    private typealias f_GetBuf     = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias f_GetStride  = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_GetSize    = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    private typealias f_CountObj   = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_GetObj     = @convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafeMutableRawPointer?
    private typealias f_ObjType    = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_GetMatrix  = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias f_GetColor   = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias f_GetWidth   = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?) -> Int32
    private typealias f_PathCount  = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_PathSeg    = @convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafeMutableRawPointer?
    private typealias f_SegPoint   = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?) -> Int32
    private typealias f_SegType    = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_SegClose   = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_DrawMode   = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias f_FormCount  = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias f_FormObj    = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> UnsafeMutableRawPointer?
    private typealias f_TextLoad   = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias f_TextClose  = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias f_TextValue  = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt16>?, UInt32) -> UInt32
    private typealias f_FontSize   = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?) -> Int32

    // ---- Resolved function pointers ----

    private static let fp_init:        f_void?       = resolve("FPDF_InitLibrary")
    private static let fp_loadDoc:     f_LDoc?       = resolve("FPDF_LoadDocument")
    private static let fp_closeDoc:    f_CDoc?       = resolve("FPDF_CloseDocument")
    private static let fp_pageCount:   f_GCount?     = resolve("FPDF_GetPageCount")
    private static let fp_loadPage:    f_LPage?      = resolve("FPDF_LoadPage")
    private static let fp_closePage:   f_CPage?      = resolve("FPDF_ClosePage")
    private static let fp_createBM:    f_CreateBM?   = resolve("FPDFBitmap_CreateEx")
    private static let fp_destroyBM:   f_DestroyBM?  = resolve("FPDFBitmap_Destroy")
    private static let fp_fillBM:      f_FillBM?     = resolve("FPDFBitmap_FillRect")
    private static let fp_render:      f_Render?     = resolve("FPDF_RenderPageBitmap")
    private static let fp_getBuf:      f_GetBuf?     = resolve("FPDFBitmap_GetBuffer")
    private static let fp_getStride:   f_GetStride?  = resolve("FPDFBitmap_GetStride")
    private static let fp_getSize:     f_GetSize?    = resolve("FPDF_GetPageSizeByIndex")
    private static let fp_countObj:    f_CountObj?   = resolve("FPDFPage_CountObjects")
    private static let fp_getObj:      f_GetObj?     = resolve("FPDFPage_GetObject")
    private static let fp_objType:     f_ObjType?    = resolve("FPDFPageObj_GetType")
    private static let fp_getMatrix:   f_GetMatrix?  = resolve("FPDFPageObj_GetMatrix")
    private static let fp_strokeColor: f_GetColor?   = resolve("FPDFPageObj_GetStrokeColor")
    private static let fp_fillColor:   f_GetColor?   = resolve("FPDFPageObj_GetFillColor")
    private static let fp_strokeWidth: f_GetWidth?   = resolve("FPDFPageObj_GetStrokeWidth")
    private static let fp_pathCount:   f_PathCount?  = resolve("FPDFPath_CountSegments")
    private static let fp_pathSeg:     f_PathSeg?    = resolve("FPDFPath_GetPathSegment")
    private static let fp_segPoint:    f_SegPoint?   = resolve("FPDFPathSegment_GetPoint")
    private static let fp_segType:     f_SegType?    = resolve("FPDFPathSegment_GetType")
    private static let fp_segClose:    f_SegClose?   = resolve("FPDFPathSegment_GetClose")
    private static let fp_drawMode:    f_DrawMode?   = resolve("FPDFPath_GetDrawMode")
    private static let fp_formCount:   f_FormCount?  = resolve("FPDFFormObj_CountObjects")
    private static let fp_formObj:     f_FormObj?    = resolve("FPDFFormObj_GetObject")
    private static let fp_textLoad:    f_TextLoad?   = resolve("FPDFText_LoadPage")
    private static let fp_textClose:   f_TextClose?  = resolve("FPDFText_ClosePage")
    private static let fp_textValue:   f_TextValue?  = resolve("FPDFTextObj_GetText")
    private static let fp_fontSize:    f_FontSize?   = resolve("FPDFTextObj_GetFontSize")

    // PDFium's V8 platform cannot be initialized again after
    // FPDF_DestroyLibrary(). Page probing and rendering happen as separate
    // calls, so initialize once and keep PDFium alive for the process lifetime.
    private static let initialized: Bool = {
        guard let initialize = fp_init else { return false }
        initialize()
        return true
    }()

    // ---- Public API ----

    static func pageCount(path: String) -> Int? {
        guard initialized, let loadDoc = fp_loadDoc, let getPageCount = fp_pageCount,
              let closeDoc = fp_closeDoc else { return nil }
        guard let doc = loadDoc(path, nil) else { return nil }
        let count = getPageCount(doc)
        closeDoc(doc)
        return Int(count)
    }

    static func extractVectorPage(path: String, pageIndex: Int) -> PDFVectorPage? {
        guard initialized, let loadDoc = fp_loadDoc, let closeDoc = fp_closeDoc,
              let getCount = fp_pageCount, let loadPage = fp_loadPage,
              let closePage = fp_closePage, let getSize = fp_getSize,
              let countObjects = fp_countObj, let getObject = fp_getObj,
              let loadText = fp_textLoad, let closeText = fp_textClose
        else { return nil }

        guard let document = loadDoc(path, nil) else { return nil }
        defer { closeDoc(document) }
        guard pageIndex >= 0, pageIndex < Int(getCount(document)) else { return nil }

        var width: Double = 0
        var height: Double = 0
        guard getSize(document, Int32(pageIndex), &width, &height) != 0,
              width > 0, height > 0 else { return nil }
        guard let page = loadPage(document, Int32(pageIndex)) else { return nil }
        defer { closePage(page) }

        let textPage = loadText(page)
        defer { if let textPage { closeText(textPage) } }

        var solidEntities: [[CADPrimitive]] = []
        var geometryEntities: [[CADPrimitive]] = []
        var textEntities: [[CADPrimitive]] = []
        let objectCount = max(0, Int(countObjects(page)))
        for index in 0..<objectCount {
            guard let object = getObject(page, Int32(index)) else { continue }
            extractObject(
                object, parentMatrix: .identity, pageHeight: height,
                textPage: textPage,
                solidEntities: &solidEntities,
                geometryEntities: &geometryEntities,
                textEntities: &textEntities,
                depth: 0
            )
        }
        return PDFVectorPage(
            width: width, height: height,
            solidEntities: solidEntities,
            geometryEntities: geometryEntities,
            textEntities: textEntities
        )
    }

    private static func extractObject(
        _ object: UnsafeMutableRawPointer,
        parentMatrix: PDFMatrix,
        pageHeight: Double,
        textPage: UnsafeMutableRawPointer?,
        solidEntities: inout [[CADPrimitive]],
        geometryEntities: inout [[CADPrimitive]],
        textEntities: inout [[CADPrimitive]],
        depth: Int
    ) {
        guard depth < 32, let getType = fp_objType else { return }
        var local = PDFMatrix.identity
        withUnsafeMutablePointer(to: &local) {
            _ = fp_getMatrix?(object, UnsafeMutableRawPointer($0))
        }
        let matrix = parentMatrix.concatenating(local)

        switch getType(object) {
        case 1:
            if let primitive = extractText(
                object, matrix: matrix, pageHeight: pageHeight, textPage: textPage
            ) {
                textEntities.append([primitive])
            }
        case 2:
            let extracted = extractPath(
                object, matrix: matrix, pageHeight: pageHeight
            )
            if !extracted.solids.isEmpty {
                solidEntities.append(extracted.solids)
            }
            if !extracted.geometry.isEmpty {
                geometryEntities.append(extracted.geometry)
            }
        case 5:
            guard let countFormObjects = fp_formCount, let getFormObject = fp_formObj else { return }
            let count = max(0, Int(countFormObjects(object)))
            for index in 0..<count {
                guard let child = getFormObject(object, UInt32(index)) else { continue }
                extractObject(
                    child, parentMatrix: matrix, pageHeight: pageHeight,
                    textPage: textPage,
                    solidEntities: &solidEntities,
                    geometryEntities: &geometryEntities,
                    textEntities: &textEntities,
                    depth: depth + 1
                )
            }
        default:
            break
        }
    }

    private static func extractPath(
        _ object: UnsafeMutableRawPointer,
        matrix: PDFMatrix,
        pageHeight: Double
    ) -> (solids: [CADPrimitive], geometry: [CADPrimitive]) {
        guard let countSegments = fp_pathCount, let getSegment = fp_pathSeg,
              let getPoint = fp_segPoint, let getType = fp_segType,
              let getClose = fp_segClose, let getMode = fp_drawMode
        else { return ([], []) }

        var fillMode: Int32 = 0
        var stroked: Int32 = 0
        guard getMode(object, &fillMode, &stroked) != 0 else { return ([], []) }

        var fillSubpaths: [[Vector3]] = []
        var fillCurrent: [Vector3] = []
        var geometry: [CADPrimitive] = []
        var lineRun: [Vector3] = []
        var subpathStart: Vector3?
        var currentPoint: Vector3?
        var cubic: [Vector3] = []
        let count = max(0, Int(countSegments(object)))
        let fillColor = objectColor(object, getter: fp_fillColor)
        let strokeColor = objectColor(object, getter: fp_strokeColor)

        func transformed(_ point: (Double, Double)) -> Vector3 {
            let p = matrix.applying(to: point)
            return Vector3(x: p.0, y: pageHeight - p.1, z: 0)
        }

        func flushLineRun() {
            guard stroked != 0, lineRun.count >= 2 else {
                lineRun.removeAll(keepingCapacity: true)
                return
            }
            if lineRun.count == 2 {
                geometry.append(.line(
                    start: lineRun[0], end: lineRun[1], color: strokeColor
                ))
            } else {
                geometry.append(.polyline(points: lineRun, color: strokeColor))
            }
            lineRun.removeAll(keepingCapacity: true)
        }

        func finishSubpath(close: Bool) {
            if close, let first = subpathStart, let last = currentPoint,
               first.distance(to: last) > 1e-8 {
                fillCurrent.append(first)
                if stroked != 0 {
                    flushLineRun()
                    geometry.append(.line(start: last, end: first, color: strokeColor))
                }
                currentPoint = first
            } else {
                flushLineRun()
            }
            if fillCurrent.count >= 3 {
                fillSubpaths.append(fillCurrent)
            }
            fillCurrent.removeAll(keepingCapacity: true)
            cubic.removeAll(keepingCapacity: true)
            lineRun.removeAll(keepingCapacity: true)
            subpathStart = nil
            currentPoint = nil
        }

        func appendFlattenedCubic(
            _ p0: Vector3, _ p1: Vector3, _ p2: Vector3, _ p3: Vector3,
            to output: inout [Vector3], depth: Int = 0
        ) {
            let chord = p3 - p0
            let chordLength = max(chord.magnitude, 1e-12)
            func distanceFromChord(_ p: Vector3) -> Double {
                abs(chord.x * (p0.y - p.y) - (p0.x - p.x) * chord.y) / chordLength
            }
            if depth >= 10 || max(distanceFromChord(p1), distanceFromChord(p2)) <= 0.05 {
                output.append(p3)
                return
            }
            let p01 = (p0 + p1) * 0.5
            let p12 = (p1 + p2) * 0.5
            let p23 = (p2 + p3) * 0.5
            let p012 = (p01 + p12) * 0.5
            let p123 = (p12 + p23) * 0.5
            let mid = (p012 + p123) * 0.5
            appendFlattenedCubic(p0, p01, p012, mid, to: &output, depth: depth + 1)
            appendFlattenedCubic(mid, p123, p23, p3, to: &output, depth: depth + 1)
        }

        for index in 0..<count {
            guard let segment = getSegment(object, Int32(index)) else { continue }
            var x: Float = 0
            var y: Float = 0
            guard getPoint(segment, &x, &y) != 0 else { continue }
            let point = transformed((Double(x), Double(y)))
            switch getType(segment) {
            case 2: // FPDF_SEGMENT_MOVETO
                if currentPoint != nil { finishSubpath(close: false) }
                subpathStart = point
                currentPoint = point
                fillCurrent = [point]
                lineRun = [point]
            case 0: // FPDF_SEGMENT_LINETO
                cubic.removeAll(keepingCapacity: true)
                guard currentPoint != nil else {
                    subpathStart = point
                    currentPoint = point
                    fillCurrent = [point]
                    lineRun = [point]
                    continue
                }
                fillCurrent.append(point)
                lineRun.append(point)
                currentPoint = point
            case 1: // FPDF_SEGMENT_BEZIERTO; control1/control2/end triples
                cubic.append(point)
                if cubic.count == 3, let start = currentPoint {
                    flushLineRun()
                    if stroked != 0 {
                        geometry.append(.spline(
                            controlPoints: [start, cubic[0], cubic[1], cubic[2]],
                            knots: [0, 0, 0, 0, 1, 1, 1, 1],
                            degree: 3,
                            weights: nil,
                            color: strokeColor
                        ))
                    }
                    appendFlattenedCubic(
                        start, cubic[0], cubic[1], cubic[2], to: &fillCurrent
                    )
                    currentPoint = cubic[2]
                    lineRun = [cubic[2]]
                    cubic.removeAll(keepingCapacity: true)
                }
            default:
                break
            }
            if getClose(segment) != 0 {
                finishSubpath(close: true)
            }
        }
        if currentPoint != nil { finishSubpath(close: false) }

        let solids = fillMode == 0
            ? []
            : makeCompoundFills(from: fillSubpaths, color: fillColor)
        return (solids, geometry)
    }

    private static func makeCompoundFills(
        from rawLoops: [[Vector3]],
        color: ColorRGBA?
    ) -> [CADPrimitive] {
        let loops = rawLoops.compactMap { raw -> [Vector3]? in
            var loop = raw
            if loop.count > 1, loop.first == loop.last { loop.removeLast() }
            return loop.count >= 3 ? loop : nil
        }
        guard !loops.isEmpty else { return [] }

        func area(_ loop: [Vector3]) -> Double {
            var result = 0.0
            for i in loop.indices {
                let j = (i + 1) % loop.count
                result += loop[i].x * loop[j].y - loop[j].x * loop[i].y
            }
            return result * 0.5
        }
        func contains(_ point: Vector3, _ loop: [Vector3]) -> Bool {
            var inside = false
            var j = loop.count - 1
            for i in loop.indices {
                let pi = loop[i], pj = loop[j]
                if ((pi.y > point.y) != (pj.y > point.y)),
                   point.x < (pj.x - pi.x) * (point.y - pi.y) /
                    ((pj.y - pi.y) == 0 ? 1e-12 : (pj.y - pi.y)) + pi.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        let magnitudes = loops.map { abs(area($0)) }
        var parents = [Int?](repeating: nil, count: loops.count)
        for child in loops.indices {
            var best: Int?
            for candidate in loops.indices where candidate != child {
                guard magnitudes[candidate] > magnitudes[child],
                      contains(loops[child][0], loops[candidate]) else { continue }
                if best == nil || magnitudes[candidate] < magnitudes[best!] {
                    best = candidate
                }
            }
            parents[child] = best
        }
        func depth(of index: Int) -> Int {
            var d = 0
            var parent = parents[index]
            while let value = parent, d < loops.count {
                d += 1
                parent = parents[value]
            }
            return d
        }

        var result: [CADPrimitive] = []
        for outer in loops.indices where depth(of: outer).isMultiple(of: 2) {
            let holes = loops.indices.filter {
                parents[$0] == outer && !depth(of: $0).isMultiple(of: 2)
            }.map { loops[$0] }
            if holes.isEmpty {
                result.append(.fillPolygon(points: loops[outer], color: color))
            } else {
                result.append(.fillComplexPolygon(
                    outer: loops[outer], holes: holes, color: color
                ))
            }
        }
        return result
    }

    private static func extractText(
        _ object: UnsafeMutableRawPointer,
        matrix: PDFMatrix,
        pageHeight: Double,
        textPage: UnsafeMutableRawPointer?
    ) -> CADPrimitive? {
        guard let textPage, let getText = fp_textValue, let getFontSize = fp_fontSize else {
            return nil
        }
        let byteCount = getText(object, textPage, nil, 0)
        guard byteCount >= 2 else { return nil }
        let unitCount = Int(byteCount / 2)
        var utf16 = [UInt16](repeating: 0, count: unitCount)
        guard getText(object, textPage, &utf16, byteCount) > 0 else { return nil }
        if utf16.last == 0 { utf16.removeLast() }
        let value = String(decoding: utf16, as: UTF16.self)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var fontSize: Float = 0
        guard getFontSize(object, &fontSize) != 0, fontSize > 0 else { return nil }
        let origin = matrix.applying(to: (0, 0))
        let scale = hypot(Double(matrix.a), Double(matrix.b))
        // PDF font size is the em size, while the CAD text renderer's `height`
        // is the visible "Hg" glyph height. On this PDFium build the median
        // visible text bounds are 0.739 em; without this conversion imported
        // text renders roughly 35% too large.
        let height = max(0.01, Double(fontSize) * scale * 0.739)
        let rotation = -atan2(Double(matrix.b), Double(matrix.a))
        return .text(
            position: Vector3(x: origin.0, y: pageHeight - origin.1, z: 0),
            text: value,
            height: height,
            rotation: rotation,
            style: "PDF_TEXT",
            alignH: 0,
            alignV: 0,
            mtextWidth: nil,
            color: objectColor(object, getter: fp_fillColor)
        )
    }

    private static func objectColor(
        _ object: UnsafeMutableRawPointer,
        getter: f_GetColor?
    ) -> ColorRGBA? {
        guard let getter else { return nil }
        var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 255
        guard getter(object, &r, &g, &b, &a) != 0 else { return nil }
        return ColorRGBA(
            r: UInt8(clamping: Int(r)),
            g: UInt8(clamping: Int(g)),
            b: UInt8(clamping: Int(b)),
            a: UInt8(clamping: Int(a))
        )
    }

    /// Render a page to an owned BGRA pixel buffer.
    /// The caller is responsible for deallocating `buffer`.
    static func renderPageBGRA(path: String, pageIndex: Int, dpi: Float)
        -> (buffer: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int)? {

        guard initialized, let loadD = fp_loadDoc,
              let getC = fp_pageCount, let closeD = fp_closeDoc,
              let loadP = fp_loadPage,
              let closeP = fp_closePage, let createB = fp_createBM,
              let destB = fp_destroyBM, let fill = fp_fillBM,
              let render = fp_render, let getBuf = fp_getBuf,
              let getStride = fp_getStride, let getSize = fp_getSize
        else { return nil }

        guard let doc = loadD(path, nil) else { return nil }
        defer { closeD(doc) }

        guard pageIndex >= 0, pageIndex < Int(getC(doc)) else { return nil }

        var wp: Double = 0, hp: Double = 0
        guard getSize(doc, Int32(pageIndex), &wp, &hp) != 0 else { return nil }

        let w = Int((wp * Double(dpi) / 72.0).rounded())
        let h = Int((hp * Double(dpi) / 72.0).rounded())
        guard w > 0, h > 0, w <= 20000, h <= 20000 else { return nil }

        guard let page = loadP(doc, Int32(pageIndex)) else { return nil }
        defer { closeP(page) }

        // FPDFBitmap_BGRA = 4. FPDFBitmap_Gray (1) only allocates one byte
        // per pixel, while the conversion below reads four bytes per pixel.
        guard let bitmap = createB(Int32(w), Int32(h), 4, nil, 0) else { return nil }
        defer { destB(bitmap) }

        fill(bitmap, 0, 0, Int32(w), Int32(h), 0xFFFFFFFF)
        render(bitmap, page, 0, 0, Int32(w), Int32(h), 0, 1) // FPDF_ANNOT

        guard let buf = getBuf(bitmap) else { return nil }
        let stride = Int(getStride(bitmap))
        guard stride >= w * 4 else { return nil }

        // PDFium owns `buf`; copy it before the deferred bitmap destruction.
        let byteCount = stride * h
        let owned = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt32>.alignment
        )
        owned.copyMemory(from: buf, byteCount: byteCount)
        return (owned, w, h, stride)
    }

    /// Render a page and convert to RGBA PNG Data.
    static func renderPageToPNG(path: String, pageIndex: Int, dpi: Float) -> Data? {
        guard let (buf, w, h, stride) = renderPageBGRA(
            path: path, pageIndex: pageIndex, dpi: dpi
        ) else { return nil }
        defer { buf.deallocate() }

        // Copy and swizzle BGRA → RGBA
        let rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        let src = buf.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let srcRow = src + y * stride
            let dstRow = rgba + y * w * 4
            for x in 0..<w {
                let si = x * 4
                let di = x * 4
                dstRow[di + 0] = srcRow[si + 2] // R ← B
                dstRow[di + 1] = srcRow[si + 1] // G ← G
                dstRow[di + 2] = srcRow[si + 0] // B ← R
                dstRow[di + 3] = srcRow[si + 3] // A ← A
            }
        }

        let pngData = PNGEncoder.encode(rgba: rgba, width: w, height: h)
        rgba.deallocate()
        return pngData
    }
}

// =========================================================================
// MARK: - PNGEncoder
//
// Minimal PNG encoder using CZLibNG (zlib-ng) for IDAT deflate compression.
// Produces 8-bit RGBA PNG files from raw pixel data.
// =========================================================================

enum PNGEncoder {

    static func encode(rgba: UnsafePointer<UInt8>, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }

        var data = Data()

        // PNG signature
        data.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10])

        // IHDR chunk
        var ihdr = Data()
        ihdr.append(contentsOf: uint32BE(UInt32(width)))
        ihdr.append(contentsOf: uint32BE(UInt32(height)))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])  // 8-bit, RGBA, deflate, adaptive filter
        writeChunk(type: "IHDR", payload: ihdr, to: &data)

        // IDAT: prepare raw scanlines (filter byte 0 + RGBA row)
        let rawStride = 1 + width * 4  // filter byte + pixel data
        var raw = Data(capacity: rawStride * height)
        for y in 0..<height {
            raw.append(0)  // filter: None
            let rowStart = rgba.advanced(by: y * width * 4)
            raw.append(rowStart, count: width * 4)
        }

        // Deflate using zlib-ng
        guard let compressed = deflate(raw) else { return nil }
        writeChunk(type: "IDAT", payload: compressed, to: &data)

        // IEND chunk
        writeChunk(type: "IEND", payload: Data(), to: &data)

        return data
    }

    // MARK: - Helpers

    private static func uint32BE(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
         UInt8((v >> 8) & 0xFF),  UInt8(v & 0xFF)]
    }

    private static func writeChunk(type: String, payload: Data, to data: inout Data) {
        let len = UInt32(payload.count)
        data.append(contentsOf: uint32BE(len))

        let typeBytes = Data(type.utf8)
        precondition(typeBytes.count == 4)
        data.append(typeBytes)
        data.append(payload)

        // CRC32 over type + payload
        var crcData = typeBytes
        crcData.append(payload)
        let crc = crc32(crcData)
        data.append(contentsOf: uint32BE(crc))
    }

    /// CRC-32 for PNG chunks. Uses zlib-ng's crc32 function.
    private static func crc32(_ data: Data) -> UInt32 {
        return data.withUnsafeBytes { ptr in
            let base = ptr.bindMemory(to: UInt8.self).baseAddress!
            return UInt32(zng_crc32(0, base, UInt32(data.count)))
        }
    }

    /// Deflate using zlib-ng (zlib format, not gzip).
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        var strm = zng_stream()
        let ret = zng_deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                    15, 8, Z_DEFAULT_STRATEGY)
        guard ret == Z_OK else { return nil }
        defer { zng_deflateEnd(&strm) }

        let bound = Int(zng_deflateBound(&strm, numericCast(data.count)))
        var output = [UInt8](repeating: 0, count: max(bound, 256))

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            strm.next_in = ptr.bindMemory(to: UInt8.self).baseAddress
            strm.avail_in = UInt32(data.count)
        }

        var total = 0
        repeat {
            let remain = output.count - total
            output.withUnsafeMutableBufferPointer { bufPtr in
                strm.next_out = bufPtr.baseAddress! + total
                strm.avail_out = UInt32(remain)
            }
            let r = zng_deflate(&strm, Z_FINISH)
            total = output.count - Int(strm.avail_out)
            if strm.avail_out == 0 && r != Z_STREAM_END {
                output.append(contentsOf: repeatElement(0, count: output.count))
            }
        } while strm.avail_out == 0

        return Data(output.prefix(total))
    }
}

import Foundation

// =========================================================================
// MARK: - MCPThumbnail
//
// Deterministic CPU rasterizer for the MCP vision loop. Input is the same
// TessInput list the GPU path consumes; the world-to-pixel mapping always
// preserves aspect (fit-center into the plot rect), so thumbnails are
// pixel-aligned turn to turn while a frustum stays pinned.
//
// Everything here is pure and Sendable: gathering runs on the frame thread,
// tessellation + raster run on the MCP socket thread.
// =========================================================================

/// World-space camera bounds for one thumbnail.
struct MCPFrustum: Sendable, Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var isValid: Bool {
        width > 1e-9 && height > 1e-9
            && width.isFinite && height.isFinite
            && minX.isFinite && minY.isFinite
    }
}

/// Pixel rect of the plot area inside the image (margins hold tick labels).
struct MCPPlotRect: Sendable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
}

enum MCPThumbMath {
    /// Plot rect: left margin for y labels, bottom margin for x labels.
    static func plotRect(imageW: Int, imageH: Int) -> MCPPlotRect {
        MCPPlotRect(x: 64, y: 4, w: max(1, imageW - 68), h: max(1, imageH - 20))
    }

    /// World→pixel scale preserving aspect (fit-center into the plot rect).
    /// Returns scale (px per world unit) and pixel origin of world (minX,minY).
    static func fitScale(
        frustum: MCPFrustum, plot: MCPPlotRect
    ) -> (scale: Double, ox: Double, oy: Double) {
        let sx = Double(plot.w) / frustum.width
        let sy = Double(plot.h) / frustum.height
        let s = min(sx, sy)
        // Center: extra space split on both sides. oy is the pixel row of
        // world minY (rows grow with world Y: Y-down, like the app).
        let usedW = frustum.width * s
        let usedH = frustum.height * s
        let ox = Double(plot.x) + (Double(plot.w) - usedW) / 2.0 - frustum.minX * s
        let oy = Double(plot.y) + (Double(plot.h) - usedH) / 2.0 - frustum.minY * s
        return (s, ox, oy)
    }

    /// Y-down presentation (matches the app window): pixel rows grow with
    /// world Y, so engine text and imports render exactly as on screen.
    static func worldToPixel(
        wx: Double, wy: Double, scale: Double, ox: Double, oy: Double
    ) -> (x: Double, y: Double) {
        (ox + wx * scale, oy + wy * scale)
    }

    /// Expand bounds to match a target aspect (w/h) by growing the smaller
    /// axis about the center. Never distorts.
    static func aspectExpand(
        frustum: MCPFrustum, aspect: Double
    ) -> MCPFrustum {
        guard frustum.isValid, aspect > 0, aspect.isFinite else { return frustum }
        let cx = (frustum.minX + frustum.maxX) / 2.0
        let cy = (frustum.minY + frustum.maxY) / 2.0
        var w = frustum.width
        var h = frustum.height
        if w / h > aspect {
            h = w / aspect
        } else {
            w = h * aspect
        }
        return MCPFrustum(minX: cx - w / 2, minY: cy - h / 2,
                          maxX: cx + w / 2, maxY: cy + h / 2)
    }

    /// Nice grid step targeting ~90 px between minor lines.
    static func niceStep(_ worldPer90px: Double) -> Double {
        guard worldPer90px > 0, worldPer90px.isFinite else { return 1.0 }
        let exp = floor(log10(worldPer90px))
        let base = pow(10.0, exp)
        let frac = worldPer90px / base
        let nice: Double = frac < 1.5 ? 1 : (frac < 3.5 ? 2 : (frac < 7.5 ? 5 : 10))
        return nice * base
    }

    /// Tick label without exponents (keeps the glyph set to 0-9, '-', '.').
    static func tickLabel(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

// MARK: - FNV-1a checksums (batch goldens)

enum MCPChecksum {
    static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 14_695_901_324_736_800_763
        for b in bytes {
            h ^= UInt64(b)
            h &*= 1_096_031_521_372_433_215
        }
        return h
    }

    private static func append<T>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    /// Quantize with clamping: degenerate coordinates must perturb the
    /// hash, never trap the conversion.
    private static func q4(_ v: Double) -> Int32 {
        Int32(clamping: Int(
            max(-2_000_000_000, min(2_000_000_000, (v * 10_000).rounded()))))
    }

    private static func q3(_ v: Double) -> Int32 {
        Int32(clamping: Int(
            max(-2_000_000_000, min(2_000_000_000, (v * 1_000).rounded()))))
    }

    static func vertexHash(_ v: CADVertex) -> UInt64 {
        var bytes = [UInt8]()
        bytes.reserveCapacity(40)
        append(q4(Double(v.x)), to: &bytes)
        append(q4(Double(v.y)), to: &bytes)
        append(UInt8(max(0, min(255, (Double(v.r) * 255).rounded()))), to: &bytes)
        append(UInt8(max(0, min(255, (Double(v.g) * 255).rounded()))), to: &bytes)
        append(UInt8(max(0, min(255, (Double(v.b) * 255).rounded()))), to: &bytes)
        append(UInt8(max(0, min(255, (Double(v.a) * 255).rounded()))), to: &bytes)
        append(q3(Double(v.u)), to: &bytes)
        append(q3(Double(v.v)), to: &bytes)
        append(v.entityIndex, to: &bytes)
        return fnv1a(bytes)
    }

    /// Per-batch checksums plus totals. Mirrors what batch_summary returns.
    static func batches(
        _ result: VertexBuildResult
    ) -> (checksums: [MCPBatchChecksum], vertexCount: Int) {
        var out: [MCPBatchChecksum] = []
        for b in result.batches {
            var h: UInt64 = 14_695_901_324_736_800_763
            let start = Int(b.firstVertex)
            let count = Int(b.vertexCount)
            let end = min(start + count, result.vertices.count)
            if start < end {
                for i in start..<end {
                    h ^= vertexHash(result.vertices[i])
                    h &*= 1_096_031_521_372_433_215
                }
            }
            let pipelineName: String
            switch b.pipelineType {
            case .line: pipelineName = "line"
            case .point: pipelineName = "point"
            case .triangle: pipelineName = "triangle"
            case .aaLine: pipelineName = "aaLine"
            }
            out.append(MCPBatchChecksum(
                pipeline: pipelineName, firstVertex: b.firstVertex,
                vertexCount: b.vertexCount, lineWeight: b.lineWeight, fnv: h))
        }
        return (out, result.vertexCount)
    }
}

struct MCPBatchChecksum: Sendable {
    var pipeline: String
    var firstVertex: UInt32
    var vertexCount: UInt32
    var lineWeight: Double
    var fnv: UInt64
}

// MARK: - Rasterizer

/// 3x5 filled bitmap glyphs (scale 2x on screen). No font dependency.
private let glyphCells: [Character: [String]] = [
    "0": ["111", "101", "101", "101", "111"],
    "1": ["010", "110", "010", "010", "111"],
    "2": ["111", "001", "111", "100", "111"],
    "3": ["111", "001", "111", "001", "111"],
    "4": ["101", "101", "111", "001", "001"],
    "5": ["111", "100", "111", "001", "111"],
    "6": ["111", "100", "111", "101", "111"],
    "7": ["111", "001", "010", "010", "010"],
    "8": ["111", "101", "111", "101", "111"],
    "9": ["111", "101", "111", "001", "111"],
    "-": ["000", "000", "111", "000", "000"],
    ".": ["000", "000", "000", "000", "010"],
]

final class MCPRaster: @unchecked Sendable {
    let width: Int
    let height: Int
    private var px: [UInt8]

    init(width: Int, height: Int, bg: (UInt8, UInt8, UInt8, UInt8)) {
        self.width = width
        self.height = height
        px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            px[i * 4] = bg.0
            px[i * 4 + 1] = bg.1
            px[i * 4 + 2] = bg.2
            px[i * 4 + 3] = bg.3
        }
    }

    var bytes: [UInt8] { px }

    private func blend(
        x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 4
        if a == 255 {
            px[i] = r
            px[i + 1] = g
            px[i + 2] = b
            px[i + 3] = 255
            return
        }
        if a == 0 { return }
        let af = Double(a) / 255.0
        px[i] = UInt8((Double(r) * af + Double(px[i]) * (1 - af)).rounded())
        px[i + 1] = UInt8((Double(g) * af + Double(px[i + 1]) * (1 - af)).rounded())
        px[i + 2] = UInt8((Double(b) * af + Double(px[i + 2]) * (1 - af)).rounded())
        px[i + 3] = 255
    }

    private func blendF(
        x: Double, y: Double, r: Float, g: Float, b: Float, a: Float
    ) {
        blend(x: Int(x.rounded()), y: Int(y.rounded()),
              r: UInt8(max(0, min(255, Double(r) * 255).rounded())),
              g: UInt8(max(0, min(255, Double(g) * 255).rounded())),
              b: UInt8(max(0, min(255, Double(b) * 255).rounded())),
              a: UInt8(max(0, min(255, Double(a) * 255).rounded())))
    }

    func drawLine(
        x0: Double, y0: Double, x1: Double, y1: Double,
        r: Float, g: Float, b: Float, a: Float
    ) {
        var ix0 = Int(x0.rounded()), iy0 = Int(y0.rounded())
        let ix1 = Int(x1.rounded()), iy1 = Int(y1.rounded())
        let dx = abs(ix1 - ix0), dy = -abs(iy1 - iy0)
        let sx = ix0 < ix1 ? 1 : -1, sy = iy0 < iy1 ? 1 : -1
        var err = dx + dy
        while true {
            blendF(x: Double(ix0), y: Double(iy0), r: r, g: g, b: b, a: a)
            if ix0 == ix1 && iy0 == iy1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; ix0 += sx }
            if e2 <= dx { err += dx; iy0 += sy }
        }
    }

    func drawPoint(
        x: Double, y: Double, r: Float, g: Float, b: Float, a: Float
    ) {
        let ix = Int(x.rounded()), iy = Int(y.rounded())
        for oy in -1...1 {
            for ox in -1...1 {
                blendF(x: Double(ix + ox), y: Double(iy + oy), r: r, g: g, b: b, a: a)
            }
        }
    }

    func fillTriangle(
        _ p0: (Double, Double, CADVertex),
        _ p1: (Double, Double, CADVertex),
        _ p2: (Double, Double, CADVertex)
    ) {
        let minX = Int(floor(min(p0.0, min(p1.0, p2.0))))
        let maxX = Int(ceil(max(p0.0, max(p1.0, p2.0))))
        let minY = Int(floor(min(p0.1, min(p1.1, p2.1))))
        let maxY = Int(ceil(max(p0.1, max(p1.1, p2.1))))
        let denom = (p1.1 - p2.1) * (p0.0 - p2.0) + (p2.0 - p1.0) * (p0.1 - p2.1)
        guard denom != 0 else { return }
        // Clamp first: an offscreen triangle must no-op, never trap on an
        // inverted range.
        let y0 = max(0, minY), y1 = min(height - 1, maxY)
        let x0 = max(0, minX), x1 = min(width - 1, maxX)
        guard y0 <= y1, x0 <= x1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let w0 = ((p1.1 - p2.1) * (px - p2.0) + (p2.0 - p1.0) * (py - p2.1)) / denom
                let w1 = ((p2.1 - p0.1) * (px - p2.0) + (p0.0 - p2.0) * (py - p2.1)) / denom
                let w2 = 1 - w0 - w1
                guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                let v0 = p0.2, v1 = p1.2, v2 = p2.2
                blendF(x: Double(x), y: Double(y),
                       r: Float(w0) * v0.r + Float(w1) * v1.r + Float(w2) * v2.r,
                       g: Float(w0) * v0.g + Float(w1) * v1.g + Float(w2) * v2.g,
                       b: Float(w0) * v0.b + Float(w1) * v1.b + Float(w2) * v2.b,
                       a: Float(w0) * v0.a + Float(w1) * v1.a + Float(w2) * v2.a)
            }
        }
    }

    func drawText(
        _ text: String, x: Int, y: Int,
        color: (UInt8, UInt8, UInt8, UInt8)
    ) {
        let s = 2
        var cx = x
        for ch in text {
            guard let cells = glyphCells[ch] else {
                cx += 4 * s
                continue
            }
            for (row, line) in cells.enumerated() {
                for (col, c) in line.enumerated() where c == "1" {
                    for oy in 0..<s {
                        for ox in 0..<s {
                            blend(x: cx + col * s + ox, y: y + row * s + oy,
                                  r: color.0, g: color.1, b: color.2, a: color.3)
                        }
                    }
                }
            }
            cx += 4 * s
        }
    }

    /// World grid + border ticks. All labels use the bitmap glyphs.
    func drawGrid(
        frustum: MCPFrustum, plot: MCPPlotRect,
        scale: Double, ox: Double, oy: Double,
        label: (UInt8, UInt8, UInt8, UInt8),
        minor: (UInt8, UInt8, UInt8, UInt8),
        major: (UInt8, UInt8, UInt8, UInt8)
    ) {
        let step = MCPThumbMath.niceStep(Double(plot.w) / scale / 9.0)
        // Frame.
        for x in plot.x..<(plot.x + plot.w) {
            blend(x: x, y: plot.y, r: label.0, g: label.1, b: label.2, a: label.3)
            blend(x: x, y: plot.y + plot.h - 1, r: label.0, g: label.1, b: label.2, a: label.3)
        }
        for y in plot.y..<(plot.y + plot.h) {
            blend(x: plot.x, y: y, r: label.0, g: label.1, b: label.2, a: label.3)
            blend(x: plot.x + plot.w - 1, y: y, r: label.0, g: label.1, b: label.2, a: label.3)
        }
        var k = Int(floor(frustum.minX / step))
        while Double(k) * step <= frustum.maxX {
            let wx = Double(k) * step
            let (px, _) = MCPThumbMath.worldToPixel(
                wx: wx, wy: frustum.minY, scale: scale, ox: ox, oy: oy)
            let isMajor = k % 5 == 0
            let col = isMajor ? major : minor
            drawLine(x0: px, y0: Double(plot.y), x1: px,
                     y1: Double(plot.y + plot.h - 1),
                     r: Float(col.0) / 255, g: Float(col.1) / 255,
                     b: Float(col.2) / 255, a: Float(col.3) / 255)
            if isMajor {
                drawText(MCPThumbMath.tickLabel(wx), x: Int(px.rounded()) - 8,
                         y: plot.y + plot.h + 3, color: label)
            }
            k += 1
        }
        var j = Int(floor(frustum.minY / step))
        while Double(j) * step <= frustum.maxY {
            let wy = Double(j) * step
            let (_, py) = MCPThumbMath.worldToPixel(
                wx: frustum.minX, wy: wy, scale: scale, ox: ox, oy: oy)
            let isMajor = j % 5 == 0
            let col = isMajor ? major : minor
            drawLine(x0: Double(plot.x), y0: py,
                     x1: Double(plot.x + plot.w - 1), y1: py,
                     r: Float(col.0) / 255, g: Float(col.1) / 255,
                     b: Float(col.2) / 255, a: Float(col.3) / 255)
            if isMajor {
                let label_ = MCPThumbMath.tickLabel(wy)
                drawText(label_, x: plot.x - 8 - label_.count * 8,
                         y: Int(py.rounded()) - 5, color: label)
            }
            j += 1
        }
    }

    /// Composite an RGBA reference image mapped by world rect at opacity.
    func compositeOverlay(
        image: MCPPngImage,
        worldMinX: Double, worldMinY: Double,
        worldMaxX: Double, worldMaxY: Double,
        scale: Double, ox: Double, oy: Double, opacity: Double
    ) {
        guard opacity > 0, image.width > 0, image.height > 0 else { return }
        let wSpan = worldMaxX - worldMinX
        let hSpan = worldMaxY - worldMinY
        guard wSpan > 0, hSpan > 0 else { return }
        for y in 0..<height {
            for x in 0..<width {
                // Invert the world→pixel map to find the source texel.
                let wx = (Double(x) - ox) / scale
                let wy = (Double(y) - oy) / scale
                let u = (wx - worldMinX) / wSpan
                let v = (wy - worldMinY) / hSpan
                guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
                let sx = min(image.width - 1, Int(u * Double(image.width)))
                // PNG rows are top-down; under Y-down presentation the
                // image top sits at world minY, matching the app window.
                let sy = min(image.height - 1,
                             Int(v * Double(image.height)))
                let s = (sy * image.width + sx) * 4
                let a = Double(image.rgba[s + 3]) / 255.0 * opacity
                guard a > 0 else { continue }
                blend(x: x, y: y, r: image.rgba[s], g: image.rgba[s + 1],
                      b: image.rgba[s + 2], a: UInt8((a * 255).rounded()))
            }
        }
    }
}

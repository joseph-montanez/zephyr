import Foundation
import CZLibNG

// =========================================================================
// MARK: - MCPPng
//
// Minimal PNG decoder for reference-floor-plan overlays. Accepts 8-bit
// RGB/RGBA non-interlaced PNGs (what exporters and screenshots produce).
// Inflate reuses CZLibNG exactly like PlotStyleTable.inflateZlib; the
// encoder direction already exists as PNGEncoder (PDFiumBridge).
// =========================================================================

enum MCPPngError: Error, Sendable {
    case truncated
    case badSignature
    case unsupported(String)
    case inflateFailed
    case tooLarge(Int)
}

/// Decoded 8-bit RGBA image in top-down row order.
struct MCPPngImage: Sendable {
    var width: Int
    var height: Int
    /// width*height*4 bytes, top row first.
    var rgba: [UInt8]
}

enum MCPPngDecoder {
    /// Hard cap so a hostile file cannot exhaust memory (~64 MP).
    static let maxPixels = 64_000_000

    static func decode(_ data: Data) throws -> MCPPngImage {
        let bytes = [UInt8](data)
        let pngSig: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= 8 else { throw MCPPngError.truncated }
        guard Array(bytes.prefix(8)) == pngSig else { throw MCPPngError.badSignature }

        var pos = 8
        var width = 0
        var height = 0
        var colorType = -1
        var seenIHDR = false
        var idat = Data()

        func u32BE(_ at: Int) throws -> Int {
            guard at + 4 <= bytes.count else { throw MCPPngError.truncated }
            return (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }

        while true {
            guard pos + 8 <= bytes.count else { throw MCPPngError.truncated }
            let length = try u32BE(pos)
            let type = String(bytes: Array(bytes[(pos + 4)..<(pos + 8)]), encoding: .ascii) ?? ""
            let payloadStart = pos + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd + 4 <= bytes.count else { throw MCPPngError.truncated }
            let payload = Array(bytes[payloadStart..<payloadEnd])
            switch type {
            case "IHDR":
                guard payload.count == 13 else { throw MCPPngError.truncated }
                width = (Int(payload[0]) << 24) | (Int(payload[1]) << 16)
                    | (Int(payload[2]) << 8) | Int(payload[3])
                height = (Int(payload[4]) << 24) | (Int(payload[5]) << 16)
                    | (Int(payload[6]) << 8) | Int(payload[7])
                let bitDepth = payload[8]
                colorType = Int(payload[9])
                guard bitDepth == 8 else {
                    throw MCPPngError.unsupported("bit depth \(bitDepth)")
                }
                guard colorType == 2 || colorType == 6 else {
                    throw MCPPngError.unsupported("color type \(colorType)")
                }
                guard payload[10] == 0, payload[11] == 0 else {
                    throw MCPPngError.unsupported("compression/filter method")
                }
                guard payload[12] == 0 else {
                    throw MCPPngError.unsupported("interlaced PNG")
                }
                guard width > 0, height > 0, width * height <= maxPixels else {
                    throw MCPPngError.tooLarge(width * height)
                }
                seenIHDR = true
            case "IDAT":
                idat.append(contentsOf: payload)
            case "IEND":
                pos = bytes.count
                break
            default:
                break // ancillary chunks ignored
            }
            if type == "IEND" { break }
            pos = payloadEnd + 4
        }
        guard seenIHDR else { throw MCPPngError.truncated }

        let channels = colorType == 6 ? 4 : 3
        let stride = 1 + width * channels
        let raw = try inflateZlib(Data(idat))
        guard raw.count == stride * height else { throw MCPPngError.truncated }
        let rawBytes = [UInt8](raw)

        // Unfilter (Paeth included) into packed rows.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var prev = [UInt8](repeating: 0, count: width * channels)
        var cur = [UInt8](repeating: 0, count: width * channels)
        for y in 0..<height {
            let rowBase = y * stride
            let filter = rawBytes[rowBase]
            for i in 0..<(width * channels) {
                let raw = Int(rawBytes[rowBase + 1 + i])
                let a = i >= channels ? Int(cur[i - channels]) : 0
                let b = Int(prev[i])
                let c = i >= channels ? Int(prev[i - channels]) : 0
                let recon: Int
                switch filter {
                case 0: recon = raw
                case 1: recon = raw + a
                case 2: recon = raw + b
                case 3: recon = raw + (a + b) / 2
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    let pr = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                    recon = raw + pr
                default: throw MCPPngError.unsupported("filter \(filter)")
                }
                cur[i] = UInt8(truncatingIfNeeded: recon)
            }
            for x in 0..<width {
                let s = x * channels
                let d = (y * width + x) * 4
                rgba[d] = cur[s]
                rgba[d + 1] = cur[s + 1]
                rgba[d + 2] = cur[s + 2]
                rgba[d + 3] = channels == 4 ? cur[s + 3] : 255
            }
            swap(&prev, &cur)
        }
        return MCPPngImage(width: width, height: height, rgba: rgba)
    }

    // MARK: - zlib inflate (mirrors PlotStyleTable.inflateZlib)

    private static func inflateZlib(_ input: Data) throws -> Data {
        guard !input.isEmpty else { throw MCPPngError.truncated }
        var strm = zng_stream()
        var ret = zng_inflateInit(&strm)
        guard ret == Z_OK else { throw MCPPngError.inflateFailed }
        defer { zng_inflateEnd(&strm) }

        var output = [UInt8](repeating: 0, count: max(input.count * 4, 4096))
        var totalOut = 0
        var finished = false
        try input.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else {
                throw MCPPngError.truncated
            }
            strm.next_in = UnsafePointer(base)
            strm.avail_in = UInt32(input.count)
            repeat {
                let outOffset = totalOut
                let outRemaining = output.count - outOffset
                var outLeft = UInt32(outRemaining)
                let ok: Bool = output.withUnsafeMutableBufferPointer { bufPtr in
                    guard let b = bufPtr.baseAddress else { return false }
                    strm.next_out = b + outOffset
                    strm.avail_out = UInt32(outRemaining)
                    ret = zng_inflate(&strm, Z_FINISH)
                    outLeft = strm.avail_out
                    return true
                }
                guard ok else { throw MCPPngError.inflateFailed }
                totalOut = output.count - Int(outLeft)
                if ret == Z_STREAM_END {
                    finished = true
                } else if outLeft == 0 {
                    output.append(contentsOf: repeatElement(0, count: output.count))
                } else if strm.avail_in == 0 {
                    finished = true
                } else {
                    throw MCPPngError.inflateFailed
                }
            } while !finished
        }
        guard finished, totalOut > 0 else { throw MCPPngError.inflateFailed }
        return Data(output.prefix(totalOut))
    }
}

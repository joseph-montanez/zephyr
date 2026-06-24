import Foundation
import CZLibNG

// =========================================================================
// MARK: - PDFWriter
//
// Low-level PDF 1.7 document writer with byte-offset tracking for xref tables.
// Supports FlateDecode (zlib-ng) compressed content streams for compact,
// production-quality CAD drawing exports.

// =========================================================================
// MARK: - PDF Writer (byte-offset tracking)
// =========================================================================

/// Builds a PDF file in memory with strict byte-offset tracking for the xref table.
/// All writes go through `Data` (UTF-8 encoded) so byte positions are accurate.
final class PDFByteWriter {
    private(set) var data = Data()
    private(set) var objectOffsets: [Int: Int] = [:]
    private var currentObj: Int?

    func beginObject(_ num: Int) {
        objectOffsets[num] = data.count
        currentObj = num
        write("\(num) 0 obj\n")
    }

    func endObject() {
        write("endobj\n")
        currentObj = nil
    }

    /// Write an uncompressed stream object (legacy; prefer compressed).
    func writeStream(_ streamData: Data) {
        write("<< /Length \(streamData.count) >>\nstream\n")
        data.append(streamData)
        write("\nendstream\n")
    }

    /// Write a FlateDecode (zlib) compressed stream — PDF 1.7 production quality.
    /// Reduces content stream size by 50-80% for typical CAD drawings.
    func writeCompressedStream(_ streamData: Data) {
        let compressed = Self.compressDeflate(streamData)
        write("<< /Length \(compressed.count) /Filter /FlateDecode >>\nstream\n")
        data.append(compressed)
        write("\nendstream\n")
    }

    func write(_ s: String) {
        data.append(Data(s.utf8))
    }

    /// Finalize: write xref table and trailer, return complete PDF Data.
    func finalize(rootObj: Int) -> Data {
        let xrefOffset = data.count
        write("xref\n")
        let maxObj = (objectOffsets.keys.max() ?? 0) + 1
        write("0 \(maxObj)\n")
        write("0000000000 65535 f \n")
        for i in 1..<maxObj {
            if let offset = objectOffsets[i] {
                write(String(format: "%010d 00000 n \n", offset))
            } else {
                write("0000000000 65535 f \n")
            }
        }
        write("trailer\n")
        write("<< /Size \(maxObj) /Root \(rootObj) 0 R >>\n")
        write("startxref\n")
        write("\(xrefOffset)\n")
        write("%%EOF\n")
        return data
    }

    // -----------------------------------------------------------------
    // MARK: zlib FlateDecode compression (PDF 1.7)
    // -----------------------------------------------------------------

    /// Compress data using zlib deflate (RFC 1950) via zlib-ng.
    /// PDF FlateDecode expects standard zlib with the 2-byte zlib header
    /// and 4-byte Adler-32 trailer, so we use `deflateInit2` with positive `MAX_WBITS`.
    /// Returns the compressed data ready for wrapping in a PDF stream object.
    private static func compressDeflate(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }

        // zng_stream setup for zlib (positive windowBits = standard zlib header/trailer)
        var strm = zng_stream()
        let windowBits: Int32 = 15  // standard zlib for PDF FlateDecode filter
        let memLevel: Int32 = 8      // default memory usage level

        var ret = zng_deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                   windowBits, memLevel, 0) // default strategy
        guard ret == Z_OK else { return input }
        defer { zng_deflateEnd(&strm) }

        // Allocate output buffer: zng_deflateBound gives worst-case compressed size
        let srcLen = input.count
#if os(Windows)
        let bound = Int(zng_deflateBound(&strm, UInt32(srcLen)))
#else
        let bound = Int(zng_deflateBound(&strm, UInt(srcLen)))
#endif
        var output = [UInt8](repeating: 0, count: max(bound, 256))

        // Set input data
        input.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            strm.next_in = UnsafePointer(ptr.bindMemory(to: UInt8.self).baseAddress!)
            strm.avail_in = UInt32(srcLen)
        }

        // Deflate loop: compress in one pass with Z_FINISH
        var totalCompressed = 0
        repeat {
            let outOffset = totalCompressed
            let outRemaining = output.count - outOffset

            output.withUnsafeMutableBufferPointer { bufPtr in
                strm.next_out = bufPtr.baseAddress! + outOffset
                strm.avail_out = UInt32(outRemaining)
            }

            ret = zng_deflate(&strm, Z_FINISH)
            totalCompressed = output.count - Int(strm.avail_out)

            // If output buffer is full but not done, grow and continue
            if strm.avail_out == 0 && ret != Z_STREAM_END {
                output.append(contentsOf: repeatElement(0, count: output.count))
            }
        } while ret == Z_OK && strm.avail_out == 0

        guard ret == Z_STREAM_END else { return input }  // fallback to uncompressed
        return Data(output.prefix(totalCompressed))
    }
}

// =========================================================================
// MARK: - PDF Content Builder (locale-safe)
// =========================================================================

/// Accumulates PDF content stream operators with `en_US_POSIX` float formatting.
/// European locales use commas for decimals, which PDF parsers treat as delimiters,
/// silently corrupting the content stream.
final class PDFContentBuilder {
    private var data = Data()

    private static let fmt: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 4
        return f
    }()

    func num(_ d: Double) {
        let s = Self.fmt.string(from: NSNumber(value: d)) ?? String(d)
        data.append(Data(s.utf8))
        data.append(32)
    }

    func op(_ s: String) {
        data.append(Data(s.utf8))
        data.append(10)
    }

    func raw(_ s: String) {
        data.append(Data(s.utf8))
    }

    var count: Int { data.count }
    func build() -> Data { data }
}

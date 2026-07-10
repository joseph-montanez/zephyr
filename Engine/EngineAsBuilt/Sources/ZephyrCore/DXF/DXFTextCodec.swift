import Foundation

#if os(Windows)
import WinSDK
#endif

/// DXF text codec using Foundation String.Encoding for all code page conversions.
///
/// Handles \\U+XXXX escape sequences per the DXF spec and provides CP1252
/// fallback encoding/decoding for code pages not natively supported by Foundation.
///
/// Mirrors libdxfrw DRW_TextCodec (drw_textcodec.h/cpp).
public class DXFTextCodec {

    public var version: DXFVersion = .r2007
    public var codePage: String = "ANSI_1252"

    public init() {
        setCodePage("ANSI_1252")
    }

    /// Set code page from DXF $DWGCODEPAGE value
    public func setCodePage(_ cp: String) {
        codePage = normalizeCodePage(cp)
    }

    /// Set DXF version
    public func setVersion(_ v: DXFVersion) {
        version = v
    }

    /// Normalize DXF code page name to canonical form
    public func normalizeCodePage(_ cp: String) -> String {
        let s = cp.uppercased().trimmingCharacters(in: .whitespaces)

        if s == "ANSI_874" || s == "CP874" || s == "ISO8859-11" || s == "TIS-620" { return "ANSI_874" }
        if s == "ANSI_1250" || s == "CP1250" || s == "ISO8859-2" { return "ANSI_1250" }
        if s == "ANSI_1251" || s == "CP1251" || s == "ISO8859-5" || s == "KOI8-R" || s == "KOI8-U" || s == "IBM 866" { return "ANSI_1251" }
        if s == "ANSI_1252" || s == "CP1252" || s == "LATIN1" || s == "ISO-8859-1" || s == "ISO8859-1" || s == "ISO8859-15" || s == "APPLE ROMAN" || s == "IBM 850" { return "ANSI_1252" }
        if s == "ANSI_1253" || s == "CP1253" || s == "ISO8859-7" { return "ANSI_1253" }
        if s == "ANSI_1254" || s == "CP1254" || s == "ISO8859-9" || s == "ISO8859-3" { return "ANSI_1254" }
        if s == "ANSI_1255" || s == "CP1255" || s == "ISO8859-8" { return "ANSI_1255" }
        if s == "ANSI_1256" || s == "CP1256" || s == "ISO8859-6" { return "ANSI_1256" }
        if s == "ANSI_1257" || s == "CP1257" || s == "ISO8859-4" || s == "ISO8859-10" || s == "ISO8859-13" { return "ANSI_1257" }
        if s == "ANSI_1258" || s == "CP1258" { return "ANSI_1258" }
        if s == "ANSI_932" || s == "SHIFT-JIS" || s == "SHIFT_JIS" || s == "CSSHIFTJIS" || s == "MS_KANJI" || s == "EUCJP" || s == "EUC-JP" || s == "JIS7" { return "ANSI_932" }
        if s == "ANSI_936" || s == "GBK" || s == "GB2312" || s == "GB18030" { return "ANSI_936" }
        if s == "ANSI_949" || s == "EUCKR" || s == "EUC-KR" { return "ANSI_949" }
        if s == "ANSI_950" || s == "BIG5" || s == "BIG5-HKSCS" { return "ANSI_950" }
        if s == "UTF-8" || s == "UTF8" { return "UTF-8" }
        if s == "UTF-16" || s == "UTF16" { return "UTF-16" }
        return "ANSI_1252"
    }

    // MARK: - Public API

    /// Convert string from DXF code page to UTF-8.
    /// Decodes \U+XXXX escape sequences embedded in the encoded text.
    public func toUtf8(_ s: String) -> String {
        if codePage == "UTF-8"  { return decodeUnicodeEscapes(s) }
        if codePage == "UTF-16" { return decodeUnicodeEscapes(s) }
        let decoded = foundationDecode(s)
        return decodeUnicodeEscapes(decoded)
    }

    /// Convert string from UTF-8 to DXF code page.
    /// Characters not representable in target encoding become \U+XXXX.
    public func fromUtf8(_ s: String) -> String {
        if codePage == "UTF-8"  { return s }
        if codePage == "UTF-16" { return s }
        let encoded = foundationEncode(s)
        // If result is empty (conversion failed), escape non-representable chars
        if encoded.isEmpty && !s.isEmpty {
            return escapeNonRepresentable(s)
        }
        return encoded
    }

    // MARK: - Foundation Conversion

    /// Decode string from DXF code page using Foundation String.Encoding.
    /// On Windows, uses MultiByteToWideChar for code pages not natively in Foundation.
    /// Falls back to CP1252 table if all conversions fail.
    private func foundationDecode(_ s: String) -> String {
#if os(Windows)
        if let winDecoded = windowsDecode(s, codePage: codePage) {
            return winDecoded
        }
#endif
        let enc = foundationEncodingFor(codePage)
        if let data = s.data(using: enc, allowLossyConversion: true),
           let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        // Fallback to CP1252 table
        return decode1252Table(s)
    }

    /// Encode string to DXF code page using Foundation String.Encoding.
    /// On Windows, uses WideCharToMultiByte for code pages not natively in Foundation.
    /// Falls back to CP1252 table if all conversions fail.
    private func foundationEncode(_ s: String) -> String {
#if os(Windows)
        if let winEncoded = windowsEncode(s, codePage: codePage) {
            return winEncoded
        }
#endif
        let enc = foundationEncodingFor(codePage)
        if let data = s.data(using: .utf8),
           let encoded = String(data: data, encoding: enc) {
            return encoded
        }
        return encode1252Table(s)
    }

    /// Map canonical DXF code page to Foundation String.Encoding.
    /// Uses CFString bridging for code pages that may not have named constants
    /// on all platforms (Linux, older macOS, etc.). Falls back to CP1252 table
    /// for encodings not natively supported by Foundation.
    private func foundationEncodingFor(_ cp: String) -> String.Encoding {
        switch cp {
        case "ANSI_874":  return .windowsCP1252      // Thai — map via CP1252 table
        case "ANSI_1250": return .windowsCP1250
        case "ANSI_1251": return .windowsCP1251
        case "ANSI_1252": return .windowsCP1252       // Western Europe (default)
        case "ANSI_1253": return .windowsCP1253
        case "ANSI_1254": return .windowsCP1254
#if canImport(Darwin)
        case "ANSI_1255":                          // Hebrew
            let nsEnc1255 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue))
            return String.Encoding(rawValue: UInt(nsEnc1255))
        case "ANSI_1256":                          // Arabic
            let nsEnc1256 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue))
            return String.Encoding(rawValue: UInt(nsEnc1256))
        case "ANSI_1257":                          // Baltic
            let nsEnc1257 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsBalticRim.rawValue))
            return String.Encoding(rawValue: UInt(nsEnc1257))
        case "ANSI_1258":                          // Vietnamese
            let nsEnc1258 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsVietnamese.rawValue))
            return String.Encoding(rawValue: UInt(nsEnc1258))
#else
        case "ANSI_1255": return .windowsCP1252   // Hebrew — see windowsDecode/Encode
        case "ANSI_1256": return .windowsCP1252   // Arabic — see windowsDecode/Encode
        case "ANSI_1257": return .windowsCP1252   // Baltic — see windowsDecode/Encode
        case "ANSI_1258": return .windowsCP1252   // Vietnamese — see windowsDecode/Encode
#endif
        case "ANSI_932":  return .shiftJIS
#if canImport(Darwin)
        case "ANSI_936":                          // Chinese GB
            let nsEnc936 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: UInt(nsEnc936))
#else
        case "ANSI_936":  return .windowsCP1252   // Chinese GB — see windowsDecode/Encode
#endif
        case "ANSI_949":  return .windowsCP1252      // Korean — see windowsDecode/Encode
        case "ANSI_950":  return .windowsCP1252      // Chinese — see windowsDecode/Encode
        default:          return .windowsCP1252
        }
    }

    // MARK: - Windows Code Page Conversion

#if os(Windows)
    /// Map canonical DXF code page to Win32 code page identifier.
    private func windowsCodePageID(_ cp: String) -> UINT? {
        switch cp {
        case "ANSI_874":  return 874   // Thai
        case "ANSI_1255": return 1255  // Hebrew
        case "ANSI_1256": return 1256  // Arabic
        case "ANSI_1257": return 1257  // Baltic
        case "ANSI_1258": return 1258  // Vietnamese
        case "ANSI_936":  return 936   // GBK / GB2312
        case "ANSI_949":  return 949   // Korean (EUC-KR)
        case "ANSI_950":  return 950   // Traditional Chinese (BIG5)
        default:          return nil
        }
    }

    /// Decode a string from the Windows code page to UTF-8 using MultiByteToWideChar.
    /// Returns nil if this code page isn't handled by Windows, so the caller can fall back.
    private func windowsDecode(_ s: String, codePage cp: String) -> String? {
        guard let codePageID = windowsCodePageID(cp) else { return nil }

        // Extract raw bytes from the string (each unicode scalar's low byte = one code-page byte).
        // This assumes the DXF file was read as Latin-1 so bytes survive intact.
        var chars = [CHAR]()
        chars.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            chars.append(CHAR(bitPattern: UInt8(scalar.value & 0xFF)))
        }

        return chars.withUnsafeBufferPointer { charPtr -> String? in
            guard let base = charPtr.baseAddress else { return nil }
            let wideLen = MultiByteToWideChar(
                codePageID, 0,
                base, Int32(charPtr.count),
                nil, 0
            )
            guard wideLen > 0 else { return nil }
            var wideBuf = [WCHAR](repeating: 0, count: Int(wideLen))
            MultiByteToWideChar(
                codePageID, 0,
                base, Int32(charPtr.count),
                &wideBuf, wideLen
            )
            return wideBuf.withUnsafeBufferPointer { wPtr -> String in
                String(utf16CodeUnits: wPtr.baseAddress!, count: Int(wideLen))
            }
        }
    }

    /// Encode a string from UTF-8 to the Windows code page using WideCharToMultiByte.
    /// Returns nil if this code page isn't handled by Windows, so the caller can fall back.
    private func windowsEncode(_ s: String, codePage cp: String) -> String? {
        guard let codePageID = windowsCodePageID(cp) else { return nil }

        let utf16 = s.utf16
        return ContiguousArray(utf16).withUnsafeBufferPointer { widePtr -> String? in
            guard let base = widePtr.baseAddress else { return nil }

            // First call to get required buffer size
            let byteLen = WideCharToMultiByte(
                codePageID, 0,
                base, Int32(widePtr.count),
                nil, 0,
                nil, nil
            )
            guard byteLen > 0 else { return nil }

            var byteBuf = [CHAR](repeating: 0, count: Int(byteLen))
            WideCharToMultiByte(
                codePageID, 0,
                base, Int32(widePtr.count),
                &byteBuf, byteLen,
                nil, nil
            )

            // Convert [CHAR] → [UInt8] → Latin-1 String (each byte maps to Unicode 0x00-0xFF)
            let unsigned = byteBuf.map { UInt8(bitPattern: $0) }
            return String(bytes: unsigned, encoding: .isoLatin1)
        }
    }
#endif

    // MARK: - \U+XXXX Escape Handling

    private func decodeUnicodeEscapes(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s[i...].hasPrefix("\\U+") {
                var hex = ""
                var j = s.index(i, offsetBy: 3)
                while j < s.endIndex, hex.count < 4, s[j].isHexDigit {
                    hex.append(s[j]); j = s.index(after: j)
                }
                if let code = Int(hex, radix: 16), let scalar = UnicodeScalar(code) {
                    result.append(Character(scalar)); i = j
                } else { result.append(s[i]); i = s.index(after: i) }
            } else { result.append(s[i]); i = s.index(after: i) }
        }
        return result
    }

    private func escapeNonRepresentable(_ s: String) -> String {
        let enc = foundationEncodingFor(codePage)
        var result = ""
        for ch in s {
            if String(ch).data(using: enc, allowLossyConversion: true) != nil {
                result.append(ch)
            } else {
                result += String(format: "\\U+%04X", ch.unicodeScalars.first!.value)
            }
        }
        return result
    }

    // MARK: - CP1252 Fallback Table

    /// CP1252-specific chars (0x80-0x9F) → Unicode
    private static let cp1252ToUnicode: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private func decode1252Table(_ s: String) -> String {
        var result = ""
        for byte in s.utf8 {
            if byte < 0x80 || byte >= 0xA0 {
                result.append(Character(UnicodeScalar(UInt32(byte))!))
            } else {
                let unicode = Self.cp1252ToUnicode[Int(byte) - 0x80]
                result.append(Character(UnicodeScalar(unicode)!))
            }
        }
        return decodeUnicodeEscapes(result)
    }

    private func encode1252Table(_ s: String) -> String {
        var result = ""
        for ch in s {
            let val = ch.unicodeScalars.first!.value
            if val < 0x80 || (val >= 0xA0 && val <= 0xFF && !isCP1252Special(val)) {
                result.append(Character(UnicodeScalar(val & 0xFF)!))
            } else if let idx = Self.cp1252ToUnicode.firstIndex(of: UInt16(val)) {
                result.append(Character(UnicodeScalar(UInt32(0x80 + idx))!))
            } else {
                result += String(format: "\\U+%04X", val)
            }
        }
        return result
    }

    private func isCP1252Special(_ val: UInt32) -> Bool {
        Self.cp1252ToUnicode.contains(UInt16(val))
    }
}

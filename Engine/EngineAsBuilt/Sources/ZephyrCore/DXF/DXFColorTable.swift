import Foundation

// =========================================================================
// MARK: - DXFColorTable
//
// AutoCAD Color Index (ACI) to RGBA conversion table. Maps DXF color
// indices 1–255 to their standard RGBA values. Uses a high-performance
// switch statement (canonical version). Also provides helpers for
// DXF transparency → opacity and DXF line weight → mm conversion.
//
// Used by DXF import/export, DWG import, command processing, and PDF export.
// =========================================================================

public enum DXFColorTable {

    /// Convert AutoCAD Color Index (ACI) to RGBA.
    ///
    /// If `color24` is non-negative, it is preferred over the ACI index
    /// (true color overrides indexed color per DXF spec).
    /// ACI 7 is rendered as white for dark CAD backgrounds.
    public static func aciToRGBA(_ aci: Int32, color24: Int32) -> ColorRGBA {
        if color24 >= 0 {
            let r = UInt8((color24 >> 16) & 0xFF)
            let g = UInt8((color24 >> 8) & 0xFF)
            let b = UInt8(color24 & 0xFF)
            return ColorRGBA(r: r, g: g, b: b)
        }

        switch abs(Int(aci)) {
        case 1: return ColorRGBA(r: 255, g: 0, b: 0)
        case 2: return ColorRGBA(r: 255, g: 255, b: 0)
        case 3: return ColorRGBA(r: 0, g: 255, b: 0)
        case 4: return ColorRGBA(r: 0, g: 255, b: 255)
        case 5: return ColorRGBA(r: 0, g: 0, b: 255)
        case 6: return ColorRGBA(r: 255, g: 0, b: 255)
        case 7: return ColorRGBA(r: 255, g: 255, b: 255)
        case 8: return ColorRGBA(r: 85, g: 85, b: 85)
        case 9: return ColorRGBA(r: 170, g: 170, b: 170)
        case 10: return ColorRGBA(r: 255, g: 0, b: 0)
        case 11: return ColorRGBA(r: 255, g: 128, b: 128)
        case 12: return ColorRGBA(r: 166, g: 0, b: 0)
        case 13: return ColorRGBA(r: 166, g: 83, b: 83)
        case 14: return ColorRGBA(r: 128, g: 0, b: 0)
        case 15: return ColorRGBA(r: 128, g: 64, b: 64)
        case 16: return ColorRGBA(r: 76, g: 0, b: 0)
        case 17: return ColorRGBA(r: 76, g: 38, b: 38)
        case 18: return ColorRGBA(r: 38, g: 0, b: 0)
        case 19: return ColorRGBA(r: 38, g: 19, b: 19)
        case 20: return ColorRGBA(r: 255, g: 64, b: 0)
        case 21: return ColorRGBA(r: 255, g: 159, b: 128)
        case 22: return ColorRGBA(r: 166, g: 41, b: 0)
        case 23: return ColorRGBA(r: 166, g: 104, b: 83)
        case 24: return ColorRGBA(r: 128, g: 32, b: 0)
        case 25: return ColorRGBA(r: 128, g: 80, b: 64)
        case 26: return ColorRGBA(r: 76, g: 19, b: 0)
        case 27: return ColorRGBA(r: 76, g: 48, b: 38)
        case 28: return ColorRGBA(r: 38, g: 10, b: 0)
        case 29: return ColorRGBA(r: 38, g: 24, b: 19)
        case 30: return ColorRGBA(r: 255, g: 128, b: 0)
        case 31: return ColorRGBA(r: 255, g: 191, b: 128)
        case 32: return ColorRGBA(r: 166, g: 83, b: 0)
        case 33: return ColorRGBA(r: 166, g: 124, b: 83)
        case 34: return ColorRGBA(r: 128, g: 64, b: 0)
        case 35: return ColorRGBA(r: 128, g: 96, b: 64)
        case 36: return ColorRGBA(r: 76, g: 38, b: 0)
        case 37: return ColorRGBA(r: 76, g: 57, b: 38)
        case 38: return ColorRGBA(r: 38, g: 19, b: 0)
        case 39: return ColorRGBA(r: 38, g: 29, b: 19)
        case 40: return ColorRGBA(r: 255, g: 191, b: 0)
        case 41: return ColorRGBA(r: 255, g: 223, b: 128)
        case 42: return ColorRGBA(r: 166, g: 124, b: 0)
        case 43: return ColorRGBA(r: 166, g: 145, b: 83)
        case 44: return ColorRGBA(r: 128, g: 96, b: 0)
        case 45: return ColorRGBA(r: 128, g: 112, b: 64)
        case 46: return ColorRGBA(r: 76, g: 57, b: 0)
        case 47: return ColorRGBA(r: 76, g: 67, b: 38)
        case 48: return ColorRGBA(r: 38, g: 29, b: 0)
        case 49: return ColorRGBA(r: 38, g: 33, b: 19)
        case 50: return ColorRGBA(r: 255, g: 255, b: 0)
        case 51: return ColorRGBA(r: 255, g: 255, b: 128)
        case 52: return ColorRGBA(r: 166, g: 166, b: 0)
        case 53: return ColorRGBA(r: 166, g: 166, b: 83)
        case 54: return ColorRGBA(r: 128, g: 128, b: 0)
        case 55: return ColorRGBA(r: 128, g: 128, b: 64)
        case 56: return ColorRGBA(r: 76, g: 76, b: 0)
        case 57: return ColorRGBA(r: 76, g: 76, b: 38)
        case 58: return ColorRGBA(r: 38, g: 38, b: 0)
        case 59: return ColorRGBA(r: 38, g: 38, b: 19)
        case 60: return ColorRGBA(r: 191, g: 255, b: 0)
        case 61: return ColorRGBA(r: 223, g: 255, b: 128)
        case 62: return ColorRGBA(r: 124, g: 166, b: 0)
        case 63: return ColorRGBA(r: 145, g: 166, b: 83)
        case 64: return ColorRGBA(r: 96, g: 128, b: 0)
        case 65: return ColorRGBA(r: 112, g: 128, b: 64)
        case 66: return ColorRGBA(r: 57, g: 76, b: 0)
        case 67: return ColorRGBA(r: 67, g: 76, b: 38)
        case 68: return ColorRGBA(r: 29, g: 38, b: 0)
        case 69: return ColorRGBA(r: 33, g: 38, b: 19)
        case 70: return ColorRGBA(r: 128, g: 255, b: 0)
        case 71: return ColorRGBA(r: 191, g: 255, b: 128)
        case 72: return ColorRGBA(r: 83, g: 166, b: 0)
        case 73: return ColorRGBA(r: 124, g: 166, b: 83)
        case 74: return ColorRGBA(r: 64, g: 128, b: 0)
        case 75: return ColorRGBA(r: 96, g: 128, b: 64)
        case 76: return ColorRGBA(r: 38, g: 76, b: 0)
        case 77: return ColorRGBA(r: 57, g: 76, b: 38)
        case 78: return ColorRGBA(r: 19, g: 38, b: 0)
        case 79: return ColorRGBA(r: 29, g: 38, b: 19)
        case 80: return ColorRGBA(r: 64, g: 255, b: 0)
        case 81: return ColorRGBA(r: 159, g: 255, b: 128)
        case 82: return ColorRGBA(r: 41, g: 166, b: 0)
        case 83: return ColorRGBA(r: 104, g: 166, b: 83)
        case 84: return ColorRGBA(r: 32, g: 128, b: 0)
        case 85: return ColorRGBA(r: 80, g: 128, b: 64)
        case 86: return ColorRGBA(r: 19, g: 76, b: 0)
        case 87: return ColorRGBA(r: 48, g: 76, b: 38)
        case 88: return ColorRGBA(r: 10, g: 38, b: 0)
        case 89: return ColorRGBA(r: 24, g: 38, b: 19)
        case 90: return ColorRGBA(r: 0, g: 255, b: 0)
        case 91: return ColorRGBA(r: 128, g: 255, b: 128)
        case 92: return ColorRGBA(r: 0, g: 166, b: 0)
        case 93: return ColorRGBA(r: 83, g: 166, b: 83)
        case 94: return ColorRGBA(r: 0, g: 128, b: 0)
        case 95: return ColorRGBA(r: 64, g: 128, b: 64)
        case 96: return ColorRGBA(r: 0, g: 76, b: 0)
        case 97: return ColorRGBA(r: 38, g: 76, b: 38)
        case 98: return ColorRGBA(r: 0, g: 38, b: 0)
        case 99: return ColorRGBA(r: 19, g: 38, b: 19)
        case 100: return ColorRGBA(r: 0, g: 255, b: 64)
        case 101: return ColorRGBA(r: 128, g: 255, b: 159)
        case 102: return ColorRGBA(r: 0, g: 166, b: 41)
        case 103: return ColorRGBA(r: 83, g: 166, b: 104)
        case 104: return ColorRGBA(r: 0, g: 128, b: 32)
        case 105: return ColorRGBA(r: 64, g: 128, b: 80)
        case 106: return ColorRGBA(r: 0, g: 76, b: 19)
        case 107: return ColorRGBA(r: 38, g: 76, b: 48)
        case 108: return ColorRGBA(r: 0, g: 38, b: 10)
        case 109: return ColorRGBA(r: 19, g: 38, b: 24)
        case 110: return ColorRGBA(r: 0, g: 255, b: 128)
        case 111: return ColorRGBA(r: 128, g: 255, b: 191)
        case 112: return ColorRGBA(r: 0, g: 166, b: 83)
        case 113: return ColorRGBA(r: 83, g: 166, b: 124)
        case 114: return ColorRGBA(r: 0, g: 128, b: 64)
        case 115: return ColorRGBA(r: 64, g: 128, b: 96)
        case 116: return ColorRGBA(r: 0, g: 76, b: 38)
        case 117: return ColorRGBA(r: 38, g: 76, b: 57)
        case 118: return ColorRGBA(r: 0, g: 38, b: 19)
        case 119: return ColorRGBA(r: 19, g: 38, b: 29)
        case 120: return ColorRGBA(r: 0, g: 255, b: 191)
        case 121: return ColorRGBA(r: 128, g: 255, b: 223)
        case 122: return ColorRGBA(r: 0, g: 166, b: 124)
        case 123: return ColorRGBA(r: 83, g: 166, b: 145)
        case 124: return ColorRGBA(r: 0, g: 128, b: 96)
        case 125: return ColorRGBA(r: 64, g: 128, b: 112)
        case 126: return ColorRGBA(r: 0, g: 76, b: 57)
        case 127: return ColorRGBA(r: 38, g: 76, b: 67)
        case 128: return ColorRGBA(r: 0, g: 38, b: 29)
        case 129: return ColorRGBA(r: 19, g: 38, b: 33)
        case 130: return ColorRGBA(r: 0, g: 255, b: 255)
        case 131: return ColorRGBA(r: 128, g: 255, b: 255)
        case 132: return ColorRGBA(r: 0, g: 166, b: 166)
        case 133: return ColorRGBA(r: 83, g: 166, b: 166)
        case 134: return ColorRGBA(r: 0, g: 128, b: 128)
        case 135: return ColorRGBA(r: 64, g: 128, b: 128)
        case 136: return ColorRGBA(r: 0, g: 76, b: 76)
        case 137: return ColorRGBA(r: 38, g: 76, b: 76)
        case 138: return ColorRGBA(r: 0, g: 38, b: 38)
        case 139: return ColorRGBA(r: 19, g: 38, b: 38)
        case 140: return ColorRGBA(r: 0, g: 191, b: 255)
        case 141: return ColorRGBA(r: 128, g: 223, b: 255)
        case 142: return ColorRGBA(r: 0, g: 124, b: 166)
        case 143: return ColorRGBA(r: 83, g: 145, b: 166)
        case 144: return ColorRGBA(r: 0, g: 96, b: 128)
        case 145: return ColorRGBA(r: 64, g: 112, b: 128)
        case 146: return ColorRGBA(r: 0, g: 57, b: 76)
        case 147: return ColorRGBA(r: 38, g: 67, b: 76)
        case 148: return ColorRGBA(r: 0, g: 29, b: 38)
        case 149: return ColorRGBA(r: 19, g: 33, b: 38)
        case 150: return ColorRGBA(r: 0, g: 128, b: 255)
        case 151: return ColorRGBA(r: 128, g: 191, b: 255)
        case 152: return ColorRGBA(r: 0, g: 83, b: 166)
        case 153: return ColorRGBA(r: 83, g: 124, b: 166)
        case 154: return ColorRGBA(r: 0, g: 64, b: 128)
        case 155: return ColorRGBA(r: 64, g: 96, b: 128)
        case 156: return ColorRGBA(r: 0, g: 38, b: 76)
        case 157: return ColorRGBA(r: 38, g: 57, b: 76)
        case 158: return ColorRGBA(r: 0, g: 19, b: 38)
        case 159: return ColorRGBA(r: 19, g: 29, b: 38)
        case 160: return ColorRGBA(r: 0, g: 64, b: 255)
        case 161: return ColorRGBA(r: 128, g: 159, b: 255)
        case 162: return ColorRGBA(r: 0, g: 41, b: 166)
        case 163: return ColorRGBA(r: 83, g: 104, b: 166)
        case 164: return ColorRGBA(r: 0, g: 32, b: 128)
        case 165: return ColorRGBA(r: 64, g: 80, b: 128)
        case 166: return ColorRGBA(r: 0, g: 19, b: 76)
        case 167: return ColorRGBA(r: 38, g: 48, b: 76)
        case 168: return ColorRGBA(r: 0, g: 10, b: 38)
        case 169: return ColorRGBA(r: 19, g: 24, b: 38)
        case 170: return ColorRGBA(r: 0, g: 0, b: 255)
        case 171: return ColorRGBA(r: 128, g: 128, b: 255)
        case 172: return ColorRGBA(r: 0, g: 0, b: 166)
        case 173: return ColorRGBA(r: 83, g: 83, b: 166)
        case 174: return ColorRGBA(r: 0, g: 0, b: 128)
        case 175: return ColorRGBA(r: 64, g: 64, b: 128)
        case 176: return ColorRGBA(r: 0, g: 0, b: 76)
        case 177: return ColorRGBA(r: 38, g: 38, b: 76)
        case 178: return ColorRGBA(r: 0, g: 0, b: 38)
        case 179: return ColorRGBA(r: 19, g: 19, b: 38)
        case 180: return ColorRGBA(r: 64, g: 0, b: 255)
        case 181: return ColorRGBA(r: 159, g: 128, b: 255)
        case 182: return ColorRGBA(r: 41, g: 0, b: 166)
        case 183: return ColorRGBA(r: 104, g: 83, b: 166)
        case 184: return ColorRGBA(r: 32, g: 0, b: 128)
        case 185: return ColorRGBA(r: 80, g: 64, b: 128)
        case 186: return ColorRGBA(r: 19, g: 0, b: 76)
        case 187: return ColorRGBA(r: 48, g: 38, b: 76)
        case 188: return ColorRGBA(r: 10, g: 0, b: 38)
        case 189: return ColorRGBA(r: 24, g: 19, b: 38)
        case 190: return ColorRGBA(r: 128, g: 0, b: 255)
        case 191: return ColorRGBA(r: 191, g: 128, b: 255)
        case 192: return ColorRGBA(r: 83, g: 0, b: 166)
        case 193: return ColorRGBA(r: 124, g: 83, b: 166)
        case 194: return ColorRGBA(r: 64, g: 0, b: 128)
        case 195: return ColorRGBA(r: 96, g: 64, b: 128)
        case 196: return ColorRGBA(r: 38, g: 0, b: 76)
        case 197: return ColorRGBA(r: 57, g: 38, b: 76)
        case 198: return ColorRGBA(r: 19, g: 0, b: 38)
        case 199: return ColorRGBA(r: 29, g: 19, b: 38)
        case 200: return ColorRGBA(r: 191, g: 0, b: 255)
        case 201: return ColorRGBA(r: 223, g: 128, b: 255)
        case 202: return ColorRGBA(r: 124, g: 0, b: 166)
        case 203: return ColorRGBA(r: 145, g: 83, b: 166)
        case 204: return ColorRGBA(r: 96, g: 0, b: 128)
        case 205: return ColorRGBA(r: 112, g: 64, b: 128)
        case 206: return ColorRGBA(r: 57, g: 0, b: 76)
        case 207: return ColorRGBA(r: 67, g: 38, b: 76)
        case 208: return ColorRGBA(r: 29, g: 0, b: 38)
        case 209: return ColorRGBA(r: 33, g: 19, b: 38)
        case 210: return ColorRGBA(r: 255, g: 0, b: 255)
        case 211: return ColorRGBA(r: 255, g: 128, b: 255)
        case 212: return ColorRGBA(r: 166, g: 0, b: 166)
        case 213: return ColorRGBA(r: 166, g: 83, b: 166)
        case 214: return ColorRGBA(r: 128, g: 0, b: 128)
        case 215: return ColorRGBA(r: 128, g: 64, b: 128)
        case 216: return ColorRGBA(r: 76, g: 0, b: 76)
        case 217: return ColorRGBA(r: 76, g: 38, b: 76)
        case 218: return ColorRGBA(r: 38, g: 0, b: 38)
        case 219: return ColorRGBA(r: 38, g: 19, b: 38)
        case 220: return ColorRGBA(r: 255, g: 0, b: 191)
        case 221: return ColorRGBA(r: 255, g: 128, b: 223)
        case 222: return ColorRGBA(r: 166, g: 0, b: 124)
        case 223: return ColorRGBA(r: 166, g: 83, b: 145)
        case 224: return ColorRGBA(r: 128, g: 0, b: 96)
        case 225: return ColorRGBA(r: 128, g: 64, b: 112)
        case 226: return ColorRGBA(r: 76, g: 0, b: 57)
        case 227: return ColorRGBA(r: 76, g: 38, b: 67)
        case 228: return ColorRGBA(r: 38, g: 0, b: 29)
        case 229: return ColorRGBA(r: 38, g: 19, b: 33)
        case 230: return ColorRGBA(r: 255, g: 0, b: 128)
        case 231: return ColorRGBA(r: 255, g: 128, b: 191)
        case 232: return ColorRGBA(r: 166, g: 0, b: 83)
        case 233: return ColorRGBA(r: 166, g: 83, b: 124)
        case 234: return ColorRGBA(r: 128, g: 0, b: 64)
        case 235: return ColorRGBA(r: 128, g: 64, b: 96)
        case 236: return ColorRGBA(r: 76, g: 0, b: 38)
        case 237: return ColorRGBA(r: 76, g: 38, b: 57)
        case 238: return ColorRGBA(r: 38, g: 0, b: 19)
        case 239: return ColorRGBA(r: 38, g: 19, b: 29)
        case 240: return ColorRGBA(r: 255, g: 0, b: 64)
        case 241: return ColorRGBA(r: 255, g: 128, b: 159)
        case 242: return ColorRGBA(r: 166, g: 0, b: 41)
        case 243: return ColorRGBA(r: 166, g: 83, b: 104)
        case 244: return ColorRGBA(r: 128, g: 0, b: 32)
        case 245: return ColorRGBA(r: 128, g: 64, b: 80)
        case 246: return ColorRGBA(r: 76, g: 0, b: 19)
        case 247: return ColorRGBA(r: 76, g: 38, b: 48)
        case 248: return ColorRGBA(r: 38, g: 0, b: 10)
        case 249: return ColorRGBA(r: 38, g: 19, b: 24)
        case 250: return ColorRGBA(r: 84, g: 84, b: 84)
        case 251: return ColorRGBA(r: 118, g: 118, b: 118)
        case 252: return ColorRGBA(r: 152, g: 152, b: 152)
        case 253: return ColorRGBA(r: 187, g: 187, b: 187)
        case 254: return ColorRGBA(r: 221, g: 221, b: 221)
        case 255: return ColorRGBA(r: 255, g: 255, b: 255)
        default: return .white
        }
    }

    /// Convert DXF line weight code to mm.
    /// DXF line weights are stored in 1/100 mm; -1=ByLayer, -2=ByBlock, -3=Default.
    public static func lineWeightToMM(_ lw: Double) -> Double {
        if lw < 0 { return 0.25 }  // default
        return lw / 100.0
    }

    /// Convert DXF transparency (group code 440/441) to opacity 0.0–1.0.
    /// Explicit DXF transparency is packed as 0x020000TT, where TT is an
    /// alpha byte (0 = transparent, 255 = opaque). 0x01000000 means ByBlock,
    /// and an omitted value means ByLayer.
    public static func transparencyToOpacity(_ trans: Int32) -> Double {
        guard trans >= 0 else { return 1.0 }

        let raw = UInt32(bitPattern: trans)
        switch raw & 0xFF00_0000 {
        case 0x0200_0000:
            return Double(raw & 0xFF) / 255.0
        case 0x0100_0000:
            return 1.0
        default:
            // Backward compatibility with DXFs written by older Zephyr builds,
            // which emitted bare transparency percentages/alpha values.
            if raw == 0 { return 1.0 }
            if raw <= 90 { return 1.0 - Double(raw) / 100.0 }
            if raw <= 255 { return Double(raw) / 255.0 }
            return 1.0
        }
    }

    /// Returns an opacity only when group 440/441 contains an explicit value.
    /// ByLayer/ByBlock values must remain inherited rather than becoming opaque.
    public static func explicitTransparencyToOpacity(_ trans: Int32) -> Double? {
        guard trans >= 0 else { return nil }
        let raw = UInt32(bitPattern: trans)
        let method = raw & 0xFF00_0000
        if method == 0x0100_0000 { return nil }
        if method == 0x0200_0000 || raw <= 255 {
            return transparencyToOpacity(trans)
        }
        return nil
    }

    /// Convert packed DXF transparency (group 440/441) to a canonical
    /// 0...90 percent layer-transparency value. ByLayer/ByBlock and
    /// missing values (-1) map to 0 (opaque).
    public static func transparencyPercent(_ trans: Int32) -> Int {
        guard trans >= 0 else { return 0 }
        let raw = UInt32(bitPattern: trans)
        switch raw & 0xFF00_0000 {
        case 0x0200_0000:
            let alpha = Int(raw & 0xFF)
            let percent = 100 - Int((Double(alpha) * 100.0 / 255.0).rounded())
            return max(0, min(90, percent))
        case 0x0100_0000:
            return 0
        default:
            // Legacy Zephyr/foreign files that stored a bare percent.
            if raw <= 90 { return Int(raw) }
            let viaOpacity = 100 - Int(transparencyToOpacity(trans) * 100.0 + 0.5)
            return max(0, min(90, viaOpacity))
        }
    }

    /// Convert opacity 0.0–1.0 to packed DXF group 440/441 format.
    /// Fully opaque values are omitted by default so entities remain ByLayer.
    public static func opacityToTransparency(
        _ opacity: Double,
        omitOpaque: Bool = true
    ) -> Int32 {
        let value = max(0.0, min(1.0, opacity))
        if omitOpaque && value >= 0.999999 { return -1 }
        let alpha = UInt32(max(0, min(255, Int((value * 255.0).rounded()))))
        return Int32(bitPattern: 0x0200_0000 | alpha)
    }

    /// Convert RGBA → ACI. Returns 7 (white) by default.
    public static func rgbaToACI(_ color: ColorRGBA) -> Int32 {
        if color.a == 0 { return 256 }
        var best: Int32 = 7; var bestDist = Double.infinity
        for i in 1..<256 {
            let (dr, dg, db) = (Double(Int(color.r) - Int(_dxfPalette[i][0])),
                                Double(Int(color.g) - Int(_dxfPalette[i][1])),
                                Double(Int(color.b) - Int(_dxfPalette[i][2])))
            let dist = dr * dr + dg * dg + db * db
            if dist < bestDist { bestDist = dist; best = Int32(i) }
        }
        return best
    }

    /// Convert RGBA → 24-bit true color. nil if BYLAYER.
    public static func rgbaToTrueColor(_ color: ColorRGBA) -> Int32? {
        if color.a == 0 { return nil }
        return (Int32(color.r) << 16) | (Int32(color.g) << 8) | Int32(color.b)
    }

    /// Returns true if the RGBA color matches an AutoCAD Color Index (ACI 1...255) standard color.
    public static func isACI(_ color: ColorRGBA) -> Bool {
        for i in 1..<256 {
            let p = _dxfPalette[i]
            if p[0] == color.r && p[1] == color.g && p[2] == color.b {
                return true
            }
        }
        return false
    }

    /// ACI palette table (indices 1-255), used by rgbaToACI
    private static let _dxfPalette: [[UInt8]] = {
        // Map ACI → RGB using the existing aciToRGBA logic
        var p = [[UInt8]](repeating: [0,0,0], count: 256)
        for i in 1..<256 {
            let c = aciToRGBA(Int32(i), color24: -1)
            p[i] = [c.r, c.g, c.b]
        }
        return p
    }()
}

import Foundation

// =========================================================================
// MARK: - Referenced media definitions (ATTACH)
//
// Document-level definitions for live-referenced images and PDF
// underlays, mirroring DXF IMAGEDEF / PDFDEFINITION objects. The
// definition carries the saved path; instances are ordinary entities
/// whose `.image` primitive names the definition. Decoded pixels are
/// runtime state (MediaReferenceStore) and never persist — saves keep
/// only the path, like drawing xrefs.
// =========================================================================

/// A referenced raster image (DXF IMAGEDEF).
public struct CADImageDefinition: Hashable, Sendable, Codable {
    /// Drawing-visible definition name (dictionary key in DXF).
    public var name: String
    /// Path as saved in the host file (absolute, relative, or bare name).
    public var savedPath: String
    /// Pixel size from the definition/file header (0 = unknown yet).
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(name: String, savedPath: String, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.name = name
        self.savedPath = savedPath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A referenced PDF page (DXF PDFDEFINITION).
public struct CADPdfDefinition: Hashable, Sendable, Codable {
    /// Drawing-visible definition name (dictionary key in DXF).
    public var name: String
    /// Path as saved in the host file.
    public var savedPath: String
    /// 1-based page number (DXF group 2 stores it as a string).
    public var pageNumber: Int

    public init(name: String, savedPath: String, pageNumber: Int = 1) {
        self.name = name
        self.savedPath = savedPath
        self.pageNumber = max(1, pageNumber)
    }
}

/// Per-instance PDF underlay parameters that cannot be derived from
/// the instance geometry (kept for DXF write-back fidelity).
/// Per-instance raster-image adjust (IMAGEADJUST): DXF IMAGE 281/282/283.
/// Stored only when non-default; the renderer maps fade to sprite alpha
/// and the values round-trip through DXF.
public struct CADImageAdjust: Hashable, Sendable, Codable {
    /// DXF 281 (0...100, default 50). Stored; render-approximated.
    public var brightness: Int = 50
    /// DXF 282 (0...100, default 50). Stored; render-approximated.
    public var contrast: Int = 50
    /// DXF 283 (0...100, default 0). Honored by the renderer (alpha).
    public var fade: Int = 0

    public init() {}

    public var isDefault: Bool {
        brightness == 50 && contrast == 50 && fade == 0
    }

    /// Alpha multiplier for sprite tint (1 = opaque).
    public var alphaMultiplier: Double {
        max(0, min(1, 1 - Double(fade) / 100))
    }
}

/// Xdata storage for CADImageAdjust on the instance entity.
public enum CADImageAdjustMetadata {
    public static let key = "image.adjust"

    public static func value(from entity: CADEntity) -> CADImageAdjust? {
        guard case .string(let string) = entity.xdata[key],
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CADImageAdjust.self, from: data)
    }

    public static func set(_ value: CADImageAdjust?, on entity: inout CADEntity) {
        guard let value, !value.isDefault else {
            entity.xdata.removeValue(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return }
        entity.xdata[key] = .string(string)
    }
}

public struct CADPdfUnderlayParams: Hashable, Sendable, Codable {
    public var scaleX: Double = 1
    public var scaleY: Double = 1
    /// Counterclockwise rotation in radians, internal convention.
    public var rotation: Double = 0
    /// DXF 281 (20...100).
    public var contrast: Int = 100
    /// DXF 282 (0...80).
    public var fade: Int = 0
    /// DXF 280 bit 2.
    public var isOn: Bool = true
    /// DXF 280 bit 4.
    public var monochrome: Bool = false
    /// Point size of the page once known (loader fills this in via
    /// `resyncMediaInstanceBounds`); placeholder until loaded.
    public var pageWidthPoints: Double = CADPdfUnderlayParams.placeholderPageWidth
    public var pageHeightPoints: Double = CADPdfUnderlayParams.placeholderPageHeight

    public static let placeholderPageWidth: Double = 612
    public static let placeholderPageHeight: Double = 792

    public init() {}
}

/// Xdata storage for `CADPdfUnderlayParams` on the instance entity.
public enum CADPdfUnderlayMetadata {
    public static let key = "zephyr.pdfunderlay.params"

    public static func value(from entity: CADEntity) -> CADPdfUnderlayParams? {
        guard case .string(let string) = entity.xdata[key],
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CADPdfUnderlayParams.self, from: data)
    }

    public static func set(_ value: CADPdfUnderlayParams?, on entity: inout CADEntity) {
        guard let value else {
            entity.xdata.removeValue(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return }
        entity.xdata[key] = .string(string)
    }
}

extension CADPrimitive {
    /// The definition/asset name when this primitive is an image.
    public var imageReferenceName: String? {
        if case .image(_, _, _, let name, _, _) = self { return name }
        return nil
    }

    /// Copy of an image primitive with new axes (loader resync).
    public func withImageAxes(uAxis: Vector3, vAxis: Vector3) -> CADPrimitive {
        guard case .image(let insertion, _, _, let name, let clip, let tint) = self else {
            return self
        }
        return .image(insertion: insertion, uAxis: uAxis, vAxis: vAxis,
                      imageName: name, clipBoundary: clip, tint: tint)
    }
}

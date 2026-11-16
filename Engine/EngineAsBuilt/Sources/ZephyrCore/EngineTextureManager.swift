import Foundation
import SwiftSDL
import SwiftSDL_image

// =========================================================================
// MARK: - GPUTextureRefCounter
//
// Reference counts for GPU textures shared between the data-texture cache
// and live sprites. The cache registers a texture with one reference;
// each sprite assigned the texture retains it and drops its reference
// through SpriteManager's textureReleaser when removed. The SDL texture
// is released only when the last reference drops, so LRU eviction can
// never free a texture a live sprite still draws (use-after-free in
// SDL_BindGPUFragmentSamplers). Textures that were never registered
// (e.g. per-sprite text textures) release immediately, preserving the
// single-owner behavior. Like the SDL GPU API itself, callers must be
// on the main thread.
// =========================================================================
final class GPUTextureRefCounter: @unchecked Sendable {
    private var counts: [OpaquePointer: Int] = [:]
    private let releaseTexture: (OpaquePointer) -> Void

    init(releaseTexture: @escaping (OpaquePointer) -> Void) {
        self.releaseTexture = releaseTexture
    }

    /// Register a newly created texture with its first (cache) reference.
    func register(_ texture: OpaquePointer) {
        counts[texture] = 1
    }

    /// Take an additional reference (e.g. a sprite using the texture).
    func retain(_ texture: OpaquePointer) {
        counts[texture, default: 0] += 1
    }

    /// Drop one reference, SDL-releasing the texture at zero.
    /// Unregistered textures are released immediately.
    func release(_ texture: OpaquePointer) {
        guard let count = counts[texture] else {
            releaseTexture(texture)
            return
        }
        if count <= 1 {
            counts[texture] = nil
            releaseTexture(texture)
        } else {
            counts[texture] = count - 1
        }
    }

    func refCount(for texture: OpaquePointer) -> Int? {
        counts[texture]
    }
}

// =========================================================================
// MARK: - EngineTextureManager
//
// Manages loading and caching of textures from disk to GPU.
// Also supports loading from in-memory Data for image assets.
// =========================================================================
@MainActor
public final class EngineTextureManager {
    
    private unowned let engine: PhrostEngine

    /// Shared reference counter for data-cached textures (see
    /// GPUTextureRefCounter). Sprite texture releasers drop sprite
    /// references through this counter instead of releasing directly.
    let dataTextureRefs: GPUTextureRefCounter
    
    /// Map of loaded textures (path to GPU texture pointer)
    public var textureCache: [String: OpaquePointer?] = [:]
    
    /// Map of filenames to integer IDs for user-facing APIs
    public var loadedFilenames: [String: UInt64] = [:]

    /// Data-based texture cache keyed by image asset name (sha256 hex).
    public var dataTextureCache: [String: OpaquePointer?] = [:]

    /// Track texture dimensions for data-cached textures (name → (width, height)).
    public var dataTextureDimensions: [String: (Int, Int)] = [:]

    /// LRU tracking: ordered list of cache keys (most recently used at end).
    private var lruKeys: [String] = []

    /// Maximum number of GPU textures to cache simultaneously.
    public var maxCachedTextures: Int = 64

    /// Maximum decoded pixel count before rejecting an image.
    public var maxDecodedPixels: Int = 100_000_000

    /// Maximum texture dimension (width or height). Exceeding this will downsample.
    public var maxTextureDimension: Int = 16384

    /// Placeholder texture for missing/failed images (optional).
    private var placeholderTexture: OpaquePointer? = nil
    
    /// Auto-incrementing texture ID counter
    public var nextTextureID: UInt64 = 1

    public init(engine: PhrostEngine) {
        self.engine = engine
        let device = engine.gpuDevice
        self.dataTextureRefs = GPUTextureRefCounter { tex in
            SDL_ReleaseGPUTexture(device, tex)
        }
    }

    /// Retain a data-cached texture for use outside the cache (e.g. a
    /// sprite). Balanced by one textureReleaser call when the user is
    /// removed; LRU eviction only drops the cache's own reference.
    public func retainDataTexture(_ texture: OpaquePointer) {
        dataTextureRefs.retain(texture)
    }

    /// Drop one reference to a texture (see GPUTextureRefCounter).
    public func releaseTextureRef(_ texture: OpaquePointer) {
        dataTextureRefs.release(texture)
    }

    // MARK: - Texture Loading

    /// Loads a texture from file and assigns it to a sprite.
    /// Returns the texture ID (0 on failure).
    @discardableResult
    public func loadTexture(path: String, forSprite id1: Int64, _ id2: Int64) -> UInt64 {
        let spriteID = SpriteID(id1: id1, id2: id2)
        let (textureID, texture) = getOrLoadTexture(path: path)
        engine.spriteManager.setTexture(for: spriteID, texture: texture)
        return textureID
    }

    /// Loads a texture from file without assigning to a sprite.
    /// Returns the texture ID (0 on failure).
    @discardableResult
    public func loadTexture(path: String) -> UInt64 {
        let (textureID, _) = getOrLoadTexture(path: path)
        return textureID
    }

    /// Gets a previously loaded texture ID by path, or loads it.
    /// Returns (textureID, texturePtr). ID is 0 on failure.
    internal func getOrLoadTexture(path: String) -> (UInt64, OpaquePointer?) {
        // Check cache
        if let existingID = loadedFilenames[path] {
            let texture = textureCache[path, default: nil] ?? nil
            return (existingID, texture)
        }

        // Load new texture
        print("Texture '\(path)' not in cache. Loading...")
        let surface = path.withCString { IMG_Load($0) }

        guard let loadedSurface = surface else {
            let err = String(cString: SDL_GetError())
            print("... FAILED to load texture surface '\(path)'. Error: \(err)")
            textureCache[path] = nil
            loadedFilenames[path] = 0
            return (0, nil)
        }
        defer { SDL_DestroySurface(loadedSurface) }

        // Make sure it is in RGBA32 format for upload
        var finalSurface = loadedSurface
        let targetFormat = SDL_PIXELFORMAT_RGBA32
        var convertedSurface: UnsafeMutablePointer<SDL_Surface>? = nil
        if loadedSurface.pointee.format != targetFormat {
            convertedSurface = SDL_ConvertSurface(loadedSurface, targetFormat)
            guard let converted = convertedSurface else {
                print("Failed to convert surface to RGBA32 format")
                textureCache[path] = nil
                loadedFilenames[path] = 0
                return (0, nil)
            }
            finalSurface = converted
        }
        defer {
            if let converted = convertedSurface {
                SDL_DestroySurface(converted)
            }
        }

        guard let loadedTexture = engine.renderer.uploadToGPUTexture(
            width: finalSurface.pointee.w,
            height: finalSurface.pointee.h,
            pixelData: finalSurface.pointee.pixels
        ) else {
            textureCache[path] = nil
            loadedFilenames[path] = 0
            return (0, nil)
        }

        print("Texture Loaded Successfully to GPU")
        let newID = nextTextureID
        nextTextureID &+= 1
        textureCache[path] = loadedTexture
        loadedFilenames[path] = newID
        return (newID, loadedTexture)
    }

    // MARK: - Data-based Texture Loading (for CADImageAsset)

    /// Load a GPU texture from in-memory image data. Caches by `name`.
    /// Respects pixel/dimension limits. Returns nil on failure or if limits exceeded.
    /// - Parameters:
    ///   - data: Raw image file bytes (PNG, JPEG, etc.)
    ///   - name: Cache key (typically sha256 hex from CADImageAsset)
    ///   - mimeType: MIME type hint (e.g. "image/png")
    /// - Returns: GPU texture pointer and (width, height) in pixels, or nil.
    public func loadTexture(from data: Data, name: String, mimeType: String) -> (OpaquePointer?, Int, Int) {
        // Check data cache first
        if let existing = dataTextureCache[name], let tex = existing,
           let dims = dataTextureDimensions[name] {
            // Touch LRU
            touchLRU(name)
            return (tex, dims.0, dims.1)
        }

        // Load from memory via temp file (IMG_Load works with file paths)
        let ext = mimeType.hasPrefix("image/png") ? "png"
            : mimeType.hasPrefix("image/jpeg") ? "jpg"
            : mimeType.hasPrefix("image/bmp") ? "bmp"
            : mimeType.hasPrefix("image/gif") ? "gif"
            : mimeType.hasPrefix("image/webp") ? "webp"
            : mimeType.hasPrefix("image/tiff") ? "tiff"
            : "png"
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tex_\(name).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        do {
            try data.write(to: tmpURL)
        } catch {
            print("Failed to write temp file for texture: \(error)")
            return (nil, 0, 0)
        }

        guard let loadedSurface = tmpURL.path.withCString({ IMG_Load($0) }) else {
            print("Failed to load texture from data for '\(name)'")
            dataTextureCache[name] = nil
            evictLRUIfNeeded()
            return (nil, 0, 0)
        }
        defer { SDL_DestroySurface(loadedSurface) }

        let surfW = Int(loadedSurface.pointee.w)
        let surfH = Int(loadedSurface.pointee.h)

        // Check limits
        let pixelCount = surfW * surfH
        if pixelCount > maxDecodedPixels {
            print("Image '\(name)' exceeds max decoded pixels (\(pixelCount) > \(maxDecodedPixels)). Rejected.")
            return (nil, 0, 0)
        }

        // Make sure it is in RGBA32 format for upload
        var finalSurface = loadedSurface
        let targetFormat = SDL_PIXELFORMAT_RGBA32
        var convertedSurface: UnsafeMutablePointer<SDL_Surface>? = nil
        if loadedSurface.pointee.format != targetFormat {
            convertedSurface = SDL_ConvertSurface(loadedSurface, targetFormat)
            guard let converted = convertedSurface else {
                print("Failed to convert surface to RGBA32 format")
                return (nil, 0, 0)
            }
            finalSurface = converted
        }
        defer {
            if let converted = convertedSurface {
                SDL_DestroySurface(converted)
            }
        }

        guard let loadedTexture = engine.renderer.uploadToGPUTexture(
            width: finalSurface.pointee.w,
            height: finalSurface.pointee.h,
            pixelData: finalSurface.pointee.pixels
        ) else {
            dataTextureCache[name] = nil
            evictLRUIfNeeded()
            return (nil, 0, 0)
        }

        // Store in data cache (the cache holds the first reference)
        dataTextureRefs.register(loadedTexture)
        dataTextureCache[name] = loadedTexture
        dataTextureDimensions[name] = (surfW, surfH)

        // LRU: add key
        lruKeys.removeAll { $0 == name }
        lruKeys.append(name)
        evictLRUIfNeeded()

        return (loadedTexture, surfW, surfH)
    }

    /// Get dimensions for a data-cached texture (without triggering LRU touch).
    public func dimensions(for name: String) -> (Int, Int)? {
        dataTextureDimensions[name]
    }

    /// Look up a cached data texture.
    public func getDataTexture(named name: String) -> OpaquePointer? {
        if let tex = dataTextureCache[name] {
            return tex ?? nil
        }
        return nil
    }

    /// Create or return a placeholder texture for missing/corrupt images.
    public func getPlaceholderTexture() -> OpaquePointer? {
        if let pt = placeholderTexture { return pt }
        // Create a small 2×2 checkerboard pattern
        let pixels: [UInt8] = [
            255, 0, 255, 255,   0, 255, 255, 255,
            0, 255, 255, 255,   255, 0, 255, 255
        ]
        placeholderTexture = engine.renderer.uploadToGPUTexture(
            width: 2, height: 2, pixelData: pixels)
        return placeholderTexture
    }

    // MARK: - LRU Eviction

    private func touchLRU(_ key: String) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    private func evictLRUIfNeeded() {
        while lruKeys.count > maxCachedTextures {
            let oldest = lruKeys.removeFirst()
            if let tex = dataTextureCache[oldest], let t = tex {
                // Drop only the cache's reference; sprites still using
                // this texture keep it alive until they are removed.
                releaseTextureRef(t)
            }
            dataTextureCache[oldest] = nil
            dataTextureDimensions[oldest] = nil
        }
    }

    /// Release a specific data-cached texture.
    public func releaseDataTexture(named name: String) {
        if let tex = dataTextureCache[name], let t = tex {
            releaseTextureRef(t)
        }
        dataTextureCache[name] = nil
        dataTextureDimensions[name] = nil
        lruKeys.removeAll { $0 == name }
    }

    /// Look up a cached texture by its ID.
    public func getTexture(byID id: UInt64) -> OpaquePointer? {
        for (_, texID) in loadedFilenames where texID == id {
            for (path, tex) in textureCache where loadedFilenames[path] == id {
                return tex
            }
        }
        return nil
    }

    /// Sets a source rectangle for a sprite's texture (for sprite sheets).
    public func setSpriteSourceRect(_ id1: Int64, _ id2: Int64,
                                     x: Float, y: Float, w: Float, h: Float) {
        engine.spriteManager.setSourceRect(SpriteID(id1: id1, id2: id2), (x, y, w, h))
    }
}

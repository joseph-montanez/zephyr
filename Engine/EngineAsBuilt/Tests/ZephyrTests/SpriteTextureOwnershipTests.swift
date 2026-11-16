import XCTest
@testable import ZephyrCore

@MainActor
final class SpriteTextureOwnershipTests: XCTestCase {

    private func fakeTexture(_ tag: Int) -> OpaquePointer {
        OpaquePointer(bitPattern: 0x1000 + tag)!
    }

    func testOwnedTextureReleasedOnceOnRemove() {
        let manager = SpriteManager()
        var released: [OpaquePointer] = []
        manager.textureReleaser = { released.append($0) }
        let tex = fakeTexture(1)
        let sprite = Sprite(
            id: SpriteID(id1: 1, id2: 1),
            position: (0, 0, 0), scale: (1, 1, 1), size: (8, 8),
            rotate: (0, 0, 0), color: (255, 255, 255, 255),
            speed: (0, 0), texture: tex, ownsTexture: true)
        manager.addRawSprite(sprite)
        manager.removeSprite(id: sprite.id)
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(released.first, tex)
    }

    func testBorrowedTextureNeverReleased() {
        let manager = SpriteManager()
        var released: [OpaquePointer] = []
        manager.textureReleaser = { released.append($0) }
        let tex = fakeTexture(2)
        let sprite = Sprite(
            id: SpriteID(id1: 2, id2: 2),
            position: (0, 0, 0), scale: (1, 1, 1), size: (8, 8),
            rotate: (0, 0, 0), color: (255, 255, 255, 255),
            speed: (0, 0), texture: tex, ownsTexture: false)
        manager.addRawSprite(sprite)
        manager.removeSprite(id: sprite.id)
        XCTAssertTrue(released.isEmpty)
    }

    // Regression: a DWG with more raster images than the data-texture
    // cache holds (64) evicted an image texture during applySpecs while
    // its sprite still drew it, segfaulting in
    // SDL_BindGPUFragmentSamplers. The cache reference and the sprite
    // reference must be dropped independently.
    func testCacheEvictionDoesNotFreeTextureSpriteStillUses() {
        var freed: [OpaquePointer] = []
        let refs = GPUTextureRefCounter { freed.append($0) }
        let tex = fakeTexture(10)
        refs.register(tex)   // cache reference
        refs.retain(tex)     // sprite reference
        refs.release(tex)    // LRU eviction drops the cache reference
        XCTAssertTrue(freed.isEmpty)
        XCTAssertEqual(refs.refCount(for: tex), 1)
        refs.release(tex)    // sprite removed
        XCTAssertEqual(freed, [tex])
        XCTAssertNil(refs.refCount(for: tex))
    }

    func testUnregisteredTextureReleasesImmediately() {
        var freed: [OpaquePointer] = []
        let refs = GPUTextureRefCounter { freed.append($0) }
        let tex = fakeTexture(11)
        refs.release(tex)
        XCTAssertEqual(freed, [tex])
    }

    func testImageSpriteSurvivesCacheEvictionUntilRemoved() {
        var freed: [OpaquePointer] = []
        let refs = GPUTextureRefCounter { freed.append($0) }
        let manager = SpriteManager()
        manager.textureReleaser = { refs.release($0) }
        let tex = fakeTexture(12)
        refs.register(tex)
        refs.retain(tex)
        let sprite = Sprite(
            id: SpriteID(id1: 12, id2: 12),
            position: (0, 0, 0), scale: (1, 1, 1), size: (8, 8),
            rotate: (0, 0, 0), color: (255, 255, 255, 255),
            speed: (0, 0), texture: tex, ownsTexture: true)
        sprite.textureIsRefCounted = true
        manager.addRawSprite(sprite)
        refs.release(tex)    // eviction while the sprite is live
        XCTAssertTrue(freed.isEmpty)
        manager.removeSprite(id: sprite.id)
        XCTAssertEqual(freed, [tex])
    }

    func testSharedRefCountedTextureFreedOnlyAfterLastSpriteRemoved() {
        var freed: [OpaquePointer] = []
        let refs = GPUTextureRefCounter { freed.append($0) }
        let manager = SpriteManager()
        manager.textureReleaser = { refs.release($0) }
        let tex = fakeTexture(13)
        refs.register(tex)
        let first = Sprite(
            id: SpriteID(id1: 13, id2: 1),
            position: (0, 0, 0), scale: (1, 1, 1), size: (8, 8),
            rotate: (0, 0, 0), color: (255, 255, 255, 255),
            speed: (0, 0), texture: tex, ownsTexture: true)
        let second = Sprite(
            id: SpriteID(id1: 13, id2: 2),
            position: (1, 0, 0), scale: (1, 1, 1), size: (8, 8),
            rotate: (0, 0, 0), color: (255, 255, 255, 255),
            speed: (0, 0), texture: tex, ownsTexture: true)
        first.textureIsRefCounted = true
        second.textureIsRefCounted = true
        refs.retain(tex)
        refs.retain(tex)
        manager.addRawSprite(first)
        manager.addRawSprite(second)
        refs.release(tex)    // eviction
        manager.removeSprite(id: first.id)
        XCTAssertTrue(freed.isEmpty)
        manager.removeSprite(id: second.id)
        XCTAssertEqual(freed, [tex])
    }

    func testSharedOwnerBorrowerReleasesExactlyOnce() {
        let manager = SpriteManager()
        var released: [OpaquePointer] = []
        manager.textureReleaser = { released.append($0) }
        let tex = fakeTexture(3)
        let owner = Sprite(
            id: SpriteID(id1: 3, id2: 1),
            position: (0, 0, 0), scale: (1, 1, 1), size: (8, 8),
            rotate: (0, 0, 0), color: (255, 255, 255, 255),
            speed: (0, 0), texture: tex, ownsTexture: true)
        let borrower = Sprite(
            id: SpriteID(id1: 3, id2: 2),
            position: (1, 0, 0), scale: (1, 1, 1), size: (8, 8),
            rotate: (0, 0, 0), color: (255, 255, 255, 255),
            speed: (0, 0), texture: tex, ownsTexture: false)
        manager.addRawSprite(owner)
        manager.addRawSprite(borrower)
        manager.removeSprite(id: owner.id)
        XCTAssertTrue(released.isEmpty)
        manager.removeSprite(id: borrower.id)
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(released.first, tex)
    }
}

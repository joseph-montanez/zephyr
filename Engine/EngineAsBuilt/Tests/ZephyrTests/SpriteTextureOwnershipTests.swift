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

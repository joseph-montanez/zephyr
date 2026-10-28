import XCTest
import Foundation
@testable import ZephyrCore

/// Phase 2.3b clipping aliases + IMAGEADJUST/PDFADJUST: target-kind
/// routing, per-instance adjust storage, renderer fade channel, and DXF
/// IMAGE 281/282/283 round-trip.
@MainActor
final class ClipAdjustTests: XCTestCase {

    private func makeDocument() -> CADDocument {
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        return document
    }

    private func zeroID(_ document: CADDocument) -> UUID {
        try! XCTUnwrap(document.findLayer(named: "0")).handle
    }

    private func imageEntity(
        _ document: CADDocument, name: String = "Photo"
    ) -> CADEntity {
        CADEntity(
            layerID: zeroID(document),
            localGeometry: [.image(
                insertion: Vector3(x: 0, y: 0, z: 0),
                uAxis: Vector3(x: 10, y: 0, z: 0),
                vAxis: Vector3(x: 0, y: 5, z: 0),
                imageName: name)],
            transform: .identity)
    }

    // MARK: - kind routing

    func testKindRouting() {
        let document = makeDocument()
        let blockRef = CADEntity(
            layerID: zeroID(document), blockID: UUID(),
            localGeometry: nil, transform: .identity)
        XCTAssertEqual(
            CADClipMetadata.kind(of: blockRef), .block)
        var image = imageEntity(document)
        XCTAssertEqual(CADClipMetadata.kind(of: image), .image)
        image.xdata[CADClipMetadata.underlayTypeKey] = .string("PDF")
        XCTAssertEqual(CADClipMetadata.kind(of: image), .pdf)
        let line = CADEntity(
            layerID: zeroID(document),
            localGeometry: [.line(
                start: Vector3(x: 0, y: 0, z: 0),
                end: Vector3(x: 1, y: 1, z: 0), color: nil)],
            transform: .identity)
        XCTAssertNil(CADClipMetadata.kind(of: line))
    }

    // MARK: - adjust storage + fade channel

    func testImageAdjustMetadataRoundTrip() throws {
        let document = makeDocument()
        var entity = imageEntity(document)
        XCTAssertNil(CADImageAdjustMetadata.value(from: entity))
        var adjust = CADImageAdjust()
        adjust.fade = 40
        adjust.contrast = 60
        CADImageAdjustMetadata.set(adjust, on: &entity)
        let stored = try XCTUnwrap(CADImageAdjustMetadata.value(from: entity))
        XCTAssertEqual(stored.fade, 40)
        XCTAssertEqual(stored.contrast, 60)
        XCTAssertEqual(stored.brightness, 50)
        XCTAssertEqual(stored.alphaMultiplier, 0.6, accuracy: 1e-12)
        CADImageAdjustMetadata.set(CADImageAdjust(), on: &entity)
        XCTAssertNil(CADImageAdjustMetadata.value(from: entity))
    }

    func testFadeMultiplier() {
        let document = makeDocument()
        var image = imageEntity(document)
        XCTAssertEqual(
            CADRendererBridge.imageFadeMultiplier(for: image), 1)
        var adjust = CADImageAdjust()
        adjust.fade = 25
        CADImageAdjustMetadata.set(adjust, on: &image)
        XCTAssertEqual(
            CADRendererBridge.imageFadeMultiplier(for: image),
            0.75, accuracy: 1e-12)
        var pdf = imageEntity(document)
        var params = CADPdfUnderlayParams()
        params.fade = 80
        CADPdfUnderlayMetadata.set(params, on: &pdf)
        XCTAssertEqual(
            CADRendererBridge.imageFadeMultiplier(for: pdf),
            0.2, accuracy: 1e-12)
    }

    func testFadedTint() {
        let opaque = ColorRGBA(r: 200, g: 100, b: 50, a: 255)
        XCTAssertEqual(
            CADRendererBridge.fadedTint(opaque, multiplier: 1), opaque)
        let faded = CADRendererBridge.fadedTint(opaque, multiplier: 0.5)
        XCTAssertEqual(faded.r, 200)
        XCTAssertEqual(faded.a, 128)
    }

    func testComputeSpecsHonorFade() async throws {
        let document = makeDocument()
        var entity = imageEntity(document)
        var adjust = CADImageAdjust()
        adjust.fade = 50
        CADImageAdjustMetadata.set(adjust, on: &entity)
        document.addEntity(entity)
        let specs = await CADRendererBridge.computeSpecs(
            fromSnapshot: document.snapshot(), simplifyComplexBlocks: false)
        let imageSpecs = specs.flatMap { $0.imageSpecs }
        XCTAssertEqual(imageSpecs.count, 1)
        XCTAssertEqual(try XCTUnwrap(imageSpecs[0].tint).3, 128)
    }

    // MARK: - DXF IMAGE round-trip

    func testDXFImageAdjustRoundTrip() throws {
        let document = makeDocument()
        document.importMediaDefinitions(
            image: [CADImageDefinition(name: "Photo", savedPath: "photo.png")],
            pdf: [CADPdfDefinition]())
        var entity = imageEntity(document)
        var adjust = CADImageAdjust()
        adjust.brightness = 70
        adjust.contrast = 30
        adjust.fade = 10
        CADImageAdjustMetadata.set(adjust, on: &entity)
        document.addEntity(entity)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adjust-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFExporter.export(document: document, to: url)
        let reimported = try DXFImporter.importDXFViews(filePath: url.path)
        let restored = try XCTUnwrap(reimported.entities.first.flatMap {
            CADImageAdjustMetadata.value(from: $0)
        })
        XCTAssertEqual(restored.brightness, 70)
        XCTAssertEqual(restored.contrast, 30)
        XCTAssertEqual(restored.fade, 10)
    }
}

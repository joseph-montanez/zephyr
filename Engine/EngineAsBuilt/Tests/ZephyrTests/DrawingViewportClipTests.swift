import XCTest
import SwiftSDL
@testable import ZephyrCore

/// The overlay clip fix for MEASUREGEOM (lines painting over a docked
/// ribbon) clips foreground overlays to `drawingViewportRect`. That rect in
/// turn excludes every docked panel reported via `excludeDockedPanelRect`.
/// These tests pin that exclusion math: a top-docked ribbon must push the
/// canvas below it, so the clip rect the overlays use never covers the
/// ribbon in the first place.
@MainActor
final class DrawingViewportClipTests: XCTestCase {

    func testTopDockedRibbonShrinksCanvasBelowIt() {
        let ui = EngineUIManager()
        ui.beginDrawingViewportFrame(x: 0, y: 86, width: 1280, height: 642)
        ui.excludeDockedPanelRect(x: 0, y: 86, width: 1280, height: 120)
        guard let rect = ui.drawingViewportRect else {
            return XCTFail("expected a canvas rect")
        }
        XCTAssertEqual(rect.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.y, 206, accuracy: 0.001)
        XCTAssertEqual(rect.w, 1280, accuracy: 0.001)
        XCTAssertEqual(rect.h, 522, accuracy: 0.001)
    }

    func testNoDockedPanelsKeepsFullCanvas() {
        let ui = EngineUIManager()
        ui.beginDrawingViewportFrame(x: 0, y: 86, width: 1280, height: 642)
        guard let rect = ui.drawingViewportRect else {
            return XCTFail("expected a canvas rect")
        }
        XCTAssertEqual(rect.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.y, 86, accuracy: 0.001)
        XCTAssertEqual(rect.w, 1280, accuracy: 0.001)
        XCTAssertEqual(rect.h, 642, accuracy: 0.001)
    }

    func testLeftDockedPanelShrinksCanvasWidth() {
        let ui = EngineUIManager()
        ui.beginDrawingViewportFrame(x: 0, y: 86, width: 1280, height: 642)
        ui.excludeDockedPanelRect(x: 0, y: 86, width: 280, height: 642)
        guard let rect = ui.drawingViewportRect else {
            return XCTFail("expected a canvas rect")
        }
        XCTAssertEqual(rect.x, 280, accuracy: 0.001)
        XCTAssertEqual(rect.y, 86, accuracy: 0.001)
        XCTAssertEqual(rect.w, 1000, accuracy: 0.001)
        XCTAssertEqual(rect.h, 642, accuracy: 0.001)
    }
}

import XCTest
@testable import ZephyrCore

/// ZOOM prompt-chip pilot: the provider, the shared token normalizer, and
/// input filtering. Hotkeys ("E"), chips ("Extents"), and pasted brackets
/// ("[E]") resolve to one canonical keyword so all three input routes
/// execute identical `applyZoomToken` branches.
@MainActor
final class ZoomPromptChipTests: XCTestCase {

    func testProviderListsAllTenKeywordsInPromptOrder() {
        let values = ZoomCommand().commandTextOptions(for: "").map(\.value)
        XCTAssertEqual(
            values,
            ["All", "Center", "Dynamic", "Extents", "Left",
             "Previous", "Right", "Scale", "Object", "Window"])
    }

    func testChipTitlesCarryBracketedAccelerators() {
        let options = ZoomCommand().commandTextOptions(for: "")
        XCTAssertEqual(
            options.map(\.title),
            ["[A] All", "[C] Center", "[D] Dynamic", "[E] Extents", "[L] Left",
             "[P] Previous", "[R] Right", "[S] Scale", "[O] Object", "[W] Window"])
        // The hotkey letter is discoverable through the alias list too.
        XCTAssertEqual(
            options.first(where: { $0.value == "Extents" })?.aliases, ["E"])
    }

    func testLetterWordAndBracketSpellingsShareOneCanonicalToken() {
        for (raw, canonical) in [
            ("E", "EXTENTS"), ("e", "EXTENTS"), ("Extents", "EXTENTS"),
            ("extents", "EXTENTS"), ("[E]", "EXTENTS"), ("<E>", "EXTENTS"),
            ("A", "ALL"), ("All", "ALL"), ("W", "WINDOW"), ("Window", "WINDOW"),
            ("S", "SCALE"), ("Scale", "SCALE"),
        ] as [(String, String)] {
            XCTAssertEqual(
                ZoomCommand.canonicalZoomToken(raw), canonical, "raw: \(raw)")
        }
    }

    func testUnknownTokensResolveToNil() {
        for raw in ["", "Q", "ZOOM", "EXTENTSS", "[]", "E E"] {
            XCTAssertNil(ZoomCommand.canonicalZoomToken(raw), "raw: \(raw)")
        }
    }

    func testProviderFiltersByTypedInput() {
        let values = ZoomCommand().commandTextOptions(for: "ext").map(\.value)
        XCTAssertEqual(values, ["Extents"])
        XCTAssertTrue(ZoomCommand().commandTextOptions(for: "zzz").isEmpty)
    }
}

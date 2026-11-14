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

    // MARK: - AutoCAD parity: letters buffer, Space/Enter submits

    func testPromptingLetterBuffersInsteadOfExecuting() {
        let command = ZoomCommand()
        let processor = CADCommandProcessor()
        XCTAssertFalse(processor.commandLineActive)
        // A fresh command is prompting; the first letter must open the
        // command line seeded with it, not execute the option.
        XCTAssertEqual(command.bufferPromptingLetter("e", processor: processor), .handled)
        XCTAssertTrue(processor.commandLineActive)
        XCTAssertEqual(processor.commandBuffer, "e")
        XCTAssertEqual(processor.promptInputKind, .token)
        // Still prompting: options remain on offer for the pending submit.
        XCTAssertEqual(command.commandTextOptions(for: "e").map(\.value), ["Extents"])
        // The buffered letter resolves through the submit-side path.
        XCTAssertEqual(ZoomCommand.canonicalZoomToken(processor.commandBuffer), "EXTENTS")
    }

    func testEverySubOptionLetterBuffers() {
        for letter in ["a", "c", "d", "e", "l", "o", "p", "r", "s", "w"] {
            let processor = CADCommandProcessor()
            XCTAssertEqual(
                ZoomCommand().bufferPromptingLetter(letter, processor: processor),
                .handled, "letter: \(letter)")
            XCTAssertEqual(processor.commandBuffer, letter, "letter: \(letter)")
        }
    }

    func testLaterLettersDeferToOpenLine() {
        let command = ZoomCommand()
        let processor = CADCommandProcessor()
        XCTAssertEqual(command.bufferPromptingLetter("e", processor: processor), .handled)
        // 'x' of "extents": the open line owns the keystroke, Zoom must
        // not rewrite the buffer or claim the key.
        XCTAssertEqual(command.bufferPromptingLetter("x", processor: processor), .continue)
        XCTAssertEqual(processor.commandBuffer, "e")
    }

    func testTypedFullWordResolvesOnSubmit() {
        // Typing "extents" + Space/Enter goes through handleCommandText,
        // whose canonical mapping the buffer ends at.
        XCTAssertEqual(ZoomCommand.canonicalZoomToken("extents"), "EXTENTS")
        XCTAssertEqual(ZoomCommand.canonicalZoomToken("Extents"), "EXTENTS")
    }
}

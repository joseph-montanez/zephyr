import XCTest
@testable import ZephyrCore

/// Decision table for macOS first-launch input-focus recovery.
///
/// The reported bug (visible window, permanently input-dead, no recovery
/// via click or Cmd-Tab) comes from a denied/lost activation that nothing
/// retries. These tests pin the recovery policy: retry briefly after
/// launch, always honor an explicit click, never steal focus back after
/// the user intentionally switched away.
@MainActor
final class MacOSFocusPolicyTests: XCTestCase {

    private func snapshot(
        isKeyWindow: Bool = false,
        hasSDLInputFocus: Bool = false,
        focusGainedSeen: Bool = false,
        secondsSinceLaunch: Double = 0,
        explicitUserClickWhileUnfocused: Bool = false,
        userSwitchedAway: Bool = false
    ) -> MacOSFocusPolicy.Snapshot {
        MacOSFocusPolicy.Snapshot(
            isKeyWindow: isKeyWindow,
            hasSDLInputFocus: hasSDLInputFocus,
            focusGainedSeen: focusGainedSeen,
            secondsSinceLaunch: secondsSinceLaunch,
            explicitUserClickWhileUnfocused: explicitUserClickWhileUnfocused,
            userSwitchedAway: userSwitchedAway)
    }

    func testHealthyWindowNeedsNoAction() {
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                isKeyWindow: true, hasSDLInputFocus: true,
                focusGainedSeen: true, secondsSinceLaunch: 30)),
            .none)
    }

    func testInitialLaunchWithoutFocusReasserts() {
        // The reported bug state: just launched, never gained focus.
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(secondsSinceLaunch: 1.2)),
            .reassert(reason: "initial-activation"))
    }

    func testRetryWindowExpires() {
        // Past the retry window with no click: stop asking, don't fight
        // whatever app the user is actually using.
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(secondsSinceLaunch: 60)),
            .none)
    }

    func testRetryWindowBoundaryIsInclusive() {
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                secondsSinceLaunch: MacOSFocusPolicy.initialActivationRetryWindowSeconds)),
            .reassert(reason: "initial-activation"))
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                secondsSinceLaunch: MacOSFocusPolicy.initialActivationRetryWindowSeconds + 0.1)),
            .none)
    }

    func testClickWhileNotKeyAlwaysReasserts() {
        // Explicit intent beats every other state, including long after
        // launch and after an intentional switch-away.
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                secondsSinceLaunch: 3600,
                explicitUserClickWhileUnfocused: true)),
            .reassert(reason: "click-while-not-key"))
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                secondsSinceLaunch: 3600,
                explicitUserClickWhileUnfocused: true,
                userSwitchedAway: true)),
            .reassert(reason: "click-while-not-key"))
    }

    func testClickOnAlreadyKeyWindowIsNotUnfocusedClick() {
        // Caller only sets the click flag when the window is not key; a
        // healthy key window with a click must stay quiet.
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                isKeyWindow: true, hasSDLInputFocus: true,
                focusGainedSeen: true, secondsSinceLaunch: 5,
                explicitUserClickWhileUnfocused: true)),
            .none)
    }

    func testIntentionalSwitchAwayIsRespected() {
        // Gained then lost focus, no new click: the user left on purpose.
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                focusGainedSeen: true, secondsSinceLaunch: 3,
                userSwitchedAway: true)),
            .none)
    }

    func testFocusGainedLateStopsRetrying() {
        XCTAssertEqual(
            MacOSFocusPolicy.action(for: snapshot(
                isKeyWindow: true, hasSDLInputFocus: false,
                focusGainedSeen: true, secondsSinceLaunch: 2)),
            .none)
    }
}

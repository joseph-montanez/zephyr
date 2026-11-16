import Foundation

// =========================================================================
// MARK: - MacOSFocusPolicy
//
// Pure decision table for macOS first-launch input-focus recovery.
//
// Context: on macOS the app sometimes starts visible but permanently
// input-dead (no typing, selection, or clicks register, and clicking or
// Cmd-Tab never recovers it). SDL_RaiseWindow is only a *request* — the
// window manager may deny it when raising would steal focus from another
// app, in which case SDL never emits SDL_EVENT_WINDOW_FOCUS_GAINED and the
// window never carries SDL_WINDOW_INPUT_FOCUS. The one-shot
// activate/makeKeyAndOrderFront in the old startup path had no recovery
// when that denial happened, and it additionally told ImGui it had focus
// unconditionally, so nothing downstream could detect the failure.
//
// The engine feeds this policy live OS state and performs the re-assert
// only when the policy says so. Kept dependency-free (no SDL/AppKit) so
// the table is unit-testable headless; the AppKit/SDL sampling lives on
// PhrostEngine.
// =========================================================================

public struct MacOSFocusPolicy: Sendable {
    /// Seconds after launch during which the engine may proactively
    /// re-request activation when focus was never gained. Bounded so the
    /// app never fights the user: after this window only an explicit
    /// click in our window triggers a re-assert, and a user who
    /// intentionally switched away (Cmd-Tab) is always left alone.
    public static let initialActivationRetryWindowSeconds: Double = 8.0

    public struct Snapshot: Sendable {
        /// NSWindow.isKeyWindow for the main window right now.
        public var isKeyWindow: Bool
        /// SDL_WINDOW_INPUT_FOCUS currently set on the SDL window.
        public var hasSDLInputFocus: Bool
        /// Whether SDL_EVENT_WINDOW_FOCUS_GAINED has ever arrived.
        public var focusGainedSeen: Bool
        /// Seconds elapsed since the render loop started.
        public var secondsSinceLaunch: Double
        /// A mouse-down/key-down just arrived while the window is not key.
        /// Explicit user intent directed at our window — always honored.
        public var explicitUserClickWhileUnfocused: Bool
        /// Focus was gained and then lost (user switched to another app).
        /// Never steal it back uninvited.
        public var userSwitchedAway: Bool

        public init(
            isKeyWindow: Bool,
            hasSDLInputFocus: Bool,
            focusGainedSeen: Bool,
            secondsSinceLaunch: Double,
            explicitUserClickWhileUnfocused: Bool,
            userSwitchedAway: Bool
        ) {
            self.isKeyWindow = isKeyWindow
            self.hasSDLInputFocus = hasSDLInputFocus
            self.focusGainedSeen = focusGainedSeen
            self.secondsSinceLaunch = secondsSinceLaunch
            self.explicitUserClickWhileUnfocused = explicitUserClickWhileUnfocused
            self.userSwitchedAway = userSwitchedAway
        }
    }

    public enum Action: Sendable, Equatable {
        case none
        case reassert(reason: String)
    }

    public static func action(for snapshot: Snapshot) -> Action {
        // Healthy: key window with SDL input focus. Nothing to do.
        if snapshot.isKeyWindow && snapshot.hasSDLInputFocus { return .none }
        // An explicit click/key in our window while it is not key is intent
        // to use the app — re-assert even if the user had switched away.
        if snapshot.explicitUserClickWhileUnfocused && !snapshot.isKeyWindow {
            return .reassert(reason: "click-while-not-key")
        }
        // The user intentionally left (focus gained, then lost). Respect it.
        if snapshot.userSwitchedAway { return .none }
        // First-launch recovery: the activation request was denied or lost
        // and no focus event ever arrived. Retry, but only briefly.
        if !snapshot.focusGainedSeen,
           snapshot.secondsSinceLaunch <= initialActivationRetryWindowSeconds {
            return .reassert(reason: "initial-activation")
        }
        return .none
    }
}

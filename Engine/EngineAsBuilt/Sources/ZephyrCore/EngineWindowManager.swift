import Foundation
import SwiftSDL
import ImGui
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// =========================================================================
// MARK: - WindowImGuiInputEvent
// =========================================================================

/// One ImGui input event captured during SDL polling, replayed into the
/// window-owned ImGui context immediately before its `NewFrame`.
///
/// Queued per window because the render loop draws each OS window
/// sequentially: every frame must consume only the input that targeted its
/// own window, and `io.MousePos` still holds whichever window framed last.
public enum WindowImGuiInputEvent {
    case mousePos(x: Float, y: Float)
    case mouseButton(index: Int32, down: Bool)
    case mouseWheel(x: Float, y: Float)
    case key(key: ImGuiKey, down: Bool)
    case text(String)
    case focus(gained: Bool)
}

// =========================================================================
// MARK: - EngineManagedWindow
// =========================================================================

/// One OS window owned by the engine: the main window plus any auxiliary
/// (floating) windows. Holds the per-window metrics, mouse state, input
/// queue, and last-frame capture flags the sequential renderer needs.
@MainActor
public final class EngineManagedWindow {
    /// The SDL window handle. Owned by the engine (see `createAuxWindow`).
    public let handle: OpaquePointer
    /// SDL window ID, used to route polled events to this window.
    public let id: SDL_WindowID
    /// True for the main application window, false for auxiliary windows.
    public let isMain: Bool
    /// The tab this window shows. Set for float windows; nil for the main
    /// window (which follows `mainShownTabID`) and debug windows.
    public var hostedTabID: UUID? = nil
    public var slotID: WindowSlotID = .main
    internal var iniPathStorage: UnsafeMutablePointer<CChar>?
    /// Last OS title pushed (float windows sync name + dirty dot per frame).
    public var lastTitle: String? = nil

    // MARK: Metrics (refreshed every rendered frame)

    public var width: Int32 = 0
    public var height: Int32 = 0
    public var pixelWidth: Int32 = 0
    public var pixelHeight: Int32 = 0
    public var scaleX: Float = 1
    public var scaleY: Float = 1
    public var dpiScale: Float = 1
    public var isMinimized: Bool = false
    public var isFocused: Bool = false
    /// Set when in-window UI asks to close this window. Drained at the start
    /// of the next frame so teardown never interrupts a frame in flight.
    public var closeRequestedByUI: Bool = false

    // MARK: ImGui context (one per OS window)

    /// This window's own ImGui context and IO. A single shared context
    /// cannot serve alternating per-window frames: `NewFrame` rolls
    /// `WasActive = Active` and hover search skips inactive windows, so
    /// with main/aux frames interleaved every window's widgets are
    /// permanently one frame too stale to hover (buttons never fire).
    /// Contexts share the engine's font atlas, which is rebuilt in place.
    public var imguiContext: UnsafeMutablePointer<ImGuiContext>?
    public var imguiIO: UnsafeMutablePointer<ImGuiIO>?
    /// Theme revision last applied to this window's ImGui style. Starts at
    /// -1 (never applied) so a fresh context is styled on its first frame.
    public var appliedThemeRevision: Int = -1

    // MARK: Input state

    /// Last known mouse position in window coordinates.
    public var mouseX: Float = 0
    public var mouseY: Float = 0
    /// False until the first motion event arrives; the frame feed reports
    /// an invalid position until then so nothing hovers spuriously.
    public var hasMousePos: Bool = false
    /// Input captured since this window's last frame, replayed before its
    /// next `NewFrame` and then drained.
    public var inputQueue: [WindowImGuiInputEvent] = []
    /// Capture flags recorded after this window's last rendered frame.
    /// Event routing reads these (never live `io` state, which belongs to
    /// whichever window framed last).
    public var wantCaptureMouse: Bool = false
    public var wantCaptureKeyboard: Bool = false

    public init(handle: OpaquePointer, id: SDL_WindowID, isMain: Bool) {
        self.handle = handle
        self.id = id
        self.isMain = isMain
    }
}

// =========================================================================
// MARK: - EngineWindowManager
// =========================================================================

/// Registry of every OS window owned by the engine. Index 0 is always the
/// main window; auxiliary (floating) windows follow in creation order.
///
/// Deliberately SDL-free: window lifecycle (create/claim/destroy) lives on
/// `PhrostEngine`, so the registry itself stays unit-testable with dummy
/// handles.
@MainActor
public final class EngineWindowManager {
    public private(set) var windows: [EngineManagedWindow] = []

    public init() {}

    /// The main application window, or nil before registration.
    public var mainWindow: EngineManagedWindow? {
        windows.first(where: { $0.isMain })
    }

    /// All non-main windows in creation order.
    public var auxWindows: [EngineManagedWindow] {
        windows.filter { !$0.isMain }
    }

    /// The currently focused window, or nil when focus is unknown/outside.
    public var focusedWindow: EngineManagedWindow? {
        windows.first(where: { $0.isFocused })
    }

    @discardableResult
    public func register(handle: OpaquePointer, id: SDL_WindowID, isMain: Bool) -> EngineManagedWindow {
        if let existing = window(for: id) {
            return existing
        }
        let window = EngineManagedWindow(handle: handle, id: id, isMain: isMain)
        window.slotID = isMain ? .main : lowestFreeFloatSlot()
        if isMain {
            windows.insert(window, at: 0)
        } else {
            windows.append(window)
        }
        return window
    }

    /// Remove a window from the registry. The main window is never removed.
    public func unregister(id: SDL_WindowID) {
        if let doomed = window(for: id), let stored = doomed.iniPathStorage {
            free(stored)
            doomed.iniPathStorage = nil
        }
        windows.removeAll(where: { $0.id == id && !$0.isMain })
    }

    public func lowestFreeFloatSlot() -> WindowSlotID {
        let used = Set(windows.filter { !$0.isMain }.map(\.slotID))
        for n in 1...64 {
            let candidate = WindowSlotID.float(n)
            if !used.contains(candidate) { return candidate }
        }
        return .float(65)
    }

    public func window(for id: SDL_WindowID) -> EngineManagedWindow? {
        windows.first(where: { $0.id == id })
    }
}

import Foundation
import SwiftSDL

private final class NativeDialogCallbackQueue: @unchecked Sendable {
    static let shared = NativeDialogCallbackQueue()

    private let lock = NSLock()
    private var callbacks: [@MainActor @Sendable () -> Void] = []

    private init() {}

    func enqueue(_ callback: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        callbacks.append(callback)
        lock.unlock()
    }

    func drain() -> [@MainActor @Sendable () -> Void] {
        lock.lock()
        let pending = callbacks
        callbacks.removeAll(keepingCapacity: true)
        lock.unlock()
        return pending
    }
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

private final class NativeOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private let allowsAllFiles: Bool
    private let allowedExtensions: Set<String>

    init(allowsAllFiles: Bool, allowedExtensions: Set<String>) {
        self.allowsAllFiles = allowsAllFiles
        self.allowedExtensions = allowedExtensions
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory)

        if exists, isDirectory.boolValue {
            return true
        }

        let fileExtension = url.pathExtension.lowercased()
        let enabled = allowsAllFiles || allowedExtensions.contains(fileExtension)

        print(
            "[NativeOpenPanel] shouldEnable " +
            "name=\(url.lastPathComponent.debugDescription) " +
            "extension=\(fileExtension.debugDescription) " +
            "exists=\(exists) " +
            "readable=\(FileManager.default.isReadableFile(atPath: url.path)) " +
            "allowsAllFiles=\(allowsAllFiles) " +
            "allowed=\(allowedExtensions.sorted()) " +
            "result=\(enabled)")

        return enabled
    }

    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        print("[NativeOpenPanel] directory=\(url?.path ?? "nil")")
        (sender as? NSOpenPanel)?.validateVisibleColumns()
    }
}
#endif

// =========================================================================
// MARK: - NativeFileDialog
//
// Wraps SDL3's native file dialog functions (`SDL_ShowOpenFileDialog`
// and `SDL_ShowSaveFileDialog`) with Swift-friendly async-callback
// bridging. The SDL functions are non-blocking and invoke a C callback
// on an arbitrary thread; this wrapper dispatches the result onto
// `DispatchQueue.main` before invoking the Swift completion handler.
//
// Memory safety notes:
// - SDL requires the filter array and its strings to remain valid until the
//   asynchronous callback is invoked.
// - All C strings and filter structs use explicitly allocated storage owned by
//   CallbackContext. No pointer escapes a withUnsafeBufferPointer closure.
// - The CallbackContext is retained until the callback consumes it.
// =========================================================================

@MainActor
public enum NativeFileDialog {

    /// Open a file with the OS default handler (AutoCAD "Open in viewer
    /// when done"). Best effort: failures are swallowed — the export
    /// itself already succeeded.
    public static func openInSystemViewer(url: URL) {
        _ = url.absoluteString.withCString { SDL_OpenURL($0) }
    }

    // MARK: - Filter

    /// A user-visible file filter for the native dialog.
    public struct Filter: Sendable {
        public let label: String       // e.g. "Drawings (*.dxf, *.dwg)"
        public let extensions: [String] // e.g. ["dxf", "dwg"]

        public init(label: String, extensions: [String]) {
            self.label = label
            self.extensions = extensions
        }

        /// Convert to SDL3 semicolon-delimited pattern: e.g. "dxf;DXF;dwg;DWG"
        /// macOS NSOpenPanel can be case-sensitive with extensions.
        fileprivate var sdlPattern: String {
            var all: [String] = []
            for ext in extensions {
                if ext == "*" {
                    all.append("*")
                } else {
                    all.append(ext.lowercased())
                    all.append(ext.uppercased())
                }
            }
            return all.joined(separator: ";")
        }
    }

    /// Shared Save As filters for drawings. DXF stays first (native format,
    /// no external tool); DWG saves go through the ODA FileConverter behind
    /// the existing TabManager `.dwg` branch.
    public static let drawingSaveFilters: [Filter] = [
        Filter(label: "DXF Drawing", extensions: ["dxf"]),
        Filter(label: "DWG Drawing", extensions: ["dwg"]),
        Filter(label: "Zephyr Drawing", extensions: ["eab"]),
        Filter(label: "PDF Document", extensions: ["pdf"]),
        Filter(label: "All Files", extensions: ["*"]),
    ]

    /// Resolve the URL to save to from the dialog result.
    ///
    /// An explicitly typed extension always wins (`plan.dxf` saves DXF even
    /// under the DWG filter). A bare name gains the selected filter's
    /// extension; with no usable filter (index -1, out of range, or
    /// "All Files") the URL is returned unchanged.
    public static func resolvedSaveURL(
        _ url: URL,
        selectedFilterIndex: Int,
        filters: [Filter] = drawingSaveFilters
    ) -> URL {
        if !url.pathExtension.isEmpty { return url }
        guard filters.indices.contains(selectedFilterIndex) else { return url }
        guard let ext = filters[selectedFilterIndex].extensions.first(where: { $0 != "*" }) else {
            return url
        }
        return url.appendingPathExtension(ext.lowercased())
    }

    /// Owns a stable, null-terminated C string allocation.
    private final class OwnedCString {
        let pointer: UnsafeMutablePointer<CChar>
        private let count: Int

        init(_ value: String) {
            let bytes = Array(value.utf8CString)
            self.count = bytes.count
            self.pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)

            for index in bytes.indices {
                pointer.advanced(by: index).initialize(to: bytes[index])
            }
        }

        deinit {
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }

        var immutablePointer: UnsafePointer<CChar> {
            UnsafePointer(pointer)
        }
    }

    /// Callback context that owns every pointer passed to SDL until the
    /// asynchronous native dialog callback is invoked.
    ///
    /// Marked `@unchecked Sendable` because the reference is handed off
    /// from the creating thread to the SDL callback thread to the main
    /// thread — at each step exactly one thread owns the reference.
    private final class CallbackContext: @unchecked Sendable {
        let completion: @MainActor @Sendable ([URL], Int) -> Void

        private let filterNames: [OwnedCString]
        private let filterPatterns: [OwnedCString]
        private let filterStructStorage: UnsafeMutablePointer<SDL_DialogFileFilter>?
        private let defaultLocationStorage: OwnedCString?

        init(
            completion: @escaping @MainActor @Sendable ([URL], Int) -> Void,
            filters: [Filter],
            defaultLocation: String? = nil
        ) {
            self.completion = completion

            let names = filters.map { OwnedCString($0.label) }
            let patterns = filters.map { OwnedCString($0.sdlPattern) }
            self.filterNames = names
            self.filterPatterns = patterns
            self.defaultLocationStorage = defaultLocation.map(OwnedCString.init)

            if filters.isEmpty {
                self.filterStructStorage = nil
            } else {
                let storage = UnsafeMutablePointer<SDL_DialogFileFilter>.allocate(
                    capacity: filters.count)

                for index in filters.indices {
                    storage.advanced(by: index).initialize(
                        to: SDL_DialogFileFilter(
                            name: names[index].immutablePointer,
                            pattern: patterns[index].immutablePointer))
                }

                self.filterStructStorage = storage
            }
        }

        deinit {
            if let filterStructStorage {
                filterStructStorage.deinitialize(count: filterNames.count)
                filterStructStorage.deallocate()
            }
        }

        var filterStructPointer: UnsafePointer<SDL_DialogFileFilter>? {
            filterStructStorage.map { UnsafePointer($0) }
        }

        var defaultLocationPointer: UnsafePointer<CChar>? {
            defaultLocationStorage?.immutablePointer
        }
    }

    // MARK: - Show Open Dialog

    /// Show the native OS file-open dialog.
    ///
    /// - Parameters:
    ///   - window: The SDL window to make the dialog modal for.
    ///   - filters: File type filters (label + extensions). Pass `[]` for all files.
    ///   - allowMultiple: Whether the user can select multiple files.
    ///   - completion: Called on the main thread with the selected file URLs,
    ///     or an empty array if the user cancelled.
    public static func showOpenDialog(
        window: OpaquePointer?,
        filters: [Filter],
        allowMultiple: Bool = false,
        completion: @escaping @MainActor @Sendable ([URL]) -> Void
    ) {
#if os(macOS)
        showMacOpenDialog(
            filters: filters,
            allowMultiple: allowMultiple,
            completion: completion)
#else
        let effectiveFilters = filters.contains { filter in
            filter.extensions.contains("*")
        } ? [] : filters

        let context = CallbackContext(
            completion: { urls, _ in completion(urls) },
            filters: effectiveFilters)
        let userdata = Unmanaged.passRetained(context).toOpaque()

        SDL_ShowOpenFileDialog(
            nativeDialogCallback,
            userdata,
            window,
            context.filterStructPointer,
            Int32(effectiveFilters.count),
            nil,
            allowMultiple
        )
#endif
    }

#if os(macOS)
    private static func showMacOpenDialog(
        filters: [Filter],
        allowMultiple: Bool,
        completion: @escaping @MainActor @Sendable ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowMultiple
        panel.allowsOtherFileTypes = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = []
        } else {
            panel.allowedFileTypes = nil
        }
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        let allowsAllFiles = filters.isEmpty || filters.contains { filter in
            filter.extensions.contains("*")
        }
        let allowedExtensions = Set(
            filters.flatMap(\.extensions)
                .filter { $0 != "*" }
                .map { $0.lowercased() })

        let panelDelegate = NativeOpenPanelDelegate(
            allowsAllFiles: allowsAllFiles,
            allowedExtensions: allowedExtensions)
        panel.delegate = panelDelegate

        print(
            "[NativeOpenPanel] showing " +
            "allowsAllFiles=\(allowsAllFiles) " +
            "allowed=\(allowedExtensions.sorted()) " +
            "filters=\(filters.map { $0.extensions })")

        let finished: (NSApplication.ModalResponse) -> Void = { response in
            let urls = response == .OK ? panel.urls : []
            _ = panelDelegate
            completion(urls)
            NSApp.activate(ignoringOtherApps: true)
        }

        if let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(
                for: parentWindow,
                completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }

    private static func showMacOpenFolderDialog(
        allowMultiple: Bool,
        defaultLocation: String?,
        completion: @escaping @MainActor @Sendable ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = allowMultiple
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        if let defaultLocation, !defaultLocation.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: defaultLocation)
        }

        let finished: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
            NSApp.activate(ignoringOtherApps: true)
        }

        if let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(
                for: parentWindow,
                completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }
#endif

    // MARK: - Show Open Folder Dialog

    /// Show the native OS folder-picker dialog (block library folder,
    /// recent-blocks location, and similar directory picks).
    ///
    /// Requires SDL 3.2+ on non-macOS platforms (`SDL_ShowOpenFolderDialog`);
    /// all pinned build environments ship 3.4.x (see CI workflows and setup scripts).
    ///
    /// - Parameters:
    ///   - window: The SDL window to make the dialog modal for.
    ///   - allowMultiple: Whether the user can select multiple folders.
    ///   - defaultLocation: Folder the dialog opens at, if supported.
    ///   - completion: Called on the main thread with the selected folder
    ///     URLs, or an empty array if the user cancelled.
    public static func showOpenFolderDialog(
        window: OpaquePointer?,
        allowMultiple: Bool = false,
        defaultLocation: String? = nil,
        completion: @escaping @MainActor @Sendable ([URL]) -> Void
    ) {
#if os(macOS)
        showMacOpenFolderDialog(
            allowMultiple: allowMultiple,
            defaultLocation: defaultLocation,
            completion: completion)
#else
        let context = CallbackContext(
            completion: { urls, _ in completion(urls) },
            filters: [],
            defaultLocation: defaultLocation)
        let userdata = Unmanaged.passRetained(context).toOpaque()

        if let location = context.defaultLocationPointer {
            SDL_ShowOpenFolderDialog(
                nativeDialogCallback, userdata, window, location, allowMultiple)
        } else {
            SDL_ShowOpenFolderDialog(
                nativeDialogCallback, userdata, window, nil, allowMultiple)
        }
#endif
    }

    // MARK: - Show Save Dialog

    /// Show the native OS file-save dialog.
    ///
    /// - Parameters:
    ///   - window: The SDL window to make the dialog modal for.
    ///   - filters: File type filters (label + extensions).
    ///   - defaultName: Default file name shown in the dialog.
    ///   - completion: Called on the main thread with the selected file URL,
    ///     or `nil` if the user cancelled, plus the index of the selected
///     filter (`-1` when the platform reports none).
    public static func showSaveDialog(
        window: OpaquePointer?,
        filters: [Filter],
        defaultName: String? = nil,
        completion: @escaping @MainActor @Sendable (URL?, Int) -> Void
    ) {
        let context = CallbackContext(
            completion: { urls, filterIndex in
                completion(urls.first, filterIndex)
            },
            filters: filters,
            defaultLocation: defaultName)
        let userdata = Unmanaged.passRetained(context).toOpaque()

        SDL_ShowSaveFileDialog(
            nativeDialogCallback,
            userdata,
            window,
            context.filterStructPointer,
            Int32(filters.count),
            context.defaultLocationPointer
        )
    }

    // MARK: - Callback Delivery

    @discardableResult
    public static func drainPendingCallbacks() -> Int {
        let callbacks = NativeDialogCallbackQueue.shared.drain()
        for callback in callbacks {
            callback()
        }
        return callbacks.count
    }

    // MARK: - C Callback

    /// The shared C callback invoked by SDL3 when the user selects files,
    /// cancels, or an error occurs.
    ///
    /// - `filelist`: NULL-terminated array of UTF-8 file paths, or NULL
    ///   if an error occurred, or a single NULL entry if cancelled.
    private static let nativeDialogCallback: SDL_DialogFileCallback = { userdata, filelist, filterIndex in
        guard let userdata else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(userdata).takeRetainedValue()

        var urls: [URL] = []
        var errorMessage: String?

        if let filelist {
            var index = 0
            while let cString = filelist[index] {
                urls.append(URL(fileURLWithPath: String(cString: cString)))
                index += 1
            }
        } else if let error = SDL_GetError(), error.pointee != 0 {
            errorMessage = String(cString: error)
        } else {
            errorMessage = "Unknown SDL file dialog error"
        }

        let selectedURLs = urls
        let dialogError = errorMessage

        NativeDialogCallbackQueue.shared.enqueue {
            if let dialogError {
                print("[NativeFileDialog] \(dialogError)")
            }
            context.completion(selectedURLs, Int(filterIndex))
        }
    }
}

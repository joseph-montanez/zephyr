import Foundation
import SwiftSDL

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
// - Filter strings and the CallbackContext are heap-allocated and kept
//   alive until the callback fires via `Unmanaged.passRetained`.
// - The C callback balances the retain with `takeRetainedValue`, then
//   frees the context (which releases the C-string arrays).
// =========================================================================

@MainActor
public enum NativeFileDialog {

    // MARK: - Filter

    /// A user-visible file filter for the native dialog.
    public struct Filter: Sendable {
        public let label: String       // e.g. "Drawings (*.dxf, *.dwg)"
        public let extensions: [String] // e.g. ["dxf", "dwg"]

        public init(label: String, extensions: [String]) {
            self.label = label
            self.extensions = extensions
        }

        /// Convert to SDL3 semicolon-delimited pattern: e.g. "dxf;dwg"
        fileprivate var sdlPattern: String {
            extensions.joined(separator: ";")
        }
    }

    /// Callback context that holds the Swift completion closure and
    /// the C-string arrays needed by SDL. Retained via Unmanaged and
    /// released in the C callback.
    ///
    /// Marked `@unchecked Sendable` because the reference is handed off
    /// from the creating thread to the SDL callback thread to the main
    /// thread — at each step exactly one thread owns the reference.
    private final class CallbackContext: @unchecked Sendable {
        let completion: @MainActor @Sendable ([URL]) -> Void
        // Keep filter C-strings alive until the callback fires
        let filterNames: [[CChar]]
        let filterPatterns: [[CChar]]
        let filterStructs: [SDL_DialogFileFilter]

        init(
            completion: @escaping @MainActor @Sendable ([URL]) -> Void,
            filters: [Filter]
        ) {
            self.completion = completion
            self.filterNames = filters.map { Array($0.label.utf8CString) }
            self.filterPatterns = filters.map { Array($0.sdlPattern.utf8CString) }
            self.filterStructs = zip(filterNames, filterPatterns).map { name, pattern in
                SDL_DialogFileFilter(
                    name: name.withUnsafeBufferPointer { $0.baseAddress },
                    pattern: pattern.withUnsafeBufferPointer { $0.baseAddress })
            }
        }

        var filterStructPointer: UnsafePointer<SDL_DialogFileFilter>? {
            filterStructs.withUnsafeBufferPointer { $0.baseAddress }
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
        let context = CallbackContext(completion: completion, filters: filters)
        let userdata = Unmanaged.passRetained(context).toOpaque()

        let filterPtr: UnsafePointer<SDL_DialogFileFilter>? = filters.isEmpty
            ? nil
            : context.filterStructPointer
        let nFilters: Int32 = Int32(filters.count)

        SDL_ShowOpenFileDialog(
            nativeDialogCallback,
            userdata,
            window,
            filterPtr,
            nFilters,
            nil,        // default_location
            allowMultiple
        )
    }

    // MARK: - Show Save Dialog

    /// Show the native OS file-save dialog.
    ///
    /// - Parameters:
    ///   - window: The SDL window to make the dialog modal for.
    ///   - filters: File type filters (label + extensions).
    ///   - defaultName: Default file name shown in the dialog.
    ///   - completion: Called on the main thread with the selected file URL,
    ///     or `nil` if the user cancelled.
    public static func showSaveDialog(
        window: OpaquePointer?,
        filters: [Filter],
        defaultName: String? = nil,
        completion: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        // Wrap in a [URL]-based completion for reuse with the shared callback
        let context = CallbackContext(completion: { urls in
            completion(urls.first)
        }, filters: filters)
        let userdata = Unmanaged.passRetained(context).toOpaque()

        let filterPtr: UnsafePointer<SDL_DialogFileFilter>? = filters.isEmpty
            ? nil
            : context.filterStructPointer
        let nFilters: Int32 = Int32(filters.count)

        var defaultNameCStr: [CChar]? = nil
        if let name = defaultName {
            defaultNameCStr = Array(name.utf8CString)
        }

        SDL_ShowSaveFileDialog(
            nativeDialogCallback,
            userdata,
            window,
            filterPtr,
            nFilters,
            defaultNameCStr?.withUnsafeBufferPointer { $0.baseAddress }
        )
    }

    // MARK: - C Callback

    /// The shared C callback invoked by SDL3 when the user selects files,
    /// cancels, or an error occurs.
    ///
    /// - `filelist`: NULL-terminated array of UTF-8 file paths, or NULL
    ///   if an error occurred, or a single NULL entry if cancelled.
    private static let nativeDialogCallback: SDL_DialogFileCallback = { userdata, filelist, _filterIndex in
        // Extract and consume the retained context
        guard let userdata else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(userdata).takeRetainedValue()

        var urls: [URL] = []

        if let filelist = filelist {
            // filelist is NULL-terminated; iterate until we hit nil
            var i = 0
            while let cStr = filelist[i] {
                let path = String(cString: cStr)
                urls.append(URL(fileURLWithPath: path))
                i += 1
            }
        }
        // If filelist is nil or first entry is nil → cancelled or error → urls remains []

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                context.completion(urls)
            }
        }
    }
}

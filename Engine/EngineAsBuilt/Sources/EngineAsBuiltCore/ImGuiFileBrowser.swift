import Foundation
import ImGui

// =========================================================================
// MARK: - ImGuiFileBrowser
// =========================================================================

/// A lightweight modal file browser rendered entirely via ImGui.
/// Supports both Open (select existing file) and Save (type new filename) modes.
/// Uses Foundation's `FileManager` for directory listing — cross-platform
/// (macOS, Linux, Windows) with no additional dependencies.
public struct ImGuiFileBrowser {

    // MARK: - Mode

    public enum Mode {
        case open
        case save
    }

    // MARK: - State

    public var isOpen: Bool = false
    public var mode: Mode = .open
    public var currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    public var directoryContents: [URL] = []
    public var selectedFile: URL? = nil
    public var onFileSelected: ((URL) -> Void)? = nil

    /// File name typed by the user in save mode.
    public var saveFileName: String = "untitled"

    /// File extension to filter by, e.g. "dxf" or "dxf;eab". Nil means "show all files".
    public var filterExtension: String? = "dxf"
    /// Parsed set of allowed extensions (from semicolon-separated filterExtension).
    private var allowedExtensions: Set<String> = []
    /// When true, show all files regardless of `filterExtension`.
    public var showAllFiles: Bool = false
    /// Set to true when the directory needs to be re-read.
    private var needsRefresh: Bool = true
    /// True after ImGuiOpenPopup has been called (called once per open).
    private var popupOpened: Bool = false
    /// Text filter within the current directory (matches file/dir names).
    public var nameFilter: String = ""
    /// Error message to display (e.g. permission denied).
    private var errorMessage: String? = nil

    // MARK: - Input Helper

    /// Call igInputText with a fixed-size C buffer. The Swift wrapper's String? inout
    /// is broken — it uses withOptionalCString which provides a buffer only strlen+1
    /// bytes long, causing buffer overflows when ImGui writes up to bufSize bytes.
    /// This helper allocates a proper buffer and handles the C↔Swift conversion.
    private static func inputText(
        _ label: String,
        text: inout String,
        bufSize: Int,
        flags: Int32 = 0
    ) -> Bool {
        var buffer = [CChar](repeating: 0, count: bufSize)
        // Copy initial value
        let utf8 = text.utf8CString
        let copyLen = min(utf8.count, bufSize - 1)
        for i in 0..<copyLen { buffer[i] = utf8[i] }
        buffer[min(copyLen, bufSize - 1)] = 0

        let changed = igInputText(label, &buffer, bufSize, flags, nil, nil)

        // Read back (ImGui modifies buffer in place)
        if let newStr = String(cString: buffer, encoding: .utf8) {
            text = newStr
        }
        return changed
    }

    // MARK: - Public API

    /// Open the file browser in **open** mode (select an existing file).
    public mutating func open(directory: URL? = nil, filterExtension: String? = "dxf") {
        openCommon(directory: directory, filterExtension: filterExtension, mode: .open)
    }

    /// Open the file browser in **save** mode (type a filename).
    /// `defaultName` is pre-filled into the filename field.
    public mutating func openSave(
        directory: URL? = nil,
        filterExtension: String? = "dxf",
        defaultName: String = "untitled"
    ) {
        saveFileName = defaultName
        openCommon(directory: directory, filterExtension: filterExtension, mode: .save)
    }

    private mutating func openCommon(directory: URL?, filterExtension: String?, mode: Mode) {
        if let dir = directory {
            currentDirectory = dir
        } else {
            currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: currentDirectory.path, isDirectory: &isDir) || !isDir.boolValue {
            currentDirectory = URL(fileURLWithPath: NSHomeDirectory())
        }
        self.filterExtension = filterExtension
        self.allowedExtensions = Self.parseExtensions(filterExtension)
        self.showAllFiles = false
        self.selectedFile = nil
        self.nameFilter = ""
        self.errorMessage = nil
        self.mode = mode
        self.isOpen = true
        self.popupOpened = false
        self.needsRefresh = true
    }

    /// Parse semicolon-separated extensions (e.g. "dxf;eab") into a set.
    private static func parseExtensions(_ filter: String?) -> Set<String> {
        guard let f = filter, !f.isEmpty else { return [] }
        return Set(f.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    /// Close the file browser.
    public mutating func close() {
        isOpen = false
        popupOpened = false
        selectedFile = nil
        nameFilter = ""
        errorMessage = nil
    }

    // MARK: - Rendering

    /// Call this every frame between `ImGuiNewFrame` and `ImGuiRender`.
    /// Renders the modal popup when `isOpen` is true.
    public mutating func render() {
        guard isOpen else { return }

        if needsRefresh {
            refreshDirectory()
            needsRefresh = false
        }

        let popupID: String
        switch mode {
        case .open:
            popupID = "Open File##FileBrowser"
        case .save:
            popupID = "Save As##SaveFileBrowser"
        }

        let io = ImGuiGetIO()!
        let displayW = io.pointee.DisplaySize.x
        let displayH = io.pointee.DisplaySize.y
        // Clamp to 90% of display so the modal always fits even at high DPI
        // (e.g. 200% DPI on a 1080p screen gives 960×540 logical pixels).
        let maxW = displayW * 0.9
        let maxH = displayH * 0.9
        let modalW: Float = min(ImGuiGetFontSize() * 48, maxW)
        let modalH: Float = min(ImGuiGetFontSize() * 36, maxH)
        ImGuiSetNextWindowPos(
            ImVec2(x: (displayW - modalW) * 0.5, y: (displayH - modalH) * 0.5),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: modalW, y: modalH), Int32(ImGuiCond_Appearing.rawValue))

        if !popupOpened {
            ImGuiOpenPopup(popupID, Int32(ImGuiPopupFlags_None.rawValue))
            popupOpened = true
        }

        var openFlag: Bool = true
        let flags: Int32 = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue) |
                            Int32(ImGuiWindowFlags_NoDocking.rawValue)

        if ImGuiBeginPopupModal(popupID, &openFlag, flags) {
            defer { ImGuiEndPopup() }

            if !openFlag {
                close()
                return
            }

            // ---- Path navigation bar ----
            renderNavigationBar()

            igSeparator()

            // ---- Directory listing ----
            let extraForSave: Float = mode == .save ? 45 : 0
            let childHeight = modalH - 130 - extraForSave
            if ImGuiBeginChild(
                "##FileList",
                ImVec2(x: 0, y: childHeight),
                Int32(ImGuiChildFlags_None.rawValue),
                Int32(ImGuiWindowFlags_NoSavedSettings.rawValue))
            {
                defer { ImGuiEndChild() }

                if let error = errorMessage {
                    ImGuiPushStyleColor(
                        Int32(ImGuiCol_Text.rawValue),
                        ImVec4(x: 1, y: 0.3, z: 0.3, w: 1))
                    ImGuiTextV(error)
                    ImGuiPopStyleColor(1)
                } else if directoryContents.isEmpty {
                    ImGuiTextV("(empty directory)")
                } else {
                    renderDirectoryListing()
                }
            }

            igSeparator()

            // ---- Filename input (save mode only) ----
            if mode == .save {
                ImGuiTextV("File name:")
                ImGuiSameLine(0, 6)
                ImGuiPushItemWidth(250)
                var fname = saveFileName
                _ = Self.inputText("##SaveFileName", text: &fname, bufSize: 256)
                saveFileName = fname
                ImGuiPopItemWidth()
            }

            // ---- Bottom bar ----
            renderBottomBar()
        }
    }

    // MARK: - Navigation Bar

    private mutating func renderNavigationBar() {
        if igSmallButton("..") {
            navigateUp()
        }
        ImGuiSameLine(0, 6)

        if igSmallButton("~") {
            currentDirectory = URL(fileURLWithPath: NSHomeDirectory())
            selectedFile = nil
            needsRefresh = true
        }
        ImGuiSameLine(0, 6)

        ImGuiPushItemWidth(-1)
        var pathStr = currentDirectory.path
        let pathSubmitted = Self.inputText("##Path", text: &pathStr, bufSize: 4096,
                                            flags: Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue))
        if pathSubmitted {
            let url = URL(fileURLWithPath: (pathStr as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                currentDirectory = url
                selectedFile = nil
                needsRefresh = true
            }
        }
        ImGuiPopItemWidth()
    }

    // MARK: - Directory Listing

    private mutating func renderDirectoryListing() {
        let filter = nameFilter.lowercased()

        let sorted = directoryContents.sorted { a, b in
            let aIsDir = a.hasDirectoryPath
            let bIsDir = b.hasDirectoryPath
            if aIsDir != bIsDir { return aIsDir && !bIsDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        if currentDirectory.path != "/" {
            if ImGuiSelectable("..  [parent directory]", false,
                               Int32(ImGuiSelectableFlags_AllowDoubleClick.rawValue),
                               ImVec2(x: 0, y: 0)) {
                navigateUp()
            }
        }

        for url in sorted {
            let name = url.lastPathComponent
            if !filter.isEmpty && !name.lowercased().contains(filter) { continue }

            let isDir: Bool
            #if os(Windows)
            isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            #else
            isDir = url.hasDirectoryPath
            #endif

            let icon = isDir ? "📁" : "📄"
            let label = "\(icon)  \(name)"
            let isSelected = (url == selectedFile)

            if ImGuiSelectable(label, isSelected,
                Int32(ImGuiSelectableFlags_AllowDoubleClick.rawValue),
                ImVec2(x: 0, y: 0))
            {
                if isDir {
                    currentDirectory = url
                    selectedFile = nil
                    needsRefresh = true
                } else {
                    selectedFile = url
                    // In save mode, pre-fill the filename from the selected existing file
                    if mode == .save {
                        saveFileName = name
                    }
                }

                if !isDir && ImGuiIsMouseDoubleClicked(ImGuiMouseButton(ImGuiMouseButton_Left.rawValue)) {
                    confirmSelection()
                }
            }

            if isSelected && ImGuiIsKeyPressed(ImGuiKey(ImGuiKey_Enter.rawValue), false) {
                if isDir {
                    currentDirectory = url
                    selectedFile = nil
                    needsRefresh = true
                } else {
                    confirmSelection()
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private mutating func renderBottomBar() {
        var showAll = showAllFiles
        ImGuiCheckbox("Show All Files", &showAll)
        if showAll != showAllFiles {
            showAllFiles = showAll
            needsRefresh = true
        }

        ImGuiSameLine(0, 20)

        ImGuiTextV("Filter:")
        ImGuiSameLine(0, 4)
        ImGuiPushItemWidth(140)
        var filterStr = nameFilter
        _ = Self.inputText("##NameFilter", text: &filterStr, bufSize: 256)
        nameFilter = filterStr
        ImGuiPopItemWidth()

        ImGuiSameLine(0, 20)

        if igSmallButton("Cancel") {
            close()
            ImGuiCloseCurrentPopup()
        }
        ImGuiSameLine(0, 8)

        let buttonLabel: String
        let isEnabled: Bool
        switch mode {
        case .open:
            buttonLabel = "Open"
            isEnabled = selectedFile != nil
        case .save:
            buttonLabel = "Save"
            isEnabled = !saveFileName.trimmingCharacters(in: .whitespaces).isEmpty
        }

        if !isEnabled {
            ImGuiBeginDisabled(true)
            igSmallButton(buttonLabel)
            ImGuiEndDisabled()
        } else {
            if igSmallButton(buttonLabel) {
                confirmSelection()
            }
        }
    }

    // MARK: - Actions

    private mutating func navigateUp() {
        let parent = currentDirectory.deletingLastPathComponent()
        if parent.path == currentDirectory.path { return }
        currentDirectory = parent
        selectedFile = nil
        needsRefresh = true
    }

    private mutating func confirmSelection() {
        switch mode {
        case .open:
            guard let file = selectedFile else { return }
            onFileSelected?(file)
            close()
            ImGuiCloseCurrentPopup()

        case .save:
            var name = saveFileName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            // Append extension if not already present
            if let ext = filterExtension, !ext.contains(";") {
                let lowerName = name.lowercased()
                if !lowerName.hasSuffix(".\(ext)") {
                    name += ".\(ext)"
                }
            } else if !name.contains("."), let ext = filterExtension?.split(separator: ";").first {
                // Default to first extension in multi-extension filter
                let lowerName = name.lowercased()
                if !lowerName.hasSuffix(".\(ext)") {
                    name += ".\(String(ext))"
                }
            }
            let url = currentDirectory.appendingPathComponent(name)
            onFileSelected?(url)
            close()
            ImGuiCloseCurrentPopup()
        }
    }

    // MARK: - Directory Refresh

    private mutating func refreshDirectory() {
        errorMessage = nil
        let fm = FileManager.default

        let resolvedPath = (currentDirectory.path as NSString).standardizingPath
        currentDirectory = URL(fileURLWithPath: resolvedPath, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: currentDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "Directory not found: \(currentDirectory.path)"
            directoryContents = []
            return
        }

        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: currentDirectory.path)
        } catch {
            errorMessage = "Cannot read directory: \(error.localizedDescription)"
            directoryContents = []
            return
        }

        var results: [URL] = []
        results.reserveCapacity(names.count)

        for name in names {
            if Self.isReservedDeviceName(name) { continue }
            if name.hasPrefix(".") { continue }

            let url = currentDirectory.appendingPathComponent(name)

            let entryIsDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            let entryHidden = (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
            if entryHidden { continue }

            if entryIsDir {
                results.append(url)
            } else if showAllFiles {
                results.append(url)
            } else if !allowedExtensions.isEmpty {
                if allowedExtensions.contains(url.pathExtension.lowercased()) { results.append(url) }
            } else if let ext = filterExtension {
                if url.pathExtension.lowercased() == ext.lowercased() { results.append(url) }
            } else {
                results.append(url)
            }
        }

        directoryContents = results
    }

    private static func isReservedDeviceName(_ name: String) -> Bool {
        #if os(Windows)
        let stem = (name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? name)
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        switch stem {
        case "CON", "PRN", "AUX", "NUL":
            return true
        default:
            if stem.count == 4, stem.hasPrefix("COM") || stem.hasPrefix("LPT") {
                return stem.last?.isNumber ?? false
            }
            return false
        }
        #else
        return false
        #endif
    }
}

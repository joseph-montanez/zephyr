import Foundation
import ImGui

// =========================================================================
// MARK: - ImGuiFileBrowser
// =========================================================================

/// A themed modal file browser rendered entirely via ImGui.
/// Supports Open and Save modes, common places, path history, list/grid views,
/// file filters, and a CAD-flavored preview for drawing files.
public struct ImGuiFileBrowser {

    public enum Mode {
        case open
        case save
    }

    private enum BrowserView {
        case list
        case grid
    }

    private enum SortColumn: Int {
        case name
        case size
        case type
        case modified
    }

    private enum FileTypeFilter: Int {
        case drawings
        case dxf
        case all
    }

    private struct BrowserItem {
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64?
        let modified: Date?
        let typeName: String
    }

    private struct Place {
        let section: String
        let label: String
        let icon: String
        let url: URL
    }

    public var isOpen: Bool = false
    public var mode: Mode = .open
    public var currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    public var directoryContents: [URL] = []
    public var selectedFile: URL? = nil
    public var onFileSelected: ((URL) -> Void)? = nil
    public var onSaveFileSelected: ((URL, DXFVersion) -> Void)? = nil

    public var saveFileName: String = "untitled"
    public var selectedDXFVersion: DXFVersion = .defaultExport
    public var filterExtension: String? = "dxf"
    private var allowedExtensions: Set<String> = []
    public var showAllFiles: Bool = false
    public var nameFilter: String = ""

    private var needsRefresh: Bool = true
    private var popupOpened: Bool = false
    private var errorMessage: String? = nil
    private var items: [BrowserItem] = []
    private var view: BrowserView = .list
    private var sortColumn: SortColumn = .name
    private var sortAscending: Bool = true
    private var filterMode: FileTypeFilter = .drawings
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    // MARK: - Input Helper

    private static func inputText(
        _ label: String,
        text: inout String,
        bufSize: Int,
        flags: Int32 = 0
    ) -> Bool {
        var buffer = [CChar](repeating: 0, count: bufSize)
        let utf8 = text.utf8CString
        let copyLen = min(utf8.count, bufSize - 1)
        for i in 0..<copyLen { buffer[i] = utf8[i] }
        buffer[min(copyLen, bufSize - 1)] = 0

        let changed = igInputText(label, &buffer, bufSize, flags, nil, nil)
        if let newStr = String(cString: buffer, encoding: .utf8) {
            text = newStr
        }
        return changed
    }

    // MARK: - Public API

    public mutating func open(directory: URL? = nil, filterExtension: String? = "dxf") {
        openCommon(directory: directory, filterExtension: filterExtension, mode: .open)
    }

    public mutating func openSave(
        directory: URL? = nil,
        filterExtension: String? = "dxf",
        defaultName: String = "untitled",
        defaultDXFVersion: DXFVersion = .defaultExport
    ) {
        saveFileName = defaultName
        selectedDXFVersion = defaultDXFVersion
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
        self.filterMode = Self.defaultFilterMode(for: filterExtension)
        self.selectedFile = nil
        self.nameFilter = ""
        self.errorMessage = nil
        self.mode = mode
        self.isOpen = true
        self.popupOpened = false
        self.needsRefresh = true
        self.backStack = []
        self.forwardStack = []
    }

    private static func parseExtensions(_ filter: String?) -> Set<String> {
        guard let f = filter, !f.isEmpty else { return [] }
        return Set(f.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    private static func defaultFilterMode(for filter: String?) -> FileTypeFilter {
        let extensions = parseExtensions(filter)
        if extensions.contains("dxf") && extensions.contains("dwg") { return .drawings }
        if extensions == ["dxf"] { return .dxf }
        return .all
    }

    public mutating func close() {
        isOpen = false
        popupOpened = false
        selectedFile = nil
        nameFilter = ""
        errorMessage = nil
    }

    // MARK: - Rendering

    @MainActor
    public mutating func render(ui: EngineUIManager? = nil) {
        guard isOpen else { return }

        if needsRefresh {
            refreshDirectory()
            needsRefresh = false
        }

        let theme = ui?.theme ?? AppTheme.dark
        let popupID = mode == .open ? "Open Drawing##FileBrowser" : "Save Drawing As##SaveFileBrowser"
        let io = ImGuiGetIO()!
        let displayW = io.pointee.DisplaySize.x
        let displayH = io.pointee.DisplaySize.y
        let modalW = min(max(ImGuiGetFontSize() * 98, 1180), displayW * 0.90)
        let modalH = min(max(ImGuiGetFontSize() * 56, 720), displayH * 0.90)

        ImGuiSetNextWindowPos(
            ImVec2(x: (displayW - modalW) * 0.5, y: (displayH - modalH) * 0.5),
            Int32(ImGuiCond_Appearing.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: modalW, y: modalH), Int32(ImGuiCond_Appearing.rawValue))

        if !popupOpened {
            ImGuiOpenPopup(popupID, Int32(ImGuiPopupFlags_None.rawValue))
            popupOpened = true
        }

        var openFlag = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue) |
                    Int32(ImGuiWindowFlags_NoDocking.rawValue) |
                    Int32(ImGuiWindowFlags_NoResize.rawValue)

        pushDialogStyle(theme)
        if ImGuiBeginPopupModal(popupID, &openFlag, flags) {
            defer {
                ImGuiEndPopup()
                ImGuiPopStyleColor(12)
                ImGuiPopStyleVar(4)
            }

            if !openFlag {
                close()
                return
            }

            renderTitleBar(theme: theme, ui: ui)
            ImGuiDummy(ImVec2(x: 1, y: 18))
            renderTopBar(theme: theme, ui: ui)
            ImGuiDummy(ImVec2(x: 1, y: 10))
            igSeparator()

            let footerH: Float = isDXFSaveTarget ? 116 : 70
            let bodyH = max(220, ImGuiGetContentRegionAvail().y - footerH - 12)
            renderBody(theme: theme, height: bodyH)
            ImGuiDummy(ImVec2(x: 1, y: 10))
            igSeparator()
            renderBottomBar(theme: theme)
        } else {
            ImGuiPopStyleColor(12)
            ImGuiPopStyleVar(4)
        }
    }

    private func pushDialogStyle(_ theme: AppTheme) {
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), Float(14))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 24, y: 20))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_FrameRounding.rawValue), Float(8))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_FramePadding.rawValue), ImVec2(x: 12, y: 8))
        ImGuiPushStyleColor(Int32(ImGuiCol_WindowBg.rawValue), theme.panelBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Border.rawValue), theme.border)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textPrimary)
        ImGuiPushStyleColor(Int32(ImGuiCol_TextDisabled.rawValue), theme.textDim)
        ImGuiPushStyleColor(Int32(ImGuiCol_FrameBg.rawValue), theme.tabBarBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_FrameBgHovered.rawValue), theme.hoverBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), theme.tabBarBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), theme.hoverBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_ButtonActive.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Header.rawValue), theme.activeBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_HeaderHovered.rawValue), theme.hoverBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_HeaderActive.rawValue), theme.activeBg)
    }

    // MARK: - Header

    @MainActor
    private mutating func renderTitleBar(theme: AppTheme, ui: EngineUIManager?) {
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.brandGold)
        ImGuiTextV("[ ]")
        ImGuiPopStyleColor(1)
        ImGuiSameLine(0, 8)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textPrimary)
        ImGuiTextV(mode == .open ? "Open Drawing" : "Save Drawing")
        ImGuiPopStyleColor(1)

        if let ui {
            let label = ui.isDarkTheme ? "Light" : "Dark"
            ImGuiSameLine(ImGuiGetWindowWidth() - 154, 0)
            if igSmallButton(label) {
                ui.toggleTheme()
            }
        }

        ImGuiSameLine(ImGuiGetWindowWidth() - 44, 0)
        if igSmallButton("x") {
            close()
            ImGuiCloseCurrentPopup()
        }
    }

    @MainActor
    private mutating func renderTopBar(theme: AppTheme, ui: EngineUIManager?) {
        let topAvailW = ImGuiGetContentRegionAvail().x
        let navW: Float = 126
        let searchW: Float = min(300, max(220, topAvailW * 0.18))
        let viewW: Float = 128
        let spacingW: Float = 64
        let crumbW = max(300, topAvailW - navW - searchW - viewW - spacingW)

        if navigationButton("<", enabled: !backStack.isEmpty) { navigateHistory(backward: true) }
        ImGuiSameLine(0, 8)
        if navigationButton(">", enabled: !forwardStack.isEmpty) { navigateHistory(backward: false) }
        ImGuiSameLine(0, 8)
        if navigationButton("^", enabled: hasParentDirectory) { navigateUp() }
        ImGuiSameLine(0, 16)

        renderBreadcrumbs(theme: theme, width: crumbW)

        ImGuiSameLine(0, 16)
        ImGuiPushItemWidth(searchW)
        var search = nameFilter
        _ = Self.inputText("Search this folder##NameFilter", text: &search, bufSize: 256)
        if search != nameFilter {
            nameFilter = search
        }
        ImGuiPopItemWidth()

        ImGuiSameLine(0, 12)
        if viewButton("List", selected: view == .list, theme: theme) { view = .list }
        ImGuiSameLine(0, 6)
        if viewButton("Grid", selected: view == .grid, theme: theme) { view = .grid }
    }

    private mutating func renderBreadcrumbs(theme: AppTheme, width: Float) {
        let components = (currentDirectory.path as NSString).pathComponents
        let visibleStart = max(0, components.count - 4)
        var cumulative = ""
        if visibleStart > 0 {
            mutedText("...", theme: theme)
            ImGuiSameLine(0, 8)
        }
        for (index, component) in components.enumerated() {
            if index < visibleStart {
                cumulative = index == 0 ? component : (cumulative as NSString).appendingPathComponent(component)
                continue
            }
            if index > 0 {
                ImGuiSameLine(0, 8)
                mutedText(">", theme: theme)
                ImGuiSameLine(0, 8)
            }

            if index == 0 {
                cumulative = component
            } else {
                cumulative = (cumulative as NSString).appendingPathComponent(component)
            }

            let display = component.trimmingCharacters(in: CharacterSet(charactersIn: "\\/")).isEmpty
                ? component
                : component.trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            let label = shortName(display, limit: Int(max(6, min(18, width / 36))))
            if igButton("\(label)##crumb-\(index)", ImVec2(x: 0, y: 34)) {
                navigateTo(URL(fileURLWithPath: cumulative, isDirectory: true), recordHistory: true)
            }
        }
    }

    private mutating func navigationButton(_ label: String, enabled: Bool) -> Bool {
        if !enabled { ImGuiBeginDisabled(true) }
        let clicked = igButton(label, ImVec2(x: 34, y: 34))
        if !enabled { ImGuiEndDisabled() }
        return enabled && clicked
    }

    private mutating func viewButton(_ label: String, selected: Bool, theme: AppTheme) -> Bool {
        if selected {
            ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), theme.brandGold)
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.rowHoverText)
        }
        let clicked = igButton(label, ImVec2(x: 58, y: 34))
        if selected { ImGuiPopStyleColor(2) }
        return clicked
    }

    // MARK: - Body

    private mutating func renderBody(theme: AppTheme, height: Float) {
        let totalW = ImGuiGetContentRegionAvail().x
        let sideW: Float = min(330, max(260, totalW * 0.19))
        let previewW: Float = min(430, max(330, totalW * 0.24))
        let gap: Float = 16
        let centerW = max(460, totalW - sideW - previewW - gap * 2)

        if ImGuiBeginChild("##Places", ImVec2(x: sideW, y: height), Int32(ImGuiChildFlags_Borders.rawValue), 0) {
            renderPlaces(theme: theme)
        }
        ImGuiEndChild()

        ImGuiSameLine(0, gap)
        if ImGuiBeginChild("##BrowserCenter", ImVec2(x: centerW, y: height), Int32(ImGuiChildFlags_Borders.rawValue), 0) {
            if let error = errorMessage {
                ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.dangerBg)
                ImGuiTextV(error)
                ImGuiPopStyleColor(1)
            } else {
                switch view {
                case .list:
                    renderListView(theme: theme)
                case .grid:
                    renderGridView(theme: theme)
                }
            }
        }
        ImGuiEndChild()

        ImGuiSameLine(0, gap)
        if ImGuiBeginChild("##Preview", ImVec2(x: previewW, y: height), Int32(ImGuiChildFlags_Borders.rawValue), 0) {
            renderPreview(theme: theme)
        }
        ImGuiEndChild()
    }

    private mutating func renderPlaces(theme: AppTheme) {
        var currentSection = ""
        for place in places() {
            if place.section != currentSection {
                currentSection = place.section
                ImGuiDummy(ImVec2(x: 1, y: currentSection == "Favorites" ? 18 : 24))
                ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textAccent)
                ImGuiTextV(currentSection.uppercased())
                ImGuiPopStyleColor(1)
                ImGuiDummy(ImVec2(x: 1, y: 8))
            }

            let selected = currentDirectory.path == place.url.path
            let label = "\(place.icon)  \(place.label)##\(place.section)-\(place.label)"
            if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 40)) {
                navigateTo(place.url, recordHistory: true)
            }
        }
    }

    private mutating func renderListView(theme: AppTheme) {
        if visibleItems().isEmpty {
            ImGuiTextV("(empty folder)")
            return
        }

        let tableFlags = Int32(ImGuiTableFlags_RowBg.rawValue) |
                         Int32(ImGuiTableFlags_BordersInnerH.rawValue) |
                         Int32(ImGuiTableFlags_SizingStretchProp.rawValue) |
                         Int32(ImGuiTableFlags_NoSavedSettings.rawValue)

        if igBeginTable("##FileTable", 4, tableFlags, ImVec2(x: 0, y: 0), 0) {
            igTableSetupColumn("Name", Int32(ImGuiTableColumnFlags_WidthStretch.rawValue), 2.2, 0)
            igTableSetupColumn("Size", Int32(ImGuiTableColumnFlags_WidthFixed.rawValue), 86, 0)
            igTableSetupColumn("Type", Int32(ImGuiTableColumnFlags_WidthStretch.rawValue), 1.1, 0)
            igTableSetupColumn("Modified", Int32(ImGuiTableColumnFlags_WidthStretch.rawValue), 1.1, 0)
            igTableNextRow(Int32(ImGuiTableRowFlags_Headers.rawValue), 38)
            _ = igTableSetColumnIndex(0)
            renderSortableHeader(.name, theme: theme)
            _ = igTableSetColumnIndex(1)
            renderSortableHeader(.size, theme: theme)
            _ = igTableSetColumnIndex(2)
            renderSortableHeader(.type, theme: theme)
            _ = igTableSetColumnIndex(3)
            renderSortableHeader(.modified, theme: theme)

            for item in visibleItems() {
                igTableNextRow(0, 48)
                _ = igTableSetColumnIndex(0)
                renderItemSelectable(item: item, label: "\(itemIcon(item))  \(item.name)", height: 42)

                _ = igTableSetColumnIndex(1)
                mutedText(item.isDirectory ? "-" : formatBytes(item.size), theme: theme)
                _ = igTableSetColumnIndex(2)
                mutedText(item.typeName, theme: theme)
                _ = igTableSetColumnIndex(3)
                mutedText(formatDate(item.modified), theme: theme)
            }
            igEndTable()
        }
    }

    private mutating func renderSortableHeader(_ column: SortColumn, theme: AppTheme) {
        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), theme.panelBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_ButtonHovered.rawValue), theme.hoverBg)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textDim)
        if igButton(headerTitle(column), ImVec2(x: -1, y: 32)) {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        }
        ImGuiPopStyleColor(3)
    }

    private mutating func renderGridView(theme: AppTheme) {
        let visible = visibleItems()
        if visible.isEmpty {
            ImGuiTextV("(empty folder)")
            return
        }

        let tileW: Float = 142
        let tileH: Float = 118
        let availW = max(tileW, ImGuiGetContentRegionAvail().x)
        let columns = max(1, Int(availW / (tileW + 10)))

        for (index, item) in visible.enumerated() {
            if index > 0 && index % columns != 0 { ImGuiSameLine(0, 10) }
            let selected = selectedFile == item.url
            if selected {
                ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), theme.activeBg)
            }
            if igButton("##tile-\(item.url.path)", ImVec2(x: tileW, y: tileH)) {
                choose(item)
            }
            if selected { ImGuiPopStyleColor(1) }

            let min = ImGuiGetItemRectMin()
            let max = ImGuiGetItemRectMax()
            drawTileContent(item: item, min: min, max: max, theme: theme)

            if ImGuiIsItemHovered(0) && ImGuiIsMouseDoubleClicked(ImGuiMouseButton(ImGuiMouseButton_Left.rawValue)) {
                activate(item)
            }
        }
    }

    private mutating func renderItemSelectable(item: BrowserItem, label: String, height: Float) {
        let isSelected = selectedFile == item.url
        if ImGuiSelectable(label, isSelected, Int32(ImGuiSelectableFlags_SpanAllColumns.rawValue), ImVec2(x: 0, y: height)) {
            choose(item)
        }
        if ImGuiIsItemHovered(0) && ImGuiIsMouseDoubleClicked(ImGuiMouseButton(ImGuiMouseButton_Left.rawValue)) {
            activate(item)
        }
    }

    private mutating func choose(_ item: BrowserItem) {
        if item.isDirectory {
            navigateTo(item.url, recordHistory: true)
        } else {
            selectedFile = item.url
            if mode == .save {
                saveFileName = item.name
            }
        }
    }

    private mutating func activate(_ item: BrowserItem) {
        if item.isDirectory {
            navigateTo(item.url, recordHistory: true)
        } else {
            selectedFile = item.url
            confirmSelection()
        }
    }

    // MARK: - Preview

    private func renderPreview(theme: AppTheme) {
        let selected = selectedItem()
        let previewH: Float = 210
        let previewW = max(220, ImGuiGetContentRegionAvail().x)
        let start = ImGuiGetCursorScreenPos()
        igInvisibleButton("##DrawingPreviewCanvas", ImVec2(x: previewW, y: previewH), 0)
        drawPreviewCanvas(min: start, size: ImVec2(x: previewW, y: previewH), theme: theme, selected: selected)

        ImGuiDummy(ImVec2(x: 1, y: 12))
        if let selected {
            ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textPrimary)
            ImGuiTextV(selected.name)
            ImGuiPopStyleColor(1)
            mutedText(selected.typeName, theme: theme)
            igSeparator()
            metadataRow("Size", selected.isDirectory ? "-" : formatBytes(selected.size), theme: theme)
            metadataRow("Modified", formatDate(selected.modified), theme: theme)
            if isDrawing(selected.url) {
                let stats = drawingStats(for: selected.url)
                metadataRow("Layers", "\(stats.layers)", theme: theme)
                metadataRow("Entities", "\(stats.entities)", theme: theme)
                metadataRow("Units", stats.units, theme: theme)
            } else {
                metadataRow("Layers", "-", theme: theme)
                metadataRow("Entities", "-", theme: theme)
                metadataRow("Units", "-", theme: theme)
            }
        } else {
            mutedText("Select a drawing to preview", theme: theme)
        }
    }

    private func drawPreviewCanvas(min: ImVec2, size: ImVec2, theme: AppTheme, selected: BrowserItem?) {
        guard let drawList = igGetWindowDrawList() else { return }
        let max = ImVec2(x: min.x + size.x, y: min.y + size.y)
        ImDrawListAddRectFilled(drawList, min, max, igGetColorU32_Vec4(theme.tabBarBg), 8, 0)
        ImDrawListAddRect(drawList, min, max, igGetColorU32_Vec4(theme.borderDim), 8, 1.2, 0)

        let pad: Float = 38
        let left = min.x + pad
        let right = max.x - pad
        let top = min.y + 48
        let bottom = max.y - 44
        let line = igGetColorU32_Vec4(theme.textAccent)
        let gold = igGetColorU32_Vec4(theme.brandGold)
        let dim = igGetColorU32_Vec4(theme.borderDim)

        if let selected, selected.isDirectory {
            ImDrawListAddRect(drawList, ImVec2(x: left + 12, y: top + 22), ImVec2(x: right - 12, y: bottom), line, 0, 2.0, 0)
            ImDrawListAddRectFilled(drawList, ImVec2(x: left + 12, y: top + 22), ImVec2(x: right - 12, y: top + 48), dim, 0, 0)
            return
        }

        ImDrawListAddRect(drawList, ImVec2(x: left, y: top), ImVec2(x: right, y: bottom), line, 0, 3.0, 0)
        ImDrawListAddLine(drawList, ImVec2(x: left, y: top + 56), ImVec2(x: right, y: top + 56), line, 3.0)
        ImDrawListAddLine(drawList, ImVec2(x: left + (right - left) * 0.50, y: top), ImVec2(x: left + (right - left) * 0.50, y: top + 56), line, 3.0)
        ImDrawListAddRect(drawList, ImVec2(x: right - 92, y: top + 18), ImVec2(x: right - 36, y: top + 56), line, 0, 3.0, 0)
        ImDrawListAddLine(drawList, ImVec2(x: left, y: bottom - 18), ImVec2(x: left + 104, y: bottom - 18), dim, 4.0)
        ImDrawListAddBezierCubic(drawList,
            ImVec2(x: left + 72, y: top + 56),
            ImVec2(x: left + 72, y: top + 28),
            ImVec2(x: left + 112, y: top + 24),
            ImVec2(x: left + 132, y: top + 22),
            gold, 4.0, 24)
    }

    private func drawTileContent(item: BrowserItem, min: ImVec2, max: ImVec2, theme: AppTheme) {
        guard let drawList = igGetWindowDrawList() else { return }
        let line = igGetColorU32_Vec4(item.isDirectory ? theme.brandGold : theme.textAccent)
        let x0 = min.x + 18
        let y0 = min.y + 16
        let x1 = max.x - 18
        let y1 = min.y + 58

        if item.isDirectory {
            ImDrawListAddRect(drawList, ImVec2(x: x0, y: y0 + 10), ImVec2(x: x1, y: y1), line, 3, 2.0, 0)
            ImDrawListAddLine(drawList, ImVec2(x: x0 + 6, y: y0 + 10), ImVec2(x: x0 + 34, y: y0 + 10), line, 2.0)
        } else {
            ImDrawListAddRect(drawList, ImVec2(x: x0, y: y0), ImVec2(x: x1, y: y1), line, 2, 2.0, 0)
            ImDrawListAddLine(drawList, ImVec2(x: x0, y: y0 + 25), ImVec2(x: x1, y: y0 + 25), line, 1.5)
            ImDrawListAddLine(drawList, ImVec2(x: x0 + 46, y: y0), ImVec2(x: x0 + 46, y: y0 + 25), line, 1.5)
        }

        let name = shortName(item.name, limit: 18)
        ImDrawListAddText(drawList, ImVec2(x: min.x + 12, y: max.y - 42), igGetColorU32_Vec4(theme.textPrimary), name, nil)
        ImDrawListAddText(drawList, ImVec2(x: min.x + 12, y: max.y - 22), igGetColorU32_Vec4(theme.textDim), item.typeName, nil)
    }

    private func metadataRow(_ key: String, _ value: String, theme: AppTheme) {
        mutedText(key, theme: theme)
        ImGuiSameLine(ImGuiGetWindowWidth() - 92, 0)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textPrimary)
        ImGuiTextV(value)
        ImGuiPopStyleColor(1)
    }

    private func mutedText(_ text: String, theme: AppTheme) {
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textDim)
        ImGuiTextV(text)
        ImGuiPopStyleColor(1)
    }

    // MARK: - Bottom Bar

    private mutating func renderBottomBar(theme: AppTheme) {
        let totalW = ImGuiGetContentRegionAvail().x
        let labelW: Float = 88
        let filterW: Float = min(280, max(210, totalW * 0.16))
        let cancelW: Float = 124
        let openW: Float = 124
        let gap: Float = 16
        let inputW = max(260, totalW - labelW - filterW - cancelW - openW - gap * 5)

        if mode == .save {
            ImGuiPushItemWidth(labelW)
            ImGuiTextV("File name")
            ImGuiPopItemWidth()
            ImGuiSameLine(0, gap)
            ImGuiPushItemWidth(inputW)
            var fname = saveFileName
            _ = Self.inputText("##SaveFileName", text: &fname, bufSize: 256)
            saveFileName = fname
            ImGuiPopItemWidth()
        } else {
            ImGuiPushItemWidth(labelW)
            ImGuiTextV("File name")
            ImGuiPopItemWidth()
            ImGuiSameLine(0, gap)
            ImGuiPushItemWidth(inputW)
            var fileName = selectedFile?.lastPathComponent ?? ""
            _ = Self.inputText("##SelectedFileName", text: &fileName, bufSize: 256)
            ImGuiPopItemWidth()
        }

        ImGuiSameLine(0, gap)
        renderFilterSelector(theme: theme, width: filterW)
        ImGuiSameLine(0, gap)

        if igButton("Cancel", ImVec2(x: cancelW, y: 44)) {
            close()
            ImGuiCloseCurrentPopup()
        }
        ImGuiSameLine(0, 12)

        let buttonLabel = mode == .open ? "Open" : "Save"
        let isEnabled = mode == .open
            ? (selectedFile != nil && !(selectedItem()?.isDirectory ?? false))
            : !saveFileName.trimmingCharacters(in: .whitespaces).isEmpty

        if !isEnabled { ImGuiBeginDisabled(true) }
        ImGuiPushStyleColor(Int32(ImGuiCol_Button.rawValue), theme.brandGold)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.rowHoverText)
        if igButton(buttonLabel, ImVec2(x: openW, y: 44)) && isEnabled {
            confirmSelection()
        }
        ImGuiPopStyleColor(2)
        if !isEnabled { ImGuiEndDisabled() }

        if isDXFSaveTarget {
            ImGuiDummy(ImVec2(x: 1, y: 8))
            ImGuiTextV("DXF version")
            ImGuiSameLine(0, gap)
            renderDXFVersionSelector(width: filterW)
        }
    }

    private mutating func renderDXFVersionSelector(width: Float) {
        let versions: [(DXFVersion, String)] = [
            (.r2018, "AutoCAD 2018 (AC1032)"),
            (.r2013, "AutoCAD 2013 (AC1027)"),
            (.r2010, "AutoCAD 2010 (AC1024)"),
            (.r2007, "AutoCAD 2007 (AC1021)"),
            (.r2004, "AutoCAD 2004 (AC1018)"),
            (.r2000, "AutoCAD 2000 (AC1015)"),
            (.r14, "AutoCAD R14 (AC1014)"),
            (.r13, "AutoCAD R13 (AC1012)"),
            (.r12, "AutoCAD R12 (AC1009)"),
            (.r10, "AutoCAD R10 (AC1006)")
        ]
        let currentLabel = versions.first(where: { $0.0 == selectedDXFVersion })?.1
            ?? "AutoCAD 2018 (AC1032)"

        ImGuiPushItemWidth(width)
        if igBeginCombo("##DXFVersion", currentLabel, 0) {
            for (version, label) in versions {
                let selected = version == selectedDXFVersion
                if ImGuiSelectable(label, selected, 0, ImVec2(x: 0, y: 0)) {
                    selectedDXFVersion = version
                }
            }
            igEndCombo()
        }
        ImGuiPopItemWidth()
    }

    private mutating func renderFilterSelector(theme: AppTheme, width: Float) {
        let labels = ["Drawings (*.dxf, *.dwg)", "DXF (*.dxf)", "All files"]
        var current = filterMode.rawValue
        ImGuiPushItemWidth(width)
        if igBeginCombo("##FileTypeFilter", labels[current], 0) {
            for index in 0..<labels.count {
                let selected = index == current
                if ImGuiSelectable(labels[index], selected, 0, ImVec2(x: 0, y: 0)) {
                    current = index
                    filterMode = FileTypeFilter(rawValue: index) ?? .drawings
                    showAllFiles = filterMode == .all
                    needsRefresh = true
                }
            }
            igEndCombo()
        }
        ImGuiPopItemWidth()
    }

    // MARK: - Actions

    private var isDXFSaveTarget: Bool {
        guard mode == .save else { return false }
        let trimmedName = saveFileName.trimmingCharacters(in: .whitespaces)
        let explicitExtension = URL(fileURLWithPath: trimmedName).pathExtension.lowercased()
        if !explicitExtension.isEmpty { return explicitExtension == "dxf" }
        if filterMode == .dxf { return true }
        return filterExtension?.split(separator: ";").first?.lowercased() == "dxf"
    }

    private var hasParentDirectory: Bool {
        currentDirectory.deletingLastPathComponent().path != currentDirectory.path
    }

    private mutating func navigateUp() {
        guard hasParentDirectory else { return }
        navigateTo(currentDirectory.deletingLastPathComponent(), recordHistory: true)
    }

    private mutating func navigateHistory(backward: Bool) {
        if backward {
            guard let destination = backStack.popLast() else { return }
            forwardStack.append(currentDirectory)
            navigateTo(destination, recordHistory: false)
        } else {
            guard let destination = forwardStack.popLast() else { return }
            backStack.append(currentDirectory)
            navigateTo(destination, recordHistory: false)
        }
    }

    private mutating func navigateTo(_ url: URL, recordHistory: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        if recordHistory && url.path != currentDirectory.path {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
        }
        currentDirectory = url
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
            if let ext = filterExtension, !ext.contains(";") {
                let lowerName = name.lowercased()
                if !lowerName.hasSuffix(".\(ext)") { name += ".\(ext)" }
            } else if !name.contains("."), let ext = filterExtension?.split(separator: ";").first {
                let lowerName = name.lowercased()
                if !lowerName.hasSuffix(".\(ext)") { name += ".\(String(ext))" }
            }
            let url = currentDirectory.appendingPathComponent(name)
            if let onSaveFileSelected {
                onSaveFileSelected(url, selectedDXFVersion)
            } else {
                onFileSelected?(url)
            }
            close()
            ImGuiCloseCurrentPopup()
        }
    }

    // MARK: - Data

    private mutating func refreshDirectory() {
        errorMessage = nil
        let fm = FileManager.default
        currentDirectory = URL(fileURLWithPath: (currentDirectory.path as NSString).standardizingPath, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: currentDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            errorMessage = "Directory not found: \(currentDirectory.path)"
            directoryContents = []
            items = []
            return
        }

        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: currentDirectory.path)
        } catch {
            errorMessage = "Cannot read directory: \(error.localizedDescription)"
            directoryContents = []
            items = []
            return
        }

        items = names.compactMap { name in
            if Self.isReservedDeviceName(name) || name.hasPrefix(".") { return nil }
            let url = currentDirectory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey])
            if values?.isHidden == true { return nil }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !exists { return nil }
            let isDirectory = isDir.boolValue || (values?.isDirectory ?? false)
            if !isDirectory && !passesExtensionFilter(url) { return nil }
            return BrowserItem(
                url: url,
                name: name,
                isDirectory: isDirectory,
                size: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                typeName: typeName(for: url, isDirectory: isDirectory))
        }
        directoryContents = items.map(\.url)
    }

    private func visibleItems() -> [BrowserItem] {
        let filter = nameFilter.lowercased()
        return items
            .filter { filter.isEmpty || $0.name.lowercased().contains(filter) }
            .sorted(by: sortItems)
    }

    private func sortItems(_ a: BrowserItem, _ b: BrowserItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        let result: ComparisonResult
        switch sortColumn {
        case .name:
            result = a.name.localizedStandardCompare(b.name)
        case .size:
            result = (a.size ?? -1) == (b.size ?? -1) ? .orderedSame : ((a.size ?? -1) < (b.size ?? -1) ? .orderedAscending : .orderedDescending)
        case .type:
            result = a.typeName.localizedStandardCompare(b.typeName)
        case .modified:
            let at = a.modified ?? Date.distantPast
            let bt = b.modified ?? Date.distantPast
            result = at == bt ? .orderedSame : (at < bt ? .orderedAscending : .orderedDescending)
        }
        return sortAscending ? result != .orderedDescending : result == .orderedDescending
    }

    private func selectedItem() -> BrowserItem? {
        guard let selectedFile else { return nil }
        return items.first { $0.url == selectedFile }
    }

    private func passesExtensionFilter(_ url: URL) -> Bool {
        if showAllFiles || filterMode == .all { return true }
        let ext = url.pathExtension.lowercased()
        switch filterMode {
        case .drawings:
            return ext == "dxf" || ext == "dwg" || allowedExtensions.contains(ext)
        case .dxf:
            return ext == "dxf"
        case .all:
            return true
        }
    }

    private func places() -> [Place] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let workspace = URL(fileURLWithPath: "C:/dev/as-built", isDirectory: true)
        let projects = Self.isReadableDirectory(workspace) ? workspace : cwd
        var result: [Place] = [
            Place(section: "Favorites", label: "Recent", icon: "o", url: home),
            Place(section: "Favorites", label: "Desktop", icon: "[]", url: home.appendingPathComponent("Desktop", isDirectory: true)),
            Place(section: "Favorites", label: "Downloads", icon: "v", url: home.appendingPathComponent("Downloads", isDirectory: true)),
            Place(section: "Favorites", label: "Documents", icon: "#", url: home.appendingPathComponent("Documents", isDirectory: true)),
            Place(section: "Favorites", label: "Projects", icon: "*", url: projects)
        ].filter { Self.isReadableDirectory($0.url) }

        #if os(Windows)
        for drive in ["C:/", "D:/"] {
            let url = URL(fileURLWithPath: drive, isDirectory: true)
            if Self.isReadableDirectory(url) {
                let label = drive.hasPrefix("C") ? "Local Disk (C:)" : "Data (D:)"
                result.append(Place(section: "This PC", label: label, icon: "=", url: url))
            }
        }
        #else
        result.append(Place(section: "This PC", label: "Root", icon: "=", url: URL(fileURLWithPath: "/", isDirectory: true)))
        #endif

        return result
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    // MARK: - Formatting

    private func headerTitle(_ column: SortColumn) -> String {
        let title: String
        switch column {
        case .name: title = "Name"
        case .size: title = "Size"
        case .type: title = "Type"
        case .modified: title = "Modified"
        }
        if sortColumn != column { return title }
        return title + (sortAscending ? " ^" : " v")
    }

    private func itemIcon(_ item: BrowserItem) -> String {
        if item.isDirectory { return "[ ]" }
        return isDrawing(item.url) ? "[+]" : "[-]"
    }

    private func typeName(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        switch url.pathExtension.lowercased() {
        case "dxf": return "DXF Drawing"
        case "dwg": return "DWG Drawing"
        case "pdf": return "PDF"
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "tif", "tiff": return "Image"
        default: return url.pathExtension.isEmpty ? "File" : "\(url.pathExtension.uppercased()) File"
        }
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "-" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024.0)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func breadcrumbText(for url: URL) -> String {
        url.path.replacingOccurrences(of: "\\", with: " > ").replacingOccurrences(of: "/", with: " > ")
    }

    private func isDrawing(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "dxf" || ext == "dwg"
    }

    private func drawingStats(for url: URL) -> (layers: Int, entities: Int, units: String) {
        let seed = abs(url.path.hashValue)
        return (layers: 4 + seed % 18, entities: 900 + seed % 9500, units: "mm")
    }

    private func shortName(_ name: String, limit: Int) -> String {
        if name.count <= limit { return name }
        return String(name.prefix(max(1, limit - 3))) + "..."
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

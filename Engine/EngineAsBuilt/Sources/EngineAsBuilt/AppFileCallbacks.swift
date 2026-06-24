import EngineAsBuiltCore
import Foundation
import ImGui

// MARK: - AppFileCallbacks
//
// Configures file browser callbacks that handle opening and saving
// DXF and EAB (EngineAsBuilt) documents. These callbacks are invoked
// when the user selects a file from the native file dialog.
//
// Open: Opens the selected DXF file in a new tab and zooms to extents.
// Save: Saves the active tab to the chosen file path.

@MainActor
struct AppFileCallbacks {
    static func configure(on engine: PhrostEngine) {
        // Callback invoked when the user selects a file in the Open dialog.
        // Opens the DXF/EAB file in a new tab and fits the view to content.
        engine.fileBrowser.onFileSelected = { url in
            do {
                try engine.tabManager.openTab(url: url)
                engine.zoomExtents()
                print("DXF opened in new tab: \(url.lastPathComponent)")
            } catch {
                print("DXF import failed: \(error)")
            }
        }

        // Callback invoked when the user selects a destination in the Save As dialog.
        // Persists the active tab's document to the chosen path.
        engine.saveFileBrowser.onFileSelected = { url in
            do {
                try engine.tabManager.saveActiveTabAs(url: url)
                print("Saved as: \(url.lastPathComponent)")
            } catch {
                print("Save As failed: \(error)")
            }
        }
    }
}

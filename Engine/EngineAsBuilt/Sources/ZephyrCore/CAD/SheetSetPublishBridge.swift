import Foundation

// =========================================================================
// MARK: - Sheet set → publish bridge (Step 6: batch PDF of the whole set)
// -------------------------------------------------------------------------
// Converts a `SheetSet` to a name-based `PublishDSDJob`, the same tolerant
// shape `-PUBLISH` consumes, then the shared `PublishCLIRun.resolveSpec`
// + `PublishRunner` pipeline resolves rows against drawing metadata,
// publishes, and writes the CSV log beside the `.dst`.
// Row order is set display order; only sheets with `includeForPlot`
// inside publishing subsets become rows. Without an override every row
// keeps its native setup; with one every row requests it by name and
// drawings lacking it count unresolved (honest, like `-PUBLISH`).
// With a setup name alone it resolves per own drawing (`.namedLocal`).
// With an override *file* (SSM "Publish Using Page Setup Override",
// a `.dwt`/`.dxf` source) every row borrows from that file
// (`.importedMaster`, loaded through the shared metadata provider).
// A missing/unreadable master or an unknown setup name leaves honest
// unresolved rows via the shared pipeline's preflight — same as
// `-PUBLISH` — never a silent wrong-setup publish.
// =========================================================================

public enum SheetSetPublishBridge {
    /// Name-based job for `PublishCLIRun.resolveSpec`.
    public static func dsdJob(
        for set: SheetSet,
        setupOverride: String? = nil,
        overrideFile: String? = nil,
        outputDirectory: String? = nil
    ) -> PublishDSDJob {
        let override = setupOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let master = overrideFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var rows: [PublishDSDSheet] = []
        func displayName(for sheet: SheetSetSheet) -> String {
            let joined = [sheet.number, sheet.title]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !joined.isEmpty { return joined }
            if !sheet.layoutName.isEmpty { return sheet.layoutName }
            return ""
        }
        func append(_ sheet: SheetSetSheet) {
            guard sheet.includeForPlot else { return }
            rows.append(PublishDSDSheet(
                sourcePath: sheet.absoluteFile,
                tabName: sheet.layoutName,
                space: .layout,
                sheetName: displayName(for: sheet),
                defaultSetupName: "",
                assignMode: override.isEmpty ? .default : (master.isEmpty ? .namedLocal : .importedMaster),
                setupName: override,
                masterPath: master))
        }
        for sheet in set.sheets { append(sheet) }
        func walk(_ subsets: [SheetSetSubset], suspended: Bool) {
            for sub in subsets {
                let off = suspended || !sub.publishSheets
                for sheet in sub.sheets { if !off { append(sheet) } }
                walk(sub.subsets, suspended: off)
            }
        }
        walk(set.subsets, suspended: false)
        let outDir: String
        if let outputDirectory, !outputDirectory.isEmpty {
            outDir = outputDirectory
        } else if !set.dstPath.isEmpty {
            outDir = URL(fileURLWithPath: set.dstPath).deletingLastPathComponent().path
        } else {
            outDir = ""
        }
        return PublishDSDJob(
            publishTo: .pdf,
            outputDirectory: outDir,
            fileType: .multiSheetFile,
            namingPolicy: .autoName,
            targetFileName: set.name.isEmpty ? nil : "\(set.name).pdf",
            sheets: rows)
    }
}

import Foundation

// =========================================================================
// MARK: - Sheet set commands (Step 3: NEWSHEETSET / OPENSHEETSET /
// SHEETSET / SHEETSETHIDE — command-line-first flows; the ImGui palette
// behind SHEETSET arrives in Step 8)
// -------------------------------------------------------------------------
// NEWSHEETSET creates an in-memory set (AcSm XML writer = Step 2, so no
// `.dst` is written yet). OPENSHEETSET decodes a `.dst` with zero DWG
// opens and registers its sheets + MRU entries. SHEETSET prints the
// manager tree (headless stand-in for the palette); SHEETSETHIDE hides it.
// =========================================================================

extension CADCommandProcessor {
    /// Dispatch for the four sheet-set verbs. `text` is the raw command
    /// line (verb + args); `upper` is its uppercased form.
    public func runSheetSetCommand(text: String, upper: String, engine: PhrostEngine?) {
        let (verb, arg) = Self.sheetSetVerbAndArg(text: text, upper: upper)
        // Bare verbs that need operands open a pending prompted session;
        // each Space/Enter submits one operand (Space == Enter).
        switch verb {
        case "NEWSHEETSET", "OPENSHEETSET", "-PUBLISHSET", "-TRANSMITSET":
            if arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !_inPendingCompletion {
                startPendingPrompt(command: verb, engine: engine)
                return
            }
        default:
            break
        }
        switch verb {
        case "NEWSHEETSET":
            newSheetSet(arg: arg)
        case "OPENSHEETSET":
            openSheetSet(arg: arg, engine: engine)
        case "SHEETSET":
            showSheetSetManager(engine: engine)
        case "SHEETSETHIDE":
            SheetSetSysvars.managerOpen = false
            if let engine { engine.setPanel(\.sheetSetManagerActive, to: false) }
            print("[SheetSet] Sheet Set Manager hidden.")
        case "-PUBLISHSET":
            publishSet(arg: arg, engine: engine)
        case "-TRANSMITSET":
            transmitSet(arg: arg)
        default:
            print("[SheetSet] Unknown sheet set command.")
        }
        clearCommand()
    }

    private func newSheetSet(arg: String) {
        let args = Self.splitSheetSetArgs(arg)
        guard let name = args.first, !name.isEmpty else {
            print("[SheetSet] Usage: NEWSHEETSET <name> [dstPath]")
            return
        }
        let dstPath = args.count > 1 ? args[1] : ""
        if !dstPath.isEmpty, FileManager.default.fileExists(atPath: dstPath) {
            print("[SheetSet] '\(dstPath)' already exists; OPENSHEETSET it instead.")
            return
        }
        if sheetSetStore.openSets[dstPath] != nil {
            print("[SheetSet] A set with that path is already open.")
            return
        }
        let set = SheetSet(name: name, dstPath: dstPath)
        sheetSetStore.register(set)
        guard !dstPath.isEmpty else {
            print("[SheetSet] Created set '\(name)' (in memory; no path given).")
            return
        }
        SheetSetSysvars.lastFoundPath = dstPath
        do {
            let xml = try SheetSetXML.serialize(set)
            try SheetSetDST.encode(xml).write(to: URL(fileURLWithPath: dstPath), options: .atomic)
            print("[SheetSet] Created set '\(name)' → \(dstPath).")
        } catch {
            print("[SheetSet] Set created in memory; write failed: \(error.localizedDescription)")
        }
    }

    private func openSheetSet(arg: String, engine: PhrostEngine?) {
        let path = arg.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            guard let eng = engine else {
                print("[SheetSet] Usage: OPENSHEETSET <file.dst>")
                return
            }
            let window = eng.dialogParentWindow
            NativeFileDialog.showOpenDialog(
                window: window,
                filters: [NativeFileDialog.Filter(label: "Sheet Sets", extensions: ["dst"])],
                allowMultiple: false
            ) { [weak self, weak eng] urls in
                guard let self, eng != nil, let url = urls.first else { return }
                self.openSheetSetFile(at: url.path)
            }
            clearCommand()
            return
        }
        openSheetSetFile(at: path)
    }

    private func openSheetSetFile(at path: String) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let xml = try SheetSetDST.decode(data)
            let set = sheetSetStore.open(dstPath: path, xml: xml)
            let lock = sheetSetStore.lockStatus(dstPath: path)
            print("[SheetSet] Opened '\(set.name)': \(set.allSheetsInOrder.count) sheet(s).\(lock.locked ? " Locked: \(lock.detail ?? "")" : "")")
        } catch {
            print("[SheetSet] Open failed: \(error.localizedDescription)")
        }
    }

    private func publishSet(arg: String, engine: PhrostEngine?) {
        // Operand rule lives in `parsePublishSetArgs` (tested); a wrong
        // override fails loudly here, never publishes with wrong setups.
        let parsed = Self.parsePublishSetArgs(arg)
        if let error = parsed.error {
            print("[SheetSet] \(error)")
            clearCommand()
            return
        }
        let dstPath = parsed.dstPath
        let setup = parsed.setup
        let lastIsFile = parsed.overrideFile ?? ""
        guard let engine else {
            print("[SheetSet] \(Self.publishSetUsage)")
            return
        }
        let xml: String
        do {
            xml = try SheetSetDST.decode(try Data(contentsOf: URL(fileURLWithPath: dstPath)))
        } catch {
            print("[SheetSet] Publish failed: \(error.localizedDescription)")
            clearCommand()
            return
        }
        let set = sheetSetStore.open(dstPath: dstPath, xml: xml)
        let ctx = makePublishCliContext(engine: engine)
        let job = SheetSetPublishBridge.dsdJob(
            for: set,
            setupOverride: setup,
            overrideFile: lastIsFile.isEmpty ? nil : lastIsFile)
        let resolved = PublishCLIRun.resolveSpec(job: job, metadataProvider: ctx.metadataProvider)
        guard !resolved.spec.sheets.isEmpty else {
            print("[SheetSet] No plottable sheets in '\(set.name)'.")
            clearCommand()
            return
        }
        startCommand("-PUBLISHSET", prompt: "Publishing \(resolved.spec.sheets.count) sheet(s)...")
        ctx.publish(resolved.spec, dstPath) { [weak self] report, logURL in
            let ok = report.sheets.filter { $0.status == .ready }.count
            for sheet in report.sheets where sheet.status != .ready {
                print("\(sheet.sheetName): \(sheet.status.rawValue) — \(sheet.message)")
            }
            if report.outputURLs.isEmpty {
                print("[SheetSet] No files written: every sheet failed (\(ok)/\(report.sheets.count) ready).")
            } else if report.outputURLs.count == 1, let first = report.outputURLs.first {
                print("[SheetSet] Published \(ok)/\(report.sheets.count) sheets to \(first.path).")
            } else {
                print("[SheetSet] Published \(ok)/\(report.sheets.count) sheets to \(report.outputURLs.count) files.")
            }
            if !report.warnings.isEmpty {
                print("[SheetSet] \(report.warnings.count) warning(s).")
            }
            if let logURL {
                print("[SheetSet] Log: \(logURL.path).")
            }
            MainActor.assumeIsolated { self?.clearCommand() }
        }
    }

    /// `-TRANSMITSET`: foreground eTransmit-style archive. Copies the
    /// `.dst` byte-identical plus the in-scope member drawings into a
    /// package folder (tree under the `.dst` folder preserved), reporting
    /// locks, missing files, and copy failures per file without aborting.
    private func transmitSet(arg: String) {
        let parsed = Self.parseTransmitSetArgs(arg)
        if let error = parsed.error {
            print("[SheetSet] \(error)")
            clearCommand()
            return
        }
        let xml: String
        do {
            xml = try SheetSetDST.decode(try Data(contentsOf: URL(fileURLWithPath: parsed.dstPath)))
        } catch {
            print("[SheetSet] Transmit failed: \(error.localizedDescription)")
            clearCommand()
            return
        }
        let set = sheetSetStore.open(dstPath: parsed.dstPath, xml: xml)
        let lock = sheetSetStore.lockStatus(dstPath: parsed.dstPath)
        let plan = SheetSetTransmit.plan(set: set, scope: parsed.scope, dstLocked: lock.locked)
        if let scopeError = plan.scopeError {
            print("[SheetSet] \(scopeError) Nothing transmitted.")
            clearCommand()
            return
        }
        let report: SheetSetTransmit.TransmitReport
        do {
            report = try SheetSetTransmit.execute(plan: plan, to: URL(fileURLWithPath: parsed.folder))
        } catch {
            print("[SheetSet] Transmit failed: \(error.localizedDescription)")
            clearCommand()
            return
        }
        if lock.locked {
            print("[SheetSet] Set lock: \(lock.detail ?? "locked by another session").")
        }
        for result in report.results {
            switch result.outcome {
            case .copied(let fromLocked):
                if fromLocked {
                    let why: String
                    if case .locked(let detail) = result.file.lock { why = detail } else { why = "locked" }
                    print("\(result.file.relativePath): copied from locked source (\(why)).")
                }
            case .skippedMissing:
                let who = result.file.sheetLabel.map { " (\($0))" } ?? ""
                print("\(result.file.relativePath): skipped — source not found\(who).")
            case .failed(let reason):
                print("\(result.file.relativePath): FAILED — \(reason).")
            }
        }
        for label in plan.unresolved {
            print("[SheetSet] Unresolved sheet: \(label).")
        }
        print("[SheetSet] Transmitted \(report.copiedCount)/\(report.results.count) file(s) to \(report.packageFolder).")
        clearCommand()
    }

    /// SSLOCATE/SSMAUTOOPEN: after a drawing opens, locate its set and open it.
    /// Wired via TabManager.onDrawingOpened. NOD `AcSheetSetData` hint
    /// first (DXF/DWT only), MRU index as fallback.
    /// Silent on failure (a missing set must never break opening a drawing).
    public func autoOpenSheetSet(for dwgPath: String) {
        guard SheetSetSysvars.sslocate == 1, !dwgPath.isEmpty else { return }
        if let hint = SheetSetNODHint.readFile(atPath: dwgPath) {
            let dstPath = SheetSetNODHint.resolve(dstPath: hint.dstPath, relativeTo: dwgPath)
            if FileManager.default.fileExists(atPath: dstPath) {
                openSheetSet(at: dstPath)
                return
            }
        }
        guard let dstPath = sheetSetStore.locate(dwgPath: dwgPath) else { return }
        openSheetSet(at: dstPath)
    }

    private func openSheetSet(at dstPath: String) {
        if sheetSetStore.openSets[dstPath] == nil {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dstPath)),
                  let xml = try? SheetSetDST.decode(data) else { return }
            sheetSetStore.open(dstPath: dstPath, xml: xml)
        } else {
            sheetSetStore.currentDSTPath = dstPath
        }
        SheetSetSysvars.lastFoundPath = dstPath
        if SheetSetSysvars.ssmAutoOpen == 1 {
            SheetSetSysvars.managerOpen = true
        }
    }

    private func showSheetSetManager(engine: PhrostEngine?) {
        SheetSetSysvars.managerOpen = true
        if let engine {
            engine.setPanel(\.sheetSetManagerActive, to: true)
            return
        }
        guard let set = sheetSetStore.current else {
            print("[SheetSet] No sheet set open. Use NEWSHEETSET or OPENSHEETSET.")
            return
        }
        let lock = sheetSetStore.lockStatus(dstPath: set.dstPath)
        print("[SheetSet] '\(set.name)' (\(set.dstPath.isEmpty ? "unsaved" : set.dstPath)) — \(set.allSheetsInOrder.count) sheet(s)\(lock.locked ? " — LOCKED (\(lock.detail ?? ""))" : "")")
        for sheet in set.sheets {
            print("  \(sheet.number) \(sheet.title)\(sheet.includeForPlot ? "" : " [no plot]")")
        }
        func walk(_ subsets: [SheetSetSubset], depth: Int) {
            let pad = String(repeating: "  ", count: depth + 1)
            for sub in subsets {
                print("\(pad)[\(sub.name)]\(sub.publishSheets ? "" : " [publish off]")")
                for sheet in sub.sheets {
                    print("\(pad)  \(sheet.number) \(sheet.title)\(sheet.includeForPlot ? "" : " [no plot]")")
                }
                walk(sub.subsets, depth: depth + 1)
            }
        }
        walk(set.subsets, depth: 0)
        if !set.selections.isEmpty {
            print("  Selections: \(set.selections.map(\.name).joined(separator: ", "))")
        }
    }

    // MARK: - Parsing helpers (testable)

    static func sheetSetVerbAndArg(text: String, upper: String) -> (verb: String, arg: String) {
        for verb in ["NEWSHEETSET", "OPENSHEETSET", "SHEETSETHIDE", "SHEETSET", "-PUBLISHSET", "-TRANSMITSET"] {
            if upper == verb { return (verb, "") }
            if upper.hasPrefix(verb + " ") {
                let idx = text.index(text.startIndex, offsetBy: verb.count)
                return (verb, String(text[idx...]))
            }
        }
        return ("SHEETSET", text)
    }

    static let publishSetUsage =
        "Usage: -PUBLISHSET <file.dst> [setup override] [override file (.dwt/.dxf)]"

    /// Parsed `-PUBLISHSET` operands. `error` carries the user-facing
    /// message; a non-nil error means nothing may publish.
    struct PublishSetOperands {
        var dstPath: String
        var setup: String?
        var overrideFile: String?
        var error: String?
    }

    /// Operand rule (mirrors `publishSetUsage`): the trailing file counts
    /// as the override file only when a setup name precedes it. A lone
    /// trailing arg that is an existing file is rejected loudly — an
    /// override file without a setup name would otherwise publish with
    /// native setups, silently dropping the requested override. Relative
    /// override paths resolve against the `.dst` folder, not the process
    /// working directory.
    static func parsePublishSetArgs(_ arg: String) -> PublishSetOperands {
        let args = splitSheetSetArgs(arg)
        guard let dstPath = args.first, !dstPath.isEmpty else {
            return PublishSetOperands(dstPath: "", setup: nil, overrideFile: nil, error: publishSetUsage)
        }
        func fail(_ message: String) -> PublishSetOperands {
            PublishSetOperands(dstPath: dstPath, setup: nil, overrideFile: nil, error: message)
        }
        if args.count == 2 {
            let second = args[1]
            let resolved = SheetSetNODHint.resolve(dstPath: second, relativeTo: dstPath)
            if FileManager.default.fileExists(atPath: resolved) {
                return fail("Override file '\(second)' needs a setup name. \(publishSetUsage)")
            }
            let setup = second.trimmingCharacters(in: .whitespacesAndNewlines)
            return PublishSetOperands(
                dstPath: dstPath, setup: setup.isEmpty ? nil : setup,
                overrideFile: nil, error: nil)
        }
        if args.count > 2 {
            // Setup is exactly one token (quote multi-word names); the rest
            // is the file path, so unquoted paths with spaces still work.
            let setup = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let fileJoined = args[2...].joined(separator: " ")
            let resolved = SheetSetNODHint.resolve(dstPath: fileJoined, relativeTo: dstPath)
            guard FileManager.default.fileExists(atPath: resolved) else {
                return fail("Override file not found: \(fileJoined). Nothing published.")
            }
            return PublishSetOperands(
                dstPath: dstPath, setup: setup.isEmpty ? nil : setup,
                overrideFile: resolved, error: nil)
        }
        return PublishSetOperands(dstPath: dstPath, setup: nil, overrideFile: nil, error: nil)
    }

    /// Parsed `-TRANSMITSET` operands. `error` carries the user-facing
    /// message; a non-nil error means nothing may transmit.
    struct TransmitSetOperands {
        var dstPath: String
        var folder: String
        var scope: SheetSetTransmit.Scope
        var error: String?
    }

    /// Operand rule (mirrors `SheetSetTransmit.usage`): `<dst> <folder>`
    /// then an optional scope; extra tokens join with spaces so subset
    /// names with spaces work unquoted. A bare name without a scope prefix
    /// is rejected — guessing subset-vs-sheet would silently mistransmit.
    static func parseTransmitSetArgs(_ arg: String) -> TransmitSetOperands {
        let args = splitSheetSetArgs(arg)
        func fail(_ message: String) -> TransmitSetOperands {
            TransmitSetOperands(dstPath: args.first ?? "", folder: "", scope: .all, error: message)
        }
        guard args.count >= 2, !args[0].isEmpty, !args[1].isEmpty else {
            return fail(SheetSetTransmit.usage)
        }
        let scopeText = args.count > 2 ? args[2...].joined(separator: " ") : "*"
        guard let scope = SheetSetTransmit.parseScope(scopeText) else {
            return fail("Unknown scope '\(scopeText)'. \(SheetSetTransmit.usage)")
        }
        return TransmitSetOperands(dstPath: args[0], folder: args[1], scope: scope, error: nil)
    }

    /// Whitespace split honoring double quotes.
    static func splitSheetSetArgs(_ arg: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in arg {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace, !inQuotes {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Ribbon spec parser
// =========================================================================
//
// Turns the value of `(zephyr-ribbon)` into a validated `RibbonSpec`.
//
// Grammar (tags may be strings or symbols, and shorter forms are accepted):
//
//   ribbon   ("ribbon" menubar tabs)
//   menubar  ("menubar" (menu…))
//   menu     ("menu" title (entry…))
//   tabs     ("tabs" (tab…))
//   tab      ("tab" title (panel…))
//   panel    ("panel" title (item…))
//   entries  ("item" cmd label opts) | ("sep")
//            ("sub" title (entry…)) | ("drop" label (entry…))
//   items    ("big" cmd label icon opts) | ("small" …) | ("item" …) |
//            ("sep") | ("drop" label (item…))
//   opts     (("enable" pred…) ("check" pred…) ("tip" text))
//   preds    ("sel" n) ("nocmd") ("cmd" name) ("undo") ("redo")
//            ("dirty") ("var" name value) ("tabcount" n)
//
// Failures are loud (a malformed tag is an error, never a silent skip); a
// *valid* item naming a command this build does not have is dropped with a
// warning, so pasting an AutoCAD-shaped definition degrades gracefully.

/// Known command names, used to validate ribbon entries.
public struct RibbonCommandCatalog: Sendable, Equatable {
    public var known: Set<String>

    public init(known: Set<String> = []) {
        self.known = known
    }

    public func contains(_ command: String) -> Bool {
        known.contains(Self.canonical(command))
    }

    /// Uppercases, trims, and strips the AutoCAD global-command prefixes
    /// (`_.` / `_`). Scripted commands use the same normalization.
    public static func canonical(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if name.hasPrefix("_.") {
            name = String(name.dropFirst(2))
        } else if name.hasPrefix("_") {
            name = String(name.dropFirst(1))
        }
        return name
    }

    /// Catalog for the running app: every registered command (canonical name
    /// and aliases) plus the loaded AutoLISP `c:` routines.
    ///
    /// `lispFunctions` are environment function names, i.e. `"C:FOO"`.
    public static func fromCurrentApp(
        lispFunctions: Set<String> = []
    ) -> RibbonCommandCatalog {
        var known = Set<String>()
        for descriptor in CommandDescriptor.allCommands {
            known.insert(descriptor.canonicalName.uppercased())
            for alias in descriptor.aliases {
                known.insert(alias.uppercased())
            }
        }
        for name in lispFunctions {
            let upper = name.uppercased()
            if upper.hasPrefix("C:") {
                known.insert(String(upper.dropFirst(2)))
            }
        }
        return RibbonCommandCatalog(known: known)
    }
}

/// Successful parse plus everything the caller should tell the user.
public struct RibbonSpecParseResult: Sendable, Equatable {
    public var spec: RibbonSpec
    public var warnings: [String]

    public init(spec: RibbonSpec, warnings: [String] = []) {
        self.spec = spec
        self.warnings = warnings
    }
}

/// Parse failure with a user-facing message (printed to the command line by
/// the loader; the previous model stays live).
public struct RibbonSpecError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public enum RibbonSpecParser {

    /// Parses the value returned by `(zephyr-ribbon)`.
    public static func parse(
        _ value: LispValue,
        catalog: RibbonCommandCatalog = RibbonCommandCatalog()
    ) throws -> RibbonSpecParseResult {
        var context = Context(catalog: catalog)
        let spec = try context.parseRibbon(value)
        return RibbonSpecParseResult(spec: spec, warnings: context.warnings)
    }

    // MARK: - Parser state

    private struct Context {
        let catalog: RibbonCommandCatalog
        var warnings: [String] = []
        private var warnedIcons: Set<String> = []

        init(catalog: RibbonCommandCatalog) {
            self.catalog = catalog
        }

        // MARK: Root

        mutating func parseRibbon(_ value: LispValue) throws -> RibbonSpec {
            let list = try properList(
                value, "zephyr-ribbon must return a list, got \(value.prin1String)")
            guard !list.isEmpty else {
                throw RibbonSpecError(
                    "zephyr-ribbon returned an empty list; build it with "
                        + "(zr-ribbon menubar tabs)")
            }
            let head = tag(list[0]) ?? ""
            guard head == "ribbon" else {
                throw RibbonSpecError(
                    "zephyr-ribbon must return (zr-ribbon menubar tabs), "
                        + "got a list starting with \(list[0].prin1String)")
            }
            var menus: [RibbonMenu] = []
            var tabs: [RibbonTab] = []
            for section in list.dropFirst() {
                if section.isNil { continue }
                let sectionList = try properList(
                    section, "ribbon section must be a list, got \(section.prin1String)")
                switch tag(sectionList.first) ?? "" {
                case "menubar":
                    menus = try parseMenubar(sectionList)
                case "tabs":
                    tabs = try parseTabs(sectionList)
                case let other:
                    throw RibbonSpecError(
                        "unknown ribbon section \"\(other)\"; expected "
                            + "\"menubar\" or \"tabs\"")
                }
            }
            if menus.isEmpty && tabs.isEmpty {
                throw RibbonSpecError(
                    "ribbon definition contains no menus and no tabs")
            }
            return RibbonSpec(menus: menus, tabs: tabs)
        }

        // MARK: Menubar + tabs

        mutating func parseMenubar(_ section: [LispValue]) throws -> [RibbonMenu] {
            guard section.count > 1, !section[1].isNil else { return [] }
            let menuValues = try properList(
                section[1], "(zr-menubar …) expects a list of menus")
            var menus: [RibbonMenu] = []
            for value in menuValues {
                let list = try properList(value, "menu must be a list")
                guard tag(list.first) ?? "" == "menu" else {
                    throw RibbonSpecError(
                        "expected (zr-menu \"Title\" items), got "
                            + value.prin1String)
                }
                let title = try requireTitle(list, what: "menu")
                let entries = try parseEntries(
                    list.count > 2 ? list[2] : .nilValue,
                    context: "menu \"\(title)\"")
                menus.append(RibbonMenu(title: title, items: entries))
            }
            return menus
        }

        mutating func parseTabs(_ section: [LispValue]) throws -> [RibbonTab] {
            guard section.count > 1, !section[1].isNil else { return [] }
            let tabValues = try properList(
                section[1], "(zr-tabs …) expects a list of tabs")
            var tabs: [RibbonTab] = []
            var seen = Set<String>()
            for value in tabValues {
                let list = try properList(value, "tab must be a list")
                guard tag(list.first) ?? "" == "tab" else {
                    throw RibbonSpecError(
                        "expected (zr-tab \"Title\" panels), got "
                            + value.prin1String)
                }
                let title = try requireTitle(list, what: "tab")
                if !seen.insert(title.uppercased()).inserted {
                    warnings.append("duplicate tab \"\(title)\" ignored")
                    continue
                }
                var panels: [RibbonPanel] = []
                let panelValues = try properList(
                    list.count > 2 ? list[2] : .nilValue,
                    "tab \"\(title)\" expects a list of panels")
                for panelValue in panelValues {
                    let panelList = try properList(
                        panelValue, "panel must be a list")
                    guard tag(panelList.first) ?? "" == "panel" else {
                        throw RibbonSpecError(
                            "expected (zr-panel \"Title\" items), got "
                                + panelValue.prin1String)
                    }
                    let panelTitle = try requireTitle(
                        panelList, what: "panel")
                    let items = try parseItems(
                        panelList.count > 2 ? panelList[2] : .nilValue,
                        context: "panel \"\(panelTitle)\" in tab \"\(title)\"")
                    if items.isEmpty {
                        warnings.append(
                            "panel \"\(panelTitle)\" in tab \"\(title)\" "
                                + "has no usable items and was dropped")
                        continue
                    }
                    panels.append(RibbonPanel(title: panelTitle, items: items))
                }
                if panels.isEmpty {
                    warnings.append(
                        "tab \"\(title)\" has no usable panels and was dropped")
                    continue
                }
                tabs.append(RibbonTab(title: title, panels: panels))
            }
            return tabs
        }

        // MARK: Panels + menus share the entry vocabulary

        mutating func parseItems(
            _ value: LispValue, context: String
        ) throws -> [RibbonItem] {
            guard !value.isNil else { return [] }
            let values = try properList(
                value, "\(context): items must be a list")
            var items: [RibbonItem] = []
            for entry in values {
                let list = try properList(
                    entry, "\(context): each entry must be a list, got "
                        + entry.prin1String)
                switch tag(list.first) ?? "" {
                case "big", "large":
                    if let item = try parseCommand(
                        list, size: .large, iconSlot: true, context: context) {
                        items.append(item)
                    }
                case "small":
                    if let item = try parseCommand(
                        list, size: .small, iconSlot: true, context: context) {
                        items.append(item)
                    }
                case "item", "cmd", "command":
                    // Menu entries carry no icon column: (cmd label [opts]).
                    if let item = try parseCommand(
                        list, size: .small, iconSlot: false, context: context) {
                        items.append(item)
                    }
                case "sep", "separator":
                    items.append(.separator)
                case "drop", "sub":
                    let label = try requireTitle(list, what: "dropdown")
                    let children = try parseItems(
                        list.count > 2 ? list[2] : .nilValue,
                        context: "\(context) > \"\(label)\"")
                    guard !children.isEmpty else {
                        warnings.append(
                            "\(context): empty dropdown \"\(label)\" dropped")
                        break
                    }
                    // A flyout has no icon column of its own; the first
                    // command child's icon is the friendly default.
                    var icon: String?
                    for child in children {
                        if case let .command(first) = child {
                            icon = first.resolvedIconName
                            break
                        }
                    }
                    items.append(
                        .dropdown(
                            RibbonDropdown(label: label, icon: icon, items: children)))
                case let other:
                    throw RibbonSpecError(
                        "\(context): unknown item tag \"\(other)\"; expected "
                            + "\"big\", \"small\", \"item\", \"sep\" or \"drop\"")
                }
            }
            return items
        }

        /// Menu entries: same vocabulary as panel items.
        mutating func parseEntries(
            _ value: LispValue, context: String
        ) throws -> [RibbonItem] {
            try parseItems(value, context: context)
        }

        mutating func parseCommand(
            _ list: [LispValue], size: RibbonCommand.Size, iconSlot: Bool,
            context: String
        ) throws -> RibbonItem? {
            guard list.count >= 2, let rawCommand = text(list[1]) else {
                throw RibbonSpecError(
                    "\(context): \(size.rawValue) item is missing a command "
                        + "name (got \(list.first?.prin1String ?? "nil"))")
            }
            let canonical = RibbonCommandCatalog.canonical(rawCommand)
            guard !canonical.isEmpty else {
                throw RibbonSpecError("\(context): empty command name")
            }
            let label = (list.count > 2 ? text(list[2]) : nil)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? canonical
            let icon = (iconSlot && list.count > 3 ? text(list[3]) : nil)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .flatMap { $0.isEmpty ? nil : $0 }
            let optionsIndex = iconSlot ? 4 : 3
            let optionsValue = list.count > optionsIndex
                ? list[optionsIndex] : .nilValue

            var command = RibbonCommand(
                command: canonical,
                label: label,
                icon: icon,
                size: size)
            try applyOptions(optionsValue, to: &command, context: context)

            if let icon, !RibbonIconNames.isKnown(icon),
               warnedIcons.insert(icon).inserted {
                warnings.append(
                    "unknown icon \"\(icon)\" (used by \(canonical)); "
                        + "drawing a letter placeholder instead")
            }

            let validationKey = canonical.split(separator: " ", maxSplits: 1).first.map(String.init) ?? canonical
            guard catalog.contains(validationKey) else {
                warnings.append(
                    "\(context): command \"\(canonical)\" is not available in "
                        + "this build; item dropped")
                return nil
            }
            return .command(command)
        }

        // MARK: Options + predicates

        mutating func applyOptions(
            _ value: LispValue, to command: inout RibbonCommand, context: String
        ) throws {
            guard !value.isNil else { return }
            let options = try properList(
                value, "\(context): options must be a list")
            for option in options {
                let list = try properList(
                    option, "\(context): each option must be a list, got "
                        + option.prin1String)
                switch tag(list.first) ?? "" {
                case "enable":
                    command.enabled += try parsePredicates(
                        list, context: "\(context): enable")
                case "check":
                    command.checked += try parsePredicates(
                        list, context: "\(context): check")
                case "tip", "tooltip":
                    guard list.count > 1, let text = text(list[1]) else {
                        throw RibbonSpecError(
                            "\(context): (zr-tip …) needs a text argument")
                    }
                    command.tooltip = text
                case let other:
                    throw RibbonSpecError(
                        "\(context): unknown option \"\(other)\"; expected "
                            + "\"enable\", \"check\" or \"tip\"")
                }
            }
        }

        mutating func parsePredicates(
            _ option: [LispValue], context: String
        ) throws -> [RibbonPredicate] {
            let values = Array(option.dropFirst())
            guard !values.isEmpty else {
                throw RibbonSpecError(
                    "\(context): expected a predicate such as (zr-sel 1)")
            }
            return try values.map { try parsePredicate($0, context: context) }
        }

        mutating func parsePredicate(
            _ value: LispValue, context: String
        ) throws -> RibbonPredicate {
            let list = try properList(
                value, "\(context): predicate must be a list, got "
                    + value.prin1String)
            let name = tag(list.first) ?? ""
            switch name {
            case "sel", "selection":
                return .selectionAtLeast(try requireInt(list, context: context))
            case "nocmd", "no-command":
                return .noActiveCommand
            case "cmd", "command":
                guard list.count > 1, let raw = text(list[1]) else {
                    throw RibbonSpecError(
                        "\(context): (zr-cmd …) needs a command name")
                }
                return .activeCommand(RibbonCommandCatalog.canonical(raw))
            case "undo", "undoable":
                return .undoAvailable
            case "redo", "redoable":
                return .redoAvailable
            case "dirty":
                return .documentDirty
            case "var":
                guard list.count > 2, let raw = text(list[1]) else {
                    throw RibbonSpecError(
                        "\(context): (zr-var name value) needs a sysvar name "
                            + "and a value")
                }
                return .variableEquals(
                    name: RibbonCommandCatalog.canonical(raw), value: list[2])
            case "tabcount", "tabs":
                return .tabCountAtLeast(try requireInt(list, context: context))
            case let other:
                throw RibbonSpecError(
                    "\(context): unknown predicate \"\(other)\"; expected sel, "
                        + "nocmd, cmd, undo, redo, dirty, var or tabcount")
            }
        }

        // MARK: Value helpers

        func properList(
            _ value: LispValue, _ message: String
        ) throws -> [LispValue] {
            if value.isNil { return [] }
            guard let list = value.properList else {
                throw RibbonSpecError(message)
            }
            return list
        }

        func requireTitle(_ list: [LispValue], what: String) throws -> String {
            guard list.count > 1, let title = text(list[1]),
                  !title.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw RibbonSpecError(
                    "(zr-\(what) …) needs a title as its first argument")
            }
            return title
        }

        func requireInt(_ list: [LispValue], context: String) throws -> Int {
            guard list.count > 1 else {
                throw RibbonSpecError("\(context): expected a number")
            }
            switch list[1] {
            case let .int(value):
                return value
            case let .real(value) where value == value.rounded():
                return Int(value)
            default:
                throw RibbonSpecError(
                    "\(context): expected an integer, got \(list[1].prin1String)")
            }
        }

        /// Tag of a list head: strings and symbols both work, case-insensitive.
        func tag(_ value: LispValue?) -> String? {
            guard let value else { return nil }
            switch value {
            case let .string(text):
                return text.trimmingCharacters(in: .whitespaces).lowercased()
            case let .symbol(name):
                return name.trimmingCharacters(in: .whitespaces).lowercased()
            default:
                return nil
            }
        }

        /// Text of a value: strings and symbols both work.
        func text(_ value: LispValue?) -> String? {
            guard let value else { return nil }
            switch value {
            case let .string(text): return text
            case let .symbol(name): return name
            case let .int(number): return String(number)
            case let .real(number): return LispValue.formatReal(number)
            default: return nil
            }
        }
    }
}

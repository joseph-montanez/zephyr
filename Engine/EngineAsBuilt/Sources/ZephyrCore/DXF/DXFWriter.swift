import Foundation

public struct DXFLayoutDefinition: Sendable {
    public var name: String
    public var blockName: String
    public var tabOrder: Int
    public var minimumLimits: Vector3
    public var maximumLimits: Vector3

    public init(
        name: String,
        blockName: String,
        tabOrder: Int,
        minimumLimits: Vector3 = .zero,
        maximumLimits: Vector3 = Vector3(x: 12, y: 9, z: 0)
    ) {
        self.name = name
        self.blockName = blockName
        self.tabOrder = tabOrder
        self.minimumLimits = minimumLimits
        self.maximumLimits = maximumLimits
    }
}

/// Pure Swift DXF writer. Writes ASCII DXF files with proper section structure.
public class DXFWriter {

    public enum WriterError: Swift.Error {
        case writeError(String)
        case invalidEntity(String)
    }

    // MARK: - Configuration

    public var version: DXFVersion = .defaultExport
    public var codePage: String = "ANSI_1252"
    public var textCodec = DXFTextCodec()
    /// Header variables to write (populated by caller or defaults are used)
    public var headerVars: [String: Any] = [:]

    /// version >= R13 (AC1012)
    private var hasSubclassMarkers: Bool { return version.rawValue >= "AC1012" }
    /// version >= R2000 (AC1015)
    private var has24BitColor: Bool { return version.rawValue >= "AC1015" }
    /// version >= R2004 (AC1018)
    private var hasTransparency: Bool { return version.rawValue >= "AC1018" }
    /// version >= R2000
    private var hasLineWeight: Bool { return version.rawValue >= "AC1015" }
    /// version >= R2007 (AC1021)
    private var hasMaterials: Bool { return version.rawValue >= "AC1021" }
    /// version >= R14 (AC1014)
    private var hasExtendedData: Bool { return version.rawValue >= "AC1014" }
    /// version > R12 (AC1009)
    private var isModern: Bool { return version.rawValue != "AC1009" && version.rawValue != "AC1006" }

    // MARK: - Storage

    public var layers: [DXFLayerEntry] = []
    public var ltypes: [DXFLTypeEntry] = []
    public var dimstyles: [DXFDimstyleEntry] = []
    public var textstyles: [DXFStyleEntry] = []
    public var vports: [DXFVportEntry] = []
    public var appids: [DXFAppIdEntry] = []
    public var blockRecords: [DXFBlockRecordEntry] = []
    public var blocks: [DXFBlockEntity] = []
    public var entities: [DXFEntity] = []
    public var layouts: [DXFLayoutDefinition] = []
    public var preservedClasses: [DXFRawRecord] = []
    public var preservedTables: [DXFRawRecord] = []
    public var preservedObjects: [DXFRawRecord] = []
    public var preservedACDSData: [DataTableRawDXFGroup] = []

    // Handle tracking
    private var nextHandle: UInt32 = 1
    private var writingBlock: Bool = false
    private var currentBlockHandle: String = ""
    private var blockNameToHandle: [String: String] = [:]
    private var blockRecordHandleByName: [String: String] = [:]
    private var textStyleHandleByName: [String: String] = [:]
    private var layoutHandleByBlockName: [String: String] = [:]
    private var entityOwnerBlockNames: [String?] = []
    private var rootDictionaryHandle: String = ""
    private var groupDictionaryHandle: String = ""
    private var layoutDictionaryHandle: String = ""
    private var plotStyleDictionaryHandle: String = ""
    private var plotStyleNormalHandle: String = ""
    private var materialDictionaryHandle: String = ""
    private var materialByBlockHandle: String = ""
    private var materialByLayerHandle: String = ""
    private var materialGlobalHandle: String = ""
    private var imageDictionaryHandle: String = ""
    private var imageDefinitionHandleByEntity: [ObjectIdentifier: String] = [:]
    private var entityHandleByObject: [ObjectIdentifier: String] = [:]
    private var mleaderStyleDictionaryHandle: String = ""
    private var mleaderStyleHandleByName: [String: String] = [:]
    private var activeViewportHandleByBlockName: [String: String] = [:]
    private var outputLayouts: [DXFLayoutDefinition] = []

    public init() {}

    // MARK: - Public API

    public func addEntity(_ entity: DXFEntity, ownerBlockName: String? = nil) {
        entities.append(entity)
        while entityOwnerBlockNames.count < entities.count - 1 {
            entityOwnerBlockNames.append(nil)
        }
        entityOwnerBlockNames.append(
            ownerBlockName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? ownerBlockName
                : nil)
    }

    public func addLayer(_ layer: DXFLayerEntry) {
        layers.append(layer)
    }

    public func addLType(_ ltype: DXFLTypeEntry) {
        ltypes.append(ltype)
    }

    public func addDimstyle(_ ds: DXFDimstyleEntry) {
        dimstyles.append(ds)
    }

    public func addTextStyle(_ ts: DXFStyleEntry) {
        textstyles.append(ts)
    }

    public func addVPort(_ vp: DXFVportEntry) {
        vports.append(vp)
    }

    public func addAppId(_ app: DXFAppIdEntry) {
        appids.append(app)
    }

    public func addBlockRecord(_ br: DXFBlockRecordEntry) {
        blockRecords.append(br)
    }

    public func addBlock(_ block: DXFBlockEntity) {
        blocks.append(block)
    }

    public func addLayout(_ layout: DXFLayoutDefinition) {
        layouts.append(layout)
    }

    /// Write DXF file to path
    public func write(to path: String) throws {
        let content = buildDXF()
        let encoding = outputStringEncoding
        guard let data = content.data(using: encoding, allowLossyConversion: false) else {
            throw WriterError.writeError("Cannot encode DXF using \(textCodec.codePage)")
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Write DXF to string
    public func writeToString() -> String {
        return buildDXF()
    }

    // MARK: - DXF Builder

    private func buildDXF() -> String {
        nextHandle = max(1, preservedMaximumHandle() &+ 1)
        writingBlock = false
        currentBlockHandle = ""
        blockNameToHandle.removeAll(keepingCapacity: true)
        blockRecordHandleByName.removeAll(keepingCapacity: true)
        textStyleHandleByName.removeAll(keepingCapacity: true)
        layoutHandleByBlockName.removeAll(keepingCapacity: true)
        rootDictionaryHandle = ""
        groupDictionaryHandle = ""
        layoutDictionaryHandle = ""
        plotStyleDictionaryHandle = ""
        plotStyleNormalHandle = ""
        materialDictionaryHandle = ""
        materialByBlockHandle = ""
        materialByLayerHandle = ""
        materialGlobalHandle = ""
        imageDictionaryHandle = ""
        imageDefinitionHandleByEntity.removeAll(keepingCapacity: true)
        entityHandleByObject.removeAll(keepingCapacity: true)
        mleaderStyleDictionaryHandle = ""
        mleaderStyleHandleByName.removeAll(keepingCapacity: true)
        activeViewportHandleByBlockName.removeAll(keepingCapacity: true)
        outputLayouts = resolvedLayouts()
        prepareObjectHandles()

        var out = ""
        out.reserveCapacity(65536)

        writeHeader(&out)
        writeClasses(&out)
        writeTables(&out)
        writeBlocks(&out)
        writeEntities(&out)
        writeObjects(&out)
        writeACDSData(&out)

        // EOF
        out += "  0\r\nEOF\r\n"
        return out
    }

    // MARK: - Handles

    private func parsedHandle(_ value: String) -> UInt32? {
        UInt32(value.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16)
    }

    private func preservedMaximumHandle() -> UInt32 {
        var maximum: UInt32 = 0
        for entity in entities where entity.handle > maximum { maximum = entity.handle }
        for block in blocks {
            if block.handle > maximum { maximum = block.handle }
            for entity in block.entities where entity.handle > maximum { maximum = entity.handle }
        }
        for record in preservedTables + preservedObjects {
            for group in record.groups where group.code == 5 || group.code == 105 {
                if let handle = parsedHandle(group.value), handle > maximum {
                    maximum = handle
                }
            }
        }
        return maximum
    }

    private func entityHandle(_ entity: DXFEntity) -> String {
        if entity.handle != 0 { return String(format: "%X", entity.handle) }
        return allocHandle()
    }

    private func allocHandle() -> String {
        let h = nextHandle
        nextHandle += 1
        return String(format: "%X", h)
    }

    private func allocHandleU32() -> UInt32 {
        let h = nextHandle
        nextHandle += 1
        return h
    }

    private func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func normalizedHandle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func recordHandle(_ record: DXFRawRecord) -> String? {
        record.groups.first(where: { $0.code == 5 || $0.code == 105 })
            .map { normalizedHandle($0.value) }
            .flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
    }

    private func rawRecordName(_ record: DXFRawRecord) -> String {
        normalizedName(record.groups.first(where: { $0.code == 2 })?.value ?? "")
    }

    private func preservedTableHeader(named tableName: String) -> DXFRawRecord? {
        let key = normalizedName(tableName)
        return preservedTables.first {
            normalizedName($0.type) == "TABLE" && rawRecordName($0) == key
        }
    }

    private func preservedTableEntries(named tableName: String) -> [DXFRawRecord] {
        let key = normalizedName(tableName)
        return preservedTables.filter { normalizedName($0.type) == key }
    }

    private func preferredTableHandle(_ tableName: String) -> String {
        if let header = preservedTableHeader(named: tableName),
           let handle = recordHandle(header) {
            return handle
        }
        return allocHandle()
    }

    private func preferredTableRecordHandle(
        tableName: String,
        recordName: String,
        fallback: UInt32 = 0
    ) -> String {
        let nameKey = normalizedName(recordName)
        if let record = preservedTableEntries(named: tableName).first(where: {
            rawRecordName($0) == nameKey
        }), let handle = recordHandle(record) {
            return handle
        }
        if fallback != 0 { return String(format: "%X", fallback) }
        return allocHandle()
    }

    private func writeTableHeader(
        named tableName: String,
        handle: String,
        count: Int,
        _ out: inout String
    ) {
        if let raw = preservedTableHeader(named: tableName) {
            writeRawGroup(DataTableRawDXFGroup(code: 0, value: "TABLE"), &out)
            var wroteType = false
            var wroteHandle = false
            var wroteOwner = false
            var wroteCount = false
            for group in raw.groups {
                switch group.code {
                case 2:
                    writeStr(2, tableName, &out)
                    wroteType = true
                case 5:
                    writeStr(5, handle, &out)
                    wroteHandle = true
                case 330:
                    writeStr(330, "0", &out)
                    wroteOwner = true
                case 70:
                    writeInt(70, count, &out)
                    wroteCount = true
                default:
                    writeRawGroup(group, &out)
                }
            }
            if !wroteType { writeStr(2, tableName, &out) }
            if !wroteHandle { writeStr(5, handle, &out) }
            if !wroteOwner { writeStr(330, "0", &out) }
            if !wroteCount { writeInt(70, count, &out) }
            return
        }

        out += "  0\r\nTABLE\r\n"
        writeStr(2, tableName, &out)
        writeStr(5, handle, &out)
        writeStr(330, "0", &out)
        out += "100\r\nAcDbSymbolTable\r\n"
        if normalizedName(tableName) == "DIMSTYLE" {
            out += "100\r\nAcDbDimStyleTable\r\n"
        }
        writeInt(70, count, &out)
        if normalizedName(tableName) == "DIMSTYLE" { writeInt(71, 1, &out) }
    }

    private func missingPreservedTableEntries(
        tableName: String,
        excluding names: Set<String>
    ) -> [DXFRawRecord] {
        preservedTableEntries(named: tableName).filter {
            let name = rawRecordName($0)
            return !name.isEmpty && !names.contains(name)
        }
    }

    private func writePreservedTableRecord(
        _ record: DXFRawRecord,
        ownerHandle: String,
        _ out: inout String
    ) {
        writeRawGroup(DataTableRawDXFGroup(code: 0, value: record.type), &out)
        for group in record.groups {
            if group.code == 330 {
                writeRawGroup(DataTableRawDXFGroup(code: 330, value: ownerHandle), &out)
            } else {
                writeRawGroup(group, &out)
            }
        }
    }

    private func resolvedLayouts() -> [DXFLayoutDefinition] {
        var result: [DXFLayoutDefinition] = []
        var blockNames = Set<String>()

        for layout in layouts {
            let key = normalizedName(layout.blockName)
            guard !key.isEmpty, blockNames.insert(key).inserted else { continue }
            result.append(layout)
        }

        if !blockNames.contains("*MODEL_SPACE") {
            result.insert(
                DXFLayoutDefinition(
                    name: "Model",
                    blockName: "*Model_Space",
                    tabOrder: 0),
                at: 0)
            blockNames.insert("*MODEL_SPACE")
        }

        if !blockNames.contains("*PAPER_SPACE") {
            let usedNames = Set(result.map { normalizedName($0.name) })
            var layoutNumber = 1
            var layoutName = "Layout1"
            while usedNames.contains(normalizedName(layoutName)) {
                layoutNumber += 1
                layoutName = "Layout\(layoutNumber)"
            }
            let nextTabOrder = max(1, (result.map(\.tabOrder).max() ?? 0) + 1)
            result.append(
                DXFLayoutDefinition(
                    name: layoutName,
                    blockName: "*Paper_Space",
                    tabOrder: nextTabOrder))
        }

        return result
    }

    private func preservedRootDictionary() -> DXFRawRecord? {
        preservedObjects.first {
            let type = normalizedName($0.type)
            guard type == "DICTIONARY" || type == "ACDBDICTIONARYWDFLT" else { return false }
            return normalizedHandle($0.groups.first(where: { $0.code == 330 })?.value ?? "") == "0"
        }
    }

    private func preservedObject(withHandle handle: String?) -> DXFRawRecord? {
        guard let handle, !handle.isEmpty else { return nil }
        let key = normalizedHandle(handle)
        return preservedObjects.first { recordHandle($0) == key }
    }

    private func dictionaryEntries(_ record: DXFRawRecord?) -> [String: String] {
        guard let record else { return [:] }
        var result: [String: String] = [:]
        var pendingName: String?
        for group in record.groups {
            if group.code == 3 {
                pendingName = normalizedName(group.value)
            } else if (group.code == 350 || group.code == 360), let name = pendingName {
                let handle = normalizedHandle(group.value)
                if !name.isEmpty && !handle.isEmpty && handle != "0" {
                    result[name] = handle
                }
                pendingName = nil
            }
        }
        return result
    }

    private func preservedOrAllocatedHandle(_ preferred: String?) -> String {
        guard let preferred else { return allocHandle() }
        let handle = normalizedHandle(preferred)
        return handle.isEmpty || handle == "0" ? allocHandle() : handle
    }

    private func prepareObjectHandles() {
        guard isModern else { return }

        let rawRoot = preservedRootDictionary()
        let rootEntries = dictionaryEntries(rawRoot)
        rootDictionaryHandle = preservedOrAllocatedHandle(rawRoot.flatMap { recordHandle($0) })
        groupDictionaryHandle = preservedOrAllocatedHandle(rootEntries["ACAD_GROUP"])
        plotStyleDictionaryHandle = preservedOrAllocatedHandle(rootEntries["ACAD_PLOTSTYLENAME"])
        let plotStyleEntries = dictionaryEntries(preservedObject(withHandle: plotStyleDictionaryHandle))
        plotStyleNormalHandle = preservedOrAllocatedHandle(plotStyleEntries["NORMAL"])

        if hasMaterials {
            materialDictionaryHandle = preservedOrAllocatedHandle(rootEntries["ACAD_MATERIAL"])
            let materialEntries = dictionaryEntries(preservedObject(withHandle: materialDictionaryHandle))
            materialByBlockHandle = preservedOrAllocatedHandle(materialEntries["BYBLOCK"])
            materialByLayerHandle = preservedOrAllocatedHandle(materialEntries["BYLAYER"])
            materialGlobalHandle = preservedOrAllocatedHandle(materialEntries["GLOBAL"])
        }

        if !outputLayouts.isEmpty {
            layoutDictionaryHandle = preservedOrAllocatedHandle(rootEntries["ACAD_LAYOUT"])
            let layoutEntries = dictionaryEntries(preservedObject(withHandle: layoutDictionaryHandle))
            for layout in outputLayouts {
                let key = normalizedName(layout.blockName)
                guard layoutHandleByBlockName[key] == nil else { continue }
                layoutHandleByBlockName[key] = preservedOrAllocatedHandle(
                    layoutEntries[normalizedName(layout.name)])
            }
        }

        let allMLeaderEntities = entities.compactMap { $0 as? DXFMLeaderEntity }
            + blocks.flatMap { $0.entities.compactMap { $0 as? DXFMLeaderEntity } }
        let mleaderStyleNames = Set(allMLeaderEntities.map { leader -> String in
            let name = leader.styleName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Standard" : name
        })
        if !mleaderStyleNames.isEmpty {
            mleaderStyleDictionaryHandle = preservedOrAllocatedHandle(rootEntries["ACAD_MLEADERSTYLE"])
            let styleEntries = dictionaryEntries(preservedObject(withHandle: mleaderStyleDictionaryHandle))
            for name in mleaderStyleNames.sorted(by: {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }) {
                mleaderStyleHandleByName[normalizedName(name)] = preservedOrAllocatedHandle(
                    styleEntries[normalizedName(name)])
            }
        }

        let preservedImageDictionaryHandle = rootEntries["ACAD_IMAGE_DICT"]
        let imageEntries = dictionaryEntries(preservedObject(withHandle: preservedImageDictionaryHandle))
        if entities.contains(where: { $0 is DXFImageEntity }) {
            imageDictionaryHandle = preservedOrAllocatedHandle(preservedImageDictionaryHandle)
        }
        for entity in entities {
            entityHandleByObject[ObjectIdentifier(entity)] = entityHandle(entity)
            if let image = entity as? DXFImageEntity {
                let filename = image.imageFilePath
                let dictionaryName = (filename as NSString).deletingPathExtension
                imageDefinitionHandleByEntity[ObjectIdentifier(entity)] = preservedOrAllocatedHandle(
                    imageEntries[normalizedName(dictionaryName)])
            }
        }
        for block in blocks {
            for entity in block.entities {
                entityHandleByObject[ObjectIdentifier(entity)] = entityHandle(entity)
            }
        }
    }

    private func blockRecordHandle(for name: String) -> String? {
        blockRecordHandleByName[normalizedName(name)]
    }

    private func blockAttributeDefinitionHandle(
        blockName: String,
        tag: String,
        sourceHandle: UInt32
    ) -> String? {
        guard let block = blocks.first(where: {
            normalizedName($0.name) == normalizedName(blockName)
        }) else { return nil }
        let normalizedTag = normalizedName(tag)
        guard let definition = block.entities.compactMap({ $0 as? DXFTextEntity }).first(where: {
            $0.eType == .aTTDEF
                && ((sourceHandle != 0 && $0.handle == sourceHandle)
                    || (!normalizedTag.isEmpty && normalizedName($0.attributeTag) == normalizedTag))
        }) else { return nil }
        return entityHandleByObject[ObjectIdentifier(definition)]
    }

    private func entityOwnerBlockName(at index: Int, entity: DXFEntity) -> String {
        if index < entityOwnerBlockNames.count,
           let explicitOwner = entityOwnerBlockNames[index],
           !explicitOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitOwner
        }
        return entity.space == 0 ? "*Model_Space" : "*Paper_Space"
    }

    // MARK: - HEADER

    private func writeHeader(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nHEADER\r\n"

        let vers: String = {
            switch version {
            case .r10: return "AC1006"
            case .r12: return "AC1009"
            case .r13: return "AC1012"
            case .r14: return "AC1014"
            case .r2000: return "AC1015"
            case .r2004: return "AC1018"
            case .r2007: return "AC1021"
            case .r2010: return "AC1024"
            case .r2013: return "AC1027"
            case .r2018: return "AC1032"
            default: return "AC1032"
            }
        }()
        textCodec.setVersion(version)
        textCodec.setCodePage(codePage)

        let insBase = headerVars["$INSBASE"] as? Vector3 ?? .zero
        let extMin = headerVars["$EXTMIN"] as? Vector3 ?? .zero
        let extMax = headerVars["$EXTMAX"] as? Vector3 ?? Vector3(x: 1, y: 1, z: 0)
        let limMin = headerVars["$LIMMIN"] as? Vector3 ?? .zero
        let limMax = headerVars["$LIMMAX"] as? Vector3 ?? Vector3(x: 420, y: 297, z: 0)

        writeHdrStr("$ACADVER", vers, 1, &out)
        writeHdrStr("$DWGCODEPAGE", textCodec.codePage, 3, &out)
        writeHdrStr("$HANDSEED", "1000000", 5, &out)
        writeHdrCoord("$INSBASE", insBase.x, insBase.y, insBase.z, &out)
        writeHdrCoord("$EXTMIN", extMin.x, extMin.y, extMin.z, &out)
        writeHdrCoord("$EXTMAX", extMax.x, extMax.y, extMax.z, &out)
        writeHdrCoord("$LIMMIN", limMin.x, limMin.y, nil, &out)
        writeHdrCoord("$LIMMAX", limMax.x, limMax.y, nil, &out)
        writeHdrInt("$ORTHOMODE", 0, 70, &out)
        writeHdrInt("$REGENMODE", 1, 70, &out)
        writeHdrInt("$FILLMODE", 1, 70, &out)
        writeHdrInt("$QTEXTMODE", 0, 70, &out)
        writeHdrInt("$MIRRTEXT", 0, 70, &out)
        writeHdrDbl("$LTSCALE", 1.0, 40, &out)
        writeHdrInt("$ATTMODE", 1, 70, &out)
        writeHdrDbl("$TEXTSIZE", 2.5, 40, &out)
        writeHdrDbl("$TRACEWID", 0.05, 40, &out)
        writeHdrStr("$TEXTSTYLE", "Standard", 7, &out)
        writeHdrStr("$CLAYER", "0", 8, &out)
        writeHdrStr("$CELTYPE", "ByLayer", 6, &out)
        writeHdrInt("$CECOLOR", 256, 62, &out)
        writeHdrDbl("$CELTSCALE", 1.0, 40, &out)
        writeHdrInt("$DISPSILH", 0, 70, &out)
        writeHdrDbl("$DIMSCALE", 1.0, 40, &out)
        writeHdrDbl("$DIMASZ", 2.5, 40, &out)
        writeHdrDbl("$DIMEXO", 0.625, 40, &out)
        writeHdrDbl("$DIMEXE", 1.25, 40, &out)
        writeHdrDbl("$DIMDLI", 3.75, 40, &out)
        writeHdrDbl("$DIMRND", 0.0, 40, &out)
        writeHdrDbl("$DIMDLE", 0.0, 40, &out)
        writeHdrDbl("$DIMTP", 0.0, 40, &out)
        writeHdrDbl("$DIMTM", 0.0, 40, &out)
        writeHdrDbl("$DIMTXT", 2.5, 40, &out)
        writeHdrDbl("$DIMCEN", 2.5, 40, &out)
        writeHdrDbl("$DIMTSZ", 0.0, 40, &out)
        writeHdrDbl("$DIMALTF", 25.4, 40, &out)
        writeHdrDbl("$DIMLFAC", 1.0, 40, &out)
        writeHdrDbl("$DIMTVP", 0.0, 40, &out)
        writeHdrDbl("$DIMTFAC", 1.0, 40, &out)
        writeHdrDbl("$DIMGAP", 0.625, 40, &out)
        writeHdrDbl("$DIMALTRND", 0.0, 40, &out)
        writeHdrInt("$DIMTOL", 0, 70, &out)
        writeHdrInt("$DIMLIM", 0, 70, &out)
        writeHdrInt("$DIMTIH", 0, 70, &out)
        writeHdrInt("$DIMTOH", 0, 70, &out)
        writeHdrInt("$DIMSE1", 0, 70, &out)
        writeHdrInt("$DIMSE2", 0, 70, &out)
        writeHdrInt("$DIMTAD", 1, 70, &out)
        writeHdrInt("$DIMZIN", 8, 70, &out)
        writeHdrInt("$DIMAZIN", 0, 70, &out)
        writeHdrInt("$DIMALT", 0, 70, &out)
        writeHdrInt("$DIMALTD", 2, 70, &out)
        writeHdrInt("$DIMTOFL", 1, 70, &out)
        writeHdrInt("$DIMSAH", 0, 70, &out)
        writeHdrInt("$DIMTIX", 0, 70, &out)
        writeHdrInt("$DIMSOXD", 0, 70, &out)
        writeHdrInt("$DIMCLRD", 0, 70, &out)
        writeHdrInt("$DIMCLRE", 0, 70, &out)
        writeHdrInt("$DIMCLRT", 0, 70, &out)
        writeHdrInt("$DIMADEC", 0, 70, &out)
        writeHdrInt("$DIMDEC", 4, 70, &out)
        writeHdrInt("$DIMTDEC", 4, 70, &out)
        writeHdrInt("$DIMALTU", 2, 70, &out)
        writeHdrInt("$DIMALTTD", 2, 70, &out)
        writeHdrInt("$DIMAUNIT", 0, 70, &out)
        writeHdrInt("$DIMFRAC", 0, 70, &out)
        if isModern {
            writeHdrInt("$DIMLUNIT", 2, 70, &out)
        } else {
            writeHdrInt("$DIMUNIT", 2, 70, &out) // pre-2000 name
        }
        writeHdrInt("$DIMDSEP", 46, 70, &out)
        writeHdrInt("$DIMTMOVE", 0, 70, &out)
        writeHdrInt("$DIMJUST", 0, 70, &out)
        writeHdrInt("$DIMSD1", 0, 70, &out)
        writeHdrInt("$DIMSD2", 0, 70, &out)
        writeHdrInt("$DIMTOLJ", 1, 70, &out)
        writeHdrInt("$DIMTZIN", 0, 70, &out)
        writeHdrInt("$DIMALTZ", 0, 70, &out)
        writeHdrInt("$DIMALTTZ", 0, 70, &out)
        writeHdrInt("$DIMFIT", 3, 70, &out)
        writeHdrInt("$DIMUPT", 0, 70, &out)
        writeHdrInt("$DIMATFIT", 3, 70, &out)
        writeHdrInt("$DIMFXLON", 0, 70, &out)
        writeHdrDbl("$DIMFXL", 1.0, 40, &out)
        writeHdrStr("$DIMTXSTY", "Standard", 7, &out)
        writeHdrInt("$DIMLWD", -2, 70, &out)
        writeHdrInt("$DIMLWE", -2, 70, &out)
        writeHdrInt("$LUNITS", 2, 70, &out)
        writeHdrInt("$LUPREC", 4, 70, &out)
        writeHdrInt("$INSUNITS", headerVars["$INSUNITS"] as? Int ?? 4, 70, &out)
        writeHdrInt("$MEASUREMENT", headerVars["$MEASUREMENT"] as? Int ?? 1, 70, &out)
        writeHdrInt("$TILEMODE", 1, 70, &out)
        writeHdrInt("$PLINEGEN", 0, 70, &out)
        writeHdrStr("$CMLSTYLE", "Standard", 2, &out)

        // Write any custom header vars not already handled
        let written: Set<String> = [
            "$ACADVER", "$DWGCODEPAGE", "$HANDSEED", "$INSBASE", "$EXTMIN", "$EXTMAX",
            "$LIMMIN", "$LIMMAX", "$ORTHOMODE", "$REGENMODE", "$FILLMODE",
            "$QTEXTMODE", "$MIRRTEXT", "$LTSCALE", "$ATTMODE", "$TEXTSIZE",
            "$TRACEWID", "$TEXTSTYLE", "$CLAYER", "$CELTYPE", "$CECOLOR",
            "$CELTSCALE", "$DISPSILH",
            "$DIMSCALE", "$DIMASZ", "$DIMEXO", "$DIMEXE", "$DIMDLI",
            "$DIMRND", "$DIMDLE", "$DIMTP", "$DIMTM", "$DIMTXT", "$DIMCEN",
            "$DIMTSZ", "$DIMALTF", "$DIMLFAC", "$DIMTVP", "$DIMTFAC", "$DIMGAP",
            "$DIMALTRND", "$DIMTOL", "$DIMLIM", "$DIMTIH", "$DIMTOH", "$DIMSE1",
            "$DIMSE2", "$DIMTAD", "$DIMZIN", "$DIMAZIN", "$DIMALT", "$DIMALTD",
            "$DIMTOFL", "$DIMSAH", "$DIMTIX", "$DIMSOXD", "$DIMCLRD", "$DIMCLRE",
            "$DIMCLRT", "$DIMADEC", "$DIMDEC", "$DIMTDEC", "$DIMALTU", "$DIMALTTD",
            "$DIMAUNIT", "$DIMFRAC", "$DIMLUNIT", "$DIMUNIT", "$DIMDSEP",
            "$DIMTMOVE", "$DIMJUST", "$DIMSD1", "$DIMSD2", "$DIMTOLJ", "$DIMTZIN",
            "$DIMALTZ", "$DIMALTTZ", "$DIMFIT", "$DIMUPT", "$DIMATFIT", "$DIMFXLON",
            "$DIMFXL", "$DIMTXSTY", "$DIMLWD", "$DIMLWE",
            "$LUNITS", "$LUPREC", "$INSUNITS", "$MEASUREMENT", "$TILEMODE",
            "$PLINEGEN", "$CMLSTYLE"
        ]
        for (key, val) in headerVars {
            if written.contains(key) { continue }
            writeHdrValue(key, val, &out)
        }

        out += "  0\r\nENDSEC\r\n"
    }

    // MARK: - Header Write Helpers

    private func writeHdrStr(_ name: String, _ defaultVal: String, _ code: Int, _ out: inout String) {
        let val = headerVars[name] as? String ?? defaultVal
        out += "  9\r\n\(name)\r\n"
        out += String(format: "%3d\r\n", code)
        let enc = textCodec.fromUtf8(val)
        out += enc + "\r\n"
    }

    private func writeHdrInt(_ name: String, _ defaultVal: Int, _ code: Int, _ out: inout String) {
        let val = headerVars[name] as? Int ?? defaultVal
        out += "  9\r\n\(name)\r\n"
        out += String(format: "%3d\r\n%d\r\n", code, val)
    }

    private func writeHdrDbl(_ name: String, _ defaultVal: Double, _ code: Int, _ out: inout String) {
        let val = headerVars[name] as? Double ?? defaultVal
        out += "  9\r\n\(name)\r\n"
        out += String(format: "%3d\r\n", code)
        out += dxfFmt(val) + "\r\n"
    }

    private func writeHdrCoord(_ name: String, _ x: Double, _ y: Double, _ z: Double?, _ out: inout String) {
        let valX = (headerVars["\(name)_x"] as? Double) ?? x
        let valY = (headerVars["\(name)_y"] as? Double) ?? y
        let valZ = z != nil ? ((headerVars["\(name)_z"] as? Double) ?? z!) : nil
        out += "  9\r\n\(name)\r\n"
        out += " 10\r\n\(dxfFmt(valX))\r\n 20\r\n\(dxfFmt(valY))\r\n"
        if let vz = valZ { out += " 30\r\n\(dxfFmt(vz))\r\n" }
    }

    private func writeHdrValue(_ name: String, _ value: Any, _ out: inout String) {
        out += "  9\r\n\(name)\r\n"
        switch value {
        case let s as String:
            out += "  1\r\n\(textCodec.fromUtf8(s))\r\n"
        case let i as Int:
            let code = i < 1000 ? 70 : 90
            out += String(format: "%3d\r\n%d\r\n", code, i)
        case let d as Double:
            out += " 40\r\n\(dxfFmt(d))\r\n"
        case let v as Vector3:
            out += " 10\r\n\(dxfFmt(v.x))\r\n 20\r\n\(dxfFmt(v.y))\r\n 30\r\n\(dxfFmt(v.z))\r\n"
        default:
            out += "  1\r\n\(String(describing: value))\r\n"
        }
    }

    private func writeRawGroup(_ group: DataTableRawDXFGroup, _ out: inout String) {
        out += String(format: "%3d\r\n", group.code)
        out += group.value
        out += "\r\n"
    }

    private func writeRawRecord(_ record: DXFRawRecord, _ out: inout String) {
        writeRawGroup(DataTableRawDXFGroup(code: 0, value: record.type), &out)
        for group in record.groups { writeRawGroup(group, &out) }
    }

    private func tableCellText(_ cell: DataTableCell) -> (raw: String, display: String) {
        let value: String
        switch cell.value {
        case .string(let text): value = text
        case .number(let number): value = dxfFmt(number)
        case .integer(let integer): value = String(integer)
        case .boolean(let boolean): value = boolean ? "1" : "0"
        case .empty: value = ""
        }
        return (
            cell.formulaExpression ?? value,
            cell.cachedDisplayText ?? value)
    }

    private func tableAlignmentCode(
        horizontal: DataTableCellAlignment,
        vertical: DataTableCellVerticalAlignment
    ) -> Int {
        let horizontalOffset: Int
        switch horizontal {
        case .left: horizontalOffset = 0
        case .center: horizontalOffset = 1
        case .right: horizontalOffset = 2
        }
        let verticalOffset: Int
        switch vertical {
        case .top: verticalOffset = 1
        case .middle: verticalOffset = 4
        case .bottom: verticalOffset = 7
        }
        return verticalOffset + horizontalOffset
    }

    private func rewrittenTableCellGroups(
        _ template: [DataTableRawDXFGroup],
        cell: DataTableCell,
        column: DataTableColumn,
        table: DataTableData
    ) -> [DataTableRawDXFGroup] {
        var groups = template
        if groups.isEmpty {
            groups = [
                DataTableRawDXFGroup(code: 171, value: "1"),
                DataTableRawDXFGroup(code: 172, value: "0"),
                DataTableRawDXFGroup(code: 173, value: "0"),
                DataTableRawDXFGroup(code: 170, value: "4"),
                DataTableRawDXFGroup(code: 140, value: dxfFmt(table.textHeight)),
                DataTableRawDXFGroup(code: 301, value: "CELL_VALUE"),
                DataTableRawDXFGroup(code: 93, value: "4"),
                DataTableRawDXFGroup(code: 90, value: "4"),
                DataTableRawDXFGroup(code: 1, value: ""),
                DataTableRawDXFGroup(code: 94, value: "0"),
                DataTableRawDXFGroup(code: 300, value: ""),
                DataTableRawDXFGroup(code: 302, value: ""),
                DataTableRawDXFGroup(code: 304, value: "ACVALUE_END")
            ]
        }

        let horizontal = cell.horizontalAlignment ?? column.alignment
        let vertical = cell.verticalAlignment ?? .middle
        let alignment = tableAlignmentCode(horizontal: horizontal, vertical: vertical)
        let text = tableCellText(cell)
        var inValue = false
        var wroteRaw = false
        var wroteDisplay = false
        var wroteAlignment = false
        var wroteStyle = false
        var wroteHeight = false

        for index in groups.indices {
            let code = groups[index].code
            let marker = groups[index].value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if code == 301, marker == "CELL_VALUE" { inValue = true }
            if code == 304, marker == "ACVALUE_END" { inValue = false }

            if code == 170, !wroteAlignment {
                groups[index].value = String(alignment)
                wroteAlignment = true
            } else if code == 7, !wroteStyle, let style = table.textStyleName, !style.isEmpty {
                groups[index].value = textCodec.fromUtf8(style)
                wroteStyle = true
            } else if code == 140, !wroteHeight {
                groups[index].value = dxfFmt(table.textHeight)
                wroteHeight = true
            } else if inValue, code == 1, !wroteRaw {
                groups[index].value = textCodec.fromUtf8(text.raw)
                wroteRaw = true
            } else if inValue, code == 302, !wroteDisplay {
                groups[index].value = textCodec.fromUtf8(text.display)
                wroteDisplay = true
            }
        }

        if !wroteAlignment {
            let insertion = min(3, groups.count)
            groups.insert(DataTableRawDXFGroup(code: 170, value: String(alignment)), at: insertion)
        }
        if !wroteHeight {
            let insertion = min(4, groups.count)
            groups.insert(DataTableRawDXFGroup(code: 140, value: dxfFmt(table.textHeight)), at: insertion)
        }
        if !wroteStyle, let style = table.textStyleName, !style.isEmpty {
            let insertion = groups.firstIndex(where: { $0.code == 301 })
                ?? min(5, groups.count)
            groups.insert(
                DataTableRawDXFGroup(code: 7, value: textCodec.fromUtf8(style)),
                at: insertion)
        }

        let hasValueBlock = groups.contains {
            $0.code == 301
                && $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() == "CELL_VALUE"
        }
        if hasValueBlock {
            if !wroteRaw {
                let insertion = groups.firstIndex(where: { $0.code == 302 || $0.code == 304 })
                    ?? groups.endIndex
                groups.insert(
                    DataTableRawDXFGroup(code: 1, value: textCodec.fromUtf8(text.raw)),
                    at: insertion)
            }
            if !wroteDisplay {
                let insertion = groups.firstIndex(where: {
                    $0.code == 304
                        && $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                            .uppercased() == "ACVALUE_END"
                }) ?? groups.endIndex
                groups.insert(
                    DataTableRawDXFGroup(code: 302, value: textCodec.fromUtf8(text.display)),
                    at: insertion)
            }
        } else {
            groups.append(DataTableRawDXFGroup(code: 301, value: "CELL_VALUE"))
            groups.append(DataTableRawDXFGroup(code: 93, value: "4"))
            groups.append(DataTableRawDXFGroup(code: 90, value: "4"))
            groups.append(DataTableRawDXFGroup(code: 1, value: textCodec.fromUtf8(text.raw)))
            groups.append(DataTableRawDXFGroup(code: 94, value: "0"))
            groups.append(DataTableRawDXFGroup(code: 300, value: ""))
            groups.append(DataTableRawDXFGroup(code: 302, value: textCodec.fromUtf8(text.display)))
            groups.append(DataTableRawDXFGroup(code: 304, value: "ACVALUE_END"))
        }
        return groups
    }

    private func rewrittenTableContentRecord(
        _ record: DXFRawRecord,
        table: DataTableData
    ) -> DXFRawRecord {
        let flattenedCells = table.rows.flatMap { row in
            table.columns.indices.map { columnIndex in
                columnIndex < row.cells.count
                    ? row.cells[columnIndex]
                    : DataTableCell(columnID: table.columns[columnIndex].id)
            }
        }
        let templateCellCount = record.groups.reduce(into: 0) { count, group in
            if group.value.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() == "LINKEDTABLEDATACELL_BEGIN" {
                count += 1
            }
        }
        let canRewriteStructure = templateCellCount == flattenedCells.count

        let rowHeights = table.rows.indices.map { index in
            index < table.rowHeights.count && table.rowHeights[index] > 0
                ? table.rowHeights[index]
                : table.defaultRowHeight
        }
        let columnWidths = table.columns.map {
            $0.width > 0 ? $0.width : table.defaultColumnWidth
        }

        var result: [DataTableRawDXFGroup] = []
        result.reserveCapacity(record.groups.count)
        var currentCellIndex = -1
        var currentColumnIndex: Int?
        var currentRowIndex: Int?
        var inCellContent = false
        var inCellValue = false
        var wroteRawValue = false
        var wroteDisplayValue = false

        for index in record.groups.indices {
            let source = record.groups[index]
            let marker = source.value.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            var group = source

            if marker == "LINKEDTABLEDATACELL_BEGIN" {
                currentCellIndex += 1
                inCellContent = false
                inCellValue = false
                wroteRawValue = false
                wroteDisplayValue = false
            } else if marker == "CELLCONTENT_BEGIN" {
                inCellContent = true
            } else if marker == "CELLCONTENT_END" {
                inCellContent = false
                inCellValue = false
            } else if marker == "LINKEDTABLEDATACELL_END" {
                inCellContent = false
                inCellValue = false
            } else if marker == "TABLECOLUMN_BEGIN" {
                currentColumnIndex = nil
            } else if marker == "TABLECOLUMN_END" {
                currentColumnIndex = nil
            } else if marker == "TABLEROW_BEGIN" {
                currentRowIndex = nil
            } else if marker == "TABLEROW_END" {
                currentRowIndex = nil
            }

            if source.code == 90, currentColumnIndex == nil,
               result.last?.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() == "TABLECOLUMN_BEGIN" {
                currentColumnIndex = Int(source.value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if source.code == 90, currentRowIndex == nil,
                      result.last?.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        .uppercased() == "TABLEROW_BEGIN" {
                currentRowIndex = Int(source.value.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if canRewriteStructure,
               source.code == 90,
               index + 1 < record.groups.count,
               record.groups[index + 1].code == 300,
               record.groups[index + 1].value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() == "COLUMN" {
                group.value = String(table.columns.count)
            } else if canRewriteStructure,
                      source.code == 91,
                      index + 1 < record.groups.count,
                      record.groups[index + 1].code == 301,
                      record.groups[index + 1].value.trimmingCharacters(in: .whitespacesAndNewlines)
                        .uppercased() == "ROW" {
                group.value = String(table.rows.count)
            } else if source.code == 40,
                      let columnIndex = currentColumnIndex,
                      columnWidths.indices.contains(columnIndex) {
                group.value = dxfFmt(columnWidths[columnIndex])
            } else if source.code == 40,
                      let rowIndex = currentRowIndex,
                      rowHeights.indices.contains(rowIndex) {
                group.value = dxfFmt(rowHeights[rowIndex])
            }

            if inCellContent, source.code == 300, marker == "VALUE" {
                inCellValue = true
                wroteRawValue = false
                wroteDisplayValue = false
            }

            if inCellValue,
               flattenedCells.indices.contains(currentCellIndex) {
                let text = tableCellText(flattenedCells[currentCellIndex])
                if source.code == 1, !wroteRawValue {
                    group.value = textCodec.fromUtf8(text.raw)
                    wroteRawValue = true
                } else if source.code == 302, !wroteDisplayValue {
                    group.value = textCodec.fromUtf8(text.display)
                    wroteDisplayValue = true
                } else if source.code == 304, marker == "ACVALUE_END" {
                    if !wroteRawValue {
                        result.append(DataTableRawDXFGroup(
                            code: 1,
                            value: textCodec.fromUtf8(text.raw)))
                    }
                    if !wroteDisplayValue {
                        result.append(DataTableRawDXFGroup(
                            code: 302,
                            value: textCodec.fromUtf8(text.display)))
                    }
                    inCellValue = false
                }
            }

            result.append(group)
        }
        return DXFRawRecord(type: record.type, groups: result)
    }

    public func rewrittenTableObjectRecords(
        for table: DataTableData
    ) -> [DXFRawRecord] {
        guard let payload = table.nativeDXFPayload else { return [] }
        return (payload.referencedObjects ?? []).map { record in
            record.type.uppercased() == "TABLECONTENT"
                ? rewrittenTableContentRecord(record, table: table)
                : record
        }
    }

    private func rewrittenNativeTableGroups(
        table: DXFTableEntity,
        payload: DataTableNativeDXFPayload,
        ownerHandle: String?
    ) -> [DataTableRawDXFGroup] {
        var prefix: [DataTableRawDXFGroup] = []
        var tableBody: [DataTableRawDXFGroup] = []
        var inTable = false
        var subclass = ""
        var reachedEntitySubclass = false
        var reachedBlockReferenceSubclass = false

        let blockReferenceIndex = payload.rawGroups.firstIndex {
            $0.code == 100
                && $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() == "ACDBBLOCKREFERENCE"
        } ?? payload.rawGroups.endIndex
        let hasProxyChunks = payload.rawGroups[..<blockReferenceIndex].contains {
            $0.code == 310
        }
        let proxySize92Index = hasProxyChunks
            ? payload.rawGroups[..<blockReferenceIndex].firstIndex(where: { $0.code == 92 })
            : nil

        for (rawIndex, group) in payload.rawGroups.enumerated() {
            if group.code == 1001 { break }
            if group.code == 100 {
                subclass = group.value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if subclass == "ACDBENTITY" { reachedEntitySubclass = true }
                if subclass == "ACDBBLOCKREFERENCE" { reachedBlockReferenceSubclass = true }
                if subclass == "ACDBTABLE" { inTable = true }
            }
            if inTable {
                tableBody.append(group)
                continue
            }
            if group.code == 5 || group.code == 160 || group.code == 310
                || rawIndex == proxySize92Index {
                continue
            }
            var value = group.value
            if group.code == 330, !reachedEntitySubclass,
               let ownerHandle, !ownerHandle.isEmpty {
                value = ownerHandle
            } else if group.code == 8, reachedEntitySubclass, !reachedBlockReferenceSubclass {
                value = esc(layer: table.layer)
            } else if subclass == "ACDBBLOCKREFERENCE" {
                switch group.code {
                case 2: value = textCodec.fromUtf8(table.blockName)
                case 10: value = dxfFmt(table.insertion.x)
                case 20: value = dxfFmt(table.insertion.y)
                case 30: value = dxfFmt(table.insertion.z)
                default: break
                }
            }
            prefix.append(DataTableRawDXFGroup(code: group.code, value: value))
        }

        guard !tableBody.isEmpty else { return prefix }
        let firstCellIndex = tableBody.firstIndex(where: { $0.code == 171 }) ?? tableBody.endIndex
        let header = Array(tableBody[..<firstCellIndex])
        let rawCells = firstCellIndex < tableBody.endIndex
            ? Array(tableBody[firstCellIndex...])
            : []
        var templates: [[DataTableRawDXFGroup]] = []
        var current: [DataTableRawDXFGroup] = []
        for group in rawCells {
            if group.code == 171, !current.isEmpty {
                templates.append(current)
                current = []
            }
            current.append(group)
        }
        if !current.isEmpty { templates.append(current) }

        let rowCount = table.data.rows.count
        let columnCount = table.data.columns.count
        let rowHeights = (0..<rowCount).map { index in
            index < table.data.rowHeights.count && table.data.rowHeights[index] > 0
                ? table.data.rowHeights[index]
                : table.data.defaultRowHeight
        }
        let columnWidths = table.data.columns.map {
            $0.width > 0 ? $0.width : table.data.defaultColumnWidth
        }

        var rewrittenHeader: [DataTableRawDXFGroup] = []
        var wroteRows = false
        var wroteColumns = false
        var wroteRowHeights = false
        var wroteColumnWidths = false
        var headerSubclass = ""
        for group in header {
            if group.code == 100 {
                headerSubclass = group.value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            }
            if group.code == 91, !wroteRows {
                rewrittenHeader.append(DataTableRawDXFGroup(code: 91, value: String(rowCount)))
                wroteRows = true
            } else if group.code == 92, !wroteColumns {
                rewrittenHeader.append(DataTableRawDXFGroup(code: 92, value: String(columnCount)))
                wroteColumns = true
            } else if group.code == 141 {
                if !wroteRowHeights {
                    for height in rowHeights {
                        rewrittenHeader.append(DataTableRawDXFGroup(code: 141, value: dxfFmt(height)))
                    }
                    wroteRowHeights = true
                }
            } else if group.code == 142 {
                if !wroteColumnWidths {
                    for width in columnWidths {
                        rewrittenHeader.append(DataTableRawDXFGroup(code: 142, value: dxfFmt(width)))
                    }
                    wroteColumnWidths = true
                }
            } else if headerSubclass == "ACDBTABLE", group.code == 11 {
                rewrittenHeader.append(DataTableRawDXFGroup(code: 11, value: dxfFmt(table.horizontal.x)))
            } else if headerSubclass == "ACDBTABLE", group.code == 21 {
                rewrittenHeader.append(DataTableRawDXFGroup(code: 21, value: dxfFmt(table.horizontal.y)))
            } else if headerSubclass == "ACDBTABLE", group.code == 31 {
                rewrittenHeader.append(DataTableRawDXFGroup(code: 31, value: dxfFmt(table.horizontal.z)))
            } else if group.code == 343,
                      let recordHandle = blockRecordHandle(for: table.blockName) {
                rewrittenHeader.append(DataTableRawDXFGroup(code: 343, value: recordHandle))
            } else {
                rewrittenHeader.append(group)
            }
        }
        if !wroteRows { rewrittenHeader.append(DataTableRawDXFGroup(code: 91, value: String(rowCount))) }
        if !wroteColumns { rewrittenHeader.append(DataTableRawDXFGroup(code: 92, value: String(columnCount))) }
        if !wroteRowHeights {
            for height in rowHeights { rewrittenHeader.append(DataTableRawDXFGroup(code: 141, value: dxfFmt(height))) }
        }
        if !wroteColumnWidths {
            for width in columnWidths { rewrittenHeader.append(DataTableRawDXFGroup(code: 142, value: dxfFmt(width))) }
        }

        var result = prefix + rewrittenHeader
        var cellIndex = 0
        for row in table.data.rows {
            for columnIndex in table.data.columns.indices {
                let cell = columnIndex < row.cells.count
                    ? row.cells[columnIndex]
                    : DataTableCell(columnID: table.data.columns[columnIndex].id)
                let template = cell.nativeDXFGroups
                    ?? (cellIndex < templates.count ? templates[cellIndex] : templates.first)
                    ?? []
                result.append(contentsOf: rewrittenTableCellGroups(
                    template,
                    cell: cell,
                    column: table.data.columns[columnIndex],
                    table: table.data))
                cellIndex += 1
            }
        }
        return result
    }

    // MARK: - CLASSES

    private func writeClasses(_ out: inout String) {
        if !isModern { return }
        out += "  0\r\nSECTION\r\n  2\r\nCLASSES\r\n"
        if !outputLayouts.isEmpty {
            writeClass(
                dxfName: "LAYOUT",
                cppName: "AcDbLayout",
                appName: "ObjectDBX Classes",
                proxyFlags: 0,
                instanceCount: outputLayouts.count,
                wasProxy: 0,
                isEntity: 0,
                &out)
        }
        if entities.contains(where: { $0.eType == .iMAGE }) {
            writeClass(
                dxfName: "IMAGEDEF",
                cppName: "AcDbRasterImageDef",
                appName: "ISM",
                proxyFlags: 0,
                instanceCount: 0,
                wasProxy: 0,
                isEntity: 0,
                &out)
            writeClass(
                dxfName: "IMAGE",
                cppName: "AcDbRasterImage",
                appName: "ISM",
                proxyFlags: 2175,
                instanceCount: entities.filter { $0.eType == .iMAGE }.count,
                wasProxy: 0,
                isEntity: 1,
                &out)
        }
        let mleaderEntityCount = entities.filter { $0.eType == .mLEADER }.count
            + blocks.reduce(0) { count, block in
                count + block.entities.filter { $0.eType == .mLEADER }.count
            }
        if mleaderEntityCount > 0 {
            writeClass(
                dxfName: "MULTILEADER",
                cppName: "AcDbMLeader",
                appName: "ObjectDBX Classes",
                proxyFlags: 4095,
                instanceCount: mleaderEntityCount,
                wasProxy: 0,
                isEntity: 1,
                &out)
            writeClass(
                dxfName: "MLEADERSTYLE",
                cppName: "AcDbMLeaderStyle",
                appName: "ObjectDBX Classes",
                proxyFlags: 4095,
                instanceCount: mleaderStyleHandleByName.count,
                wasProxy: 0,
                isEntity: 0,
                &out)
        }
        if hasMaterials {
            writeClass(
                dxfName: "MATERIAL",
                cppName: "AcDbMaterial",
                appName: "ObjectDBX Classes",
                proxyFlags: 1153,
                instanceCount: 3,
                wasProxy: 0,
                isEntity: 0,
                &out)
        }
        let tableEntityCount = entities.filter { $0.eType == .tABLE }.count
            + blocks.reduce(0) { $0 + $1.entities.filter { $0.eType == .tABLE }.count }
        if tableEntityCount > 0 {
            writeClass(
                dxfName: "ACAD_TABLE",
                cppName: "AcDbTable",
                appName: "ObjectDBX Classes",
                proxyFlags: 1025,
                instanceCount: tableEntityCount,
                wasProxy: 0,
                isEntity: 1,
                &out)
        }

        var generatedClassNames = Set<String>()
        if !outputLayouts.isEmpty { generatedClassNames.insert("LAYOUT") }
        if entities.contains(where: { $0.eType == .iMAGE }) {
            generatedClassNames.formUnion(["IMAGEDEF", "IMAGE"])
        }
        if mleaderEntityCount > 0 {
            generatedClassNames.formUnion(["MULTILEADER", "MLEADERSTYLE"])
        }
        if hasMaterials { generatedClassNames.insert("MATERIAL") }
        if tableEntityCount > 0 { generatedClassNames.insert("ACAD_TABLE") }
        for record in preservedClasses {
            let dxfName = record.groups.first(where: { $0.code == 1 })?.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            guard !generatedClassNames.contains(dxfName) else { continue }
            writeRawRecord(record, &out)
        }
        out += "  0\r\nENDSEC\r\n"
    }

    private func writeClass(
        dxfName: String,
        cppName: String,
        appName: String,
        proxyFlags: Int,
        instanceCount: Int,
        wasProxy: Int,
        isEntity: Int,
        _ out: inout String
    ) {
        out += "  0\r\nCLASS\r\n"
        writeStr(1, dxfName, &out)
        writeStr(2, cppName, &out)
        writeStr(3, appName, &out)
        writeInt(90, proxyFlags, &out)
        writeInt(91, instanceCount, &out)
        writeInt(280, wasProxy, &out)
        writeInt(281, isEntity, &out)
    }

    // MARK: - TABLES

    private func writeTables(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nTABLES\r\n"

        writeVPortTable(&out)
        writeLTypeTable(&out)
        writeLayerTable(&out)
        writeStyleTable(&out)
        writeViewTable(&out)
        writeUCSTable(&out)
        writeAppIdTable(&out)
        writeDimStyleTable(&out)
        writeBlockRecordTable(&out)

        out += "  0\r\nENDSEC\r\n"
    }

    private func writeVPortTable(_ out: inout String) {
        let tableHandle = preferredTableHandle("VPORT")
        let generatedNames = Set(vports.map { normalizedName($0.name) })
        let preservedExtras = missingPreservedTableEntries(
            tableName: "VPORT",
            excluding: generatedNames)
        let usePreservedOnly = vports.isEmpty && !preservedExtras.isEmpty
        let vpCount = usePreservedOnly ? preservedExtras.count : max(vports.count, 1) + preservedExtras.count
        writeTableHeader(named: "VPORT", handle: tableHandle, count: vpCount, &out)

        if usePreservedOnly {
            for record in preservedExtras {
                writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
            }
        } else if vports.isEmpty {
            let h = preferredTableRecordHandle(tableName: "VPORT", recordName: "*ACTIVE")
            out += "  0\r\nVPORT\r\n"
            out += "  5\r\n\(h)\r\n"
            out += "330\r\n\(tableHandle)\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbViewportTableRecord\r\n"
            out += "  2\r\n*ACTIVE\r\n"
            out += " 70\r\n0\r\n"
            out += " 10\r\n0.0\r\n 20\r\n0.0\r\n"
            out += " 11\r\n1.0\r\n 21\r\n1.0\r\n"
            out += " 12\r\n286.0\r\n 22\r\n211.0\r\n"
            out += " 13\r\n0.0\r\n 23\r\n0.0\r\n"
            out += " 14\r\n10.0\r\n 24\r\n10.0\r\n"
            out += " 15\r\n10.0\r\n 25\r\n10.0\r\n"
            out += " 16\r\n0.0\r\n 26\r\n0.0\r\n 36\r\n1.0\r\n"
            out += " 17\r\n0.0\r\n 27\r\n0.0\r\n 37\r\n0.0\r\n"
            out += " 40\r\n297.0\r\n 41\r\n1.5\r\n 42\r\n50.0\r\n"
            out += " 43\r\n0.0\r\n 44\r\n0.0\r\n"
            out += " 50\r\n0.0\r\n 51\r\n0.0\r\n"
            out += " 71\r\n0\r\n 72\r\n100\r\n 73\r\n1\r\n 74\r\n3\r\n"
            out += " 75\r\n0\r\n 76\r\n1\r\n 77\r\n0\r\n 78\r\n0\r\n"
            out += "281\r\n0\r\n 65\r\n1\r\n"
            out += "110\r\n0.0\r\n120\r\n0.0\r\n130\r\n0.0\r\n"
            out += "111\r\n1.0\r\n121\r\n0.0\r\n131\r\n0.0\r\n"
            out += "112\r\n0.0\r\n122\r\n1.0\r\n132\r\n0.0\r\n"
            out += " 79\r\n0\r\n146\r\n0\r\n"
            out += " 60\r\n7\r\n 61\r\n5\r\n292\r\n1\r\n282\r\n1\r\n"
            out += "141\r\n0.0\r\n142\r\n0.0\r\n"
            out += " 63\r\n250\r\n421\r\n3358443\r\n"
        } else {
            for vp in vports {
                writeOneVPort(vp, ownerHandle: tableHandle, &out)
            }
        }
        if !usePreservedOnly {
            for record in preservedExtras {
                writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
            }
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeOneVPort(_ vp: DXFVportEntry, ownerHandle: String, _ out: inout String) {
        let handle = preferredTableRecordHandle(
            tableName: "VPORT",
            recordName: vp.name,
            fallback: vp.handle)
        out += "  0\r\nVPORT\r\n  5\r\n\(handle)\r\n330\r\n\(ownerHandle)\r\n"
        out += "100\r\nAcDbSymbolTableRecord\r\n100\r\nAcDbViewportTableRecord\r\n"
        writeStr(2, vp.name, &out)
        writeInt(70, vp.flags, &out)
        writePoint(10, vp.lowerLeft, &out)
        writePoint(11, vp.upperRight, &out)
        writePoint(12, vp.center, &out)
        writePoint(13, vp.snapBase, &out)
        writePoint(14, vp.snapSpacing, &out)
        writePoint(15, vp.gridSpacing, &out)
        writeCoord3(16, vp.viewDir, &out)
        writeCoord3(17, vp.viewTarget, &out)
        writeDbl(40, vp.height, &out)
        writeDbl(41, vp.ratio, &out)
        writeDbl(42, vp.lensHeight, &out)
        writeDbl(43, vp.frontClip, &out)
        writeDbl(44, vp.backClip, &out)
        writeDbl(50, vp.snapAngle, &out)
        writeDbl(51, vp.twistAngle, &out)
        writeInt(71, vp.viewMode, &out)
        writeInt(72, vp.circleZoom, &out)
        writeInt(73, vp.fastZoom, &out)
        writeInt(74, vp.ucsIcon, &out)
        writeInt(75, vp.snap, &out)
        writeInt(76, vp.grid, &out)
        writeInt(77, vp.snapStyle, &out)
        writeInt(78, vp.snapIsopair, &out)
        writeInt(60, vp.gridBehavior, &out)
    }

    private func writeLTypeTable(_ out: inout String) {
        var entries: [DXFLTypeEntry] = []
        var names = Set<String>()

        func append(_ entry: DXFLTypeEntry) {
            let key = normalizedName(entry.name)
            guard !key.isEmpty, names.insert(key).inserted else { return }
            entries.append(entry)
        }

        for name in ["ByBlock", "ByLayer", "Continuous"] {
            if let existing = ltypes.first(where: { normalizedName($0.name) == normalizedName(name) }) {
                append(existing)
            } else {
                let entry = DXFLTypeEntry()
                entry.name = name
                entry.desc = name == "Continuous" ? "Solid line" : ""
                append(entry)
            }
        }
        for entry in ltypes { append(entry) }

        let generatedNames = Set(entries.map { normalizedName($0.name) })
        let preservedExtras = missingPreservedTableEntries(tableName: "LTYPE", excluding: generatedNames)
        let tableHandle = preferredTableHandle("LTYPE")
        writeTableHeader(named: "LTYPE", handle: tableHandle, count: entries.count + preservedExtras.count, &out)

        for lt in entries {
            let handle = preferredTableRecordHandle(tableName: "LTYPE", recordName: lt.name, fallback: lt.handle)
            out += "  0\r\nLTYPE\r\n  5\r\n\(handle)\r\n"
            out += "330\r\n\(tableHandle)\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbLinetypeTableRecord\r\n"
            writeStr(2, lt.name, &out)
            writeInt(70, lt.flags, &out)
            writeStrAllowEmpty(3, lt.desc, &out)
            writeInt(72, 65, &out)
            writeInt(73, lt.path.count, &out)
            writeDbl(40, lt.path.reduce(0) { $0 + abs($1) }, &out)
            for p in lt.path {
                writeDbl(49, p, &out)
                if isModern { writeInt(74, 0, &out) }
            }
        }

        for record in preservedExtras {
            writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeLayerTable(_ out: inout String) {
        var entries: [DXFLayerEntry] = []
        var names = Set<String>()

        func append(_ entry: DXFLayerEntry) {
            let key = normalizedName(entry.name)
            guard !key.isEmpty, names.insert(key).inserted else { return }
            entries.append(entry)
        }

        if let existing = layers.first(where: { normalizedName($0.name) == "0" }) {
            append(existing)
        } else {
            let layer0 = DXFLayerEntry()
            layer0.name = "0"
            layer0.color = 7
            append(layer0)
        }
        for layer in layers { append(layer) }

        let generatedNames = Set(entries.map { normalizedName($0.name) })
        let preservedExtras = missingPreservedTableEntries(tableName: "LAYER", excluding: generatedNames)
        let tableHandle = preferredTableHandle("LAYER")
        writeTableHeader(named: "LAYER", handle: tableHandle, count: entries.count + preservedExtras.count, &out)

        for layer in entries {
            let handle = preferredTableRecordHandle(tableName: "LAYER", recordName: layer.name, fallback: layer.handle)
            out += "  0\r\nLAYER\r\n  5\r\n\(handle)\r\n"
            out += "330\r\n\(tableHandle)\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbLayerTableRecord\r\n"
            writeStr(2, layer.name, &out)
            writeInt(70, layer.flags, &out)
            writeInt(62, Int(layer.color), &out)
            if layer.color24 >= 0 { writeInt(420, Int(layer.color24), &out) }
            writeStr(6, layer.lineType, &out)
            if isModern {
                writeBool(290, layer.plotFlag, &out)
                writeInt(370, layer.lWeight.dxfInt, &out)
                writeStr(390, plotStyleNormalHandle, &out)
                if hasMaterials {
                    writeStr(347, materialGlobalHandle, &out)
                }
            }
            if hasTransparency, layer.transparency >= 0 {
                writeInt(440, Int(layer.transparency), &out)
                writeStr(1001, "AcCmTransparency", &out)
                writeInt(1071, Int(layer.transparency), &out)
            }
        }

        for record in preservedExtras {
            writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeStyleTable(_ out: inout String) {
        var entries: [DXFStyleEntry] = []
        var names = Set<String>()

        func append(_ entry: DXFStyleEntry) {
            let key = normalizedName(entry.name)
            guard !key.isEmpty, names.insert(key).inserted else { return }
            entries.append(entry)
        }

        if let existing = textstyles.first(where: { normalizedName($0.name) == "STANDARD" }) {
            append(existing)
        } else {
            let standard = DXFStyleEntry()
            standard.name = "Standard"
            append(standard)
        }
        for style in textstyles { append(style) }

        let generatedNames = Set(entries.map { normalizedName($0.name) })
        let preservedExtras = missingPreservedTableEntries(tableName: "STYLE", excluding: generatedNames)
        let tableHandle = preferredTableHandle("STYLE")
        writeTableHeader(named: "STYLE", handle: tableHandle, count: entries.count + preservedExtras.count, &out)

        for style in entries {
            let handle = preferredTableRecordHandle(tableName: "STYLE", recordName: style.name, fallback: style.handle)
            textStyleHandleByName[normalizedName(style.name)] = handle
            out += "  0\r\nSTYLE\r\n  5\r\n\(handle)\r\n"
            out += "330\r\n\(tableHandle)\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbTextStyleTableRecord\r\n"
            writeStr(2, style.name, &out)
            writeInt(70, style.flags, &out)
            writeDbl(40, style.height, &out)
            writeDbl(41, style.width, &out)
            writeDbl(50, style.oblique, &out)
            writeInt(71, style.genFlag, &out)
            writeDbl(42, style.lastHeight, &out)
            writeStr(3, style.font, &out)
            writeStr(4, style.bigFont, &out)
        }

        for record in preservedExtras {
            writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeViewTable(_ out: inout String) {
        let records = preservedTableEntries(named: "VIEW")
        let tableHandle = preferredTableHandle("VIEW")
        writeTableHeader(named: "VIEW", handle: tableHandle, count: records.count, &out)
        for record in records { writePreservedTableRecord(record, ownerHandle: tableHandle, &out) }
        out += "  0\r\nENDTAB\r\n"
    }

    private func writeUCSTable(_ out: inout String) {
        let records = preservedTableEntries(named: "UCS")
        let tableHandle = preferredTableHandle("UCS")
        writeTableHeader(named: "UCS", handle: tableHandle, count: records.count, &out)
        for record in records { writePreservedTableRecord(record, ownerHandle: tableHandle, &out) }
        out += "  0\r\nENDTAB\r\n"
    }

    private func writeAppIdTable(_ out: inout String) {
        var entries: [DXFAppIdEntry] = []
        var names = Set<String>()

        func append(_ entry: DXFAppIdEntry) {
            let key = normalizedName(entry.name)
            guard !key.isEmpty, names.insert(key).inserted else { return }
            entries.append(entry)
        }

        if let existing = appids.first(where: { normalizedName($0.name) == "ACAD" }) {
            append(existing)
        } else {
            let acad = DXFAppIdEntry()
            acad.name = "ACAD"
            append(acad)
        }
        if hasTransparency, layers.contains(where: { $0.transparency >= 0 }) {
            let transparency = DXFAppIdEntry()
            transparency.name = "AcCmTransparency"
            append(transparency)
        }
        for app in appids { append(app) }

        let generatedNames = Set(entries.map { normalizedName($0.name) })
        let preservedExtras = missingPreservedTableEntries(tableName: "APPID", excluding: generatedNames)
        let tableHandle = preferredTableHandle("APPID")
        writeTableHeader(named: "APPID", handle: tableHandle, count: entries.count + preservedExtras.count, &out)

        for app in entries {
            let handle = preferredTableRecordHandle(tableName: "APPID", recordName: app.name, fallback: app.handle)
            out += "  0\r\nAPPID\r\n  5\r\n\(handle)\r\n"
            out += "330\r\n\(tableHandle)\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbRegAppTableRecord\r\n"
            writeStr(2, app.name, &out)
            writeInt(70, app.flags, &out)
        }

        for record in preservedExtras {
            writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeDimStyleTable(_ out: inout String) {
        var entries: [DXFDimstyleEntry] = []
        var names = Set<String>()
        func append(_ entry: DXFDimstyleEntry) {
            let key = normalizedName(entry.name)
            guard !key.isEmpty, names.insert(key).inserted else { return }
            entries.append(entry)
        }
        if let existing = dimstyles.first(where: { normalizedName($0.name) == "STANDARD" }) {
            append(existing)
        } else {
            let standard = DXFDimstyleEntry()
            standard.name = "Standard"
            append(standard)
        }
        for style in dimstyles { append(style) }

        let generatedNames = Set(entries.map { normalizedName($0.name) })
        let preservedExtras = missingPreservedTableEntries(tableName: "DIMSTYLE", excluding: generatedNames)
        let tableHandle = preferredTableHandle("DIMSTYLE")
        writeTableHeader(named: "DIMSTYLE", handle: tableHandle, count: entries.count + preservedExtras.count, &out)

        for ds in entries {
            let handle = preferredTableRecordHandle(tableName: "DIMSTYLE", recordName: ds.name, fallback: ds.handle)
            out += "  0\r\nDIMSTYLE\r\n105\r\n\(handle)\r\n"
            out += "330\r\n\(tableHandle)\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbDimStyleTableRecord\r\n"
            writeStr(2, ds.name, &out)
            writeInt(70, ds.flags, &out)
            writeDbl(40, ds.dimscale, &out)
            writeDbl(41, ds.dimasz, &out)
            writeDbl(42, ds.dimexo, &out)
            writeDbl(43, ds.dimdli, &out)
            writeDbl(44, ds.dimexe, &out)
            writeDbl(45, ds.dimrnd, &out)
            writeDbl(46, ds.dimdle, &out)
            writeDbl(47, ds.dimtp, &out)
            writeDbl(48, ds.dimtm, &out)
            writeDbl(49, ds.dimfxl, &out)
            writeInt(71, ds.dimtol, &out)
            writeInt(72, ds.dimlim, &out)
            writeInt(73, ds.dimtih, &out)
            writeInt(74, ds.dimtoh, &out)
            writeInt(75, ds.dimse1, &out)
            writeInt(76, ds.dimse2, &out)
            writeInt(77, ds.dimtad, &out)
            writeInt(78, ds.dimzin, &out)
            writeInt(79, ds.dimazin, &out)
            writeDbl(140, ds.dimtxt, &out)
            writeDbl(141, ds.dimcen, &out)
            writeDbl(142, ds.dimtsz, &out)
            writeDbl(143, ds.dimaltf, &out)
            writeDbl(144, ds.dimlfac, &out)
            writeDbl(145, ds.dimtvp, &out)
            writeDbl(146, ds.dimtfac, &out)
            writeDbl(147, ds.dimgap, &out)
            writeDbl(148, ds.dimaltrnd, &out)
            writeInt(170, ds.dimalt, &out)
            writeInt(171, ds.dimaltd, &out)
            writeInt(172, ds.dimtofl, &out)
            writeInt(173, ds.dimsah, &out)
            writeInt(174, ds.dimtix, &out)
            writeInt(175, ds.dimsoxd, &out)
            writeInt(176, ds.dimclrd, &out)
            writeInt(177, ds.dimclre, &out)
            writeInt(178, ds.dimclrt, &out)
            writeInt(179, ds.dimadec, &out)
            writeInt(271, ds.dimdec, &out)
            writeInt(272, ds.dimtdec, &out)
            writeInt(273, ds.dimaltu, &out)
            writeInt(274, ds.dimalttd, &out)
            writeInt(275, ds.dimaunit, &out)
            writeInt(276, ds.dimfrac, &out)
            writeInt(277, ds.dimlunit, &out)
            writeInt(278, ds.dimdsep, &out)
            writeInt(279, ds.dimtmove, &out)
            writeInt(280, ds.dimjust, &out)
            writeInt(281, ds.dimsd1, &out)
            writeInt(282, ds.dimsd2, &out)
            writeInt(283, ds.dimtolj, &out)
            writeInt(284, ds.dimtzin, &out)
            writeInt(285, ds.dimaltz, &out)
            writeInt(286, ds.dimaltttz, &out)
            writeInt(287, ds.dimfit, &out)
            writeInt(288, ds.dimupt, &out)
            writeInt(289, ds.dimatfit, &out)
            writeInt(290, ds.dimfxlon, &out)
            let styleName = ds.dimtxsty.isEmpty ? "Standard" : ds.dimtxsty
            if let styleHandle = textStyleHandleByName[normalizedName(styleName)]
                ?? textStyleHandleByName["STANDARD"] {
                writeStr(340, styleHandle, &out)
            }
            if let leaderHandle = blockRecordHandle(for: ds.dimldrblk) {
                writeStr(341, leaderHandle, &out)
            }
            writeInt(371, ds.dimlwd, &out)
            writeInt(372, ds.dimlwe, &out)
        }

        for record in preservedExtras {
            writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeBlockRecordTable(_ out: inout String) {
        var entries: [DXFBlockRecordEntry] = []
        var names = Set<String>()

        func appendRecord(name: String, flags: Int = 0) {
            let key = normalizedName(name)
            guard !key.isEmpty, names.insert(key).inserted else { return }
            let record = DXFBlockRecordEntry()
            record.name = name
            record.flags = flags
            entries.append(record)
        }

        appendRecord(name: "*Model_Space")
        for layout in outputLayouts where normalizedName(layout.blockName) != "*MODEL_SPACE" {
            appendRecord(name: layout.blockName)
        }
        for record in blockRecords {
            let key = normalizedName(record.name)
            guard !key.isEmpty, names.insert(key).inserted else { continue }
            entries.append(record)
        }
        for block in blocks { appendRecord(name: block.name, flags: block.flags) }

        let generatedNames = Set(entries.map { normalizedName($0.name) })
        let preservedExtras = missingPreservedTableEntries(tableName: "BLOCK_RECORD", excluding: generatedNames)
        let tableHandle = preferredTableHandle("BLOCK_RECORD")
        writeTableHeader(named: "BLOCK_RECORD", handle: tableHandle, count: entries.count + preservedExtras.count, &out)

        for record in entries {
            let handle = preferredTableRecordHandle(
                tableName: "BLOCK_RECORD",
                recordName: record.name,
                fallback: record.handle)
            let key = normalizedName(record.name)
            blockRecordHandleByName[key] = handle
            out += "  0\r\nBLOCK_RECORD\r\n  5\r\n\(handle)\r\n"
            out += "330\r\n\(tableHandle)\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbBlockTableRecord\r\n"
            writeStr(2, record.name, &out)
            writeInt(70, record.flags, &out)
            writeInt(280, 1, &out)
            writeInt(281, 0, &out)
            if let layoutHandle = layoutHandleByBlockName[key] {
                writeStr(340, layoutHandle, &out)
            }
        }

        for record in preservedExtras {
            writePreservedTableRecord(record, ownerHandle: tableHandle, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    // MARK: - BLOCKS Section

    private func writeBlocks(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nBLOCKS\r\n"
        writingBlock = false

        func closeBlock() {
            guard writingBlock else { return }
            let endHandle = allocHandle()
            out += "  0\r\nENDBLK\r\n  5\r\n\(endHandle)\r\n"
            if isModern {
                out += "330\r\n\(currentBlockHandle)\r\n100\r\nAcDbEntity\r\n"
            }
            out += "  8\r\n0\r\n"
            if isModern { out += "100\r\nAcDbBlockEnd\r\n" }
            writingBlock = false
        }

        func openBlock(_ name: String, _ basePoint: Vector3, flags: Int = 0) {
            closeBlock()
            let blockHandle = allocHandle()
            let recordHandle = blockRecordHandle(for: name) ?? "0"
            currentBlockHandle = recordHandle
            blockNameToHandle[normalizedName(name)] = blockHandle
            out += "  0\r\nBLOCK\r\n  5\r\n\(blockHandle)\r\n"
            if isModern {
                out += "330\r\n\(recordHandle)\r\n100\r\nAcDbEntity\r\n"
            }
            out += "  8\r\n0\r\n"
            if isModern { out += "100\r\nAcDbBlockBegin\r\n" }
            writeStr(2, name, &out)
            writeInt(70, flags, &out)
            writePoint3(10, basePoint, &out)
            writeStr(3, name, &out)
            writeStrAllowEmpty(1, "", &out)
            writingBlock = true
        }

        var spaceNames = ["*Model_Space"]
        for layout in outputLayouts where normalizedName(layout.blockName) != "*MODEL_SPACE" {
            if !spaceNames.contains(where: { normalizedName($0) == normalizedName(layout.blockName) }) {
                spaceNames.append(layout.blockName)
            }
        }
        for name in spaceNames {
            openBlock(name, .zero)
            let spaceKey = normalizedName(name)
            if spaceKey != "*MODEL_SPACE" && spaceKey != "*PAPER_SPACE" {
                for (index, entity) in entities.enumerated() where
                    normalizedName(entityOwnerBlockName(at: index, entity: entity)) == spaceKey {
                    writeEntity(
                        entity,
                        &out,
                        ownerHandle: currentBlockHandle,
                        ownerBlockName: name)
                }
            }
            closeBlock()
        }

        let spaceKeys = Set(spaceNames.map(normalizedName))
        for block in blocks where !spaceKeys.contains(normalizedName(block.name)) {
            openBlock(block.name, block.basePoint, flags: block.flags)
            for entity in block.entities {
                writeEntity(entity, &out, ownerHandle: currentBlockHandle)
            }
            closeBlock()
        }

        out += "  0\r\nENDSEC\r\n"
    }

    // MARK: - ENTITIES Section

    private func writeEntities(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nENTITIES\r\n"

        for (index, entity) in entities.enumerated() {
            let blockName = entityOwnerBlockName(at: index, entity: entity)
            let blockKey = normalizedName(blockName)
            guard blockKey == "*MODEL_SPACE" || blockKey == "*PAPER_SPACE" else { continue }
            writeEntity(
                entity,
                &out,
                ownerHandle: blockRecordHandle(for: blockName),
                ownerBlockName: blockName)
        }

        out += "  0\r\nENDSEC\r\n"
    }

    private func writeEntity(
        _ e: DXFEntity,
        _ out: inout String,
        ownerHandle: String? = nil,
        ownerBlockName: String? = nil
    ) {
        let h = entityHandleByObject[ObjectIdentifier(e)] ?? allocHandle()
        if let viewport = e as? DXFViewportEntity,
           let ownerBlockName,
           viewport.vpID > 1 || activeViewportHandleByBlockName[normalizedName(ownerBlockName)] == nil {
            activeViewportHandleByBlockName[normalizedName(ownerBlockName)] = h
        }

        switch e.eType {
        case .pOINT:
            guard let pt = e as? DXFPointEntity else { return }
            writeEntityHeader("POINT", entity: pt, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbPoint\r\n"
            writePoint3(10, pt.basePoint, &out)
            writeDbl(39, pt.thickness_p, &out)

        case .lINE:
            guard let ln = e as? DXFLineEntity else { return }
            writeEntityHeader("LINE", entity: ln, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbLine\r\n"
            writePoint3(10, ln.basePoint, &out)
            writePoint3(11, ln.secPoint, &out)
            writeDbl(39, ln.thickness_p, &out)

        case .cIRCLE:
            guard let ci = e as? DXFCircleEntity else { return }
            writeEntityHeader("CIRCLE", entity: ci, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbCircle\r\n"
            writePoint3(10, ci.basePoint, &out)
            writeDbl(40, ci.radius, &out)
            writeDbl(39, ci.thickness_p, &out)

        case .aRC:
            guard let arc = e as? DXFArcEntity else { return }
            writeEntityHeader("ARC", entity: arc, handle: h, ownerHandle: ownerHandle, &out)
            if hasSubclassMarkers { out += "100\r\nAcDbCircle\r\n" }
            writePoint3(10, arc.basePoint, &out)
            writeDbl(40, arc.radius, &out)
            writeDbl(39, arc.thickness_p, &out)
            if hasSubclassMarkers { out += "100\r\nAcDbArc\r\n" }
            writeDbl(50, arc.startAngle * 180.0 / .pi, &out)  // radians → degrees
            writeDbl(51, arc.endAngle * 180.0 / .pi, &out)

        case .eLLIPSE:
            guard let el = e as? DXFEllipseEntity else { return }
            el.correctAxis()
            writeEntityHeader("ELLIPSE", entity: el, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbEllipse\r\n"
            writePoint3(10, el.basePoint, &out)
            writePoint3(11, el.secPoint, &out)
            writeDbl(40, el.ratio, &out)
            writeDbl(41, el.startParam, &out)
            writeDbl(42, el.endParam, &out)

        case .lWPOLYLINE:
            guard let lw = e as? DXFLWPolylineEntity else { return }
            writeEntityHeader("LWPOLYLINE", entity: lw, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbPolyline\r\n"
            writeInt(90, lw.vertices.count, &out)
            writeInt(70, lw.flags, &out)
            writeDbl(43, lw.width, &out)
            writeDbl(38, lw.elevation, &out)
            writeDbl(39, lw.thickness_p, &out)
            for v in lw.vertices {
                writeDbl(10, v.x, &out)
                writeDbl(20, v.y, &out)
                if v.startWidth != 0 { writeDbl(40, v.startWidth, &out) }
                if v.endWidth != 0 { writeDbl(41, v.endWidth, &out) }
                if v.bulge != 0 { writeDbl(42, v.bulge, &out) }
            }
            writeCoord3(210, lw.extPoint, &out)

        case .pOLYLINE:
            guard let pl = e as? DXFPolylineEntity else { return }
            writeEntityHeader("POLYLINE", entity: pl, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDb2dPolyline\r\n"
            writePoint3(10, pl.basePoint, &out)
            writeDbl(40, pl.defStartWidth, &out)
            writeDbl(41, pl.defEndWidth, &out)
            writeInt(70, pl.flags, &out)
            writeInt(71, pl.vertexCount, &out)
            writeInt(72, pl.faceCount, &out)
            writeInt(73, pl.smoothM, &out)
            writeInt(74, pl.smoothN, &out)
            writeInt(75, pl.curveType, &out)
            writeInt(66, 1, &out)
            for v in pl.vertices {
                writeVertex(v, ownerHandle: h, layer: pl.layer, &out)
            }
            let seqendHandle = allocHandle()
            out += "  0\r\nSEQEND\r\n  5\r\n\(seqendHandle)\r\n"
            if isModern { out += "330\r\n\(h)\r\n100\r\nAcDbEntity\r\n" }
            writeStr(8, esc(layer: pl.layer), &out)

        case .sPLINE:
            guard let sp = e as? DXFSplineEntity else { return }
            writeEntityHeader("SPLINE", entity: sp, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbSpline\r\n"
            writeCoord3(210, sp.normalVec, &out)
            writeInt(70, sp.flags, &out)
            writeInt(71, sp.degree, &out)
            writeInt(72, sp.knots.count, &out)
            writeInt(73, sp.controlPoints.count, &out)
            writeInt(74, sp.fitPoints.count, &out)
            writeDbl(42, sp.tolKnot, &out)
            writeDbl(43, sp.tolControl, &out)
            writeDbl(44, sp.tolFit, &out)
            for k in sp.knots { writeDbl(40, k, &out) }
            for w in sp.weights { writeDbl(41, w, &out) }
            for cp in sp.controlPoints { writePoint3(10, cp, &out) }
            for fp in sp.fitPoints { writePoint3(11, fp, &out) }
            if !sp.fitPoints.isEmpty {
                writePoint3(12, sp.tgStart, &out)
                writePoint3(13, sp.tgEnd, &out)
            }

        case .tEXT:
            guard let tx = e as? DXFTextEntity else { return }
            writeEntityHeader("TEXT", entity: tx, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbText\r\n"
            writePoint3(10, tx.basePoint, &out)
            writeDbl(40, tx.height, &out)
            writeStr(1, tx.text, &out)
            writeDbl(50, tx.angle_p, &out)  // degrees
            writeDbl(41, tx.widthScale, &out)
            writeDbl(51, tx.oblique, &out)
            writeStr(7, tx.style, &out)
            writeInt(71, tx.textGen, &out)
            writeInt(72, tx.alignH, &out)
            out += "100\r\nAcDbText\r\n"
            if tx.alignH != 0 || tx.alignV != 0 {
                writePoint3(11, tx.secPoint, &out)
            }
            writeInt(73, tx.alignV, &out)

        case .mTEXT:
            guard let mt = e as? DXFMTextEntity else { return }
            writeEntityHeader("MTEXT", entity: mt, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbMText\r\n"
            writePoint3(10, mt.basePoint, &out)
            writeDbl(40, mt.height, &out)
            writeDbl(41, mt.widthScale, &out)
            writeDbl(44, mt.interlin, &out)
            writeInt(73, mt.lineSpacingStyle, &out)
            writeDbl(50, mt.angle_p, &out)  // degrees
            writeInt(71, mt.textGen, &out)  // attachment
            writeInt(72, mt.alignH, &out)   // drawing direction
            writeMTextString(mt.text, &out)
            writeStr(7, mt.style, &out)

        case .iNSERT:
            guard let ins = e as? DXFInsertEntity else { return }
            writeEntityHeader("INSERT", entity: ins, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbBlockReference\r\n"
            writeStr(2, ins.name, &out)
            writePoint3(10, ins.basePoint, &out)
            writeDbl(41, ins.xScale, &out)
            writeDbl(42, ins.yScale, &out)
            writeDbl(43, ins.zScale, &out)
            writeDbl(50, ins.angle * 180.0 / .pi, &out)  // radians → degrees
            writeInt(70, ins.colCount, &out)
            writeInt(71, ins.rowCount, &out)
            writeDbl(44, ins.colSpace, &out)
            writeDbl(45, ins.rowSpace, &out)

        case .sOLID:
            guard let sd = e as? DXFSolidEntity else { return }
            writeEntityHeader("SOLID", entity: sd, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbTrace\r\n"
            writePoint3(10, sd.basePoint, &out)
            writePoint3(11, sd.secPoint, &out)
            writePoint3(12, sd.thirdPoint, &out)
            writePoint3(13, sd.fourPoint, &out)

        case .tRACE:
            guard let tr = e as? DXFTraceEntity else { return }
            writeEntityHeader("TRACE", entity: tr, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbTrace\r\n"
            writePoint3(10, tr.basePoint, &out)
            writePoint3(11, tr.secPoint, &out)
            writePoint3(12, tr.thirdPoint, &out)
            writePoint3(13, tr.fourPoint, &out)

        case .e3DFACE:
            guard let f3 = e as? DXF3DFaceEntity else { return }
            writeEntityHeader("3DFACE", entity: f3, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbFace\r\n"
            writePoint3(10, f3.basePoint, &out)
            writePoint3(11, f3.secPoint, &out)
            writePoint3(12, f3.thirdPoint, &out)
            writePoint3(13, f3.fourPoint, &out)
            writeInt(70, f3.invisibleFlag, &out)

        case .xLINE:
            guard let xl = e as? DXFXLineEntity else { return }
            writeEntityHeader("XLINE", entity: xl, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbXline\r\n"
            writePoint3(10, xl.basePoint, &out)
            let xlDir = unitize(xl.secPoint)
            writePoint3(11, xlDir, &out)

        case .rAY:
            guard let ry = e as? DXFRayEntity else { return }
            writeEntityHeader("RAY", entity: ry, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbRay\r\n"
            writePoint3(10, ry.basePoint, &out)
            let ryDir = unitize(ry.secPoint)
            writePoint3(11, ryDir, &out)

        case .dIMENSION:
            guard let dm = e as? DXFDimensionEntity else { return }
            writeEntityHeader("DIMENSION", entity: dm, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbDimension\r\n"
            writeStr(2, dm.name, &out)
            writeStr(3, dm.style, &out)
            writeInt(70, dm.type, &out)
            writePoint3(10, dm.defPoint, &out)
            writePoint3(11, dm.textPoint, &out)
            writeDbl(41, dm.lineFactor, &out)
            writeDbl(53, dm.rot, &out)
            writeCoord3(210, dm.extPoint, &out)
            writeStr(1, dm.text, &out)
            writeInt(71, dm.align, &out)
            writeInt(72, dm.lineStyle, &out)

        case .lEADER:
            guard let ld = e as? DXFLeaderEntity else { return }
            writeEntityHeader("LEADER", entity: ld, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbLeader\r\n"
            writeStr(3, ld.style, &out)
            writeInt(71, ld.arrow, &out)
            writeInt(72, ld.leaderType, &out)
            writeInt(73, ld.flag, &out)
            writeInt(74, ld.hookLine, &out)
            writeInt(75, ld.hookFlag, &out)
            writeDbl(40, ld.textHeight, &out)
            writeDbl(41, ld.textWidth, &out)
            writeInt(76, ld.vertices.count, &out)
            writeInt(77, ld.colorUse, &out)
            for v in ld.vertices { writePoint3(10, v, &out) }
            if let annotation = ld.annotation,
               let annotationHandle = entityHandleByObject[ObjectIdentifier(annotation)] {
                writeStr(340, annotationHandle, &out)
            } else if ld.annotHandle != 0 {
                writeStr(340, String(ld.annotHandle, radix: 16).uppercased(), &out)
            }
            writeCoord3(210, ld.extrusionPoint, &out)

        case .mLEADER:
            guard let ml = e as? DXFMLeaderEntity else { return }
            writeEntityHeader("MULTILEADER", entity: ml, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbMLeader\r\n"
            writeInt(270, 2, &out)
            writeStr(300, "CONTEXT_DATA{", &out)
            writeDbl(40, ml.contentScale, &out)
            writePoint3(10, ml.contentBasePosition ?? ml.textPosition, &out)
            writeDbl(41, ml.textHeight, &out)
            writeDbl(140, ml.arrowSize, &out)
            writeDbl(145, ml.landingGap, &out)
            writeInt(174, ml.textAngleType, &out)
            writeInt(175, ml.textAlignment, &out)
            writeInt(176, 0, &out)
            writeInt(177, 1, &out)

            let hasMText = ml.contentType == 2 && !ml.text.isEmpty
            writeInt(290, hasMText ? 1 : 0, &out)
            if hasMText {
                writeStr(304, ml.text, &out)
                writePoint3(11, Vector3(x: 0, y: 0, z: 1), &out)
                writeStr(340, textStyleHandleByName[normalizedName(ml.textStyleName)]
                    ?? textStyleHandleByName["STANDARD"]
                    ?? "0", &out)
                writePoint3(12, ml.textPosition, &out)
                writePoint3(13, ml.textDirection, &out)
                writeDbl(42, ml.textRotation, &out)
                writeDbl(43, ml.textWidth, &out)
                writeDbl(45, 1.0, &out)
                writeInt(170, 1, &out)
                writeInt(171, ml.textAttachment, &out)
                writeInt(172, ml.textFlowDirection, &out)
                writeInt(291, 0, &out)
                writeInt(292, 0, &out)
                writeInt(173, 0, &out)
                writeInt(293, 0, &out)
                writeInt(294, ml.textDirectionNegative ? 1 : 0, &out)
                writeInt(295, 0, &out)
            }

            let hasBlock = ml.contentType == 1 && !ml.blockName.isEmpty
            writeInt(296, hasBlock ? 1 : 0, &out)
            if hasBlock, let blockHandle = blockRecordHandle(for: ml.blockName) {
                writeStr(341, blockHandle, &out)
                writePoint3(15, ml.textPosition, &out)
                writePoint3(16, Vector3(
                    x: ml.blockScale,
                    y: ml.blockScale,
                    z: ml.blockScale), &out)
                writeDbl(46, ml.blockRotation, &out)
            }

            writePoint3(110, .zero, &out)
            writePoint3(111, Vector3(x: 1, y: 0, z: 0), &out)
            writePoint3(112, Vector3(x: 0, y: 1, z: 0), &out)
            writeInt(297, 0, &out)

            for (branchIndex, branch) in ml.branches.enumerated()
                where branch.vertices.count >= 2 {
                guard let lastPoint = branch.vertices.last else { continue }
                var direction = branch.doglegDirection?.normalized ?? Vector3(
                    x: ml.textPosition.x >= lastPoint.x ? 1 : -1,
                    y: 0,
                    z: 0)
                if direction.magnitudeSquared <= 1e-18 {
                    direction = Vector3(x: 1, y: 0, z: 0)
                }

                writeStr(302, "LEADER{", &out)
                writeInt(290, ml.landingEnabled ? 1 : 0, &out)
                writeInt(291, ml.doglegEnabled ? 1 : 0, &out)
                writePoint3(10, lastPoint, &out)
                writePoint3(11, direction, &out)
                let leaderLineIndex = branch.leaderLineIndex ?? branchIndex
                writeInt(90, leaderLineIndex, &out)
                writeDbl(40, branch.doglegLength ?? ml.doglegLength, &out)
                writeStr(304, "LEADER_LINE{", &out)
                for vertex in branch.vertices.dropLast() {
                    writePoint3(10, vertex, &out)
                }
                writeInt(91, leaderLineIndex, &out)
                writeStr(305, "}", &out)
                writeInt(271, 0, &out)
                writeStr(303, "}", &out)
            }
            writeInt(272, 9, &out)
            writeInt(273, 9, &out)
            writeStr(301, "}", &out)

            let styleKey = normalizedName(ml.styleName.isEmpty ? "Standard" : ml.styleName)
            writeStr(340, mleaderStyleHandleByName[styleKey] ?? "0", &out)
            var propertyOverrideFlags = (1 << 5) | (1 << 7) | (1 << 9) | (1 << 10) | (1 << 16)
            if hasMText { propertyOverrideFlags |= 1 << 18 }
            if hasBlock {
                propertyOverrideFlags |= (1 << 19) | (1 << 21) | (1 << 22)
            }
            writeInt(90, propertyOverrideFlags, &out)
            writeInt(170, ml.pathType, &out)
            writeInt(171, -2, &out)
            writeInt(290, ml.landingEnabled ? 1 : 0, &out)
            writeInt(291, ml.doglegEnabled ? 1 : 0, &out)
            writeDbl(41, ml.doglegLength, &out)
            if !ml.arrowheadName.isEmpty,
               let arrowHandle = blockRecordHandle(for: ml.arrowheadName) {
                writeStr(342, arrowHandle, &out)
            }
            writeDbl(42, ml.arrowSize, &out)
            writeInt(172, ml.contentType, &out)
            writeStr(343, textStyleHandleByName[normalizedName(ml.textStyleName)]
                ?? textStyleHandleByName["STANDARD"]
                ?? "0", &out)
            writeInt(173, ml.leftAttachment, &out)
            writeInt(95, ml.rightAttachment, &out)
            writeInt(174, ml.textAngleType, &out)
            writeInt(175, ml.textAlignment, &out)
            writeInt(292, ml.textFrameEnabled ? 1 : 0, &out)
            if hasBlock, let blockHandle = blockRecordHandle(for: ml.blockName) {
                writeStr(344, blockHandle, &out)
            }
            writePoint3(10, Vector3(
                x: ml.blockScale,
                y: ml.blockScale,
                z: ml.blockScale), &out)
            writeDbl(43, ml.blockRotation, &out)
            writeInt(176, 0, &out)
            writeInt(293, ml.contentScale != 1 ? 1 : 0, &out)
            if hasBlock {
                for attribute in ml.blockAttributes {
                    guard let definitionHandle = blockAttributeDefinitionHandle(
                        blockName: ml.blockName,
                        tag: attribute.tag,
                        sourceHandle: attribute.definitionHandle) else { continue }
                    writeStr(330, definitionHandle, &out)
                    writeInt(177, attribute.index, &out)
                    writeDbl(44, attribute.width, &out)
                    writeStr(302, attribute.text, &out)
                }
            }
            writeInt(294, ml.textDirectionNegative ? 1 : 0, &out)
            writeInt(178, ml.textAlignInIPE, &out)
            writeInt(179, ml.textAttachmentPoint, &out)
            writeDbl(45, ml.contentScale, &out)
            writeInt(271, ml.attachmentDirection, &out)
            writeInt(272, ml.bottomAttachment, &out)
            writeInt(273, ml.topAttachment, &out)
            for (branchIndex, branch) in ml.branches.enumerated()
                where !branch.arrowheadName.isEmpty {
                guard let arrowHandle = blockRecordHandle(for: branch.arrowheadName) else { continue }
                writeInt(94, branch.leaderLineIndex ?? branchIndex, &out)
                writeStr(345, arrowHandle, &out)
            }

        case .hATCH:
            guard let ht = e as? DXFHatchEntity else { return }
            writeEntityHeader("HATCH", entity: ht, handle: h, ownerHandle: ownerHandle, &out)
            if !ht.rawBodyGroups.isEmpty {
                for group in ht.rawBodyGroups { writeRawGroup(group, &out) }
                writeExtendedData(ht, &out)
                return
            }
            out += "100\r\nAcDbHatch\r\n"
            writePoint3(10, ht.basePoint, &out)
            writeCoord3(210, ht.extrusion, &out)
            writeStr(2, ht.name, &out)
            writeInt(70, ht.solid, &out)
            writeInt(71, ht.associative, &out)
            writeInt(91, ht.loops.count, &out)

            for loop in ht.loops {
                let polyline = loop.entities.compactMap { $0 as? DXFLWPolylineEntity }.first
                writeInt(92, polyline == nil ? (loop.type & ~2) : (loop.type | 2), &out)

                if let polyline {
                    let hasBulge = polyline.vertices.contains { abs($0.bulge) > 1e-12 }
                    writeInt(72, hasBulge ? 1 : 0, &out)
                    writeInt(73, (polyline.flags & 1) != 0 ? 1 : 0, &out)
                    writeInt(93, polyline.vertices.count, &out)
                    for vertex in polyline.vertices {
                        writeDbl(10, vertex.x, &out)
                        writeDbl(20, vertex.y, &out)
                        if hasBulge { writeDbl(42, vertex.bulge, &out) }
                    }
                    writeInt(97, loop.sourceBoundaryHandles.count, &out)
                    for handle in loop.sourceBoundaryHandles {
                        writeStr(330, String(handle, radix: 16).uppercased(), &out)
                    }
                    continue
                }

                let boundaries = loop.entities.filter { boundary in
                    boundary is DXFLineEntity
                        || boundary is DXFArcEntity
                        || boundary is DXFEllipseEntity
                        || boundary is DXFSplineEntity
                }
                writeInt(93, boundaries.count, &out)
                for boundary in boundaries {
                    if let ellipse = boundary as? DXFEllipseEntity {
                        writeInt(72, 3, &out)
                        writePoint(10, ellipse.basePoint, &out)
                        writePoint(11, ellipse.secPoint, &out)
                        writeDbl(40, ellipse.ratio, &out)
                        writeDbl(50, ellipse.startParam * 180.0 / .pi, &out)
                        writeDbl(51, ellipse.endParam * 180.0 / .pi, &out)
                        writeInt(73, ellipse.isCCW != 0 ? 1 : 0, &out)
                    } else if let line = boundary as? DXFLineEntity {
                        writeInt(72, 1, &out)
                        writePoint(10, line.basePoint, &out)
                        writePoint(11, line.secPoint, &out)
                    } else if let arc = boundary as? DXFArcEntity {
                        writeInt(72, 2, &out)
                        writePoint(10, arc.basePoint, &out)
                        writeDbl(40, arc.radius, &out)
                        writeDbl(50, arc.startAngle * 180.0 / .pi, &out)
                        writeDbl(51, arc.endAngle * 180.0 / .pi, &out)
                        writeInt(73, arc.isCCW != 0 ? 1 : 0, &out)
                    } else if let spline = boundary as? DXFSplineEntity {
                        writeInt(72, 4, &out)
                        writeInt(94, spline.degree, &out)
                        writeInt(73, (spline.flags & 4) != 0 ? 1 : 0, &out)
                        writeInt(74, (spline.flags & 2) != 0 ? 1 : 0, &out)
                        writeInt(95, spline.knots.count, &out)
                        writeInt(96, spline.controlPoints.count, &out)
                        for knot in spline.knots { writeDbl(40, knot, &out) }
                        for (index, point) in spline.controlPoints.enumerated() {
                            writePoint(10, point, &out)
                            if (spline.flags & 4) != 0 {
                                let weight = index < spline.weights.count ? spline.weights[index] : 1.0
                                writeDbl(42, weight, &out)
                            }
                        }
                        writeInt(97, spline.fitPoints.count, &out)
                        for point in spline.fitPoints { writePoint(11, point, &out) }
                        if !spline.fitPoints.isEmpty {
                            writePoint(12, spline.tgStart, &out)
                            writePoint(13, spline.tgEnd, &out)
                        }
                    }
                }
                writeInt(97, loop.sourceBoundaryHandles.count, &out)
                for handle in loop.sourceBoundaryHandles {
                    writeStr(330, String(handle, radix: 16).uppercased(), &out)
                }
            }

            writeInt(75, ht.hStyle, &out)
            writeInt(76, ht.hPattern, &out)

            if ht.solid == 0 {
                writeDbl(52, ht.angle_p, &out)
                writeDbl(41, ht.scale, &out)
                writeInt(77, ht.doubleFlag, &out)
                let patternLines = ht.patternLines
                writeInt(78, patternLines.count, &out)
                for line in patternLines {
                    writeDbl(53, line.angle, &out)
                    writeDbl(43, line.base.x, &out)
                    writeDbl(44, line.base.y, &out)
                    writeDbl(45, line.offset.x, &out)
                    writeDbl(46, line.offset.y, &out)
                    writeInt(79, line.dashes.count, &out)
                    for dash in line.dashes { writeDbl(49, dash, &out) }
                }
            }

            if ht.isGradient == 0, ht.bgColor >= 0 {
                writeInt(63, Int(ht.bgColor), &out)
            }

            if ht.isGradient != 0 || ht.pixelSize > 0 {
                let pixelSize = ht.pixelSize.isFinite && ht.pixelSize > 0
                    ? ht.pixelSize
                    : max(abs(ht.scale), 1.0) * 0.01
                writeDbl(47, pixelSize, &out)
            }
            writeInt(98, ht.seedPoints.count, &out)
            for point in ht.seedPoints {
                writePoint(10, point, &out)
            }

            if ht.isGradient != 0 {
                writeInt(450, ht.isGradient, &out)
                writeInt(451, 0, &out)
                writeDbl(460, ht.gradientAngle * .pi / 180.0, &out)
                writeDbl(461, ht.gradientShift, &out)
                writeInt(452, ht.singleColorGrad, &out)
                writeDbl(462, ht.gradientTint, &out)
                writeInt(453, ht.gradientColors.count, &out)
                for stop in ht.gradientColors {
                    writeDbl(463, stop.position, &out)
                    writeInt(63, Int(stop.aci), &out)
                    if stop.rgb >= 0 { writeInt(421, Int(stop.rgb), &out) }
                }
                writeStr(470, ht.gradientName.isEmpty ? "LINEAR" : ht.gradientName, &out)
            }

        case .iMAGE:
            guard let im = e as? DXFImageEntity else { return }
            writeEntityHeader("IMAGE", entity: im, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbRasterImage\r\n"
            if let imageDefinitionHandle = imageDefinitionHandleByEntity[ObjectIdentifier(im)] {
                writeStr(340, imageDefinitionHandle, &out)
            }
            writePoint3(10, im.basePoint, &out)
            writePoint3(11, im.secPoint, &out)     // U-vector
            writePoint3(12, im.vVector, &out)       // V-vector
            writeDbl(13, im.sizeU, &out)
            writeDbl(23, im.sizeV, &out)
            writeDbl(33, im.dz, &out)
            writeInt(280, im.clip, &out)
            writeInt(281, im.brightness, &out)
            writeInt(282, im.contrast, &out)
            writeInt(283, im.fade, &out)

        case .vIEWPORT:
            guard let vp = e as? DXFViewportEntity else { return }
            writeEntityHeader("VIEWPORT", entity: vp, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbViewport\r\n"
            writePoint3(10, vp.basePoint, &out)
            writeDbl(40, vp.psWidth, &out)
            writeDbl(41, vp.psHeight, &out)
            writeInt(68, vp.vpStatus, &out)
            writeInt(69, vp.vpID, &out)
            writeDbl(12, vp.centerPX, &out)
            writeDbl(22, vp.centerPY, &out)
            writeDbl(13, 0, &out)
            writeDbl(23, 0, &out)
            writeDbl(14, 10, &out)
            writeDbl(24, 10, &out)
            writeDbl(15, 10, &out)
            writeDbl(25, 10, &out)
            writePoint3(16, Vector3(x: 0, y: 0, z: 1), &out)
            writePoint3(17, vp.viewTarget, &out)
            writeDbl(42, 50, &out)
            writeDbl(43, 0, &out)
            writeDbl(44, 0, &out)
            writeDbl(45, vp.viewHeight, &out)
            writeDbl(50, 0, &out)
            writeDbl(51, vp.twistAngle, &out)
            writeInt(72, 100, &out)
            writeInt(90, 32800, &out)
            writeStrAllowEmpty(1, "", &out)
            writeInt(281, 0, &out)
            writeInt(71, 1, &out)
            writeInt(74, 0, &out)
            writePoint3(110, .zero, &out)
            writePoint3(111, Vector3(x: 1, y: 0, z: 0), &out)
            writePoint3(112, Vector3(x: 0, y: 1, z: 0), &out)
            writeInt(79, 0, &out)
            writeDbl(146, 0, &out)
            writeInt(170, 0, &out)
            writeInt(61, 5, &out)
            writeInt(292, 1, &out)
            writeInt(282, 1, &out)
            writeDbl(141, 0, &out)
            writeDbl(142, 0, &out)
            writeInt(63, 250, &out)
            writeInt(421, 3355443, &out)

        case .tABLE:
            guard let table = e as? DXFTableEntity else { return }
            if let payload = table.data.nativeDXFPayload,
               !payload.rawGroups.isEmpty {
                writeRawGroup(DataTableRawDXFGroup(code: 0, value: "ACAD_TABLE"), &out)
                writeRawGroup(DataTableRawDXFGroup(code: 5, value: h), &out)
                if payload.isModified {
                    for group in rewrittenNativeTableGroups(
                        table: table,
                        payload: payload,
                        ownerHandle: ownerHandle) {
                        writeRawGroup(group, &out)
                    }
                    writeExtendedData(table, &out)
                    return
                }
                var wroteHandle = false
                var reachedEntitySubclass = false
                var reachedBlockReferenceSubclass = false
                for group in payload.rawGroups {
                    if group.code == 5, !wroteHandle {
                        wroteHandle = true
                        continue
                    }
                    if group.code == 1001 { break }
                    if group.code == 100 {
                        let subclass = group.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if subclass.caseInsensitiveCompare("AcDbEntity") == .orderedSame {
                            reachedEntitySubclass = true
                        } else if subclass.caseInsensitiveCompare("AcDbBlockReference") == .orderedSame {
                            reachedBlockReferenceSubclass = true
                        }
                    }
                    if group.code == 330, !reachedEntitySubclass,
                       let ownerHandle, !ownerHandle.isEmpty {
                        writeRawGroup(DataTableRawDXFGroup(code: 330, value: ownerHandle), &out)
                    } else if group.code == 8, reachedEntitySubclass, !reachedBlockReferenceSubclass {
                        writeRawGroup(DataTableRawDXFGroup(code: 8, value: esc(layer: table.layer)), &out)
                    } else if group.code == 343,
                              let recordHandle = blockRecordHandle(for: table.blockName) {
                        writeRawGroup(DataTableRawDXFGroup(code: 343, value: recordHandle), &out)
                    } else {
                        writeRawGroup(group, &out)
                    }
                }
                writeExtendedData(table, &out)
                return
            }
            writeEntityHeader("ACAD_TABLE", entity: table, handle: h, ownerHandle: ownerHandle, &out)
            out += "100\r\nAcDbBlockReference\r\n"
            writeStr(2, table.blockName, &out)
            writePoint3(10, table.insertion, &out)
            writePoint3(11, table.horizontal, &out)
            out += "100\r\nAcDbTable\r\n"

        default:
            break
        }
        writeExtendedData(e, &out)
    }

    private func writeExtendedData(_ entity: DXFEntity, _ out: inout String) {
        guard hasExtendedData else { return }
        let registered = Set(appids.map { $0.name.uppercased() })
        var active = false
        for pair in entity.extendedData {
            if pair.code == 1001 {
                guard let appID = pair.value as? String else {
                    active = false
                    continue
                }
                active = registered.contains(appID.uppercased())
                if active { writeStr(1001, appID, &out) }
                continue
            }
            guard active else { continue }
            switch pair.value {
            case let value as String:
                writeStr(pair.code, value, &out)
            case let value as Double:
                writeDbl(pair.code, value, &out)
            case let value as Int:
                writeInt(pair.code, value, &out)
            case let value as Int32:
                writeInt(pair.code, Int(value), &out)
            case let value as UInt32:
                writeInt(pair.code, Int(value), &out)
            default:
                continue
            }
        }
    }

    private func writeEntityHeader(
        _ type: String,
        entity: DXFEntity,
        handle: String,
        ownerHandle: String?,
        _ out: inout String
    ) {
        out += "  0\r\n\(type)\r\n  5\r\n\(handle)\r\n"
        if isModern, let ownerHandle, !ownerHandle.isEmpty {
            out += "330\r\n\(ownerHandle)\r\n"
        }
        if hasSubclassMarkers { out += "100\r\nAcDbEntity\r\n" }
        writeStr(8, esc(layer: entity.layer), &out)
        writeCommonEntityData(entity, &out)
    }

    private func writeVertex(
        _ v: DXFVertexEntity,
        ownerHandle: String,
        layer: String,
        _ out: inout String
    ) {
        out += "  0\r\nVERTEX\r\n  5\r\n\(allocHandle())\r\n"
        if isModern { out += "330\r\n\(ownerHandle)\r\n100\r\nAcDbEntity\r\n" }
        writeStr(8, esc(layer: layer), &out)
        out += "100\r\nAcDbVertex\r\n"
        out += "100\r\nAcDb2dVertex\r\n"
        writePoint3(10, v.basePoint, &out)
        writeDbl(40, v.startWidth, &out)
        writeDbl(41, v.endWidth, &out)
        writeDbl(42, v.bulge, &out)
        writeInt(70, v.flags, &out)
        writeDbl(50, v.tangentDir, &out)
        writeInt(71, v.vIndex1, &out)
        writeInt(72, v.vIndex2, &out)
        writeInt(73, v.vIndex3, &out)
        writeInt(74, v.vIndex4, &out)
        writeInt(91, v.identifier, &out)
    }

    private func writeCommonEntityData(_ e: DXFEntity, _ out: inout String) {
        if e.color != 256 { writeInt(62, Int(e.color), &out) }
        if e.color24 >= 0 { writeInt(420, Int(e.color24), &out) }
        if e.lineType != "BYLAYER" { writeStr(6, e.lineType, &out) }
        if e.ltypeScale != 1.0 { writeDbl(48, e.ltypeScale, &out) }
        if !e.visible { writeInt(60, 1, &out) }
        if e.space != 0 { writeInt(67, e.space, &out) }
        if e.lWeight != .byLayer { writeInt(370, e.lWeight.dxfInt, &out) }
        if !e.colorName.isEmpty { writeStr(430, e.colorName, &out) }
        if hasTransparency, e.transparency >= 0 { writeInt(440, Int(e.transparency), &out) }
        if e.haveExtrusion || e.extrusion != Vector3(x: 0, y: 0, z: 1) {
            writeCoord3(210, e.extrusion, &out)
        }
    }

    // MARK: - ACDSDATA

    private func writeACDSData(_ out: inout String) {
        guard isModern, !preservedACDSData.isEmpty else { return }
        out += "  0\r\nSECTION\r\n  2\r\nACDSDATA\r\n"
        for group in preservedACDSData {
            writeRawGroup(group, &out)
        }
        out += "  0\r\nENDSEC\r\n"
    }

    // MARK: - OBJECTS

    private func isHandleReferenceCode(_ code: Int) -> Bool {
        (320...369).contains(code)
            || (390...399).contains(code)
            || code == 480
            || code == 481
            || code == 1005
    }

    private func definedHandles(in content: String) -> Set<String> {
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var result = Set<String>()
        var index = 0
        var foundHandleInRecord = false
        while index + 1 < lines.count {
            guard let code = Int(lines[index].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                index += 1
                continue
            }
            let value = normalizedHandle(lines[index + 1])
            if code == 0 {
                foundHandleInRecord = false
            } else if !foundHandleInRecord, code == 5 || code == 105 {
                if !value.isEmpty && value != "0" { result.insert(value) }
                foundHandleInRecord = true
            }
            index += 2
        }
        return result
    }

    private func scrubMissingDictionaryEntries(
        _ groups: [DataTableRawDXFGroup],
        validHandles: Set<String>
    ) -> [DataTableRawDXFGroup] {
        var result: [DataTableRawDXFGroup] = []
        var pendingNameIndex: Int?
        for group in groups {
            if group.code == 3 {
                result.append(group)
                pendingNameIndex = result.count - 1
                continue
            }
            if (group.code == 350 || group.code == 360), let nameIndex = pendingNameIndex {
                let target = normalizedHandle(group.value)
                if target == "0" || validHandles.contains(target) {
                    result.append(group)
                } else if nameIndex < result.count {
                    result.remove(at: nameIndex)
                }
                pendingNameIndex = nil
                continue
            }
            result.append(group)
        }
        return result
    }

    private func sanitizedPreservedObjectRecords(
        _ source: [DXFRawRecord],
        baseHandles: Set<String>
    ) -> [DXFRawRecord] {
        var records = source
        var changed = true
        while changed {
            changed = false
            var validHandles = baseHandles
            for record in records {
                if let handle = recordHandle(record) { validHandles.insert(handle) }
            }

            var next: [DXFRawRecord] = []
            next.reserveCapacity(records.count)
            for var record in records {
                let type = normalizedName(record.type)
                if type == "DICTIONARY" || type == "ACDBDICTIONARYWDFLT" {
                    let groups = scrubMissingDictionaryEntries(
                        record.groups,
                        validHandles: validHandles)
                    if groups.count != record.groups.count { changed = true }
                    record.groups = groups
                }

                let missingReference = record.groups.contains { group in
                    guard isHandleReferenceCode(group.code),
                          group.code != 5,
                          group.code != 105 else { return false }
                    let target = normalizedHandle(group.value)
                    return !target.isEmpty && target != "0" && !validHandles.contains(target)
                }
                if missingReference {
                    changed = true
                } else {
                    next.append(record)
                }
            }
            records = next
        }
        return records
    }

    private func writeObjects(_ out: inout String) {
        guard isModern else { return }

        let rawRoot = preservedRootDictionary()
        let rawRootHandle = rawRoot.flatMap { recordHandle($0) }
        var generatedRootNames: Set<String> = [
            "ACAD_GROUP", "ACAD_LAYOUT", "ACAD_MATERIAL", "ACAD_PLOTSTYLENAME"
        ]
        if entities.contains(where: { $0.eType == .iMAGE }) {
            generatedRootNames.insert("ACAD_IMAGE_DICT")
        }
        if !mleaderStyleDictionaryHandle.isEmpty {
            generatedRootNames.insert("ACAD_MLEADERSTYLE")
        }

        var rawRootEntries: [(name: String, handle: String, code: Int)] = []
        if let rawRoot {
            var pendingName: String?
            for group in rawRoot.groups {
                if group.code == 3 {
                    pendingName = group.value
                } else if (group.code == 350 || group.code == 360), let entryName = pendingName {
                    rawRootEntries.append((entryName, normalizedHandle(group.value), group.code))
                    pendingName = nil
                }
            }
        }
        let skippedRawDictionaryHandles = Set(rawRootEntries.compactMap { entry -> String? in
            generatedRootNames.contains(normalizedName(entry.name)) ? entry.handle : nil
        })

        let imageEntities = entities.compactMap { $0 as? DXFImageEntity }
        let outputImageDictionaryHandle = imageEntities.isEmpty ? nil : imageDictionaryHandle
        var mleaderStyleEntityByName: [String: DXFMLeaderEntity] = [:]
        let allMLeaderEntities = entities.compactMap { $0 as? DXFMLeaderEntity }
            + blocks.flatMap { $0.entities.compactMap { $0 as? DXFMLeaderEntity } }
        for leader in allMLeaderEntities {
            let name = leader.styleName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.isEmpty ? "Standard" : name
            let key = normalizedName(resolvedName)
            if mleaderStyleEntityByName[key] == nil {
                mleaderStyleEntityByName[key] = leader
            }
        }

        var generatedHandles: Set<String> = [
            rootDictionaryHandle,
            groupDictionaryHandle,
            plotStyleDictionaryHandle,
            plotStyleNormalHandle
        ].reduce(into: Set<String>()) { result, value in
            let handle = normalizedHandle(value)
            if !handle.isEmpty && handle != "0" { result.insert(handle) }
        }
        if hasMaterials {
            generatedHandles.formUnion([
                normalizedHandle(materialDictionaryHandle),
                normalizedHandle(materialByBlockHandle),
                normalizedHandle(materialByLayerHandle),
                normalizedHandle(materialGlobalHandle)
            ].filter { !$0.isEmpty && $0 != "0" })
        }
        if !layoutDictionaryHandle.isEmpty {
            generatedHandles.insert(normalizedHandle(layoutDictionaryHandle))
            generatedHandles.formUnion(layoutHandleByBlockName.values.map { normalizedHandle($0) })
        }
        if !mleaderStyleDictionaryHandle.isEmpty {
            generatedHandles.insert(normalizedHandle(mleaderStyleDictionaryHandle))
            generatedHandles.formUnion(mleaderStyleHandleByName.values.map { normalizedHandle($0) })
        }
        if let outputImageDictionaryHandle {
            generatedHandles.insert(normalizedHandle(outputImageDictionaryHandle))
            generatedHandles.formUnion(imageDefinitionHandleByEntity.values.map { normalizedHandle($0) })
        }

        let preservedCandidates = preservedObjects.filter { record in
            let handle = recordHandle(record) ?? ""
            let owner = normalizedHandle(record.groups.first(where: { $0.code == 330 })?.value ?? "")
            if handle == rawRootHandle { return false }
            if generatedHandles.contains(handle) { return false }
            if skippedRawDictionaryHandles.contains(handle) || skippedRawDictionaryHandles.contains(owner) {
                return false
            }
            return true
        }
        let baseHandles = definedHandles(in: out).union(generatedHandles)
        let preservedRecords = sanitizedPreservedObjectRecords(
            preservedCandidates,
            baseHandles: baseHandles)
        let preservedHandles = Set(preservedRecords.compactMap(recordHandle))
        let emittedHandles = baseHandles.union(preservedHandles)

        out += "  0\r\nSECTION\r\n  2\r\nOBJECTS\r\n"

        out += "  0\r\nDICTIONARY\r\n  5\r\n\(rootDictionaryHandle)\r\n"
        out += "330\r\n0\r\n100\r\nAcDbDictionary\r\n281\r\n1\r\n"
        out += "  3\r\nACAD_GROUP\r\n350\r\n\(groupDictionaryHandle)\r\n"
        if !layoutDictionaryHandle.isEmpty {
            out += "  3\r\nACAD_LAYOUT\r\n350\r\n\(layoutDictionaryHandle)\r\n"
        }
        if hasMaterials {
            out += "  3\r\nACAD_MATERIAL\r\n350\r\n\(materialDictionaryHandle)\r\n"
        }
        out += "  3\r\nACAD_PLOTSTYLENAME\r\n350\r\n\(plotStyleDictionaryHandle)\r\n"
        if let outputImageDictionaryHandle {
            out += "  3\r\nACAD_IMAGE_DICT\r\n350\r\n\(outputImageDictionaryHandle)\r\n"
        }
        if !mleaderStyleDictionaryHandle.isEmpty {
            out += "  3\r\nACAD_MLEADERSTYLE\r\n350\r\n\(mleaderStyleDictionaryHandle)\r\n"
        }
        for entry in rawRootEntries
        where !generatedRootNames.contains(normalizedName(entry.name))
            && emittedHandles.contains(normalizedHandle(entry.handle)) {
            writeStr(3, entry.name, &out)
            writeStr(entry.code, entry.handle, &out)
        }

        out += "  0\r\nDICTIONARY\r\n  5\r\n\(groupDictionaryHandle)\r\n"
        out += "330\r\n\(rootDictionaryHandle)\r\n100\r\nAcDbDictionary\r\n281\r\n1\r\n"

        writePlotStyleObjects(&out)
        if hasMaterials { writeMaterialObjects(&out) }

        if !layoutDictionaryHandle.isEmpty {
            out += "  0\r\nDICTIONARY\r\n  5\r\n\(layoutDictionaryHandle)\r\n"
            out += "330\r\n\(rootDictionaryHandle)\r\n100\r\nAcDbDictionary\r\n281\r\n1\r\n"
            for layout in outputLayouts {
                guard let layoutHandle = layoutHandleByBlockName[normalizedName(layout.blockName)] else { continue }
                writeStr(3, layout.name, &out)
                writeStr(350, layoutHandle, &out)
            }

            var writtenLayoutHandles = Set<String>()
            for layout in outputLayouts {
                let blockKey = normalizedName(layout.blockName)
                guard let layoutHandle = layoutHandleByBlockName[blockKey],
                      writtenLayoutHandles.insert(layoutHandle).inserted,
                      let blockHandle = blockRecordHandle(for: layout.blockName) else { continue }
                writeLayoutObject(
                    layout,
                    handle: layoutHandle,
                    ownerHandle: layoutDictionaryHandle,
                    blockRecordHandle: blockHandle,
                    &out)
            }
        }

        if !mleaderStyleDictionaryHandle.isEmpty {
            out += "  0\r\nDICTIONARY\r\n  5\r\n\(mleaderStyleDictionaryHandle)\r\n"
            out += "330\r\n\(rootDictionaryHandle)\r\n100\r\nAcDbDictionary\r\n281\r\n1\r\n"
            for (key, handle) in mleaderStyleHandleByName.sorted(by: { $0.key < $1.key }) {
                let storedName = mleaderStyleEntityByName[key]?.styleName
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                writeStr(3, storedName.isEmpty ? "Standard" : storedName, &out)
                writeStr(350, handle, &out)
            }

            for (key, handle) in mleaderStyleHandleByName.sorted(by: { $0.key < $1.key }) {
                guard let leader = mleaderStyleEntityByName[key] else { continue }
                let name = leader.styleName.trimmingCharacters(in: .whitespacesAndNewlines)
                writeMLeaderStyleObject(
                    leader,
                    name: name.isEmpty ? "Standard" : name,
                    handle: handle,
                    &out)
            }
        }

        if let outputImageDictionaryHandle {
            out += "  0\r\nDICTIONARY\r\n  5\r\n\(outputImageDictionaryHandle)\r\n"
            out += "330\r\n\(rootDictionaryHandle)\r\n100\r\nAcDbDictionary\r\n281\r\n1\r\n"
            for (index, image) in imageEntities.enumerated() {
                guard let definitionHandle = imageDefinitionHandleByEntity[ObjectIdentifier(image)] else { continue }
                let filename = image.imageFilePath.isEmpty ? "Image_\(index + 1)" : image.imageFilePath
                let dictionaryName = (filename as NSString).deletingPathExtension
                writeStr(3, dictionaryName.isEmpty ? "Image_\(index + 1)" : dictionaryName, &out)
                writeStr(350, definitionHandle, &out)
            }

            for image in imageEntities {
                guard let definitionHandle = imageDefinitionHandleByEntity[ObjectIdentifier(image)] else { continue }
                out += "  0\r\nIMAGEDEF\r\n  5\r\n\(definitionHandle)\r\n"
                out += "330\r\n\(outputImageDictionaryHandle)\r\n100\r\nAcDbRasterImageDef\r\n"
                writeInt(90, 0, &out)
                writeStr(1, image.imageFilePath, &out)
                writeDbl(10, image.sizeU, &out)
                writeDbl(20, image.sizeV, &out)
                writeDbl(11, 1.0, &out)
                writeDbl(21, 1.0, &out)
                writeInt(280, 1, &out)
                writeInt(281, 0, &out)
            }
        }

        for record in preservedRecords {
            writeRawGroup(DataTableRawDXFGroup(code: 0, value: record.type), &out)
            for group in record.groups {
                if group.code == 330,
                   let rawRootHandle,
                   normalizedHandle(group.value) == rawRootHandle {
                    writeRawGroup(DataTableRawDXFGroup(
                        code: group.code,
                        value: rootDictionaryHandle), &out)
                } else {
                    writeRawGroup(group, &out)
                }
            }
        }

        out += "  0\r\nENDSEC\r\n"
    }


    private func writeMLeaderStyleObject(
        _ leader: DXFMLeaderEntity,
        name: String,
        handle: String,
        _ out: inout String
    ) {
        out += "  0\r\nMLEADERSTYLE\r\n  5\r\n\(handle)\r\n"
        out += "330\r\n\(mleaderStyleDictionaryHandle)\r\n100\r\nAcDbMLeaderStyle\r\n"
        writeInt(179, 2, &out)
        writeInt(170, leader.contentType, &out)
        writeInt(171, 1, &out)
        writeInt(172, 0, &out)
        writeInt(90, max(2, leader.maxLeaderPoints), &out)
        writeDbl(40, 0.0, &out)
        writeDbl(41, 0.0, &out)
        writeInt(173, leader.pathType, &out)
        writeInt(91, 256, &out)
        writeStr(340, "0", &out)
        writeInt(92, -2, &out)
        writeInt(290, leader.landingEnabled ? 1 : 0, &out)
        writeDbl(42, leader.landingGap, &out)
        writeInt(291, leader.doglegEnabled ? 1 : 0, &out)
        writeDbl(43, leader.doglegLength, &out)
        writeStr(3, name, &out)
        if !leader.arrowheadName.isEmpty,
           let arrowHandle = blockRecordHandle(for: leader.arrowheadName) {
            writeStr(341, arrowHandle, &out)
        } else {
            writeStr(341, "0", &out)
        }
        writeDbl(44, leader.arrowSize, &out)
        writeStr(300, "", &out)
        writeStr(342, textStyleHandleByName[normalizedName(leader.textStyleName)] ?? textStyleHandleByName["STANDARD"] ?? "0", &out)
        writeInt(174, leader.leftAttachment, &out)
        writeInt(175, leader.textAngleType, &out)
        writeInt(176, leader.textAlignment, &out)
        writeInt(178, leader.rightAttachment, &out)
        writeInt(93, 256, &out)
        writeDbl(45, leader.textHeight, &out)
        writeInt(292, leader.textFrameEnabled ? 1 : 0, &out)
        writeInt(297, leader.alwaysLeftJustify ? 1 : 0, &out)
        writeDbl(46, leader.landingGap, &out)
        if !leader.blockName.isEmpty, let blockHandle = blockRecordHandle(for: leader.blockName) {
            writeStr(343, blockHandle, &out)
        } else {
            writeStr(343, "0", &out)
        }
        writeInt(94, 256, &out)
        writeDbl(47, leader.blockScale, &out)
        writeDbl(49, leader.blockScale, &out)
        writeDbl(140, leader.blockScale, &out)
        writeInt(293, 1, &out)
        writeDbl(141, leader.blockRotation, &out)
        writeInt(294, 1, &out)
        writeInt(177, 0, &out)
        writeDbl(142, 1.0, &out)
        writeInt(295, 0, &out)
        writeInt(296, 0, &out)
        writeDbl(143, 0.0, &out)
        writeInt(271, leader.attachmentDirection, &out)
        writeInt(272, leader.bottomAttachment, &out)
        writeInt(273, leader.topAttachment, &out)
    }

    private func writePlotStyleObjects(_ out: inout String) {
        out += "  0\r\nACDBDICTIONARYWDFLT\r\n  5\r\n\(plotStyleDictionaryHandle)\r\n"
        out += "330\r\n\(rootDictionaryHandle)\r\n100\r\nAcDbDictionary\r\n281\r\n1\r\n"
        writeStr(3, "Normal", &out)
        writeStr(350, plotStyleNormalHandle, &out)
        out += "100\r\nAcDbDictionaryWithDefault\r\n"
        writeStr(340, plotStyleNormalHandle, &out)

        out += "  0\r\nACDBPLACEHOLDER\r\n  5\r\n\(plotStyleNormalHandle)\r\n"
        out += "102\r\n{ACAD_REACTORS\r\n330\r\n\(plotStyleDictionaryHandle)\r\n102\r\n}\r\n"
        out += "330\r\n\(plotStyleDictionaryHandle)\r\n"
    }

    private func writeMaterialObjects(_ out: inout String) {
        out += "  0\r\nDICTIONARY\r\n  5\r\n\(materialDictionaryHandle)\r\n"
        out += "330\r\n\(rootDictionaryHandle)\r\n100\r\nAcDbDictionary\r\n281\r\n1\r\n"
        writeStr(3, "ByBlock", &out)
        writeStr(350, materialByBlockHandle, &out)
        writeStr(3, "ByLayer", &out)
        writeStr(350, materialByLayerHandle, &out)
        writeStr(3, "Global", &out)
        writeStr(350, materialGlobalHandle, &out)

        writeDefaultMaterial(name: "ByBlock", handle: materialByBlockHandle, &out)
        writeDefaultMaterial(name: "ByLayer", handle: materialByLayerHandle, &out)
        writeDefaultMaterial(name: "Global", handle: materialGlobalHandle, &out)
    }

    private func writeDefaultMaterial(name: String, handle: String, _ out: inout String) {
        out += "  0\r\nMATERIAL\r\n  5\r\n\(handle)\r\n"
        out += "102\r\n{ACAD_REACTORS\r\n330\r\n\(materialDictionaryHandle)\r\n102\r\n}\r\n"
        out += "330\r\n\(materialDictionaryHandle)\r\n100\r\nAcDbMaterial\r\n"
        writeStr(1, name, &out)
        writeStrAllowEmpty(2, "", &out)
        writeInt(70, 0, &out)
        writeDbl(40, 1, &out)
        writeInt(71, 1, &out)
        writeDbl(41, 1, &out)
        writeInt(91, -1023410177, &out)
        writeDbl(42, 1, &out)
        writeInt(72, 1, &out)
        writeStrAllowEmpty(3, "", &out)
        writeInt(73, 1, &out)
        writeInt(74, 1, &out)
        writeInt(75, 1, &out)
        writeDbl(44, 0.5, &out)
        writeInt(73, 0, &out)
        writeDbl(45, 1, &out)
        writeDbl(46, 1, &out)
        writeInt(77, 1, &out)
        writeStrAllowEmpty(4, "", &out)
        writeInt(78, 1, &out)
        writeInt(79, 1, &out)
        writeInt(170, 1, &out)
        writeDbl(48, 1, &out)
        writeInt(171, 1, &out)
        writeStrAllowEmpty(6, "", &out)
        writeInt(172, 1, &out)
        writeInt(173, 1, &out)
        writeInt(174, 1, &out)
        writeDbl(140, 1, &out)
        writeDbl(141, 1, &out)
        writeInt(175, 1, &out)
        writeStrAllowEmpty(7, "", &out)
        writeInt(176, 1, &out)
        writeInt(177, 1, &out)
        writeInt(178, 1, &out)
        writeDbl(143, 1, &out)
        writeInt(179, 1, &out)
        writeStrAllowEmpty(8, "", &out)
        writeInt(270, 1, &out)
        writeInt(271, 1, &out)
        writeInt(272, 1, &out)
        writeDbl(145, 1, &out)
        writeDbl(146, 1, &out)
        writeInt(273, 1, &out)
        writeStrAllowEmpty(9, "", &out)
        writeInt(274, 1, &out)
        writeInt(275, 1, &out)
        writeInt(276, 1, &out)
        writeDbl(42, 1, &out)
        writeInt(72, 1, &out)
        writeStrAllowEmpty(3, "", &out)
        writeInt(73, 1, &out)
        writeInt(74, 1, &out)
        writeInt(75, 1, &out)
        writeInt(94, 63, &out)
    }

    private func writeLayoutObject(
        _ layout: DXFLayoutDefinition,
        handle: String,
        ownerHandle: String,
        blockRecordHandle: String,
        _ out: inout String
    ) {
        let isModel = normalizedName(layout.blockName) == "*MODEL_SPACE"
        out += "  0\r\nLAYOUT\r\n  5\r\n\(handle)\r\n"
        out += "330\r\n\(ownerHandle)\r\n100\r\nAcDbPlotSettings\r\n"
        writeStrAllowEmpty(1, "", &out)
        writeStrAllowEmpty(2, "", &out)
        writeStrAllowEmpty(4, "", &out)
        writeStrAllowEmpty(6, "", &out)
        for code in 40...49 { writeDbl(code, 0, &out) }
        writeDbl(140, 0, &out)
        writeDbl(141, 0, &out)
        writeDbl(142, 1, &out)
        writeDbl(143, 1, &out)
        writeInt(70, isModel ? 1024 : 0, &out)
        writeInt(72, 0, &out)
        writeInt(73, 0, &out)
        writeInt(74, 5, &out)
        writeStrAllowEmpty(7, "", &out)
        writeInt(75, 0, &out)
        writeDbl(147, 1, &out)
        writeInt(76, 0, &out)
        writeInt(77, 2, &out)
        writeInt(78, 300, &out)
        writeDbl(148, 0, &out)
        writeDbl(149, 0, &out)

        out += "100\r\nAcDbLayout\r\n"
        writeStr(1, layout.name, &out)
        writeInt(70, isModel ? 1 : 0, &out)
        writeInt(71, layout.tabOrder, &out)
        writePoint(10, layout.minimumLimits, &out)
        writePoint(11, layout.maximumLimits, &out)
        writePoint3(12, .zero, &out)
        writePoint3(14, .zero, &out)
        writePoint3(15, .zero, &out)
        writeDbl(146, 0, &out)
        writePoint3(13, .zero, &out)
        writePoint3(16, Vector3(x: 1, y: 0, z: 0), &out)
        writePoint3(17, Vector3(x: 0, y: 1, z: 0), &out)
        writeInt(76, 0, &out)
        writeStr(330, blockRecordHandle, &out)
        if let viewportHandle = activeViewportHandleByBlockName[normalizedName(layout.blockName)] {
            writeStr(331, viewportHandle, &out)
        }
    }

    // MARK: - Write Helpers

    private var storesStringsAsUTF8: Bool {
        switch version {
        case .r2007, .r2010, .r2013, .r2018:
            return true
        default:
            return false
        }
    }

    public var outputStringEncoding: String.Encoding {
        storesStringsAsUTF8 || textCodec.codePage == "UTF-8" ? .utf8 : .isoLatin1
    }

    private func normalizedDXFString(_ value: String, mtext: Bool) -> String {
        value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: mtext ? "\\P" : " ")
    }

    private func writeEncodedStr(_ code: Int, _ encoded: String, _ out: inout String) {
        guard !encoded.isEmpty else { return }
        out += String(format: "%3d\r\n", code)
        out += encoded + "\r\n"
    }

    private func writeStr(_ code: Int, _ val: String, _ out: inout String) {
        let normalized = normalizedDXFString(val, mtext: false)
        guard !normalized.isEmpty else { return }
        writeEncodedStr(code, textCodec.fromUtf8(normalized), &out)
    }

    private func writeStrAllowEmpty(_ code: Int, _ val: String, _ out: inout String) {
        let normalized = normalizedDXFString(val, mtext: false)
        out += String(format: "%3d\r\n", code)
        out += textCodec.fromUtf8(normalized) + "\r\n"
    }

    private func writeInt(_ code: Int, _ val: Int, _ out: inout String) {
        out += String(format: "%3d\r\n%d\r\n", code, val)
    }

    private func writeDbl(_ code: Int, _ val: Double, _ out: inout String) {
        out += String(format: "%3d\r\n", code)
        out += dxfFmt(val) + "\r\n"
    }

    private func writeBool(_ code: Int, _ val: Bool, _ out: inout String) {
        writeInt(code, val ? 1 : 0, &out)
    }

    private func splitEncodedString(_ value: String, maxBytes: Int) -> (String, String) {
        var byteCount = 0
        var end = value.startIndex
        for character in value {
            let text = String(character)
            let characterBytes = text.data(
                using: outputStringEncoding,
                allowLossyConversion: false)?.count ?? text.utf8.count
            if byteCount > 0, byteCount + characterBytes > maxBytes { break }
            byteCount += characterBytes
            end = value.index(end, offsetBy: 1)
        }
        if end == value.startIndex, !value.isEmpty {
            end = value.index(after: value.startIndex)
        }
        return (String(value[..<end]), String(value[end...]))
    }

    /// Write MText string, chunking >250 encoded bytes into code 3 segments.
    private func writeMTextString(_ text: String, _ out: inout String) {
        let normalized = normalizedDXFString(text, mtext: true)
        var remaining = textCodec.fromUtf8(normalized)
        while (remaining.data(using: outputStringEncoding)?.count ?? remaining.utf8.count) > 250 {
            let (chunk, rest) = splitEncodedString(remaining, maxBytes: 250)
            writeEncodedStr(3, chunk, &out)
            remaining = rest
        }
        writeEncodedStr(1, remaining, &out)
    }

    /// Unitize a direction vector
    private func unitize(_ v: Vector3) -> Vector3 {
        let dist = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        if dist > 0 { return Vector3(x: v.x / dist, y: v.y / dist, z: v.z / dist) }
        return v
    }

    private func writePoint(_ code: Int, _ p: Vector3, _ out: inout String) {
        writeDbl(code, p.x, &out)
        writeDbl(code + 10, p.y, &out)
    }

    private func writePoint3(_ code: Int, _ p: Vector3, _ out: inout String) {
        writeDbl(code, p.x, &out)
        writeDbl(code + 10, p.y, &out)
        writeDbl(code + 20, p.z, &out)
    }

    private func writeCoord3(_ code: Int, _ p: Vector3, _ out: inout String) {
        writeDbl(code, p.x, &out)
        writeDbl(code + 10, p.y, &out)
        writeDbl(code + 20, p.z, &out)
    }

    private func esc(layer name: String) -> String {
        return name.isEmpty ? "0" : name
    }

    /// Format double for DXF: trim trailing zeros, use '.0' for integers
    private func dxfFmt(_ val: Double) -> String {
        if val.isNaN || val.isInfinite { return "0.0" }
        if abs(val) < 1e-15 { return "0.0" }
        let value = String(
            format: "%.17g",
            locale: Locale(identifier: "en_US_POSIX"),
            val)
        if value.contains(".") || value.contains("e") || value.contains("E") {
            return value
        }
        return value + ".0"
    }
}
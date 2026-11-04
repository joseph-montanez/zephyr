import Foundation

// MARK: - SheetSetSheetViews
//
// Sheet Views listing (read-only): named VIEW table records from the
// set's member drawings. One row group per drawing file, views sorted
// by name. Binary `.dwg` is skipped (needs the ODA converter; the MRU
// path has the same limit); `.dxf`/`.dwt` parse as DXF text, matching
// the codebase convention. Any unreadable file yields no group —
// listing views must never break opening the set.
// Place-on-sheet (viewport + XREF automation) stays explicitly gated;
// this only exposes what exists for browsing and future placement.

public enum SheetSetSheetViews {
    public struct NamedView: Sendable, Equatable {
        public var name: String
        public var handle: String
        public var height: Double
        public var width: Double
        /// View target in model units (placement centers here).
        public var targetX: Double
        public var targetY: Double

        public init(
            name: String, handle: String, height: Double, width: Double,
            targetX: Double = 0, targetY: Double = 0
        ) {
            self.name = name
            self.handle = handle
            self.height = height
            self.width = width
            self.targetX = targetX
            self.targetY = targetY
        }
    }

    public struct DrawingViews: Sendable, Equatable {
        /// Absolute drawing path.
        public var path: String
        public var title: String
        public var views: [NamedView]

        public init(path: String, title: String, views: [NamedView]) {
            self.path = path
            self.title = title
            self.views = views
        }
    }

    /// Grouped named views for every distinct readable member drawing,
    /// sorted by drawing title. Drawings with no named views are omitted.
    public static func viewsByDrawing(for set: SheetSet) -> [DrawingViews] {
        var seen = Set<String>()
        var out: [DrawingViews] = []
        for sheet in set.allSheetsInOrder {
            let path = sheet.absoluteFile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let key = path.replacingOccurrences(of: "\\", with: "/").lowercased()
            guard seen.insert(key).inserted else { continue }
            guard let views = readViews(atPath: path), !views.isEmpty else { continue }
            out.append(DrawingViews(
                path: path,
                title: URL(fileURLWithPath: path).lastPathComponent,
                views: views))
        }
        return out.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    /// Named views in one file, sorted by name. Nil on any failure.
    public static func readViews(atPath path: String) -> [NamedView]? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ext == "dxf" || ext == "dwt" else { return nil }
        guard let reader = try? DXFReader().readFile(at: path) else { return nil }
        let views = reader.views
            .filter { !$0.name.isEmpty }
            .map {
                NamedView(
                    name: $0.name,
                    handle: String(format: "%X", $0.handle),
                    height: $0.height,
                    width: $0.width,
                    targetX: $0.target.x,
                    targetY: $0.target.y)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return views
    }
}

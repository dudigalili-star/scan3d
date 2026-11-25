import Foundation

struct ExtraDimension: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var value: Double   // millimeters
}

struct ScanMeta: Codable {
    var name: String
    var created: Date
    /// Multiplier applied on top of the LiDAR scale (1.0 = no caliper correction).
    var scale: Double = 1.0
    /// Values typed by the user that replace the scanned overall dimensions on the drawing (mm).
    var widthMM: Double?
    var depthMM: Double?
    var heightMM: Double?
    /// Extra dimensions the user adds to the drawing (hole diameter, wall thickness...).
    var extraDimensions: [ExtraDimension]?
}

struct ScanItem: Identifiable, Hashable {
    let id: String
    var meta: ScanMeta
    let folder: URL

    var imagesURL: URL { folder.appendingPathComponent("Images", isDirectory: true) }
    var checkpointURL: URL { folder.appendingPathComponent("Checkpoint", isDirectory: true) }
    var exportsURL: URL { folder.appendingPathComponent("Exports", isDirectory: true) }
    var modelURL: URL { folder.appendingPathComponent("model.usdz") }
    var metaURL: URL { folder.appendingPathComponent("meta.json") }
    var thumbnailURL: URL { folder.appendingPathComponent("thumbnail.png") }
    var hasModel: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    static func == (a: ScanItem, b: ScanItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanItem] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var items: [ScanItem] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(ScanMeta.self, from: data) else { continue }
            items.append(ScanItem(id: dir.lastPathComponent, meta: meta, folder: dir))
        }
        scans = items.sorted { $0.meta.created > $1.meta.created }
    }

    func newScan() -> ScanItem {
        let now = Date()
        let idFormat = DateFormatter()
        idFormat.locale = Locale(identifier: "en_US_POSIX")
        idFormat.dateFormat = "yyyyMMdd-HHmmss"
        let nameFormat = DateFormatter()
        nameFormat.dateFormat = "d.M.yyyy HH:mm"
        let id = idFormat.string(from: now)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let item = ScanItem(id: id,
                            meta: ScanMeta(name: "סריקה " + nameFormat.string(from: now), created: now),
                            folder: folder)
        let fm = FileManager.default
        for dir in [item.imagesURL, item.checkpointURL, item.exportsURL] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        save(item)
        return item
    }

    func save(_ item: ScanItem) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(item.meta) {
            try? data.write(to: item.metaURL)
        }
        reload()
    }

    func delete(_ item: ScanItem) {
        try? FileManager.default.removeItem(at: item.folder)
        reload()
    }

    func scan(withID id: String) -> ScanItem? {
        scans.first { $0.id == id }
    }
}

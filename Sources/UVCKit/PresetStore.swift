import Foundation
import Observation

public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: CameraSettings
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, settings: CameraSettings, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.settings = settings; self.createdAt = createdAt
    }
}

/// Named setting presets for one camera, persisted to
/// ~/Library/Application Support/Camdeck/presets-<uniqueID>.json.
/// UI convention: `items[0...4]` map to ⌘1 ... ⌘5.
@MainActor @Observable
public final class PresetStore {
    public private(set) var items: [Preset] = []
    /// Applied automatically when this camera attaches or re-attaches (call `applyStartup()`).
    public var startupPresetID: UUID? { didSet { if oldValue != startupPresetID { persist() } } }

    /// Bundle ID -> preset id. When a bound app is running as another app starts using the camera, its preset applies.
    public private(set) var appBindings: [String: UUID] = [:]

    @ObservationIgnored public var capture: () -> CameraSettings
    @ObservationIgnored public var applySettings: (CameraSettings) -> Void
    /// Called after a preset was applied (hook for SettingsLock.userDidChange).
    @ObservationIgnored public var onApplied: (() -> Void)?
    @ObservationIgnored private let fileURL: URL

    public nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Camdeck", isDirectory: true)
    }

    public init(uniqueID: String, directory: URL = PresetStore.defaultDirectory,
                capture: @escaping () -> CameraSettings, apply: @escaping (CameraSettings) -> Void) {
        let safe = uniqueID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        fileURL = directory.appendingPathComponent("presets-\(safe).json")
        self.capture = capture
        self.applySettings = apply
        load()
    }

    private struct Disk: Codable {
        var items: [Preset]
        var startupPresetID: UUID?
        var appBindings: [String: UUID]
        init(items: [Preset], startupPresetID: UUID?, appBindings: [String: UUID]) {
            self.items = items; self.startupPresetID = startupPresetID; self.appBindings = appBindings
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decode([Preset].self, forKey: .items)
            startupPresetID = try c.decodeIfPresent(UUID.self, forKey: .startupPresetID)
            appBindings = try c.decodeIfPresent([String: UUID].self, forKey: .appBindings) ?? [:]
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = Self.decoder()
        guard let d = try? dec.decode(Disk.self, from: data) else { return }
        items = d.items
        startupPresetID = d.startupPresetID
        appBindings = d.appBindings.filter { b in d.items.contains { $0.id == b.value } }
    }

    private func persist() {
        let enc = Self.encoder()
        guard let data = try? enc.encode(Disk(items: items, startupPresetID: startupPresetID, appBindings: appBindings)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public var defaultName: String { "Preset \(items.count + 1)" }

    private static func clean(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    @discardableResult
    public func save(name: String) -> Preset {
        let p = Preset(name: Self.clean(name) ?? defaultName, settings: capture())
        items.append(p)
        persist()
        return p
    }

    public func apply(_ id: UUID) {
        guard let p = items.first(where: { $0.id == id }) else { return }
        applySettings(p.settings)
        onApplied?()
    }

    /// Applies the startup preset, if any (no `onApplied`: the lock's own re-apply path owns attach).
    public func applyStartup() {
        guard let id = startupPresetID, let p = items.first(where: { $0.id == id }) else { return }
        applySettings(p.settings)
    }

    public func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        if startupPresetID == id { startupPresetID = nil }
        appBindings = appBindings.filter { $0.value != id }
        persist()
    }

    /// Binds an app to a preset (an app has at most one preset).
    public func bind(app bundleID: String, to id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        appBindings[bundleID] = id
        persist()
    }

    public func unbind(app bundleID: String) {
        guard appBindings.removeValue(forKey: bundleID) != nil else { return }
        persist()
    }

    public func boundApps(for id: UUID) -> [String] {
        appBindings.filter { $0.value == id }.map(\.key).sorted()
    }

    /// The preset to use when another app starts the camera. macOS does not say which app, so only the
    /// frontmost app counts, and only if it is bound: a bound app idling in the background (Zoom left open)
    /// must not hijack FaceTime or Photo Booth.
    public func preset(frontmost: String?) -> Preset? {
        guard let f = frontmost, let id = appBindings[f] else { return nil }
        return items.first { $0.id == id }
    }

    /// Blank names are ignored.
    public func rename(_ id: UUID, to name: String) {
        guard let trimmed = Self.clean(name), let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = trimmed
        persist()
    }

    /// Same semantics as SwiftUI's `onMove`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter { items.indices.contains($0) }.map { items[$0] }
        let before = source.filter { $0 < destination }.count
        var rest = items
        for i in source.sorted(by: >) where rest.indices.contains(i) { rest.remove(at: i) }
        rest.insert(contentsOf: moving, at: min(max(destination - before, 0), rest.count))
        items = rest
        persist()
    }

    // MARK: Export / import

    private struct Bundle: Codable { var camdeck: Int; var presets: [Preset] }

    /// Pretty JSON `{ "camdeck": 1, "presets": [...] }`, same preset schema as the on-disk file.
    public func exportData() throws -> Data {
        return try Self.encoder().encode(Bundle(camdeck: 1, presets: items))
    }

    /// Appends the file's presets with fresh IDs; clashing names become "Name 2", "Name 3"... Returns the count.
    /// Unknown control ids are kept: they are filtered when a preset is applied.
    @discardableResult
    public func importData(_ data: Data) throws -> Int {
        let bundle = try Self.decoder().decode(Bundle.self, from: data)
        var names = Set(items.map(\.name))
        for p in bundle.presets {
            let name = Self.unique(Self.clean(p.name) ?? defaultName, in: names)
            names.insert(name)
            items.append(Preset(name: name, settings: p.settings, createdAt: p.createdAt))
        }
        if !bundle.presets.isEmpty { persist() }
        return bundle.presets.count
    }

    private static func unique(_ name: String, in taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

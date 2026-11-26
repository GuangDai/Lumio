//
//  PinStore.swift
//  lumio-app
//
//  Pinned apps, folders, links and settings stay on the Home screen in the order you pinned them.
//  Pin from a result's actions or with ⌘⇧P.
//
//  Stored locally in ~/Library/Application Support/lumio/pins.json.
//

import Combine
import Foundation

final class PinStore: ObservableObject {
    static let shared = PinStore()

    /// One pinned result: enough to draw and open it again without searching.
    private struct Entry: Codable {
        var kind: String
        var sourceID: String?
        var name: String
        var meta: String?
        var target: String
        var iconPath: String?
        var colors: String
        var symbol: String?
        var favicon: String?
        var candidateID: String?
    }

    @Published private(set) var items: [SpotlightItem] = []
    private var entries: [Entry] = []

    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("lumio/pins.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Entry].self, from: data)
        {
            entries = saved.filter { entry in
                SpotlightItem.acceptsSavedTarget(
                    kind: entry.kind, sourceID: entry.sourceID ?? entry.candidateID,
                    name: entry.name, target: entry.target,
                    iconPath: entry.iconPath, symbol: entry.symbol, meta: entry.meta
                )
            }
        }
        publish()
    }

    /// What can be pinned: results with a stable thing to open.
    static func target(of item: SpotlightItem) -> (kind: SpotlightKind, target: String)? {
        switch item.kind {
        case .app, .folder, .url, .setting:
            guard let target = item.target, !target.isEmpty,
                  item.canSave(as: item.kind, target: target) else { return nil }
            return (item.kind, target)
        case .tab:
            guard let url = item.tab?.url ?? item.target, item.canSave(as: .url, target: url) else { return nil }
            return (.url, url)
        default:
            return nil
        }
    }

    func isPinned(_ item: SpotlightItem) -> Bool {
        guard let (_, target) = Self.target(of: item) else { return false }
        return entries.contains { $0.target.lowercased() == target.lowercased() }
    }

    /// Pins or unpins `item`. Returns the new state (true = now pinned), nil when it can't be pinned.
    @discardableResult
    func toggle(_ item: SpotlightItem) -> Bool? {
        guard let (kind, target) = Self.target(of: item) else { return nil }
        if let index = entries.firstIndex(where: { $0.target.lowercased() == target.lowercased() }) {
            entries.remove(at: index)
            save()
            return false
        }
        entries.append(Entry(
            kind: kind.rawValue, sourceID: item.id, name: item.name, meta: item.meta, target: target,
            iconPath: item.iconPath, colors: item.colors, symbol: item.symbol, favicon: item.favicon,
            candidateID: item.candidateID
        ))
        save()
        return true
    }

    private func save() {
        publish()
        let snapshot = entries
        let file = Self.file
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private func publish() {
        items = entries.compactMap { entry in
            guard let kind = SpotlightKind(rawValue: entry.kind) else { return nil }
            return SpotlightItem(
                id: "pin|" + entry.target, name: entry.name, kind: kind, colors: entry.colors, meta: entry.meta,
                target: entry.target, iconPath: entry.iconPath, symbol: entry.symbol,
                candidateID: entry.candidateID, favicon: entry.favicon
            )
        }
    }
}

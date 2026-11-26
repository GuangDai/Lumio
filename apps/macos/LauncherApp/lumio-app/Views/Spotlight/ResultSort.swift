import Foundation

enum ResultSort: String, CaseIterable {
    case relevance, name

    var label: String {
        switch self {
        case .relevance: "Default"
        case .name: "Name"
        }
    }

    static func sorted(_ items: [SpotlightItem], by mode: ResultSort) -> [SpotlightItem] {
        guard mode == .name else { return items }
        let nameable: Set<SpotlightKind> = [.app, .folder, .url, .tab, .window, .setting]
        let named = items.filter { nameable.contains($0.kind) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return named + items.filter { !nameable.contains($0.kind) }
    }
}

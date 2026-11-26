import Foundation

@_silgen_name("lumio_search_json_compact")
nonisolated
private func lumio_search_json_compact(_ query: UnsafePointer<CChar>?, _ limit: UInt32) -> UnsafeMutablePointer<CChar>?


@_silgen_name("lumio_record_usage_json")
nonisolated
private func lumio_record_usage_json(_ candidateID: UnsafePointer<CChar>?, _ action: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("lumio_free_cstring")
nonisolated
private func lumio_free_cstring(_ ptr: UnsafeMutablePointer<CChar>?)

@_silgen_name("lumio_reload_config")
nonisolated
private func lumio_reload_config() -> Bool

@_silgen_name("lumio_request_index_refresh")
nonisolated
private func lumio_request_index_refresh() -> Bool

@_silgen_name("lumio_fuzzy_score")
nonisolated
private func lumio_fuzzy_score(_ query: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?) -> Int64

@_silgen_name("lumio_classify_url_json")
nonisolated
private func lumio_classify_url_json(_ query: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

final class EngineBridge: @unchecked Sendable {
    nonisolated static let shared = EngineBridge()

    nonisolated private init() {}

    nonisolated func search(query: String, limit: Int = 40) -> [LauncherResult] {
        let ptr = query.withCString { cstr in
            lumio_search_json_compact(cstr, UInt32(limit))
        }

        guard let ptr else {
            return fallbackResults()
        }

        defer {
            lumio_free_cstring(ptr)
        }

        let raw = String(cString: ptr)
        guard let data = raw.data(using: .utf8) else {
            return fallbackResults()
        }

        if let compactPayload = try? JSONDecoder().decode(CompactSearchPayload.self, from: data) {
            if compactPayload.error != nil {
                return fallbackResults()
            }
            return compactPayload.results.map { LauncherResult($0, defaultKind: .app) }
        }

        // Compatibility fallback for older JSON payload shape.
        guard let fullPayload = try? JSONDecoder().decode(SearchPayload.self, from: data),
            fullPayload.error == nil
        else {
            return fallbackResults()
        }

        return fullPayload.results.map { LauncherResult($0, defaultKind: .app) }
    }

    nonisolated func recordUsage(candidateID: String, action: String) -> BridgeError? {
        let ptr = candidateID.withCString { idCstr in
            action.withCString { actionCstr in
                lumio_record_usage_json(idCstr, actionCstr)
            }
        }

        guard let ptr else {
            return BridgeError(code: "ffi_null_response", message: "Usage tracking is temporarily unavailable")
        }

        defer {
            lumio_free_cstring(ptr)
        }

        let raw = String(cString: ptr)
        guard let data = raw.data(using: .utf8),
            let payload = try? JSONDecoder().decode(UsageRecordPayload.self, from: data)
        else {
            return BridgeError(code: "decode_failed", message: "Usage tracking response could not be decoded")
        }

        return payload.error
    }

    /// Re-reads `~/.lumio/config` and refreshes the search index.
    /// Blocks the caller for the whole walk: use `reloadConfigInBackground()` from the UI.
    nonisolated func reloadConfig() -> Bool {
        lumio_reload_config()
    }

    /// `reloadConfig()` off the main thread, one at a time. Saving a setting posts a reload
    /// while Settings may run its own: overlapping walks fight over lumio.db's write lock
    /// (5 s busy timeout per statement) and can fail with "database is locked".
    nonisolated func reloadConfigInBackground() async -> Bool {
        await withCheckedContinuation { continuation in
            Self.reloadQueue.async { continuation.resume(returning: self.reloadConfig()) }
        }
    }

    private nonisolated static let reloadQueue = DispatchQueue(
        label: "com.cavaldos.Lumio.config-reload", qos: .userInitiated)

    @discardableResult
    nonisolated func requestIndexRefresh() -> Bool {
        lumio_request_index_refresh()
    }

    nonisolated func fuzzyScore(query: String, title: String) -> Int? {
        let score = query.withCString { queryCstr in
            title.withCString { titleCstr in
                lumio_fuzzy_score(queryCstr, titleCstr)
            }
        }
        return score == Int64.min ? nil : Int(score) // Int64.min = NO_MATCH sentinel
    }

    /// Classifies `query` as a URL, or nil to leave it as a search term.
    /// Network-free; shares the Rust core's tier rules and TLD list with linows.
    nonisolated func classifyURL(query: String) -> URLMatch? {
        let ptr = query.withCString { lumio_classify_url_json($0) }
        guard let ptr else { return nil }
        defer { lumio_free_cstring(ptr) }
        let raw = String(cString: ptr)
        guard raw != "null", let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(URLMatch.self, from: data)
    }

    nonisolated private func fallbackResults() -> [LauncherResult] {
        []
    }
}

/// Wire shape of `lumio_answers::UrlMatch`: the resolved openable URL and how
/// certain the classification is. `tier` decodes the lowercased Rust enum
/// (`structural` / `barehost`).
nonisolated struct URLMatch: Decodable {
    enum Tier: String, Decodable {
        case structural
        case bareHost = "barehost"
    }

    let url: String
    let tier: Tier
}

private nonisolated struct SearchPayload: Decodable {
    let query: String
    let count: Int
    let results: [SearchItem]
    let error: BridgeError?
}

private nonisolated struct CompactSearchPayload: Decodable {
    let count: Int
    let results: [SearchItem]
    let error: BridgeError?
}

private nonisolated struct UsageRecordPayload: Decodable {
    let ok: Bool
    let error: BridgeError?
}

nonisolated struct BridgeError: Decodable {
    let code: String
    let message: String

    var userFacingMessage: String {
        BridgeErrorMapping.userFacingMessage(code: code, fallback: message)
    }
}

private nonisolated struct SearchItem: Decodable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let path: String
    let score: Int
    let icon: String?
}

extension LauncherResult {
    /// One decode of a search payload row. Spelled out per call site, every new
    /// field the core adds is a three-site edit, and the sites drift: `icon`
    /// reached search results and missed file recall entirely.
    fileprivate nonisolated init(_ item: SearchItem, defaultKind: LauncherResultKind) {
        self.init(
            id: item.id,
            kind: LauncherResultKind(rawValue: item.kind) ?? defaultKind,
            title: item.title,
            subtitle: item.subtitle,
            path: item.path,
            score: item.score,
            icon: item.icon
        )
    }
}

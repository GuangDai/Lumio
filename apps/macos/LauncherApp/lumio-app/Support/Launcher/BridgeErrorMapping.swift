enum BridgeErrorCode: String {
    case invalidInput = "invalid_input"
    case invalidCandidateID = "invalid_candidate_id"
    case invalidUsageAction = "invalid_usage_action"
    case storageOpenFailed = "storage_open_failed"
    case recordUsageFailed = "record_usage_failed"
    case ffiNullResponse = "ffi_null_response"
    case decodeFailed = "decode_failed"
    case serializeFailed = "serialize_failed"
}

nonisolated enum BridgeErrorMapping {
    static func userFacingMessage(code: String, fallback: String) -> String {
        guard let code = BridgeErrorCode(rawValue: code) else {
            return fallback
        }

        switch code {
        case .invalidInput, .invalidCandidateID, .invalidUsageAction:
            return "This item could not be tracked."
        case .storageOpenFailed, .recordUsageFailed:
            return "Usage tracking is temporarily unavailable."
        case .ffiNullResponse, .decodeFailed, .serializeFailed:
            return "Backend response was invalid."
        }
    }
}

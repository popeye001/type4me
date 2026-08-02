import Foundation

struct BailianASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.bailian
    static let displayName = L("阿里云百炼", "Alibaba Cloud Bailian")
    static let defaultModel = "fun-asr-realtime"
    static let supportedModels = [
        "fun-asr-realtime",
        "fun-asr-realtime-2026-02-28",
        "fun-asr-realtime-2025-11-07",
        "fun-asr-realtime-2025-09-15",
        "fun-asr-flash-8k-realtime",
        "fun-asr-flash-8k-realtime-2026-01-28",
    ]
    static let supportedLanguageHints = ["zh", "en", "ja"]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "model",
            label: "Model",
            placeholder: defaultModel,
            isSecure: false,
            isOptional: false,
            defaultValue: defaultModel,
            options: supportedModels.map { FieldOption(value: $0, label: $0) },
            allowCustomInput: true
        ),
        CredentialField(
            key: "languageHint",
            label: "Language Hint",
            placeholder: "zh / en / ja",
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "vocabularyId",
            label: "Vocabulary ID",
            placeholder: L("热词词表 ID", "Hotword vocabulary ID"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "baseURL",
            label: "Base URL",
            placeholder: "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
    ]}

    let apiKey: String
    let model: String
    let languageHint: String
    let vocabularyId: String
    let baseURL: String

    init?(credentials: [String: String]) {
        guard let apiKey = Self.sanitized(credentials["apiKey"]),
              !apiKey.isEmpty
        else { return nil }

        self.apiKey = apiKey
        self.model = Self.sanitized(credentials["model"]) ?? Self.defaultModel

        let rawLanguageHint = Self.sanitized(credentials["languageHint"])?.lowercased() ?? ""
        self.languageHint = Self.supportedLanguageHints.contains(rawLanguageHint) ? rawLanguageHint : ""
        self.vocabularyId = Self.sanitized(credentials["vocabularyId"]) ?? ""
        self.baseURL = Self.sanitized(credentials["baseURL"]) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "model": model,
            "languageHint": languageHint,
            "vocabularyId": vocabularyId,
            "baseURL": baseURL,
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty && !model.isEmpty
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

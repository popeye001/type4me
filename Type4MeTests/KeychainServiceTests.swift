import XCTest
@testable import Type4Me

final class KeychainServiceTests: XCTestCase {

    private var originalProvider: ASRProvider!
    private var originalASRValues: [String: String]?
    private var originalLLMValues: [String: String]?
    private var originalMigrationMarker: Any?
    private let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Type4Me", isDirectory: true)
    private var credentialsURL: URL {
        appSupportDir.appendingPathComponent("credentials.json")
    }

    override func setUp() {
        super.setUp()
        originalProvider = KeychainService.selectedASRProvider
        originalASRValues = KeychainService.loadASRCredentials(for: .volcano)
        originalLLMValues = KeychainService.loadLLMCredentials(for: .doubao)
        originalMigrationMarker = UserDefaults.standard.object(forKey: "tf_migratedFromTypeFlow")
    }

    override func tearDown() {
        KeychainService.delete(key: "test_key")
        if let originalASRValues {
            try? KeychainService.saveASRCredentials(for: .volcano, values: originalASRValues)
        } else {
            try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
        }
        if let originalLLMValues {
            try? KeychainService.saveLLMCredentials(for: .doubao, values: originalLLMValues)
        } else {
            try? KeychainService.saveLLMCredentials(for: .doubao, values: [:])
        }
        KeychainService.selectedASRProvider = originalProvider
        restoreUserDefault(key: "tf_migratedFromTypeFlow", value: originalMigrationMarker)
        originalASRValues = nil
        originalLLMValues = nil
        originalMigrationMarker = nil
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        try KeychainService.save(key: "test_key", value: "secret123")
        let loaded = KeychainService.load(key: "test_key")
        XCTAssertEqual(loaded, "secret123")
    }

    func testOverwrite() throws {
        try KeychainService.save(key: "test_key", value: "old")
        try KeychainService.save(key: "test_key", value: "new")
        XCTAssertEqual(KeychainService.load(key: "test_key"), "new")
    }

    func testLoadMissing() {
        let result = KeychainService.load(key: "nonexistent_key_xyz")
        XCTAssertNil(result)
    }

    func testDelete() throws {
        try KeychainService.save(key: "test_key", value: "value")
        KeychainService.delete(key: "test_key")
        XCTAssertNil(KeychainService.load(key: "test_key"))
    }

    func testLoadCredentials_fromKeychain() throws {
        let original = KeychainService.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? KeychainService.saveASRCredentials(for: .volcano, values: original)
            } else {
                try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
            "resourceId": "myResource",
        ])

        let config = KeychainService.loadASRConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.appKey, "myAppKey")
        XCTAssertEqual(config?.accessKey, "myAccessKey")
        XCTAssertEqual(config?.resourceId, "myResource")
    }

    func testCompatibleASRCredentials_backfillsVolcanoResourceIdForOldValues() throws {
        let values = KeychainService.compatibleASRCredentials(
            for: .volcano,
            stored: [
                "appKey": "myAppKey",
                "accessKey": "myAccessKey",
            ]
        )

        XCTAssertEqual(values["appKey"], "myAppKey")
        XCTAssertEqual(values["accessKey"], "myAccessKey")
        XCTAssertEqual(values["resourceId"], VolcanoASRConfig.resourceIdAuto)
        XCTAssertNotNil(VolcanoASRConfig(credentials: values))
    }

    func testCompatibleLLMCredentials_backfillsModelAndBaseURLForOldValues() throws {
        let values = KeychainService.compatibleLLMCredentials(
            for: .doubao,
            stored: ["apiKey": "myApiKey"]
        )

        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["model"], LLMProvider.doubao.modelOptions.first?.value)
        XCTAssertEqual(values["baseURL"], LLMProvider.doubao.defaultBaseURL)
        XCTAssertNotNil(OpenAICompatibleLLMConfig<DoubaoLLMTag>(credentials: values))
    }

    func testCompatibleCredentialsPreferStoredValuesOverLegacyFallbacks() throws {
        let values = KeychainService.compatibleASRCredentials(
            for: .volcano,
            stored: ["appKey": "newAppKey"],
            legacy: [
                "appKey": "oldAppKey",
                "accessKey": "oldAccessKey",
                "resourceId": "oldResourceId",
            ]
        )

        XCTAssertEqual(values["appKey"], "newAppKey")
        XCTAssertEqual(values["accessKey"], "oldAccessKey")
        XCTAssertEqual(values["resourceId"], "oldResourceId")
    }

    func testLoadASRCredentials_backfillsDefaultsWhenSecureFieldIsStoredAlone() throws {
        let original = KeychainService.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? KeychainService.saveASRCredentials(for: .volcano, values: original)
            } else {
                try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
        ])

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .volcano))
        XCTAssertEqual(values["appKey"], "myAppKey")
        XCTAssertEqual(values["accessKey"], "myAccessKey")
        XCTAssertEqual(values["resourceId"], VolcanoASRConfig.resourceIdAuto)
        XCTAssertNotNil(KeychainService.loadASRConfig(for: .volcano))
    }

    func testLoadLLMCredentials_backfillsDefaultsWhenOnlyAPIKeyIsStored() throws {
        let original = KeychainService.loadLLMCredentials(for: .doubao)
        defer {
            if let original {
                try? KeychainService.saveLLMCredentials(for: .doubao, values: original)
            } else {
                try? KeychainService.saveLLMCredentials(for: .doubao, values: [:])
            }
        }

        try KeychainService.saveLLMCredentials(for: .doubao, values: [
            "apiKey": "myApiKey",
        ])

        let values = try XCTUnwrap(KeychainService.loadLLMCredentials(for: .doubao))
        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["model"], LLMProvider.doubao.modelOptions.first?.value)
        XCTAssertEqual(values["baseURL"], LLMProvider.doubao.defaultBaseURL)
        XCTAssertNotNil(KeychainService.loadLLMProviderConfig(for: .doubao))
    }

    func testMigrateStoredCredentialsCleansLegacyFallbackSourcesAfterBackfill() throws {
        let legacyKeys = ["tf_appKey", "tf_accessKey", "tf_resourceId"]
        let originalDefaults = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        let originalScalarValues = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, KeychainService.load(key: $0)) }
        )
        defer {
            for key in legacyKeys {
                restoreUserDefault(key: key, value: originalDefaults[key] ?? nil)
                if let value = originalScalarValues[key] ?? nil {
                    try? KeychainService.save(key: key, value: value)
                } else {
                    KeychainService.delete(key: key)
                }
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [:])
        UserDefaults.standard.set("legacyAppKey", forKey: "tf_appKey")
        try KeychainService.save(key: "tf_accessKey", value: "legacyAccessKey")
        UserDefaults.standard.set("legacyResource", forKey: "tf_resourceId")

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadASRCredentials(for: .volcano))
        XCTAssertEqual(values["appKey"], "legacyAppKey")
        XCTAssertEqual(values["accessKey"], "legacyAccessKey")
        XCTAssertEqual(values["resourceId"], "legacyResource")
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_appKey"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_resourceId"))
        XCTAssertNil(KeychainService.load(key: "tf_accessKey"))
    }

    func testMigrateStoredCredentialsCleansLegacyLLMFallbackSourcesAfterBackfill() throws {
        let legacyKeys = ["tf_llmApiKey", "tf_llmModel", "tf_llmEndpointId", "tf_llmBaseURL"]
        let originalDefaults = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        let originalScalarValues = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, KeychainService.load(key: $0)) }
        )
        defer {
            for key in legacyKeys {
                restoreUserDefault(key: key, value: originalDefaults[key] ?? nil)
                if let value = originalScalarValues[key] ?? nil {
                    try? KeychainService.save(key: key, value: value)
                } else {
                    KeychainService.delete(key: key)
                }
            }
        }

        try KeychainService.saveLLMCredentials(for: .doubao, values: [:])
        try KeychainService.save(key: "tf_llmApiKey", value: "legacyLLMKey")
        UserDefaults.standard.set("legacy-model", forKey: "tf_llmEndpointId")
        UserDefaults.standard.set("https://legacy.example/v1", forKey: "tf_llmBaseURL")

        KeychainService.migrateStoredCredentials()

        let values = try XCTUnwrap(KeychainService.loadLLMCredentials(for: .doubao))
        XCTAssertEqual(values["apiKey"], "legacyLLMKey")
        XCTAssertEqual(values["model"], "legacy-model")
        XCTAssertEqual(values["baseURL"], "https://legacy.example/v1")
        XCTAssertNil(KeychainService.load(key: "tf_llmApiKey"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_llmEndpointId"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_llmBaseURL"))
    }

    func testSaveASRCredentials_storesSecureFieldsOutsideCredentialsFile() throws {
        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
            "resourceId": "myResource",
        ])

        let fileData = try Data(contentsOf: credentialsURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        let stored = try XCTUnwrap(json["tf_asr_volcano"] as? [String: String])

        XCTAssertEqual(stored["appKey"], "myAppKey")
        XCTAssertEqual(stored["resourceId"], "myResource")
        XCTAssertNil(stored["accessKey"])
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .volcano)?["accessKey"], "myAccessKey")
    }

    func testSelectedASRProviderPostsNotificationOnChange() {
        let targetProvider: ASRProvider = originalProvider == .bailian ? .volcano : .bailian
        let expectation = expectation(description: "provider change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.object as? ASRProvider, targetProvider)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        KeychainService.selectedASRProvider = targetProvider

        wait(for: [expectation], timeout: 1.0)
    }

    private func restoreUserDefault(key: String, value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

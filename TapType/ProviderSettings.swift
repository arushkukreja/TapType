import Foundation
import Security

enum SpeechProvider: String, CaseIterable, Identifiable {
    case apple, base = "base.en", small = "small.en", openAI, groq
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple Speech"
        case .base: "Whisper Base"
        case .small: "Whisper Small"
        case .openAI: "OpenAI"
        case .groq: "Groq"
        }
    }
    var cloud: CloudProvider? { self == .openAI ? .openAI : self == .groq ? .groq : nil }
    var modelName: String { cloud?.speechModel ?? title }
    var downloaded: Bool { self == .base || self == .small }
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: "speechProvider") ?? "apple") ?? .apple }
}

enum WritingProvider: String, CaseIterable, Identifiable {
    case apple, openAI, groq
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple Speech" : self == .openAI ? "OpenAI" : "Groq" }
    var cloud: CloudProvider? { self == .openAI ? .openAI : self == .groq ? .groq : nil }
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: "writingProvider") ?? "apple") ?? .apple }
}

enum CloudProvider: String, CaseIterable, Identifiable {
    case openAI, groq
    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI" : "Groq" }
    var baseURL: URL { URL(string: self == .openAI ? "https://api.openai.com/v1/" : "https://api.groq.com/openai/v1/")! }
    var speechModel: String { UserDefaults.standard.string(forKey: rawValue + "SpeechModel") ?? (self == .openAI ? "gpt-transcribe" : "whisper-large-v3-turbo") }
    var writingModel: String { UserDefaults.standard.string(forKey: rawValue + "WritingModel") ?? (self == .openAI ? "gpt-6-luna" : "llama-3.3-70b-versatile") }
}

struct ProviderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Credentials belong only to the companion app, never the keyboard's App Group.
enum ProviderKeys {
    private static let service = "com.arushkukreja.TapTypeDev.provider"
    private static func query(_ provider: CloudProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
    static func read(_ provider: CloudProvider) throws -> String {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw ProviderFailure(message: "Add your \(provider.title) API key in TapType’s Cloud providers settings.")
        }
        return key
    }
    static func save(_ key: String, for provider: CloudProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count < 4096, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ProviderFailure(message: "Enter a valid API key without spaces.")
        }
        let q = query(provider)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProviderFailure(message: "Couldn’t save this key securely. Please unlock your iPhone and try again.") }
    }
    static func remove(_ provider: CloudProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderFailure(message: "Couldn’t remove the saved key. Please try again.")
        }
    }
}

struct CloudSelection {
    let provider: CloudProvider
    let model: String
    let key: String
    #if DEBUG
    init(testProvider: CloudProvider, model: String, key: String) { self.provider = testProvider; self.model = model; self.key = key }
    #endif
    init(_ provider: CloudProvider, writing: Bool = false, model override: String? = nil) throws {
        self.provider = provider
        model = (override ?? (writing ? provider.writingModel : provider.speechModel)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 160, !model.contains(where: { $0.isNewline }) else {
            throw ProviderFailure(message: "Choose a valid \(provider.title) model in Cloud providers settings.")
        }
        guard model != "gpt-live-transcribe" else { throw ProviderFailure(message: "Live API transcription was removed. Choose Apple Speech or a file transcription model.") }
        key = try ProviderKeys.read(provider)
    }
}

struct CloudSettingsDraft {
    var key: String
    var speech: String
    var writing: String
    func validate() throws {
        guard speech.trimmingCharacters(in: .whitespacesAndNewlines) != "gpt-live-transcribe" else { throw ProviderFailure(message: "Choose a lower-cost speech model, such as gpt-transcribe. The live model has been removed.") }
        guard [speech, writing].allSatisfy({ value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && name.count <= 160 && !name.contains(where: { $0.isWhitespace })
        }) else { throw ProviderFailure(message: "Enter a model name without spaces.") }
        if !key.isEmpty {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count < 4096, !value.contains(where: { $0.isWhitespace }) else {
                throw ProviderFailure(message: "Enter a valid API key without spaces.")
            }
        }
    }
}

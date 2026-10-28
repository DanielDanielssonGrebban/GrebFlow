import Foundation
import Observation

/// Save, replace, remove, and test the Anthropic API key. The key itself is
/// only ever held in the Keychain; this object just knows whether one exists.
@MainActor
@Observable
final class APIKeyController {
    private(set) var hasKey = false
    private(set) var status: String?
    private(set) var isTesting = false

    /// Called after the key is saved or removed, so analysis can stop or
    /// resume with the new authorization.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let client: AnthropicClient

    init(secrets: SecretStore, client: AnthropicClient) {
        self.secrets = secrets
        self.client = client
        hasKey = ((try? secrets.read()) ?? nil)?.isEmpty == false
    }

    @discardableResult
    func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Paste a key first."
            return false
        }
        do {
            try secrets.save(trimmed)
            hasKey = true
            status = "Key saved to the Keychain."
            onChange()
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    func remove() {
        do {
            try secrets.delete()
            hasKey = false
            status = "Key removed. Automatic grouping is stopped."
            onChange()
        } catch {
            status = error.localizedDescription
        }
    }

    /// Checks the key and model through the Models API. Sends no history.
    func test(modelID: String) async {
        guard let key = try? secrets.read(), !key.isEmpty else {
            status = AnthropicError.missingAPIKey.errorDescription
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            let info = try await client.model(id: modelID, apiKey: key)
            let name = info.displayName ?? info.id
            if let limit = info.maxInputTokens {
                status = "Connected. \(name) is available, with a \(limit.formatted())-token context window."
            } else {
                status = "Connected. \(name) is available."
            }
        } catch {
            status = error.localizedDescription
        }
    }
}

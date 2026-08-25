//
//  CarbAIKeychain.swift
//  Loop
//
//  Secure storage for AI carb-estimation provider API keys.
//  Thin wrapper over LoopKit's KeychainManager (generic password items).
//  Keys are NEVER written to UserDefaults and NEVER logged.
//

import Foundation
import LoopKit

/// Stores and retrieves per-provider API keys in the iOS Keychain.
struct CarbAIKeychain {
    private let keychain = KeychainManager()

    /// Keychain generic-password service identifier for a given provider.
    private func service(for provider: CarbEstimationProviderType) -> String {
        "com.loopkit.Loop.aiCarb.apiKey.\(provider.rawValue)"
    }

    /// Store (or clear, when `key` is nil/empty) the API key for a provider.
    func setAPIKey(_ key: String?, for provider: CarbEstimationProviderType) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        // Failure here is non-fatal; the UI validates presence separately.
        try? keychain.replaceGenericPassword(value, forService: service(for: provider))
    }

    /// Retrieve the API key for a provider, if one has been stored.
    func apiKey(for provider: CarbEstimationProviderType) -> String? {
        try? keychain.getGenericPasswordForService(service(for: provider))
    }

    /// Whether a non-empty API key exists for a provider.
    func hasAPIKey(for provider: CarbEstimationProviderType) -> Bool {
        (apiKey(for: provider)?.isEmpty == false)
    }
}

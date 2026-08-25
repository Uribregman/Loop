//
//  CarbProviderFactory.swift
//  Loop
//
//  Builds the configured CarbEstimationProvider from settings + Keychain.
//  Returns nil (with a reason) when the selection isn't usable, so callers can
//  prompt the user rather than fail silently (§5).
//

import Foundation

enum CarbProviderFactory {
    static func makeProvider(settings: CarbEstimationSettings = CarbEstimationSettings(),
                             keychain: CarbAIKeychain = CarbAIKeychain()) throws -> CarbEstimationProvider {
        // Kill-switch layer 1: no provider is even constructed while AI is off.
        // (Layer 2 sits in CarbProviderHTTP, gating the actual network call.)
        guard settings.isEnabled else {
            throw CarbEstimationError.aiDisabled
        }

        let provider = settings.provider

        if provider.requiresAPIKey, keychain.apiKey(for: provider)?.isEmpty != false {
            throw CarbEstimationError.noAPIKey
        }

        switch provider {
        case .appleOnDevice:
            return AppleOnDeviceCarbProvider()
        case .gemini:
            return GeminiCarbProvider(apiKey: keychain.apiKey(for: .gemini) ?? "")
        case .claude:
            return ClaudeCarbProvider(apiKey: keychain.apiKey(for: .claude) ?? "")
        case .openAI:
            return OpenAICarbProvider(apiKey: keychain.apiKey(for: .openAI) ?? "")
        case .custom:
            let endpoint = settings.customEndpoint
            guard !endpoint.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CarbEstimationError.notConfigured
            }
            return CustomCarbProvider(endpoint: endpoint, apiKey: keychain.apiKey(for: .custom) ?? "")
        }
    }
}

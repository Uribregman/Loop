//
//  CarbEstimationSettings.swift
//  Loop
//
//  Part of the optional AI-assisted carb estimation feature.
//  Stores the user's provider choice and master on/off toggle in UserDefaults.
//  API keys are NEVER stored here — see CarbAIKeychain.
//
//  This feature is fully additive: when `isEnabled` is false the app behaves
//  exactly as it does today and no AI UI is shown.
//

import Foundation

/// The AI carb-estimation provider the user has selected.
enum CarbEstimationProviderType: String, CaseIterable, Identifiable {
    case appleOnDevice
    case gemini
    case claude
    case openAI
    case custom

    var id: String { rawValue }

    /// Human-readable name shown in the settings picker.
    var title: String {
        switch self {
        case .appleOnDevice: return NSLocalizedString("Apple On-Device", comment: "AI carb provider name: Apple Foundation Models")
        case .gemini:        return NSLocalizedString("Google Gemini", comment: "AI carb provider name: Google Gemini")
        case .claude:        return NSLocalizedString("Anthropic Claude", comment: "AI carb provider name: Anthropic Claude")
        case .openAI:        return NSLocalizedString("OpenAI ChatGPT", comment: "AI carb provider name: OpenAI ChatGPT")
        case .custom:        return NSLocalizedString("Custom Endpoint", comment: "AI carb provider name: user-supplied endpoint")
        }
    }

    /// Whether this provider needs an API key stored in the Keychain.
    var requiresAPIKey: Bool {
        switch self {
        case .appleOnDevice: return false
        case .gemini, .claude, .openAI, .custom: return true
        }
    }

    /// Whether this provider needs a user-supplied endpoint URL.
    var requiresEndpoint: Bool { self == .custom }

    /// Whether this provider can be given a web-search tool (research branded
    /// foods / restaurant items). Apple On-Device stays private/offline by
    /// design; Custom endpoints are the user's own server and out of our control.
    var supportsWebSearch: Bool {
        switch self {
        case .claude, .gemini, .openAI: return true
        case .appleOnDevice, .custom:   return false
        }
    }
}

/// Persisted settings for the AI carb-estimation feature.
///
/// Only the toggle, selected provider, and (for the custom provider) the
/// endpoint URL live in UserDefaults. Secrets live in the Keychain.
struct CarbEstimationSettings {
    private enum Key: String {
        case isEnabled = "com.loopkit.Loop.aiCarb.isEnabled"
        case provider = "com.loopkit.Loop.aiCarb.provider"
        case customEndpoint = "com.loopkit.Loop.aiCarb.customEndpoint"
        case webSearchEnabled = "com.loopkit.Loop.aiCarb.webSearchEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Master switch. Defaults to OFF so the feature is opt-in.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.isEnabled.rawValue) }
    }

    /// Selected provider. Defaults to Apple on-device (no key, works offline where supported).
    var provider: CarbEstimationProviderType {
        get {
            guard let raw = defaults.string(forKey: Key.provider.rawValue),
                  let value = CarbEstimationProviderType(rawValue: raw) else {
                return .appleOnDevice
            }
            return value
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.provider.rawValue) }
    }

    /// Endpoint URL string for the custom provider (non-secret; the key is in Keychain).
    var customEndpoint: String {
        get { defaults.string(forKey: Key.customEndpoint.rawValue) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.customEndpoint.rawValue) }
    }

    /// When on, providers that support it may use a web-search tool to look up
    /// nutrition facts for branded/packaged foods and restaurant items. Defaults
    /// to OFF: it's opt-in on top of the master toggle, and only takes effect for
    /// providers whose `supportsWebSearch` is true. Ignored entirely while
    /// `isEnabled` is false (no request is made at all in that case).
    var isWebSearchEnabled: Bool {
        get { defaults.bool(forKey: Key.webSearchEnabled.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.webSearchEnabled.rawValue) }
    }
}

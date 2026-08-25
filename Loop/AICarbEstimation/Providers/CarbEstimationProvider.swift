//
//  CarbEstimationProvider.swift
//  Loop
//
//  The single provider contract. Every AI backend (Apple, Gemini, Claude,
//  Custom) conforms to this — same input, same output, same error type — so
//  the rest of the app never talks to a specific vendor.
//
//  This layer produces an ESTIMATE ONLY. It never saves a carb entry and has
//  no reference to the carb store or dosing/algorithm code.
//

import Foundation

/// Input sent to a provider: the meal photo plus optional context.
struct CarbEstimationInput {
    /// JPEG-encoded meal photos — multiple angles or separate components of ONE
    /// meal. May be empty for text-only estimation.
    let images: [Data]
    /// Optional free-text note the user added (e.g. "whole wheat pasta"). §8.
    let note: String?
    /// LiDAR volume estimate in milliliters, if available on this device. §3A.
    let volumeMilliliters: Double?
    /// When true, the provider MAY use a web-search tool to look up published
    /// nutrition facts for branded/packaged foods and restaurant items. Only set
    /// by the coordinator when the user opted in AND the selected provider
    /// supports it (see `CarbEstimationProviderType.supportsWebSearch`). Providers
    /// that can't search ignore this.
    var webSearch: Bool = false
}

/// One carbohydrate component of an estimated meal (fast carbs or FPU/slow).
struct CarbEstimateComponent: Identifiable {
    enum Kind {
        case fast   // fast-acting carbohydrates
        case fpu    // fat/protein units — slow carbs
    }

    let id = UUID()
    let kind: Kind
    /// Short caption describing what THIS box contains (e.g. "Pizza crust").
    let name: String
    /// One of the three preset emojis: 🍭 sugar/fast, 🌮 normal, 🍕 fat/slow.
    let emoji: String
    /// Estimated grams, ALWAYS a range (§6). `low <= high`.
    let gramsLow: Double
    let gramsHigh: Double
    /// Suggested absorption time for this component.
    let absorptionTime: TimeInterval
    /// Minutes this component should start AFTER the meal time (0 = at meal time).
    let offsetMinutes: Double
    /// One-sentence reason for the absorption-time suggestion.
    let absorptionReason: String

    /// Midpoint of the range, rounded — used to pre-fill the amount so the user
    /// can just tap Continue.
    var gramsMidpoint: Double { ((gramsLow + gramsHigh) / 2).rounded() }
}

/// Structured result of an estimation. 1...3 components (§7).
struct CarbEstimate {
    /// All foods identified, combined for the meal name.
    let mealName: String
    let components: [CarbEstimateComponent]
}

/// Uniform error type across all providers.
enum CarbEstimationError: LocalizedError {
    case aiDisabled
    case noAPIKey
    case notConfigured
    case unsupportedDevice
    case unreachable
    case timeout
    case badResponse

    var errorDescription: String? {
        switch self {
        case .aiDisabled:        return NSLocalizedString("AI carb estimation is turned off.", comment: "AI carb error: master toggle off")
        case .noAPIKey:          return NSLocalizedString("No API key is configured for this provider.", comment: "AI carb error: missing API key")
        case .notConfigured:     return NSLocalizedString("This provider is not fully configured.", comment: "AI carb error: not configured")
        case .unsupportedDevice: return NSLocalizedString("On-device estimation isn't supported on this device.", comment: "AI carb error: unsupported device")
        case .unreachable:       return NSLocalizedString("Couldn't reach the estimation service.", comment: "AI carb error: unreachable")
        case .timeout:           return NSLocalizedString("The estimation request timed out.", comment: "AI carb error: timeout")
        case .badResponse:       return NSLocalizedString("The estimation service returned an unexpected response.", comment: "AI carb error: bad response")
        }
    }
}

/// The abstraction the rest of the app depends on.
protocol CarbEstimationProvider {
    func estimate(_ input: CarbEstimationInput) async throws -> CarbEstimate
}

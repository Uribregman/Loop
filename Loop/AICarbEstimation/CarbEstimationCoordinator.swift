//
//  CarbEstimationCoordinator.swift
//  Loop
//
//  Orchestrates the estimation pipeline (§3): LiDAR (if available) → provider
//  call → reconciliation. Returns a CarbEstimate or throws a mapped error.
//
//  HARD BOUNDARY: this type has NO reference to the carb store / dosing code and
//  cannot save anything. It only produces an estimate for the UI to pre-fill.
//

import Foundation

struct CarbEstimationCoordinator {
    var settings = CarbEstimationSettings()
    var keychain = CarbAIKeychain()

    /// Run capture-result → estimate. `imageData` is the JPEG photo; `note` is
    /// the optional user annotation (§8).
    func estimate(images: [Data], note: String?) async throws -> CarbEstimate {
        let volume = await LiDARVolumeEstimator.estimateVolumeMilliliters()
        let provider = try CarbProviderFactory.makeProvider(settings: settings, keychain: keychain)
        // Web search is opt-in (its own toggle) AND only offered to providers that
        // support it; Apple On-Device / Custom always run without it.
        let webSearch = settings.isWebSearchEnabled && settings.provider.supportsWebSearch
        let input = CarbEstimationInput(images: images, note: note, volumeMilliliters: volume, webSearch: webSearch)
        let estimate = try await provider.estimate(input)

        // Log each suggested component for later accuracy review (confirmed values
        // are appended later, when the user submits the meal entry).
        for c in estimate.components {
            CarbEstimateLog.append(CarbEstimateLogEntry(
                date: Date(),
                provider: settings.provider.rawValue,
                suggestedGramsLow: c.gramsLow,
                suggestedGramsHigh: c.gramsHigh,
                suggestedAbsorptionSeconds: c.absorptionTime,
                confirmedGrams: nil,
                confirmedAbsorptionSeconds: nil
            ))
        }
        return estimate
    }
}

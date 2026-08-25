//
//  AppleOnDeviceCarbProvider.swift
//  Loop
//
//  Apple on-device provider using the Foundation Models framework (iOS 26.3+).
//  Runs privately on the Neural Engine, no API key, works offline.
//
//  IMPORTANT: The real Foundation Models call requires building against the
//  iOS 26.3+/27 SDK. To keep the app compiling on the current SDK, the on-device
//  path throws `.unsupportedDevice` so the coordinator falls back gracefully.
//  Fill in the framework call inside the availability block when building on the
//  newer SDK — the surrounding contract does not change.
//

import Foundation

struct AppleOnDeviceCarbProvider: CarbEstimationProvider {
    func estimate(_ input: CarbEstimationInput) async throws -> CarbEstimate {
        // TODO(iOS 26.3+ SDK): replace with a real Foundation Models multimodal
        // request that returns CarbEstimateWireFormat JSON, then:
        //   return try CarbEstimateWireFormat.decode(text: modelOutput)
        //
        // #if canImport(FoundationModels)
        // if #available(iOS 26.3, *) { ... }
        // #endif
        throw CarbEstimationError.unsupportedDevice
    }

    /// Whether on-device estimation is available on this device/OS.
    static var isAvailable: Bool {
        // Becomes a real capability check when built against the newer SDK.
        false
    }
}

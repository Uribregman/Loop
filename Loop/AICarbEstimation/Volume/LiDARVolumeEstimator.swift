//
//  LiDARVolumeEstimator.swift
//  Loop
//
//  Optional, isolated LiDAR-based food-volume estimate (§3A). No-op on devices
//  without a LiDAR sensor — returns nil so the pipeline runs photo-only.
//
//  Kept deliberately self-contained: it takes no part in dosing/algorithm and
//  only returns an auxiliary numeric hint to the provider call.
//

import Foundation
#if canImport(ARKit)
import ARKit
#endif

enum LiDARVolumeEstimator {
    /// Whether this device can provide scene depth (LiDAR).
    static var isSupported: Bool {
        #if canImport(ARKit)
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        #else
        return false
        #endif
    }

    /// Best-effort volume estimate in milliliters, or nil when unavailable.
    ///
    /// NOTE: a full ARKit mesh-integration capture is a larger piece of work; this
    /// returns nil today so the pipeline is fully functional photo-only. When the
    /// live-capture volume scan is implemented, return its result here — the rest
    /// of the pipeline already consumes an optional mL value and needs no changes.
    static func estimateVolumeMilliliters() async -> Double? {
        guard isSupported else { return nil }
        return nil
    }
}

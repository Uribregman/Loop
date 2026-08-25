//
//  Preferences.swift
//  Loop
//
//  Created by Jonas Björkert on 2024-02-25.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import HealthKit

struct Preferences: PreferencesProvider {
    
    static var shared = Preferences()
    
    private init() {}
    
    // Basal Lock Threshold
    var basalLockThreshold: HKQuantity {
        get {
            let key = "basalLockThreshold"
            if let value = UserDefaults.standard.value(forKey: key) as? Double {
                return HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value)
            } else {
                return HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 250)
            }
        }
        set {
            let key = "basalLockThreshold"
            let value = newValue.doubleValue(for: .milligramsPerDeciliter)
            UserDefaults.standard.set(value, forKey: key)
        }
    }
    
    // Basal Lock Enabled
    var isBasalLockEnabled: Bool {
        get {
            let key = "isBasalLockEnabled"
            if UserDefaults.standard.object(forKey: key) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        set {
            let key = "isBasalLockEnabled"
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

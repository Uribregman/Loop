//
//  CarbEstimateLog.swift
//  Loop
//
//  Local-only accuracy log (§4a): records what the AI suggested alongside what
//  the user actually confirmed. Stored in UserDefaults on-device; nothing is
//  sent anywhere beyond what the provider call already sent.
//

import Foundation

struct CarbEstimateLogEntry: Codable {
    let date: Date
    let provider: String
    let suggestedGramsLow: Double
    let suggestedGramsHigh: Double
    let suggestedAbsorptionSeconds: Double
    let confirmedGrams: Double?
    let confirmedAbsorptionSeconds: Double?
}

enum CarbEstimateLog {
    private static let key = "com.loopkit.Loop.aiCarb.log"
    private static let maxEntries = 200

    static func append(_ entry: CarbEstimateLogEntry) {
        var all = read()
        all.append(entry)
        if all.count > maxEntries { all.removeFirst(all.count - maxEntries) }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func read() -> [CarbEstimateLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([CarbEstimateLogEntry].self, from: data) else {
            return []
        }
        return all
    }
}

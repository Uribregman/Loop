//
//  MealMetadataStore.swift
//  Loop
//
//  Loop's carb records (StoredCarbEntry) don't persist a meal name, photo, or a
//  meal-level time — only a per-entry start time and an emoji. This local store
//  keeps that extra meal metadata so the history "Meals" view can show a proper
//  meal card. Nothing here touches LoopKit or the algorithm.
//

import Foundation
import UIKit
import LoopKit

struct MealMetadata: Codable, Identifiable {
    let id: String
    var name: String
    /// Meal (eating) time — distinct from each component's offset/start time.
    var mealTime: Date
    var photoFilename: String?
    /// Meal-level emoji the user picked (when not using a photo). Optional so old
    /// saved metadata still decodes.
    var emoji: String? = nil
    /// Start (offset) time of each component, used to match back to carb records.
    var componentStartDates: [Date]
    /// Caption for each component, aligned with `componentStartDates`.
    var componentNames: [String]

    /// Caption for the component whose start time matches `date`, if any.
    func name(forStart date: Date, tolerance: TimeInterval = 90) -> String? {
        for (i, d) in componentStartDates.enumerated() where abs(d.timeIntervalSince(date)) <= tolerance {
            return i < componentNames.count ? componentNames[i] : nil
        }
        return nil
    }
}

enum MealMetadataStore {
    private static let key = "com.loopkit.Loop.aiCarb.mealMetadata"
    private static let maxEntries = 300
    private static let matchTolerance: TimeInterval = 90   // seconds

    private static var photosDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AICarbMealPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Metadata

    static func all() -> [MealMetadata] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MealMetadata].self, from: data) else { return [] }
        return list
    }

    static func save(_ meta: MealMetadata) {
        var list = all()
        list.append(meta)
        if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Best metadata match for a group of carb records (by start-time overlap).
    static func match(entries: [StoredCarbEntry]) -> MealMetadata? {
        let starts = entries.map { $0.startDate }
        var best: (meta: MealMetadata, score: Int)?
        for meta in all() {
            let score = meta.componentStartDates.reduce(0) { acc, d in
                acc + (starts.contains { abs($0.timeIntervalSince(d)) <= matchTolerance } ? 1 : 0)
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (meta, score)
            }
        }
        return best?.meta
    }

    // MARK: - Photos

    static func savePhoto(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let filename = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: photosDirectory.appendingPathComponent(filename))
            return filename
        } catch {
            return nil
        }
    }

    static func loadPhoto(_ filename: String?) -> UIImage? {
        guard let filename else { return nil }
        return UIImage(contentsOfFile: photosDirectory.appendingPathComponent(filename).path)
    }
}

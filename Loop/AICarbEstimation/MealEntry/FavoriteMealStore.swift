//
//  FavoriteMealStore.swift
//  Loop
//
//  Full multi-component favorite meals. Loop's StoredFavoriteFood only holds ONE
//  carb quantity, so saving a meal with 1–3 carb slots needs its own store.
//  Time is intentionally NOT saved (a favorite is reusable across meal times).
//

import Foundation

struct FavoriteMealComponent: Codable {
    var amount: Double
    var foodEmoji: String
    var absorptionTime: TimeInterval
    var isFPU: Bool
    var caption: String
    /// Minutes after the meal time this component starts (0 = at meal time).
    /// Stored so a favorite restores its offset-time structure (e.g. an FPU
    /// tail that begins 2h after eating).
    var offsetMinutes: Double

    init(amount: Double, foodEmoji: String, absorptionTime: TimeInterval,
         isFPU: Bool, caption: String, offsetMinutes: Double = 0) {
        self.amount = amount
        self.foodEmoji = foodEmoji
        self.absorptionTime = absorptionTime
        self.isFPU = isFPU
        self.caption = caption
        self.offsetMinutes = offsetMinutes
    }

    // Backward-compatible decode: favorites saved before offsetMinutes existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try container.decode(Double.self, forKey: .amount)
        foodEmoji = try container.decode(String.self, forKey: .foodEmoji)
        absorptionTime = try container.decode(TimeInterval.self, forKey: .absorptionTime)
        isFPU = try container.decode(Bool.self, forKey: .isFPU)
        caption = try container.decode(String.self, forKey: .caption)
        offsetMinutes = try container.decodeIfPresent(Double.self, forKey: .offsetMinutes) ?? 0
    }
}

struct FavoriteMeal: Codable, Identifiable {
    let id: String
    var name: String
    var photoFilename: String?
    var components: [FavoriteMealComponent]
}

enum FavoriteMealStore {
    private static let key = "com.loopkit.Loop.aiCarb.favoriteMeals"

    static func all() -> [FavoriteMeal] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([FavoriteMeal].self, from: data) else { return [] }
        return list
    }

    private static func write(_ list: [FavoriteMeal]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func add(_ meal: FavoriteMeal) {
        var list = all()
        list.append(meal)
        write(list)
    }

    static func remove(id: String) {
        write(all().filter { $0.id != id })
    }

    /// Replace the meal with the same id (or append if it's new).
    static func update(_ meal: FavoriteMeal) {
        var list = all()
        if let idx = list.firstIndex(where: { $0.id == meal.id }) {
            list[idx] = meal
        } else {
            list.append(meal)
        }
        write(list)
    }

    // One-time migration of Loop's legacy single-quantity StoredFavoriteFood
    // entries into this store (performed by FavoriteFoodsView on first open).
    private static let migratedLegacyKey = key + ".migratedLegacy"
    static var didMigrateLegacy: Bool {
        UserDefaults.standard.bool(forKey: migratedLegacyKey)
    }
    static func markLegacyMigrated() {
        UserDefaults.standard.set(true, forKey: migratedLegacyKey)
    }
}

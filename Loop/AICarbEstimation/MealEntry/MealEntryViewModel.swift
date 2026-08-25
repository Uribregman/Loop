//
//  MealEntryViewModel.swift
//  Loop
//
//  Backs the redesigned meal-entry screen (§7). Presents ONE meal on screen but
//  writes 1–3 DISTINCT carb records underneath (never merged). Reuses Loop's
//  existing carb save API (delegate.addCarbEntry) — no algorithm/data-model change.
//
//  AI results only PRE-FILL sub-blocks; nothing is saved until the user taps the
//  pill / Continue (submit). §4a.
//

import SwiftUI
import LoopKit
import HealthKit
import Combine
import LoopCore

/// One carb record shown as a sub-block. 1–3 per meal.
struct MealCarbSubBlock: Identifiable {
    enum Kind { case fast, fpu }

    let id = UUID()
    var kind: Kind = .fast
    /// Short caption shown at the top of the box describing what it contains.
    var caption: String = ""
    /// Raw text the user types. Empty shows a grey "0" placeholder that never
    /// becomes a real value until the user types (§6/§7).
    var amountText: String = ""
    /// Per-sub-block start time; defaults to meal time when created (§7.3).
    var offsetTime: Date
    /// Selected emoji (food-type classification, functionally wired to absorption).
    /// Defaults to the taco (normal carbs) preset.
    var foodEmoji: String = MealFoodEmoji.medium
    var absorptionTime: TimeInterval
    /// Optional AI-suggested gram range, shown until the user edits `amount` (§6).
    var suggestedGramsLow: Double? = nil
    var suggestedGramsHigh: Double? = nil
    var absorptionReason: String? = nil

    var amount: Double? {
        let t = amountText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Double(t)
    }

    var hasValidAmount: Bool {
        if let amount, amount > 0 { return true }
        return false
    }
}

/// Emoji → absorption preset mapping, mirroring Loop's FoodEmojiShortcut.
enum MealFoodEmoji {
    static let fast = "🍭"    // candy — sugar / very fast
    static let medium = "🌮"  // taco — normal carbs
    static let slow = "🍕"    // pizza — fat & protein / slow
    static let other = "🍽️"  // plate — pick a custom emoji
    static let presets = [fast, medium, slow, other]

    /// Distinct caption for each preset (candy and taco differ).
    static func label(for emoji: String) -> String {
        switch emoji {
        case fast:   return NSLocalizedString("Sugar · very fast", comment: "Candy preset label")
        case medium: return NSLocalizedString("Normal carbs", comment: "Taco preset label")
        case slow:   return NSLocalizedString("Fat & protein · slow", comment: "Pizza preset label")
        default:     return NSLocalizedString("Carbs", comment: "Custom emoji label")
        }
    }
}

@MainActor
final class MealEntryViewModel: ObservableObject {
    private let unit = HKUnit.gram()
    private let maxSubBlocks = 4

    weak var delegate: CarbEntryViewModelDelegate?
    private let defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes

    @Published var mealName: String = ""
    @Published var usesPhoto: Bool = false
    @Published var mealImage: UIImage? = nil
    static let defaultMealEmoji = "🍽️"
    @Published var mealEmoji: String = MealEntryViewModel.defaultMealEmoji
    @Published var mealTime: Date = Date()
    /// Meal-level offset/start time, shown below the main time. The "+15" preset
    /// affects THIS, not the main meal time. Changing it propagates to every box.
    @Published var offsetTime: Date = Date()
    @Published var subBlocks: [MealCarbSubBlock]

    @Published var favoriteMeals = FavoriteMealStore.all()
    @Published var isFavorited = false
    @Published var didUsePlus15 = false
    private var savedFavoriteID: String?

    /// When set, the view pushes the bolus screen for the just-saved meal.
    @Published var bolusViewModel: BolusEntryViewModel?
    @Published var isSaving = false
    /// Editing an existing meal from history sets this so the view dismisses on save.
    @Published var shouldDismiss = false

    /// The existing records being edited, if this VM was opened from history.
    private var editingEntries: [StoredCarbEntry] = []
    var isEditing: Bool { !editingEntries.isEmpty }

    /// FAVORITE-EDITING MODE (Settings → Favorite Foods): the same meal-entry
    /// UI edits a FavoriteMeal. submit() saves ONLY to FavoriteMealStore —
    /// there is no delegate and no carb-record save path in this mode.
    private var editingFavorite: FavoriteMeal?
    private(set) var isFavoriteEditing = false

    /// Supplied by the caller (history screen) to delete a record when a box is
    /// removed while editing. Calls the completion when done.
    var deleteHandler: ((StoredCarbEntry, @escaping () -> Void) -> Void)?

    /// How many original records would be deleted by the current edit (removed boxes).
    var pendingDeletionCount: Int {
        guard isEditing else { return 0 }
        let validBoxes = subBlocks.filter { $0.hasValidAmount }.count
        return max(0, editingEntries.count - validBoxes)
    }

    private let maxQuantity = LoopConstants.maxCarbEntryQuantity

    init(delegate: CarbEntryViewModelDelegate) {
        self.delegate = delegate
        self.defaultAbsorptionTimes = delegate.defaultAbsorptionTimes
        let now = Date()
        self.mealTime = now
        self.offsetTime = now
        self.subBlocks = [MealCarbSubBlock(offsetTime: now, absorptionTime: delegate.defaultAbsorptionTimes.medium)]
    }

    /// Editing initializer — loads an existing meal (1–3 records) for editing.
    init(delegate: CarbEntryViewModelDelegate, editing entries: [StoredCarbEntry]) {
        // Build everything in locals first — the closure must not touch `self`
        // before all stored properties are initialized.
        let absorption = delegate.defaultAbsorptionTimes
        let gramUnit = HKUnit.gram()
        let sorted = entries.sorted { $0.startDate < $1.startDate }
        let start = sorted.first?.startDate ?? Date()
        // StoredCarbEntry carries no meal name/photo — look those up in the
        // metadata store (matched by component start-time overlap).
        let metadata = MealMetadataStore.match(entries: sorted)
        let blocks: [MealCarbSubBlock] = sorted.prefix(4).map { e in
            var b = MealCarbSubBlock(offsetTime: e.startDate,
                                     absorptionTime: e.absorptionTime ?? absorption.medium)
            b.foodEmoji = e.foodType ?? ""
            if b.foodEmoji == MealFoodEmoji.slow { b.kind = .fpu }
            let grams = e.quantity.doubleValue(for: gramUnit)
            b.amountText = grams == grams.rounded() ? String(Int(grams)) : String(grams)
            // Prefer the saved per-component caption; fall back to the emoji.
            b.caption = metadata?.name(forStart: e.startDate) ?? e.foodType ?? ""
            return b
        }

        self.delegate = delegate
        self.defaultAbsorptionTimes = absorption
        self.editingEntries = sorted
        // Use the saved meal time when available (distinct from the earliest
        // component start), else fall back to the earliest component start.
        self.mealTime = metadata?.mealTime ?? start
        self.offsetTime = start
        self.subBlocks = blocks

        // Restore the meal name + photo that StoredCarbEntry can't hold.
        if let metadata {
            self.mealName = metadata.name
            if let image = MealMetadataStore.loadPhoto(metadata.photoFilename) {
                self.mealImage = image
                self.usesPhoto = true
            } else if let emoji = metadata.emoji {
                self.mealEmoji = emoji
                self.usesPhoto = false
            }
        }
    }

    /// Favorite-editing initializer — no delegate, no carb saving. Pass nil to
    /// create a new favorite, or an existing FavoriteMeal to edit it.
    init(editingFavorite favorite: FavoriteMeal?) {
        self.delegate = nil
        self.defaultAbsorptionTimes = LoopCoreConstants.defaultCarbAbsorptionTimes
        let now = Date()
        self.mealTime = now
        self.offsetTime = now
        self.isFavoriteEditing = true
        self.editingFavorite = favorite

        if let favorite {
            let blocks: [MealCarbSubBlock] = favorite.components.prefix(4).map { c in
                var b = MealCarbSubBlock(offsetTime: now.addingTimeInterval(c.offsetMinutes * 60),
                                         absorptionTime: c.absorptionTime)
                b.foodEmoji = c.foodEmoji
                b.kind = c.isFPU ? .fpu : .fast
                b.caption = c.caption
                b.amountText = c.amount == c.amount.rounded() ? String(Int(c.amount)) : String(c.amount)
                return b
            }
            self.subBlocks = blocks.isEmpty
                ? [MealCarbSubBlock(offsetTime: now, absorptionTime: LoopCoreConstants.defaultCarbAbsorptionTimes.medium)]
                : blocks
            self.mealName = favorite.name
            if let filename = favorite.photoFilename, let image = MealMetadataStore.loadPhoto(filename) {
                self.mealImage = image
                self.usesPhoto = true
            }
        } else {
            self.subBlocks = [MealCarbSubBlock(offsetTime: now, absorptionTime: LoopCoreConstants.defaultCarbAbsorptionTimes.medium)]
        }
    }

    // MARK: - Sub-block management

    var canAddSubBlock: Bool { subBlocks.count < maxSubBlocks }

    func addSubBlock() {
        guard canAddSubBlock else { return }
        subBlocks.append(MealCarbSubBlock(offsetTime: offsetTime, absorptionTime: defaultAbsorptionTimes.medium))
    }

    func removeSubBlock(_ id: UUID) {
        guard subBlocks.count > 1 else { return }
        subBlocks.removeAll { $0.id == id }
    }

    /// Select one of the three preset emojis. First it sets the emoji, then it
    /// updates the absorption time accordingly (candy 0.5h / taco 3h / pizza 5h).
    /// The user can still adjust the exact absorption afterwards via the wheel.
    /// The plate (custom) emoji is handled separately and never changes absorption.
    func selectEmoji(_ emoji: String, for id: UUID) {
        guard let idx = subBlocks.firstIndex(where: { $0.id == id }) else { return }
        subBlocks[idx].foodEmoji = emoji
        switch emoji {
        case MealFoodEmoji.fast:
            subBlocks[idx].kind = .fast; subBlocks[idx].absorptionTime = defaultAbsorptionTimes.fast
        case MealFoodEmoji.medium:
            subBlocks[idx].kind = .fast; subBlocks[idx].absorptionTime = defaultAbsorptionTimes.medium
        case MealFoodEmoji.slow:
            subBlocks[idx].kind = .fpu; subBlocks[idx].absorptionTime = defaultAbsorptionTimes.slow
        default:
            break
        }
    }

    /// Set a custom emoji (from the emoji keyboard) without altering absorption.
    func setCustomEmoji(_ emoji: String, for id: UUID) {
        guard let idx = subBlocks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = emoji.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first { subBlocks[idx].foodEmoji = String(first) }
    }

    // MARK: - Time presets

    /// "+15" preset — sets the OFFSET time to 15 minutes from now WITHOUT touching
    /// the main meal time. Marks itself used so the UI can dim it afterwards.
    func setOffsetPlus15() {
        offsetTime = Date().addingTimeInterval(15 * 60)
        didUsePlus15 = true
        propagateOffset()
    }

    @Published var didUsePlus15Meal = false

    /// "+15" preset on the MAIN meal time — moves the meal time (and, as with any
    /// main-time change, the offset follows it).
    func setMealTimePlus15() {
        mealTime = Date().addingTimeInterval(15 * 60)
        offsetTime = mealTime
        propagateOffset()
        didUsePlus15Meal = true
    }

    /// Apply the meal-level offset time to every carb box.
    func propagateOffset() {
        for i in subBlocks.indices { subBlocks[i].offsetTime = offsetTime }
    }

    // MARK: - Favorites

    var matchingFavorites: [FavoriteMeal] {
        guard !mealName.isEmpty else { return [] }
        return favoriteMeals.filter { $0.name.localizedCaseInsensitiveContains(mealName) }
    }

    /// Apply a favorite: fills name + photo + ALL carb sub-blocks (NOT time — §7).
    func applyFavorite(_ meal: FavoriteMeal) {
        mealName = meal.name
        if let filename = meal.photoFilename, let image = MealMetadataStore.loadPhoto(filename) {
            mealImage = image
            usesPhoto = true
        }
        let blocks = meal.components.prefix(maxSubBlocks).map { c -> MealCarbSubBlock in
            var b = MealCarbSubBlock(offsetTime: offsetTime.addingTimeInterval(c.offsetMinutes * 60),
                                     absorptionTime: c.absorptionTime)
            b.foodEmoji = c.foodEmoji
            b.kind = c.isFPU ? .fpu : .fast
            b.caption = c.caption
            b.amountText = formatAmount(c.amount)
            return b
        }
        if !blocks.isEmpty { subBlocks = Array(blocks) }
    }

    private func formatAmount(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Heart: toggle saving the current config as a favorite (excludes time — §7).
    /// Saves ALL carb slots. Filled heart = saved; tapping again removes it.
    func toggleFavorite() {
        if isFavorited, let id = savedFavoriteID {
            FavoriteMealStore.remove(id: id)
            favoriteMeals = FavoriteMealStore.all()
            savedFavoriteID = nil
            isFavorited = false
            return
        }
        let validBlocks = subBlocks.filter { $0.hasValidAmount }
        guard !validBlocks.isEmpty else { return }
        let components = validBlocks.map { block in
            FavoriteMealComponent(
                amount: block.amount ?? 0,
                foodEmoji: block.foodEmoji,
                absorptionTime: block.absorptionTime,
                isFPU: block.kind == .fpu,
                caption: block.caption,
                offsetMinutes: (block.offsetTime.timeIntervalSince(mealTime) / 60).rounded()
            )
        }
        let photoFilename = (usesPhoto && mealImage != nil) ? MealMetadataStore.savePhoto(mealImage!) : nil
        let meal = FavoriteMeal(
            id: UUID().uuidString,
            name: mealName.isEmpty ? NSLocalizedString("Meal", comment: "Default favorite meal name") : mealName,
            photoFilename: photoFilename,
            components: components
        )
        FavoriteMealStore.add(meal)
        favoriteMeals = FavoriteMealStore.all()
        savedFavoriteID = meal.id
        isFavorited = true
    }

    // MARK: - AI pre-fill

    /// Populate sub-blocks from an AI estimate (pre-filled, editable, NOT saved).
    /// Amounts are left nil so the range is shown until the user confirms (§6).
    func applyEstimate(_ estimate: CarbEstimate) {
        let blocks = estimate.components.prefix(maxSubBlocks).map { c -> MealCarbSubBlock in
            // Offset time is meal time plus the AI's per-component offset.
            var b = MealCarbSubBlock(offsetTime: mealTime.addingTimeInterval(c.offsetMinutes * 60),
                                     absorptionTime: c.absorptionTime)
            b.kind = (c.kind == .fpu) ? .fpu : .fast
            b.foodEmoji = c.emoji                          // one of the 3 presets
            b.caption = c.name                             // "what it contains" at the top
            b.amountText = formatAmount(c.gramsMidpoint)   // pre-filled → just tap Continue
            b.suggestedGramsLow = c.gramsLow
            b.suggestedGramsHigh = c.gramsHigh
            b.absorptionReason = c.absorptionReason
            return b
        }
        if !blocks.isEmpty {
            subBlocks = Array(blocks)
            mealName = estimate.mealName          // all foods, not just one
        }
    }

    // MARK: - Submit (the ONLY save path)

    var submitDisabled: Bool { !subBlocks.contains { $0.hasValidAmount } }

    /// Builds one NewCarbEntry per valid sub-block. Never merges.
    private func buildEntries() -> [NewCarbEntry] {
        subBlocks.compactMap { block in
            guard let amount = block.amount, amount > 0 else { return nil }
            let clamped = min(amount, maxQuantity.doubleValue(for: unit))
            return NewCarbEntry(
                date: Date(),
                quantity: HKQuantity(unit: unit, doubleValue: clamped),
                startDate: block.offsetTime,
                foodType: block.foodEmoji.isEmpty ? nil : block.foodEmoji,
                absorptionTime: block.absorptionTime
            )
        }
    }

    /// Saves all sub-blocks as distinct records, then offers the bolus screen.
    /// In favorite-editing mode it saves ONLY the favorite (no carb records).
    func submit() {
        if isFavoriteEditing {
            submitFavorite()
            return
        }
        guard let delegate, !submitDisabled, !isSaving else { return }
        let entries = buildEntries()
        guard !entries.isEmpty else { return }
        isSaving = true

        // Log confirmed values for AI accuracy review (§4a).
        for (block, entry) in zip(subBlocks.filter({ $0.hasValidAmount }), entries) {
            if block.suggestedGramsLow != nil {
                CarbEstimateLog.append(CarbEstimateLogEntry(
                    date: Date(),
                    provider: CarbEstimationSettings().provider.rawValue,
                    suggestedGramsLow: block.suggestedGramsLow ?? 0,
                    suggestedGramsHigh: block.suggestedGramsHigh ?? 0,
                    suggestedAbsorptionSeconds: block.absorptionTime,
                    confirmedGrams: entry.quantity.doubleValue(for: unit),
                    confirmedAbsorptionSeconds: entry.absorptionTime
                ))
            }
        }

        saveMealMetadata(for: entries)

        if isEditing {
            submitEdits(entries: entries, delegate: delegate)
        } else {
            submitNewMeal(entries: entries, delegate: delegate)
        }
    }

    /// Favorite-editing save: writes the FavoriteMeal (new or replaced) to
    /// FavoriteMealStore and dismisses. NO carb entries are created here.
    private func submitFavorite() {
        let validBlocks = subBlocks.filter { $0.hasValidAmount }
        guard !validBlocks.isEmpty else { return }
        let components = validBlocks.map { block in
            FavoriteMealComponent(
                amount: block.amount ?? 0,
                foodEmoji: block.foodEmoji,
                absorptionTime: block.absorptionTime,
                isFPU: block.kind == .fpu,
                caption: block.caption,
                offsetMinutes: (block.offsetTime.timeIntervalSince(mealTime) / 60).rounded()
            )
        }
        let photoFilename = (usesPhoto && mealImage != nil) ? MealMetadataStore.savePhoto(mealImage!) : nil
        let trimmedName = mealName.trimmingCharacters(in: .whitespaces)
        let meal = FavoriteMeal(
            id: editingFavorite?.id ?? UUID().uuidString,
            name: trimmedName.isEmpty ? NSLocalizedString("Meal", comment: "Default favorite meal name") : trimmedName,
            photoFilename: photoFilename,
            components: components
        )
        FavoriteMealStore.update(meal)
        favoriteMeals = FavoriteMealStore.all()
        shouldDismiss = true
    }

    /// Persist the meal name / photo / meal-time so the history "Meals" card can
    /// show them (StoredCarbEntry doesn't carry this metadata).
    private func saveMealMetadata(for entries: [NewCarbEntry]) {
        let trimmedName = mealName.trimmingCharacters(in: .whitespaces)
        let hasPhoto = usesPhoto && mealImage != nil
        // Save metadata for anything that is a "meal": has a name, a photo, or more
        // than one component (so multi-box meals stay grouped and never mix).
        guard !trimmedName.isEmpty || hasPhoto || entries.count > 1 else { return }
        let photoFilename = hasPhoto ? MealMetadataStore.savePhoto(mealImage!) : nil
        let validBlocks = subBlocks.filter { $0.hasValidAmount }
        let names = validBlocks.map { $0.caption.isEmpty ? $0.foodEmoji : $0.caption }
        // Persist the user-chosen meal emoji (skip the default 🍽️ so unchosen meals
        // keep falling back to the first component's food emoji in the history cell).
        let chosenEmoji = (!hasPhoto && mealEmoji != Self.defaultMealEmoji) ? mealEmoji : nil
        MealMetadataStore.save(MealMetadata(
            id: UUID().uuidString,
            name: trimmedName,
            mealTime: mealTime,
            photoFilename: photoFilename,
            emoji: chosenEmoji,
            componentStartDates: entries.map { $0.startDate },
            componentNames: names
        ))
    }

    /// New meal → behave like the old carb→bolus flow: the FIRST box is handed to
    /// the bolus screen as a potential entry (so the recommended bolus auto-fills
    /// and the button reads "Save Carbs and Deliver"/"Save without Bolusing"), and
    /// any extra boxes are saved immediately.
    private func submitNewMeal(entries: [NewCarbEntry], delegate: CarbEntryViewModelDelegate) {
        isSaving = true
        let first = entries[0]
        let firstEmoji = subBlocks.first(where: { $0.hasValidAmount })?.foodEmoji ?? ""
        let extras = Array(entries.dropFirst())
        Task { @MainActor in
            // Save the extra boxes ONE AT A TIME — concurrent addCarbEntry calls
            // (3+ at once for a 4-component meal) raced inside the carb store.
            for entry in extras {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    delegate.addCarbEntry(entry, replacing: nil) { _ in cont.resume() }
                }
            }
            let vm = BolusEntryViewModel(
                delegate: delegate,
                screenWidth: UIScreen.main.bounds.width,
                potentialCarbEntry: first,
                selectedCarbAbsorptionTimeEmoji: firstEmoji
            )
            vm.analyticsServicesManager = delegate.analyticsServicesManager
            bolusViewModel = vm
            isSaving = false
            // Pre-fill the recommended bolus into the entry box (like the old version),
            // ready for the user to confirm. Localized to this flow only.
            Task { @MainActor in
                await vm.generateRecommendationAndStartObserving()
                if let rec = vm.recommendedBolusAmount, rec > 0 {
                    vm.updateEnteredBolus(rec)
                }
            }
        }
    }

    /// Editing an existing meal → like the new-meal flow, the FIRST box is handed
    /// to the bolus screen (as a replacement of its original record) so the user
    /// can bolus for the edit; any extra boxes are replaced/added immediately and
    /// removed boxes are deleted. Previously this path just saved and dismissed,
    /// which skipped the bolus screen entirely — that was the reported bug.
    private func submitEdits(entries: [NewCarbEntry], delegate: CarbEntryViewModelDelegate) {
        isSaving = true
        let originals = editingEntries
        let first = entries[0]
        let firstOriginal = originals.first
        let firstEmoji = subBlocks.first(where: { $0.hasValidAmount })?.foodEmoji ?? ""
        // Extras (everything after the first) keep index-paired replacements.
        let extras = Array(entries.enumerated().dropFirst())
        let toDelete = originals.count > entries.count ? Array(originals[entries.count...]) : []

        Task { @MainActor in
            // Save/replace the extra boxes ONE AT A TIME — concurrent addCarbEntry
            // calls (3+ at once for a 4-component meal) raced inside the carb store.
            for (i, entry) in extras {
                let replacing = i < originals.count ? originals[i] : nil
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    delegate.addCarbEntry(entry, replacing: replacing) { _ in cont.resume() }
                }
            }
            for entry in toDelete {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if let deleteHandler {
                        deleteHandler(entry) { cont.resume() }
                    } else {
                        cont.resume()
                    }
                }
            }

            // Hand the first box to the bolus screen, replacing its original record
            // there (so the recommended bolus accounts for the edited carbs).
            let vm = BolusEntryViewModel(
                delegate: delegate,
                screenWidth: UIScreen.main.bounds.width,
                originalCarbEntry: firstOriginal,
                potentialCarbEntry: first,
                selectedCarbAbsorptionTimeEmoji: firstEmoji
            )
            vm.analyticsServicesManager = delegate.analyticsServicesManager
            bolusViewModel = vm
            isSaving = false
            Task { @MainActor in
                await vm.generateRecommendationAndStartObserving()
                if let rec = vm.recommendedBolusAmount, rec > 0 {
                    vm.updateEnteredBolus(rec)
                }
            }
        }
    }
}

//
//  FavoriteFoodsView.swift
//  Loop
//
//  Created by Noah Brauner on 7/12/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//
//  Rewritten for the AI-carb redesign: favorites are multi-component
//  FavoriteMeals edited with the SAME meal-entry UI as the carb screen
//  (sub-blocks, offset time, emoji presets). In this mode the editor saves
//  ONLY to FavoriteMealStore — it cannot create carb records.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

struct FavoriteFoodsView: View {
    @Environment(\.dismissAction) private var dismiss

    @State private var meals: [FavoriteMeal] = []
    @State private var editorMeal: FavoriteMeal?
    @State private var showAddEditor = false
    @State private var mealToDelete: FavoriteMeal?

    var body: some View {
        NavigationView {
            List {
                if meals.isEmpty {
                    Section {
                        Text("Selecting a favorite meal in the carb entry screen automatically fills in the name, photo, and every carb box — amounts, food types, absorption and offset times. Tap the add button below to create your first favorite!",
                             comment: "Empty state of the favorite foods screen")
                    }
                } else {
                    Section(header: listHeader) {
                        ForEach(meals) { meal in
                            Button {
                                editorMeal = meal
                            } label: {
                                row(for: meal)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    mealToDelete = meal
                                } label: {
                                    Label(NSLocalizedString("Delete", comment: "Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section {
                    addFoodButton
                        .listRowInsets(EdgeInsets())
                }
            }
            .insetGroupedListStyle()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: dismiss) {
                        Text("Done", comment: "Done button on favorite foods screen")
                    }
                }
            }
            .navigationBarTitle(String(localized: "Favorite Foods", comment: "Title for Favorite Foods view"), displayMode: .large)
            .loopSoftTopEdge()
        }
        .onAppear {
            migrateLegacyFavoritesIfNeeded()
            reload()
        }
        .sheet(isPresented: $showAddEditor, onDismiss: reload) {
            favoriteEditor(nil)
        }
        .sheet(item: $editorMeal, onDismiss: reload) { meal in
            favoriteEditor(meal)
        }
        .alert(
            Text("Delete this favorite?", comment: "Delete favorite meal alert title"),
            isPresented: Binding(get: { mealToDelete != nil }, set: { if !$0 { mealToDelete = nil } })
        ) {
            Button(NSLocalizedString("Delete", comment: "Delete"), role: .destructive) {
                if let meal = mealToDelete {
                    FavoriteMealStore.remove(id: meal.id)
                    reload()
                }
                mealToDelete = nil
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) { mealToDelete = nil }
        }
    }

    // MARK: - Editor (the NEW meal-entry UI in favorite mode)

    private func favoriteEditor(_ meal: FavoriteMeal?) -> some View {
        MealEntryView(viewModel: MealEntryViewModel(editingFavorite: meal))
            .environment(\.dismissAction, {
                showAddEditor = false
                editorMeal = nil
            })
    }

    // MARK: - Rows

    private func row(for meal: FavoriteMeal) -> some View {
        HStack(spacing: 12) {
            if let filename = meal.photoFilename, let image = MealMetadataStore.loadPhoto(filename) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text(meal.components.first?.foodEmoji ?? "🍽️")
                    .font(.title2)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.name)
                    .foregroundStyle(.primary)
                Text(summary(for: meal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    /// "🌮 45 g · 🍕 20 g (+2h)" — every box with its offset when nonzero.
    private func summary(for meal: FavoriteMeal) -> String {
        meal.components.map { c in
            var part = "\(c.foodEmoji) \(Int(c.amount)) g"
            if c.offsetMinutes != 0 {
                let hours = c.offsetMinutes / 60
                part += hours == hours.rounded()
                    ? " (+\(Int(hours))h)"
                    : " (+\(Int(c.offsetMinutes))m)"
            }
            return part
        }.joined(separator: " · ")
    }

    private var listHeader: some View {
        Text("All Favorites", comment: "section header for list of existing FavoriteFoods")
            .font(.title3)
            .fontWeight(.semibold)
            .textCase(nil)
            .foregroundColor(.primary)
            .listRowInsets(EdgeInsets(top: 20, leading: 4, bottom: 10, trailing: 4))
    }

    private var addFoodButton: some View {
        Button {
            showAddEditor = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("Add a new favorite food", comment: "Button label to open new favorite food view")
            }
        }
        .buttonStyle(PillActionButtonStyle())
    }

    // MARK: - Data

    private func reload() {
        meals = FavoriteMealStore.all()
    }

    /// One-time import of Loop's legacy single-quantity favorites so they keep
    /// appearing here. The legacy store itself is left untouched.
    private func migrateLegacyFavoritesIfNeeded() {
        guard !FavoriteMealStore.didMigrateLegacy else { return }
        for food in UserDefaults.standard.favoriteFoods {
            let grams = food.carbsQuantity.doubleValue(for: .gram())
            FavoriteMealStore.add(FavoriteMeal(
                id: UUID().uuidString,
                name: food.name,
                photoFilename: nil,
                components: [FavoriteMealComponent(
                    amount: grams,
                    foodEmoji: food.foodType,
                    absorptionTime: food.absorptionTime,
                    isFPU: false,
                    caption: "",
                    offsetMinutes: 0
                )]
            ))
        }
        FavoriteMealStore.markLegacyMigrated()
    }
}

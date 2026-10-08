//
//  MealEntryView.swift
//  Loop
//
//  Meal-entry screen, rebuilt on native iOS 26 controls.
//
//  Layout: two floating Liquid Glass bubbles pinned to the top — the meal time
//  on the left, the meal identity on the right — over a scroll of carb boxes.
//
//  No value editor can trap you:
//    • times          → `DatePicker(.compact)`  (self-dismissing popover)
//    • absorption     → a chip + wheel in a self-dismissing popover
//    • the bubbles    → close on a tap anywhere around them
//  There is deliberately no custom "which picker is open" state. The previous
//  version tracked that by hand and inlined `.wheel` pickers, which pushed the
//  very chip that opened them out from under the user's finger — leaving no
//  reliable way back out. Native controls own their own dismissal.
//
//  AI compatibility: this file is presentation only. `MealEntryViewModel` is
//  untouched, so AI prefill of the name, emoji and sub-blocks still applies.
//

import SwiftUI
import UIKit
import LoopKit
import LoopKitUI

struct MealEntryView: View {
    @ObservedObject var viewModel: MealEntryViewModel
    @Environment(\.dismissAction) private var dismiss
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    /// The two floating top bubbles. Only one is open at a time.
    enum TopBubble: Hashable { case time, meal }
    @State private var expandedBubble: TopBubble?

    /// Shared namespace so the bubbles morph as one glass material.
    @Namespace private var bubbleGlass

    @State private var showFavorites = false
    @State private var showPhotoPicker = false
    @State private var showPhotoOrEmojiChoice = false
    @State private var showMealEmojiPicker = false
    @State private var headerPickerSource: UIImagePickerController.SourceType = .photoLibrary
    @State private var emojiPickerBlockID: UUID?
    /// Which block's offset-time / absorption wheel is showing, if any.
    @State private var offsetPickerBlockID: UUID?
    @State private var absorptionPickerBlockID: UUID?
    @State private var showDeleteConfirm = false

    @FocusState private var amountFocus: UUID?

    /// Drives the floating pill's clearance above the numeric keypad.
    @StateObject private var keyboard = LoopKeyboardObserver()

    /// Height reserved at the top of the scroll so the collapsed bubbles never
    /// sit over a carb box.
    private static let topBubbleReservedHeight: CGFloat = 58
    private static let bubbleWidth: CGFloat = 236

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottomTrailing) {
                Color.loopScreenBackground
                    .ignoresSafeArea()
                    .onTapGesture { collapseBubbles() }

                ScrollView {
                    VStack(spacing: 16) {
                        Color.clear.frame(height: Self.topBubbleReservedHeight)
                        ForEach($viewModel.subBlocks) { $block in
                            subBlockCard($block)
                        }
                        if viewModel.canAddSubBlock {
                            addSubBlockButton
                        }
                        Color.clear.frame(height: 112) // room for the floating pill
                    }
                    .padding(.horizontal, 16)
                    .animation(.spring(response: 0.35, dampingFraction: 0.82), value: viewModel.subBlocks.count)
                }
                .scrollDismissesKeyboard(.interactively)

                // Dismiss layer for the bubbles. Above the scroll content but
                // below the bubbles themselves, so tapping ANYWHERE around an
                // open bubble closes it. `Color.clear` is unreliable for hit
                // testing — a hair of opacity is not.
                if isMenuInteractionShieldPresented {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { dismissMenus() }
                }

                continuePill
                bolusNavigationLink
            }
            .overlay(alignment: .top) { topBubbles }
            .navigationTitle(viewModel.isFavoriteEditing
                ? Text("Favorite Meal", comment: "Favorite meal editor title")
                : Text("Add Meal", comment: "Meal entry screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .loopSoftTopEdge()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismiss) { Text("Cancel", comment: "Button label for cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirmSubmit) {
                        viewModel.isFavoriteEditing
                            ? Text("Save", comment: "Button label to save a favorite meal")
                            : Text("Continue", comment: "Button label for continue")
                    }
                    .disabled(viewModel.submitDisabled)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                MealImagePicker(image: $viewModel.mealImage, source: headerPickerSource) { viewModel.usesPhoto = $0 }
            }
            .confirmationDialog(
                Text("Meal Photo", comment: "Meal photo chooser title"),
                isPresented: $showPhotoOrEmojiChoice, titleVisibility: .visible
            ) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button(NSLocalizedString("Take Photo", comment: "Take photo")) {
                        headerPickerSource = .camera; showPhotoPicker = true
                    }
                }
                Button(NSLocalizedString("Choose from Library", comment: "Choose from library")) {
                    headerPickerSource = .photoLibrary; showPhotoPicker = true
                }
                Button(NSLocalizedString("Choose Emoji", comment: "Pick a meal emoji")) {
                    viewModel.usesPhoto = false
                    showMealEmojiPicker = true
                }
            }
            .sheet(isPresented: $showMealEmojiPicker) {
                EmojiPickerSheet { picked in
                    let trimmed = picked.trimmingCharacters(in: .whitespaces)
                    if let first = trimmed.first { viewModel.mealEmoji = String(first) }
                    viewModel.usesPhoto = false
                    showMealEmojiPicker = false
                }
            }
            .sheet(isPresented: Binding(get: { emojiPickerBlockID != nil },
                                        set: { if !$0 { emojiPickerBlockID = nil } })) {
                EmojiPickerSheet { picked in
                    if let id = emojiPickerBlockID { viewModel.setCustomEmoji(picked, for: id) }
                    emojiPickerBlockID = nil
                }
            }
            .onChange(of: viewModel.shouldDismiss) { _, finished in
                if finished { dismiss() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: viewModel.subBlocks.count)
            .sensoryFeedback(.selection, trigger: expandedBubble)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: viewModel.isFavorited)
            .sensoryFeedback(.success, trigger: viewModel.shouldDismiss) { _, new in new }
            .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.didUsePlus15Meal) { _, new in new }
            .alert(Text("Delete carb entries?", comment: "Delete confirmation title"),
                   isPresented: $showDeleteConfirm) {
                Button(NSLocalizedString("Delete", comment: "Delete"), role: .destructive) { viewModel.submit() }
                Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(format: NSLocalizedString("This will remove %d carb record(s) you took out of this meal.", comment: "Delete confirmation body"), viewModel.pendingDeletionCount))
            }
        }
    }

    private func confirmSubmit() {
        if viewModel.pendingDeletionCount > 0 {
            showDeleteConfirm = true
        } else {
            viewModel.submit()
        }
    }

    // MARK: - Floating top bubbles

    private func bubbleShape(expanded: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: expanded ? loopTileCornerRadius : 22, style: .continuous)
    }

    /// Both bubbles in ONE container, so the system renders them as a single
    /// glass material and they morph rather than cross-fade.
    private var topBubbles: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                timeBubble
                Spacer(minLength: 0)
                mealBubble
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var isMenuInteractionShieldPresented: Bool {
        expandedBubble != nil || offsetPickerBlockID != nil || absorptionPickerBlockID != nil
    }

    private func dismissMenus() {
        collapseBubbles()
        offsetPickerBlockID = nil
        absorptionPickerBlockID = nil
    }

    private func collapseBubbles() {
        guard expandedBubble != nil else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { expandedBubble = nil }
    }

    private func toggleBubble(_ bubble: TopBubble) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            expandedBubble = (expandedBubble == bubble) ? nil : bubble
        }
    }

    // MARK: Time bubble

    /// The meal time IS the start time — the universal offset control is gone,
    /// so setting this propagates to every carb box.
    private var mealTimeBinding: Binding<Date> {
        Binding(
            get: { viewModel.mealTime },
            set: {
                viewModel.mealTime = $0
                viewModel.offsetTime = $0
                viewModel.propagateOffset()
            }
        )
    }

    private var timeBubble: some View {
        let isOpen = expandedBubble == .time
        return VStack(alignment: .leading, spacing: 12) {
            Button { toggleBubble(.time) } label: {
                HStack(spacing: 8) {
                    if isOpen {
                        Image(systemName: "clock.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(viewModel.mealTime, style: .time)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressExpandButtonStyle())

            if isOpen {
                VStack(spacing: 12) {
                    // Compact, NOT wheel: the system popover dismisses itself,
                    // so there is always a way out.
                    DatePicker("", selection: mealTimeBinding, displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.compact)
                        .labelsHidden()
                    mealPlus15Button
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .frame(width: isOpen ? Self.bubbleWidth : nil, alignment: .leading)
        .contentShape(bubbleShape(expanded: isOpen))
        .onTapGesture {}
        .glassEffect(.regular.interactive(), in: bubbleShape(expanded: isOpen))
        .glassEffectID("mealTimeBubble", in: bubbleGlass)
    }

    private var mealPlus15Button: some View {
        Button { viewModel.setMealTimePlus15() } label: {
            Text("+15", comment: "Preset button: meal time 15 minutes from now")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(viewModel.didUsePlus15Meal ? Color.secondary : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(GlassButtonStyle(
            viewModel.didUsePlus15Meal ? .regular : .regular.tint(Color.loopControlTint).interactive(),
            in: Capsule()))
        .disabled(viewModel.didUsePlus15Meal)
    }

    // MARK: Meal bubble

    /// True only once the user actually picked something — the default plate is
    /// not worth showing next to the name.
    private var hasChosenMealGlyph: Bool {
        (viewModel.usesPhoto && viewModel.mealImage != nil)
            || viewModel.mealEmoji != MealEntryViewModel.defaultMealEmoji
    }

    @ViewBuilder
    private var mealGlyph: some View {
        if viewModel.usesPhoto, let img = viewModel.mealImage {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 26, height: 26).clipShape(Circle())
        } else {
            Text(viewModel.mealEmoji).font(.body)
        }
    }

    private var mealBubble: some View {
        let isOpen = expandedBubble == .meal
        return VStack(alignment: .leading, spacing: 12) {
            Button { toggleBubble(.meal) } label: {
                HStack(spacing: 8) {
                    if hasChosenMealGlyph { mealGlyph }
                    Text(viewModel.mealName.isEmpty
                         ? NSLocalizedString("Carbs", comment: "Default meal name when none was entered")
                         : viewModel.mealName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(viewModel.mealName.isEmpty ? .secondary : .primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressExpandButtonStyle())

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(NSLocalizedString("Meal name", comment: "Placeholder for meal name"),
                              text: $viewModel.mealName)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .submitLabel(.done)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .glassEffect(.regular.tint(Color.loopControlTint), in: Capsule())

                    HStack(spacing: 10) {
                        glassIconButton("camera.fill", tint: Color.accentColor) {
                            showPhotoOrEmojiChoice = true
                        }
                        if !viewModel.isFavoriteEditing {
                            glassIconButton(viewModel.isFavorited ? "heart.fill" : "heart", tint: .pink) {
                                viewModel.toggleFavorite()
                            }
                            glassIconButton("star.fill", tint: .yellow) {
                                showFavorites = true
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .frame(width: isOpen ? Self.bubbleWidth : nil, alignment: .leading)
        .contentShape(bubbleShape(expanded: isOpen))
        .onTapGesture {}
        .glassEffect(.regular.interactive(), in: bubbleShape(expanded: isOpen))
        .glassEffectID("mealNameBubble", in: bubbleGlass)
        .sheet(isPresented: $showFavorites) { favoritesSheet }
    }

    private func glassIconButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(GlassButtonStyle(in: Circle()))
    }

    private var favoritesSheet: some View {
        NavigationView {
            List(viewModel.favoriteMeals) { meal in
                Button {
                    viewModel.applyFavorite(meal); showFavorites = false
                } label: {
                    let emojis = meal.components.map { $0.foodEmoji }.joined()
                    Text(emojis.isEmpty ? meal.name : "\(meal.name)  \(emojis)")
                }
            }
            .navigationTitle(Text("Favorite Foods", comment: "Favorites list title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Done", comment: "Done")) { showFavorites = false }
                }
            }
        }
    }

    // MARK: - Card container

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .loopTileGlass()
            .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    // MARK: - Carb sub-block

    private func settingRow<Trailing: View>(_ title: LocalizedStringKey,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func pickerHitShield<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0))
            content()
                .frame(width: 220, height: 180)
        }
        .frame(width: 260, height: 220)
    }

    private func subBlockCard(_ block: Binding<MealCarbSubBlock>) -> some View {
        let id = block.wrappedValue.id
        return card {
            // `spacing` is a MERGE distance, not a gap: anything above the gap
            // between the food-type circles fuses them into one blob.
            GlassEffectContainer(spacing: 0) {
                VStack(spacing: 18) {
                    // Only earns its space when there is more than one box to
                    // tell apart — the meal bubble above already names the meal.
                    if viewModel.subBlocks.count > 1 {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(block.wrappedValue.caption.isEmpty
                                     ? NSLocalizedString("Carbs", comment: "Default carb box title")
                                     : block.wrappedValue.caption)
                                    .font(.headline)
                                Text(MealFoodEmoji.label(for: block.wrappedValue.foodEmoji))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { viewModel.removeSubBlock(id) } label: {
                                Image(systemName: "minus")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(GlassButtonStyle(in: Circle()))
                        }
                    }

                    // Amount — bare numerals, no box.
                    VStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Spacer(minLength: 0)
                            TextField("0", text: block.amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .fixedSize()
                                .focused($amountFocus, equals: id)
                            Text("g", comment: "Grams unit")
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { amountFocus = id }

                        if block.wrappedValue.amountText.isEmpty,
                           let lo = block.wrappedValue.suggestedGramsLow,
                           let hi = block.wrappedValue.suggestedGramsHigh {
                            Text(String(format: NSLocalizedString("Suggested %d–%d g", comment: "AI suggested carb range"), Int(lo), Int(hi)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Offset time matches Absorption Time: a semibold glass chip
                    // opening a wheel popover with the native picker highlighter.
                    settingRow("Offset Time") {
                        Button { offsetPickerBlockID = id } label: {
                            Text(block.wrappedValue.offsetTime, style: .time)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(GlassButtonStyle(in: Capsule()))
                        .popover(isPresented: Binding(
                            get: { offsetPickerBlockID == id },
                            set: { if !$0 { offsetPickerBlockID = nil } }
                        )) {
                            pickerHitShield {
                                Picker("", selection: offsetTimeBinding(block)) {
                                    ForEach(offsetTimeOptions(for: block.wrappedValue.offsetTime), id: \.self) { time in
                                        Text(time, style: .time).tag(time)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .labelsHidden()
                            }
                            .presentationCompactAdaptation(.popover)
                        }
                    }

                    // Food type
                    settingRow("Food Type") {
                        HStack(spacing: 4) {
                            ForEach(MealFoodEmoji.presets, id: \.self) { emoji in
                                let current = block.wrappedValue.foodEmoji
                                let isCustomSlot = emoji == MealFoodEmoji.other
                                let hasCustomEmoji = !current.isEmpty && !MealFoodEmoji.presets.contains(current)
                                let display = (isCustomSlot && hasCustomEmoji) ? current : emoji
                                let isSelected = isCustomSlot
                                    ? (hasCustomEmoji || current == MealFoodEmoji.other)
                                    : current == emoji
                                Button {
                                    if isCustomSlot {
                                        emojiPickerBlockID = id
                                    } else {
                                        viewModel.selectEmoji(emoji, for: id)
                                    }
                                } label: {
                                    Text(display)
                                        .font(.title3)
                                        .frame(width: 38, height: 38)
                                        .scaleEffect(isSelected ? 1.1 : 1)
                                        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isSelected)
                                }
                                .buttonStyle(GlassButtonStyle(
                                    isSelected ? .regular.tint(Color.loopSelectionTint).interactive() : .regular.interactive(),
                                    in: Circle()))
                            }
                        }
                    }

                    // Absorption — same interaction as the times: a chip that
                    // opens a wheel in a system popover, which dismisses itself
                    // on an outside tap.
                    settingRow("Absorption Time") {
                        Button { absorptionPickerBlockID = id } label: {
                            Text(absorptionText(block.wrappedValue.absorptionTime))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(GlassButtonStyle(in: Capsule()))
                        .popover(isPresented: Binding(
                            get: { absorptionPickerBlockID == id },
                            set: { if !$0 { absorptionPickerBlockID = nil } }
                        )) {
                            pickerHitShield {
                                Picker("", selection: block.absorptionTime) {
                                    ForEach(absorptionOptions, id: \.self) { t in
                                        Text(absorptionText(t)).tag(t)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .labelsHidden()
                            }
                            // Without this a popover becomes a sheet on iPhone.
                            .presentationCompactAdaptation(.popover)
                        }
                    }
                }
            }
        }
    }

    private var addSubBlockButton: some View {
        Button { viewModel.addSubBlock() } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(GlassButtonStyle(in: Circle()))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Continue pill

    private var continuePill: some View {
        Button(action: confirmSubmit) {
            (viewModel.isFavoriteEditing
                ? Text("Save", comment: "Floating save pill label (favorite editing)")
                : Text("Continue", comment: "Floating submit pill label"))
                // Matches the top-bar Continue EXACTLY — same body/semibold, and
                // the same LABEL colour rather than the accent. Both controls
                // perform the identical action and share an enabled state; when
                // one was blue and the other black they read as two different
                // buttons. iOS renders a `.confirmationAction` toolbar item in
                // the label colour, so that is what this follows.
                .font(.body.weight(.semibold))
                .foregroundStyle(viewModel.submitDisabled ? Color.secondary : Color.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
        .disabled(viewModel.submitDisabled)
        .padding(.horizontal, 20)
        // SwiftUI's keyboard avoidance already lifts the pill to the keypad's
        // top edge; sitting flush against it reads as the pill being part of the
        // keyboard. This is the deliberate gap above it.
        .padding(.bottom, keyboard.height > 0 ? Self.keyboardClearance : 10)
        .padding(.top, 20)
        .animation(.easeOut(duration: 0.2), value: keyboard.height > 0)
    }

    /// Gap between the floating pill and the top of the keyboard.
    private static let keyboardClearance: CGFloat = 14

    @ViewBuilder
    private var bolusNavigationLink: some View {
        if viewModel.isFavoriteEditing {
            EmptyView()
        } else {
            let isActive = Binding(get: { viewModel.bolusViewModel != nil },
                                   set: { if !$0 { viewModel.bolusViewModel = nil } })
            NavigationLink(isActive: isActive) {
                if let vm = viewModel.bolusViewModel {
                    BolusEntryView(viewModel: vm)
                        .environmentObject(displayGlucosePreference)
                        .environment(\.dismissAction, dismiss)
                }
            } label: { EmptyView() }
            .frame(width: 0, height: 0).opacity(0)
        }
    }

    // MARK: - Helpers

    private var absorptionOptions: [TimeInterval] {
        stride(from: LoopConstants.minCarbAbsorptionTime,
               through: LoopConstants.maxCarbAbsorptionTime,
               by: 1800).map { $0 }
    }

    private func offsetTimeBinding(_ block: Binding<MealCarbSubBlock>) -> Binding<Date> {
        Binding(
            get: { roundedOffsetTime(block.wrappedValue.offsetTime) },
            set: { block.wrappedValue.offsetTime = $0 }
        )
    }

    private func offsetTimeOptions(for date: Date) -> [Date] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        return stride(from: 0, through: 23 * 60 + 55, by: 5).compactMap { minutes in
            calendar.date(byAdding: .minute, value: minutes, to: startOfDay)
        }
    }

    private func roundedOffsetTime(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let roundedMinutes = min(23 * 60 + 55, Int((Double(minutes) / 5).rounded()) * 5)
        return calendar.date(byAdding: .minute, value: roundedMinutes, to: calendar.startOfDay(for: date)) ?? date
    }

    private func absorptionText(_ t: TimeInterval) -> String {
        String(format: "%.1f h", t / 3600)
    }
}

// MARK: - Emoji and photo pickers
// (moved here from the removed AI photo screen; the meal screen still uses them)

/// One searchable food-emoji entry: the emoji plus keywords to match against.
struct FoodEmoji: Hashable {
    let emoji: String
    let keywords: [String]
}

/// A curated, SEARCHABLE food-emoji grid (modeled on Loop's own food-type picker
/// rather than the system emoji keyboard). Calls `onPick` and dismisses.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(minimum: 40)), count: 6)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if query.isEmpty {
                        ForEach(EmojiLibrary.sections, id: \.title) { sec in
                            section(title: sec.title, items: sec.items)
                        }
                    } else {
                        let results = EmojiLibrary.search(query)
                        if results.isEmpty {
                            Text("No matching food emoji", comment: "Empty emoji search result")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            grid(items: results)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(Text("Choose Emoji", comment: "Emoji picker title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("Search food", comment: "Emoji search field prompt"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [FoodEmoji]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            grid(items: items)
        }
    }

    private func grid(items: [FoodEmoji]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items, id: \.self) { item in
                Button {
                    onPick(item.emoji); dismiss()
                } label: {
                    Text(item.emoji).font(.system(size: 30))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressExpandButtonStyle())
            }
        }
    }
}

/// Curated, keyword-tagged food-emoji library for the picker. Grouped by
/// absorption feel (fast / medium / slow / drinks / other) and searchable.
enum EmojiLibrary {
    static let sections: [(title: String, items: [FoodEmoji])] = [
        ("Fast", [
            .init(emoji: "🍭", keywords: ["candy", "lollipop", "sugar", "sweet"]),
            .init(emoji: "🍬", keywords: ["candy", "sweet", "sugar"]),
            .init(emoji: "🍯", keywords: ["honey", "syrup", "sweet"]),
            .init(emoji: "🍉", keywords: ["watermelon", "melon", "fruit"]),
            .init(emoji: "🍇", keywords: ["grapes", "fruit"]),
            .init(emoji: "🍓", keywords: ["strawberry", "berry", "fruit"]),
            .init(emoji: "🫐", keywords: ["blueberries", "berry", "fruit"]),
            .init(emoji: "🍒", keywords: ["cherry", "cherries", "fruit"]),
            .init(emoji: "🍌", keywords: ["banana", "fruit"]),
            .init(emoji: "🍊", keywords: ["orange", "tangerine", "citrus", "fruit"]),
            .init(emoji: "🍎", keywords: ["apple", "fruit"]),
            .init(emoji: "🍏", keywords: ["apple", "green apple", "fruit"]),
            .init(emoji: "🍐", keywords: ["pear", "fruit"]),
            .init(emoji: "🍑", keywords: ["peach", "fruit"]),
            .init(emoji: "🥭", keywords: ["mango", "fruit"]),
            .init(emoji: "🍍", keywords: ["pineapple", "fruit"]),
            .init(emoji: "🥝", keywords: ["kiwi", "fruit"]),
            .init(emoji: "🍈", keywords: ["melon", "fruit"]),
            .init(emoji: "🍋", keywords: ["lemon", "citrus", "fruit"]),
            .init(emoji: "🍧", keywords: ["shaved ice", "dessert", "sweet"]),
            .init(emoji: "🍦", keywords: ["ice cream", "soft serve", "dessert"]),
            .init(emoji: "🧁", keywords: ["cupcake", "dessert", "sweet"]),
            .init(emoji: "🍪", keywords: ["cookie", "biscuit", "dessert"]),
            .init(emoji: "🍿", keywords: ["popcorn", "snack"])
        ]),
        ("Medium", [
            .init(emoji: "🌮", keywords: ["taco", "mexican"]),
            .init(emoji: "🌯", keywords: ["burrito", "wrap", "mexican"]),
            .init(emoji: "🫓", keywords: ["flatbread", "pita", "naan", "bread"]),
            .init(emoji: "🥙", keywords: ["pita", "gyro", "kebab", "wrap"]),
            .init(emoji: "🍞", keywords: ["bread", "toast", "loaf"]),
            .init(emoji: "🥖", keywords: ["baguette", "bread"]),
            .init(emoji: "🥨", keywords: ["pretzel", "bread"]),
            .init(emoji: "🥯", keywords: ["bagel", "bread"]),
            .init(emoji: "🥪", keywords: ["sandwich", "sub"]),
            .init(emoji: "🍚", keywords: ["rice", "grain"]),
            .init(emoji: "🍙", keywords: ["rice ball", "onigiri", "rice"]),
            .init(emoji: "🍘", keywords: ["rice cracker", "rice"]),
            .init(emoji: "🍜", keywords: ["ramen", "noodles", "soup"]),
            .init(emoji: "🍝", keywords: ["pasta", "spaghetti", "noodles"]),
            .init(emoji: "🍲", keywords: ["stew", "soup", "hot pot"]),
            .init(emoji: "🥘", keywords: ["paella", "pan", "stew"]),
            .init(emoji: "🥗", keywords: ["salad", "greens", "vegetables"]),
            .init(emoji: "🥔", keywords: ["potato", "vegetable"]),
            .init(emoji: "🌽", keywords: ["corn", "vegetable"]),
            .init(emoji: "🥕", keywords: ["carrot", "vegetable"]),
            .init(emoji: "🥦", keywords: ["broccoli", "vegetable"]),
            .init(emoji: "🍠", keywords: ["sweet potato", "yam", "vegetable"]),
            .init(emoji: "🥟", keywords: ["dumpling", "gyoza", "potsticker"]),
            .init(emoji: "🍣", keywords: ["sushi", "fish", "rice"]),
            .init(emoji: "🍱", keywords: ["bento", "box", "meal"])
        ]),
        ("Slow", [
            .init(emoji: "🍕", keywords: ["pizza", "cheese"]),
            .init(emoji: "🍔", keywords: ["burger", "hamburger", "cheeseburger"]),
            .init(emoji: "🍟", keywords: ["fries", "chips", "fried"]),
            .init(emoji: "🌭", keywords: ["hot dog", "sausage"]),
            .init(emoji: "🥓", keywords: ["bacon", "pork", "fat"]),
            .init(emoji: "🥩", keywords: ["steak", "meat", "beef"]),
            .init(emoji: "🍖", keywords: ["meat", "bone", "rib"]),
            .init(emoji: "🍗", keywords: ["chicken", "poultry", "drumstick"]),
            .init(emoji: "🧀", keywords: ["cheese", "dairy"]),
            .init(emoji: "🥚", keywords: ["egg"]),
            .init(emoji: "🍳", keywords: ["egg", "fried egg", "breakfast"]),
            .init(emoji: "🥜", keywords: ["peanuts", "nuts", "fat"]),
            .init(emoji: "🌰", keywords: ["chestnut", "nut"]),
            .init(emoji: "🥑", keywords: ["avocado", "fat"]),
            .init(emoji: "🧈", keywords: ["butter", "fat", "dairy"]),
            .init(emoji: "🥞", keywords: ["pancakes", "breakfast"]),
            .init(emoji: "🧇", keywords: ["waffle", "breakfast"]),
            .init(emoji: "🍩", keywords: ["donut", "doughnut", "dessert"]),
            .init(emoji: "🎂", keywords: ["cake", "birthday", "dessert"]),
            .init(emoji: "🍰", keywords: ["cake", "shortcake", "dessert"]),
            .init(emoji: "🥧", keywords: ["pie", "dessert"]),
            .init(emoji: "🍫", keywords: ["chocolate", "dessert", "sweet"]),
            .init(emoji: "🍮", keywords: ["custard", "flan", "pudding", "dessert"])
        ]),
        ("Drinks", [
            .init(emoji: "🥤", keywords: ["soda", "drink", "cup", "juice"]),
            .init(emoji: "🧃", keywords: ["juice", "box", "drink"]),
            .init(emoji: "🧋", keywords: ["boba", "bubble tea", "drink"]),
            .init(emoji: "🥛", keywords: ["milk", "dairy", "drink"]),
            .init(emoji: "☕️", keywords: ["coffee", "tea", "drink"]),
            .init(emoji: "🍵", keywords: ["tea", "matcha", "drink"]),
            .init(emoji: "🧉", keywords: ["mate", "drink"]),
            .init(emoji: "🍺", keywords: ["beer", "alcohol", "drink"]),
            .init(emoji: "🍷", keywords: ["wine", "alcohol", "drink"]),
            .init(emoji: "🥂", keywords: ["champagne", "alcohol", "drink"]),
            .init(emoji: "🍹", keywords: ["cocktail", "alcohol", "drink"]),
            .init(emoji: "🍸", keywords: ["martini", "cocktail", "alcohol"])
        ]),
        ("Other", [
            .init(emoji: "🍽️", keywords: ["meal", "plate", "food", "generic"]),
            .init(emoji: "🥣", keywords: ["bowl", "cereal", "soup"]),
            .init(emoji: "🍤", keywords: ["shrimp", "prawn", "seafood", "fried"]),
            .init(emoji: "🦞", keywords: ["lobster", "seafood"]),
            .init(emoji: "🦐", keywords: ["shrimp", "seafood"]),
            .init(emoji: "🐟", keywords: ["fish", "seafood"]),
            .init(emoji: "🍄", keywords: ["mushroom", "vegetable"]),
            .init(emoji: "🫑", keywords: ["pepper", "bell pepper", "vegetable"]),
            .init(emoji: "🍅", keywords: ["tomato", "vegetable"]),
            .init(emoji: "🥒", keywords: ["cucumber", "pickle", "vegetable"]),
            .init(emoji: "🫘", keywords: ["beans", "legume"]),
            .init(emoji: "🧆", keywords: ["falafel", "meatball"]),
            .init(emoji: "🍛", keywords: ["curry", "rice"]),
            .init(emoji: "🍥", keywords: ["fish cake", "narutomaki"]),
            .init(emoji: "🥮", keywords: ["mooncake", "dessert"])
        ])
    ]

    /// All entries flat, for search.
    static let all: [FoodEmoji] = sections.flatMap { $0.items }

    /// Case-insensitive keyword/emoji search.
    static func search(_ query: String) -> [FoodEmoji] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { item in
            item.emoji == q || item.keywords.contains { $0.contains(q) }
        }
    }
}

/// Reusable camera/library image picker.
struct MealImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    let source: UIImagePickerController.SourceType
    let onPicked: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(source) ? source : .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: MealImagePicker
        init(_ parent: MealImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
                parent.onPicked(true)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

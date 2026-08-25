//
//  PhotoCaptureView.swift
//  Loop
//
//  AI entry composer (§8): a text box alongside a camera icon so the user can
//  type a note, add a photo, or both — then Continue. The camera icon lets them
//  choose Take Photo or Choose from Library. One estimate, no chat/multi-turn.
//
//  Also hosts MealImagePicker, the shared camera/library bridge used elsewhere.
//

import SwiftUI
import UIKit

/// The AI composer shown when the user taps the AI button. Supports MULTIPLE
/// photos of one meal (different angles or separate components).
struct AICarbComposerView: View {
    @Binding var note: String
    @Binding var images: [UIImage]
    let onContinue: () -> Void
    let onCancel: () -> Void

    @State private var showSourceDialog = false
    @State private var pickerSource: UIImagePickerController.SourceType = .camera
    @State private var showPicker = false
    @State private var pickedImage: UIImage?

    private var canContinue: Bool {
        !images.isEmpty || !note.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if !images.isEmpty {
                    photoStrip
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                // Text box alongside the camera icon.
                HStack(spacing: 12) {
                    TextField(
                        NSLocalizedString("Describe your meal, or leave blank", comment: "AI composer note placeholder"),
                        text: $note
                    )
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Button { showSourceDialog = true } label: {
                        Image(systemName: "camera.fill")
                            .font(.title2)
                            .frame(width: 52, height: 52)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .contentShape(Circle())   // full circle tappable
                    }
                    .buttonStyle(PressExpandButtonStyle())
                    .sensoryFeedback(.impact(weight: .light), trigger: showSourceDialog) { _, new in new }
                }

                Spacer()

                Button(action: onContinue) {
                    Text("Continue", comment: "AI composer continue button")
                }
                .buttonStyle(PillActionButtonStyle(.primary))   // glass pill + expand
                .disabled(!canContinue)
            }
            .padding(20)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: images.count)
            .sensoryFeedback(.impact(weight: .medium), trigger: images.count)
            .navigationTitle(Text("AI Meal Estimate", comment: "AI composer screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onCancel) { Text("Cancel", comment: "Button label for cancel") }
                }
            }
            .confirmationDialog(
                Text("Add a Photo", comment: "Camera source chooser title"),
                isPresented: $showSourceDialog, titleVisibility: .visible
            ) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button(NSLocalizedString("Take Photo", comment: "Camera source: take photo")) {
                        pickerSource = .camera; showPicker = true
                    }
                }
                Button(NSLocalizedString("Choose from Library", comment: "Camera source: library")) {
                    pickerSource = .photoLibrary; showPicker = true
                }
            }
            .sheet(isPresented: $showPicker) {
                MealImagePicker(image: $pickedImage, source: pickerSource) { _ in }
            }
            .onChange(of: pickedImage) { _, new in
                if let new {
                    images.append(new)
                    pickedImage = nil
                }
            }
        }
    }

    /// Horizontal strip of the added photos, each removable.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                // Bounds-check: the captured index can be stale
                                // if the array mutated mid-animation (would crash
                                // with .offset-keyed ForEach).
                                if images.indices.contains(index) {
                                    images.remove(at: index)
                                }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3).foregroundStyle(.white, .black.opacity(0.45))
                                .padding(5)
                        }
                    }
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

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

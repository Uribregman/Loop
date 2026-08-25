//
//  CarbPromptStore.swift
//  Loop
//
//  Local, versioned storage for the editable AI prompt TEMPLATE (the free-
//  language instructions; the JSON output contract is appended separately by
//  CarbEstimateWireFormat and is not editable).
//
//  OFFLINE BY DESIGN: this file uses only Foundation + UserDefaults. There is
//  no networking import and no way for the editing pipeline to touch the
//  network — the prompt only leaves the device through the existing provider
//  request path.
//
//  Storage model (§space-efficient): version 0 ("Original") stores the FULL
//  text. Every later version stores only a DELTA against the previous version
//  in the chain (common prefix length, common suffix length, and the replaced
//  middle). Full texts are reconstructed on demand for display.
//

import Foundation

/// The changed middle of an edit, relative to the previous version's text.
struct PromptDelta: Codable {
    /// Characters unchanged at the start of the previous text.
    var prefixCount: Int
    /// Characters unchanged at the end of the previous text.
    var suffixCount: Int
    /// What the middle was replaced with.
    var replacement: String
}

struct PromptVersion: Codable, Identifiable {
    let id: String
    var name: String
    let date: Date
    /// Full text — present ONLY on the base (first) version of the chain.
    var fullText: String?
    /// Delta vs. the previous version — present on every non-base version.
    var delta: PromptDelta?
}

final class CarbPromptStore {
    static let shared = CarbPromptStore()

    private let defaultsKey = "com.loopkit.Loop.aiCarbPromptVersions"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The built-in instruction template (everything the user may edit).
    /// The JSON contract + user note/volume are appended by the wire format.
    static let defaultTemplate: String = [
        "Act as a Certified Diabetes Care and Education Specialist (CDCES) and Registered Dietitian (RD)",
        "specializing in Type 1 Diabetes, with expertise in advanced carb counting and how complex food",
        "matrices affect blood-glucose patterns. A carbohydrate is never isolated: its glycemic impact",
        "depends on the whole meal. Analyze macronutrient interactions — how FAT, PROTEIN and FIBER delay",
        "gastric emptying, slow glucose absorption, and blunt/extend the spike (a plain bun digests fast;",
        "the same bun with a fatty burger and cheese gives a delayed, prolonged rise).",
        "Use this clinical analysis to DRIVE the structured output below: split the meal into a fast",
        "component and a slow FPU (fat/protein) component when the composition warrants it, set each",
        "component's absorption time to match its real digestion curve, and use offsetMinutes for a portion",
        "that acts later (the FPU tail) — this is effectively an extended/split-bolus strategy expressed",
        "as separate carb boxes. In each 'reason', briefly note the composition and expected glucose",
        "trajectory (fast spike vs. delayed/extended rise) that justifies that box.",
        "You may receive MULTIPLE photos — they are different angles of the SAME meal, or separate",
        "components of it. Combine everything into ONE single meal estimate; never treat photos as",
        "separate meals, and don't double-count food that appears in more than one photo.",
        "photos may be of nutrians list if its a spacific size (e.g one bar, one donut, etc.)",
        "it can also be general nutritions in which case the user will say how much they are eating",
        "by another photo or text  and you calculate.",
        "Look at the FULL image(s) carefully. Identify EVERY distinct food in the meal.",
        "SCALE REFERENCES: actively look for objects of known size to judge portion sizes —",
        "fork/spoon (~19/16 cm), credit card (8.6×5.4 cm), coins,entry chips, keychain swiss army knife (length 5.8 cm)",
        "smartphone, or a hand. If the user's note names a reference object or gives sizes/weights,",
        "trust it over your visual guess. Mention the reference you used in the component 'reason'.",
        "'mealName' MUST list all the foods you see (e.g. \"Pizza, salad & soda\").",
        "Use as MANY or as FEW components (carb boxes) as the meal actually needs — anywhere from 1",
        "up to a maximum of 4. Do NOT pad to a fixed number: a simple food is a single component.",
        "Only split when it genuinely helps — e.g. a food that is part fast-absorbing and part slow",
        "(pizza: a fast portion over ~3h and a slow fat/protein portion over ~6h — just an example).",
        "For each component set 'name' to a SHORT caption of what that box contains.",
        "'emoji' MUST be exactly one of: 🍭 (sugar / very fast), 🌮 (normal carbs), 🍕 (fat & protein / slow).",
        "'kind' is 'fast' for 🍭/🌮 and 'fpu' for 🍕.",
        "First choose the emoji, THEN set 'absorptionSeconds' to the precise absorption time.",
        "Decide if a component should start later than the meal: set 'offsetMinutes' (0 = at meal time,",
        "e.g. 120 for a slow portion that mostly acts ~2h later). Give one short 'reason' per component.",
        "Make sure you consider all coponents in the meal unless user said otherwise."
    ].joined(separator: "\n")

    // MARK: - Reading

    /// All versions, chain order (index 0 = base/original, last = ACTIVE).
    func versions() -> [PromptVersion] {
        loadChain()
    }

    /// The template that currently feeds the AI (last version in the chain,
    /// or the built-in default when the user never edited anything).
    func activeTemplate() -> String {
        let chain = loadChain()
        guard !chain.isEmpty else { return Self.defaultTemplate }
        return reconstructText(at: chain.count - 1, in: chain)
    }

    /// Full text of a specific version, reconstructed from the delta chain.
    func text(of versionID: String) -> String? {
        let chain = loadChain()
        guard let idx = chain.firstIndex(where: { $0.id == versionID }) else { return nil }
        return reconstructText(at: idx, in: chain)
    }

    // MARK: - Writing

    /// Save `text` as a new version on top of the chain (it becomes active).
    /// Creates the base "Original" entry first if the chain is empty.
    /// Returns the new version's id, or nil if the text equals the active one.
    @discardableResult
    func saveNewVersion(text: String, name: String? = nil) -> String? {
        var chain = loadChain()
        if chain.isEmpty {
            chain.append(PromptVersion(
                id: UUID().uuidString,
                name: NSLocalizedString("Original", comment: "Name of the built-in AI prompt version"),
                date: Date(),
                fullText: Self.defaultTemplate,
                delta: nil
            ))
        }
        let currentText = reconstructText(at: chain.count - 1, in: chain)
        guard text != currentText else { return nil }

        let version = PromptVersion(
            id: UUID().uuidString,
            name: name ?? Self.defaultName(for: Date()),
            date: Date(),
            fullText: nil,
            delta: Self.delta(from: currentText, to: text)
        )
        chain.append(version)
        saveChain(chain)
        return version.id
    }

    /// Restore an old version: its text is COPIED to the top of the chain and
    /// becomes active; every newer version stays in the history untouched.
    @discardableResult
    func restore(versionID: String) -> Bool {
        guard let restoredText = text(of: versionID),
              let original = loadChain().first(where: { $0.id == versionID }) else { return false }
        let name = String(
            format: NSLocalizedString("%@ (restored)", comment: "Name of a restored AI prompt version (1: old name)"),
            original.name
        )
        // Same text as active → still surface the restore as a new top entry?
        // No: keep the chain clean; only append when the text differs.
        return saveNewVersion(text: restoredText, name: name) != nil
    }

    func rename(versionID: String, to newName: String) {
        var chain = loadChain()
        guard let idx = chain.firstIndex(where: { $0.id == versionID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        chain[idx].name = trimmed
        saveChain(chain)
    }

    /// Delete a version. The chain is REBASED so every other version's text is
    /// preserved exactly: the successor's delta is recomputed against the
    /// deleted version's predecessor (or the successor becomes the new base).
    /// The last remaining version cannot be deleted.
    @discardableResult
    func delete(versionID: String) -> Bool {
        var chain = loadChain()
        guard chain.count > 1,
              let idx = chain.firstIndex(where: { $0.id == versionID }) else { return false }

        if idx + 1 < chain.count {
            // Rebase successor before removing idx.
            let successorText = reconstructText(at: idx + 1, in: chain)
            if idx == 0 {
                chain[1].fullText = successorText
                chain[1].delta = nil
            } else {
                let predecessorText = reconstructText(at: idx - 1, in: chain)
                chain[idx + 1].delta = Self.delta(from: predecessorText, to: successorText)
                chain[idx + 1].fullText = nil
            }
        }
        chain.remove(at: idx)
        saveChain(chain)
        return true
    }

    // MARK: - Delta plumbing

    /// Compact edit: keep the common prefix + suffix, store only the middle.
    static func delta(from old: String, to new: String) -> PromptDelta {
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let replacement = String(newChars[prefix..<(newChars.count - suffix)])
        return PromptDelta(prefixCount: prefix, suffixCount: suffix, replacement: replacement)
    }

    static func apply(_ delta: PromptDelta, to text: String) -> String {
        let chars = Array(text)
        let prefix = max(0, min(delta.prefixCount, chars.count))
        let suffix = max(0, min(delta.suffixCount, chars.count - prefix))
        return String(chars[0..<prefix]) + delta.replacement + String(chars[(chars.count - suffix)...])
    }

    private func reconstructText(at index: Int, in chain: [PromptVersion]) -> String {
        var text = chain.first?.fullText ?? Self.defaultTemplate
        guard index > 0 else { return text }
        for i in 1...index {
            if let delta = chain[i].delta {
                text = Self.apply(delta, to: text)
            } else if let full = chain[i].fullText {
                text = full
            }
        }
        return text
    }

    // MARK: - Persistence

    private func loadChain() -> [PromptVersion] {
        guard let data = defaults.data(forKey: defaultsKey),
              let chain = try? JSONDecoder().decode([PromptVersion].self, from: data) else {
            return []
        }
        return chain
    }

    private func saveChain(_ chain: [PromptVersion]) {
        if let data = try? JSONEncoder().encode(chain) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return String(
            format: NSLocalizedString("Edit %@", comment: "Default name of a saved AI prompt version (1: date)"),
            formatter.string(from: date)
        )
    }
}

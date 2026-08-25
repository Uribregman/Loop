//
//  CarbEstimateWireFormat.swift
//  Loop
//
//  Shared prompt + JSON schema used by all REST providers (Gemini, Claude,
//  Custom) so they request and decode the same structured shape. Keeps the
//  provider contract identical regardless of vendor.
//

import Foundation

enum CarbEstimateWireFormat {

    /// Instruction text sent to the model. Asks for STRICT JSON matching `WireEstimate`.
    /// Gram values must be ranges (§6).
    ///
    /// The instruction TEMPLATE is user-editable (CarbPromptStore, versioned,
    /// offline); the JSON output contract below is always appended verbatim so
    /// the app can parse the reply no matter how the template was edited.
    static func prompt(note: String?, volumeMilliliters: Double?, webSearchAvailable: Bool = false) -> String {
        var lines = [
            CarbPromptStore.shared.activeTemplate(),
            "Respond with ONLY valid JSON, no markdown, matching exactly:",
            "{\"mealName\":string,\"components\":[{\"kind\":\"fast|fpu\",\"name\":string,\"emoji\":string,\"gramsLow\":number,\"gramsHigh\":number,\"absorptionSeconds\":number,\"offsetMinutes\":number,\"reason\":string}]}"
        ]
        if webSearchAvailable {
            lines.append("If the meal includes a specific packaged/branded product or a named restaurant or chain menu item, you may use web search to look up its published nutrition facts before estimating — prefer that over a guess when it's available.")
        }
        if let note, !note.isEmpty {
            lines.append("User note about the meal: \(note)")
        }
        if let volumeMilliliters {
            lines.append("Approximate measured food volume: \(Int(volumeMilliliters)) mL. Use it to tighten the range.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Decoding

    private struct WireComponent: Decodable {
        let kind: String
        let name: String
        let emoji: String?
        let gramsLow: Double
        let gramsHigh: Double
        let absorptionSeconds: Double
        let offsetMinutes: Double?
        let reason: String
    }

    private struct WireEstimate: Decodable {
        let mealName: String?
        let components: [WireComponent]
    }

    /// Decode a model's text answer (which should be JSON) into a `CarbEstimate`.
    /// Tolerates the model wrapping JSON in prose/markdown by extracting the
    /// outermost `{...}` object.
    static func decode(text: String) throws -> CarbEstimate {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(WireEstimate.self, from: data),
              !wire.components.isEmpty else {
            throw CarbEstimationError.badResponse
        }

        let components: [CarbEstimateComponent] = wire.components.prefix(4).map { c in
            let low = min(c.gramsLow, c.gramsHigh)
            let high = max(c.gramsLow, c.gramsHigh)
            let kind: CarbEstimateComponent.Kind = c.kind.lowercased() == "fpu" ? .fpu : .fast
            // Constrain to the three allowed preset emojis.
            let allowed: Set<String> = ["🍭", "🌮", "🍕"]
            let emoji = (c.emoji.map { allowed.contains($0) ? $0 : nil } ?? nil) ?? (kind == .fpu ? "🍕" : "🌮")
            return CarbEstimateComponent(
                kind: kind,
                name: c.name,
                emoji: emoji,
                gramsLow: low,
                gramsHigh: high,
                absorptionTime: c.absorptionSeconds,
                offsetMinutes: c.offsetMinutes ?? 0,
                absorptionReason: c.reason
            )
        }
        let mealName = (wire.mealName?.isEmpty == false) ? wire.mealName! :
            wire.components.map { $0.name }.joined(separator: ", ")
        return CarbEstimate(mealName: mealName, components: components)
    }

    /// Extract the first balanced top-level JSON object from arbitrary text.
    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...idx])
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}

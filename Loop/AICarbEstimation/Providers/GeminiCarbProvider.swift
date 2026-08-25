//
//  GeminiCarbProvider.swift
//  Loop
//
//  Google Gemini REST provider (multimodal, no SDK). Estimate only.
//

import Foundation

struct GeminiCarbProvider: CarbEstimationProvider {
    let apiKey: String

    /// NOTE: confirm the current Gemini model name at build time (§10 Q4) — do not
    /// assume this is current. Easy to change here.
    var model = "gemini-2.5-flash"
    var timeout: TimeInterval = 30

    func estimate(_ input: CarbEstimationInput) async throws -> CarbEstimate {
        guard !apiKey.isEmpty else { throw CarbEstimationError.noAPIKey }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let prompt = CarbEstimateWireFormat.prompt(note: input.note, volumeMilliliters: input.volumeMilliliters, webSearchAvailable: input.webSearch)
        var parts: [[String: Any]] = [["text": prompt]]
        for imageData in input.images {
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": imageData.base64EncodedString()]])
        }
        var body: [String: Any] = ["contents": [["parts": parts]]]
        if input.webSearch {
            // Grounding with Google Search. NOTE: Gemini does not allow the
            // google_search tool together with response_mime_type=application/json,
            // so we drop JSON mode here and rely on the prompt's "ONLY JSON"
            // instruction plus the tolerant JSON extractor in the shared decoder.
            body["tools"] = [["google_search": [String: Any]()]]
        } else {
            body["generationConfig"] = ["response_mime_type": "application/json"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let text = try await CarbProviderHTTP.postForText(request) { data in
            // Gemini: candidates[0].content.parts[*].text. With grounding there
            // can be more than one text part, so concatenate them all in order
            // (the shared decoder extracts the JSON object from the combined text).
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = root["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                return nil
            }
            let texts = parts.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return try CarbEstimateWireFormat.decode(text: text)
    }
}

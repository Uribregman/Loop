//
//  OpenAICarbProvider.swift
//  Loop
//
//  OpenAI ChatGPT REST provider via /v1/chat/completions (multimodal). Estimate only.
//

import Foundation

struct OpenAICarbProvider: CarbEstimationProvider {
    let apiKey: String

    /// NOTE: confirm the current OpenAI vision model name at build time (§10 Q4).
    var model = "gpt-4o"
    /// Model used when web search is enabled. Chat-completions web search requires
    /// a search-capable model, which does NOT support response_format json_object.
    /// NOTE: confirm this model name at build time (§10 Q4).
    var webSearchModel = "gpt-4o-search-preview"
    var timeout: TimeInterval = 30

    func estimate(_ input: CarbEstimationInput) async throws -> CarbEstimate {
        guard !apiKey.isEmpty else { throw CarbEstimationError.noAPIKey }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let prompt = CarbEstimateWireFormat.prompt(note: input.note, volumeMilliliters: input.volumeMilliliters, webSearchAvailable: input.webSearch)
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for imageData in input.images {
            let dataURI = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
            content.append(["type": "image_url", "image_url": ["url": dataURI]])
        }
        var body: [String: Any] = [
            "model": input.webSearch ? webSearchModel : model,
            "messages": [["role": "user", "content": content]]
        ]
        if input.webSearch {
            // Chat-completions web search: enabled via web_search_options and a
            // search-capable model. Those models don't accept response_format
            // json_object, so we omit it and rely on the prompt + tolerant decoder.
            body["web_search_options"] = [String: Any]()
        } else {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let text = try await CarbProviderHTTP.postForText(request) { data in
            // OpenAI: choices[0].message.content
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                return nil
            }
            return text
        }
        return try CarbEstimateWireFormat.decode(text: text)
    }
}

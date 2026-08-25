//
//  ClaudeCarbProvider.swift
//  Loop
//
//  Anthropic Claude REST provider via the /v1/messages endpoint (multimodal).
//  Requires an Anthropic Console API key (separate from any Claude subscription).
//  Estimate only.
//

import Foundation

struct ClaudeCarbProvider: CarbEstimationProvider {
    let apiKey: String

    /// NOTE: confirm the current Claude model name at build time (§10 Q4).
    var model = "claude-sonnet-5"
    var apiVersion = "2023-06-01"
    var timeout: TimeInterval = 30
    /// Cap web searches per estimate so a lookup stays fast and bounded (§ web search).
    var webSearchMaxUses = 3

    func estimate(_ input: CarbEstimationInput) async throws -> CarbEstimate {
        guard !apiKey.isEmpty else { throw CarbEstimationError.noAPIKey }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let prompt = CarbEstimateWireFormat.prompt(note: input.note, volumeMilliliters: input.volumeMilliliters, webSearchAvailable: input.webSearch)
        var content: [[String: Any]] = []
        for imageData in input.images {
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": "image/jpeg",
                "data": imageData.base64EncodedString()
            ]])
        }
        content.append(["type": "text", "text": prompt])
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": content]]
        ]
        if input.webSearch {
            // Anthropic server-side web search tool. Claude decides whether to
            // search; max_uses bounds cost/latency. See docs (web_search_20250305).
            body["tools"] = [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": webSearchMaxUses
            ]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let text = try await CarbProviderHTTP.postForText(request) { data in
            // Claude returns an array of content blocks. With web search enabled
            // there are several `text` blocks (a "let me search" preamble, then
            // the final answer) interleaved with server_tool_use / result blocks.
            // Concatenate ALL text blocks in order so the final JSON answer is
            // always included — the shared decoder extracts the JSON object from
            // the combined text. (The old code grabbed only the first text block,
            // which would be the preamble when searching.)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = root["content"] as? [[String: Any]] else {
                return nil
            }
            let texts = content.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return try CarbEstimateWireFormat.decode(text: text)
    }
}

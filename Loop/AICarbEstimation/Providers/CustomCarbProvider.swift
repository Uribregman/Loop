//
//  CustomCarbProvider.swift
//  Loop
//
//  Generic REST provider for a user-supplied endpoint. Uses a FIXED request/
//  response contract (v1): we POST { prompt, note, volumeMilliliters, imageBase64 }
//  and expect the endpoint to return the shared WireEstimate JSON directly.
//  (Configurable body templates are deferred — §10 Q2.)
//

import Foundation

struct CustomCarbProvider: CarbEstimationProvider {
    let endpoint: String
    let apiKey: String
    var timeout: TimeInterval = 30

    func estimate(_ input: CarbEstimationInput) async throws -> CarbEstimate {
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw CarbEstimationError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "prompt": CarbEstimateWireFormat.prompt(note: input.note, volumeMilliliters: input.volumeMilliliters),
            "note": input.note ?? "",
            "volumeMilliliters": input.volumeMilliliters as Any,
            "imageBase64": input.images.first?.base64EncodedString() ?? "",
            "imagesBase64": input.images.map { $0.base64EncodedString() }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Fixed contract: the endpoint returns the WireEstimate JSON as its body.
        let text = try await CarbProviderHTTP.postForText(request) { data in
            String(data: data, encoding: .utf8)
        }
        return try CarbEstimateWireFormat.decode(text: text)
    }
}

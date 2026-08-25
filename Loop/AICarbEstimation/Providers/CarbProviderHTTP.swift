//
//  CarbProviderHTTP.swift
//  Loop
//
//  Shared HTTP plumbing for REST carb providers: performs the request, maps
//  transport errors to CarbEstimationError, and extracts the model's text via
//  a provider-specific closure. API keys are never logged here.
//

import Foundation

enum CarbProviderHTTP {
    /// POST `request`, then pull the model text out of the JSON response body
    /// using `extractText`. Returns the extracted text or throws a mapped error.
    static func postForText(_ request: URLRequest,
                            extractText: (Data) -> String?) async throws -> String {
        // NETWORK KILL-SWITCH: every AI request in the app funnels through here.
        // When the master toggle is off, the network layer is disconnected — any
        // stored API key stays in place but is inert. Turning AI back on
        // reconnects automatically (this is re-checked on every request).
        guard CarbEstimationSettings().isEnabled else {
            throw CarbEstimationError.aiDisabled
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CarbEstimationError.timeout
        } catch {
            throw CarbEstimationError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw CarbEstimationError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CarbEstimationError.noAPIKey
            }
            throw CarbEstimationError.badResponse
        }
        guard let text = extractText(data) else {
            throw CarbEstimationError.badResponse
        }
        return text
    }
}
